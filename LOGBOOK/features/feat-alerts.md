---
status: shipped
branch: feat-alerts
---

# Alerts that count

## Intent

Nothing in this system told anybody anything. Every signal ended on a page an
operator had to open: the nightly result, the storage figures, the mail queue.
The banner shipped alongside those only helps somebody already looking.

The evidence for why that matters is a single day's findings. Mail was dead for
weeks. The artifact sweep had never run. Three suites were red. Four messages
sat undelivered for ten days, one of them a password reset. Every one of those
was found by somebody going and counting, and none of them by being told.

The requirement was not "send alerts". It was **meaningful alerts, not noise**,
and that is a harder constraint than it sounds, because the obvious
implementation of every condition below sends something every fifteen minutes
forever.

## Decisions

### 2026-08-29: fire once, clear once, say nothing in between

The single rule that decides whether anybody keeps reading these. `AlertCondition`
exists for it: a scan hands it the same true statement every quarter of an hour
and it turns four hundred of those into one email when it starts and one when it
stops.

Two consequences worth stating:

**A condition has to hold across two scans before a word is sent.** A service
restarting during a deploy is wrong for one scan and right for the next, and an
alert for each of those is how somebody learns to filter the folder.

**Something that never fired is never announced as resolved.** Nobody was told
it broke, so nobody needs telling it is better.

### 2026-08-29: what earned a place, and what did not

Every condition had to answer three questions: can somebody act on it, will it
fix itself, and is it actually bad.

Left off deliberately, each considered: build failures, which happen several
times a day for ordinary reasons; a single dead message, which is one wrong
address; container restarts, which is the engine doing its job; and anything
that resolved before the next scan.

Kept: a red sweep, a sweep that has stopped running, low disk, a mail worker
that is not draining, a transport refusing everything, a domain near its storage
ceiling, and a module unhealthy for a quarter of an hour.

The second of those is the one that catches the checker. A sweep that has
stopped running looks exactly like a sweep that is passing, from every page that
reads its result.

### 2026-08-29: the first alert it ever sent was noise, and that was useful

Within a minute of being switched on it fired: twenty nine dead messages against
seventy one sent, therefore a broken transport.

Twenty five of those deaths were from that same afternoon, from a transport that
had been fixed hours earlier. The condition compared lifetime dead against
lifetime sent, and a ratio over all time never recovers: that alert would have
stayed lit forever, which is precisely the outcome the requirement was about.

It now asks whether mail is failing **now**: deaths in the last hour with no
successes in the last hour. One message getting through clears it. The Mailer
reports the recent window, because the caller cannot work it out from summaries
that carry no timestamps.

### 2026-08-29: an occurrence is counted, not timestamped

The email is deduplicated on an idempotency key, and the first version hashed
the message body. That meant the same sentence could never be sent twice ever: a
disk filling to the same number next month would be deduplicated into an email
somebody read and acted on weeks earlier.

Keyed on the occurrence instead. A timestamp was tried and collided, because two
firings inside one second share a second, so it is a counter. Both sides needed
it: the first fix left the recovery key as one string forever, so only the first
recovery in the life of the system was ever sent.

Every one of those was found by the smoke running the same scenario twice, which
is the argument for a smoke that is safe to run repeatedly.

### 2026-08-29: every quarter of an hour, which is safe because of the refusals

The frequency is chosen against the requirement rather than in spite of it.
Because a condition must hold twice before anything is sent and is never sent
again while it stays true, running often makes the first alert arrive sooner
without making any alert arrive twice.

From the host rather than a container, for one reason: `df` inside a container
reports the container's filesystem, and a box that has filled up is exactly the
thing worth knowing. The host takes the number and passes it in; nil means
nobody could say, and nothing is claimed.

## Outcome

Checked by `bin/smoke-alerts` against the running stack, three times in a row,
which is itself the point.

| | |
|---|---|
| something wrong once | nothing said, nobody emailed |
| still wrong on the second look | one email, to whoever can act |
| still wrong after that | nothing, however often it is asked |
| the page meanwhile | shows it, with today's number |
| better again | said once |
| after that | silence |
| a healthy system | no rows, no email, nothing |

Recipients are asked for rather than configured: whoever holds a role granting
anything in `core.`, derived from the catalogue and not from the role's name,
because a list of addresses in a settings file goes stale the first time
somebody leaves.

Twenty two tests, most of them asserting silence.

## What this does not do

- **One channel.** Email, through the queue the system already has, which means
  an alert about the mail transport being down cannot reach anybody. That is a
  real hole and the reason a second channel eventually matters.
- **No acknowledgement.** A firing condition stays on the dashboard until it
  actually recovers; there is no way to say "known, working on it".
- **No severity.** Everything here is worth an email or is not here at all,
  which is a reasonable place to start and will not survive a longer list.
- **Nothing about a module's own errors.** A module returning 500 to every
  request is invisible to this: the core knows the container is running, and
  that is all it knows.
