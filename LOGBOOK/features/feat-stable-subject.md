---
status: shipped
branch: feat-stable-subject
---

# A name for a person that is not their address

## Intent

Every module keyed its rows by email address. `demo-tasks` had `user_email text
NOT NULL`, `example-push` had two tables on it, `example-notes` inserted by it.
An address is how somebody signs in. It was never meant to be who they are.

Two costs followed, one already worked around and one waiting to happen. The
core could not let anybody end an account and free the address, because the next
person to claim it would open a module and find the last person's data; that is
why `deleted_at` exists rather than a real delete. And changing an address would
have orphaned everything somebody ever made, in every module at once, with
nothing anywhere reporting it. Nobody could change one yet, which is the only
reason it had not happened.

## Decisions

### 2026-08-30: a prefix, not a bare id

`app_users` and `users` are separate tables with separate sequences, so operator
7 and app user 7 both exist. Both kinds use modules: most of the rows in this
box's `demo-tasks` database turned out to belong to the operator, not to an app
user. A module keying by a bare id would have put two people's rows in one pile,
and the first symptom would have been somebody opening a module and seeing data
that was not theirs.

So `au_` and `cu_` in front of a uuid. Structurally impossible to confuse, and
self-describing wherever it turns up: in a module's table, in a log line, in a
support question about whose row this is.

### 2026-08-30: backfilled on a visit, not by a lookup

Existing rows had to be attached to their owners, and a module cannot ask the
core for the subject behind an address. It should not be able to: that is a
lookup from an address to a person, which is exactly what a module has no
business doing.

What a module can do is wait. When somebody visits it is holding both halves of
the mapping and the join is free, so each module claims its own old rows once
per person, hanging off the one place every handler passes through before it can
query for anybody. Rows whose owner never returns stay unclaimed, which is the
right outcome: unclaimed is better than handed to the wrong person.

### 2026-08-30: modules stop storing addresses at all

New rows carry a subject and nothing else. This started as a `NOT NULL`
violation and turned into the better answer: keeping a copy of everybody's email
address in every module database is a cost with no remaining benefit, now that
the core owns the mapping. A module that never stores an address cannot leak one
or be asked to forget one.

The column stays nullable for the old rows the backfill still needs to find, and
can be dropped once there are none.

### 2026-08-30: the soft delete has to stay, and now it is possible to say why

Freeing an address on deletion is still unsafe, but for a smaller and more
precise reason than before. Reads are keyed by subject, so a new person with a
reused address sees nothing of the old one's. What is not safe is the backfill:
`WHERE user_email = ... AND user_subject IS NULL` would attach the previous
person's unclaimed rows to whoever took the address next.

So the rule is exact. The address can be freed once no module is still running a
backfill keyed on it, which is a thing that can be finished and checked, rather
than the open-ended "every module would have to change" it was before.

### 2026-08-30: a test that asserted an exact key list

Adding `subject` to the identity broke a test whose own comment said it
deliberately did not assert an exact key list, immediately above an assertion of
an exact key list. It now asserts what must always be present and what must
never be, which is what the comment always claimed.

## Outcome

`bin/smoke-identity` proves the properties on real rows in a real module
database: the address moves, the name does not, and the task is still theirs. It
also proves the negative, that a second person with a different subject sees
none of the first one's rows, not even under the address the first one gave up.

Eight tests in `core/auth/test/models/stable_subject_test.rb` cover the naming
itself, including that an operator and an app user sharing an id are still told
apart.
