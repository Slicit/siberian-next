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

c() { curl -s --cacert "$CA" "$@"; }

TOKEN=$(c -c $J $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
echo "1. got a CSRF token           -> ${#TOKEN} chars"

STATUS=$(c -b $J -c $J -o /tmp/out -w "%{http_code}" -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=$EMAIL" \
  --data-urlencode "password=$PASSWORD" \
  $B/login)
echo "2. POST /login                -> $STATUS   (expect 302)"

echo "3. cookie scope"
grep siberian_session $J | awk '{print "   domain=" $1 "  secure=" $4 "  name=" $6}'

echo "4. the Backoffice takes the same cookie -> $(c -b $J -o /dev/null -w '%{http_code}' https://core.$DOMAIN/)   (expect 200)"

echo "5. wrong password             -> $(c -b $J -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$TOKEN" --data-urlencode "email=$EMAIL" \
  --data-urlencode "password=nope" $B/login)   (expect 422)"
