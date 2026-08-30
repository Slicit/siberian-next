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


### 2026-08-30: the transport's own honesty was being thrown away

`example-relay` answers 2xx with `"sent": false`, deliberately, because its
author wrote that a transport which discards mail and reports success is a bug
in a nicer disguise. The core read that answer as `HTTP 200` and discarded the
rest, which put the bug straight back one layer up.

The message is still delivered as far as the queue is concerned, and should be:
the transport accepted it, and asking again would only produce another copy of
the same non-delivery. What changed is that the fact is written down, counted,
and read by the nightly scan.

`mail.transport.silent` is the alert, and it is deliberately separate from
`mail.transport.failing`. A transport that refuses everything is loud: messages
die and somebody notices. A transport that accepts and drops is quiet, and quiet
is the one worth waking somebody for.

### 2026-08-30: a smoke was leaving the product's mail switched off

`smoke-honest-manifest` installs `example-relay` to prove the probe accepts an
honest manifest, and left it installed. Installing it makes it the live
transport for the whole product, so every run of that smoke silently switched
off mail for everything afterwards, and every later run of every other smoke
happened on a system where nothing could arrive.

It uninstalls it now. The install is a test, not a configuration.

### 2026-08-30: the reset link is read out of the delivered mail

Both recovery smokes read the link out of the Mailer's own row. That proves the
message was composed with a link in it, which is a different fact from a person
receiving one, and for the life of the project it was the only fact available.

They read it out of mailpit now. The first attempt read the wrong message: a
greedy match took the last id in the list, which was the account verification
mail sent moments earlier, and its link is a verify link no reset endpoint
knows. Worth recording because the failure looked like a broken token rather
than a test reading the wrong mail.

### 2026-08-30: two checks that passed alone and failed in a sweep

`mailpit has exactly one message` is true when nothing else is happening and
false whenever the worker drains the queue alongside it. Counted by subject now.

`nothing is firing` asserted a globally clean alert board, next to a check that
was already incremental. A condition that is genuinely true, from something that
really happened, is not that check's business: it now asserts nothing new fired.

## Outcome

A message is sent over SMTP, arrives, and is read back: sender, recipient,
subject and body. Both password reset flows now take their link out of the
delivered mail rather than out of the queue, so what is proved is that a
person could have received it and used it.

`build_rfc822` assembles a message by hand and nothing had ever read the
result; now three smokes do.
