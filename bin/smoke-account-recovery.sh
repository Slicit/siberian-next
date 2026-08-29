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
FAILURES=0

a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }

check() {
  if [ "$2" = "$3" ]; then
    printf '   ok    %s\n' "$1"
  else
    printf '   FAIL  %s (wanted %s, got %s)\n' "$1" "$3" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}

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
echo "2. the mail was queued, delivered, and the transport kept it"
sleep 8
STATE=$($COMPOSE exec -T mailer bin/rails runner \
  "puts Message.where(core_sender: 'core-auth', to: '$RIDER').order(:id).last&.state" </dev/null 2>/dev/null | tail -1 | tr -d '\r')
check "the message reached the transport" "$STATE" "sent"

LINK=$($COMPOSE exec -T mailer bin/rails runner \
  "puts Message.where(core_sender: 'core-auth', to: '$RIDER').order(:id).last&.text_body.to_s[/https:\S+/]" \
  </dev/null 2>/dev/null | tail -1 | tr -d '\r')
TOKEN=$(printf '%s' "$LINK" | sed 's/.*token=//')
[ -n "$TOKEN" ] && check "the email carried a link" "carried" "carried" \
  || check "the email carried a link" "none" "carried"

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

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "account recovery: every check passed"
else
  echo "account recovery: $FAILURES check(s) FAILED"
  exit 1
fi
