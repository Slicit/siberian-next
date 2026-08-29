#!/bin/sh
# The phone app for one domain: configure it, watch a module's requirement
# decide how that module appears, and queue a build.
#
# Driven through the Backoffice, because every one of those is something an
# operator does. The build itself is the builder's business and has its own
# timing; this proves the queue accepts work and reports it.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
PASSWORD="${SIBERIAN_DEMO_PASSWORD:-siberian-demo}"
J=/tmp/mob_jar.txt
P=/tmp/mob_page
rm -f $J

c() { curl -s --cacert "$CA" -b $J -c $J "$@"; }

get() {
  rm -f $P
  c -o $P -w "%{http_code}" "$1"
}

token() { grep -o 'name="csrf-token" content="[^"]*"' $P | head -1 | sed 's/.*content="//; s/"//'; }

T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"
echo "signed in as operator"

echo
echo "1. the phone apps page -> $(get "https://core.$DOMAIN/mobile")"
ID=$(grep -A30 ">$DOMAIN<" $P | grep -oE "mobile/[0-9]+" | head -1 | grep -oE "[0-9]+")
echo "   $DOMAIN is domain $ID"

echo "2. the app for it      -> $(get "https://core.$DOMAIN/mobile/$ID")"
grep -oE 'Native capabilities|In the app as' $P | sort -u | sed 's/^/   /'

echo "3. every catalogue capability is offered"
grep -oE 'expo-[a-z-]+|react-native-purchases' $P | sort -u | tr '\n' ' ' | sed 's/^/   /'
echo

echo "4. a module that requires a capability says which"
grep -oE 'Required by [a-z-]+' $P | sort -u | sed 's/^/   /'

echo "5. how each module would appear"
grep -A1 "span class=\"badge" $P | sed "s/^ *//" | grep -xE "native|its web UI|none" | sort | uniq -c | sed "s/^/  /"

echo
echo "6. ask for an Android build"
echo "   -> $(c -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "platform=android" "https://core.$DOMAIN/mobile/$ID/build")   (expect 302)"

get "https://core.$DOMAIN/mobile/$ID" > /dev/null
grep -oE 'Build queued[^<]*' $P | head -1 | sed 's/^/   said: /'
grep -oE '>(queued|building|succeeded|dead)<' $P | tr -d '<>' | head -1 | sed 's/^/   the queue holds: /'

echo
echo "7. the app door, which is where module isolation lives without origins"
echo "   /m/demo-tasks/      -> $(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/m/demo-tasks/")   (expect 200)"
echo "   /m/no-such-module/x -> $(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/m/no-such-module/x")   (expect 404, not a 502 at a name that is not there)"
echo "   /m/<capability-id>  -> $(c -o /dev/null -w '%{http_code}' "https://$DOMAIN/m/demo_tasks-task-list")   (expect 200, still the Base App frame)"

# The screen's own data, not just the door it comes through.
#
# The native screen shipped calling tasks.json and the module never served
# it, so every phone and every preview showed "the module answered 404" from
# the day it was written. Everything above passed the whole time: a door that
# opens is not a screen that loads.
screen=$(c -o /tmp/mob_screen -w '%{http_code}' "https://$DOMAIN/m/demo-tasks/tasks.json")
echo "   the screen's own data -> $screen   (expect 200)"
if [ "$screen" != "200" ]; then
  echo "   FAIL: the native screen calls this and would show the error it prints"
  exit 1
fi
grep -qF '[' /tmp/mob_screen || { echo "   FAIL: not a JSON list: $(head -c 80 /tmp/mob_screen)"; exit 1; }

echo
echo "8. the product side, where somebody configures their own domain's app"
J=/tmp/mob_user_jar.txt
rm -f $J
T=$(c "https://$DOMAIN/login" | grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
c -o /dev/null -X POST \
  --data-urlencode "authenticity_token=$T" \
  --data-urlencode "email=operator@siberian.localhost" \
  --data-urlencode "password=$PASSWORD" "https://$DOMAIN/login"

echo "   GET /app          -> $(get "https://$DOMAIN/app")"
grep -oE 'Describe it|Build for Android' $P | sort -u | sed 's/^/   /'

# Says so rather than failing when no key is configured, which is a normal
# installation rather than a broken one.
echo "   ask the assistant -> $(c -o $P -w '%{http_code}' -X POST \
  --data-urlencode "authenticity_token=$(token)" \
  --data-urlencode "description=A field service app for engineers who work where there is no signal." \
  "https://$DOMAIN/app/suggest")"
grep -oE 'assistant is not configured|What it suggests' $P | head -1 | sed 's/^/   /'

echo
echo "9. the splash, and what it refuses"
get "https://core.$DOMAIN/mobile/$ID" > /dev/null
grep -oE 'image: (set|none)|Android animation: (set|none)|centre [0-9]+ pixels' $P | sort -u | sed 's/^/   /'

# A GIF is what everybody reaches for first, and Android animates exactly one
# thing that is not a GIF. Generated here rather than committed: three bytes of
# header is enough to be recognised and refused by name.
printf 'GIF89a' > /tmp/mob_fake.gif
head -c 64 /dev/zero >> /tmp/mob_fake.gif
# Multipart, so the token goes as a form field: curl cannot mix
# --data-urlencode with -F, and sending only one of them would test nothing.
echo "   a GIF as the animation -> $(c -o $P -w '%{http_code}' -X POST \
  -F "authenticity_token=$(token)" \
  -F "animation=@/tmp/mob_fake.gif" "https://core.$DOMAIN/mobile/$ID/splash")   (expect 302, refused)"
get "https://core.$DOMAIN/mobile/$ID" > /dev/null
grep -oE 'cannot play a GIF there' $P | head -1 | sed 's/^/   said: /'
