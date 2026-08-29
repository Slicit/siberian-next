#!/bin/sh
# A manifest is written by somebody else and believed by the core. This checks
# that believing it has a limit.
#
# The failure it stands for is not hypothetical. example-relay declared
# mail.transport.v1 at an endpoint its stock nginx image could not serve, the
# core believed the manifest, and every message in the system died on its first
# attempt for weeks with everything reporting success.
#
# Driven through the Orchestrator rather than the Backoffice, because installing
# a module that is expected to fail is not something the catalogue page should
# make easy.
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

. "$(dirname "$0")/smoke-lib.sh"

runner() { $COMPOSE exec -T orchestrator bin/rails runner "$1" </dev/null 2>/dev/null | tr -d '\r'; }

echo "1. a module that declares an endpoint it does not serve"

# Clean slate, in case a previous run left the failed record behind.
runner '
m = InstalledModule.find_by(name: "example-liar")
ModuleUninstaller.new(m, registrar: ServiceRegistrar.new).call if m
' >/dev/null

OUT=$(runner '
e = ModuleCatalog.new.find("example-liar")
r = ModuleInstaller.new(e.manifest, registrar: ServiceRegistrar.new).call
puts r.success? ? "INSTALLED" : "REFUSED " + r.error.to_s
' | tail -1)

case "$OUT" in
  REFUSED*) check "the install is refused" "refused" "refused" ;;
  *)        check "the install is refused" "installed" "refused" ;;
esac
contains "and says which declaration was wrong" "$OUT" "mail.transport.v1"

echo "2. nothing of it is left running"
check "no container survives" "$(docker ps --format '{{.Names}}' | grep -c example-liar)" "0"
# The record is kept on purpose, so an operator can see what failed and why. It
# is the container and the network that must not survive.
check "no network survives" "$(docker network ls --format '{{.Name}}' | grep -c "$(runner 'puts InstalledModule.find_by(name: "example-liar")&.network_name.to_s' | tail -1)x")" "0"

echo "3. and the failure is legible"
STATE=$(runner 'm = InstalledModule.find_by(name: "example-liar"); puts m ? m.status : "gone"' | tail -1)
check "the record says failed" "$STATE" "failed"
RETRY=$(runner '
e = ModuleCatalog.new.find("example-liar")
r = ModuleInstaller.new(e.manifest, registrar: ServiceRegistrar.new).call
puts r.error.to_s
' | tail -1)
contains "installing again explains what to do" "$RETRY" "Remove it first"

echo "4. an honest module still installs"
# The other half of the check. A probe that refused everything would also pass
# every assertion above, and would be worse than no probe at all.
runner '
m = InstalledModule.find_by(name: "example-relay")
ModuleUninstaller.new(m, registrar: ServiceRegistrar.new).call if m
' >/dev/null

HONEST=$(runner '
e = ModuleCatalog.new.find("example-relay")
r = ModuleInstaller.new(e.manifest, registrar: ServiceRegistrar.new).call
puts r.success? ? "OK" : "REFUSED " + r.error.to_s
' | tail -1)
check "example-relay installs" "$HONEST" "OK"

echo "5. tidy up"
runner '
m = InstalledModule.find_by(name: "example-liar")
ModuleUninstaller.new(m, registrar: ServiceRegistrar.new).call if m
puts "removed"
' >/dev/null
check "the liar is gone" \
  "$(runner 'puts InstalledModule.where(name: "example-liar").count' | tail -1)" "0"

finish "honest manifest"
