#!/bin/sh
# Signs in, then walks every Backoffice page with the resulting cookie. The
# cookie is scoped to .<domain>, so the same jar works on admin.<domain>.
B=http://127.0.0.1:8080
J=/tmp/bo_jar.txt
rm -f $J

TOKEN=$(curl -s -c $J -H "Host: siberian.localhost" $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
curl -s -b $J -c $J -o /dev/null -H "Host: siberian.localhost" -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=siberian-demo" $B/login
echo "signed in as operator"
echo

for path in / /modules /catalog /domains /interfaces /activity; do
  code=$(curl -s -b $J -o /tmp/page -w "%{http_code}" -H "Host: admin.siberian.localhost" "$B$path")
  title=$(grep -o '<title>[^<]*' /tmp/page | head -1 | sed 's/<title>//')
  printf "%-12s -> %s   %s\n" "$path" "$code" "$title"
done

echo
echo "catalogue entries visible:"
curl -s -b $J -H "Host: admin.siberian.localhost" $B/catalog | grep -oE 'Example (Notes|Mail Relay)' | sort -u | sed 's/^/   /'

echo
echo "review screen for example-relay:"
curl -s -b $J -H "Host: admin.siberian.localhost" $B/catalog/example-relay > /tmp/review
grep -oE 'mail.transport.v1|owner access to a new database \(deliveries\)|priority [0-9]+' /tmp/review | sort -u | sed 's/^/   /'

echo
echo "a non-operator:"
rm -f /tmp/u_jar.txt
T2=$(curl -s -c /tmp/u_jar.txt -H "Host: siberian.localhost" $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
curl -s -b /tmp/u_jar.txt -c /tmp/u_jar.txt -o /dev/null -H "Host: siberian.localhost" -X POST \
  --data-urlencode "authenticity_token=$T2" --data-urlencode "email=user@siberian.localhost" \
  --data-urlencode "password=siberian-demo" $B/login
echo "   GET / -> $(curl -s -b /tmp/u_jar.txt -o /tmp/nu -w '%{http_code}' -H 'Host: admin.siberian.localhost' $B/)   (expect 403)"
grep -oE 'not as an operator' /tmp/nu | head -1 | sed 's/^/   says: /'
