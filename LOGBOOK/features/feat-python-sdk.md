---
status: shipped
branch: feat-python-sdk
---

# The first SDK, and the three mistakes it exists to stop

## Intent

The reference modules are the documentation. Nobody writing a third-party
module reads the Storage service's controller; they open `demo-tasks/app.py`
and copy what is there. So whatever is there gets written again, and three
things in it were wrong in the same way: correct, obvious, and expensive only
once there is traffic.

- **A Postgres connection per request.** A TCP connection, a handshake, and an
  authentication round trip, per page view, discarded at the end of it.
- **DDL per request.** The schema call lived inside the connection helper, so
  every request ran `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD
  COLUMN IF NOT EXISTS`. Postgres takes an `ACCESS EXCLUSIVE` lock to decide it
  has nothing to do. Invisible with one visitor; it serialises the module with
  twenty.
- **An HTTP call to Auth for every mention of the current user.** A page that
  draws a nav bar, a list, and a footer asked three times for an answer that
  could not have changed, while the core services cached the same lookup for
  thirty seconds.

A fourth was added by the storage work that came before this: a module reading
a file into its own memory and copying it out again, when it could hand over an
address instead.

The SDK is not a convenience layer. It is how the correct version of each of
those reaches the next module, and the cheapest moment to write it is while the
only modules that exist are ours.

Out of scope for this feature:

- The PHP, Ruby, and Node SDKs. The same four patterns apply and the shape
  should be the same, but one written and proven against a real module beats
  four written from the same guess.
- Presigned uploads. The write path still carries bytes through Storage.

## Plan

1. Storage grows a way to hand a module a signed URL for its own object, so
   the private read path can stop copying bytes.
2. `sdk/python/siberian`: the call convention, an Auth client with the same
   thirty second ceiling the core uses, a pooled database with the schema
   applied once, and a storage client that prefers URLs to bytes.
3. Module images build with the repository root as context, so a module can
   copy the SDK in.
4. `demo-tasks` is ported to it and keeps behaving identically.

## Decisions

### 2026-08-22: one lock was a deadlock, and only a real request found it

The first authenticated request to the ported module never returned. The
container was healthy, `bin/build-module` was clean, the module logged nothing,
and the Router gave up after sixty seconds with a 504.

Everything measured said it was fine. Fetching the DSN took 0.1s from inside
the container. Opening a pool and running `SELECT 1` took 0.02s. The Auth call
took 0.03s. The granted read took 0.1s. Each part of the request worked and the
request did not.

It was `migrate()` taking the lock and then calling the pool helper, which took
the same lock to create the pool. `threading.Lock` is not reentrant, so the
first request for a domain waited on itself forever. The second request queued
behind it, and the health check kept passing because it touches neither.

Now there are two locks that are never nested, and the pool is created before
the migration lock is taken. Two locks rather than one reentrant one, because
`RLock` would have made the symptom go away while leaving a function that takes
a lock and calls something that takes the same lock.

Worth recording for what found it rather than for the fix: nothing did, except
driving the real thing. A unit test with a fake database would have passed, and
so would a health check, and so would a review. `bin/smoke-demo` signs in and
loads a page, and that is the only reason this was a bad afternoon rather than
a bad week.

### 2026-08-22: module images build from the repository root

`bin/build-module` used the module's own directory as the build context, so a
module Dockerfile could not copy anything shared. The core images already build
from the root so they can copy `lib/`, and the reason is the same one.

The cost is that each module Dockerfile now names its own files by their path
from the root, which is four one line changes and is why they all say
`COPY modules/<name>/app.py`.

### 2026-08-22: the SDK is optional, and the README says so first

LOGBOOK is explicit that a module in any language talking plain HTTP is a valid
module, and an SDK that becomes required would quietly make that false. So the
README opens by saying a module never needs it, and the table underneath is
about what the hand-rolled version costs rather than about what the SDK adds.

`Refused` is the one piece of opinion in it: a full quota, an ungranted space,
and a revoked token are answers that will not improve on a retry, and giving
them their own exception is how a module avoids turning a refusal into a loop.

## Outcome

Shipped. `demo-tasks` behaves identically and is measurably cheaper per request:

- one pooled connection per domain instead of one per request
- the schema applied once per domain instead of on every page view
- `current_user()` cached for thirty seconds, the same ceiling the core states
- the attachment download is a redirect to the object store rather than a file
  copied through the module

`bin/smoke-demo` now follows that redirect and asserts the content, so the
round trip is proved rather than assumed: the module checks the task belongs to
whoever is asking, hands out a URL, and the file comes back from the object
store.
