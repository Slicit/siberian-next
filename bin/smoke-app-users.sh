#!/bin/sh
# The people an app is for: one account, several devices, one domain.
#
# Asserts rather than narrates. Every check here is a property somebody could
# remove without any unit test noticing, because each of them only becomes true
# once the Router, Auth, the Backoffice and a module are all in the same
# request path.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
OTHER="${SIBERIAN_SECOND_DOMAIN:-siberian.localhost}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"

# Fresh addresses per run, so a second run is not a duplicate-email failure
# that reads as a broken feature.
STAMP=$(date +%s)
RIDER="rider-$STAMP@example.test"
FAILURES=0

J=/tmp/appuser_jar.txt
K=/tmp/appuser_op.txt
rm -f $J $K

a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }
op() { curl -s --cacert "$CA" -b $K -c $K "$@"; }

check() {
  if [ "$2" = "$3" ]; then
    printf '   ok    %s\n' "$1"
  else
    printf '   FAIL  %s (wanted %s, got %s)\n' "$1" "$3" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}

json() { sed "s/.*\"$1\":\"\([^\"]*\)\".*/\1/"; }

echo "signing in as the operator"
T=$(op "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
op -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

echo
echo "1. sign-up is closed until somebody opens it"
CODE=$(a -o /dev/null -w '%{http_code}' -X POST \
  -d "{\"email\":\"$RIDER\",\"password\":\"long-enough-1\"}" "https://$DOMAIN/-/auth/register")
check "a stranger cannot create an account" "$CODE" "403"

echo
echo "2. an operator creates one, through the Backoffice"
op -o /tmp/appuser_page -w '' "https://core.$DOMAIN/app-users"
# The link sits after the hostname in the row, not before. Getting this
# backwards silently creates the account on a different domain, which then
# looks like a broken sign-in rather than a wrong id.
ID=$(grep -A4 ">$DOMAIN<" /tmp/appuser_page | grep -oE 'app-users/[0-9]+' | head -1 | grep -oE '[0-9]+')
if [ -z "$ID" ]; then
  echo "   FAIL  could not find $DOMAIN on the app users page"
  exit 1
fi
op -o /tmp/appuser_page "https://core.$DOMAIN/app-users/$ID"
# The meta tag, not a form field. Per-form CSRF tokens are scoped to the
# action they were rendered for, so the first form on the page carries a token
# that is valid for that form and nothing else.
PAGE_TOKEN=$(grep -o 'name="csrf-token" content="[^"]*"' /tmp/appuser_page | head -1 | sed 's/.*content="//; s/"//')

check "the domain has an app users page" \
  "$(op -o /dev/null -w '%{http_code}' "https://core.$DOMAIN/app-users/$ID")" "200"

op -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$PAGE_TOKEN" \
  --data-urlencode "email=$RIDER" \
  --data-urlencode "name=Rider" \
  --data-urlencode "password=long-enough-1" \
  "https://core.$DOMAIN/app-users/$ID"

op -o /tmp/appuser_page "https://core.$DOMAIN/app-users/$ID"
if [ "$(grep -c "$RIDER" /tmp/appuser_page)" -ge 1 ]; then
  check "the account is listed for this domain" "listed" "listed"
else
  check "the account is listed for this domain" "absent" "listed"
fi

echo
echo "3. one account, two devices, one identity"
P=$(a -X POST -d "{\"email\":\"$RIDER\",\"password\":\"long-enough-1\",\"device_id\":\"phone-$STAMP\",\"device_name\":\"Pixel\",\"platform\":\"android\"}" "https://$DOMAIN/-/auth/sign-in")
L=$(a -X POST -d "{\"email\":\"$RIDER\",\"password\":\"long-enough-1\",\"device_id\":\"tablet-$STAMP\",\"device_name\":\"iPad\",\"platform\":\"ios\"}" "https://$DOMAIN/-/auth/sign-in")
PHONE=$(echo "$P" | json token)
TABLET=$(echo "$L" | json token)
PHONE_USER=$(echo "$P" | grep -o '"id":[0-9]*' | head -1)
TABLET_USER=$(echo "$L" | grep -o '"id":[0-9]*' | head -1)

check "both sign-ins are the same person" "$PHONE_USER" "$TABLET_USER"
[ "$PHONE" != "$TABLET" ] && check "each device holds its own token" "different" "different" \
  || check "each device holds its own token" "same" "different"

# Counted with -o rather than -c: the whole answer is one line, so a line
# count of a JSON array is always 1 and would pass with one device.
DEVICES=$(a -H "Authorization: Bearer $PHONE" "https://$DOMAIN/-/auth/devices" | grep -o '"platform"' | wc -l | tr -d ' ')
check "both devices are listed" "$DEVICES" "2"

echo
echo "4. ending one device leaves the other signed in"
TABLET_ID=$(a -H "Authorization: Bearer $PHONE" "https://$DOMAIN/-/auth/devices" \
  | tr '{' '\n' | grep '"iPad"' | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
a -o /dev/null -X DELETE -H "Authorization: Bearer $PHONE" "https://$DOMAIN/-/auth/devices/$TABLET_ID"

check "the tablet is out" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TABLET" "https://$DOMAIN/-/auth/me")" "401"
check "the phone is not" \
  "$(a -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PHONE" "https://$DOMAIN/-/auth/me")" "200"

echo
echo "5. the same address on another domain is somebody else"
SECOND=$(a -X POST -d "{\"email\":\"$RIDER\",\"password\":\"long-enough-1\"}" "https://$OTHER/-/auth/sign-in")
check "it is not the same account" \
  "$(echo "$SECOND" | grep -c 'do not match')" "1"

echo
echo "6. a module identifies them, and their data is their own"
rm -f $J
a -c $J -o /dev/null -X POST \
  -d "{\"email\":\"$RIDER\",\"password\":\"long-enough-1\",\"device_id\":\"phone-$STAMP\"}" \
  "https://$DOMAIN/-/auth/sign-in"
check "the sign-in leaves a cookie a WebView can carry" "$(grep -c siberian_session $J)" "1"
check "a module answers them" \
  "$(curl -s --cacert "$CA" -b $J -o /dev/null -w '%{http_code}' -H "Accept: application/json" \
     "https://$DOMAIN/m/demo-tasks/tasks.json")" "200"
check "and shows them nobody else's rows" \
  "$(curl -s --cacert "$CA" -b $J -H "Accept: application/json" "https://$DOMAIN/m/demo-tasks/tasks.json")" "[]"

echo
echo "7. an app account is not an operator"
check "the Backoffice refuses them" \
  "$(curl -s --cacert "$CA" -b $J -o /dev/null -w '%{http_code}' "https://core.$DOMAIN/modules")" "403"
check "the product does not" \
  "$(curl -s --cacert "$CA" -b $J -o /dev/null -w '%{http_code}' "https://$DOMAIN/")" "200"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "app users: every check passed"
else
  echo "app users: $FAILURES check(s) FAILED"
  exit 1
fi
