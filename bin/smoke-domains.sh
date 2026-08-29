#!/bin/sh
# Adds a domain with a storage allowance, changes it, and removes it, all
# through the Backoffice over HTTPS.
#
# The point of the feature is the domain that has nothing stored on it yet: the
# Storage service knows a domain once a module writes to it, and an operator
# knows one the moment they add it. This drives the second case, which is the
# one that used to have nowhere to be configured.
#
# It used to grep for the phrases it hoped to find and print whatever it got,
# so a page that had stopped showing an allowance at all printed nothing and
# passed.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
HOST="${SIBERIAN_SMOKE_DOMAIN:-quota-smoke.test}"
J=/tmp/dom_jar.txt
P=/tmp/dom_page
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

# Fresh file every time. A request that never lands must not be reported on
# with the page the previous one left behind.
get() {
  rm -f $P
  c -o $P -w "%{http_code}" "$1"
}

# Rails masks the token per session, so it has to come from the page the form
# was rendered on, with the session cookie that rendered it.
token() { grep -o 'name="csrf-token" content="[^"]*"' $P | head -1 | sed 's/.*content="//; s/"//'; }

domain_id() { grep -A25 ">$HOST<" $P | grep -oE 'domains/[0-9]+/storage' | head -1 | grep -oE '[0-9]+'; }

rm -f $J
T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

# A previous run may have left it behind. Same hostname every time, so the
# Storage service accumulates one row rather than one per run.
get "https://core.$DOMAIN/domains" > /dev/null
ID=$(domain_id)
if [ -n "$ID" ]; then
  c -o /dev/null -X DELETE --data-urlencode "authenticity_token=$(token)" "https://core.$DOMAIN/domains/$ID"
  echo "removed a leftover $HOST"
  get "https://core.$DOMAIN/domains" > /dev/null
fi

echo "1. add $HOST with 64 MB total and 8 MB per new bucket"
expect "   created                   " "$(c -o /tmp/dom_add -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "domain[hostname]=$HOST" \
  --data-urlencode "domain[label]=Storage smoke" \
  --data-urlencode "quota_mb=64" \
  --data-urlencode "default_bucket_quota_mb=8" "https://core.$DOMAIN/domains")" 302

echo "2. the Domains page reads it back"
check "the page answers" "$(get "https://core.$DOMAIN/domains")" "200"
contains "the domain is listed" "$(cat $P)" ">$HOST<"
ROW=$(grep -A25 ">$HOST<" $P)
# Both numbers, not either: the domain ceiling and the per bucket default are
# separate settings and each has been silently dropped on the way in before.
contains "the 64 MB ceiling came back" "$ROW" 'value="64"'
contains "the 8 MB bucket default came back" "$ROW" 'value="8"'
ID=$(domain_id)
present "the row carries an id" "$ID"

echo "3. Storage knows it before anything is stored"
check "the Storage page answers" "$(get "https://core.$DOMAIN/storage")" "200"
contains "the new domain is on it" "$(cat $P)" ">$HOST<"
contains "with its ceiling" "$(grep -A10 ">$HOST<" $P)" "64 MB"

echo "4. the ceiling can be cleared"
get "https://core.$DOMAIN/domains" > /dev/null
expect "   cleared                   " "$(c -o /dev/null -w '%{http_code}' -X PATCH \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "quota_mb=" \
  --data-urlencode "default_bucket_quota_mb=" "https://core.$DOMAIN/domains/$ID/storage")" 302
get "https://core.$DOMAIN/domains" > /dev/null
check "the 64 MB ceiling is gone" "$(grep -A25 ">$HOST<" $P | grep -c 'value="64"')" "0"

echo "5. removing the domain"
expect "   removed                   " "$(c -o /dev/null -w '%{http_code}' -X DELETE \
  --data-urlencode "authenticity_token=$(token)" "https://core.$DOMAIN/domains/$ID")" 302
get "https://core.$DOMAIN/domains" > /dev/null
check "it is off the Domains page" "$(grep -c ">$HOST<" $P)" "0"

echo "6. but its storage row outlives it"
# Deliberate: bytes that exist have to be attributable to somebody even after
# nobody is serving the domain they were written for.
check "the Storage page answers" "$(get "https://core.$DOMAIN/storage")" "200"
contains "the domain is still accounted for" "$(cat $P)" ">$HOST<"
contains "and says it is no longer served" "$(grep -A3 ">$HOST<" $P)" "no longer served"

finish "domains"
