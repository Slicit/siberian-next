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
| Host | `claude-machine-01.home`, user `claude`, passwordless sudo. Address it by name: the box takes its address by DHCP, so the IP moves. It was `192.168.1.86` when this was written |
| SSH | `ssh claude-machine-01`, or the older alias `ssh siberian`. Key `~/.ssh/siberian_debian`. There is more than one box: see the `claude-machine` skill before running anything destructive |
| Repo | `~/siberian-next`, remote over SSH, pushes as `Slicit` |
| Engine | Docker 29.7.2 |
| Services | 13 containers: 7 Rails apps, a mail worker, a build worker, the Router, two Postgres clusters, and the object store |
| Domains | Every domain in the `domains` table is served, each with its own shell, Backoffice, and object store door. `siberian.test` is the one with a certificate |
| Object store | Behind a driver (`lib/object_store`), Garage by default, S3 for AWS or anything speaking its API. Reachable from a browser at `s3.<domain>` for signed URLs |
| Credentials | One secret per pair of services, not one shared admin token. `SIBERIAN_CALLERS` and `SIBERIAN_CALLEES` per service |
| Housekeeping | Nightly at 04:30 via `/etc/cron.d/siberian-housekeeping`, logging to `/var/log/siberian-housekeeping.log`. Installed by `deploy/maintenance/install.sh` |
| Checks | Nightly at 05:00 via `/etc/cron.d/siberian-checks`, logging to `/var/log/siberian-checks.log`. The Overview shows the result |
| Assistant | `ANTHROPIC_API_KEY` in `.env`, read by the Mobile service alone. Absent, the app studio says so and everything else works |

The laptop is for authoring. The loop is edit locally, commit, push, pull on the
box, run there. Run `./bin/reload` after a pull or a branch switch: shared `lib/`
code is required at boot rather than reloaded, and a branch switch can replace a
bind-mounted directory underneath a running container. Two more things about
that loop have bitten already:

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
   from the domains and modules actually installed.

   These are addresses rather than `claude-machine-01.home`, because a hosts
   file maps names to addresses and cannot point one name at another. So this
   is the one place the DHCP address matters: regenerate it if the box moves.

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
./bin/check              architecture and convention checks, no stack needed
./bin/check-boot         every service loads what it names, and boots in production
./bin/reload             make the running stack match the checkout, after a pull
./bin/test-lib           the shared library suite
./bin/test-engine        the engine driver against a real daemon
./bin/smoke-auth         sign in, and the cookie lands scoped and Secure
./bin/smoke-access       every page against three roles, and a surgical deny
./bin/smoke-storage      register, provision, and every verb and refusal
./bin/smoke-quotas       all three quota levels, including a refusal from each
./bin/smoke-domains      a domain allowance set before a module stores anything
./bin/smoke-domains-served  every domain in the database answers on all three doors
./bin/smoke-public-media public files served from the object store, and four refusals
./bin/smoke-s3-backend   the object store driver against a second, different store
./bin/smoke-reconcile    a registration the Mobile service lost, put back
./bin/smoke-mobile       the phone app for a domain, its capabilities, and its queue
./bin/smoke-cms          a page of blocks, in the browser and as JSON for the app
./bin/smoke-push         an inbox, and read, archive and delete staying different
./bin/smoke-mail         enqueue, deliver, acknowledge, and a permanent rejection
./bin/smoke-backoffice   every Backoffice page, as an operator and as a plain user
./bin/smoke-demo         the demo module end to end over HTTPS
./bin/smoke-modules      both reference modules, PHP and Python
```

`bin/check` runs two architecture guards worth knowing by name, because they
fail the build rather than warn: `check-engine-leak` refuses a container engine
named outside `lib/siberian_engine`, and `check-storage-leak` refuses an object
store backend named outside `lib/object_store`.

Two smokes are slow on purpose. `smoke-access` waits out the 30 second
permission cache to prove a revocation actually bites, and `smoke-mail` waits
for the worker to pick up a message. Shortening either would test a shorter
window than the one that ships.

`smoke-s3-backend` pulls an image for a second object store and skips rather
than fails when it cannot, so a registry hiccup does not turn the sweep red.

### All of them, nightly and unattended

```
./deploy/maintenance/nightly-checks.sh
```

Runs everything above, records each result rather than stopping at the first
failure, and writes `deploy/checks/latest.json`, which the Backoffice Overview
reads. Installed by `deploy/maintenance/install.sh` to run at 05:00 as the user
who owns the checkout, after housekeeping has freed the disk.

It refuses to run as root. The smokes keep working files at fixed paths in
`/tmp`, so a root run leaves root-owned files there and the next run by a person
cannot overwrite them, which surfaces as a smoke reporting that the bytes came
back wrong.

The Overview card is red when the sweep failed and also when the sweep is more
than forty hours old, because a green tick from a sweep that stopped running is
the failure this exists to remove.

Rails suites run per service:

```
docker compose --env-file .env -f deploy/compose.yml exec -T \
  -e RAILS_ENV=test \
  -e DATABASE_URL=postgres://postgres:postgres_dev_only@configuration:5432/siberian_<service>_test \
  <service> bin/rails test
```

## When something is broken

**Several unrelated things break at once.** Check `df -h /` first. The box
filled to 100 percent once and the symptoms were Postgres refusing writes and
services failing to boot, none of which points at a disk. Housekeeping runs
nightly (below); to see what it has been doing, `sudo tail
/var/log/siberian-housekeeping.log`, and to run it now:

```
sudo SIBERIAN_REPO=~/siberian-next ~/siberian-next/deploy/maintenance/housekeeping.sh
```


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

**A build succeeded and the app did not change.** The builder mounts
`core/mobile-builder`, so an edit is visible inside the container at once and
`grep` there will confirm it, but Node had already loaded the module and kept
building from the code it started with. The worker now hashes its own source
between builds and exits when it differs, and Compose restarts it, so the log
says `builder source changed ... restarting`. If it does not, check the worker
is actually up.

**The app preview is a blank frame.** Look at what the page asks for. An export
whose asset paths are root-absolute sends the browser to the Backoffice root
rather than to `/mobile/:id/preview/`, and the only symptom is a 404 in the
browser console. The export now makes those paths relative and fails the build
if it names a file it did not produce, so this should surface as a failed build
rather than an empty phone.

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
- **No assistant on this box.** The app studio proposes a configuration from a
  description, which needs an `ANTHROPIC_API_KEY` in `.env`. Without one the
  page says the assistant is not configured and the rest of it still works.
- **No iOS binary.** Apple's toolchain runs on macOS, so the builder produces
  the configured Xcode project and stops. The artifact is a zip of `ios/`, the
  package manifest, the generated module registry, and any native module
  source: on a Mac that is `npm install && cd ios && pod install`, then open the
  workspace. Signing and an `.ipa` need a macOS runner or EAS.
- **No over the air updates, and no store submission.** A build produces an
  artifact; getting one onto a phone that already has the app is a different
  mechanism.
- **One builder.** Two domains asking at once are two rows in a queue. The
  claim query is already written for more than one worker, so adding a second
  is a compose change, but nothing scales itself yet.
