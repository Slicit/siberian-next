---
status: active
branch: feat-storage-quotas
---

# Storage quotas: per bucket, per domain, and a default

## Intent

A module currently asks for a quota in its manifest and gets it. That is the
wrong way round: the manifest is written by somebody else, and an operator who
cannot say "no module gets more than this" has no way to stop one module
filling a disk everybody shares.

Three levels, because three questions get asked. What does a new bucket get by
default? What is this one bucket allowed? And what is every module on this
domain allowed between them?

Out of scope for this feature:

- Quotas on the core's own storage. Only module buckets are counted.
- Per-space quotas. A module's `public` and `files` share its allowance.
- Alerting. The Backoffice shows usage; nothing sends a warning yet.

## Plan

1. A default bucket quota an operator sets, which caps what a manifest can ask for.
2. A per-domain total, shared by every module bucket on that domain.
3. Enforcement of both on write, without a query per request.
4. Admin API for reading and changing all three.
5. Backoffice: usage, headroom, and the settings behind them.
6. Recalculation, because a denormalised counter will drift eventually.
7. Tests, and a smoke that fills a quota and watches a write get refused.

## Decisions

### 2026-08-19

- **Decision:** the operator's default caps the manifest, rather than the manifest winning.
- **Why:** a manifest is written by a third party. If asking for more is enough to get more, the setting is a suggestion and the disk is a shared resource with no owner.
- **Impact:** a bucket gets `min(requested, default)`. A module asking for less than the default still gets what it asked for, because there is no reason to give it more than it wants.

- **Decision:** usage is a counter kept on the row, not a sum computed per request.
- **Why:** the domain check has to run on every upload. Summing every bucket on a domain per write is a query whose cost grows with the number of modules installed, which is the wrong direction: installing a module should not make every other module slower.
- **Impact:** two counters, incremented on write and decremented on delete. Counters drift, so recalculation is a button rather than a hope.

## Links

- Branch: `feat-storage-quotas`
- PR: TBD
- Related features: `feat-core-storage`
