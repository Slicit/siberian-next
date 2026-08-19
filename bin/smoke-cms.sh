#!/bin/sh
# The CMS module, both faces.
#
# What it proves is not that a page renders. It is that one description of a
# block reaches the browser and the phone app unchanged: the same ids, the same
# keys, and media URLs that resolve through whichever door asked.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
MODULE=https://cms.apps.$DOMAIN
J=/tmp/cms_jar.txt
rm -f $J

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

T=$(c -c $J "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"
echo "signed in as operator"

SLUG="smoke-$(date +%s)"
echo
echo "1. create a page          -> $(c -o /dev/null -w '%{http_code}' -X POST --data-urlencode "title=$SLUG" $MODULE/pages)   (expect 302)"

echo "2. one block of every kind"
for kind in title text image carousel video; do
  c -o /dev/null -X POST --data-urlencode "kind=$kind" $MODULE/$SLUG/blocks
done
c -o /tmp/cms_edit $MODULE/$SLUG/edit
grep -oE 'class="kind">[A-Za-z]+' /tmp/cms_edit | sed 's/.*>//' | sort -u | tr '\n' ' ' | sed 's/^/   /'
echo

# Real bytes, because a header-only PNG is accepted by everything and drawn by
# nothing. Generated here so the repository carries no binary for a test.
python3 - <<'PYEOF'
import zlib, struct
w = h = 240
raw = b"".join(b"\x00" + bytes((37, 99, 235)) * w for _ in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
head = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
open("/tmp/cms_shot.png", "wb").write(
    b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
)
PYEOF

ID=$(grep -oE "/$SLUG/blocks/[0-9]+\"" /tmp/cms_edit | grep -oE '[0-9]+' | sort -un | sed -n 3p)
echo "3. upload an image        -> $(c -o /dev/null -w '%{http_code}' -X POST -F "file=@/tmp/cms_shot.png" $MODULE/$SLUG/blocks/$ID/media)   (expect 302)"

echo "4. the rendered page      -> $(c -o /tmp/cms_page -w '%{http_code}' $MODULE/$SLUG)"
grep -oE '<figure>|class="strip"|<iframe|<h2>' /tmp/cms_page | sort | uniq -c | tr '\n' ' ' | sed 's/^/   /'
echo

echo "5. the same page as JSON, through the app door"
c -o /tmp/cms_api "https://$DOMAIN/m/example-cms/api/pages/$SLUG"
grep -oE '"kind": *"[a-z]+"' /tmp/cms_api | sed 's/.*: *//' | tr -d '"' | tr '\n' ' ' | sed 's/^/   kinds: /'
echo
echo "   media URL: $(grep -oE 'https://[^"]*cms_shot.png' /tmp/cms_api | head -1)"

# The door decides the prefix. A URL built for the browser points at the product
# shell when the phone asks, and every image in the app would be a 404.
echo "6. that URL actually serves -> $(c -o /dev/null -w '%{http_code}' "$(grep -oE 'https://[^"]*cms_shot.png' /tmp/cms_api | head -1)")   (expect 200)"

echo "7. and through its own origin"
c -o /tmp/cms_api2 "$MODULE/api/pages/$SLUG"
echo "   media URL: $(grep -oE 'https://[^"]*cms_shot.png' /tmp/cms_api2 | head -1)"
echo "   serves      -> $(c -o /dev/null -w '%{http_code}' "$(grep -oE 'https://[^"]*cms_shot.png' /tmp/cms_api2 | head -1)")   (expect 200)"

echo
echo "9. linking pages"
OTHER="${SLUG}-b"
c -o /dev/null -X POST --data-urlencode "title=$OTHER" $MODULE/pages > /dev/null
c -o /dev/null -X POST --data-urlencode "next_slug=$OTHER" --data-urlencode "prev_slug=" $MODULE/$SLUG/neighbours

# The picker is an input bound to a datalist, so it filters as somebody types
# and still submits a slug. A page never offers itself.
c -o /tmp/cms_edit2 $MODULE/$SLUG/edit
echo "   the picker offers: $(grep -oE "<option value=\"$OTHER\"" /tmp/cms_edit2 | head -1 | sed 's/<option value=//')"
echo "   and never itself:  $(grep -c "<option value=\"$SLUG\"" /tmp/cms_edit2)   (expect 0)"

c -o /dev/null -X POST --data-urlencode "kind=nav" $MODULE/$SLUG/blocks
c -o /tmp/cms_edit3 $MODULE/$SLUG/edit
NAV=$(grep -oE "blocks/[0-9]+/links\"" /tmp/cms_edit3 | grep -oE '[0-9]+' | head -1)
c -o /dev/null -X POST --data-urlencode "slug=$OTHER" $MODULE/$SLUG/blocks/$NAV/links
c -o /dev/null -X POST --data-urlencode "slug=$SLUG" $MODULE/$SLUG/blocks/$NAV/links

c "https://$DOMAIN/m/example-cms/api/pages/$SLUG" > /tmp/cms_api3
python3 - <<PYEOF
import json
payload = json.load(open("/tmp/cms_api3"))
links = [l["slug"] for b in payload["blocks"] if b["kind"] == "nav" for l in b["links"]]
print("   nav block links:  ", links, "(a page cannot link to itself)")
print("   next:             ", (payload.get("next") or {}).get("slug"))
PYEOF

c -o /dev/null -X POST $MODULE/$OTHER/delete

echo
echo "10. tidy up               -> $(c -o /dev/null -w '%{http_code}' -X POST $MODULE/$SLUG/delete)   (expect 302, and the blocks go with it)"
