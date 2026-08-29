#!/bin/sh
# The notification inbox, and the three things that are not the same thing.
#
# Read is having seen it. Archive is being done with it while it still happened.
# Delete is deciding it never needs to exist again. A smoke that only checked
# "it disappeared" would pass on an implementation that lost all three, which is
# what this one did: it printed the inbox after each step and never once said
# what the inbox should have contained.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
MODULE=https://push.apps.$DOMAIN
J=/tmp/push_jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

# Whether one particular notification is in one particular list, and how it
# reads. Answers about the row this run created, so rows left by earlier runs
# cannot make a count come out right.
where() { # where <state-or-empty> <id>  -> "absent" | "read" | "unread"
  c "$MODULE/api/notifications${1:+?state=$1}" | python3 -c "
import sys, json
wanted = int(sys.argv[1])
payload = json.load(sys.stdin)
for n in payload['notifications']:
    if n['id'] == wanted:
        print('read' if n['read'] else 'unread')
        break
else:
    print('absent')
" "$2"
}

T=$(c -c $J "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

echo "1. send one to myself"
expect "   accepted                  " "$(c -o /tmp/push_send -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"title":"Smoke","body":"Sent by bin/smoke-push"}' "$MODULE/api/notifications")" 200

ID=$(grep -oE '"id": *[0-9]+' /tmp/push_send | grep -oE '[0-9]+' | head -1)
present "it came back with an id" "$ID"
# No device has agreed to be interrupted on this box. The module is expected to
# say so rather than report a failure that sends somebody to look at a phone.
present "it says what happened to the delivery" \
  "$(grep -oE '"detail": *"[^"]*"' /tmp/push_send | head -1)"

echo "2. it arrives unread"
check "in the inbox, unread" "$(where '' "$ID")" "unread"

echo "3. reading is not removing"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/read"
check "still in the inbox, now read" "$(where '' "$ID")" "read"

echo "4. archiving is not deleting"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/archive"
check "gone from the inbox" "$(where '' "$ID")" "absent"
check "and present in the archive" "$(where archived "$ID")" "read"

echo "5. and it comes back"
c -o /dev/null -X POST "$MODULE/api/notifications/$ID/unarchive"
check "back in the inbox, still read" "$(where '' "$ID")" "read"

echo "6. deleting is forever"
expect "   delete                    " "$(c -o /dev/null -w '%{http_code}' -X DELETE "$MODULE/api/notifications/$ID")" 200
expect "   and again                 " "$(c -o /dev/null -w '%{http_code}' -X DELETE "$MODULE/api/notifications/$ID")" 404
check "gone from the inbox" "$(where '' "$ID")" "absent"
check "gone from the archive too" "$(where archived "$ID")" "absent"

finish "push"
