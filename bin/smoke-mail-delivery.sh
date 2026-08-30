#!/bin/sh
# Whether a message actually leaves the building.
#
# Everything else about mail was already covered: the queue, the retries, the
# dead letters, the acknowledgements. None of it touched a transport that sends.
# With no SMTP_ADDRESS the built-in writes "would send" to a log and reports the
# message delivered, and the only transport module in the catalogue records what
# it is handed and says so in its own description. So every mail check in this
# repository passed for the life of the project without one byte of SMTP being
# spoken, which is the same shape as the transport that 404ed for weeks.
#
# Mailpit is a dev sink with an HTTP API, so this asserts on what arrived rather
# than on what the queue said about it.
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
MAILPIT="http://mailpit:8025/api/v1"

. "$(dirname "$0")/smoke-lib.sh"

STAMP=$(date +%s)
SUBJECT="Delivery proof $STAMP"

# Run from inside the mailer, because mailpit is on the core network and has no
# door to the outside. That is deliberate: it is a test fixture, not a mailbox.
inside() { $COMPOSE exec -T mailer sh -c "$1" </dev/null 2>/dev/null | tr -d '\r'; }
runner() { $COMPOSE exec -T mailer bin/rails runner "$1" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }

inside "curl -s -X DELETE $MAILPIT/messages" >/dev/null

echo "1. the core's own transport speaks SMTP"
# Exercised directly rather than through the queue, because the queue asks the
# Orchestrator which module implements mail.transport.v1 and a module answers.
# This is the path a deployment with no such module uses, and it is core code.
RESULT=$(runner "
  m = Message.new(domain: 'siberian.test', to: 'proof-$STAMP@example.test',
                  subject: '$SUBJECT', text_body: 'The body survived the trip.',
                  core_sender: 'smoke')
  r = Transport::BuiltIn.new.deliver(m)
  puts \"#{Transport::BuiltIn.new.name}/#{r.outcome}/#{r.detail}\"
")
check "it reports itself as SMTP rather than a recorder" "${RESULT%%/*}" "core-smtp"
contains "and says it delivered" "$RESULT" "/delivered/"

echo "2. and something arrived"
# The check that could not be made before. A transport reporting success and a
# transport that sent something are different facts, and only one of them was
# ever observable.
sleep 1
BOX=$(inside "curl -s $MAILPIT/messages")
# Counted by subject rather than by total. The worker is draining the queue
# the whole time this runs, so anything else the stack sent in the same second
# lands in the same sink: asserting the sink holds exactly one message is a
# check that passes alone and fails in a sweep.
check "mailpit has the message that was just sent" \
  "$(printf '%s' "$BOX" | grep -c "$SUBJECT")" "1"
contains "with the subject that was sent" "$BOX" "$SUBJECT"
contains "addressed to the recipient" "$BOX" "proof-$STAMP@example.test"
contains "from the configured sender" "$BOX" "no-reply@siberian.test"

echo "3. the message the recipient would read"
ID=$(printf '%s' "$BOX" | sed 's/.*"ID":"\([^"]*\)".*/\1/')
present "it has an id" "$ID"
BODY=$(inside "curl -s $MAILPIT/message/$ID")
# build_rfc822 assembles the headers and body by hand. Nothing had ever read
# the result back, so this is the first check that it is a message at all.
contains "the body arrived intact" "$BODY" "The body survived the trip."

echo "4. a relay that wants no password is not refused"
# The bug this found. Net::SMTP raises "SMTP-AUTH requested but missing user
# name" when handed an auth type and no user, so the core could not send to any
# relay that does not demand a password, and nothing anywhere noticed.
check "no credentials are configured here" "$(inside 'printf %s "$SMTP_USERNAME"')" ""
check "and it sent anyway" "$(printf '%s' "$BOX" | grep -c "$SUBJECT")" "1"

inside "curl -s -X DELETE $MAILPIT/messages" >/dev/null

finish "mail delivery"
