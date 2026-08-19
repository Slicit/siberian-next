#!/bin/sh
# The notification inbox, and the three things that are not the same thing.
#
# Read is having seen it. Archive is being done with it while it still happened.
# Delete is deciding it never needs to exist again. A smoke that only checked
# "it disappeared" would pass on an implementation that lost all three.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
MODULE=https://push.apps.$DOMAIN
J=/tmp/push_jar.txt
rm -f $J

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

state() {
  c "$MODULE/api/notifications${1:+?state=$1}" | python3 -c "
import sys, json
payload = json.load(sys.stdin)
rows = [(n['id'], 'read' if n['read'] else 'unread') for n in payload['notifications']]
print(rows, 'unread count:', payload['unread'])
"
}

T=$(c -c $J "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"
echo "signed in as operator"

echo
echo "1. send one to myself     -> $(c -o /tmp/push_send -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"title":"Smoke","body":"Sent by bin/smoke-push"}' "$MODULE/api/notifications")"

# No device has agreed to be interrupted on this box, and the module says which
# rather than reporting a failure that sends somebody to look at a phone.
grep -oE '"detail": *"[^"]*"' /tmp/push_send | head -1 | sed 's/^/   delivery: /'

ID=$(grep -oE '"id": *[0-9]+' /tmp/push_send | grep -oE '[0-9]+' | head -1)

echo "2. in the inbox           $(state)"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/read"
echo "3. after reading          $(state)"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/archive"
echo "4. inbox after archiving  $(state)"
echo "   archived              $(state archived)"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/unarchive"
echo "5. back in the inbox      $(state)"

echo "6. delete it              -> $(c -o /dev/null -w '%{http_code}' -X DELETE "$MODULE/api/notifications/$ID")   (expect 200)"
echo "7. and again              -> $(c -o /dev/null -w '%{http_code}' -X DELETE "$MODULE/api/notifications/$ID")   (expect 404, it is gone)"
echo "8. the inbox              $(state)"
