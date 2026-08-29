#!/bin/sh
# What the system is doing, on a page instead of behind curl.
#
# The mail queue and the database audit trail both existed and neither had a
# page: an operator asking why mail was not arriving needed an admin token, at
# the moment they would least want to reach for one. Mail now carries password
# resets, so that stopped being a question anybody can leave for later.
#
# And nothing alerted. A failing nightly sweep sat on the dashboard, which is a
# page somebody visits once they already suspect something.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
RESULTS="${SIBERIAN_CHECK_RESULTS:-deploy/checks}/latest.json"
J=/tmp/vis_jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

echo "1. the mail queue has a page"
check "it answers" "$(c -o /tmp/vis_q -w '%{http_code}' "https://core.$DOMAIN/queue")" "200"
contains "it counts what is sent" "$(cat /tmp/vis_q)" "Sent ("
contains "and what is dead" "$(cat /tmp/vis_q)" "Dead ("

# The reason there is no message body on that page. A reset link is a
# credential, and a page showing one lets whoever reads it take over the
# account. Metadata answers "why is mail not arriving"; contents answer a
# question nobody should be asking here.
check "no reset link is readable on it" "$(grep -c 'auth/reset?token=' /tmp/vis_q)" "0"
check "no message body is on it" "$(grep -c 'text_body' /tmp/vis_q)" "0"

echo "2. filtering by state works"
check "the sent filter answers" \
  "$(c -o /tmp/vis_s -w '%{http_code}' "https://core.$DOMAIN/queue?state=sent")" "200"
contains "and says which state it is showing" "$(cat /tmp/vis_s)" "Sent messages"

echo "3. the audit trail has a page"
check "it answers" "$(c -o /tmp/vis_a -w '%{http_code}' "https://core.$DOMAIN/audit-trail")" "200"
contains "it offers the refusals filter" "$(cat /tmp/vis_a)" "Refusals only"
check "the filter answers" \
  "$(c -o /dev/null -w '%{http_code}' "https://core.$DOMAIN/audit-trail?refusals=true")" "200"

echo "4. both are in the menu"
contains "mail queue" "$(cat /tmp/vis_q)" ">Mail queue</a>"
contains "database audit" "$(cat /tmp/vis_q)" ">Database audit</a>"

echo "5. a failing sweep says so on every page, not only the dashboard"
if [ ! -f "$RESULTS" ]; then
  echo "   (no sweep result here, skipping)"
else
  cp "$RESULTS" /tmp/vis_latest.backup
  python3 - "$RESULTS" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
checks = data.get("checks") or []
if checks:
    checks[0]["status"] = "failed"
    checks[0]["detail"] = "made to fail by bin/smoke-visibility"
json.dump(data, open(path, "w"))
PY

  # A working system is silent, so the check is that an unwell one is not.
  contains "the banner appears on Modules" "$(c "https://core.$DOMAIN/modules")" "nightly check"
  contains "and on the queue page" "$(c "https://core.$DOMAIN/queue")" "nightly check"

  cp /tmp/vis_latest.backup "$RESULTS"
  check "and goes when the sweep is green again" \
    "$(c "https://core.$DOMAIN/modules" | grep -c 'nightly check failing')" "0"
fi

finish "visibility"
