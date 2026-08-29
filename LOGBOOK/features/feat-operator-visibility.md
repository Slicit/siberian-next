---
status: shipped
branch: feat-operator-visibility
---

# The operator can see the system

## Intent

Two services do their work asynchronously, which means their failures are
invisible until somebody complains. Both had admin endpoints and neither had a
page, so finding out why mail was not arriving meant curl and a token, at the
moment somebody would least want to reach for either.

Mail now carries password resets, so that stopped being a question anybody can
leave for later.

And nothing alerts. A failing nightly sweep sat on the dashboard, which is a
page an operator visits once they already suspect something.

## Decisions

### 2026-08-29: the queue page shows addressees and outcomes, never contents

Deliberately no message body, and this is the interesting decision on the page.

A password reset link is a credential. A page showing one lets whoever can read
it take over the account it belongs to, and the people who can read this page
are exactly the people who should not need to.

What is there answers the question the page exists for: who it was for, what it
was about, which state it reached, how many attempts, and the last error. That
is enough to diagnose "mail is not arriving" without handing over somebody's
inbox.

The contents are readable in one place, and correctly: the transport module that
received them. `example-relay` keeps its own delivery log because a transport
does, and an operator who installed it chose to have that.

Two assertions in the smoke hold the line, because this is the kind of thing a
later "it would be handy to see the body" would quietly undo.

### 2026-08-29: retry, from a door the Backoffice can reach

Putting a dead message back is the one thing on the page that changes anything.
The module-facing retry needs the sending module's token, which the Backoffice
does not hold and should not, so the Mailer grew the same operation on its admin
door.

Gated on `core.modules.install` rather than read: retrying is sending.

### 2026-08-29: a failing sweep says so on every page

The banner is in the layout, not the dashboard, and renders only when there is
something wrong. A working system is silent.

It says two different things, because two different things are wrong: checks
failing, named; or a sweep that has not run for over a day, which is the failure
this whole area exists to catch. A green result from last week is not evidence
that anything works today.

### 2026-08-29: the navigation test caught a permission that had already drifted

Both pages started in one controller. The menu entry for the audit trail asked
for `core.audit.read` while the page it led to also inherited
`core.modules.read` from the controller it was sharing, so somebody holding one
and not the other would see the link and be refused.

That is exactly the drift `test/navigation_test.rb` was written for, and it
found it within a minute of the entry being added. The audit trail is now its
own controller asking for one permission, which is also the more honest reading:
it is not a modules page.

## Outcome

| | |
|---|---|
| the mail queue | a page, counted by state, filterable |
| a reset link on that page | not readable, asserted twice |
| a dead message | retriable by an operator who may install |
| the database audit trail | a page, with a refusals filter |
| a failing nightly check | named in a banner on every page |
| a sweep that stopped running | said plainly, on every page |
| a healthy system | silent |

Checked by `bin/smoke-visibility`, which makes the sweep fail on purpose,
asserts the banner appears, and puts it back.

## What this does not do

- **Nothing leaves the box.** The banner is an alert an operator sees when they
  look at the Backoffice. A domain filling its disk overnight still tells
  nobody who is not looking, and mail or a webhook is the obvious next step.
- **No time range on either page.** The queue shows the most recent hundred and
  the trail the most recent two hundred. Both endpoints take a limit and neither
  page offers one.
- **The audit trail cannot be filtered by module from the page**, though the
  client and the endpoint both support it.
