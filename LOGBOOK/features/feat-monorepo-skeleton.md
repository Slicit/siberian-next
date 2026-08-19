---
status: active
branch: feat-monorepo-skeleton
---

# Monorepo skeleton

## Intent

Give the project a shape before it has code, so the first real service lands in
a repository whose directories already match the architecture rather than one
someone reorganizes later. The skeleton also has to make the engine abstraction
and the module contract concrete on day one: both are the kind of constraint
that survives only if something in the repository enforces them.

Out of scope for this feature:

- The Database service provisioning and credential minting logic.
- The Auth service flows (OAuth, JWT, 2FA).
- The per-language SDKs. The directories exist; the clients do not.
- Module install, update, and removal in the Backoffice UI.
- Capability auto-discovery and workflow composition.

## Plan

1. ~~Create the monorepo tree: `core/`, `lib/`, `sdk/`, `modules/`, `deploy/`, `bin/`, `docs/`.~~
2. ~~Define the module manifest contract as a JSON Schema, covering containers, routes, permissions, capabilities.~~
3. ~~Write a reference module that exercises the contract.~~
4. ~~Define the engine driver interface and the engine-neutral container spec.~~
5. ~~Add a check that fails if anything outside the driver names a container engine.~~
6. ~~Write the Router config: core origins, per-module origins, frame-ancestors policy.~~
7. ~~Write the development stack: compose, shared Rails Dockerfile, core SQL init.~~
8. ~~Write the development entry points: `bin/setup`, `bin/up`, `bin/new-rails-app`, `bin/check`.~~
9. ~~Install a container engine on the development machine.~~
10. ~~Generate the core Rails services.~~ Five, not four: Storage joined the core.
11. ~~Implement the Docker driver against a live daemon, with tests.~~
12. ~~Wire `bin/check` into CI.~~

## Decisions

### 2026-08-19

- **Decision:** the container engine sits behind `Siberian::Engine::Driver`, with Docker as the first backend.
- **Why:** Kubernetes is wanted later, and an abstraction retrofitted after the Orchestrator is written never actually lands. Podman was considered and parked as a candidate.
- **Impact:** `lib/siberian_engine/`. `ContainerSpec` is deliberately expressible under both engines, which is why it carries no run flags or compose keys.

- **Decision:** `bin/check-engine-leak` fails the build if `core/` or `lib/` names an engine outside the driver.
- **Why:** an architectural constraint with nothing enforcing it degrades into a comment. This one costs a grep.
- **Impact:** it immediately caught a real leak: the Router hardcoded `127.0.0.11`, which is the Docker embedded DNS address and would be wrong under Kubernetes. The resolver address is now rendered from `SIBERIAN_RESOLVER`.

- **Decision:** shared Ruby lives in `lib/`, not in extracted gems.
- **Why:** the isolation that matters is core against modules; internal core boundaries do not need packaging ceremony.
- **Impact:** core images build with the repository root as build context so `lib/` can be copied in. `deploy/rails.Dockerfile` takes the service as a build arg rather than being duplicated four times.

- **Decision:** the Base App wraps module UIs in iframes, and each module is served from its own origin at `<module>.apps.<domain>`.
- **Why:** iframes give isolation of styles and of intent. A same-origin frame gives neither a security boundary nor a usable CSP, and modules are third-party code. Scoping the auth cookie to the parent domain keeps out-of-the-box auth working across frames. Wildcard DNS and certificates were already a requirement of multi-domain.
- **Impact:** `core/router/nginx/templates/`. Module responses carry `frame-ancestors` naming only the parent domain; the Backoffice carries `frame-ancestors 'none'` and is never framed by anything.

- **Decision:** isolate data, not runners. Containers are installed once and shared across domains; databases are per domain.
- **Why:** duplicating a container set per domain multiplies resource cost by domain count for isolation that belongs in the data layer.
- **Impact:** manifest database grants carry `scope: per_domain` by default. The domain travels as `X-Siberian-Domain` from the Router, and the Database service mints credentials against the `(module, domain)` pair.

- **Decision:** Ruby is not a host prerequisite. The Rails services are generated and run in containers via `bin/new-rails-app`.
- **Why:** the development machine has no Ruby and no container engine, and a project whose runtime is containers should not need a parallel host toolchain.
- **Impact:** `bin/setup` checks for the engine only, and says so explicitly when it is missing.

## Links

- Branch: `feat-monorepo-skeleton`
- PR: TBD
- Related ideas: none
- Related features: none
- External: none
