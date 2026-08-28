#!/usr/bin/env bash
# Installs the housekeeping routine on the box, as a cron entry.
#
# Idempotent: run it again after changing anything here and it replaces what it
# installed before. Everything it writes is under a name that says where it
# came from, so somebody who finds it in six months can trace it back.
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO="$(pwd)"
# Whoever owns the checkout is who the sweep runs as. Taken from the tree rather
# than assumed, so this is right on a box where the repository lives somewhere
# other than one person's home directory.
CHECK_USER="$(stat -c '%U' "$REPO")"
CRON=/etc/cron.d/siberian-housekeeping
CHECKS_CRON=/etc/cron.d/siberian-checks
DAEMON=/etc/docker/daemon.json
LOG=/var/log/siberian-housekeeping.log
CHECKS_LOG=/var/log/siberian-checks.log

echo "Installing the housekeeping cron entry..."
sudo tee "$CRON" >/dev/null <<CRONTAB
# Siberian Next housekeeping. Installed from $REPO/deploy/maintenance/install.sh
#
# Nightly, because the thing it prevents took weeks to happen and an hourly job
# that prunes build cache would make every rebuild slower for no reason.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 4 * * * root SIBERIAN_REPO=$REPO $REPO/deploy/maintenance/housekeeping.sh >> $LOG 2>&1
CRONTAB
sudo chmod 0644 "$CRON"

sudo touch "$LOG"
sudo chmod 0644 "$LOG"

echo "Installing the nightly check cron entry..."
sudo tee "$CHECKS_CRON" >/dev/null <<CRONTAB
# Siberian Next nightly checks. Installed from $REPO/deploy/maintenance/install.sh
#
# After housekeeping rather than before it, because a smoke that queues an
# Android build needs the disk that housekeeping just freed, and a sweep that
# fails on a full disk reports on the disk rather than on the code.
#
# As $CHECK_USER and not as root, unlike housekeeping. The sweep needs nothing
# root has: it drives the stack through the Docker socket, which this user
# already reaches, and it writes one file.
#
# Running it as root actively broke it. The smokes keep working files at fixed
# paths in /tmp, so a root run left root owned files there and the next run by
# a person could not overwrite them: smoke-public-media then compared an empty
# file and reported that the bytes came back wrong. One user, no collision.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 5 * * * $CHECK_USER SIBERIAN_REPO=$REPO $REPO/deploy/maintenance/nightly-checks.sh >> $CHECKS_LOG 2>&1
CRONTAB
sudo chmod 0644 "$CHECKS_CRON"

sudo touch "$CHECKS_LOG"
# Writable by the user cron will run this as, since it is not root.
sudo chown "$CHECK_USER" "$CHECKS_LOG"
sudo chmod 0644 "$CHECKS_LOG"

# Written by the sweep, read by the Backoffice through a read only bind mount.
mkdir -p "$REPO/deploy/checks"

# Logs are capped for containers created after this lands. Existing containers
# keep whatever they were created with, which is why housekeeping also truncates.
if [ ! -f "$DAEMON" ]; then
  echo "Capping container logs in $DAEMON..."
  sudo mkdir -p /etc/docker
  sudo cp deploy/maintenance/daemon.json "$DAEMON"
  echo "  written. It takes effect for containers created after the daemon restarts:"
  echo "    sudo systemctl restart docker    # restarts every container"
else
  echo "$DAEMON already exists, leaving it alone. It should contain:"
  cat deploy/maintenance/daemon.json | sed 's/^/    /'
fi

echo
echo "Installed."
echo "  housekeeping   04:30, logs to $LOG"
echo "  nightly checks 05:00, logs to $CHECKS_LOG, and the Overview reads"
echo "                 $REPO/deploy/checks/latest.json"
echo
echo "Run them now with:"
echo "  sudo SIBERIAN_REPO=$REPO $REPO/deploy/maintenance/housekeeping.sh"
echo "  SIBERIAN_REPO=$REPO $REPO/deploy/maintenance/nightly-checks.sh"
