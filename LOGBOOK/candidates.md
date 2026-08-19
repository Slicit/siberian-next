# Candidates

<!--
Agent-surfaced candidates awaiting human triage. See LOGBOOK spec §12.
-->

## 2026-08-19

- Nothing re-registers a module with a core service that did not exist when the module was installed. example-notes and example-relay are absent from every phone app because they were installed before the Mobile service, and only a reinstall tells it they exist. `RouteReconciler` solves the same class of problem for routing; service registrations have no equivalent. (trigger: gap, source: feat-mobile-apps verification 2026-08-19, agent: claude-code)
- A second `mobile-builder` replica. The claim query is already `FOR UPDATE SKIP LOCKED`, so two workers need no coordination, but nothing scales itself: it is a compose change plus a decision about how many builds a box should run at once. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- iOS binaries, through a macOS runner or EAS Build. The builder produces the configured Xcode project today, which is what either of those takes as input. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- Over the air updates for a phone app that is already installed, and store submission. Both are a different mechanism from producing an artifact. (trigger: out-of-scope, source: feat-mobile-apps Intent 2026-08-19, agent: claude-code)
- Reviewing a module's native code at install. Approving a native screen means running a third party's JavaScript inside the app binary, and the review screen currently shows what it asks for rather than what it is. (trigger: gap, source: feat-mobile-apps composition decision 2026-08-19, agent: claude-code)
- The Router renders core server blocks from a single `SIBERIAN_DOMAIN`, so a second served domain gets module routes from the reconciler and no server block for the product shell or the Backoffice. Its requests fall through to the default server, which answers as the first domain. Rendering the core template per domain would move ownership of that file to the Orchestrator, which is the decision. (trigger: gap, source: feat-domain-naming Intent 2026-08-19, agent: claude-code)
- `Role.seed_defaults!` skips a role that already exists, so a permission added to the catalogue later never reaches an installation that has already been seeded. `core.storage.manage` shipped with storage quotas and no seeded operator role held it. Deciding this is not obvious: re-seeding would overwrite a role an operator has edited, which is exactly what the current guard protects. (trigger: gap, source: feat-domain-storage-limits Outcome 2026-08-19, agent: claude-code)
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
