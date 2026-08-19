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
| Services | 14 containers: 7 Rails apps, a mail worker, a build worker, the Router, two Postgres clusters, and Garage |
| Domain | `siberian.test` over HTTPS, behind a local CA |

The laptop is for authoring. The loop is edit locally, commit, push, pull on the
box, run there. Two things about that loop have bitten already:

- Anything generated on the box (Rails apps, migrations, schema dumps) has to be
  committed **from** the box. CI once checked out five services with no
  initializer because a generator ran there and its output never left.
- Containers write `tmp` and `log` as root. If either is ever tracked, `git
  pull` on the box fails with `unable to unlink old ...: Permission denied`,
  which reads as a broken checkout. The fix is `sudo chown -R claude:claude
  core/*/tmp core/*/log`, and then making sure the app has a `.gitignore`.

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
   rough edge in the setup. `bin/hosts-file` prints the current set, on the box,
   from the domains and modules actually installed:

```
./bin/hosts-file
```

```
# siberian-next, generated 2026-08-19 by bin/hosts-file
192.168.1.86 siberian.test
192.168.1.86 core.siberian.test
192.168.1.86 example-relay.apps.siberian.test
192.168.1.86 notes.apps.siberian.test
192.168.1.86 tasks.apps.siberian.test
# end siberian-next
```

   Rerun it after installing a module or adding a domain. On Windows the file
   is `C:WindowsSystem32driverstchosts` and needs an Administrator editor.

| Where | What |
|---|---|
| `https://siberian.test` | the product shell |
| `https://core.siberian.test` | the Backoffice, operators only |
| `https://<module>.apps.siberian.test` | one module, its own origin |

Demo accounts, seeded and deliberately obvious, password `siberian-demo`:

| Account | Role | Can |
|---|---|---|
| `owner@siberian.localhost` | owner | everything, including changing who else can do what |
| `operator@siberian.localhost` | operator | run the system, but not rewrite access |
| `user@siberian.localhost` | member | use the product and its modules, nothing in the Backoffice |

The email suffix is an identifier, not a hostname, which is why it did not
change when the domain did.

## Checking it works

Every one of these drives the real stack. They are the fastest way to answer
"is it still working" without reading a transcript.

```
./bin/check            architecture and convention checks, no stack needed
./bin/test-lib         the shared library suite
./bin/test-engine      the engine driver against a real daemon
./bin/smoke-auth       sign in, and the cookie lands scoped and Secure
./bin/smoke-access     every page against three roles, and a surgical deny
./bin/smoke-storage    register, provision, and every verb and refusal
./bin/smoke-quotas     all three quota levels, including a refusal from each
./bin/smoke-domains    a domain allowance set before a module stores anything
./bin/smoke-mobile     the phone app for a domain, its capabilities, and its queue
./bin/smoke-mail       enqueue, deliver, acknowledge, and a permanent rejection
./bin/smoke-backoffice every Backoffice page, as an operator and as a plain user
./bin/smoke-demo       the demo module end to end over HTTPS
./bin/smoke-modules    both reference modules, PHP and Python
```

Two of them are slow on purpose. `smoke-access` waits out the 30 second
permission cache to prove a revocation actually bites, and `smoke-mail` waits
for the worker to pick up a message. Shortening either would test a shorter
window than the one that ships.

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

**A core service cannot reach a module.** It addresses it as
`http://modules/<name>/<path>`, never by the module's own name: only the Router
is on both networks. Addressing it directly fails DNS resolution, which reads as
a broken module rather than as a missing door.

**Mail is queued and never sends.** Check the worker is up, not just the mailer:
they are separate containers. `docker compose ... logs mailer-worker` shows the
claim query and every delivery.

**A permission change has not taken effect.** It is cached for 30 seconds per
session. Wait, or use the endpoint that never caches.

`LOGBOOK/notes.md` has the full list, including the ones that cost the most time.

## What is not built

Deliberate, not forgotten:

- **No SDKs.** Modules hand-roll their HTTP, which is the point of the contract
  being small, but not an argument against helping.
- **No wildcard DNS.** Adding a module means editing a hosts file. `bin/hosts-file`
  generates the block rather than leaving it to be remembered, but pasting it
  still does not scale past a handful of modules.
- **No Backoffice view of the mail queue or the database audit trail.** Both
  exist behind `/admin` endpoints and an operator currently needs curl to see
  why mail is not arriving, which is the moment they would least want to.
- **No alerting anywhere.** The Backoffice shows storage usage; a domain filling
  up overnight tells nobody.
- **No `tmp` sweeper in Storage**, and no Router rule for `/-/public/<path>`.
  No module has needed either, and building them first would be guessing.
- **No templates in the Mailer**, no inbound mail, no bounce handling.
- **No per-space storage quotas.** A module's `public` and `files` share one
  allowance.
- **No OAuth, SSO, or 2FA.** Auth is password sessions.
- **No iOS binary.** Apple's toolchain runs on macOS, so the builder produces
  the configured Xcode project and stops. Signing and an `.ipa` need a macOS
  runner or EAS.
- **No over the air updates, and no store submission.** A build produces an
  artifact; getting one onto a phone that already has the app is a different
  mechanism.
- **One builder.** Two domains asking at once are two rows in a queue. The
  claim query is already written for more than one worker, so adding a second
  is a compose change, but nothing scales itself yet.
