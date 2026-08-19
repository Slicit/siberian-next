#!/bin/sh
# Signs in, then walks every Backoffice page with the resulting cookie. The
# cookie is scoped to .<domain>, so the same jar works on core.<domain>.
#
# Over HTTPS through the Router, like every other smoke: the Backoffice has no
# plain HTTP door, and a session cookie that is not Secure never arrives.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
J=/tmp/bo_jar.txt
rm -f $J

c() { curl -s --cacert "$CA" "$@"; }

# Every fetch writes to a fresh file. A curl that never connects leaves the
# previous run's page behind otherwise, and the greps below then report on a
# stack that is not answering at all.
fetch() {
  rm -f /tmp/bo_page
  c -b $J -o /tmp/bo_page -w "%{http_code}" "$1"
}

sign_in() {
  jar=$1
  email=$2
  rm -f "$jar"
  token=$(c -c "$jar" "https://$DOMAIN/login" \
    | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
  c -b "$jar" -c "$jar" -o /dev/null -X POST \
    --data-urlencode "authenticity_token=$token" \
    --data-urlencode "email=$email" \
    --data-urlencode "password=$PASSWORD" \
    "https://$DOMAIN/login"
}

sign_in $J operator@siberian.localhost
echo "signed in as operator"
echo

for path in / /modules /catalog /domains /interfaces /activity; do
  code=$(fetch "https://core.$DOMAIN$path")
  title=$(grep -o '<title>[^<]*' /tmp/bo_page | head -1 | sed 's/<title>//')
  printf "%-12s -> %s   %s\n" "$path" "$code" "$title"
done

echo
echo "catalogue entries visible:"
fetch "https://core.$DOMAIN/catalog" > /dev/null
grep -oE '>(Tasks|Notes|Example Mail Relay)<' /tmp/bo_page | tr -d '<>' | sort -u | sed 's/^/   /'

echo
echo "review screen for example-relay:"
fetch "https://core.$DOMAIN/catalog/example-relay" > /dev/null
grep -oE 'mail.transport.v1|owner access to a new database \(deliveries\)|priority [0-9]+' /tmp/bo_page \
  | sort -u | sed 's/^/   /'

echo
echo "a non-operator:"
J=/tmp/bo_user_jar.txt
sign_in $J user@siberian.localhost
echo "   GET / -> $(fetch "https://core.$DOMAIN/")   (expect 403)"
grep -oE 'You cannot do that' /tmp/bo_page | head -1 | sed 's/^/   says: /'

echo
echo "the menu, as rendered rather than as intended:"
get "https://core.$DOMAIN/" > /dev/null
# The unit tests check the menu data against the controllers. This checks that
# the data reached the page at all, which is a different failure and one that
# has happened: a nav entry that exists and is never rendered.
grep -oE '>(Overview|Modules|Catalogue|People|Roles|Domains|Storage|Phone apps|Interfaces|Activity)</a>' $P \
  | sed 's/>//; s|</a>||' | sort | tr '\n' ' ' | sed 's/^/   operator sees: /'
echo
echo "   breadcrumb: $(grep -c 'class="breadcrumb"' $P) on the page"
