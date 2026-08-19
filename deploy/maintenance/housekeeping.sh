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

after=$(avail)
say "finished, ${after} MB free, $(( after - before )) MB reclaimed"
