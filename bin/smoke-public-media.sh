#!/bin/sh
# Public module media, served by the Router straight out of Storage.
#
# The point of the path is that no module process touches the bytes and no
# token travels. Both halves need checking, and so does the half that must not
# work: the same URL shape must not reach the private spaces of the module that
# owns the public one.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
MODULE="example-cms"
OUT=/tmp/pub_body

fail() { echo "FAIL: $1"; exit 1; }

CMS=$(docker ps --format "{{.Names}}" | grep -- "-${MODULE}-web" | head -1)
[ -n "$CMS" ] || fail "$MODULE is not installed, so there is nothing to serve"

# Written through the module's own token, which is the only way anything gets
# into a bucket. The public path is a way to read, never a way to write.
inside() { docker exec "$CMS" sh -c "$1"; }

inside 'echo -n PUBLICBYTES > /tmp/pm.png' >/dev/null
code=$(inside "curl -s -o /dev/null -w '%{http_code}' -X PUT \
  -H \"Authorization: Bearer \$SIBERIAN_STORAGE_TOKEN\" \
  -H 'X-Siberian-Domain: $DOMAIN' -H 'Content-Type: image/png' \
  --data-binary @/tmp/pm.png http://core/storage/v1/public/smoke/pm.png")
echo "1. module writes a public file -> $code   (expect 201)"
[ "$code" = "201" ] || fail "the module could not write the fixture"

inside 'echo -n PRIVATEBYTES > /tmp/pm.txt' >/dev/null
code=$(inside "curl -s -o /dev/null -w '%{http_code}' -X PUT \
  -H \"Authorization: Bearer \$SIBERIAN_STORAGE_TOKEN\" \
  -H 'X-Siberian-Domain: $DOMAIN' \
  --data-binary @/tmp/pm.txt http://core/storage/v1/files/pm-private.txt")
echo "2. and a private one           -> $code   (expect 201)"
[ "$code" = "201" ] || fail "the module could not write the private fixture"

cleanup() {
  for path in public/smoke/pm.png files/pm-private.txt; do
    inside "curl -s -o /dev/null -X DELETE \
      -H \"Authorization: Bearer \$SIBERIAN_STORAGE_TOKEN\" \
      -H 'X-Siberian-Domain: $DOMAIN' http://core/storage/v1/$path" >/dev/null
  done
}
trap cleanup EXIT

# No Authorization header anywhere below this line. That is the feature.
rm -f $OUT
code=$(curl -sL --cacert "$CA" -o $OUT -w "%{http_code}" \
  "https://$DOMAIN/-/public/$MODULE/smoke/pm.png")
echo "3. anyone reads it, no token   -> $code   (expect 200)"
[ "$code" = "200" ] || fail "the public path answered $code"
[ "$(cat $OUT)" = "PUBLICBYTES" ] || fail "the bytes came back wrong: $(cat $OUT)"

# Storage hands out an address and carries nothing. The redirect is the visible
# part of that: if this ever goes back to answering 200 with a body, the bytes
# are travelling through Rails again and the feature has quietly regressed.
SIGNED=$(curl -s --cacert "$CA" -D- -o /dev/null "https://$DOMAIN/-/public/$MODULE/smoke/pm.png" \
  | grep -i "^location" | tr -d '\r' | sed 's/^location: //I')
echo "4. Storage redirects, not serves-> $(echo "$SIGNED" | cut -c1-40)..."
case "$SIGNED" in
  https://s3.$DOMAIN/*X-Amz-Signature=*) : ;;
  "") fail "no redirect: Storage is serving the bytes itself" ;;
  *) fail "redirected somewhere unexpected: $SIGNED" ;;
esac

# The content type survives. Proxying it through the module lost the real one
# and guessed from the file extension instead.
ctype=$(curl -s --cacert "$CA" -D- -o /dev/null "$SIGNED" \
  | grep -i "^content-type" | tr -d '\r' | awk '{print $2}')
echo "5. content type is the real one-> $ctype   (expect image/png)"
[ "$ctype" = "image/png" ] || fail "content type came back as '$ctype'"

nosniff=$(curl -s --cacert "$CA" -D- -o /dev/null "$SIGNED" \
  | grep -ic "x-content-type-options: nosniff")
echo "6. nosniff on the object store -> $nosniff   (expect 1)"
[ "$nosniff" = "1" ] || fail "third-party bytes served without nosniff"

# The door forwards signatures; it does not make them. Each of these is a way
# somebody might try to turn one legitimate URL into access to something else.
echo -n "7. unsigned request refused    -> "
code=$(curl -s --cacert "$CA" -o /dev/null -w "%{http_code}" "${SIGNED%%\?*}")
echo "$code   (expect 403)"
[ "$code" = "403" ] || fail "the object store served an unsigned request"

echo -n "8. key swapped for a private one-> "
code=$(curl -s --cacert "$CA" -o /dev/null -w "%{http_code}" \
  "$(echo "$SIGNED" | sed 's|public/smoke/pm.png|files/pm-private.txt|')")
echo "$code   (expect 403)"
[ "$code" = "403" ] || fail "a signature for a public object reached a private one"

echo -n "9. tampered signature refused  -> "
# Replaced wholesale rather than by editing one character. Changing the first
# character to a zero does nothing at all when it is already a zero, which is
# one signature in sixteen, and the check then passed a genuinely unsigned
# request and reported it as a failure. An intermittent security check is worse
# than none: it gets rerun until it is green and then believed.
code=$(curl -s --cacert "$CA" -o /dev/null -w "%{http_code}" \
  "$(echo "$SIGNED" | sed 's/X-Amz-Signature=[0-9a-f]*/X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000/')")
echo "$code   (expect 403)"
[ "$code" = "403" ] || fail "a tampered signature was accepted"

# The preview runs on core.<domain>, so one URL has to work from both.
rm -f $OUT
code=$(curl -sL --cacert "$CA" -o $OUT -w "%{http_code}" \
  "https://core.$DOMAIN/-/public/$MODULE/smoke/pm.png")
echo "10. same path on core.<domain> -> $code   (expect 200)"
[ "$code" = "200" ] || fail "the preview origin answered $code"
[ "$(cat $OUT)" = "PUBLICBYTES" ] || fail "the preview origin served the wrong bytes"

# What must not work.
for attempt in "../files/pm-private.txt" "..%2ffiles%2fpm-private.txt" "%2e%2e/files/pm-private.txt"; do
  rm -f $OUT
  code=$(curl -s --cacert "$CA" -o $OUT -w "%{http_code}" \
    "https://$DOMAIN/-/public/$MODULE/$attempt")
  body=$(cat $OUT 2>/dev/null)
  echo "11. traversal refused          -> $code   ($attempt)"
  [ "$code" = "200" ] && fail "the public path reached a private object"
  case "$body" in *PRIVATE*) fail "a private object leaked through the public path";; esac
done

code=$(curl -s --cacert "$CA" -o /dev/null -w "%{http_code}" \
  "https://$DOMAIN/-/public/not-a-module/anything.png")
echo "12. unknown module             -> $code   (expect 404)"
[ "$code" = "404" ] || fail "an unknown module answered $code"

echo
echo "public media comes from the object store itself: no token, no module, and"
echo "no core service carrying the bytes."
