#!/bin/sh
# What a module keys its rows by, and what that survives.
#
# Modules used to key by email address. An address is how somebody signs in; it
# was never meant to be who they are, and using it as a name had two costs. The
# core could not let anybody end an account and free the address, because the
# next person to claim it would open a module and find the last person's data.
# And changing an address would have orphaned everything somebody ever made, in
# every module at once, with nothing anywhere reporting it.
#
# So the core hands out a subject: stable, never reused, and prefixed by which
# kind of account it names. This proves the properties that follow from it, on
# real rows in a real module database.
DOMAIN="${SIBERIAN_DOMAIN:-siberian.test}"
CA="${SIBERIAN_CA:-deploy/certs/ca.pem}"
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"

. "$(dirname "$0")/smoke-lib.sh"

STAMP=$(date +%s)
FIRST="ident-$STAMP@example.test"
MOVED="moved-$STAMP@example.test"

a() { curl -s --cacert "$CA" -H "Content-Type: application/json" "$@"; }
runner() { $COMPOSE exec -T "$1" bin/rails runner "$2" </dev/null 2>/dev/null | tail -1 | tr -d '\r'; }
tasks_db() {
  $COMPOSE exec -T moduledb psql -U postgres -d "$TASKS_DB" -tAc "$1" </dev/null 2>/dev/null | tr -d '\r'
}

# Asked for by module and domain rather than guessed from the name. There is
# one database per (module, domain) pair, and picking the first that matches
# the module gives whichever domain sorts first, which is a smoke that passes
# while testing somebody else's data.
TASKS_DB=$(runner database \
  "puts ActiveRecord::Base.connection.select_value(%{SELECT database_name FROM provisioned_databases pd JOIN module_registrations mr ON mr.id = pd.module_registration_id WHERE mr.module_name = 'demo-tasks' AND pd.domain = '$DOMAIN'})")
present "found the tasks database" "$TASKS_DB"

echo "1. the core names everybody, and never twice"
runner orchestrator "Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$FIRST', password: 'long-enough-1', name: 'Ident' })" >/dev/null
SUBJECT=$(runner auth "puts AppUser.find_by(email: '$FIRST').subject")
contains "an app user is named au_" "$SUBJECT" "au_"
contains "an operator is named cu_" "$(runner auth "puts User.first.subject")" "cu_"

# The reason for the prefixes rather than a bare id. Two tables, two sequences,
# so operator 7 and app user 7 both exist: a module keying by a bare id would
# put their rows in one pile, and the first symptom would be somebody opening a
# module and seeing another person's data.
check "and the two are told apart even at the same id" \
  "$(runner auth "puts [AppUser.first.id == User.first.id, AppUser.first.subject == User.first.subject].inspect")" \
  "[true, false]"

echo "2. a module is handed the name, not the address"
TOKEN=$(a -X POST -d "{\"email\":\"$FIRST\",\"password\":\"long-enough-1\",\"device_id\":\"d-$STAMP\"}" \
  "https://$DOMAIN/-/auth/sign-in" | sed 's/.*"token":"\([^"]*\)".*/\1/')
present "signed in" "$TOKEN"
contains "the identity carries the subject" \
  "$(a -H "Authorization: Bearer $TOKEN" "https://$DOMAIN/-/auth/me")" "$SUBJECT"

echo "3. rows are written under it"
runner orchestrator "true" >/dev/null
tasks_db "INSERT INTO tasks (user_subject, title) VALUES ('$SUBJECT', 'before the move')" >/dev/null
check "one task, keyed by the subject" \
  "$(tasks_db "SELECT count(*) FROM tasks WHERE user_subject = '$SUBJECT'")" "1"
# The address is not copied into the module at all. A module that never stores
# one cannot leak one or be asked to forget one.
check "and no address was stored with it" \
  "$(tasks_db "SELECT count(*) FROM tasks WHERE user_subject = '$SUBJECT' AND user_email IS NOT NULL")" "0"

echo "4. changing the address keeps the rows"
# The failure this whole shape exists to prevent. Keyed by address, this would
# orphan everything the person ever made, here and in every other module at
# once, and nothing anywhere would report it.
runner auth "u = AppUser.find_by(email: '$FIRST'); u.update!(email: '$MOVED'); puts u.email" >/dev/null
check "the address moved" "$(runner auth "puts AppUser.find_by(email: '$MOVED')&.email")" "$MOVED"
check "the name did not" "$(runner auth "puts AppUser.find_by(email: '$MOVED').subject")" "$SUBJECT"
check "and the task is still theirs" \
  "$(tasks_db "SELECT count(*) FROM tasks WHERE user_subject = '$SUBJECT'")" "1"

echo "5. and nobody else can be handed them"
SECOND="other-$STAMP@example.test"
runner orchestrator "Siberian::AuthClient.new.create_app_user('$DOMAIN', { email: '$SECOND', password: 'long-enough-1' })" >/dev/null
OTHER=$(runner auth "puts AppUser.find_by(email: '$SECOND').subject")
check "a second person gets a different name" \
  "$(runner auth "puts AppUser.find_by(email: '$SECOND').subject == '$SUBJECT'")" "false"
check "and sees none of the first one's rows" \
  "$(tasks_db "SELECT count(*) FROM tasks WHERE user_subject = '$OTHER'")" "0"

# Even taking the address the first person left behind, which is the case the
# core currently forbids and which this makes safe to allow later.
check "not even under the address the first one gave up" \
  "$(tasks_db "SELECT count(*) FROM tasks WHERE user_email = '$FIRST'")" "0"

tasks_db "DELETE FROM tasks WHERE user_subject IN ('$SUBJECT', '$OTHER')" >/dev/null

finish "identity"
