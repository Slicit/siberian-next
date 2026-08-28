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

# Followed, because the module no longer serves this itself: it checks that the
# task belongs to whoever is asking and then sends them to the object store with
# a URL that reaches one object and expires. The redirect is the visible part of
# the module having stopped copying bytes through its own process, and the
# content check is what proves the redirect actually leads somewhere.
rm -f /tmp/sib_back
code=$(c -b "$JAR" -o /dev/null -w '%{http_code}' "https://tasks.apps.$DOMAIN/tasks/$ID/file")
echo "read it back     -> $code   (expect 302, the module hands out an address)"
code=$(c -L -b "$JAR" -o /tmp/sib_back -w '%{http_code}' "https://tasks.apps.$DOMAIN/tasks/$ID/file")
echo "   following it  -> $code"
echo "   content: $(cat /tmp/sib_back)"
grep -q "smoke attachment" /tmp/sib_back \
  || { echo "   FAIL: the signed URL did not lead to the file"; exit 1; }

# The menu is on every page, and it was not: the phone app page loaded without
# it and every module vanished from the shell with nothing reporting a thing.
# Checked on a page that is not the overview, because the overview was always
# the one that worked.
echo
echo "the shell menu, on a page that is not the overview:"
for path in "/" "/app" "/m/demo_tasks-task-list"; do
  c -b "$JAR" -o /tmp/sib_menu "https://$DOMAIN$path"
  found=$(grep -oE '<span class="grow">[^<]+' /tmp/sib_menu | sed 's|<span class="grow">||' | sort | tr '\n' ' ')
  printf "   %-26s %s\n" "$path" "${found:-NOTHING}"
done
