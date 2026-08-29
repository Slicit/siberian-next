---
status: shipped
branch: feat-sdk-rollout
---

# The other two Python modules, and a leak the rollout exposed

## Intent

The SDK was written and proven on one module. The other two Python modules,
`example-cms` and `example-push`, still had all three patterns it exists to
replace: a Postgres connection per request, `CREATE TABLE IF NOT EXISTS` on
every page view, and an HTTP round trip to Auth for every mention of the
current user.

Leaving them that way defeats the point. The reference modules are the
documentation, so an unported one keeps teaching the expensive version to
whoever copies it next, and the CMS is the biggest module in the tree.

Out of scope:

- `example-notes`, which is PHP. It has the same shape and wants the same
  treatment, but the PHP SDK does not exist yet and writing one from a single
  reading of one module is how you get an SDK that fits nothing.

## Decisions

### 2026-08-29: the connection lives on the request, not on the call

`demo-tasks` was converted call site by call site to `with db() as connection`.
That worked because it had eight of them. The CMS has fifteen, and `example-push`
nine, and neither closed a connection anywhere: there was no `connection.close()`
in either file. They leaked one per request and survived only because Python
eventually collected them.

Against a pool that stops being survivable, because a pool that is never given
anything back empties. So rather than rewriting twenty-four call sites and their
indentation, `db()` now keeps one connection on Flask's request context and a
`teardown_appcontext` hands it back however the request ends, exception
included. Every existing call site is unchanged and correct, and a page that
calls `db()` six times now uses one connection instead of six.

This is Flask's own documented pattern for a request scoped resource, which is
worth saying because "keep it on `g`" can read as a trick rather than the shape
the framework already has.

### 2026-08-29: the rollout uncovered a network leak that had nothing to do with it

Reinstalling the two modules failed:

```
HTTP 400: all predefined address pools have been fully subnetted
```

Docker had run out of address space, and both modules were down. There were 26
module networks for 5 modules, 19 of them empty.

The uninstaller looked correct: it detaches the Router, removes the containers,
then removes the network. What it missed is that the Router is not the only
thing attached. `RouteReconciler` also joins the module data cluster to every
module network so a module can reach Postgres directly, and nothing ever took it
off. A network with anything still attached cannot be removed, and the failure
went through `attempt`, which logs and continues.

So every uninstall since that reconciler was written has left a network behind.
It is invisible until the pool runs out, at which point the error names subnets
and no module can be installed at all, which is a long way from "uninstall does
not finish".

Fixed by detaching the data cluster before removing the network, mirroring how
the reconciler attaches it.

### 2026-08-29: the double could not fail the way the engine does

`FakeEngine` had neither `attach` nor `detach`, and `RouteReconciler` calls
`attach`. That never broke a test only because both call sites return early when
`SIBERIAN_MODULEDB_CONTAINER` is unset, which it is in tests. The same shape as
the `FakeRouter` that was missing `refresh_upstreams!` and kept CI red for eight
days: a double quietly narrower than the interface, with an environment variable
hiding it.

Both are implemented now, and `remove_network` on the double **raises while
anything is still attached**, because that refusal is the entire bug. A double
that removes a network regardless cannot fail the way the real engine did, and a
test written against it would have passed before the fix and after.

Checked rather than assumed: with the fix removed, the new test fails with
`Expected ["siberian-moduledb-1"] to be empty`. It has teeth.

## Outcome

Shipped.

- `example-cms` and `example-push` use the SDK. Between them that removes
  twenty-four per-request connections, four per-request DDL statements, and an
  uncached Auth round trip on every request of both.
- Uninstall no longer leaks a network. 19 orphans were removed from the box by
  hand; the fix stops the next one.
- `FakeEngine` matches the interface it stands in for, and refuses to remove an
  attached network.

`smoke-cms` was also printing `-> 302 (expect 200)` for media and exiting zero,
so the sweep stayed green while the line said otherwise. That expectation went
stale when public media became a redirect to the object store. It now follows
the redirect and asserts the bytes, which is what it was always claiming to
check.

71 orchestrator tests, and the full sweep at 18/18.
