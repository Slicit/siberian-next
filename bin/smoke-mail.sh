#!/bin/sh
M=http://mailer:3000
A="Authorization: Bearer orchestrator_dev_only"
D="X-Siberian-Domain: siberian.test"
q() { curl -s -o /tmp/mb -w "%{http_code}" "$@"; }

echo "1. register a module        -> $(q -X POST "$M/admin/modules" -H "$A" -H "Content-Type: application/json" -d '{"module_name":"mail-smoke","module_uuid":"ms1","daily_limit":100}')"
TOKEN=$(sed 's/.*"token":"//; s/".*//' /tmp/mb)
T="Authorization: Bearer $TOKEN"

echo "2. enqueue                  -> $(q -X POST "$M/v1/messages" -H "$T" -H "$D" -H "Content-Type: application/json" -d '{"to":"someone@example.test","subject":"Hello from the queue","text_body":"It works.","idempotency_key":"smoke-1"}')"
ID=$(sed 's/.*"id"://; s/,.*//' /tmp/mb)
echo "   id=$ID state=$(sed 's/.*"state":"//; s/".*//' /tmp/mb)"

echo "3. same key again           -> $(q -X POST "$M/v1/messages" -H "$T" -H "$D" -H "Content-Type: application/json" -d '{"to":"someone@example.test","subject":"Hello from the queue","text_body":"It works.","idempotency_key":"smoke-1"}')"
echo "   deduplicated: $(grep -o '"deduplicated":true' /tmp/mb || echo no)"

echo "4. wait for the worker..."
sleep 8
q "$M/v1/messages/$ID" -H "$T" -H "$D" >/dev/null
echo "   state=$(sed 's/.*"state":"//; s/".*//' /tmp/mb) transport=$(sed 's/.*"transport":"//; s/".*//' /tmp/mb) attempts=$(sed 's/.*"attempts"://; s/,.*//' /tmp/mb)"

echo "5. unacknowledged           -> $(q "$M/v1/messages?unacknowledged=true" -H "$T" -H "$D")"
echo "   count: $(grep -o '"id":' /tmp/mb | wc -l)"

echo "6. acknowledge it           -> $(q -X POST "$M/v1/messages/$ID/ack" -H "$T" -H "$D")"
q "$M/v1/messages?unacknowledged=true" -H "$T" -H "$D" >/dev/null
echo "   unacknowledged now: $(grep -o '"id":' /tmp/mb | wc -l)"

echo "7. stats                    -> $(q "$M/v1/stats" -H "$T" -H "$D")"
echo "   $(head -c 220 /tmp/mb)"

echo "8. another module cannot see it"
q -X POST "$M/admin/modules" -H "$A" -H "Content-Type: application/json" -d '{"module_name":"nosy","module_uuid":"n1"}' >/dev/null
NOSY=$(sed 's/.*"token":"//; s/".*//' /tmp/mb)
echo "   nosy sees $(q "$M/v1/messages" -H "Authorization: Bearer $NOSY" -H "$D" >/dev/null; grep -o '"id":' /tmp/mb | wc -l) message(s), and message $ID -> $(q "$M/v1/messages/$ID" -H "Authorization: Bearer $NOSY" -H "$D")"

echo
echo "9. a permanent rejection does not burn six attempts"
q -X POST "$M/v1/messages" -H "$T" -H "$D" -H "Content-Type: application/json" -d "{\"to\":\"c@example.test\",\"subject\":\"through the module transport\",\"text_body\":\"x\"}" >/dev/null
R=$(sed "s/.*\"id\"://; s/,.*//" /tmp/mb)
sleep 9
q "$M/v1/messages/$R" -H "$T" -H "$D" >/dev/null
echo "   state=$(sed "s/.*\"state\":\"//; s/\".*//" /tmp/mb) attempts=$(sed "s/.*\"attempts\"://; s/,.*//" /tmp/mb) transport=$(sed "s/.*\"transport\":\"//; s/\".*//" /tmp/mb)"
echo "10. retry it by hand        -> $(q -X POST "$M/v1/messages/$R/retry" -H "$T" -H "$D")  state=$(sed "s/.*\"state\":\"//; s/\".*//" /tmp/mb)"
