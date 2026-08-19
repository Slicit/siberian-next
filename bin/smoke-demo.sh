#!/bin/sh
# Drives the demo module the way a person would: over HTTPS, through the
# Router, with a real session cookie.
#
# Proves the parts no unit test reaches: the cookie is issued Secure and scoped
# to the parent domain, so it travels into a module frame on another origin;
# the module identifies the user through the core; and its own database and the
# storage service are both reachable from inside it.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
EMAIL="${SIBERIAN_DEMO_EMAIL:-operator@siberian.localhost}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
JAR=/tmp/siberian_demo_jar.txt

rm -f "$JAR"
c() { curl -s --cacert "$CA" "$@"; }

TOKEN=$(c -c "$JAR" "https://$DOMAIN/login" \
  | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')

c -b "$JAR" -c "$JAR" -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=$EMAIL" \
  --data-urlencode "password=$PASSWORD" \
  "https://$DOMAIN/login"

echo "session cookie:"
grep siberian_session "$JAR" | awk '{print "   domain=" $1 "  secure=" $4}'

echo "shell            -> $(c -b "$JAR" -o /tmp/sib_shell -w '%{http_code}' "https://$DOMAIN/")"
grep -oE '>Tasks<|>Notes<' /tmp/sib_shell | sort -u | sed 's/^/   /'

echo "framed page      -> $(c -b "$JAR" -o /tmp/sib_frame -w '%{http_code}' "https://$DOMAIN/m/demo_tasks-task-list")"
grep -oE "https://tasks.apps.$DOMAIN/" /tmp/sib_frame | head -1 | sed 's/^/   iframe src: /'

echo "module direct    -> $(c -b "$JAR" -o /tmp/sib_mod -w '%{http_code}' "https://tasks.apps.$DOMAIN/")"
grep -oE 'written in Python|Nothing yet' /tmp/sib_mod | sort -u | sed 's/^/   /'

echo "add a task       -> $(c -b "$JAR" -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode 'title=Smoke test task' "https://tasks.apps.$DOMAIN/tasks")"

c -b "$JAR" -o /tmp/sib_mod2 "https://tasks.apps.$DOMAIN/"
ID=$(grep -oE '/tasks/[0-9]+/toggle' /tmp/sib_mod2 | head -1 | grep -oE '[0-9]+')

echo "toggle it        -> $(c -b "$JAR" -o /dev/null -w '%{http_code}' -X POST \
  "https://tasks.apps.$DOMAIN/tasks/$ID/toggle")"

echo "smoke attachment" > /tmp/sib_attach.txt
echo "attach a file    -> $(c -b "$JAR" -o /dev/null -w '%{http_code}' -X POST \
  -F "file=@/tmp/sib_attach.txt" "https://tasks.apps.$DOMAIN/tasks/$ID/attach")"

echo "read it back     -> $(c -b "$JAR" -o /tmp/sib_back -w '%{http_code}' \
  "https://tasks.apps.$DOMAIN/tasks/$ID/file")"
echo "   content: $(cat /tmp/sib_back)"
