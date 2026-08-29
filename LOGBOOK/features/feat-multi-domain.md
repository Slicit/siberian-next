---
status: shipped
branch: feat-multi-domain
---

# Serving every domain, not the first one

## Intent

LOGBOOK states multi-domain as architecture: "the system serves multiple
domains. Isolation is at the data layer, not the runtime layer." Module routing
already worked that way, rendering one server block per domain per module.

The core did not. The product shell, the Backoffice, and the object store door
were rendered once at Router start from a single `SIBERIAN_DOMAIN`, so the
Router served one domain while the database held two.

The failure mode is the bad kind. A domain with no server block is not refused:
nginx hands it to whichever block matches first, so a request to the second
domain was answered, correctly formatted, by the first domain's shell. Nobody
noticed because the second domain here is `siberian.localhost`, and browsers
hardcode `.localhost` to 127.0.0.1, which is the reason the project moved to
`.test` in the first place.

Out of scope:

- Certificates for a second domain. The development certificate covers
  `siberian.test` and its subdomains; a real second domain needs its own SAN
  entry, and `bin/generate-certs` still takes one domain.

## Decisions

### 2026-08-29: the core blocks move from container start to the Orchestrator

A template rendered at container start from an environment variable cannot know
how many domains exist, because that lives in a database it cannot read. It also
cannot be reconciled, which is the second and larger problem: every other piece
of derived routing state converges, and this one could not.

So the per-domain blocks became `lib/router/domain.conf.template`, rendered by
`RouterConfig#write_domains` into `conf.d/modules/domains/`, and converged by
`RouteReconciler` alongside routes and upstreams. What stays in the start-time
template is what answers to a fixed name or none: the HTTP redirect, the `core`
door modules use, and the `modules` door core services use. None of those varies
by domain.

Written whole and files for withdrawn domains removed, for the same reason the
upstream map is rewritten rather than appended to: a server block for a domain
nobody serves keeps answering, and the answer looks correct.

### 2026-08-29: the same assumption was one layer up, in Rails

Fixing the Router surfaced the next one immediately. `core.siberian.localhost`
went from falling through to answering **403**, because every service builds
`config.hosts` from a single `SIBERIAN_DOMAIN` and Rails refuses a Host it was
not told about.

That reads as a routing fault and is not one: the Router had already decided the
request was legitimate and delivered it to the right application. So the
allowlist now takes `SIBERIAN_DOMAINS`, comma separated, falling back to
`SIBERIAN_DOMAIN` so an unchanged deployment behaves exactly as before.

Worth being plain about the limitation: that list is read at boot, so a domain
added in the Backoffice does not answer until the core services restart. Rather
than pretend otherwise, the reconciler compares what it just wrote against what
the applications were told and reports the difference by name:

```
not in SIBERIAN_DOMAINS, so the applications will refuse them until the core
services restart: siberian.localhost
```

Reported rather than repaired, because restarting every core service is not
something a reconcile should decide to do on its own.

### 2026-08-29: the door's address comes from the driver, not a constant

The per-domain template carries the object store door, which needs the store's
address. The Orchestrator renders that template, so the obvious move is a
default in `RouterConfig`.

That would have named a backend in `core/`, which `bin/check-storage-leak` fails
the build for, and rightly: it is exactly the coupling that check exists to
prevent. The address is asked of `Siberian::ObjectStore.driver` instead, so the
door follows the deployment's backend, and an explicit
`SIBERIAN_OBJECT_STORE_ADDRESS` still wins for a deployment that puts the door
somewhere else.

## Outcome

Shipped. Both configured domains are served on all three doors, verified against
the running stack:

| | shell | Backoffice | object store |
|---|---|---|---|
| `siberian.test` | 302 | 302 | 403 |
| `siberian.localhost` | 302 | **302**, was 403 | 403 |

`bin/smoke-domains-served` asks the database what is served and then checks each
of those domains answers on its own three doors, so the next domain that is
configured and not served fails a check rather than being quietly answered by
its neighbour. The reconciler's drift report was verified by running it with a
narrowed allowlist: it named `siberian.localhost` exactly.

Seventy-seven orchestrator tests, six of them new on the per-domain rendering,
and the sweep at 19/19.

The certificate remains single-domain, so a genuinely new domain needs a SAN
entry before TLS works. Routing, host authorisation, and reconciliation no
longer assume one domain; certificates still do.
