---
status: shipped
branch: feat-artifact-retention
---

# Letting go of builds nobody will install

## Intent

Every finished build left an APK of sixty megabytes and nothing ever removed
one. Forty-one builds of the same app had accumulated, and the disk was at 86
percent with a larger one on order.

A superseded build of an app that has been built eleven times since is not
something anybody is going to install. Keeping it is not caution, it is the
absence of a decision.

## Decisions

### 2026-08-29: the binary goes, the build stays

Only `artifact_path` is cleared. The row, its log, its duration, its outcome and
its error all remain, because those are how a failure six weeks ago gets
explained, they cost bytes rather than megabytes, and trading the history for
space nobody was short of would be the wrong way round.

Clearing the path is also what stops the Backoffice offering a download that
answers 404, and it is done after the delete rather than before: a record saying
the binary is gone while it is still on the disk is the one state where the
space can never be reclaimed, because nothing knows to look for it. There is a
test for that ordering.

### 2026-08-29: the newest per app and per platform

Not the newest overall. Each platform is a separate answer to "can I install
this now", so keeping one artifact per app would delete the only iOS build in
order to keep an Android one.

`keep` is configurable and floors at one, because keeping zero deletes the only
installable build, which is a setting nobody means to write.

### 2026-08-29: it freed two gigabytes of quota and almost no disk

Worth recording because the assumption behind the whole feature was wrong in an
interesting way.

The retention run removed 38 artifacts and 1,927 MB by the quota's reckoning.
The disk did not move. Garage's data directory was 257 MB for what the
accounting called 2.3 GB, because Garage stores blocks by content and thirty
eight builds of the same app share nearly all of theirs.

So this reclaims *quota*, which is real and worth having: the domain pool is
what refuses the next build when it fills. It is not what was filling the disk.

Where the disk actually is, measured rather than assumed:

| | |
|---|---|
| images | 21.7 GB, of which `siberian-mobile-builder` is **8.36 GB** |
| build cache | 4.8 GB, 1.3 GB of it reclaimable |
| volumes | 5.7 GB |

The builder image carries an Android SDK, Gradle and Node, and it is needed. The
disk pressure is images, not data, and no amount of artifact retention addresses
it. That is a hardware answer, which is the one already on order.

## Outcome

Shipped, and run: 38 artifacts expired, 1,927 MB of quota returned, three kept,
one each for android, web and ios. Housekeeping now does it nightly, guarded by
the same in-flight check that protects the build workspaces, so an artifact is
never deleted out from under a running build.

Nine tests, which are the Mobile service's first. It had the scaffolding and no
test files at all, which is worth saying out loud: it holds the build queue, the
app configuration and the capability catalogue, and until now nothing checked
any of it.

The housekeeping line was wrong on its first run, reporting docker's usage text
as the number of artifacts removed, because a line continuation was eaten when
the block was written. Fixed, and the command is one line now so there is no
continuation to lose.
