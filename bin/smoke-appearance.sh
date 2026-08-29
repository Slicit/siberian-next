#!/bin/sh
# What a person sees, rather than what an operator configured.
#
# An operator picks a palette. A phone has its own light or dark setting, and
# ignoring it means showing a light app to somebody who set their phone to dark
# at eleven at night. A theme here is a palette rather than a light-or-dark
# decision, which is what lets both be true: the chosen palette is used on every
# phone whose scheme matches it, and only the other case moves.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
J=/tmp/appearance.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }
runner() { $COMPOSE exec -T "$1" bin/rails runner "$2" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }

T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

echo "1. the palette an operator chose survives a matching phone"
# The property that makes this something an operator can leave on. If a light
# phone moved a light theme to a different light theme, the picker would be
# decoration.
check "meadow on a light phone stays meadow" \
  "$(runner mobile 'puts Siberian::MobileThemes.for_scheme("light", preferred: "meadow")')" "meadow"
check "midnight on a dark phone stays midnight" \
  "$(runner mobile 'puts Siberian::MobileThemes.for_scheme("dark", preferred: "midnight")')" "midnight"

echo "2. and a phone asking for the other scheme gets it"
check "meadow on a dark phone becomes a dark theme" \
  "$(runner mobile 'puts Siberian::MobileThemes.fetch(Siberian::MobileThemes.for_scheme("dark", preferred: "meadow"))[:scheme]')" "dark"
check "midnight on a light phone becomes a light theme" \
  "$(runner mobile 'puts Siberian::MobileThemes.fetch(Siberian::MobileThemes.for_scheme("light", preferred: "midnight"))[:scheme]')" "light"

echo "3. the setting reaches the app that gets built"
check "the plan carries it" \
  "$(runner mobile 'a = MobileApp.first; b = Build.new(mobile_app: a, domain: a.domain, platform: "web"); puts BuildPlan.new(b).to_h(secrets: false)[:app][:follow_device_scheme].inspect')" "true"

echo "4. the page says what it will do, in words"
c -o /tmp/appearance_page "https://core.$DOMAIN/mobile/2" >/dev/null
check "the page answers" "$(c -o /dev/null -w '%{http_code}' "https://core.$DOMAIN/mobile/2")" "200"
contains "the control is there" "$(cat /tmp/appearance_page)" "follow_device_scheme"
# Naming the themes rather than describing the mechanism: an operator should be
# able to read what a phone will show without working it out.
contains "and names what a dark phone will see" "$(cat /tmp/appearance_page)" "A phone set to dark sees"

echo "5. attaching a file is a capability an operator approves"
contains "the picker is offered" "$(cat /tmp/appearance_page)" "document_picker"
check "the module requires it" \
  "$(runner orchestrator 'puts ModuleCatalog.new.find("demo-tasks").manifest.data.dig("native", "requires").include?("document_picker")')" "true"
# Declining it costs the native rendering and nothing a person can do, because
# the WebView it falls back to has had attachments all along.
contains "and the web face still has attachments" \
  "$(c "https://tasks.apps.$DOMAIN/")" "attach"

finish "appearance"
