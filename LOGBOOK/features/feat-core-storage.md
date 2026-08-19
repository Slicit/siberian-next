---
status: draft
branch: feat-core-storage
---

# Core Storage capability

## Intent

Every module needs somewhere to put files, and none of them should have to
learn an object store to do it. The core exposes four HTTP verbs against
`/v1/{space}/{path}` and keeps S3 entirely on its own side of the wall. A module
in PHP or Python uses the HTTP client it already has, which is the same reason
the rest of the module contract is plain HTTP.

Out of scope for this feature:

- Serving `public` objects through a CDN.
- Direct-to-storage uploads via pre-signed URLs, which would put the object
  store back in front of modules.
- Multi-node Garage layout and replication tuning.

## Plan

1. ~~Choose the backing store.~~
2. ~~Specify the module-facing API, the three spaces, and the bucket mapping.~~
3. ~~Add the storage grant to the module manifest schema.~~
4. ~~Put Garage on an internal-only network that only the Storage service joins.~~
5. Generate the Storage Rails service.
6. Implement the four verbs, plus list, against Garage.
7. Bucket provisioning at install time, keyed on `(module, domain)`.
8. Quota accounting and enforcement.
9. The `tmp` sweeper.
10. Router rule for `/-/public/<path>`.

## Decisions

### 2026-08-19

- **Decision:** Garage, not MinIO.
- **Why:** MinIO's community edition was archived in February 2026 and its community documentation was pulled in October 2025, which makes it a dead dependency to build a product on. Garage is actively maintained, a single Rust binary with no JVM and no external database, and light enough that adding it to an already large core costs little. Its weaker S3 surface (no bucket versioning, no ACLs or bucket policies, no lifecycle rules) is nearly irrelevant here, because our own API is the authorization layer and modules never issue S3 calls.
- **Impact:** `deploy/compose.yml`, `core/storage/garage/`. The one place it bites is `tmp` expiry, which needs a sweeper in the Storage service rather than a bucket lifecycle rule.

- **Decision:** modules get a plain HTTP file API, not S3 credentials.
- **Why:** requiring an S3 SDK would quietly contradict "the core does not constrain module language or framework": it would mean every module language needs a maintained S3 client and a working signature implementation. Four verbs over HTTP need nothing.
- **Impact:** the caller's identity is never a request parameter. A module cannot name another module's file because the API has no field in which to name one. It also means the backing store can be replaced by touching one service.

- **Decision:** Garage sits on an `internal: true` network that only the Storage service joins.
- **Why:** the object store holds every module's files across every domain. If it were reachable from the core network, a single leaked credential would cross both the module and the domain boundary at once.
- **Impact:** `deploy/compose.yml`. Storage is the only service on two networks, and that is deliberate rather than incidental.

- **Decision:** one bucket per `(module, domain)`, named `sib-<module_name>-<domain_hash>`.
- **Why:** mirrors the Database service exactly, so there is one isolation rule in the system rather than two. The hash keeps the name inside the 63 character S3 limit without truncating the domain into ambiguity.
- **Impact:** bucket provisioning happens at install time and again when a domain is added.

## Links

- Branch: `feat-core-storage`
- PR: TBD
- Related ideas: none
- Related features: `feat-monorepo-skeleton`
- External: MinIO community edition archived 2026-02-13
