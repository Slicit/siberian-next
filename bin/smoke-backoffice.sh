#!/bin/sh
# Signs in, then walks every Backoffice page with the resulting cookie. The
# cookie is scoped to .<domain>, so the same jar works on core.<domain>.
#
# Over HTTPS through the Router, like every other smoke: the Backoffice has no
# plain HTTP door, and a session cookie that is not Secure never arrives.
#
# It used to print each page's status and title and exit zero either way, so a
# stack answering 500 everywhere produced a tidy table and a green night.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
J=/tmp/bo_jar.txt
rm -f $J

. "$(dirname "$0")/smoke-lib.sh"

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

echo "1. every page an operator may open"
for path in / /modules /catalog /domains /interfaces /activity; do
  check "$(printf '%-12s answers' "$path")" "$(fetch "https://core.$DOMAIN$path")" "200"
  # A Rails error page is also 200 in some configurations, and always has a
  # title. An empty title is the tell for a page that rendered nothing.
  present "$(printf '%-12s has a title' "$path")" \
    "$(grep -o '<title>[^<]*' /tmp/bo_page | head -1 | sed 's/<title>//' | tr -d ' \n')"
done

echo
echo "2. the catalogue lists what is on disk"
fetch "https://core.$DOMAIN/catalog" > /dev/null
for entry in Tasks Notes "Example Mail Relay"; do
  contains "$entry is offered" "$(cat /tmp/bo_page)" "$entry"
done

echo
echo "3. the review screen says what installing would approve"
fetch "https://core.$DOMAIN/catalog/example-relay" > /dev/null
# Everything a manifest asks for has to be visible before an operator says yes.
# This module asks for one interface and one database; a screen that showed the
# module and not its requests would be an approval nobody made.
contains "the interface it implements" "$(cat /tmp/bo_page)" "mail.transport.v1"
contains "the database it wants" "$(cat /tmp/bo_page)" "database"

echo
echo "4. somebody with no Backoffice access"
J=/tmp/bo_user_jar.txt
sign_in $J user@siberian.localhost
check "is refused" "$(fetch "https://core.$DOMAIN/")" "403"
contains "and told so in words" "$(cat /tmp/bo_page)" "cannot do that"

echo
echo "5. the menu, as rendered rather than as intended"
# Back to the operator: the section above signed in as somebody with no
# Backoffice access at all, and a menu on a refusal page is not a menu.
J=/tmp/bo_jar.txt
sign_in $J operator@siberian.localhost
fetch "https://core.$DOMAIN/" > /dev/null

# The unit tests check the menu data against the controllers. This checks the
# data reached the page, which is a different failure and one that has happened:
# a nav entry that exists and is never rendered. Roles is absent on purpose,
# because an operator does not hold core.roles.manage.
for item in Overview Modules Catalogue People Domains Storage "Phone apps" Interfaces Activity "App users"; do
  contains "$item is in the menu" "$(cat /tmp/bo_page)" ">$item</a>"
done
check "Roles is not, because an operator may not manage them" \
  "$(grep -c '>Roles</a>' /tmp/bo_page)" "0"

check "the page has a breadcrumb" "$(grep -c 'class="breadcrumb"' /tmp/bo_page)" "1"

finish "backoffice"
