#!/usr/bin/env bash
# Keeps the development box from filling up.
#
# It filled up once, completely: 47 GB, nothing left, and the first symptom was
# Postgres refusing writes and the apps failing in ways that pointed everywhere
# except at the disk. Three things had grown without limit.
#
#   Build workspaces. Roughly 800 MB each, and the builder deleted one only at
#   the start of the next build. Sixteen builds, fourteen gigabytes. The builder
#   removes its own now; this catches what a killed worker left behind.
#
#   Docker build cache. Nearly six gigabytes, all reclaimable, none of it
#   needed by anything running.
#
#   Container logs. Capped for new containers by deploy/maintenance/daemon.json,
#   but a container created before that keeps writing without a limit.
#
# Conservative on purpose: it removes build cache, dangling images, and its own
# workspaces. It does not touch volumes, named images, or anything a running
# container depends on, because this runs unattended and a maintenance job that
# surprises somebody is worse than a full disk.
set -uo pipefail

REPO="${SIBERIAN_REPO:-/home/claude/siberian-next}"
KEEP_LOG_MB="${KEEP_LOG_MB:-20}"
CACHE_AGE="${CACHE_AGE:-48h}"

say() { printf '%s  %s\n' "$(date -Is)" "$*"; }

avail() { df --output=avail -BM / | tail -1 | tr -dc '0-9'; }

before=$(avail)
say "starting, ${before} MB free"

# Container logs. Truncated rather than deleted: the file is held open by the
# daemon, so removing it frees nothing until the container restarts.
trimmed=0
for log in /var/lib/docker/containers/*/*-json.log; do
  [ -f "$log" ] || continue
  size=$(( $(stat -c %s "$log") / 1024 / 1024 ))
  if [ "$size" -gt "$KEEP_LOG_MB" ]; then
    : > "$log"
    trimmed=$(( trimmed + 1 ))
  fi
done
say "truncated ${trimmed} container log(s) over ${KEEP_LOG_MB} MB"

# Build cache. Anything recent is worth keeping: a rebuild that has to start
# from nothing is twenty minutes somebody waits for.
docker builder prune -f --filter "until=${CACHE_AGE}" >/dev/null 2>&1 \
  && say "pruned build cache older than ${CACHE_AGE}" \
  || say "build cache prune failed"

# Dangling images only. Not `-a`: that removes images no container is running
# right now, which on this box includes the generator image and anything built
# for a service that happens to be stopped.
docker image prune -f >/dev/null 2>&1 \
  && say "pruned dangling images" \
  || say "image prune failed"

# Under pressure, prune harder.
#
# The age filter above is the right default: recent cache is worth keeping
# because a rebuild that starts from nothing is twenty minutes somebody waits
# for. But an age filter has no ceiling, and a full `up --build` produces twelve
# gigabytes of cache that is minutes old, which is exactly what it will not
# touch. The disk filled twice; the second time an npm install died with ENOSPC
# in the middle of a build.
#
# So: gentle every night, thorough when the disk is actually running out.
free_mb=$(avail)
if [ "$free_mb" -lt "${FLOOR_MB:-8000}" ]; then
  say "only ${free_mb} MB free, below the ${FLOOR_MB:-8000} MB floor, so pruning harder"
  docker builder prune -f >/dev/null 2>&1 && say "pruned all dangling build cache"
  docker image prune -af --filter "until=24h" >/dev/null 2>&1 && say "pruned images unused for a day"
fi

# Build workspaces, but never while something is building. The builder cleans
# up after itself; this is for the case where it was killed halfway.
building=$(cd "$REPO" 2>/dev/null && docker compose --env-file .env -f deploy/compose.yml \
  exec -T mobile bin/rails runner 'puts Build.where(state: "building").count' 2>/dev/null | tr -dc '0-9')

if [ -z "$building" ]; then
  say "could not ask the Mobile service what is building, so workspaces were left alone"
elif [ "$building" != "0" ]; then
  say "${building} build(s) in flight, so workspaces were left alone"
else
  docker exec siberian-mobile-builder-1 sh -c 'rm -rf /workspace/*' >/dev/null 2>&1 \
    && say "cleared idle build workspaces" \
    || say "no builder to clear workspaces in"
fi

# Superseded build artifacts.
#
# Each finished build leaves an APK of sixty megabytes and nothing removed one,
# so forty-one builds of the same app held two gigabytes. Only the newest per
# app and platform is kept: a superseded build of an app that has been built
# eleven times since is not something anybody is going to install.
#
# The build rows stay. They are the log, the duration and the outcome, they cost
# bytes rather than megabytes, and losing the history to reclaim space nobody
# was short of would be a bad trade.
#
# Guarded by the same in-flight check as the workspaces above: deleting an
# artifact while its build is running would race the upload.
if [ "$building" = "0" ]; then
  # One line on purpose: a continuation here was eaten once, which split the
  # command in two and reported docker's usage text as the number of
  # artifacts removed.
  retention_ruby='r = ArtifactRetention.new.call; puts [r.removed, r.megabytes, r.kept].join(" ")'
  artifacts=$(cd "$REPO" 2>/dev/null && docker compose --env-file .env -f deploy/compose.yml exec -T mobile bin/rails runner "$retention_ruby" 2>/dev/null | tr -d "")
  set -- $artifacts
  if [ -n "$1" ]; then
    say "removed $1 superseded artifact(s), $2 MB, keeping $3"
  else
    say "could not ask the Mobile service to expire artifacts"
  fi
fi

after=$(avail)
say "finished, ${after} MB free, $(( after - before )) MB reclaimed"
