# Feature index

_Generated: 2026-08-20, by hand. Fourteen features, all shipped._

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
| [Domain naming](feat-domain-naming.md) | The Backoffice at core.<domain>, off .localhost for good, generated hosts entries | `bin/smoke-auth`, `bin/hosts-file` |
| [Phone apps](feat-mobile-apps.md) | One React Native app per domain, native capabilities an operator caps, and a build queue | `bin/smoke-mobile` |
| [App studio](feat-app-studio.md) | The phone app configured from the product side, from a description | `bin/smoke-mobile` |
| [Splash](feat-splash.md) | Custom splash artwork, centred with a stated safe zone, and an animated one on Android | `bin/smoke-mobile` |
| [Interface polish](feat-interface-polish.md) | A menu built from data and tested against the controllers, breadcrumbs, a confirm dialog, and actions that read as what they do | `bin/test-lib`, `bin/smoke-backoffice` |
| [Housekeeping](feat-housekeeping.md) | The builder cleans up after itself, and the box prunes nightly | `deploy/maintenance/housekeeping.sh` |

## Abandoned

None.

## What is not built

Listed at the end of [`docs/running-the-stack.md`](../../docs/running-the-stack.md),
where somebody picking this up will actually look for it.
