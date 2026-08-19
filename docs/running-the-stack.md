# Running the stack

Where this actually runs, how to bring it back, and how to check it is working
without reading anything else.

If you are picking this up cold, read `LOGBOOK.md` first for what the system is,
then this for where it is.

## Where it runs

Development happens on a Debian 13 box, not on a laptop. The project is a
container orchestrator, so a Linux host with a real engine is the target, not a
convenience.

| | |
|---|---|
| Host | `192.168.1.86`, user `claude`, passwordless sudo |
| SSH | `ssh siberian` (alias in `~/.ssh/config`, key `~/.ssh/siberian_debian`) |
| Repo | `~/siberian-next`, remote over SSH, pushes as `Slicit` |
| Engine | Docker 29.7.2 |
| Domain | `siberian.test` over HTTPS, behind a local CA |

The laptop is for authoring. The loop is edit locally, commit, push, pull on the
box, run there. Anything generated on the box (Rails apps, migrations, schema
dumps) has to be committed **from** the box, which is a step easy to forget: CI
once checked out five services with no initializer because a generator ran there
and its output never left.

## Bringing it up

```
ssh siberian
cd ~/siberian-next

./bin/setup                     # checks the engine is reachable, writes .env
./bin/generate-certs            # local CA and wildcard certificate, once
./bin/up                        # the core
./bin/garage-init               # assigns Garage a layout, once
```

Then the databases, once per service:

```
docker compose --env-file .env -f deploy/compose.yml exec -T <service> bin/rails db:prepare
```

and the demo accounts:

```
docker compose --env-file .env -f deploy/compose.yml exec -T auth bin/rails db:seed
```

Modules are built locally and installed through the Backoffice:

```
./bin/build-module example-notes
./bin/build-module demo-tasks
```

## Getting to it from a browser

Certificates and DNS both need help, because neither wildcard DNS nor a trusted
CA exists on a laptop by default.

1. Trust `deploy/certs/ca.pem` in the OS store, and separately in Firefox, which
   keeps its own.
2. Add hosts entries pointing at the box. Wildcards are not possible in a hosts
   file, so **every module origin needs its own line**, which is the sharpest
   rough edge in the setup:

```
192.168.1.86 siberian.test
192.168.1.86 admin.siberian.test
192.168.1.86 tasks.apps.siberian.test
192.168.1.86 notes.apps.siberian.test
```

| Where | What |
|---|---|
| `https://siberian.test` | the product shell |
| `https://admin.siberian.test` | the Backoffice, operators only |
| `https://<module>.apps.siberian.test` | one module, its own origin |

Demo accounts, seeded and deliberately obvious: `operator@siberian.localhost`
and `user@siberian.localhost`, password `siberian-demo`. The email suffix is an
identifier, not a hostname, which is why it did not change with the domain.

## Checking it works

Every one of these drives the real stack. They are the fastest way to answer
"is it still working" without reading a transcript.

```
./bin/check            architecture and convention checks, no stack needed
./bin/test-lib         the shared library suite
./bin/test-engine      the engine driver against a real daemon
./bin/smoke-auth       sign in, and the cookie lands scoped and Secure
./bin/smoke-storage    register, provision, and every verb and refusal
./bin/smoke-backoffice every Backoffice page, as an operator and as a plain user
./bin/smoke-demo       the demo module end to end over HTTPS
./bin/smoke-modules    both reference modules, PHP and Python
```

Rails suites run per service:

```
docker compose --env-file .env -f deploy/compose.yml exec -T \
  -e RAILS_ENV=test \
  -e DATABASE_URL=postgres://postgres:postgres_dev_only@configuration:5432/siberian_<service>_test \
  <service> bin/rails test
```

## When something is broken

**Every module route answers 502.** The Router was probably rebuilt. A new
container has none of the network attachments the old one had, so it can no
longer resolve any module. Fix it from the Backoffice with **Repair routing**,
or:

```
docker compose --env-file .env -f deploy/compose.yml exec -T orchestrator \
  bin/rails runner "puts RouteReconciler.new.call.errors.inspect"
```

**One module 502s for a few seconds after a reinstall.** nginx caches the
resolved address for `valid=10s`. It recovers on its own.

**A module reports a wrong database password.** Its role is probably `NOLOGIN`
from a previous uninstall. Reinstalling reactivates it; if not, check
`pg_roles.rolcanlogin` on `moduledb`.

`LOGBOOK/notes.md` has the full list, including the ones that cost the most time.

## What is not built

- No Mailer beyond a health endpoint.
- No SDKs. Modules hand-roll their HTTP, which is the point of the contract
  being small but not an argument against helping.
- No `tmp` sweeper in Storage, and no Router rule for `/-/public/<path>`.
- No Backoffice view of the Database audit trail, which exists and nobody can
  read without curl.
- No wildcard DNS, so adding a module means editing a hosts file.
