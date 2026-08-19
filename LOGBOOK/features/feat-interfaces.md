---
status: shipped
branch: main
---

# Backoffice, Base App, reference modules, and local TLS

## Intent

Everything before this was verifiable only by curl. This is the part a person
can open: an operator-facing Backoffice that installs modules, a product shell
that renders them, and two reference modules that actually work.

Out of scope for this feature:

- A module marketplace. The catalogue is a directory.
- Wildcard DNS for development. Hosts entries are the current answer, and they
  do not scale past a handful of modules.
- Any Backoffice view of the Database audit trail.

## Plan

1. ~~Backoffice: overview, modules, catalogue, domains, interfaces, activity.~~
2. ~~Install behind a permission review an operator has to approve.~~
3. ~~Base App: a shell that reads capabilities and frames modules.~~
4. ~~Local CA and wildcard certificate, HTTPS everywhere.~~
5. ~~A working PHP module with markdown CRUD.~~
6. ~~A working Python module with archive, delete, and attachments.~~
7. dnsmasq so module origins resolve without a hosts entry each.
8. A module SDK for at least one language, so the HTTP calls stop being hand-rolled.

## Decisions

### 2026-08-19

- **Decision:** installing is two steps, and the second one is inert until an operator ticks a box.
- **Why:** the permissions a module asks for are the whole security model, and an operator who never sees them has not approved anything. The review screen ranks them by severity and shows the tables and the stated reason for any cross-database grant.
- **Impact:** `core/orchestrator/app/controllers/catalog_controller.rb`. Conflicts are shown before installing rather than raised during it: an operator can act on "the mail transport is already claimed", but a half-finished install is only cleanup.

- **Decision:** the Base App learns a title, an area, and a URL, and nothing else.
- **Why:** if the shell knew a container name or a uuid, installing a module would mean changing the shell. It does not, and that is the whole test of the design.
- **Impact:** a capability declaring an area the shell does not recognise appears under More rather than vanishing, and a slow Orchestrator produces an empty sidebar rather than a page that will not render.

- **Decision:** development runs over HTTPS behind a local CA, on a `.test` domain.
- **Why:** two independent reasons. Browsers hardcode `.localhost` to 127.0.0.1, so a development domain there can never point at another machine. And the session cookie must be `Secure` to reach a module frame on another origin, so plain HTTP is not a simpler version of the product, it is a broken one.
- **Impact:** `bin/generate-certs`. Certificates match one label at a time, so `*.siberian.test` does not cover `tasks.apps.siberian.test`; both are in the SAN list, which is the kind of thing discovered at 2am rather than read in a spec.

- **Decision:** the two reference modules are PHP and Python, not Ruby.
- **Why:** "modules can be written in any language" is a claim until two of them are, in languages the core is not. Their dependencies are a web framework, a database driver, and a server. Nothing that knows Siberian exists.
- **Impact:** `modules/example-notes` (PHP, markdown CRUD), `modules/demo-tasks` (Python, archive and delete). `bin/build-module` builds locally, and the Orchestrator installs a present image without pulling, which is what makes a module developable without a registry.

- **Decision:** destructive actions confirm on a page, not with a JavaScript dialog.
- **Why:** modules render inside a frame, and a dialog a frame throws at you is easy to miss and impossible to test. A page says what will happen and works with scripting off. Task deletion also offers "archive instead", which is usually what somebody actually wants.
- **Impact:** both modules. Deleting a task takes its attachment out of storage with it: a module that deletes rows and leaves files behind quietly bills its owner for storage nothing can reach.

- **Decision:** markdown renders with HTML input escaped and unsafe links off.
- **Why:** a note is text a person typed and the module renders it back to them. A markdown field that renders raw HTML is a cross-site scripting hole with a nice name.
- **Impact:** asserted in `bin/smoke-modules.sh` rather than left as a comment.

## Links

- Branch: `main`
- PR: none, merged directly to main
- Shipped: 2026-08-19
- Related features: `feat-core-services`
- Verify with: `bin/smoke-backoffice`, `bin/smoke-modules`
