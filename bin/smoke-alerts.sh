#!/bin/sh
# Alerts, judged by what they refuse to say.
#
# The failure mode of an alerting system is not missing an incident. It is
# sending so many that nobody reads the one that mattered, and every check here
# is about a moment where the obvious implementation would have sent something
# and this one does not.
#
# Driven with a made-up disk reading, because that is the one condition whose
# input comes from outside: the scan is handed free megabytes by whoever can see
# the host, so a test can hand it a number without breaking anything.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

. "$(dirname "$0")/smoke-lib.sh"

runner() { $COMPOSE exec -T orchestrator bin/rails runner "$1" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }
posted() { $COMPOSE exec -T mailer bin/rails runner \
  'puts Message.where(core_sender: "core-orchestrator").count' </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }

# Cleared by scanning healthy rather than by deleting the rows.
#
# Deleting them resets the occurrence counter, so a second run of this script
# produced occurrence one again, which is the same idempotency key, which the
# Mailer correctly deduplicated into the first run's email. The script then
# failed on its own tidying up. Clearing the honest way keeps the counter
# advancing, which is what happens in production, where nothing deletes these.
runner '2.times { AlertScan.new(free_megabytes: 50_000).call }; puts "clear"' >/dev/null

scan() { runner "puts AlertScan.new(free_megabytes: $1).call.opened.join(',')"; }

echo "1. something wrong once is not an incident"
BEFORE=$(posted)
check "the first scan says nothing" "$(scan 100)" ""
check "and emails nobody" "$(posted)" "$BEFORE"

echo "2. something wrong twice is"
check "the second scan opens it" "$(scan 100)" "disk.low"
sleep 2
AFTER=$(posted)
[ "$AFTER" -gt "$BEFORE" ] && check "and somebody is emailed" "sent" "sent" \
  || check "and somebody is emailed" "nothing" "sent"

echo "3. still wrong is not news"
SETTLED=$(posted)
check "the third scan says nothing new" "$(scan 100)" ""
check "the fourth says nothing either" "$(scan 90)" ""
sleep 2
check "and no more email went" "$(posted)" "$SETTLED"

echo "4. but the page still shows it, with today's number"
check "it is firing" "$(runner 'puts AlertCondition.find_by(key: "disk.low").state')" "firing"
contains "and the detail is current" \
  "$(runner 'puts AlertCondition.find_by(key: "disk.low").detail')" "90 MB"

echo "5. better is worth saying, once"
check "clearing it is reported" "$(runner 'puts AlertScan.new(free_megabytes: 50_000).call.closed.join(",")')" "disk.low"
sleep 2
RESOLVED=$(posted)
check "the scan after that is silent" \
  "$(runner 'puts AlertScan.new(free_megabytes: 50_000).call.closed.join(",")')" ""
sleep 2
check "and sent nothing more" "$(posted)" "$RESOLVED"

echo "6. the resolution email says so"
contains "it names what recovered" \
  "$($COMPOSE exec -T mailer bin/rails runner \
     'puts Message.where(core_sender: "core-orchestrator").order(:id).last&.text_body.to_s' </dev/null 2>/dev/null)" \
  "Resolved"

echo "7. a healthy system adds nothing to the list"
BEFORE_ROWS=$(runner 'puts AlertCondition.count')
runner 'AlertScan.new(free_megabytes: 50_000).call' >/dev/null
check "no new row for a healthy thing" "$(runner 'puts AlertCondition.count')" "$BEFORE_ROWS"
check "and nothing is firing" "$(runner 'puts AlertCondition.firing.count')" "0"

finish "alerts"
