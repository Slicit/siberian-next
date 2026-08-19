---
status: shipped
branch: feat-access-control
---

# User management and access control

## Intent

Right now there is exactly one distinction in the system: `operator` is a
boolean on a user, and it decides whether the Backoffice lets you in. That is
not an access model, it is a door with one key, and every question anyone will
actually ask ("can this person install modules but not remove them", "can they
see Tasks but not Notes") has no place to be answered.

Both interfaces need user management, for different populations. The Backoffice
manages operators and the permissions that run the system. The Base App manages
the people who use the product and what they can reach inside it. One account
across both, because that is what the core promised.

Out of scope for this feature:

- Invitations and email flows. The Mailer is still a health endpoint.
- Per-record authorization inside a module. A module owns its own rows; the core
  says which module a person may open, not which invoice.
- OAuth, SSO, and 2FA.

## Plan

1. ~~Permission vocabulary and matching rules.~~
2. ~~Roles, direct grants, and deny.~~
3. ~~Resolution into a flat set, stored with the session.~~
4. ~~Version stamping so a change invalidates without a broadcast.~~
5. ~~Shared checking code, so both interfaces answer identically.~~
6. ~~Auth admin API for users, roles, and grants.~~
7. ~~Backoffice: people, roles, and who can do what.~~
8. ~~Base App: product-side people and module access.~~
9. ~~Tests, and a smoke that proves a revoked permission actually stops working.~~

## Decisions

### 2026-08-19

- **Decision:** permissions are dotted strings with wildcard grants, not a table of booleans.
- **Why:** a boolean per capability needs a migration every time the system grows a verb, and the set of verbs is not knowable in advance when third parties add features. Strings with `module.<name>.use` in the same namespace as `core.users.write` let a module's arrival extend the vocabulary without touching the schema.
- **Impact:** matching rules have to be written down precisely, because a permission system nobody can predict is worse than a coarse one. `*` matches exactly one segment, except as the final segment where it matches the rest.

- **Decision:** resolve permissions once per session and store the flat set on the session row.
- **Why:** this is the whole performance question. Fine-grained authorization means many checks: a sidebar with twelve capabilities asks twelve questions before it renders. If each is a join, the model is unusable; if each is a network call, it is absurd. Resolving once turns every later check into a set lookup.
- **Impact:** `/internal/session` returns the user and the resolved set in one row read, no joins. Checking is O(1) in memory in every consumer.

- **Decision:** invalidate by version stamp rather than by hunting down sessions.
- **Why:** a resolved set is a cache, and the hard part of a cache is knowing when it is wrong. A counter on the user, copied onto the session at resolution time, makes staleness a comparison rather than a broadcast: changing a role bumps the counter and every session built before it re-resolves on next use.
- **Impact:** revocation takes effect on the next session validation rather than instantly across a cluster. Consumers cache for 30 seconds, so the honest ceiling is that a withdrawn permission can survive half a minute. That is the trade, stated rather than hidden, and security-critical actions can ask for a fresh check.

- **Decision:** deny beats allow, always.
- **Why:** the useful real-world shape is "an operator, except for this one thing", and expressing that by carefully not granting something is fragile: the next role that grants it silently undoes the intent.
- **Impact:** an explicit deny cannot be overridden by any role, which also means it cannot be accidentally granted back.

## Outcome

Shipped 2026-08-19. The measured shape is what was designed: validating a
session is one row read, every later check is a set lookup, and a page asking a
dozen times costs nothing extra.

One bug worth remembering came out of it, and it was not in the model. Rails
deduplicates commit callbacks by filter name, so 
followed by  registers one callback rather than two.
Editing a role therefore invalidated nobody, silently, and the callback list
looked correct.

The Backoffice overview was also readable by anybody signed in, which the
per-controller declarations missed because the dashboard declared nothing. Both
are covered now.

## Links

- Branch: `feat-access-control`
- PR: none, merged to main
- Shipped: 2026-08-19
- Verify with: `bin/smoke-access`
- Related features: `feat-core-services`
