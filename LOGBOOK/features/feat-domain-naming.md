---
status: shipped
branch: feat-domain-naming
---

# The Backoffice at core.<domain>, and hosts entries that generate themselves

## Intent

Chrome resolves anything under `.localhost` to 127.0.0.1 itself and never asks
a resolver, so no hosts entry can point such a name at the box the stack runs
on. The stack had already moved to `siberian.test` for that reason, but
`bin/setup` and the compose file still defaulted to `siberian.localhost`, which
walks a fresh machine straight back into it, and two smokes still addressed
hostnames nothing serves.

The Backoffice also wanted a name that says what it is. `admin.<domain>` becomes
`core.<domain>`.

Out of scope for this feature:

- A Backoffice on a domain of its own. The session cookie is scoped to
  `.<domain>`; anything outside that scope needs a login of its own.
- Core server blocks for a second served domain. The Router renders one copy
  from `SIBERIAN_DOMAIN`, so a second domain gets module routes and no shell.
- Wildcard DNS. The hosts file is generated now, not eliminated.

## Plan

1. ~~`admin.<domain>` becomes `core.<domain>`, in the Router and everywhere that addressed it.~~
2. ~~`bin/setup` and compose default to `siberian.test` rather than `siberian.localhost`.~~
3. ~~`smoke-auth` and `smoke-storage` take the domain from the environment.~~
4. ~~`bin/generate-certs` takes a list of domains for one SAN list.~~
5. ~~`bin/hosts-file` prints the block from the domains and modules installed.~~

## Decisions

### 2026-08-19

- **Decision:** the Backoffice is `core.<domain>`, a label under the served domain, rather than a domain of its own such as `siberian.core`.
- **Why:** Auth sets the session cookie on `.<domain>` so that it reaches module frames. A Backoffice outside that scope receives no cookie at all and would need its own login, or a cross-domain token handoff. That is a redesign of Backoffice authentication, not a rename.
- **Impact:** one line in the Router template and one prefix in `login_url_for`. The wildcard certificate already covered it, because `*.<domain>` matches one label.

- **Decision:** development domains stay under `.test`.
- **Why:** RFC 6761 reserves `.test` for exactly this and no registry can ever delegate it. `.default`, `.core`, and the rest are unreserved, so a dev box on them is one ICANN round away from colliding with real DNS, and the failure would look like a broken network rather than a naming choice.
- **Impact:** a second tenant is a second name under `.test`, for example `siberian-second.test`, which is its own registrable domain and therefore its own cookie scope.

- **Decision:** the hosts block is generated from the database rather than written into the docs.
- **Why:** it changes with every module installed and every domain added, and a list in a document that changes on install is a list that is wrong most of the time.
- **Impact:** `bin/hosts-file` asks the Orchestrator what is served and what is installed. It names a `.localhost` domain as skipped, with the reason, instead of printing a line that cannot take effect.

## Outcome

Shipped 2026-08-19. The Backoffice answers on `core.siberian.test`, `smoke-auth`
now checks the thing this rename could have broken (the cookie issued on the
product domain still opens the Backoffice), and `bin/hosts-file` prints the
block.

Two things surfaced on the way. Recreating the Router does not re-render its
config: the core template is baked into the image, so `--force-recreate`
without `--build` served the previous config and `core.siberian.test` fell
through to the default server, which answered as the product shell rather than
404. And a second served domain still has no core server block of its own,
raised in `LOGBOOK/candidates.md`.
