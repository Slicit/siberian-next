#!/bin/sh
# Getting back into an account you cannot sign in to.
#
# This is the first thing in the core that sends mail, so it crosses Auth, the
# Mailer, the transport module answering mail.transport.v1, and the Router door
# core services use to reach a module. Every one of those was broken at some
# point on the way in, and none of it is provable without all of them running.
#
# The reset link is read out of the transport's own record rather than out of a
# log, which is what a transport that keeps one is for.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

STAMP=$(date +%s)
RIDER="recover-$STAMP@example.test"
. "$(dirname "$0")/smoke-lib.sh"

a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }

# The throttle is real and this script trips it deliberately, so it starts from
# a clean count. Without this a second run inside the window fails on the limit
# it is trying to prove, which reads as a broken feature rather than a working
# one.
$COMPOSE exec -T auth bin/rails runner 'AuthAttempt.delete_all' </dev/null >/dev/null 2>&1

echo "creating an account to lose the password to"
$COMPOSE exec -T orchestrator bin/rails runner \
  "Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$RIDER', password: 'original-pass-1' })" \
  </dev/null >/dev/null 2>&1

OLD=$(a -X POST -d "{\"email\":\"$RIDER\",\"password\":\"original-pass-1\",\"device_id\":\"old-phone-$STAMP\"}" \
  "https://$DOMAIN/-/auth/sign-in" | sed 's/.*"token":"\([^"]*\)".*/\1/')

echo
echo "1. signed in on a device, then asks for a reset"
check "the device is signed in" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OLD" "https://$DOMAIN/-/auth/me")" "200"

# The same answer whether or not the address exists, always: anything else makes
# this a way to ask who has an account on this domain.
KNOWN=$(a -X POST -d "{\"email\":\"$RIDER\"}" "https://$DOMAIN/-/auth/forgot")
UNKNOWN=$(a -X POST -d "{\"email\":\"nobody-$STAMP@example.test\"}" "https://$DOMAIN/-/auth/forgot")
check "an unknown address gets the same answer as a known one" "$UNKNOWN" "$KNOWN"

echo
echo
echo "2. the mail was queued, sent, and arrived"
sleep 8
STATE=$($COMPOSE exec -T mailer bin/rails runner \
  "puts Message.where(core_sender: 'core-auth', to: '$RIDER').order(:id).last&.state" </dev/null 2>/dev/null | tail -1 | tr -d '\r')
check "the message reached the transport" "$STATE" "sent"

# Read out of the delivered mail rather than out of the queue's own row.
#
# The row proves the message was composed with a link in it, which is not the
# same fact and was the only one ever checked: for the life of this project the
# transport either wrote a log line or recorded the message and sent nothing, so
# a reset link had never once been read back from anywhere a person could have
# received it.
INBOX=$($COMPOSE exec -T mailer sh -c \
  "curl -s 'http://mailpit:8025/api/v1/search?query=to%3A$RIDER'" </dev/null 2>/dev/null | tr -d '\r')
contains "it arrived at the address that asked" "$INBOX" "$RIDER"

# The newest, not the oldest. A greedy match took the last "ID" in the list,
# which is the account verification mail sent when this account was created a
# few lines above, and its link is a verify link that no reset endpoint knows.
MAIL_ID=$(printf '%s' "$INBOX" | grep -o '"ID":"[^"]*"' | head -1 | sed 's/.*:"//; s/"//')
present "the delivered message has an id" "$MAIL_ID"

DELIVERED=$($COMPOSE exec -T mailer sh -c \
  "curl -s http://mailpit:8025/api/v1/message/$MAIL_ID" </dev/null 2>/dev/null | tr -d '\r')
# The reset link specifically. Two mails reach this address and both carry a
# token, so matching any link at all is a check that can pass on the wrong one.
LINK=$(printf '%s' "$DELIVERED" | grep -oE 'https://[^" ]+/-/auth/reset[?]token=[A-Za-z0-9_-]+' | head -1)
TOKEN=$(printf '%s' "$LINK" | sed 's/.*token=//')
present "the delivered email carried a link" "$TOKEN"
echo
echo "3. the link works once"
check "it says it is valid before anybody types a password" \
  "$(a "https://$DOMAIN/-/auth/reset?token=$TOKEN")" '{"valid":true}'
check "resetting signs them straight in" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"token\":\"$TOKEN\",\"password\":\"brand-new-pass-2\",\"device_id\":\"new-phone-$STAMP\"}" \
     "https://$DOMAIN/-/auth/reset")" "201"
check "the same link cannot be used again" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"token\":\"$TOKEN\",\"password\":\"third-pass-3\"}" "https://$DOMAIN/-/auth/reset")" "422"

echo
echo "4. the reset actually changed things"
check "the old device is signed out" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OLD" "https://$DOMAIN/-/auth/me")" "401"
check "the old password is refused" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"email\":\"$RIDER\",\"password\":\"original-pass-1\"}" "https://$DOMAIN/-/auth/sign-in")" "401"
check "the new password works" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"email\":\"$RIDER\",\"password\":\"brand-new-pass-2\",\"device_id\":\"new-phone-$STAMP\"}" \
     "https://$DOMAIN/-/auth/sign-in")" "201"

echo
echo "5. neither door can be hammered"
GUESSER="guesser-$STAMP@example.test"
i=1
while [ "$i" -le 10 ]; do
  a -o /dev/null -X POST -d "{\"email\":\"$GUESSER\",\"password\":\"wrong-$i\"}" "https://$DOMAIN/-/auth/sign-in"
  i=$((i + 1))
done
check "the eleventh sign-in guess is refused" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"email\":\"$GUESSER\",\"password\":\"wrong-11\"}" "https://$DOMAIN/-/auth/sign-in")" "429"

ASKER="asker-$STAMP@example.test"
i=1
while [ "$i" -le 3 ]; do
  a -o /dev/null -X POST -d "{\"email\":\"$ASKER\"}" "https://$DOMAIN/-/auth/forgot"
  i=$((i + 1))
done
check "the fourth reset request is refused" \
  "$(a -o /dev/null -w '%{http_code}' -X POST -d "{\"email\":\"$ASKER\"}" "https://$DOMAIN/-/auth/forgot")" "429"

finish "account recovery"
