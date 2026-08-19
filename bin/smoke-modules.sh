#!/bin/sh
# Drives both reference modules end to end, over HTTPS, through the Router.
#
# One is PHP and one is Python. Neither imports an SDK. If this passes, the
# module contract works in two languages at once, which is the claim the whole
# container boundary rests on.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
EMAIL="${SIBERIAN_DEMO_EMAIL:-operator@siberian.localhost}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
JAR=/tmp/siberian_modules_jar.txt

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
echo "list             -> $(c -o /tmp/sm_n -w '%{http_code}' "$NOTES/")"
echo "create           -> $(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode 'title=Smoke note' \
  --data-urlencode 'body=# Heading

**bold** and `code`

- one
- two' "$NOTES/notes")"

c -o /tmp/sm_n2 "$NOTES/"
NID=$(grep -oE 'href="/notes/[0-9]+"' /tmp/sm_n2 | head -1 | grep -oE '[0-9]+')
echo "read             -> $(c -o /tmp/sm_n3 -w '%{http_code}' "$NOTES/notes/$NID")"
echo "   markdown:      $(grep -oE '<h1>Heading</h1>|<strong>bold</strong>|<code>code</code>|<li>one</li>' /tmp/sm_n3 | tr '\n' ' ')"
echo "update           -> $(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode 'title=Updated note' --data-urlencode 'body=## Subheading' "$NOTES/notes/$NID/update")"
echo "confirm delete   -> $(c -o /tmp/sm_n4 -w '%{http_code}' "$NOTES/notes/$NID/delete")"
echo "   says:          $(grep -oE 'Delete this note|no undo' /tmp/sm_n4 | tr '\n' ' ')"
echo "delete           -> $(c -o /dev/null -w '%{http_code}' -X POST "$NOTES/notes/$NID/delete")"

# A markdown field that renders raw HTML is a cross-site scripting hole with a
# nice name, so the escaping is worth a check rather than a comment.
c -o /dev/null -X POST --data-urlencode 'title=XSS' \
  --data-urlencode 'body=<script>alert(1)</script> [link](javascript:alert(2))' "$NOTES/notes" >/dev/null
c -o /tmp/sm_x "$NOTES/"
XID=$(grep -oE 'href="/notes/[0-9]+"' /tmp/sm_x | head -1 | grep -oE '[0-9]+')
c -o /tmp/sm_x2 "$NOTES/notes/$XID"
echo "raw script tags  -> $(grep -c '<script>alert' /tmp/sm_x2)  (expect 0)"
echo "javascript: href -> $(grep -oE 'href="javascript' /tmp/sm_x2 | wc -l | tr -d ' ')  (expect 0)"
c -o /dev/null -X POST "$NOTES/notes/$XID/delete"

echo
echo "--- Tasks (Python): archive and delete ---"
echo "add              -> $(c -o /dev/null -w '%{http_code}' -X POST --data-urlencode 'title=Smoke task' "$TASKS/tasks")"
c -o /tmp/sm_t "$TASKS/"
TID=$(grep -oE '/tasks/[0-9]+/archive' /tmp/sm_t | head -1 | grep -oE '[0-9]+')
echo "smoke attachment" > /tmp/sm_attach.txt
echo "attach           -> $(c -o /dev/null -w '%{http_code}' -X POST -F "file=@/tmp/sm_attach.txt" "$TASKS/tasks/$TID/attach")"
echo "archive          -> $(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/archive")"
c -o /tmp/sm_t2 "$TASKS/?archived=1"
echo "   archived tab:  $(grep -c 'Smoke task' /tmp/sm_t2) entry"
echo "restore          -> $(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/unarchive")"
echo "confirm delete   -> $(c -o /tmp/sm_t3 -w '%{http_code}' "$TASKS/tasks/$TID/delete")"
echo "   says:          $(grep -oE 'Delete this task|no undo|Archive instead|deleted from storage' /tmp/sm_t3 | tr '\n' ' ')"
echo "delete           -> $(c -o /dev/null -w '%{http_code}' -X POST "$TASKS/tasks/$TID/delete")"
