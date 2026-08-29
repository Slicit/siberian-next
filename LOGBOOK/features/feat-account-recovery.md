---
status: shipped
branch: feat-account-recovery
---

# Getting back in

## Intent

App users shipped without a way to recover a password, which was written down as
the first thing to add. An account somebody cannot get back into is an account
they abandon, and the operator had no remedy either.

The endpoint is also the most abusable thing in the system: public,
unauthenticated, and it sends an email to any address it is given. So this is
one feature and two halves, recovery and the limits on it, and the second half
covers app sign-in as well, which was equally unthrottled.

## Decisions

### 2026-08-29: the core can send mail, without becoming a module

The Mailer was built for modules and every message hung off a module
registration. Auth is the first thing in the core to send anything.

Registering Auth as a module would have cost nothing and been wrong: "module"
means the packaged third-party unit everywhere else here, and a schema where it
also means "a core service" is a word that has to be explained every time. So a
message belongs to a sender, and a sender is either a module or a named core
service, with a check constraint saying exactly one. The caller proves itself
with the per-pair service token it already holds rather than a module token it
has no business having.

Everything downstream was untouched, because none of it cared which kind it was:
the queue, the backoff, the dead state, the transport interface. The one thing
that did care was the transport's log line, which reached through the
association and got nil.

### 2026-08-29: the same answer whether the address exists or not

`/-/auth/forgot` always answers "if that address has an account, a reset link is
on its way". Anything else makes it a way to ask whether somebody has an account
on this domain, and per-domain identity is exactly what makes that question
worth asking: knowing somebody is a customer here is itself the leak.

The reset endpoint is the opposite, and deliberately. An expired link says it
expired and a spent one says it was used, because holding the token is already
the secret, and a person who read the email an hour late has done nothing wrong
and needs to be told what to do.

### 2026-08-29: a reset ends every device

The usual reason to reset a password is that somebody else knows it. A reset
that leaves that person signed in on their own phone has not done the thing it
was asked to do.

Asking again also kills the earlier link, so somebody who clicks twice because
the first email was slow finds the newest one working rather than holding two
live keys. And a password that fails validation leaves the link usable, because
spending it on a rejected password locks somebody out for typing badly.

### 2026-08-29: counted two ways, because either alone is walked around

By address, so one source cannot walk a list. By source, so one address cannot
be spread across a botnet. Exceeding either is enough.

Checked before the password is verified rather than after: bcrypt is
deliberately slow, so an unthrottled sign-in is a way to spend this box's CPU as
well as a way to guess. Cleared on success, so mistyping three times and then
getting it right does not leave somebody nearly locked out.

Sign-in is the looser of the two at ten per address per quarter hour. Reset is
three per hour, because each one emails somebody who may not have asked, so the
limit is about the recipient rather than about the account.

### 2026-08-29: three things were broken under this, and none of them knew

None of these was found by reading. Each was found by being the first thing to
actually use the path.

**The reference transport had never worked.** `example-relay` declared
`mail.transport.v1` at `/internal/mail` and was a stock nginx image, which
cannot serve it. nginx answered 404, a 4xx tells the Mailer the message will
never be right, and so every message in the system died on its first attempt,
with the queue faithfully recording a permanent rejection nobody read. A
reference implementation that does not implement the thing is worse than none,
because the core believes it. It is now a real module: it accepts the message,
records it in the database it already declared, and sends nothing onward, which
makes it a development mail catcher rather than a transport pretending to be one.

**The core-to-module door ignored the module's port.** It proxied to
`http://<module>` with no port, so it always tried 80. Nothing noticed because
the only module ever reached that way was the nginx image above, and every
module that declares a port declares 8080. The first module to serve its own
traffic answered every core call with 502. It now uses the same upstream map the
app's door uses.

**A database named anything but `primary` is a database the SDK cannot find.**
The relay declared `deliveries`, the SDK asked for `primary`, and the service
correctly answered that nothing was provisioned. The manifest is where the name
is chosen and the SDK is where it is assumed, and nothing checks they agree.

## Outcome

Checked against the running stack by `bin/smoke-account-recovery`, which crosses
Auth, the Mailer, the transport module, and the Router door core services use.
The reset link is read out of the transport's own record rather than a log.

| | |
|---|---|
| an unknown address | the same answer as a known one |
| the message | queued, delivered, and kept by the transport |
| the link | valid once, then reports it was used |
| after a reset | old devices out, old password refused, new one works |
| an eleventh sign-in guess | refused |
| a fourth reset request in an hour | refused |

Twenty-four model tests: nine on reset links, nine on the throttle, six on the
sender constraint. The throttle tests are mostly about the ways around it, since
a limit that can be walked around only inconveniences the people it was not
aimed at.

## What this does not do

- **Core accounts still cannot reset a password.** Only app accounts can. The
  machinery is now there for both and the Backoffice has an operator remedy;
  wiring the same flow to `users` is a small, separate piece.
- **No email verification.** With sign-up open, an address is still taken on the
  word of whoever typed it.
- **The throttle is per box.** It counts rows in Auth's database, which is the
  right place for one instance and not a shared limiter for several. The nightly
  housekeeping sweeps what is older than a day, because a counter with a fifteen
  minute window has no use for yesterday.
