---
status: shipped
branch: feat-service-tokens
---

# One secret per pair of services

## Intent

Every core service authenticated every other with the same static bearer,
`SIBERIAN_ADMIN_TOKEN`. That token was admin everywhere, so compromising any one
service was compromising all of them: the Mailer could mint database
credentials, the Storage service could delete a domain's buckets, the Base App
could create users. None of them needed those powers and nothing checked
whether the caller had a reason to be asking.

It also meant no call could be attributed. "Which service registered this
module" had no answer, because they all presented the same string.

The right pattern already existed in the tree. The Mobile service issues the
builder its own token and admits it to exactly the endpoints one claimed build
needs, because the builder runs third-party code and is a different trust level.
That reasoning applies to every pair of core services; it had only been applied
where the danger was obvious.

Out of scope for this feature:

- Rotating these without a restart. They are environment, read at boot.
- Asymmetric credentials. A shared secret means the callee holds something it
  could present as the caller, which is why the secret is per pair: the blast
  radius of that is one direction of one pair.
- mTLS, which answers the same question at a layer this project does not yet
  manage.

## Plan

1. `lib/service_identity.rb`: who is calling, and what to present when calling.
2. `lib/service_authentication.rb`: a controller says which services may call
   it, and a controller that names nobody permits nobody.
3. Every guarded endpoint declares its callers.
4. Compose issues one secret per pair, with distinct defaults.
5. The smokes stop presenting a token that no longer exists.

## Decisions

### 2026-08-22: per pair, not per service

The obvious design is one token per service: each caller presents its own, each
callee checks it. It is simpler and it does not work, for a reason worth
writing down.

A callee has to know a token in order to check it. With one token per caller,
every service that the Orchestrator calls must hold the Orchestrator's token,
and that token is what the Orchestrator uses everywhere. So a compromised
Storage service reads its own environment and can then act as the Orchestrator
against the Database service, the Mailer, Auth, and Mobile. The shared secret
has been split five ways and the blast radius has not moved.

Per pair, the most a compromised service can learn is how to talk to itself.
Storage holds the Orchestrator-to-Storage secret and the Mobile-to-Storage
secret, and neither opens anything else.

Verified on the running stack rather than reasoned about:

| presented | at | result |
|---|---|---|
| Orchestrator to Storage | Storage | 200 |
| the same token | Database | 401 |
| Orchestrator to Database | Database | 200 |
| the old shared admin token | Storage | 401 |
| Mobile to Storage | Storage | 200 |
| Mobile to Storage | Mailer | 401 |

### 2026-08-22: the dev defaults are distinct

Each pair's default is its own string (`dev_orchestrator_to_storage` and so on)
rather than one shared development value. A shared default would make
development behave exactly like the thing this replaces, every smoke would pass,
and the first place anybody noticed would be a deployment that inherited it.

### 2026-08-22: a controller that names nobody permits nobody

`permit_services` defaults to the empty list, so including the concern and
forgetting the declaration closes the endpoint rather than opening it. The
failure mode of forgetting is then a refusal in a smoke, which is loud, instead
of an endpoint that admits every service, which is silent and is what this
feature exists to end.

The refusal names the caller in the log and not in the response. Which services
would have been allowed is not useful to a legitimate caller and is useful to
everybody else.

### 2026-08-22: the old token still works, until it does not

A service with no `SIBERIAN_CALLERS` accepts the shared token and logs a warning
every time. That is what lets the code and the environment be upgraded at
separate moments rather than in one simultaneous restart.

The moment a service is given its callers, the shared token stops being
special: it is not in the list, so it is refused. There is a test for both
halves, because a compatibility path that never closes is a permanent hole.

## Outcome

Shipped. Eight services carry their own credentials, nine pairs in total, and
the endpoints they guard each name who may call them:

- Storage admits the Orchestrator, and Mobile, which registers itself like a
  module to keep build artifacts.
- Database, Mailer, and Auth admit the Orchestrator alone. Notably Auth's user
  and role management admits only the Backoffice: the Base App asks Auth who
  somebody is, which needs no token at all, and managing people is not its job.
- The Orchestrator admits the Base App for capabilities and the Mailer for
  transport lookup, and nothing else.
- Mobile admits the Orchestrator everywhere and the Base App on the one
  endpoint it reads to draw the product side menu.

108 lib tests including ten on identity, the five service suites, and all
fourteen smokes. The `bin/check` conventions pass.

Found while doing it: Storage and Auth had no `SIBERIAN_ADMIN_TOKEN` in compose
at all and were relying on the literal default in the code. The default was
doing real work in a running system, which is the second time in three features
that a value nobody set turned out to be load bearing.
