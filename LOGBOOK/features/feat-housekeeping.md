---
status: shipped
branch: feat-housekeeping
---

# Not filling the disk, and clearing up when something does

## Intent

The box filled to 100 percent. What it looked like from outside was Postgres
refusing writes and services failing to start, which points at Postgres and at
services. What it was, was sixteen build workspaces of roughly 800 MB each that
nothing ever deleted, plus six gigabytes of Docker build cache and a container
log with no ceiling.

Two routines, because there are two problems. The builder should not leave
anything behind. And the machine should tidy up whatever else accumulates,
without being asked, because whoever it inconveniences will be busy with
something else when it happens.

Out of scope for this feature:

- Monitoring or alerting. Nothing warns that the disk is filling; the routine
  stops it filling instead.
- Pruning anything a running container depends on. This runs unattended, and a
  maintenance job that surprises somebody is worse than a full disk.

## Plan

1. ~~The builder removes a workspace when its build reports, both ways.~~
2. ~~It sweeps whatever a killed worker left behind, at startup.~~
3. ~~A housekeeping script: logs, build cache, dangling images, orphan workspaces.~~
4. ~~Container logs capped so they cannot grow without limit in the first place.~~
5. ~~Installed on the box, nightly, with a log of what it did.~~

## Decisions

### 2026-08-20

- **Decision:** the workspace goes when the build reports, whether it succeeded or failed.
- **Why:** keeping a failed build's tree sounds useful and is not: the log is on the row by the time this runs, and it is the log that explains a failure. Keeping 800 MB per failure to avoid reading it is a bad trade at any disk size.
- **Impact:** `discard` runs in a `finally`, so a build that throws on the way out still cleans up. It logs a failure to remove rather than failing the build over it.

- **Decision:** at startup the builder sweeps everything in the workspace.
- **Why:** anything there belonged to a build this process was running, and this process has just started. There is no case where a directory there is legitimately in progress.
- **Impact:** the children are removed rather than the directory, because the directory is a mount point.

- **Decision:** the nightly routine prunes build cache and dangling images, and does not touch volumes or named images.
- **Why:** it runs unattended at half past four. `docker image prune -a` would take images no container is running at that moment, which on this box includes the generator image and anything belonging to a stopped service. The cost of being conservative is that somebody occasionally prunes by hand; the cost of being thorough is a morning spent working out what went missing.
- **Impact:** it refuses to clear build workspaces while anything is building, and says so rather than skipping silently.

- **Decision:** container logs are capped in `daemon.json` as well as truncated by the routine.
- **Why:** truncating is a cure and the cap is the prevention. The cap only applies to containers created after the daemon restarts, which is why both exist.
- **Impact:** 10 MB, three files, per container. The routine still truncates anything over 20 MB, which is how the containers that predate the cap are handled.


### 2026-08-29: the artifact sweep shared a guard it did not need

Artifact retention sat behind the same in-flight check as the workspace
cleanup, on the reasoning that deleting an artifact while its build is running
would race the upload.

It cannot. A build in flight has uploaded nothing, so it holds no
`artifact_path` and is not a candidate; and if it finishes mid sweep it becomes
the newest for its app and platform, which is the one thing always kept. The
race is real for workspaces, which are deleted from under a running build, and
that guard stays.

The cost of sharing it was invisible and large. On a box whose build queue is
rarely empty, the sweep effectively never ran: thirteen superseded APKs and 723
megabytes had accumulated, on a disk at ninety six percent, while the nightly
log said nothing at all because the whole block was skipped rather than
reporting zero.

Fixed, and the difference is visible in one run: the artifact line now appears
with a build in flight, where it used to be absent.

### 2026-08-29: a preview is not an artifact

A web build records the sentinel `preview` rather than a path, because every web
build writes to `previews/<bundle identifier>/` and a superseded one was
overwritten the moment the next finished.

The sweep did not know that, so for each superseded web build it asked Storage
to delete an object called "preview", got a 404, recorded an error, and tried
again the next night. Forever, and for nothing: those files had been gone since
the build after them.

Now the row is simply forgotten: the field is cleared, no delete is attempted,
and nothing is reported as reclaimed, because reporting megabytes freed from
something that occupied none is a lie in the direction that makes a disk look
healthier than it is.
## Outcome

Shipped 2026-08-20. The immediate problem was 44 GB used of 47 with nothing
free; clearing stale workspaces and build cache took it to 28 GB used and 17 GB
free without stopping anything.

The routine is installed at `/etc/cron.d/siberian-housekeeping`, runs at 04:30,
and appends to `/var/log/siberian-housekeeping.log`. Run by hand it reported
what it did line by line, including refusing to clear workspaces because a
build was in flight, which is the behaviour worth having.
