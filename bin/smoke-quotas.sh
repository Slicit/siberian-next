#!/bin/sh
S=http://storage:3000
# These endpoints are for core services. This stands in for the Orchestrator,
# and since there is one secret per pair of services it is specifically the
# Orchestrator-to-that-service credential, which works nowhere else.
A="Authorization: Bearer ${SIBERIAN_TOKEN_ORCHESTRATOR_STORAGE:-dev_orchestrator_to_storage}"

# A domain of its own, not the one the stack serves.
#
# This smoke sets a 1 MB default and a 2 MB domain pool and leaves them set.
# Pointed at the served domain that was a slow-acting trap: everything else
# storing anything real on it, phone app artifacts included, then met a 2 MB
# ceiling nobody had chosen. Storage keys a bucket on the domain string and
# does not require it to be routable, so the smoke gets one nothing else uses.
DOMAIN="${SIBERIAN_QUOTA_SMOKE_DOMAIN:-quota-smoke.test}"
D="X-Siberian-Domain: $DOMAIN"
q() { curl -s -o /tmp/qb -w "%{http_code}" "$@"; }

# Prints and checks. These steps used to print "(expect 507)" beside whatever
# they got and exit zero regardless, so the run where the domain pool had
# silently filled reported a refusal for the wrong reason and still passed. A
# check that narrates is not a check.
expect() { # expect <label> <got> <wanted>
  if [ "$2" = "$3" ]; then
    echo "$1 -> $2"
  else
    echo "$1 -> $2   FAIL, wanted $3"
    exit 1
  fi
}

NAME="quota-$(date +%s)"

# The default is global, so leaving it at 1 MB would give every bucket
# provisioned afterwards, anywhere, one megabyte. Read it first and put it back
# at the end: a check that changes the system it checked is not a check.
q "$S/admin/quotas" -H "$A" >/dev/null
WAS=$(grep -oE '"default_bucket_quota_mb":[0-9]+' /tmp/qb | head -1 | cut -d: -f2)

echo "1. set the default to 1 MB   -> $(q -X PATCH "$S/admin/quotas" -H "$A" -H "Content-Type: application/json" -d '{"default_bucket_quota_mb":1}')"
echo "2. cap the smoke domain     -> $(q -X PATCH "$S/admin/quotas/domains/$DOMAIN" -H "$A" -H "Content-Type: application/json" -d '{"quota_mb":2}')"
echo "   $(head -c 150 /tmp/qb)"

echo "3. a module asking for 500 MB gets the default"
q -X POST "$S/admin/modules" -H "$A" -H "Content-Type: application/json" -d "{\"module_name\":\"$NAME\",\"module_uuid\":\"q1\",\"spaces\":[\"files\"],\"quota_mb\":500}" >/dev/null
T="Authorization: Bearer $(sed 's/.*"token":"//; s/".*//' /tmp/qb)"
q -X POST "$S/admin/modules/$NAME/buckets" -H "$A" -H "Content-Type: application/json" -d "{\"domain\":\"$DOMAIN\"}" >/dev/null
q "$S/admin/quotas" -H "$A" >/dev/null
echo "   its bucket allowance: $(tr ',' '\n' < /tmp/qb | grep -A0 'quota_mb' | tail -1)"
tr '{' '\n' < /tmp/qb | grep "$NAME" | grep -oE '"quota_mb":[0-9]+' | head -1 | sed 's/^/   /'

echo "4. write 700 KB              -> $(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-1" -H "$T" -H "$D" --data-binary @-)"
expect "5. write another 700 KB     " \
  "$(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-2" -H "$T" -H "$D" --data-binary @-)" 507
echo "   $(head -c 200 /tmp/qb)"

echo "6. raise this bucket to 5 MB"
q "$S/admin/quotas" -H "$A" >/dev/null
BID=$(tr '{' '\n' < /tmp/qb | grep "$NAME" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)
echo "   -> $(q -X PATCH "$S/admin/quotas/buckets/$BID" -H "$A" -H "Content-Type: application/json" -d '{"quota_mb":5}')"
expect "7. write again              " \
  "$(dd if=/dev/zero bs=1024 count=700 2>/dev/null | q -X PUT "$S/v1/files/big-2" -H "$T" -H "$D" --data-binary @-)" 201
expect "8. and again, the domain pool" \
  "$(dd if=/dev/zero bs=1024 count=900 2>/dev/null | q -X PUT "$S/v1/files/big-3" -H "$T" -H "$D" --data-binary @-)" 507
echo "   reason: $(grep -oE '"reason":"[a-z_]+"' /tmp/qb)"

echo "9. delete gives the space back -> $(q -X DELETE "$S/v1/files/big-1" -H "$T" -H "$D")"

# The step the accumulated pool broke. It failed with 507 for runs on end,
# printed "10. now it fits -> 507", and passed.
expect "10. now it fits             " \
  "$(dd if=/dev/zero bs=1024 count=600 2>/dev/null | q -X PUT "$S/v1/files/big-4" -H "$T" -H "$D" --data-binary @-)" 201
echo "11. recount                  -> $(q -X POST "$S/admin/quotas/recalculate" -H "$A")"
echo "   $(head -c 200 /tmp/qb)"

echo "12. put the default back     -> $(q -X PATCH "$S/admin/quotas" -H "$A" -H "Content-Type: application/json" -d "{\"default_bucket_quota_mb\":${WAS:-15}}")   (was ${WAS:-unknown} MB)"

# Take the objects back out, and revoke the module.
#
# Every run registers a module named for the second it started and provisions a
# bucket on the same domain, whose pool this smoke caps at 2 MB. Left behind,
# each run ate into that pool until step 7 met the domain ceiling rather than
# the bucket one and reported a refusal for the wrong reason: a check that
# breaks the next run of itself.
#
# The bucket survives the module, deliberately, because Storage keeps data when
# a module is revoked. So the objects go first and explicitly.
for object in big-1 big-2 big-3 big-4; do
  q -X DELETE "$S/v1/files/$object" -H "$T" -H "$D" >/dev/null
done
echo "13. objects removed          -> $(q "$S/v1/files" -H "$T" -H "$D"; grep -o '"objects":\[\]' /tmp/qb >/dev/null && echo "the space is empty" || echo "still holding: $(head -c 80 /tmp/qb)")"

expect "14. module revoked          " "$(q -X DELETE "$S/admin/modules/$NAME" -H "$A")" 204
