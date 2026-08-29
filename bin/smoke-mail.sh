#!/bin/sh
# The mail queue: enqueue, deduplicate, deliver, acknowledge, and stay out of
# another module's mail.
#
# It used to narrate, and step 9 is why that mattered. It printed the state a
# message ended in beside a sentence about permanent rejections, and the state
# it printed every night was `dead`, because the transport module answered 404
# to everything. The run was green throughout.
M=http://mailer:3000
# These endpoints are for core services. This stands in for the Orchestrator,
# and since there is one secret per pair of services it is specifically the
# Orchestrator-to-that-service credential, which works nowhere else.
A="Authorization: Bearer ${SIBERIAN_TOKEN_ORCHESTRATOR_MAILER:-dev_orchestrator_to_mailer}"
D="X-Siberian-Domain: siberian.test"

. "$(dirname "$0")/smoke-lib.sh"

q() { curl -s -o /tmp/mb -w "%{http_code}" "$@"; }
field() { sed "s/.*\"$1\":\"*//; s/[\",].*//" /tmp/mb; }

# Fresh per run. A fixed name re-registers the same module, which works, and
# then counts messages from every previous run.
NAME="mailq-$(date +%s)"

echo "1. a module that may send"
expect "   register                  " \
  "$(q -X POST "$M/admin/modules" -H "$A" -H "Content-Type: application/json" \
     -d "{\"module_name\":\"$NAME\",\"module_uuid\":\"ms1\",\"daily_limit\":100}")" 201
TOKEN=$(field token)
T="Authorization: Bearer $TOKEN"
present "it was given a token" "$TOKEN"

echo "2. enqueue"
expect "   accepted                  " \
  "$(q -X POST "$M/v1/messages" -H "$T" -H "$D" -H "Content-Type: application/json" \
     -d '{"to":"someone@example.test","subject":"Hello from the queue","text_body":"It works.","idempotency_key":"smoke-1"}')" 201
ID=$(sed 's/.*"id"://; s/,.*//' /tmp/mb)
check "it starts queued" "$(field state)" "queued"

echo "3. the same key twice is one message"
q -X POST "$M/v1/messages" -H "$T" -H "$D" -H "Content-Type: application/json" \
  -d '{"to":"someone@example.test","subject":"Hello from the queue","text_body":"It works.","idempotency_key":"smoke-1"}' >/dev/null
contains "the second is reported as a duplicate" "$(cat /tmp/mb)" '"deduplicated":true'

echo "4. the worker delivers it"
sleep 9
q "$M/v1/messages/$ID" -H "$T" -H "$D" >/dev/null
# `sent`, not merely terminal. A transport that rejects everything also reaches
# a terminal state, which is what this used to accept.
check "it was sent" "$(field state)" "sent"
present "a transport is named" "$(field transport)"

echo "5. outcomes are reported until somebody says they have seen them"
q "$M/v1/messages?unacknowledged=true" -H "$T" -H "$D" >/dev/null
check "it is waiting to be acknowledged" "$(grep -c '"id":' /tmp/mb)" "1"
expect "   acknowledge               " "$(q -X POST "$M/v1/messages/$ID/ack" -H "$T" -H "$D")" 200
q "$M/v1/messages?unacknowledged=true" -H "$T" -H "$D" >/dev/null
check "nothing is waiting now" "$(grep -c '"id":' /tmp/mb)" "0"

echo "6. stats answer"
expect "   stats                     " "$(q "$M/v1/stats" -H "$T" -H "$D")" 200

echo "7. another module cannot see it"
q -X POST "$M/admin/modules" -H "$A" -H "Content-Type: application/json" \
  -d "{\"module_name\":\"nosy-$(date +%s)\",\"module_uuid\":\"n1\"}" >/dev/null
NOSY=$(field token)
q "$M/v1/messages" -H "Authorization: Bearer $NOSY" -H "$D" >/dev/null
check "it sees no messages at all" "$(grep -c '"id":' /tmp/mb)" "0"
expect "   and not that one by id    " \
  "$(q "$M/v1/messages/$ID" -H "Authorization: Bearer $NOSY" -H "$D")" 404

echo "8. a terminal message can be put back by hand"
expect "   retry                     " "$(q -X POST "$M/v1/messages/$ID/retry" -H "$T" -H "$D")" 200
check "it is queued again" "$(field state)" "queued"

finish "mail"
