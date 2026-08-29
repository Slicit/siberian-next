#!/usr/bin/env bash
# Asks what is wrong, and lets the Orchestrator decide whether that is news.
#
# Runs from the host rather than inside a container for one reason: free disk.
# `df` inside a container reports the container's filesystem, and a box that has
# filled up is exactly the condition worth knowing about, so the number is taken
# here and passed in.
#
# Every quarter of an hour, which is chosen against the requirement rather than
# for it. The scan is cheap and says nothing almost every time: a condition has
# to hold across two scans before a word is sent, and a condition that is still
# true is not sent again. Running it often makes the first alert arrive sooner
# without making any alert arrive twice.
set -uo pipefail

REPO="${SIBERIAN_REPO:-$HOME/siberian-next}"
LOG="${SIBERIAN_ALERT_LOG:-/var/log/siberian-alerts.log}"

cd "$REPO" || { echo "no repo at $REPO"; exit 1; }

say() { echo "$(date --iso-8601=seconds)  $*"; }

# Megabytes free on the filesystem the box actually runs on.
free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
[ -z "$free_mb" ] && free_mb="nil"

# One line on purpose. A continuation inside a docker compose exec has been
# eaten here before, which split the command and reported docker's usage text as
# the result.
ruby="r = AlertScan.new(free_megabytes: ${free_mb}).call; puts [r.opened.join(','), r.closed.join(','), r.firing.length, r.notified].join('|')"

out=$(docker compose --env-file .env -f deploy/compose.yml exec -T orchestrator \
        bin/rails runner "$ruby" 2>/dev/null | tail -1 | tr -d '\r')

if [ -z "$out" ]; then
  say "could not ask the Orchestrator what is wrong"
  exit 1
fi

opened=$(echo "$out" | cut -d'|' -f1)
closed=$(echo "$out" | cut -d'|' -f2)
firing=$(echo "$out" | cut -d'|' -f3)
notified=$(echo "$out" | cut -d'|' -f4)

# Silence is the normal outcome and is logged as one line rather than none, so
# "the scan is running and finding nothing" and "the scan has stopped" are
# different things in the log.
if [ -n "$opened" ] || [ -n "$closed" ]; then
  say "opened: [${opened}] resolved: [${closed}] now firing: ${firing} notified: ${notified}"
else
  say "nothing new, ${firing} still firing"
fi
