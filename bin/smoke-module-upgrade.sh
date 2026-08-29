#!/bin/sh
# Moving an installed module to a new version, through the Backoffice.
#
# Before this, upgrading meant removing and installing again. That revokes the
# module's credentials, detaches its network, drops its containers and gives it
# a new uuid, and gives an operator no way back when the new version is broken.
#
# The three things worth proving are the three that uninstall-and-install cannot
# do: the data survives, a same-version call says so instead of pretending, and
# a version that does not come up leaves the working one running.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
MODULE="example-push"
J=/tmp/upg_jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }
runner() { $COMPOSE exec -T orchestrator bin/rails runner "$1" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }

T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

UUID=$(runner "puts InstalledModule.find_by(name: '$MODULE').uuid")
present "the module is installed" "$UUID"

echo "1. asking for the version it already has"
SAME=$(runner "
m = InstalledModule.find_by(name: '$MODULE')
e = ModuleCatalog.new.find('$MODULE')
r = ModuleUpgrader.new(m, e.manifest, registrar: ServiceRegistrar.new).call
puts \"#{r.success?} #{r.changed?}\"
")
# An operator who rebuilt an image under the same tag and was told it worked
# would go looking for their change in the wrong place. That cost an afternoon
# once already.
check "succeeds without changing anything" "$SAME" "true false"

echo "2. a version that does not serve what it declares"
BEFORE_IMAGE=$(docker ps --format '{{.Image}}' | grep "$MODULE" | head -1)
ROLLED=$(runner "
m = InstalledModule.find_by(name: '$MODULE')
data = ModuleCatalog.new.find('$MODULE').manifest.data.deep_dup
data['version'] = '9.9.9'
data['containers'].first['health']['path'] = '/there-is-nothing-here'
r = ModuleUpgrader.new(m, Siberian::Contracts::Manifest.new(data), registrar: ServiceRegistrar.new).call
puts r.success?
")
check "is refused" "$ROLLED" "false"
check "the version does not move" \
  "$(runner "puts InstalledModule.find_by(name: '$MODULE').version != '9.9.9'")" "true"

echo "3. and the version that worked is what is left running"
check "one container, not two" "$(docker ps --format '{{.Names}}' | grep -c "$MODULE")" "1"
check "the same image as before" "$(docker ps --format '{{.Image}}' | grep "$MODULE" | head -1)" "$BEFORE_IMAGE"
check "and it answers" \
  "$(c -o /dev/null -w '%{http_code}' "https://push.apps.$DOMAIN/")" "200"

echo "4. through it all, the module kept its identity"
# The uuid names the network, the containers, and every provisioned database and
# bucket. Keeping it is the whole reason this is not a remove and an install.
check "the same uuid" "$(runner "puts InstalledModule.find_by(name: '$MODULE').uuid")" "$UUID"
check "its data is still there" \
  "$(c "https://push.apps.$DOMAIN/api/notifications" | grep -c '"notifications"')" "1"

echo "5. the page offers an upgrade only when there is one"
c -o /tmp/upg_page "https://core.$DOMAIN/modules/$MODULE" >/dev/null
check "the module page answers" \
  "$(c -o /dev/null -w '%{http_code}' "https://core.$DOMAIN/modules/$MODULE")" "200"
check "no upgrade is offered at the current version" \
  "$(grep -c 'Upgrade to' /tmp/upg_page)" "0"

finish "module upgrade"
