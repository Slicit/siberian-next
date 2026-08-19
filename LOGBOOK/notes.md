<!--
Template: LOGBOOK/notes.md

Codebase learnings: patterns, anti-patterns, gotchas, glossary.

Rules:
  · Agents may propose additions; user confirms before merging.
  · Each entry should be transferable (useful for the next person who
    touches the area), not feature-specific.
  · Cite a concrete file path or commit when relevant.
  · No em-dashes.
-->

# Notes

## Patterns

<!-- Conventions and approaches that have proven useful in this codebase. -->

- Enforce architecture with a check, not a comment: `bin/check-engine-leak` greps `core/` and `lib/` for engine names outside the driver. It found a real leak within minutes of being written.
- One Dockerfile per language, service passed as a build arg: `deploy/rails.Dockerfile` covers all four Rails services. Four near-identical Dockerfiles drift; one does not.

## Anti-patterns

<!-- Things that have caused bugs, regressions, or maintenance pain. Avoid these. -->

- A smoke that greps a fixed temp file can pass while touching nothing. `bin/smoke-backoffice.sh` pointed at `127.0.0.1:8080` and `*.siberian.localhost` from before the stack moved to HTTPS on `siberian.test`. Every request returned 000 and every grep read the page the previous run left in `/tmp`, so the output looked normal for six features. Clear the file before each fetch, and print the status code beside whatever was grepped out of it.

- Piping a `docker compose build` to `tail` throws away its exit status. A build that failed reported success, and the image being missing was only noticed at `up`.

## Gotchas

<!-- Surprising behavior in dependencies, frameworks, or our own code. -->

- Same-origin iframes are not a boundary: a frame served from the parent's own origin can reach `window.parent`, its DOM, and its storage. Module frames are served from `<module>.apps.<domain>` precisely so the boundary is browser-enforced. Never "simplify" a module back onto the parent origin.
- Core images build from the repository root, not from their own directory, because `lib/` has to be copied in. A Dockerfile that assumes its own directory is the build context will fail to find `lib/`. See `deploy/rails.Dockerfile`.
- `rails new --skip-git` also skips generating `.gitignore`, which is not obvious from the flag name. The Database service was generated with it and shipped 1743 bootsnap cache files into the repository. Because those files are written by a container running as root, they then blocked `git pull` on the build host with `unable to unlink old ...: Permission denied`, which reads as a permissions problem rather than as a missing ignore file.
- Rails inflects `quota` as already plural, from the Latin `quotum`, so `DomainQuota` looks for a table called `domain_quota`. The failure is `PG::UndefinedTable` naming a table nobody wrote, which reads as a missing migration rather than as an inflection. Set `self.table_name` on the model.
- A sequence derived from a resettable counter is not a sequence. Attempt numbers came from the retry budget, and reviving a dead message resets that budget while keeping the history, so the next attempt collided with an existing row. Derive an ordinal from what is already there, never from a counter something else is allowed to reset.
- Core services have no route into a module, only the reverse. A module reaches the core at `http://core/...`; a core service addressing a module by its short name resolves to nothing, because only the Router is on both networks. Core to module goes through `http://modules/<name>/...`. The symptom is a DNS failure, which reads as a broken module rather than as a missing door.
- Rails deduplicates commit callbacks by filter name. `after_update_commit :thing` followed by `after_destroy_commit :thing` registers one callback, not two: the second replaces the first and only it ever runs. There is no warning, and `_commit_callbacks` shows a single entry, which reads as normal. Use one `after_commit :thing, on: %i[update destroy]`.
- Postgres reports a NOLOGIN role as `password authentication failed`, not as a disabled account. Uninstalling a module locks its role out that way, so reinstalling handed back correct credentials that could not log in, and the symptom pointed at the password. `DatabaseProvisioner` reactivates the role whenever it hands out an existing one.
- Revoking CONNECT per database does not isolate Postgres tenants on its own. A fresh cluster leaves PUBLIC with CONNECT on `postgres` and `template1`, and from either of them any role can read `pg_database` and `pg_roles` and enumerate every other tenant. Isolating the tenants while leaving the lobby unlocked is not isolation. `PostgresAdmin#harden` revokes both on every provision.
- `config.hosts += [...]` turns an allow-all list into a restrictive one. An empty `config.hosts` means every host is allowed, which is what the test environment relies on, so appending unconditionally makes every integration test fail with `Blocked hosts: www.example.com`. Only extend a list that already has entries.
- A broad .dockerignore pattern can delete a whole service from the build context. `**/storage` was meant for Rails upload directories and also matched `core/storage`, so the Storage service vanished and the image failed with a bare `"/core/storage": not found`. Scope patterns to where they apply: `core/*/storage`.
- Reinstalling a module can 502 for up to the resolver TTL (`valid=10s`). nginx resolves the module short name per request but caches the answer, so for a few seconds after a reinstall it still holds the previous container IP. The route recovers on its own; do not go looking for a bug.
- A module container is unreachable from the Router until the Router joins that module network. Module containers sit on `siberian-mod-<uuid>` and the Router sits on `siberian_core`, so install has to attach the Router explicitly. This is deliberate: it is what stops module A from reaching module B directly.
- Executable bits do not survive authoring on Windows: `chmod +x` is a no-op on the working tree there, so scripts land in git as mode 100644 and fail with `Permission denied` on Linux. Fix in the index with `git update-index --chmod=+x <file>`, not by chmod.
- `resolver 127.0.0.11` is the Docker embedded DNS address, not a general one. Anything engine-specific in Router config has to be rendered from environment, or it silently breaks under a different engine. Caught by `bin/check-engine-leak`.
- A generated healthcheck runs inside an image the core did not build. The probe was `wget ... || curl ...`, and an image with neither exits 127, which the engine counts as a failed probe rather than as a missing tool. A module on `python:3.12-slim` therefore reported unhealthy forever while serving every request. The probe now looks for a client first and says nothing when it finds none, matching what `healthy?` already answers for a container with no healthcheck at all. A module image that wants a real verdict ships wget or curl.

- A `.gitignore` pattern with no leading slash matches at every depth. The root file said "Root level only" and listed `package.json`, which then swallowed `core/mobile-builder/package.json`, and the symptom was a Docker build failing on a file that plainly exists in the working tree. Anchor root-level patterns with `/`.
- `:domain` is a reserved URL option in Rails. `ActionDispatch::Routing::RouteSet::RESERVED_OPTIONS` is `[:host, :protocol, :port, :subdomain, :domain, ...]`, so a route segment named `:domain` never receives its value: it is consumed to build the host, and the path helper raises "missing required keys: [:domain]" for an argument that was in fact passed. Name the segment something else, or address the record by id.
- nginx refuses to start on a variable no `map` defines. A map whose entries another service writes has to have its block in config that is always present, with the entries pulled in by an `include` glob: an include matching nothing is not an error, but an undefined variable is, and the Router stays down on an installation with no modules.
- An expo-* package installed as "*" is built for whichever SDK is newest, not the one in `package.json`. The build then fails in Gradle with `Plugin [id: expo-module-gradle-plugin] was not found`, which reads as a broken Android toolchain rather than as a version mismatch. `expo install` resolves versions against the installed SDK, which is what it is for.

## Glossary

<!-- Project-specific terms an outside reader would not know. -->

- **Module**: the packaged unit a third party ships. A manifest plus one or more containers. Never called a plugin (see `LOGBOOK.md`, Conventions).
- **Core**: the containers required for the system to run at all: Orchestrator, Base App, Router, Configuration, Auth, Mailer, Database.
- **Orchestrator / Backoffice**: the operator-facing app. Installs modules, drives container CRUD, handles maintenance.
- **Base App / Admin**: the product shell end users see. Wraps installed modules in iframes.
- **Capability**: something a module declares it offers, identified as `<module>.<subject>.<role>`. Auto-discovery composes workflows out of these without either module hardcoding the other.
- **Area**: a named region of the Base App where capabilities are listed or linked, for example `sidebar.entities`.
- **Grant**: an access right a module declares in its manifest and an operator approves at install or update time. Nothing outside the grants is reachable.
- **Domain**: one of the several domains the system serves. Each has its own database; containers are shared across all of them.
- **Engine driver**: the backend implementing `Siberian::Engine::Driver`. Docker today, Kubernetes later.
- **Entry container**: the `http` container in a module that the Router points its origin at.
