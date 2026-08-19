---
status: active
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

1. The Domains page reads storage and shows each domain's usage and allowance.
2. A domain's total and its per-bucket default are set from that page.
3. Adding a domain can set its allowance in the same form.
4. The Storage page lists every domain the system serves, not only the ones
   that already hold a bucket.
5. A smoke that sets an allowance on a domain with no bucket and reads it back.

## Decisions

## Outcome
