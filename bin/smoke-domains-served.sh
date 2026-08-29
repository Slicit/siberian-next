#!/bin/sh
# Every configured domain gets served, not just the first one.
#
# The Router used to render its core server blocks once at container start from
# a single SIBERIAN_DOMAIN, while the database held several domains. The ones it
# missed were not refused: they fell through to whichever block matched first
# and were answered as the wrong domain, which is a silent wrong answer.
#
# So this asks the database what is served and then checks that each of those
# domains actually answers on its own three doors.
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

fail() { echo "FAIL: $1"; exit 1; }

DOMAINS=$($COMPOSE exec -T orchestrator bin/rails runner \
  'puts Domain.ordered.map(&:hostname).join(" ")' 2>/dev/null | tr -d '\r')
[ -n "$DOMAINS" ] || fail "the database names no domains at all"
echo "1. domains in the database    -> $DOMAINS"

count=0
for d in $DOMAINS; do
  count=$((count + 1))
  # -k because the development certificate covers the first domain's names and
  # not a second domain's. What is being checked here is routing, and a
  # certificate is a separate thing that a real second domain would need.
  shell=$(curl -sk --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' -m 12 "https://$d/")
  back=$(curl -sk --resolve "core.$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' -m 12 "https://core.$d/")
  store=$(curl -sk --resolve "s3.$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' -m 12 "https://s3.$d/")

  echo "   $d: shell=$shell backoffice=$back store=$store"

  # 302 is the redirect to login, which is what a shell and a Backoffice answer
  # to somebody signed out. 403 is the object store refusing an unsigned
  # request, which is the door working.
  [ "$shell" = "302" ] || fail "$d has no product shell (answered $shell)"
  [ "$back" = "302" ] || fail "core.$d has no Backoffice (answered $back)"
  [ "$store" = "403" ] || fail "s3.$d is not the object store door (answered $store)"
done

echo "2. every one of the $count served, on all three doors"

# The Router's own view, which is what the reconciler writes.
served=$($COMPOSE exec -T router sh -c 'ls /etc/nginx/conf.d/modules/domains/*.conf 2>/dev/null | wc -l' | tr -d '\r')
echo "3. per-domain configs written -> $served   (expect $count)"
[ "$served" = "$count" ] || fail "the Router has $served domain configs for $count domains"

echo
echo "every domain the database names is served by the Router and answered by the applications."
