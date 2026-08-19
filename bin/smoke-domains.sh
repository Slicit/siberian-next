#!/bin/sh
# Adds a domain with a storage allowance, changes it, and removes it, all
# through the Backoffice over HTTPS.
#
# The point of the feature is the domain that has nothing stored on it yet: the
# Storage service knows a domain once a module writes to it, and an operator
# knows one the moment they add it. This drives the second case, which is the
# one that used to have nowhere to be configured.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
HOST="${SIBERIAN_SMOKE_DOMAIN:-quota-smoke.test}"
J=/tmp/dom_jar.txt
P=/tmp/dom_page
rm -f $J

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
echo "signed in as operator"

# A previous run may have left it behind. Same hostname every time, so the
# Storage service accumulates one row rather than one per run.
get "https://admin.$DOMAIN/domains" > /dev/null
ID=$(domain_id)
if [ -n "$ID" ]; then
  c -o /dev/null -X DELETE --data-urlencode "authenticity_token=$(token)" "https://admin.$DOMAIN/domains/$ID"
  echo "removed a leftover $HOST"
  get "https://admin.$DOMAIN/domains" > /dev/null
fi

echo
echo "1. add $HOST with 64 MB total and 8 MB per new bucket"
echo "   -> $(c -o /tmp/dom_add -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "domain[hostname]=$HOST" \
  --data-urlencode "domain[label]=Storage smoke" \
  --data-urlencode "quota_mb=64" \
  --data-urlencode "default_bucket_quota_mb=8" "https://admin.$DOMAIN/domains")   (expect 302)"

echo "2. the Domains page reads it back -> $(get "https://admin.$DOMAIN/domains")"
grep -oE "$HOST [^<]{0,80}" $P | head -1 | sed 's/^/   said: /'
grep -A25 ">$HOST<" $P | grep -oE 'of 64 MB|value="64"|value="8"' | sort -u | sed 's/^/   /'
ID=$(domain_id)

echo "3. Storage lists it with nothing stored on it -> $(get "https://admin.$DOMAIN/storage")"
grep -A10 ">$HOST<" $P | grep -oE '0 Bytes|of 64 MB|no ceiling' | head -2 | sed 's/^/   /'

echo "4. clear the ceiling"
get "https://admin.$DOMAIN/domains" > /dev/null
echo "   -> $(c -o /dev/null -w '%{http_code}' -X PATCH \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "quota_mb=" \
  --data-urlencode "default_bucket_quota_mb=" "https://admin.$DOMAIN/domains/$ID/storage")   (expect 302)"
get "https://admin.$DOMAIN/domains" > /dev/null
grep -oE "$HOST: [^<]{0,60}" $P | head -1 | sed 's/^/   said: /'

echo "5. remove the domain -> $(c -o /dev/null -w '%{http_code}' -X DELETE \
  --data-urlencode "authenticity_token=$(token)" "https://admin.$DOMAIN/domains/$ID")   (expect 302)"

echo "6. its storage row outlives it, and says so -> $(get "https://admin.$DOMAIN/storage")"
grep -A2 ">$HOST<" $P | grep -oE 'no longer served' | head -1 | sed 's/^/   /'
