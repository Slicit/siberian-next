---
status: shipped
branch: main
---

# Core services: Auth, Database, and the capability split

## Intent

Three things the module contract could not work without: a way for a module to
know who is looking at it, a way for it to store data that is its own, and a
way for a module to extend the core rather than only the product. All three
were specified in `LOGBOOK.md` before any of them existed.

Out of scope for this feature:

- The Mailer beyond a generated Rails app and a health endpoint.
- OAuth and 2FA. Auth ships password sessions only.
- Kubernetes as an engine backend.

## Plan

1. ~~Auth: users, revocable sessions, one login screen, an internal endpoint everything else asks.~~
2. ~~An internal door so modules can reach the core at all.~~
3. ~~Split capabilities into system and feature kinds, enforced rather than documented.~~
4. ~~InterfaceRegistry: who implements a core interface, best first.~~
5. ~~Database: provision a database and role per (module, domain), hand over a DSN.~~
6. ~~Audited, table-by-table reads of databases a module does not own.~~
7. ~~Wire both into the install flow so a module arrives with its credentials.~~
8. Rotation on a schedule rather than only on request.
9. A Backoffice view of the audit trail.

## Decisions

### 2026-08-19

- **Decision:** sessions are opaque and revocable, not signed claims.
- **Why:** a session that cannot be revoked is a bearer grant with an expiry, and revoking one is the first thing anyone asks for. Only the digest is stored.
- **Impact:** `core/auth`. The cookie is scoped to `.<domain>` so every module frame carries it, which is what lets a module identify a user without implementing a login.

- **Decision:** capabilities come in two kinds, and the distinction is enforced.
- **Why:** a module extends two different things, and conflating them made the manifest lie about both. A system capability declaring an area is rejected; a feature capability declaring an interface is rejected.
- **Impact:** `lib/contracts/manifest.rb`, the `capabilities` table, `InterfaceRegistry`. Two modules claiming one interface exclusively is an install-time conflict an operator resolves, not a silent decision about where the core sends mail.

- **Decision:** the core's own service is the last resort for an interface, not the first choice.
- **Why:** installing a module that implements `mail.transport.v1` should route mail through it. A module that wants to sit behind the core can say so with a priority above 1000.
- **Impact:** a module that stops being live stops receiving the core's work immediately, which the suite pins.

- **Decision:** modules connect to Postgres directly with issued credentials, but read other people's tables through the service.
- **Why:** nothing should sit in the hot path of a module reading its own data, because Postgres roles already are the isolation. The opposite is true for somebody else's data: a direct connection is unobservable, and an audit trail is the entire point of that grant existing.
- **Impact:** `core/database`. There is no SQL parameter anywhere in the module-facing API: a module names a table it was granted and gets rows, so it cannot express a query that escapes the grant.

- **Decision:** module data lives on a separate Postgres cluster from the core's own databases.
- **Why:** auth, orchestrator, and configuration must not sit on an instance modules can reach at all.
- **Impact:** `moduledb` in compose, joined to each module network under the alias `db` at install time.

- **Decision:** removing a module locks its credentials out and keeps its data.
- **Why:** revoking an identity is not the same as destroying what it wrote, and only an operator decides the second.
- **Impact:** roles go `NOLOGIN`, buckets survive. This produced the sharpest bug of the beta, recorded in `notes.md`: Postgres reports a `NOLOGIN` role as "password authentication failed", so reinstalling handed back correct credentials that could not log in and the symptom pointed at the password.

## Links

- Branch: `main`
- PR: none, merged directly to main
- Shipped: 2026-08-19
- Related features: `feat-monorepo-skeleton`, `feat-core-storage`, `feat-interfaces`
- Verify with: `bin/smoke-auth`, `bin/smoke-storage`
