#!/bin/sh
# Writing a file without the bytes travelling through the Storage service.
#
# Reads already worked this way: Storage answers with a signed URL and the
# object store sends the bytes. Writes did not, so a finished Android build
# crossed the network three times, once into the Mobile service, once into
# Storage, and once into the object store.
#
# What this checks is that the quota still holds, because that is the part a
# direct write could quietly lose: the service that used to count the bytes no
# longer sees them.
S=http://storage:3000
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
A="Authorization: Bearer ${SIBERIAN_TOKEN_ORCHESTRATOR_STORAGE:-dev_orchestrator_to_storage}"
DOMAIN="${SIBERIAN_UPLOAD_SMOKE_DOMAIN:-direct-upload.test}"
D="X-Siberian-Domain: $DOMAIN"
NAME="upload-$(date +%s)"

fail() { echo "FAIL: $1"; exit 1; }
expect() { [ "$2" = "$3" ] && echo "$1 -> $2" || { echo "$1 -> $2   FAIL, wanted $3"; exit 1; }; }

# Everything runs inside the Storage container: it is on the object store's
# network, which is the point being tested. A caller outside would reach the
# store through the Router's s3 door instead, which smoke-public-media covers.
inside() { $COMPOSE exec -T storage sh -c "$1"; }

register=$(inside "curl -s -X POST '$S/admin/modules' -H '$A' -H 'Content-Type: application/json' \
  -d '{\"module_name\":\"$NAME\",\"module_uuid\":\"u1\",\"spaces\":[\"files\"],\"quota_mb\":5}'")
TOKEN=$(printf '%s' "$register" | sed 's/.*"token":"//; s/".*//')
[ -n "$TOKEN" ] || fail "the module did not register: $register"
echo "1. module registered"

# Revoked however this script ends, not only on the happy path at the bottom.
trap 'inside "curl -s -o /dev/null -X DELETE '"'"'$S/admin/modules/$NAME'"'"' -H '"'"'$A'"'"'"' EXIT INT TERM

inside "curl -s -o /dev/null -X POST '$S/admin/modules/$NAME/buckets' -H '$A' \
  -H 'Content-Type: application/json' -d '{\"domain\":\"$DOMAIN\"}'"
echo "2. bucket provisioned"

T="Authorization: Bearer $TOKEN"

# A refusal before any address is minted, because the quota is checked against
# the declared size rather than discovered when the bytes arrive somewhere else.
code=$(inside "curl -s -o /dev/null -w '%{http_code}' -X POST '$S/v1/uploads/files/too-big' \
  -H '$T' -H '$D' -H 'Content-Type: application/json' -d '{\"content_length\":99999999}'")
expect "3. an oversized upload refused" "$code" 507

MINT=$(inside "curl -s -X POST '$S/v1/uploads/files/direct.txt' -H '$T' -H '$D' \
  -H 'Content-Type: application/json' -d '{\"content_length\":24,\"content_type\":\"text/plain\"}'")
URL=$(printf '%s' "$MINT" | sed 's/.*"url":"//; s/".*//' | sed 's/\\u0026/\&/g')
case "$URL" in
  *X-Amz-Signature=*) echo "4. an address was minted" ;;
  *) fail "no signed URL in: $MINT" ;;
esac

# The write itself, from outside the stack.
#
# Deliberately not from inside the Storage container. The minted URL names the
# object store's public address, which is the Router's s3 door, and the whole
# point is that whoever holds the bytes writes there without Storage in the
# path. A caller inside the core network cannot even resolve that name, which
# is the first version of this check answering 000 and being right to.
code=$(curl -s --cacert "${SIBERIAN_CA:-deploy/certs/ca.pem}" \
  -o /dev/null -w '%{http_code}' -X PUT "$URL" \
  -H 'Content-Type: text/plain' --data-binary 'twenty four bytes here!!')
expect "5. written to the store direct" "$code" 200

# Before confirming, Storage does not know. That is the honest state: the file
# exists and the accounting has not caught up.
USED=$(inside "curl -s '$S/admin/quotas' -H '$A'" | tr '{' '\n' | grep "$NAME" | grep -oE '"bytes_used":[0-9]+' | head -1 | cut -d: -f2)
expect "6. unconfirmed, still counted as" "${USED:-0}" 0

code=$(inside "curl -s -o /dev/null -w '%{http_code}' -X POST '$S/v1/uploads/files/direct.txt/confirm' -H '$T' -H '$D'")
expect "7. confirmed" "$code" 200

USED=$(inside "curl -s '$S/admin/quotas' -H '$A'" | tr '{' '\n' | grep "$NAME" | grep -oE '"bytes_used":[0-9]+' | head -1 | cut -d: -f2)
expect "8. now counted as" "${USED:-0}" 24

# Twice, because a caller whose confirm timed out will send it again.
inside "curl -s -o /dev/null -X POST '$S/v1/uploads/files/direct.txt/confirm' -H '$T' -H '$D'"
USED=$(inside "curl -s '$S/admin/quotas' -H '$A'" | tr '{' '\n' | grep "$NAME" | grep -oE '"bytes_used":[0-9]+' | head -1 | cut -d: -f2)
expect "9. confirming again is free" "${USED:-0}" 24

# And the ordinary read path still finds it, so a direct write produces an
# object indistinguishable from one written through the service.
body=$(inside "curl -s '$S/v1/files/direct.txt' -H '$T' -H '$D'")
[ "$body" = "twenty four bytes here!!" ] || fail "read back wrong: $body"
echo "10. and reads back through Storage"

inside "curl -s -o /dev/null -X DELETE '$S/v1/files/direct.txt' -H '$T' -H '$D'"
inside "curl -s -o /dev/null -X DELETE '$S/admin/modules/$NAME' -H '$A'"
echo "11. cleaned up"

echo
echo "the bytes went straight to the object store, and the quota still counted them."
