---
status: shipped
branch: feat-stable-subject
---

# Mail that provably left the building

## Intent

Everything about mail was covered except whether any of it was sent. The queue,
the retries, the dead letters, the acknowledgements and the throttles all had
checks. Not one of them touched a transport that sends.

## Decisions

### 2026-08-30: two layers of pretending, stacked

With no `SMTP_ADDRESS`, the built-in transport writes `[mail] would send ...` to
a log and returns `delivered`. That is honest in its own comment and invisible
from anywhere else.

Above it, the Mailer asks the Orchestrator which module implements
`mail.transport.v1`, and a module answers. The only one in the catalogue is
`example-relay`, whose own description says it "records what the Mailer hands it
and sends nothing onward". So on this box the queue reported `sent` with
`transport=example-relay`, truthfully, about a message that went nowhere.

Neither layer is a bug. Together they meant no byte of SMTP had ever been spoken
by this project, and every mail check was green.

### 2026-08-30: a sink with an API, so the assertion can be about arrival

Mailpit accepts SMTP on 1025 and hands back what it was given over HTTP. That
turns "the queue says sent" into "the recipient, the subject and the body are
these", which is the difference between exercising a code path and proving it.

It is a development service and says so where it is defined. A real deployment
points `SMTP_ADDRESS` at its own relay, or installs a transport module, which
takes precedence over the built-in entirely.

### 2026-08-30: and the first message found a bug in core code

`Net::SMTP.start` was always handed an auth type, even with no user name
configured, and raises `SMTP-AUTH requested but missing user name` before
opening a connection. The core could not send to any relay that does not demand
a password.

That is not an exotic case. It is the default for a local relay, a sidecar, and
most internal mail hosts. It survived because the two layers above meant the
line had never run: the first time anything reached it, it failed.

Authentication is now attempted only when there is a user name to attempt it
with.

### 2026-08-30: the transport is exercised directly

`bin/smoke-mail-delivery` calls `Transport::BuiltIn` rather than pushing through
the queue, because the queue resolves the interface and a module answers. The
built-in is the path a deployment without such a module uses, it is core code,
and it is the code that had never run.

Reverting the auth fix fails five of its checks, which is the test that was run
before trusting it.

## Outcome

A message is sent over SMTP, arrives, and is read back: sender, recipient,
subject and body. `build_rfc822` assembles a message by hand and nothing had
ever read the result; now something does.
