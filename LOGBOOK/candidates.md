# Candidates

<!--
Agent-surfaced candidates awaiting human triage. See LOGBOOK spec §12.
-->

## 2026-08-29

- The PHP SDK is not needed for the reason the Python one was. `example-notes` calls `currentUser()` once per request and holds its PDO and its settings in `static`, so PHP-FPM already reuses them per worker: the connection-per-request and DDL-per-request costs the Python SDK exists to remove were a consequence of the Python modules being written per request, not of hand-rolling the contract. An SDK for PHP is still worth having as a convenience, and should be written when a PHP module wants something it does not have rather than to match a count. (trigger: alternative, source: feat-php-sdk investigation 2026-08-29, agent: claude-code)
- The certificate is reissued by hand. The reconciler names the served domains it does not cover and the exact command, but adding a domain still needs somebody to run `bin/generate-certs` and reload the Router. Automating it means the Orchestrator holding the CA key, which is a larger decision than the convenience. (trigger: gap, source: feat-domain-gaps Outcome 2026-08-29, agent: claude-code)

## 2026-08-22

- The smokes keep working files at fixed paths in /tmp, so two users running them on one box collide: a root run leaves root owned files and the next run by a person cannot overwrite them, which reports as a failure in the thing being tested. Removed as a live problem by running the nightly sweep as the checkout owner and refusing root, but fourteen scripts still share the hazard and `mktemp` would end it. (trigger: gap, source: feat-resource-limits decision 2026-08-22, agent: claude-code)
- Presigned uploads, so a large file never transits the Storage service on the way in either. The read path no longer carries bytes; the write path still does. The obstacle is that quota is checked while the bytes are in flight, so a presigned PUT needs a declared size at mint time and a confirmation afterwards, which is the same trust the current check already places in `Content-Length`. (trigger: out-of-scope, source: feat-public-media Intent 2026-08-22, agent: claude-code)
- A full review of bottlenecks and proposed next major changes is in `docs/review-2026-08-22.md`: the box hardware, buffered byte paths, the per-request DDL pattern in reference modules, drift as a class, the flat admin token, development mode, and a proposal to make reconciliation the installation model. (trigger: review, source: project review 2026-08-22, agent: claude-code)

## 2026-08-19

- A second `mobile-builder` replica. The claim query is already `FOR UPDATE SKIP LOCKED`, so two workers need no coordination, but nothing scales itself: it is a compose change plus a decision about how many builds a box should run at once. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- iOS binaries, through a macOS runner or EAS Build. The builder produces the configured Xcode project today, which is what either of those takes as input. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- Over the air updates for a phone app that is already installed, and store submission. Both are a different mechanism from producing an artifact. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- Reviewing a module's native code at install. Approving a native screen means running a third party's JavaScript inside the app binary, and the review screen currently shows what it asks for rather than what it is. (trigger: gap, source: feat-mobile-apps composition decision 2026-08-19, agent: claude-code)
- `bin/smoke-quotas` does not clean up after itself. Every run leaves objects in the same bucket on the same domain, so the domain pool it caps at 2 MB fills over time and step 7, which expects a write to succeed once the bucket is raised, starts failing on the domain instead. The smoke reports a real refusal for the wrong reason. (trigger: gap, source: feat-domain-storage-limits verification 2026-08-19, agent: claude-code)
- Evaluate Podman as a second engine driver backend, for rootless isolation of untrusted third-party modules. (trigger: alternative, source: LOGBOOK bootstrap engine decision 2026-08-19, agent: claude-code)
- Server-side fragment composition, where modules expose fragments the Base App renders into its own layout, as a path to a more seamless product feel than iframes allow. (trigger: alternative, source: LOGBOOK bootstrap composition decision 2026-08-19, agent: claude-code)
- Reverse-proxy composition through the Router as a fallback for modules whose UI cannot sit in an iframe. (trigger: alternative, source: LOGBOOK bootstrap composition decision 2026-08-19, agent: claude-code)
- Extract shared core code from lib/ into versioned gems if a core service ever needs to pin an older version. (trigger: alternative, source: LOGBOOK bootstrap shared-code decision 2026-08-19, agent: claude-code)
- Database service provisioning and credential minting for the (module, domain) pair. (trigger: out-of-scope, source: feat-monorepo-skeleton Intent, agent: claude-code)
- Auth service flows: OAuth, JWT, 2FA. (trigger: out-of-scope, source: feat-monorepo-skeleton Intent, agent: claude-code)
- Per-language module SDKs for ruby, php, python, and node. (trigger: out-of-scope, source: feat-monorepo-skeleton Intent, agent: claude-code)
- Module install, update, and removal in the Backoffice UI. (trigger: out-of-scope, source: feat-monorepo-skeleton Intent, agent: claude-code)
- Capability auto-discovery and workflow composition across modules. (trigger: out-of-scope, source: feat-monorepo-skeleton Intent, agent: claude-code)
- Serve public storage objects through a CDN rather than through the Router. (trigger: out-of-scope, source: feat-core-storage Intent, agent: claude-code)
- Direct-to-storage uploads via pre-signed URLs, for large files that should not transit the Storage service. (trigger: out-of-scope, source: feat-core-storage Intent, agent: claude-code)
- Multi-node Garage layout and replication tuning for production. (trigger: out-of-scope, source: feat-core-storage Intent, agent: claude-code)
- SeaweedFS as an alternative object store backend if Garage's feature gaps bite. (trigger: alternative, source: feat-core-storage backing store decision 2026-08-19, agent: claude-code)
