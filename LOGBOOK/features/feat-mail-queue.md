---
status: active
branch: feat-mail-queue
---

# The Mailer: a queue, acknowledgement, and retry

## Intent

The Mailer has been a health endpoint since the skeleton. Sending mail is the
one core service where the failure is asynchronous and invisible: the call
succeeds, the message does not arrive, and nobody finds out until a person
complains. A queue makes that visible, retry makes it survivable, and
acknowledgement makes it somebody's job to look.

Everything is namespaced by module and by domain, like storage and databases,
because a module has no business seeing another module's mail.

Out of scope for this feature:

- Templates and layouts. A module composes its own body.
- Inbound mail, bounces, and complaint handling.
- Rate limiting per module, which will matter and does not yet.

## Plan

1. Queue: a message belongs to a (module, domain), with a state and a next attempt time.
2. Delivery through the `mail.transport.v1` interface, so an installed module can be the transport.
3. Retry with exponential backoff, a cap, and a terminal dead state.
4. Acknowledgement, so a module has to have seen an outcome before it stops being reported.
5. API: enqueue, list, fetch, cancel, retry, acknowledge, and counts.
6. A worker that runs as its own container.
7. Tests, and a smoke that fails a delivery on purpose and watches it retry.

## Decisions

### 2026-08-19

- **Decision:** a queue rather than sending inline.
- **Why:** the alternative makes every module handle transport failure itself, badly and differently. A module should hand over a message and stop thinking about it, which is only honest if something else keeps thinking about it.
- **Impact:** enqueuing is a database write and returns immediately. Nothing in a module's request path talks to a transport.

- **Decision:** acknowledgement is required before a terminal outcome stops being reported.
- **Why:** a module that crashes between "the send failed" and acting on it has lost the only copy of that fact. Reporting an outcome until somebody says they have seen it is the difference between a queue and a fire-and-forget log.
- **Impact:** `GET /v1/messages?unacknowledged=true` is the endpoint a module polls. Outcomes accumulate there until acknowledged, which is deliberate: a growing pile is a module that is not looking, and that should be visible rather than quiet.

- **Decision:** delivery goes through `mail.transport.v1`, resolved per attempt.
- **Why:** the interface already exists and the capability split promised exactly this. Resolving per attempt rather than per message means installing a transport module fixes a queue that is already backed up, without anybody re-queuing anything.
- **Impact:** the Mailer asks the Orchestrator which implementation wins, and falls back to its built-in transport. A queue that is failing because the transport is gone drains itself once one is installed.

- **Decision:** the queue is the database, claimed with `SKIP LOCKED`, rather than Redis and Sidekiq.
- **Why:** the source of truth has to be a table regardless. The API answers per module and per domain, acknowledgement is durable state, and the question the feature exists to answer is "what happened to this message". Putting scheduling in Redis as well means two stores that can disagree, and the two ways they disagree are a message sent twice and a message lost, which are precisely the two outcomes a mail queue must not have. Rails 8 ships a database-backed queue as its default for the same reason. Sidekiq is better at concurrency and avoids polling; neither is the constraint at this volume.
- **Impact:** one store, one truth, one place to look. `FOR UPDATE SKIP LOCKED` lets several workers claim without coordinating. If polling ever becomes the wrong shape, the executor can be replaced without touching the API, because the API reads the table rather than the scheduler.

- **Decision:** backoff is exponential with jitter, capped, and ends in `dead` rather than looping forever.
- **Why:** a message that will never send should stop consuming attempts and start being a visible problem. Jitter because a transport that just came back should not be hit by the whole backlog in the same second.
- **Impact:** attempts are recorded individually, so "why did this take four hours" has an answer rather than a guess.

## Links

- Branch: `feat-mail-queue`
- PR: TBD
- Related features: `feat-core-services`
