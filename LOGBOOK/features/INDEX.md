# Feature index

_Generated: 2026-08-30, by hand. Thirty two features, all shipped._

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
| [CMS module](feat-cms-module.md) | Pages from blocks, rendered in the browser and natively from one description | `bin/smoke-cms` |
| [Push notifications](feat-push-module.md) | An inbox with read, archive and delete, and the first module to require a native capability | `bin/smoke-push` |
| [App themes](feat-app-themes.md) | Three palettes the app carries and picks at render time, adopted by a module inside a WebView | `bin/smoke-mobile`, `bin/smoke-demo` |
| [App users](feat-app-users.md) | The person an app is for: one account, many devices, one domain, no way into the Backoffice | `bin/smoke-app-users` |
| [Account recovery](feat-account-recovery.md) | A reset link by email, the first mail the core sends, and a throttle on both public doors | `bin/smoke-account-recovery` |
| [Test isolation](fix-test-isolation.md) | Suites against their own database, mobile in CI, seven smokes that can now fail, and the JSX parsed | `bin/test-service`, `bin/check-native` |
| [Honest manifest](feat-honest-manifest.md) | Install probes what a module declared, and refuses one that does not serve it | `bin/smoke-honest-manifest` |
| [Accounts finished](feat-accounts-finished.md) | A reset for core accounts too, email verification, and an operator's last resort | `bin/smoke-core-recovery` |
| [Operator visibility](feat-operator-visibility.md) | The mail queue and audit trail have pages, and a failing sweep says so everywhere | `bin/smoke-visibility` |
| [Alerts](feat-alerts.md) | Fire once, clear once, silent in between, and only for things somebody can act on | `bin/smoke-alerts` |
| [Builder CPU cap](feat-builder-cap.md) | Measured on both sides: 27% faster builds against 25% slower pages | `build_attempts.duration_ms` |
| [Module upgrade](feat-module-upgrade.md) | One action, data kept, and the working version put back when the new one fails | `bin/smoke-module-upgrade` |
| [Product surface](feat-product-surface.md) | The app follows the phone's light or dark setting, the theme contract is written down, and the phone can attach a file | `bin/smoke-appearance` |
| [App preview](feat-app-preview.md) | The app rendered through React Native for Web in a phone-shaped panel, and a shell with a bottom bar | `bin/smoke-mobile` |
| [Owner app view](feat-owner-app-view.md) | The app owner sees their own builds, their place in line, and the app running, on the domain they built it for | `bin/smoke-owner-app` |
| [Build lanes](feat-build-lanes.md) | Previews get a worker of their own: about a minute whether or not an Android build is running, down from about twenty | `bin/smoke-owner-app` |
| [Base App tests](feat-base-tests.md) | The product side gets a suite: stand-ins for the three services it is a view onto, and the domain invariant asserted | `bin/test-service base` |
| [Stable subject](feat-stable-subject.md) | Modules key rows by a name the core issues, not by an email address: it survives a change of address and is never handed on | `bin/smoke-identity` |

## Abandoned

None.

## What is not built

Listed at the end of [`docs/running-the-stack.md`](../../docs/running-the-stack.md),
where somebody picking this up will actually look for it.
