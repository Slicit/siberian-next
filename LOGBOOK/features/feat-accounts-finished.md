---
status: shipped
branch: feat-accounts-finished
---

# Accounts, finished

## Intent

Three holes left open when app accounts shipped, each of them the kind that
makes a working feature unusable rather than broken.

A core account could not reset a password. An app account's address was taken on
the word of whoever typed it. And an operator could not set a password from the
Backoffice, though the API had always allowed it.

## Decisions

### 2026-08-29: one implementation, two tables

`ResetToken` is a concern over `user_password_resets` and `app_password_resets`.

Two tables rather than one polymorphic one. A reset row is inert (it grants
nothing but "set this account's password") so sharing would be safe enough, and
the reason not to is the reason `app_users` is its own table at all: every place
the two kinds of account meet is a place a bug can hand one the other's powers,
and there was no need to make another one.

The behaviour is shared instead, which is where duplication would actually have
hurt. The rules are subtle enough to drift in two copies: asking again kills the
earlier link, a rejected password does not spend it, and completing one ends
every session the account had. Two tests assert the separation directly: an app
token is meaningless to `UserPasswordReset` and the reverse.

### 2026-08-29: a browser flow, not the JSON one

App accounts get JSON because the caller is a phone. Core accounts get pages,
because the caller is looking at the sign-in form and the next thing they need
is a link on it.

Same throttle for both, and deliberately the same counter: the reset limit is
about the person receiving the email, not about which kind of account asked.

The reset page says it will sign them out everywhere else **before** they commit
to it. Somebody who does not want that should find out while they can still
stop.

### 2026-08-29: verification is recorded, never enforced

An app account starts unverified and gets a link. Following it verifies, once.

It gates nothing. Blocking sign-in on it would mean a broken mail transport
locks every new account out of a product that was otherwise working, which is a
worse failure than an unverified address, and mail on this box was silently
broken for weeks. So it is recorded, shown to an operator as a badge, and
reported in the identity, and a module that wants to care decides for itself.

An operator-created account gets the same link. An operator vouching for
somebody does not make the address theirs, and an account that could never be
verified would carry the badge forever through no fault of the person using it.

### 2026-08-29: the operator's password box is the last resort

It is on the page because a mail transport that is down would otherwise mean
nobody can get back in at all. It is not the normal path, and the copy says so:
the reset link exists precisely so that nobody has to be told their password by
another person.

## Outcome

Checked against the running stack by `bin/smoke-core-recovery`, which drives the
pages rather than the API: the form, the queued email, the link, the page it
opens, and the session it leaves behind.

| | |
|---|---|
| the sign-in form | links to the reset |
| the email | queued, delivered, carrying a link |
| the reset page | warns it signs them out elsewhere |
| after setting | signed in, link spent, old password refused |
| a new app account | unverified, and sent a link |
| following the link | verified, once |
| an operator setting a password | new one works, old one does not |

88 auth runs, 21 smokes passing.

## What this does not do

- **Verification gates nothing.** That is the decision above, not an oversight,
  but it does mean the flag is only worth what somebody chooses to do with it.
- **No "resend the verification email".** An operator can create the account
  again only by deleting it. A button is the obvious next thing.
- **Nothing expires an unverified account.** They stay unverified forever and
  nothing sweeps them.
- **The core reset does not cover the app's JSON door and the reverse.** Two
  flows for two kinds of caller, sharing rules and not routes.
