# Siberian Next

A container orchestrator for modular applications: the core provisions and wires containers, third-party modules ship as container groups in any language, and everything talks over an internal API instead of an in-process plugin ABI.

## Architecture

Two classes of containers.

**Core** (required for the system to run):

- **Orchestrator (Backoffice)**: the operator-facing application. Installs, updates, and removes modules, drives container CRUD, and handles maintenance. Rails with Hotwire, monolith.
- **Base App (Admin)**: the application that wraps every installed module and presents them as one product. Modules render inside it; it does not manage them. Rails with Hotwire, monolith.
- **Router**: gives every installed module a base route (`/module-base-route`) and an internal short DNS name, so modules can call each other over the local API. This is the hook and integration surface between modules.
- **Configuration**: core data and configuration store.
- **Auth**: out-of-the-box authentication exposed over API (OAuth, JWT, 2FA, and the rest of the modern set).
- **Mailer**: out-of-the-box mail delivery exposed over API.
- **Database**: PostgreSQL handler with an internal API that provisions and isolates databases. A module declares the access it needs at install or update time and the core mints scoped credentials automatically, on the Android permission model. A module may also request access to an existing database; default is read-only, with write granted deliberately.

**Third-party modules**: any number of containers per module (for example a Redis, a php-fpm runner, and a small Nginx to serve the app). Install registers the module, mounts its files, and assigns a UUID. Every container of that module is prefixed: `<uuid>-<module_name>-<service>`.

**Language independence**: a module can be written in anything that runs in a container (PHP, Python, Rails, React, and the rest). Integration happens over the internal API, never through a shared runtime. This is the payoff of the container boundary.

**SDKs**: the core ships first-party client SDKs for the common module languages, so a module author talks to the internal APIs and to other modules without hand-rolling HTTP.

**Capabilities**: a module declares in its manifest the capabilities it exposes. The Base App has named areas, and a declared capability is listed or linked in the area it belongs to. Auto-discovery reads these declarations, which is what lets custom workflows be composed across modules without either side hardcoding the other.

**Composition**: the Base App wraps module UIs in iframes. That buys real isolation of styles and of intent. Each module is served from its own origin (`<module>.apps.<domain>`) so the frame boundary is enforced by the browser and not by convention, which matters because modules are third-party code. The auth cookie is scoped to the parent domain, so out-of-the-box auth still covers every frame and the usual iframe auth friction does not apply. Wildcard DNS and a wildcard certificate are a baseline requirement of the product anyway.

**Multi-domain**: the system serves multiple domains. Isolation is at the data layer, not the runtime layer: containers are installed once and shared across domains, while databases are per domain. The Database service mints credentials scoped to the `(module, domain)` pair, the Router and Auth propagate the current domain as request context, and the SDKs resolve the right credential so module authors never handle it by hand.

**Engine abstraction**: the container engine sits behind a driver interface. Docker is the first backend; Kubernetes or an equivalent comes later without rewriting the Orchestrator. This is a deliberate architectural constraint, not a convenience layer.

## Stack

- Two Ruby on Rails monoliths with Hotwire (Turbo, Stimulus): the Orchestrator (Backoffice) and the Base App (Admin)
- Ruby on Rails for the Mailer and the Auth service, API first
- Nginx for the Router
- PostgreSQL for Configuration, for the Database service, and one isolated database per domain
- Container engine behind a driver interface: Docker first, Kubernetes or equivalent later
- Monorepo: every core service, shared library, and SDK lives in this repository

## Repo layout

```
core/            one directory per core container, each with its own Dockerfile
lib/             shared Ruby for the core apps
sdk/             per-language module SDKs (ruby, php, python, node)
modules/         first-party reference modules that exercise the contract
deploy/          compose for development, Kubernetes manifests later
bin/             development entry points
docs/
```

Core images build with the repository root as build context, so `lib/` can be copied in.

## Conventions

- **No em-dashes.** Use commas, parentheses, or middle dots (`·`).
- **Dates: `YYYY-MM-DD`.** Always absolute.
- **Say "module", never "plugin".** The packaged unit is a module. "Plugin" carries the in-process connotation this project rejects, in code, in docs, and in UI copy.
- **File naming:** lowercase, dash-separated.
- **Line endings: LF everywhere**, enforced by `.gitattributes`. CRLF in a container entrypoint fails at runtime.
- **Branch naming:** `feat-<slug>` for features, `fix-<slug>` for fixes.
- **Container naming:** `<uuid>-<module_name>-<service>`. The UUID is assigned once, at first install, and never reused.
- **Isolate data, not runners.** Containers are installed once and shared across every domain. Domain isolation happens in the database layer, never by duplicating container sets.
- **Shared code goes in `lib/`, not extracted gems**, unless something genuinely needs independent versioning. The isolation that matters is core against modules; internal core boundaries do not need packaging ceremony.
- **Engine-specific code lives only in the driver.** No Docker (or Kubernetes) concept leaks into core domain code. If a feature needs an engine capability, it goes through the driver interface or the interface grows.
- **Module to module traffic goes through the Router**, addressed by short internal DNS name. Never hardcode container IPs or ports.
- **Database access is brokered by the Database service.** No module holds a credential it was not granted at install or update time. Read-only is the default grant.

## Non-goals

- **Not a WordPress-style in-process plugin system.** Modules never load code into the core. The isolation boundary is the container, not a language runtime.
- **The Orchestrator does not run module business logic.** It manages container lifecycle, registration, and wiring, nothing else.
- **The Backoffice is not the product shell.** The Orchestrator manages modules; it does not host their UI. Module interfaces are wrapped by the Base App, and the two stay separate applications.
- **The core does not constrain module language or framework.** If it runs in a container and speaks the internal API, it is a valid module.

## Reading order for agents

1. This file (`LOGBOOK.md`).
2. `LOGBOOK/notes.md` for codebase patterns, gotchas, anti-patterns.
3. The active feature file matching the current branch (`LOGBOOK/features/feat-<slug>.md`) if any.
4. `LOGBOOK/features/INDEX.md` for the broader picture.

Do not read `LOGBOOK/ideas.md` unless the user explicitly asks; it is the human-owned inbox.

## Writing guidance for agents

- Append to the current feature's `## Decisions` log when making non-trivial choices. Use today's date.
- Propose additions to `notes.md` when you discover a transferable pattern, gotcha, or anti-pattern. Show a diff and wait for confirmation.
- Never edit `LOGBOOK.md` (this file) without showing the proposed change first.
- Never modify `ideas.md` without an explicit user request.
- Use `git mv` for renames and archive moves.

## Status

- LOGBOOK adopted: 2026-08-19
- Index regenerated: manual
- Active feature count: see `LOGBOOK/features/INDEX.md`
