#!/bin/sh
# What a person can do to their own account.
#
# All of it was possible for an operator and impossible for the person it
# belongs to, which is the wrong way round for a product whose audience is the
# app user. Changing a password meant asking for a reset link to an address you
# were already signed in with, and ending an account meant asking somebody.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
B="https://$DOMAIN/-/auth"

. "$(dirname "$0")/smoke-lib.sh"

STAMP=$(date +%s)
EMAIL="own-$STAMP@example.test"

a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }
runner() { $COMPOSE exec -T "$1" bin/rails runner "$2" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }
token_from() { sed 's/.*"token":"\([^"]*\)".*/\1/'; }

runner orchestrator "Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$EMAIL', password: 'first-pass-111', name: 'Before' })" >/dev/null

PHONE=$(a -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"first-pass-111\",\"device_id\":\"phone-$STAMP\"}" "$B/sign-in" | token_from)
TABLET=$(a -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"first-pass-111\",\"device_id\":\"tablet-$STAMP\"}" "$B/sign-in" | token_from)
present "signed in on two devices" "$PHONE"

echo "1. their own name"
contains "they can change it" \
  "$(a -X PATCH -H "Authorization: Bearer $PHONE" -d '{"name":"After"}' "$B/me")" '"name":"After"'

echo "2. their own password"
# Asked for even though they are signed in. A session left open on a borrowed
# laptop is the case: whoever holds it can already read everything, and the one
# thing they must not be able to do is take the account.
check "the current one is required" \
  "$(a -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PHONE" \
     -d '{"current_password":"nope","password":"second-pass-22"}' "$B/password")" "401"
contains "and with it, changed" \
  "$(a -X POST -H "Authorization: Bearer $PHONE" \
     -d '{"current_password":"first-pass-111","password":"second-pass-22"}' "$B/password")" '"changed":true'

echo "3. changing it signs out the others and not this one"
check "this device stays" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PHONE" "$B/me")" "200"
check "the other is out" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TABLET" "$B/me")" "401"
check "the old password no longer works" \
  "$(a -o /dev/null -w '%{http_code}' -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"first-pass-111\"}" "$B/sign-in")" "401"

echo "4. signing out everywhere means everywhere"
AGAIN=$(a -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"second-pass-22\",\"device_id\":\"tablet-$STAMP\"}" "$B/sign-in" | token_from)
contains "it reports how many" \
  "$(a -X POST -H "Authorization: Bearer $PHONE" "$B/sign-out-everywhere")" '"signed_out"'
check "including the one that asked" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PHONE" "$B/me")" "401"
check "and the other" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AGAIN" "$B/me")" "401"

echo "5. ending the account"
LAST=$(a -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"second-pass-22\",\"device_id\":\"last-$STAMP\"}" "$B/sign-in" | token_from)
check "the password is required" \
  "$(a -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $LAST" -d '{"password":"nope"}' "$B/me")" "401"

DELETED=$(a -X DELETE -H "Authorization: Bearer $LAST" -d '{"password":"second-pass-22"}' "$B/me")
contains "and then it is done" "$DELETED" '"deleted":true'
# Said rather than implied: a module holds its own rows and the core cannot
# reach into them, which is the same isolation that keeps a module out of
# everybody else's data.
contains "it says module data is not removed" "$DELETED" "held by that module"

check "the session is gone" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $LAST" "$B/me")" "401"
check "and they cannot sign in" \
  "$(a -o /dev/null -w '%{http_code}' -X POST -d "{\"email\":\"$EMAIL\",\"password\":\"second-pass-22\"}" "$B/sign-in")" "401"

echo "6. the address is not handed to the next person"
# The property the whole shape exists for. Every module keys its rows by email,
# so freeing it would give whoever claimed it next the previous person's tasks.
check "a new account cannot take it" \
  "$(runner orchestrator "puts Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$EMAIL', password: 'somebody-else-3' }).nil?")" "true"

finish "app account"
