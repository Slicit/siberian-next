---
status: shipped
branch: feat-resource-limits
---

# Bounding the builder, and asking whether this would deploy

## Intent

Two things from the review on 2026-08-22, both filed under "run the box like
the smallest production", and the second one turned out to want the opposite of
what it said.

**Nothing had a resource limit.** The box has two cores. Gradle and Metro each
take every core they are offered, so an Android build competed with Postgres,
eleven Rails processes, and the Router for the whole machine. The symptom of
that is the entire product being slow while nothing looks wrong with any part
of it: the cause is in one container and the evidence is spread across all of
them.

**Nothing exercised the production configuration.** Development autoloads on
demand, so a class that cannot be loaded is fine until somebody opens the page
that names it, and no setting that production requires is ever read until the
day of a deployment.

Out of scope for this feature:

- Anything about the hardware. The box is local development with specs that are
  not final, which the review treated as a bottleneck and which is not one to
  solve in this repository.

## Decisions

### 2026-08-22: the dev box stays in development mode

The review proposed `RAILS_ENV=production` on the box, for eager loading. On
reflection that trades a real cost for a benefit available another way.

The cost is the development loop. Source is bind mounted and production mode
turns off reloading, so every edit becomes a container restart, and error pages
stop saying what went wrong. This box is where the work happens.

The benefit, catching a class that cannot be loaded, is what `zeitwerk:check`
does: it eager loads everything exactly as a production boot would and reports
what breaks. It costs a second and changes nothing about how the stack runs.

So `bin/check-boot` asks both questions of the running stack without changing
it: can every service load everything it names, and would every service boot in
production configuration. Both, nightly.

### 2026-08-22: the boot probe supplies the secrets production demands

The first run reported that the Database service would not boot in production.
That was not a bug: it refuses to start without `SIBERIAN_ENCRYPTION_PRIMARY_KEY`
because it stores credentials encrypted, and the guard is deliberate.

A check that fails every night for a known and correct reason is a check nobody
reads, so the probe supplies values for everything production insists on. The
question being asked is whether the code boots, not whether this box happens to
hold production secrets. Nothing the probe supplies outlives it: `runner` serves
no request, issues no cookie, and writes no row.

### 2026-08-22: one core for the builder, and no CPU cap on anything else

The builder is capped at one core of two, so a build always leaves one for the
databases, the Router, and everything in front of them. Builds get slower, which
is the intended trade: a build nobody is watching should lose to a page somebody
is.

Nothing else has a CPU cap. The Rails services are waiting on Postgres and on
each other almost all the time, and capping something already idle costs latency
under load and buys nothing. They do get a memory ceiling, at roughly seven
times what they use, so a leak stops one container rather than the box.

Verified rather than assumed. Four busy loops inside the builder, on a two core
box, and it sat at 100.28 percent, which is one core. Postgres answered a query
in 0.126 seconds while that was running.

### 2026-08-22: the nightly sweep must not run as root, and now refuses to

Adding `bin/check-boot` to the sweep turned up a failure that had nothing to do
with it. `smoke-public-media` reported that the bytes came back wrong, and the
recorded output said why: `rm: cannot remove '/tmp/pub_body': Operation not
permitted`.

The smokes keep working files at fixed paths in /tmp. The sweep had been
installed to run as root, so a nightly run left root owned files there, and the
next run by a person could not overwrite them. The smoke then compared an empty
file and reported a failure in the thing it was testing, which was fine.

The fix is that the sweep does not need root and never did: it drives the stack
through the Docker socket, which the user owning the checkout already reaches,
and writes one file. Cron now runs it as that user, and the script refuses to
run as root rather than trusting the cron entry to stay correct.

Worth noting what found it. The failing check reported the last few lines of its
own output into the result file, and the cause was in those lines. A report that
had only recorded pass or fail would have said `smoke-public-media` was broken.

## Outcome

Shipped.

- The builder is bounded at one core and 3 GB, verified under synthetic load.
- Seven Rails services carry a 768 MB ceiling, verified on the running
  containers rather than in the file.
- `bin/check-boot` reports that all seven load everything they name and boot in
  production configuration, and runs nightly.
- The sweep is 17 checks and runs as a person rather than as root.

The `/tmp` fragility in the smokes is real and is not fixed here: fourteen of
them use fixed paths, and the collision only stopped mattering because there is
now one user. Recorded as a candidate rather than churned through now.
