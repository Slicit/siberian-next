---
status: shipped
branch: feat-base-tests
---

# The Base App has tests

## Intent

It had none. Every check on the product side was a smoke needing eleven
containers up, so nothing about it could be checked while it was being written,
and the invariant the Mobile service's pinning rests on had never been asserted
anywhere.

## Decisions

### 2026-08-30: the invariant worth having a test for

The Mobile service pins the Base App to one domain and cannot verify the claim,
because the call arrives directly rather than through the Router. The half that
can be checked is on this side: the Base App passes the domain the Router put on
the request and never one it was handed.

Two tests, and they have teeth. Making `current_domain` prefer `params[:domain]`
fails exactly those two and nothing else, which is the check that was run before
trusting the suite.

### 2026-08-30: stand-ins built from the real structs

The Base App owns no data. Every page is another service's answer over HTTP, so
there is no way to test any of it without standing in for Auth, the Orchestrator
and Mobile.

The person and the capability are built from the real `Identity` and
`Capability` rather than hand-rolled shapes, because a double that invents its
own drifts from the thing it stands for, and the first symptom is a test passing
against a page that would fail. The Mobile stand-in records what it was asked,
since several of these tests are about the question rather than the answer.

### 2026-08-30: swapping a constructor rather than reshaping the app

Minitest 6 no longer ships `Object#stub`. The alternatives were a gem in every
service's Gemfile, or giving the app class-level slots for its clients that it
only needs because of its tests.

Ten lines in test support instead, swapping one constructor for the length of a
block and putting it back in an `ensure`. It is confined to the file that
explains it.

### 2026-08-30: what the tests are about

Not whether it answers 200. The page answered 200 for its whole life while
showing nothing, so these read what it says: that a refusal is not reported as
an absence, that the frame points at the module's own origin rather than a path
on this one, that a build the Mobile service refuses says why.

One of them records something true and surprising: `/m/notes.all` is not a door,
because Rails reads the dot as a format. Every link in the shell uses the slug,
and now there is a test saying why.

## Outcome

Forty six tests over the shell, the module frame and the phone app, running in
under a second against no containers at all.
