#!/bin/sh
# Getting back into a core account, and proving an app account verified itself.
#
# The app half shipped first, because an app account had no other way in at all.
# A core account has an operator who can reset it by hand, which made this less
# urgent and not less necessary: the installation with one operator has nobody
# to ask.
#
# A browser flow rather than the JSON one, so this drives the pages: the form,
# the emailed link, the page it opens, and the session it leaves behind.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

. "$(dirname "$0")/smoke-lib.sh"

STAMP=$(date +%s)
CORE="reset-me-$STAMP@siberian.localhost"
APP="verify-me-$STAMP@example.test"
J=/tmp/core_recovery.txt
rm -f $J

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }
a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }
runner() { $COMPOSE exec -T "$1" bin/rails runner "$2" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }
token_from() { grep -o 'name="authenticity_token" value="[^"]*"' "$1" | head -1 | sed 's/.*value="//; s/"//'; }

# The throttle is real and this trips it. Start from a clean count so a second
# run inside the window does not fail on the limit it is meant to respect.
$COMPOSE exec -T auth bin/rails runner 'AuthAttempt.delete_all' </dev/null >/dev/null 2>&1

runner auth "u = User.create!(email: '$CORE', password: 'original-pass-1'); u.roles << Role.find_by(name: 'member'); puts u.id" >/dev/null

echo "1. a core account asks for a reset"
c -o /tmp/cr_forgot "https://$DOMAIN/forgot" >/dev/null
check "the page is there" "$(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/forgot")" "200"
contains "and the sign-in form links to it" "$(c "https://$DOMAIN/login")" "Forgotten"

c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$(token_from /tmp/cr_forgot)" \
  --data-urlencode "email=$CORE" "https://$DOMAIN/forgot"

echo "2. the email arrives through the queue, and arrives"
sleep 9
check "it was sent" \
  "$(runner mailer "puts Message.where(core_sender: 'core-auth', to: '$CORE').order(:id).last&.state")" "sent"

# Out of the delivered mail rather than the queue's own row. The row proves the
# message was composed with a link in it, which is a different fact: the
# transport used to write a log line or record the message and send nothing, so
# no reset link had ever been read back from anywhere a person could receive it.
mailpit() { $COMPOSE exec -T mailer sh -c "curl -s http://mailpit:8025/api/v1/$1" </dev/null 2>/dev/null | tr -d '\r'; }

INBOX=$(mailpit "search?query=to%3A$CORE")
contains "it arrived at the address that asked" "$INBOX" "$CORE"
# The newest, because the same address also received a verification mail and its
# link is a verify link no reset endpoint knows.
MAIL_ID=$(printf '%s' "$INBOX" | grep -o '"ID":"[^"]*"' | head -1 | sed 's/.*:"//; s/"//')
DELIVERED=$(mailpit "message/$MAIL_ID")
LINK=$(printf '%s' "$DELIVERED" | grep -oE 'https://[^" ]+/reset[?]token=[A-Za-z0-9_-]+' | head -1)
TOKEN=$(printf '%s' "$LINK" | sed 's/.*token=//')
present "it carried a link" "$TOKEN"
echo "3. the link opens a page that sets a password"
check "the page opens" "$(c -o /tmp/cr_reset -w '%{http_code}' "https://$DOMAIN/reset?token=$TOKEN")" "200"
# Said before they commit rather than after: somebody who does not want to be
# signed out on their other devices should know that now.
contains "and warns it signs them out elsewhere" "$(cat /tmp/cr_reset)" "everywhere else"

check "setting it redirects" "$(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$(token_from /tmp/cr_reset)" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "password=brand-new-pass-2" \
  --data-urlencode "password_confirmation=brand-new-pass-2" \
  "https://$DOMAIN/reset")" "302"

echo "4. and it did what it said"
check "they are signed in already" "$(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/")" "200"
check "the link cannot be used twice" \
  "$(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/reset?token=$TOKEN")" "302"

K=/tmp/core_recovery_2.txt
rm -f $K
OLD=$(curl -s --cacert "$CA" -c $K "https://$DOMAIN/login")
check "the old password is refused" \
  "$(curl -s --cacert "$CA" -b $K -c $K -o /dev/null -w '%{http_code}' -X POST \
     --data-urlencode "authenticity_token=$(printf '%s' "$OLD" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')" \
     --data-urlencode "email=$CORE" --data-urlencode "password=original-pass-1" \
     "https://$DOMAIN/login")" "422"

echo "5. an app account proves it can read its own address"
runner orchestrator "Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$APP', password: 'long-enough-1' })" >/dev/null
check "it starts unverified" \
  "$(runner orchestrator "puts Siberian::AuthClient.new.app_users('$DOMAIN')['users'].find { |u| u['email'] == '$APP' }['verified']")" "false"

sleep 9
VLINK=$(runner mailer "puts Message.where(core_sender: 'core-auth', to: '$APP').order(:id).last&.text_body.to_s[/https:\S+/]")
present "a verification link was sent" "$VLINK"
contains "following it verifies them" "$(a "$VLINK")" '"verified":true'
contains "and it works only once" "$(a "$VLINK")" '"verified":false'

check "the operator sees them as verified" \
  "$(runner orchestrator "puts Siberian::AuthClient.new.app_users('$DOMAIN')['users'].find { |u| u['email'] == '$APP' }['verified']")" "true"

echo "6. an operator can set a password when mail cannot be received"
ID=$(runner orchestrator "puts Siberian::AuthClient.new.app_users('$DOMAIN')['users'].find { |u| u['email'] == '$APP' }['id']")
runner orchestrator "Siberian::AuthClient.new.update_app_user('$DOMAIN', $ID, password: 'operator-set-pass-3')" >/dev/null
check "the new password works" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"email\":\"$APP\",\"password\":\"operator-set-pass-3\"}" "https://$DOMAIN/-/auth/sign-in")" "201"
check "the old one does not" \
  "$(a -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"email\":\"$APP\",\"password\":\"long-enough-1\"}" "https://$DOMAIN/-/auth/sign-in")" "401"

finish "core recovery"
