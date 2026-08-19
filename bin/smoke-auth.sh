#!/bin/sh
# Signs in the way a browser does: fetch the form, carry the CSRF token and the
# cookie jar, then post.
H="Host: siberian.localhost"
B=http://127.0.0.1:8080
J=/tmp/jar.txt
rm -f $J

TOKEN=$(curl -s -c $J -H "$H" $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
echo "1. got a CSRF token           -> ${#TOKEN} chars"

STATUS=$(curl -s -b $J -c $J -o /tmp/out -w "%{http_code}" -H "$H" -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=siberian-demo" \
  $B/login)
echo "2. POST /login                -> $STATUS   (expect 302)"

echo "3. cookie scope"
grep siberian_session $J | awk '{print "   domain=" $1 "  name=" $6}'

SESSION=$(grep siberian_session $J | awk '{print $7}')

echo "5. wrong password             -> $(curl -s -b $J -o /dev/null -w '%{http_code}' -H "$H" -X POST --data-urlencode "authenticity_token=$TOKEN" --data-urlencode "email=operator@siberian.localhost" --data-urlencode "password=nope" $B/login)   (expect 422)"
