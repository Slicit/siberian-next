#!/usr/bin/env bash
# Installs the housekeeping routine on the box, as a cron entry.
#
# Idempotent: run it again after changing anything here and it replaces what it
# installed before. Everything it writes is under a name that says where it
# came from, so somebody who finds it in six months can trace it back.
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO="$(pwd)"
CRON=/etc/cron.d/siberian-housekeeping
DAEMON=/etc/docker/daemon.json
LOG=/var/log/siberian-housekeeping.log

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
echo "Installed. It runs at 04:30 and logs to $LOG."
echo "Run it now with: sudo SIBERIAN_REPO=$REPO $REPO/deploy/maintenance/housekeeping.sh"
