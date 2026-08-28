#!/bin/sh
# Drives the reconciler through the Backoffice, and checks the thing it exists
# for: that a module the Mobile service has been made to forget comes back.
#
# The interesting assertion is not that the button returns 200. It is that the
# Mobile service's own inventory changes as a result, because the bug this
# feature closes was a module being absent from every phone app while every
# page in the Backoffice said it was installed.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
J=/tmp/rec_jar.txt
P=/tmp/rec_page
rm -f $J

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

get() {
  rm -f $P
  c -o $P -w "%{http_code}" "$1"
}

token() { grep -o 'name="csrf-token" content="[^"]*"' $P | head -1 | sed 's/.*content="//; s/"//'; }

# The Mobile service's own view, not the Backoffice's opinion of it.
mobile_knows() {
  $COMPOSE exec -T mobile bin/rails runner \
    "print ModuleRegistration.live.where(module_name: '$1').count" 2>/dev/null
}

fail() { echo "FAIL: $1"; exit 1; }

T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"
echo "1. signed in as operator"

# Any installed module will do. Picking one from the page rather than naming a
# module keeps this working when the reference set changes.
code=$(get "https://core.$DOMAIN/modules")
[ "$code" = "200" ] || fail "the modules page answered $code"
SUBJECT=$(grep -oE 'href="/modules/[a-z0-9-]+"' $P | head -1 | sed 's|.*/modules/||; s|"||')
[ -n "$SUBJECT" ] || fail "no installed module to reconcile against"
echo "2. subject module              -> $SUBJECT"

before=$(mobile_knows "$SUBJECT")
[ "$before" = "1" ] || fail "the Mobile service does not know $SUBJECT to begin with (got '$before')"
echo "3. Mobile knows it             -> yes"

# The drift this repairs, produced deliberately rather than waited for.
$COMPOSE exec -T mobile bin/rails runner \
  "ModuleRegistration.where(module_name: '$SUBJECT').update_all(revoked_at: Time.current)" >/dev/null 2>&1
gone=$(mobile_knows "$SUBJECT")
[ "$gone" = "0" ] || fail "could not make the Mobile service forget $SUBJECT"
echo "4. made Mobile forget it       -> gone"

code=$(get "https://core.$DOMAIN/modules")
CSRF=$(token)
status=$(c -o /dev/null -w "%{http_code}" -X POST \
  -H "X-CSRF-Token: $CSRF" \
  -e "https://core.$DOMAIN/modules" \
  "https://core.$DOMAIN/state/reconcile")
echo "5. POST /state/reconcile       -> $status   (expect 302)"
[ "$status" = "302" ] || fail "reconcile answered $status"

after=$(mobile_knows "$SUBJECT")
echo "6. Mobile knows it again       -> $([ "$after" = "1" ] && echo yes || echo "no ($after)")"
[ "$after" = "1" ] || fail "reconciling did not restore the registration"

# Running it again must be free, which is what makes it safe on a button.
status=$(c -o /dev/null -w "%{http_code}" -X POST \
  -H "X-CSRF-Token: $CSRF" \
  -e "https://core.$DOMAIN/modules" \
  "https://core.$DOMAIN/state/reconcile")
echo "7. reconciling again           -> $status   (expect 302)"
[ "$status" = "302" ] || fail "the second reconcile answered $status"

still=$(mobile_knows "$SUBJECT")
[ "$still" = "1" ] || fail "the second reconcile undid the first"
echo "8. still registered            -> yes"

echo
echo "the reconciler restored a registration the Mobile service had lost, twice over."
