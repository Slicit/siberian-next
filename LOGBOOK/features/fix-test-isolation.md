---
status: shipped
branch: fix-test-isolation
---

# The development loop tells the truth

## Intent

Three findings in one day were found by accident rather than by anything that
was supposed to find them. This is about the things that were supposed to.

Three service suites were red on the box. Seven of nineteen smokes could not
fail. The JSX the phone app is built from was parsed by nothing until a build
ran. None of that was known until somebody looked.

## Decisions

### 2026-08-29: the suites were fine, the way they were run was not

`bin/rails test` inside a service container runs against the **development**
database. Every service is handed a `DATABASE_URL`, Rails merges that into every
environment including test, and so the suite reads and writes live data.

It failed in ways that were about the data rather than the code: a test
expecting one module registration found forty-seven. And it wrote, so every run
left rows behind in a database somebody was using.

CI never had this, because it sets `DATABASE_URL` to its own test database
explicitly. `bin/test-service` now does the same thing, which is why the fix is
a wrapper rather than a change to `database.yml`: `DATABASE_URL` wins over the
file, so the only reliable way to point a suite somewhere else is to set it.

With that, all seven suites pass. Nothing was hiding behind the noise, which was
the thing worth finding out.

### 2026-08-29: mobile was in no matrix at all

The CI matrix listed six services and there are seven. The Mobile service's
tests ran nowhere, in CI or on the box, and the artifact retention work landed
against a suite nobody was running. Added.

### 2026-08-29: a check that narrates is not a check

Seven smokes printed what they got beside a sentence about what they were doing
and exited zero either way: access, auth, backoffice, domains, mail, modules,
push. The nightly job records exit codes, so each of them reported OK every
night regardless of what the system did.

`smoke-mail` is the one that proves the cost. Step 9 printed the state a message
ended in, beside a sentence about permanent rejections. The state it printed
every night was `dead`, because the transport module answered 404 to everything
and had done since it was written. A green run, every night, for a mail system
that delivered nothing.

They now assert. One helper in `bin/smoke-lib.sh` rather than seven, because
`smoke-quotas` had already grown its own and an eighth variant was the
alternative. Failures accumulate instead of exiting at the first one: a smoke
that stops on step 2 hides whether 3 to 12 also broke, and finding that out is
why it is being run.

Two things the conversion turned up, both of which had been passing:

- `smoke-modules` counted rows by a fixed title, so "archiving removed it from
  the open list" was answered by somebody else's task from a previous run.
  Titles are stamped per run now.
- `smoke-access` printed a matrix of status codes with no statement of what they
  should be. The expectation is now written out, derived from the seeded roles
  and the `requires` line on each controller rather than from a previous run's
  output. Every cell matched, which is worth knowing rather than assuming.

### 2026-08-29: the JSX was parsed by nothing

A missing bracket in a native screen surfaced when a build ran: minutes for the
web export, over half an hour for Android. `bin/check-native` parses all seven
files in under a second.

The parser comes from whichever of two places has it, and the runner is chosen
once up front so a file that genuinely fails to parse is reported rather than
mistaken for a missing dependency and retried elsewhere. When it can find
neither it refuses, because a check that passes silently when it could not run
is worse than no check: the green is read as an answer.

### 2026-08-29: the smokes were leaking credentials

Twenty-four active module registrations in the development stack, one per
abandoned smoke run, each a live token nothing was using and nothing would ever
revoke. The revoke was the last line of a script that exits early on failure.

Both scripts now revoke in a `trap`, so the credential goes however the run
ends. The twenty-four were revoked.

## Outcome

| | before | after |
|---|---|---|
| service suites runnable on the box | 4 of 7 | 7 of 7 |
| services in the CI matrix | 6 | 7 |
| smokes that can fail | 12 of 19 | 19 of 19 |
| native files parsed before a build | 0 of 7 | 7 of 7 |
| abandoned smoke credentials | 24 | 0 |

244 service runs, 128 lib runs, `bin/check` clean, and all nineteen smokes
passing, every one of which is now capable of not passing.

## What this does not do

- **`bin/test-service` needs the stack up.** It runs each suite in its own
  container, which is the point: it uses the same Ruby, gems and Postgres the
  service does. CI covers the case where nothing is running.
- **The integration suite still runs only from `bin/test-engine`.** It creates
  real containers, and that is a deliberate exclusion rather than an oversight.
- **The JSX check parses; it does not type check.** A file that parses can still
  reference something that does not exist, and only a build finds that.
