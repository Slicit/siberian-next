#!/bin/sh
# Signs in the way a browser does: fetch the form, carry the CSRF token and the
# cookie jar, then post.
#
# Over HTTPS on the served domain, because the cookie this checks for is only
# issued Secure, and a Secure cookie does not survive plain HTTP.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
EMAIL="${SIBERIAN_DEMO_EMAIL:-operator@siberian.localhost}"
B="https://$DOMAIN"
J=/tmp/jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" "$@"; }

TOKEN=$(c -c $J $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
echo "1. the sign-in form"
present "it carries a CSRF token" "$TOKEN"

echo "2. signing in"
expect "   POST /login               " "$(c -b $J -c $J -o /tmp/out -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=$EMAIL" \
  --data-urlencode "password=$PASSWORD" \
  $B/login)" 302

echo "3. the cookie it left"
COOKIE=$(grep siberian_session $J || true)
present "a session cookie was set" "$COOKIE"
# The leading dot is what carries it into <module>.apps.<domain>, and Secure is
# what lets it travel at all. Both have broken before and neither is visible
# from a page that happens to render.
contains "scoped to every subdomain" "$COOKIE" ".$DOMAIN"
contains "marked Secure" "$COOKIE" "TRUE"

echo "4. what the cookie opens"
expect "   the Backoffice            " "$(c -b $J -o /dev/null -w '%{http_code}' https://core.$DOMAIN/)" 200

echo "5. and what it does not"
expect "   a wrong password          " "$(c -b $J -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$TOKEN" --data-urlencode "email=$EMAIL" \
  --data-urlencode "password=nope" $B/login)" 422

finish "auth"
