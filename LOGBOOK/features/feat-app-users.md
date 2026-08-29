---
status: shipped
branch: feat-app-users
---

# The person an app is for

## Intent

Every feature built so far has been used by an operator, because an operator is
the only kind of person the system could describe. A module identifies whoever
is in front of it, and that was always somebody with a Backoffice login. The
phone app is for customers, and there was no way to be one.

So: an identity for the people a domain's app is for. One account signed in on
any number of devices, belonging to one domain, and never able to reach the
Backoffice.

## Decisions

### 2026-08-29: correcting the premise before building on it

The feature was asked for on the reasoning that Auth is already per domain, so
the same email on two domains would be free. That was not true. `users.email`
carried a globally unique index, and the domain lived on the session rather
than on the identity: one account across the whole system, signed in somewhere.

The conclusion was right and the reason was not, which is worth writing down
because the difference is the work. Per-domain identity had to be built rather
than inherited.

### 2026-08-29: a second table, not a flag on the first

`AppUser` rather than `User.app?`, for three reasons that are each enough alone.

**The uniqueness rule differs.** A core account is one person everywhere, so its
address is unique everywhere. An app account belongs to one domain, and the same
address signing up on two domains is two unrelated people who share a mailbox.
Those two rules cannot live on one column.

**The blast radius differs.** A core account can be made an operator. An app
account must never be one. With a separate table the operator machinery has
nothing to attach to: no role assignments, no permission grants, no `operator`
column. The property is structural rather than checked, which is the only kind
worth relying on.

**The session differs.** A browser session is short and replaced by signing in
again. A phone is signed in for months across several devices, each of which has
to be nameable and endable on its own.

The cost is one branch in `/internal/session`, which now tries a core session
and then an app one. That is the whole integration: every module, the Base App
and the Backoffice ask the same question and get the same shape back, so nothing
downstream learned a second concept.

### 2026-08-29: permissions are fixed, not resolved

An app account holds `app.use` and `module.*.use`, the same set the seeded
`member` role carries, and holds it as a constant rather than through roles.

Roles exist so an operator can shape what staff may do. A customer is not staff,
and giving them the role machinery creates a path from customer to operator that
then has to be defended forever, in exchange for flexibility nobody asked for. A
module that wants finer control over its own users has its own tables and its
own opinion, which is a module's business.

The consequence is that there is no version stamp to report and nothing to
re-resolve: the stored answer and a fresh one are the same by construction.

### 2026-08-29: a device is a row, and signing in again replaces it

One account, many `app_sessions`, one per device, ninety days each.

Signing in from a device that is already signed in revokes that device's session
first, matched on an id the app supplies. Without it, reinstalling an app leaves
a row nobody can identify, and a device list full of ghosts is a device list
people learn to ignore, which is the same as not having one. A sign-in with no
device id is left alone by the next one, because with nothing to match on,
replacing would end a session belonging to some other device.

Ending one device leaves the others signed in. Deactivating the account ends all
of them, because an inactive account with a live session on a phone somewhere is
an active account.

### 2026-08-29: sign-up is closed until somebody opens it

A per-domain switch, defaulting to closed, with the operator page saying which
it is in words rather than showing a toggle.

A default of open would mean every domain accepts accounts from anyone who can
reach it, before its operator has been asked, and the first they would hear of
it is the account list. Turning it on is one click; finding out you should not
have is not.

### 2026-08-29: one sign-in produces two things

The app holds a bearer token. The WebView pages it frames carry a cookie. Both
are the same opaque string, and one sign-in issues both.

The alternative was a token-only scheme, which would mean every module learning
a second way to identify somebody. The core exists so a module does not have to
implement identity once, and asking every module author to implement it twice is
worse than not having shipped it.

### 2026-08-29: the app's door is under `/-/`

`/-/auth/...` on the served domain, routed to Auth by the Router. That prefix is
already reserved for core paths, so it cannot collide with a module base route
or with a page a CMS publishes at the root, and a regex location means it wins
over the catch-all the way `/-/public/` already does.


### 2026-08-30: a person can now manage their own account

Everything here was possible for an operator and impossible for the person the
account belongs to, which is the wrong way round for a product whose audience is
the app user. Changing a password meant asking for a reset link to an address
you were already signed in with. Changing a name meant asking somebody.

Two details worth keeping:

**The current password is required to change it, even while signed in.** A
session left open on a borrowed laptop is the case: whoever is holding it can
already read everything, and the one thing they must not be able to do is take
the account.

**Changing a password signs out the other devices and not this one.** Somebody
doing it because they think their password is known wants the others gone;
being signed out of the phone in their hand as well is a surprise. Signing out
everywhere is a separate action, and that one does include the device asking.

### 2026-08-30: deleting an account cannot free the address, because modules key by it

This was found while building deletion, and it changed its shape.

Every module keys its rows by the person's email. `demo-tasks` has `user_email
text NOT NULL`; `example-notes` inserts by it. So if deleting an account freed
the address, the next person to sign up with that address would open the app and
find the previous person's tasks, notes and notifications waiting for them.

That is a privacy hole that deletion itself would have opened, which is the
worst kind: the feature meant to protect somebody creating the exposure.

So the row survives and keeps its address, which keeps it claimed. What goes is
the ability to sign in, every session, the password, the name and the
verification. The response says so in words rather than implying it, including
that module data is not removed, because the core cannot reach into a module's
database and pretending otherwise would be worse than the gap.

**The durable fix is not this.** Modules should key by the stable id the
identity already carries rather than by an address that can change hands. That
is a change to every module and to the contract, and until it happens, an
address that has been used cannot be reused. It is the next thing worth doing to
this area, and it is cheaper now than after there is real data.
## Outcome

An account belongs to one domain, signs in on any number of devices, is seen by
every module, and is refused by the Backoffice.

Checked against the running stack by `bin/smoke-app-users`, which asserts:

| | |
|---|---|
| a stranger with sign-up closed | refused |
| an operator adding an account | listed on that domain |
| two devices, one account | one identity, two tokens, both listed |
| ending one device | that one out, the other still in |
| the same address on another domain | a different person |
| a module asked by an app account | answers, and shows only their rows |
| the Backoffice asked by one | 403 |
| the product asked by one | 200 |

Fifteen model tests cover the rules that no request path would notice losing:
case-insensitive uniqueness within a domain, freedom across domains, a device
summary carrying nothing secret, and deactivation reaching every device.

136 lib runs, 57 auth runs, 77 orchestrator runs, `bin/check` clean, and all
fifteen smoke checks passing.

## What this does not do

Stated because each is a thing somebody will reasonably expect.

- **No password reset.** There is no way for an app account to recover one, and
  the Mailer is right there. This is the first thing to add.
- **No email verification.** With sign-up open, an address is taken on the word
  of whoever typed it.
- **No rate limiting on sign-in.** The endpoint answers as fast as it is asked.
- **No OTP**, though core accounts have the columns for it.
- **One app per domain** is assumed. `app_users.domain` is the tenant, and a
  second app on one domain would need a column beside it rather than a rewrite.
