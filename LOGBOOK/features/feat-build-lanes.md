---
status: shipped
branch: feat-build-lanes
---

# Two queues, because two kinds of build

## Intent

One builder took every build. A web export is about a minute and a Gradle build
is twenty, so somebody pressing "Rebuild preview" behind an Android build waited
a third of an hour to look at a page.

## Decisions

### 2026-08-30: two workers, not two priorities

The obvious fix is to let previews jump the queue, and it does not work. With
one worker the Android build is holding the worker: a preview at the front of
the queue still waits for it to finish. Only a second worker changes what
somebody waits for.

The claim query already took its row with `FOR UPDATE SKIP LOCKED`, which was
written for more than one worker and had never had one. So the change is a lane
on the claim and a second container.

A lane is derived from the platform rather than stored, because it is not a
decision anybody makes: it is how long the work takes. An unknown platform is
native, because native is the slow lane and putting something unknown in the
fast one is how the fast one stops being fast.

### 2026-08-30: a worker that names no lane still takes anything

That is what makes the rollout safe rather than a moment where the old container
and the new schema disagree. It is also what the single builder was, so nothing
about the old behaviour had to be described as a special case.

### 2026-08-30: its own volumes, and not for tidiness

The worker sweeps every workspace it can see at startup, on the correct
assumption that anything left behind belongs to a run that died. Two workers
sharing a workspace means the second one starting deletes the first one's build
out from under it, and the first one then fails somewhere deep in Gradle with a
missing file.

Two volumes instead. The cost is a second dependency cache, a few hundred
megabytes, against a failure that would have been blamed on the build.

### 2026-08-30: the same image, run twice

Giving the preview lane a tag of its own made the daemon extract the whole
Android SDK again for a second copy of identical layers. Both services did it at
once and the disk went from 14 GB free to none, mid build.

So the preview lane has no build section and names the image the native lane
builds. Compose builds every service that has one before it starts anything, so
the image is there by the time it is needed.

A slim node only image would be the better answer, since the preview lane never
touches Gradle or the Android SDK. It is a rebuild on a box that has run out of
disk twice, and it can wait until there is a reason beyond neatness.

### 2026-08-30: a position counts its own lane

A preview waits behind previews. A position counted across both queues would
tell somebody they were third when they were next, which is worse than saying
nothing. The page reports each lane separately for the same reason: "a build is
running" is the wrong thing to say when the one running is Android and the
preview somebody asked for is already going.

### 2026-08-30: measured, and it moved the CPU cap back

| preview lane | native lane | a preview takes |
|---|---|---|
| 0.75 | 1.5 | 298 s |
| 1.0 | 1.0 | 60 s |

Two cores asked to supply 2.25 did not make the preview a little slower, it made
it five times slower. A preview alone on an idle box takes 72 seconds, so at 1.0
against 1.0 a busy box costs it nothing measurable.

What that gives up is the 27 percent on Android builds that `feat-builder-cap.md`
measured and bought. It is the right thing to give up, and it is recorded there
rather than by editing reasoning that was correct when one builder did
everything.


### 2026-08-30: the split leaked once, during its own rollout

The preview worker took an Android build and spent twenty minutes on it while
two previews waited. Exactly the failure the split exists to prevent, and it
looked like a preview that was taking a while.

The cause was version skew of my own making: the builders and the Mobile service
were deployed separately, so for a few minutes a builder that sent `lanes` was
talking to a service that ignored it. The design already handled the opposite
skew, where an old builder sends nothing and gets anything, and that is the one
that was thought about.

So the lane travels with the build now and the worker checks it too. A mismatch
is put back through a new `release` endpoint rather than failed, so it keeps its
attempts and the right worker takes it within a poll rather than after the stale
timeout. Belt and braces, because the cost of one wrong claim is the whole
feature for as long as the build lasts.

### 2026-08-30: the stale timeout was sized for the slow lane

Ninety minutes is a sensible ceiling for a Gradle build and an absurd one for an
export that takes sixty seconds. There had only ever been one number to pick and
it had to suit the slow case.

That was invisible until the lanes existed, and then it was not: a preview
abandoned by a worker restarted underneath it blocked its own queue for an hour
and a half. Ten minutes for the preview lane, ninety for the native one.

`bin/reload` learned the second builder in the same change. Naming only the
first made it a maintenance command that quietly half worked, leaving the lane
somebody is actually watching on the old code, which is how the leak above
lasted as long as it did.

## Outcome

A preview takes about a minute whether or not an Android build is running, down
from about twenty. Product latency with both lanes busy is 274 ms on the product
root and 212 ms on the phone app page.

Nine tests in `core/mobile/test/models/build_lane_test.rb` pin which lane takes
what, including that a worker naming no lane still takes anything.
`bin/smoke-owner-app` checks both containers are up and each is told which queue
it takes, because a preview lane that quietly died looks exactly like a preview
that is taking a while.
