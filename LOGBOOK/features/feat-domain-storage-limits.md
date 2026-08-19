---
status: shipped
branch: feat-domain-storage-limits
---

# Domain storage limits, set where domains are managed

## Intent

Storage quotas shipped with a Storage page that can set all three levels, and
that page lists a domain only once a module has provisioned a bucket on it. So
the one moment an operator knows what a domain is for, the moment they add it,
is the one moment they cannot say how much disk it may have. The allowance
arrives later, after a module has already started writing.

Domains are added on the Domains page. That is where the limit belongs.

Out of scope for this feature:

- New quota arithmetic. The Storage service already owns every number and
  every refusal; this only asks it different questions.
- Per-space quotas. A module's `public` and `files` still share its allowance.
- Alerting. A domain filling up overnight still tells nobody.

## Plan

1. ~~The Domains page reads storage and shows each domain's usage and allowance.~~
2. ~~A domain's total and its per-bucket default are set from that page.~~
3. ~~Adding a domain can set its allowance in the same form.~~
4. ~~The Storage page lists every domain the system serves, not only the ones that already hold a bucket.~~
5. ~~A smoke that sets an allowance on a domain with no bucket and reads it back.~~

## Decisions

### 2026-08-19

- **Decision:** the allowance is set from the Domains page, and the Storage page keeps the same two fields rather than giving them up.
- **Why:** the two pages answer different questions. Domains is where somebody decides what a hostname is for; Storage is where they compare one domain against another. Moving the fields would trade the gap this feature closes for a new one.
- **Impact:** two places render the same two fields against the same endpoint. The Storage service is still the only thing that owns a number, so the two views cannot disagree.

- **Decision:** the Storage page lists the union of the domains Storage knows and the domains the Orchestrator serves.
- **Why:** Storage learns a domain when a bucket appears on it, which is later than the domain exists, and a removed domain keeps its buckets, which is after it stops being served. Listing only one side loses a domain at one end or the other.
- **Impact:** a domain with nothing stored on it is configurable, and a row whose domain is gone says "no longer served" instead of quietly disappearing with the data still there.

- **Decision:** adding a domain and setting its allowance stay separate permissions, including inside the one form that does both.
- **Why:** a hostname is cheap and a shared disk is not. This is the same argument that gave storage its own permission when quotas shipped, and putting the fields on another page does not change it.
- **Impact:** an operator holding only `core.domains.manage` sees the add form without the allowance fields, and `create` ignores the parameters if they arrive anyway.

## Outcome

Shipped 2026-08-19. A domain can be given a total and a per-bucket default at
the moment it is added, before any module has written a byte, which was the one
thing the quota feature could not do. `bin/smoke-domains` drives it through the
Backoffice: add with an allowance, read it back, clear the ceiling, remove the
domain, and watch its storage row survive marked as no longer served.

Found on the way, and not fixed here: `Role.seed_defaults!` skips a role that
already exists, so `core.storage.manage` never reached the operator role on an
installation seeded before storage quotas shipped. The permission existed, the
pages checked it, and no seeded role held it. Repaired on the development box by
hand and raised in `LOGBOOK/candidates.md`, because deciding what happens to a
role an operator has since edited is its own decision.
