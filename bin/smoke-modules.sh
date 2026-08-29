#!/bin/sh
# Drives both reference modules end to end, over HTTPS, through the Router.
#
# One is PHP and one is Python. Neither imports the same SDK as the other. If
# this passes, the module contract works in two languages at once, which is the
# claim the whole container boundary rests on.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
EMAIL="${SIBERIAN_DEMO_EMAIL:-operator@siberian.localhost}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
JAR=/tmp/siberian_modules_jar.txt

. "$(dirname "$0")/smoke-lib.sh"

rm -f "$JAR"
c() { curl -s --cacert "$CA" -b "$JAR" "$@"; }

TOKEN=$(curl -s --cacert "$CA" -c "$JAR" "https://$DOMAIN/login" \
  | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
curl -s --cacert "$CA" -b "$JAR" -c "$JAR" -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=$EMAIL" --data-urlencode "password=$PASSWORD" \
  "https://$DOMAIN/login"

NOTES="https://notes.apps.$DOMAIN"
TASKS="https://tasks.apps.$DOMAIN"

echo "--- Notes (PHP): markdown CRUD ---"
expect "list             " "$(c -o /tmp/sm_n -w '%{http_code}' "$NOTES/")" 200
expect "create           " "$(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode 'title=Smoke note' \
  --data-urlencode 'body=# Heading

**bold** and `code`

- one
- two' "$NOTES/notes")" 302

c -o /tmp/sm_n2 "$NOTES/"
NID=$(grep -oE 'href="/notes/[0-9]+"' /tmp/sm_n2 | head -1 | grep -oE '[0-9]+')
present "the new note is listed" "$NID"
expect "read             " "$(c -o /tmp/sm_n3 -w '%{http_code}' "$NOTES/notes/$NID")" 200

# Markdown is the module's own job, and the whole reason it carries a library.
# Counting the elements rather than printing them, because "rendered nothing" is
# what a broken converter looks like and it reads the same as a blank line.
RENDERED=$(grep -oE '<h1>Heading</h1>|<strong>bold</strong>|<code>code</code>|<li>one</li>' /tmp/sm_n3 | wc -l | tr -d ' ')
check "markdown rendered, all four elements" "$RENDERED" "4"

expect "update           " "$(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode 'title=Updated note' --data-urlencode 'body=## Subheading' "$NOTES/notes/$NID/update")" 302
c -o /tmp/sm_n5 "$NOTES/notes/$NID"
contains "the update is visible" "$(cat /tmp/sm_n5)" "Subheading"

expect "confirm delete   " "$(c -o /tmp/sm_n4 -w '%{http_code}' "$NOTES/notes/$NID/delete")" 200
contains "it asks before deleting" "$(cat /tmp/sm_n4)" "no undo"
expect "delete           " "$(c -o /dev/null -w '%{http_code}' -X POST "$NOTES/notes/$NID/delete")" 302

# A markdown field that renders raw HTML is a cross-site scripting hole with a
# nice name, so the escaping is checked rather than described.
c -o /dev/null -X POST --data-urlencode 'title=XSS' \
  --data-urlencode 'body=<script>alert(1)</script> [link](javascript:alert(2))' "$NOTES/notes" >/dev/null
c -o /tmp/sm_x "$NOTES/"
XID=$(grep -oE 'href="/notes/[0-9]+"' /tmp/sm_x | head -1 | grep -oE '[0-9]+')
c -o /tmp/sm_x2 "$NOTES/notes/$XID"
check "no raw script tag survives" "$(grep -c '<script>alert' /tmp/sm_x2)" "0"
check "no javascript: href survives" "$(grep -oE 'href="javascript' /tmp/sm_x2 | wc -l | tr -d ' ')" "0"
c -o /dev/null -X POST "$NOTES/notes/$XID/delete"

echo
echo "--- Tasks (Python): archive, attach, delete ---"
expect "add              " "$(c -o /dev/null -w '%{http_code}' -X POST --data-urlencode 'title=Smoke task' "$TASKS/tasks")" 302
c -o /tmp/sm_t "$TASKS/"
TID=$(grep -oE '/tasks/[0-9]+/archive' /tmp/sm_t | head -1 | grep -oE '[0-9]+')
present "the new task is listed" "$TID"

echo "smoke attachment" > /tmp/sm_attach.txt
expect "attach           " "$(c -o /dev/null -w '%{http_code}' -F "file=@/tmp/sm_attach.txt" "$TASKS/tasks/$TID/attach")" 302
c -o /tmp/sm_ta "$TASKS/"
contains "the attachment is named on the row" "$(cat /tmp/sm_ta)" "sm_attach"

expect "archive          " "$(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/archive")" 302
c -o /tmp/sm_t2 "$TASKS/?archived=1"
check "it moved to the archived list" "$(grep -c 'Smoke task' /tmp/sm_t2)" "1"
c -o /tmp/sm_t2b "$TASKS/"
check "and left the open one" "$(grep -c 'Smoke task' /tmp/sm_t2b)" "0"

expect "restore          " "$(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/unarchive")" 302
expect "confirm delete   " "$(c -o /tmp/sm_t3 -w '%{http_code}' "$TASKS/tasks/$TID/delete")" 200
contains "it asks before deleting" "$(cat /tmp/sm_t3)" "no undo"
expect "delete           " "$(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/delete")" 302

finish "modules"
