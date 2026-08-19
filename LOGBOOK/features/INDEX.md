# Feature index

_Generated: 2026-08-19, by hand. Eight features, all shipped._

## Active

None. The beta is in, and the next thing has not been picked.

## Draft

None.

## Recently shipped (last 90 days)

| Feature | What it delivered | Verify with |
|---|---|---|
| [Monorepo skeleton](feat-monorepo-skeleton.md) | The layout, the module contract, the engine driver, CI | `bin/check`, `bin/test-engine` |
| [Core Storage](feat-core-storage.md) | Four HTTP verbs over Garage, per (module, domain) buckets | `bin/smoke-storage` |
| [Core services](feat-core-services.md) | Auth, Database, and the system/feature capability split | `bin/smoke-auth` |
| [Interfaces](feat-interfaces.md) | Backoffice, Base App, two reference modules, local TLS | `bin/smoke-backoffice`, `bin/smoke-modules` |
| [Access control](feat-access-control.md) | Roles, grants, deny, and user management on both sides | `bin/smoke-access` |
| [Mail queue](feat-mail-queue.md) | Queue, acknowledgement, retry, and a door into modules | `bin/smoke-mail` |
| [Storage quotas](feat-storage-quotas.md) | Per bucket, per domain, and the default that caps a manifest | `bin/smoke-quotas` |
| [Domain storage limits](feat-domain-storage-limits.md) | An allowance set where a domain is added, before anything is stored | `bin/smoke-domains` |

## Abandoned

None.

## What is not built

Listed at the end of [`docs/running-the-stack.md`](../../docs/running-the-stack.md),
where somebody picking this up will actually look for it.
