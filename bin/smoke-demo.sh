#!/bin/sh
# Drives the demo module the way a person would, through the Router, with a
# real session cookie. Proves the module contract end to end: auth, its own
# database, a granted core table, and storage.
J=/tmp/demo_jar.txt
B=http://127.0.0.1:8080
rm -f $J

TOKEN=$(curl -s -c $J -H "Host: siberian.localhost" $B/login | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
curl -s -b $J -c $J -o /dev/null -H "Host: siberian.localhost" -X POST \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=siberian-demo" $B/login

H="Host: tasks.apps.siberian.localhost"
echo "shell lists the module    -> $(curl -s -b $J -H 'Host: siberian.localhost' $B/ | grep -c '>Tasks<') entry"
echo "module renders            -> $(curl -s -b $J -o /tmp/m -w '%{http_code}' -H "$H" $B/)"
grep -oE 'Ophelia Operator|written in Python' /tmp/m | sort -u | sed 's/^/   /'
echo "add a task                -> $(curl -s -b $J -o /dev/null -w '%{http_code}' -X POST -H "$H" --data-urlencode 'title=Smoke test task' $B/tasks)"
curl -s -b $J -H "$H" $B/ > /tmp/m2
ID=$(grep -oE '/tasks/[0-9]+/toggle' /tmp/m2 | head -1 | grep -oE '[0-9]+')
echo "toggle it                 -> $(curl -s -b $J -o /dev/null -w '%{http_code}' -X POST -H "$H" $B/tasks/$ID/toggle)"
echo "smoke attachment" > /tmp/smoke.txt
echo "attach a file             -> $(curl -s -b $J -o /dev/null -w '%{http_code}' -X POST -H "$H" -F 'file=@/tmp/smoke.txt' $B/tasks/$ID/attach)"
echo "read it back              -> $(curl -s -b $J -o /tmp/back -w '%{http_code}' -H "$H" $B/tasks/$ID/file)"
echo "   content: $(cat /tmp/back)"
