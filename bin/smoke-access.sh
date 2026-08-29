#!/bin/sh
# Proves the access model does what it claims, against the running stack.
#
# Three claims, none testable in a unit test: every page agrees with the
# permission set, a per-module deny is surgical, and a withdrawn permission
# actually stops working inside the stated window.
#
# It used to print a matrix of status codes with no statement of what they
# should be, which meant a page that had quietly stopped checking anything
# printed 200 and read as correct.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
ADMIN="Authorization: Bearer ${SIBERIAN_TOKEN_ORCHESTRATOR_AUTH:-dev_orchestrator_to_auth}"

. "$(dirname "$0")/smoke-lib.sh"

login() {
  jar="/tmp/access_$1.txt"
  rm -f "$jar"
  token=$(curl -s --cacert "$CA" -c "$jar" "https://$DOMAIN/login" \
    | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
  curl -s --cacert "$CA" -b "$jar" -c "$jar" -o /dev/null -X POST \
    --data-urlencode "authenticity_token=$token" \
    --data-urlencode "email=$1@siberian.localhost" \
    --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"
}

code() { curl -s --cacert "$CA" -b "/tmp/access_$1.txt" -o /tmp/access_page -w '%{http_code}' "$2"; }
api() { docker run --rm --network siberian_core curlimages/curl:latest -s "$@"; }

for who in owner operator user; do login "$who"; done

# The expectation, written from the seeded roles and the `requires` line on each
# controller rather than from a previous run's output. Owner holds `*`. Operator
# holds core.modules.*, domains, storage, mobile, audit and users.read, but not
# roles.manage. A member holds app.use and module.*.use and nothing in the core.
#
#   path  owner operator user
echo "--- The Backoffice, by role ---"
for row in \
  "/:200:200:403" \
  "/modules:200:200:403" \
  "/catalog:200:200:403" \
  "/people:200:200:403" \
  "/roles:200:403:403" \
  "/domains:200:200:403" \
  "/activity:200:200:403"
do
  path=$(echo "$row" | cut -d: -f1)
  i=2
  for who in owner operator user; do
    wanted=$(echo "$row" | cut -d: -f$i)
    check "$(printf '%-10s %-9s' "$path" "$who")" "$(code "$who" "https://core.$DOMAIN$path")" "$wanted"
    i=$((i + 1))
  done
done

echo
echo "--- The product, which every role may use ---"
for path in / /m/demo_tasks-task-list /m/example_notes-note-viewer; do
  for who in owner operator user; do
    check "$(printf '%-30s %-9s' "$path" "$who")" "$(code "$who" "https://$DOMAIN$path")" 200
  done
done

echo
echo "--- A per-module deny is surgical ---"
person=$(api -H "$ADMIN" http://auth:3000/internal/users \
  | tr '{' '\n' | grep 'user@siberian.localhost' | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)
present "found the member to deny" "$person"

api -o /dev/null -X POST -H "$ADMIN" -H "Content-Type: application/json" \
  -d '{"permission":"module.demo-tasks.use","effect":"deny","reason":"smoke test"}' \
  "http://auth:3000/internal/users/$person/grants" >/dev/null

# The stated ceiling is 30 seconds. Waiting longer than that is the check: a
# deny that needs a sign-out to take effect is a different product promise.
echo "denied module.demo-tasks.use, waiting out the 30 second cache..."
sleep 32

check "the denied module is refused" "$(code user "https://$DOMAIN/m/demo_tasks-task-list")" "403"
contains "the refusal names the permission" "$(cat /tmp/access_page)" "module.demo-tasks.use"
check "the other module still opens" "$(code user "https://$DOMAIN/m/example_notes-note-viewer")" "200"

api -o /dev/null -X DELETE -H "$ADMIN" \
  "http://auth:3000/internal/users/$person/grants?permission=module.demo-tasks.use&effect=deny" >/dev/null
sleep 32
check "and works again once the deny is withdrawn" \
  "$(code user "https://$DOMAIN/m/demo_tasks-task-list")" "200"

finish "access"
