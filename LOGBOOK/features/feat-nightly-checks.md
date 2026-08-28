---
status: shipped
branch: feat-nightly-checks
---

# Checks that run without being asked

## Intent

The smokes are the only thing in this project that covers the seams between
Rails, nginx, Postgres, and the engine, and every expensive bug so far has lived
in one of those seams. They also only ran when somebody remembered to run them.

That gap was not theoretical, and the evidence turned up while building the
reconciler: GitHub Actions had been red on every push for eight days, because a
test double never grew a method the installer started calling. Seven orchestrator
tests were failing on `main` the whole time. Nobody noticed, so every change in
that window landed on a baseline nobody had verified.

Two things follow from that, and only the second one is about running checks.
The first is that a check nobody looks at is not a check. So the result goes on
the Overview, which is a page an operator already opens, rather than into a log
they would have to know existed.

Out of scope for this feature:

- Alerting anywhere other than the Backoffice. No mail, no webhook. The box has
  one operator and they open the Overview.
- Running the sweep on demand from the Backoffice. It takes a minute and a half
  and drives the real stack, which is a different thing from a page render.

## Plan

1. `deploy/maintenance/nightly-checks.sh`: run `bin/check`, `bin/test-lib`, and
   every smoke, recording each rather than stopping at the first failure.
2. Cron, after housekeeping.
3. A JSON result the Orchestrator reads through a read only bind mount.
4. A card on the Overview, which is red when the sweep failed and also red when
   the sweep is too old to mean anything.

## Decisions

### 2026-08-22: a stale pass is drawn as a failure

The obvious card shows green when the last sweep passed. That reproduces the
exact bug this feature exists to remove, one level up: a sweep that stopped
running three weeks ago and passed when it last ran would render as a reassuring
green tick forever.

So `ok?` requires the result to be recent as well as clean, and the card says
"the sweep may have stopped running" when it is not. Forty hours, because the
sweep is daily and a single missed night is a slow box rather than a broken
one.

### 2026-08-22: it records every check rather than stopping at the first failure

`set -e` would have made the script exit on the first red, and the report would
then say one thing failed and nothing about the fifteen checks after it. The
whole point is a complete picture on one page, so each check is run, timed, and
recorded, and the script exits zero regardless.

Zero even when checks failed, because the report is the output. A cron job that
exits non-zero adds a second, less informative alarm in root's mail spool, which
is another place nobody looks.

### 2026-08-22: a file through a bind mount, not an API

The sweep runs on the host, outside every container, under cron. It has no
credential for anything in the stack and giving it one would mean a service
token living in a cron environment.

So it writes a file and the Orchestrator mounts the directory read only. That is
the entire interface: the sweep never learns the Backoffice exists, the
Backoffice cannot influence the sweep, and the failure mode of the mount being
absent is a card that says the sweep has not run rather than an exception.

Written to a temporary file and moved into place, so a page render that lands
mid write reads the previous result rather than half of the next one.

## Outcome

Shipped, and verified by making it fail rather than by watching it pass.

- A real sweep on the box: 16 checks, 16 passed, 85 seconds, both as the
  developer and as root the way cron runs it.
- The recorded detail is the last few lines of each check, which is the part
  that says what it asserted. Reading it back is how the fast ones were
  confirmed to have done real work rather than exited early.
- A failure edited into the result renders as `15 of 16 passed`, names
  `smoke-cms`, and shows what it said.
- A result backdated six days renders red with "the sweep may have stopped
  running", which is the case the card exists for.

Seven tests on the reader, covering the answers that have to be honest: no file,
an unparseable file, a file that is not an object, a result with no timestamp,
and a stale pass. Each of those must not be green, and none of them is.
