#!/bin/sh
S=http://storage:3000
# These endpoints are for core services. This stands in for the Orchestrator,
# and since there is one secret per pair of services it is specifically the
# Orchestrator-to-that-service credential, which works nowhere else.
ADMIN="Authorization: Bearer ${SIBERIAN_TOKEN_ORCHESTRATOR_STORAGE:-dev_orchestrator_to_storage}"
DOM="X-Siberian-Domain: ${SIBERIAN_DOMAIN:-siberian.test}"
q() { curl -s -o /tmp/body -w "%{http_code}" "$@"; }

code=$(q -X POST "$S/admin/modules" -H "$ADMIN" -H "Content-Type: application/json" \
  -d '{"module_name":"smoke-test","module_uuid":"smoke123","spaces":["files","public"],"quota_mb":5}')
echo "1. register module              -> $code"
TOKEN=$(sed 's/.*"token":"//; s/".*//' /tmp/body)
MOD="Authorization: Bearer $TOKEN"
[ ${#TOKEN} -gt 20 ] && echo "   token looks like a token       (${#TOKEN} chars)" || { echo "   BAD TOKEN: $(head -c 200 /tmp/body)"; exit 1; }

echo "2. provision bucket             -> $(q -X POST "$S/admin/modules/smoke-test/buckets" -H "$ADMIN" -H "Content-Type: application/json" -d "{\"domain\":\"${SIBERIAN_DOMAIN:-siberian.test}\"}")"
echo "   $(head -c 120 /tmp/body)"
echo "3. PUT a file                   -> $(q -X PUT "$S/v1/files/notes/hello.txt" -H "$MOD" -H "$DOM" -H "Content-Type: text/plain" --data-binary 'hello from a module')"
echo "   $(head -c 120 /tmp/body)"
echo "4. GET it back                  -> $(q "$S/v1/files/notes/hello.txt" -H "$MOD" -H "$DOM")"
echo "   body: $(head -c 60 /tmp/body)"
echo "5. HEAD it                      -> $(q -I "$S/v1/files/notes/hello.txt" -H "$MOD" -H "$DOM")"
echo "6. list the space               -> $(q "$S/v1/files" -H "$MOD" -H "$DOM")"
echo "   $(head -c 200 /tmp/body)"
echo "7. ungranted space (tmp)        -> $(q -X PUT "$S/v1/tmp/x" -H "$MOD" -H "$DOM" --data-binary x)   (expect 403)"
echo "8. no token                     -> $(q "$S/v1/files/notes/hello.txt" -H "$DOM")   (expect 401)"
echo "9. no domain header             -> $(q "$S/v1/files/notes/hello.txt" -H "$MOD")   (expect 400)"
echo "10. DELETE                      -> $(q -X DELETE "$S/v1/files/notes/hello.txt" -H "$MOD" -H "$DOM")   (expect 204)"
echo "11. GET after delete            -> $(q "$S/v1/files/notes/hello.txt" -H "$MOD" -H "$DOM")   (expect 404)"
