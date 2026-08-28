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
- **Mailer**: a queue rather than a send call. A module hands over a message and stops thinking about it; the queue retries with backoff, gives up into a dead state rather than looping, and keeps reporting every terminal outcome until the module acknowledges it. Delivery resolves `mail.transport.v1` per attempt, so installing a transport module drains a queue that is already backed up.
- **Database**: provisions one database and one Postgres role per `(module, domain)` pair and hands the module a DSN. The module then connects to Postgres directly: nothing sits in the hot path of a module reading its own data, because Postgres roles already are the isolation. Module data lives on its own cluster, separate from the one holding auth, orchestrator, and configuration. Reading a table the module does not own works the other way round, and deliberately so: those reads go through the service, table by table against grants an operator approved with a stated reason, and every one lands in the audit trail. A direct connection would be unobservable, which is what an audit trail cannot afford.
- **Storage**: a facade over an S3 compatible object store, with two faces that exist for different reasons.

  Inward, it is file storage for every module over a plain HTTP API (`GET`, `HEAD`, `PUT`, `DELETE` on `/v1/{space}/{path}`). Modules never see S3, never hold an object store credential, and never need an S3 SDK. One protocol, whatever the object store underneath turns out to be. Spaces are `files`, `tmp`, and `public`. One bucket per `(module, domain)` pair, same isolation rule as the Database service. Quotas apply at three levels an operator sets: a default that caps what a manifest can ask for, one per bucket, and one per domain shared by every module bucket on it. A new bucket gets the smaller of what its manifest asked for and the operator default, because a manifest is written by a third party and asking for more should not be enough to get more.

  Outward, public objects are addressed by S3 compatible URIs and fetched from the object store directly. Storage signs a URL and answers with a redirect; it does not carry the bytes. This is deliberate and it is not only about speed: a presigned URL is the same mechanism against Garage, AWS S3, or OVH, so the backend is a deployment choice rather than a rewrite. Self hosted on one box today, a managed bucket when there is a reason to scale, and nothing above the facade changes either way.

  The credential stays on one side of that. Storage holds it and signs with it; a signed URL grants one object for a limited time and nothing else in the bucket.

**Third-party modules**: any number of containers per module (for example a Redis, a php-fpm runner, and a small Nginx to serve the app). Install registers the module, mounts its files, and assigns a UUID. Every container of that module is prefixed: `<uuid>-<module_name>-<service>`.

**Language independence**: a module can be written in anything that runs in a container (PHP, Python, Rails, React, and the rest). Integration happens over the internal API, never through a shared runtime. This is the payoff of the container boundary.

**SDKs**: the core ships first-party client SDKs for the common module languages, so a module author talks to the internal APIs and to other modules without hand-rolling HTTP.

**Capabilities**, in two kinds, because they extend different things:

- **System capabilities** extend the core. One implements a named interface the core already calls (`mail.transport.v1`, `auth.provider.v1`), so mail or authentication can be answered by a module instead of by the built-in service. No UI, no area; the core reaches it over the internal network and never learns which module answered. Two modules claiming one interface exclusively is an install-time conflict for an operator to resolve, not a silent decision about where the core sends mail.
- **Feature capabilities** extend the product. A page or fragment the Base App lists in a named area. The shell asks for a title, an area, and a URL, and never learns a container name, a uuid, or a network, which is why installing a module requires no change to it.

A module's `consumes` is matched against both kinds. An unmatched request is not an error; it is a feature that stays switched off.

**Composition**: the Base App wraps module UIs in iframes. That buys real isolation of styles and of intent. Each module is served from its own origin (`<module>.apps.<domain>`) so the frame boundary is enforced by the browser and not by convention, which matters because modules are third-party code. The auth cookie is scoped to the parent domain, so out-of-the-box auth still covers every frame and the usual iframe auth friction does not apply.

**TLS is not a production-only concern.** The session cookie must be `Secure` to travel into a module frame on another origin, so development runs over HTTPS too, behind a local CA. Wildcard DNS and a wildcard certificate are a baseline requirement of the product, and certificates match one label at a time: `*.<domain>` does not cover `<module>.apps.<domain>`, so both are always in the SAN list.

**The internal door**: a module sits on its own network with only the Router attached, so it has no route to the core at all. It reaches the core at `http://core/auth/...`, `http://core/storage/...`, `http://core/database/...`, where `core` is an alias the Router answers to on every module network it joins. That is what makes "module traffic goes through the Router" true by construction rather than by convention.

**Multi-domain**: the system serves multiple domains. Isolation is at the data layer, not the runtime layer: containers are installed once and shared across domains, while databases are per domain. The Database service mints credentials scoped to the `(module, domain)` pair, the Router and Auth propagate the current domain as request context, and the SDKs resolve the right credential so module authors never handle it by hand.

**Engine abstraction**: the container engine sits behind a driver interface. Docker is the first backend; Kubernetes or an equivalent comes later without rewriting the Orchestrator. This is a deliberate architectural constraint, not a convenience layer.

## Stack

- Ruby on Rails 8.1 for all six core services. The Orchestrator, Base App, and Auth serve HTML; the Mailer, Storage, and Database are API only
- Nginx for the Router, terminating TLS and holding the only certificate
- PostgreSQL twice over: a configuration cluster for the core's own databases, and a separate module data cluster modules connect to directly
- Object storage behind a driver, the same way the container engine is: `lib/object_store`, chosen by `SIBERIAN_OBJECT_STORE`, with Garage self hosted as the default and S3 for AWS or anything that speaks its API. Only the control plane is behind it, because reading and writing objects is the S3 protocol and every backend already speaks that. Garage is the only container holding objects, and the only credential for it belongs to the Storage service. The Router joins that network to forward already signed requests at `s3.<domain>`: it holds no credential and can sign nothing, so it reaches the object store without being able to read it. `bin/check-storage-leak` fails the build if anything outside the driver names a backend
- Container engine behind a driver interface: Docker first, Kubernetes or equivalent later
- Modules in any language. The two reference modules are PHP and Python
- Monorepo: every core service, shared library, SDK, and reference module lives in this repository

## Repo layout

```
core/            one directory per core container, each with its own Dockerfile
lib/             shared Ruby for the core apps
  siberian_engine/  the engine driver, the only code that knows Docker exists
  contracts/        the module manifest schema and its parser
  router/           the per-module nginx template the Orchestrator renders
  ui/               one stylesheet the three core interfaces share
sdk/             per-language module SDKs (ruby, php, python, node)
modules/         reference modules that exercise the contract, in several languages
deploy/          compose for development, Kubernetes manifests later
  certs/            local CA and wildcard certificate, generated, never committed
bin/             development entry points and smoke checks
docs/
```

Every `bin/smoke-*` drives a real stack rather than a mock. They exist because
the failures worth catching here live in the seams between Rails, nginx,
Postgres, and the engine, and no unit test stands in that seam.

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
- **The object store is addressed as S3, never as Garage.** Garage is a deployment choice, the same way Docker is. A module talks to the Storage facade and a browser follows a presigned URL, and neither is a shape that only Garage can answer. Anything that would work against Garage and not against AWS or OVH belongs behind the facade or nowhere.
- **Storage signs; nothing else does.** The credential for the object store lives in the Storage service alone. The Router forwards signed requests and holds nothing, which is what lets it reach the object store without being able to read it.
- **Module to module traffic goes through the Router**, addressed by short internal DNS name. Never hardcode container IPs or ports.
- **Database access is brokered by the Database service.** No module holds a credential it was not granted at install or update time. Read-only is the default grant.
- **Reaching into a database somebody else owns is granted table by table, with a stated reason.** A grant with no table list is a request for everything, and an operator cannot meaningfully approve that. Every use of such a grant is audited, refusals included.
- **Development runs over HTTPS.** The session cookie must be `Secure` to reach a module frame, so plain HTTP is not a simpler version of the product, it is a broken one.
- **Modules address the core at `http://core/...`**, never a service name directly. They have no route to one.
- **Core services reach a module at `http://modules/<name>/...`**, for the same reason in reverse. The Router is the only container on both sides.
- **Access is resolved once per session and checked in memory.** Permissions are dotted strings with wildcards, resolved into a flat set when a session starts and invalidated by a version stamp on the user. A page may ask a dozen times without a query or a round trip. The cost is a stated ceiling: a withdrawn permission can survive up to 30 seconds, and anything that cannot tolerate that asks Auth for a fresh answer.
- **A hidden link is not access control.** Every page checks, not only the navigation that led to it.

## Non-goals

- **Not a WordPress-style in-process plugin system.** Modules never load code into the core. The isolation boundary is the container, not a language runtime.
- **The Orchestrator does not run module business logic.** It manages container lifecycle, registration, and wiring, nothing else.
- **The Backoffice is not the product shell.** The Orchestrator manages modules; it does not host their UI. Module interfaces are wrapped by the Base App, and the two stay separate applications.
- **The core does not constrain module language or framework.** If it runs in a container and speaks the internal API, it is a valid module.

## Reading order for agents

1. This file (`LOGBOOK.md`) for what the system is.
2. `docs/running-the-stack.md` for where it runs, how to bring it back, and how to check it works. Development happens on a Linux box rather than a laptop, and nothing else says so.
3. `LOGBOOK/notes.md` for codebase patterns, gotchas, anti-patterns. Several of those cost hours to find.
4. The active feature file matching the current branch (`LOGBOOK/features/feat-<slug>.md`) if any.
5. `LOGBOOK/features/INDEX.md` for the broader picture.

Do not read `LOGBOOK/ideas.md` unless the user explicitly asks; it is the human-owned inbox.

## Before changing anything

Ask what else the change touches, before making it. Every expensive hour in this
project so far has been a change that was correct on its own and wrong next to
something else.

- **What else reads or writes this?** A stylesheet, a shared client, a template,
  a volume, a generated file. `lib/` is loaded at boot by six services, and a
  volume outlives every image built after it.
- **What did the thing I removed also do?** Deleting build workspaces stopped
  the disk filling and made every build reinstall a thousand packages. Caching
  those packages fixed that and broke device builds, because the cache was
  written with absolute paths into a workspace the first fix deletes. Both were
  right alone.
- **Does something already cover the path I did not touch?** The regression
  above was found by `bin/smoke-mobile`, which queues an Android build, and not
  by any of the checking done on the preview that caused it.
- **Would this fail quietly?** A menu with one fewer entry, a splash that fell
  back to stock artwork, a smoke reporting on a page it never fetched. Prefer a
  change that fails loudly to one that degrades politely, and when a fallback is
  genuinely wanted, say in a comment why it is narrow.

Then run the whole sweep rather than the smoke for the thing you changed. It
costs a few minutes and it is the only part of this list that is not judgement.

## Writing guidance for agents

- Append to the current feature's `## Decisions` log when making non-trivial choices. Use today's date.
- Propose additions to `notes.md` when you discover a transferable pattern, gotcha, or anti-pattern. Show a diff and wait for confirmation.
- Never edit `LOGBOOK.md` (this file) without showing the proposed change first.
- Run `./bin/check` and the full smoke sweep before merging, not only the check for the thing that changed.
- Never modify `ideas.md` without an explicit user request.
- Use `git mv` for renames and archive moves.

## Status

- LOGBOOK adopted: 2026-08-19
- Index regenerated: 2026-08-19
- Last reviewed: 2026-08-19, after access control, the mail queue, and storage quotas. Architecture, Stack, Conventions, and Repo layout are checked against the tree rather than remembered.
- Feature count: see `LOGBOOK/features/INDEX.md`
