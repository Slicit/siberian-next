#!/bin/sh
S=http://storage:3000
A="Authorization: Bearer orchestrator_dev_only"
D="X-Siberian-Domain: siberian.test"
q() { curl -s -o /tmp/qb -w "%{http_code}" "$@"; }
NAME="quota-$(date +%s)"

echo "1. set the default to 1 MB   -> $(q -X PATCH "$S/admin/quotas" -H "$A" -H "Content-Type: application/json" -d '{"default_bucket_quota_mb":1}')"
echo "2. cap the domain at 2 MB    -> $(q -X PATCH "$S/admin/quotas/domains/siberian.test" -H "$A" -H "Content-Type: application/json" -d '{"quota_mb":2}')"
echo "   $(head -c 150 /tmp/qb)"

echo "3. a module asking for 500 MB gets the default"
q -X POST "$S/admin/modules" -H "$A" -H "Content-Type: application/json" -d "{\"module_name\":\"$NAME\",\"module_uuid\":\"q1\",\"spaces\":[\"files\"],\"quota_mb\":500}" >/dev/null
T="Authorization: Bearer $(sed 's/.*"token":"//; s/".*//' /tmp/qb)"
q -X POST "$S/admin/modules/$NAME/buckets" -H "$A" -H "Content-Type: application/json" -d '{"domain":"siberian.test"}' >/dev/null
q "$S/admin/quotas" -H "$A" >/dev/null
echo "   its bucket allowance: $(tr ',' '\n' < /tmp/qb | grep -A0 'quota_mb' | tail -1)"
tr '{' '\n' < /tmp/qb | grep "$NAME" | grep -oE '"quota_mb":[0-9]+' | head -1 | sed 's/^/   /'

echo "4. write 700 KB              -> $(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-1" -H "$T" -H "$D" --data-binary @-)"
echo "5. write another 700 KB      -> $(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-2" -H "$T" -H "$D" --data-binary @-)   (expect 507)"
echo "   $(head -c 200 /tmp/qb)"

echo "6. raise this bucket to 5 MB"
q "$S/admin/quotas" -H "$A" >/dev/null
BID=$(tr '{' '\n' < /tmp/qb | grep "$NAME" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)
echo "   -> $(q -X PATCH "$S/admin/quotas/buckets/$BID" -H "$A" -H "Content-Type: application/json" -d '{"quota_mb":5}')"
echo "7. write again               -> $(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-2" -H "$T" -H "$D" --data-binary @-)"
echo "8. and again, hitting the domain pool -> $(dd if=/dev/zero bs=1024 count=900 2>/dev/null | q -X PUT "$S/v1/files/big-3" -H "$T" -H "$D" --data-binary @-)   (expect 507, domain)"
echo "   reason: $(grep -oE '"reason":"[a-z_]+"' /tmp/qb)"

echo "9. delete gives the space back -> $(q -X DELETE "$S/v1/files/big-1" -H "$T" -H "$D")"
echo "10. now it fits              -> $(dd if=/dev/zero bs=1024 count=600 2>/dev/null | q -X PUT "$S/v1/files/big-4" -H "$T" -H "$D" --data-binary @-)"
echo "11. recount                  -> $(q -X POST "$S/admin/quotas/recalculate" -H "$A")"
echo "   $(head -c 200 /tmp/qb)"
