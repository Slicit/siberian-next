#!/bin/sh
# Proves the access model does what it claims, against the running stack.
#
# Three claims worth checking, and none of them is testable in a unit test:
# every page agrees with the permission set, a per-module deny is surgical, and
# a withdrawn permission actually stops working within the stated window.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
ADMIN="Authorization: Bearer ${SIBERIAN_ADMIN_TOKEN:-orchestrator_dev_only}"

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

echo "--- Backoffice, by role ---"
printf "%-12s %-8s %-9s %-6s\n" page owner operator user
for path in / /modules /catalog /people /roles /domains /activity; do
  printf "%-12s " "$path"
  for who in owner operator user; do printf "%-9s" "$(code "$who" "https://core.$DOMAIN$path")"; done
  echo
done

echo
echo "--- The product ---"
printf "%-26s %-8s %-9s %-6s\n" page owner operator user
for path in / /m/demo_tasks-task-list /m/example_notes-note-viewer; do
  printf "%-26s " "$path"
  for who in owner operator user; do printf "%-9s" "$(code "$who" "https://$DOMAIN$path")"; done
  echo
done

echo
echo "--- A per-module deny is surgical ---"
person=$(api -H "$ADMIN" http://auth:3000/internal/users \
  | tr '{' '\n' | grep 'user@siberian.localhost' | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)

api -o /dev/null -X POST -H "$ADMIN" -H "Content-Type: application/json" \
  -d '{"permission":"module.demo-tasks.use","effect":"deny","reason":"smoke test"}' \
  "http://auth:3000/internal/users/$person/grants" >/dev/null

echo "denied module.demo-tasks.use for the member, waiting out the cache..."
sleep 32

echo "  tasks  -> $(code user "https://$DOMAIN/m/demo_tasks-task-list")   (expect 403)"
grep -oE 'module.demo-tasks.use' /tmp/access_page | head -1 | sed 's/^/  refusal names: /'
echo "  notes  -> $(code user "https://$DOMAIN/m/example_notes-note-viewer")   (expect 200, the deny was surgical)"

api -o /dev/null -X DELETE -H "$ADMIN" \
  "http://auth:3000/internal/users/$person/grants?permission=module.demo-tasks.use&effect=deny" >/dev/null
echo "grant withdrawn"
