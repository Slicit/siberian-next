#!/bin/sh
# The phone app page an app owner actually uses, on their own domain.
#
# It spent its whole life showing "Nothing built yet" to a domain with eighty
# builds, and its build buttons did nothing, because the Mobile service refused
# the Base App and the Base App turned the refusal into an empty list. Nothing
# was red. That is the failure this exists to catch: a page that reports an
# error as an absence looks exactly like a page with nothing to report.
#
# So every check here reads what the page says, not what it answered.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
J=/tmp/owner_jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }
runner() { $COMPOSE exec -T "$1" bin/rails runner "$2" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }

# The token is per form, so the one at the top of the page is not the one the
# build button carries. Taking the first would test a 422 rather than a build.
# Each form is folded onto one line so that grep can pick out the right one.
token_for() { # token_for <file> <action> <a value in that form>
  tr -d '\n' < "$1" | sed 's|</form>|</form>\n|g' \
    | grep "$2" | grep "$3" | head -1 \
    | grep -o 'authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//'
}

TOKEN=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=operator@siberian.localhost" --data-urlencode "password=$PASSWORD" \
  "https://$DOMAIN/login"

check "the page answers" "$(c -o /tmp/owner_page -w '%{http_code}' "https://$DOMAIN/app")" "200"

echo "1. the builds it shows are this domain's builds"
present "the database has builds for it" "$(runner mobile "puts Build.where(domain: '$DOMAIN').count")"
check "the page does not claim there are none" "$(grep -c 'Nothing built yet' /tmp/owner_page)" "0"
check "and did not fail to ask" "$(grep -c 'did not answer' /tmp/owner_page)" "0"
check "the table is drawn" "$(grep -c '<tbody>' /tmp/owner_page)" "1"

echo "2. the Mobile service enforces the pinning rather than trusting the caller"
# The Base App names its own domain because it is written to. These say what
# happens when something claiming to be it does not.
contains "a pinned caller with no domain is refused" \
  "$(runner base "puts Siberian::MobileClient.new.builds.inspect")" "must name the domain"
contains "and never gets the list of other domains" \
  "$(runner base "puts Array(Siberian::MobileClient.new.apps['apps']).size")" "0"
contains "while an operator still sees every domain" \
  "$(runner orchestrator "puts Array(Siberian::MobileClient.new.builds['builds']).size.positive?")" "true"

ID=$(runner mobile "puts Build.where(domain: '$DOMAIN').order(:id).last.id")
contains "a build it owns is readable" \
  "$(runner base "puts Siberian::MobileClient.new.build($ID, domain: '$DOMAIN')['domain']")" "$DOMAIN"
# The same answer as a build that does not exist, deliberately: telling a caller
# that a build it may not see exists is itself an answer.
contains "the same build under another domain is not" \
  "$(runner base "puts Siberian::MobileClient.new.build($ID, domain: 'somebody-else.test')['error']")" "no such build"

echo "3. the preview is the built app, not a picture of one"
contains "the frame points at the export" \
  "$(grep -o 'src="/app/preview/index.html[^"]*"' /tmp/owner_page | head -1)" "/app/preview/index.html"
check "which serves the exported page" \
  "$(c -o /tmp/owner_preview -w '%{http_code}' "https://$DOMAIN/app/preview/index.html")" "200"

# The asset, because this is where it broke: Rails refuses to send JavaScript to
# a request it cannot prove came from here, and a preview whose script is a 422
# renders a blank white phone rather than an error anybody would notice.
ASSET=$(grep -o 'src="[^"]*\.js"' /tmp/owner_preview | head -1 | sed 's/src="//; s/"//')
present "the page names its bundle" "$ASSET"
check "and the bundle is served" \
  "$(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/app/preview/$ASSET")" "200"

echo "4. the themes can be tried on and one kept"
STARTED_AS=$(runner mobile "puts MobileApp.find_by(domain: '$DOMAIN').theme")
KEPT=$(runner mobile "a = MobileApp.find_by(domain: '$DOMAIN'); puts [a.name, a.bundle_identifier, a.version].join('|')")
contains "the picker is drawn" "$(grep -o 'id="theme-picker"' /tmp/owner_page)" "theme-picker"
contains "the frame opens on the saved one" \
  "$(grep -o 'index.html?theme=[a-z]*' /tmp/owner_page | head -1)" "theme=$STARTED_AS"

# midnight unless that is already it, so the check is a change either way.
WANTED=midnight
[ "$STARTED_AS" = midnight ] && WANTED=daylight
THEME_TOKEN=$(token_for /tmp/owner_page 'action="/app/theme"' 'theme-picker')
c -o /dev/null -X POST --data-urlencode "authenticity_token=$THEME_TOKEN" \
  --data-urlencode "_method=patch" --data-urlencode "theme=$WANTED" "https://$DOMAIN/app/theme"
check "keeping one saves it" "$(runner mobile "puts MobileApp.find_by(domain: '$DOMAIN').theme")" "$WANTED"
# Only the theme is sent, so the upsert has to keep everything it was not
# given. A save that quietly renamed the app would still pass the line above.
check "and rewrites nothing else" \
  "$(runner mobile "a = MobileApp.find_by(domain: '$DOMAIN'); puts [a.name, a.bundle_identifier, a.version].join('|')")" \
  "$KEPT"

c -o /dev/null -X POST --data-urlencode "authenticity_token=$(token_for /tmp/owner_page 'action="/app/theme"' 'theme-picker')" \
  --data-urlencode "_method=patch" --data-urlencode "theme=$STARTED_AS" "https://$DOMAIN/app/theme"

echo "5. asking for a build asks for a build"
BEFORE=$(runner mobile "puts Build.count")
BUILD_TOKEN=$(token_for /tmp/owner_page 'action="/app/build"' 'value="web"')
present "the build button carries its own token" "$BUILD_TOKEN"
check "and posting it redirects rather than refusing" \
  "$(c -o /dev/null -w '%{http_code}' -X POST \
     --data-urlencode "authenticity_token=$BUILD_TOKEN" --data-urlencode "platform=web" \
     "https://$DOMAIN/app/build")" "302"
check "a build row exists that did not before" "$(runner mobile "puts Build.count")" "$((BEFORE + 1))"

# Read from the flash rather than the table, because by the time the page is
# fetched the builder may already have picked the build up, and a build that is
# running is not waiting for anything.
c -o /tmp/owner_page2 "https://$DOMAIN/app"
contains "and the person is told where they were in line" \
  "$(grep -o 'Build queued[^<]*' /tmp/owner_page2 | head -1)" "in line"

echo "6. a preview does not wait for an Android build"
# The reason the split exists. Asserted against the claim itself rather than
# by timing a build: a test that waits twenty minutes to find out is a test
# nobody runs.
contains "web is the preview lane" \
  "$(runner mobile "puts Build.lane_for('web')")" "preview"
contains "android and ios are the native one" \
  "$(runner mobile "puts [Build.lane_for('android'), Build.lane_for('ios')].uniq.join")" "native"
contains "the queue reports each lane separately" \
  "$(runner mobile "puts Build.in_lanes('preview').where(platform: 'android').count")" "0"

# Both containers, and each taking only its own. A second worker that quietly
# died leaves the preview queue served by nobody, which looks exactly like a
# preview that is taking a while.
contains "the native lane is running" \
  "$($COMPOSE ps --format '{{.Service}} {{.State}}' mobile-builder)" "running"
contains "and so is the preview lane" \
  "$($COMPOSE ps --format '{{.Service}} {{.State}}' mobile-builder-web)" "running"
contains "each told which queue it takes" \
  "$($COMPOSE exec -T mobile-builder-web printenv BUILDER_LANES </dev/null | tr -d '')" "preview"

finish "owner app"
