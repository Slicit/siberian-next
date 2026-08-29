---
status: shipped
branch: feat-honest-manifest
---

# A manifest that cannot lie

## Intent

Three bugs in one day shared a shape: something was declared and nothing checked
it. A module declared a capability endpoint it did not serve, declared a
database name the SDK could not ask for, and declared a port one Router door
honoured and the other ignored.

The manifest is written by a third party and believed by the core. This is about
where believing it stops.

## Decisions

### 2026-08-29: install asks the module whether the manifest was true

The last thing before an install is called a success: `GET` every declared
capability endpoint and every declared health path, through the same door the
core will use.

Deliberately weak, and the weakness is the design. It asks whether an address
exists, not whether it works:

- **404 is a refusal.** Nothing is there, and that is the one thing this can be
  sure of. It is exactly what example-relay answered for weeks.
- **405 passes.** The route exists and does not take GET, which is the correct
  answer for a transport that only accepts POST. Refusing those would mean the
  check could only be satisfied by a module that answers GET to everything.
- **401 and 403 pass.** An endpoint defending itself is an endpoint that exists,
  and demanding it open up to be installable would be asking modules to weaken
  themselves.

**It must never invoke the capability.** A probe that POSTed to a mail transport
to see whether it was there would send mail, and a probe with side effects is a
probe nobody dares run. That constraint is why GET-and-read-the-status is the
whole mechanism.

### 2026-08-29: 404 is retried, because two different things say it

"The module does not serve this" and "the Router has not reloaded its upstream
map yet" are the same status code from here, and the second was happening: the
first run refused the liar's health path at `/`, which stock nginx does serve.

So 404 is retried on the same bounded schedule as no answer at all. A wrong
manifest costs a few seconds at install time; an honest module refused because
nginx was a moment behind costs an operator their afternoon. Installs are rare.

The check that this did not go too far is in the smoke and in the suite: an
honest module must still install. A probe that refuses everything passes every
test about refusing and is worse than no probe, because the first response to it
is to switch it off.

### 2026-08-29: a module that exists to be refused

`modules/example-liar` declares `mail.transport.v1` at an endpoint its stock
nginx image cannot serve. Every other reference module demonstrates the contract
working; this one demonstrates it being enforced, which was untestable while
nothing enforced it.

It is not in any catalogue listing by accident. `bin/smoke-honest-manifest`
installs it on purpose.

### 2026-08-29: the probe is injected, like the driver and the router

The unit suite installs against a fake engine that serves no HTTP, so a probe
that really asks fails every install for a reason that is not about installing.
Eight tests went red the moment it was wired in, which is the correct outcome
and the reason the seam already existed for the other two dependencies.

### 2026-08-29: "already installed" was the one thing it was not

A failed install keeps its record on purpose, so an operator can see what failed.
Installing again then said "example-liar is already installed", which is
actively misleading: it failed, it is not installed, and the operator has
nowhere to go from that sentence. It now says what happened and what to do.

### 2026-08-29: the database name was not a manifest bug

The relay declared `deliveries` and its code asked for `primary`, and no
install-time check could have known which name the code would use. Two fixes,
neither of them validation:

- **The SDK can ask by name.** It could only ever ask for `primary`, so a
  manifest declaring anything else described a database the module could not
  reach. Pools are keyed by `(domain, name)`, so a module with two databases
  gets two pools rather than the first one it happened to open.
- **The refusal says what the module does have.** "no database provisioned for X
  on Y" is true and is also what a module with no databases at all is told. It
  now names the database asked for and lists the ones that exist, which is the
  difference between forty minutes and one.

## Outcome

| | |
|---|---|
| a module declaring an endpoint it does not serve | refused, and told which declaration |
| its container and network | rolled back, nothing left running |
| its record | kept and marked failed, so an operator can see why |
| installing it again | says what happened and what to do |
| an honest module | still installs |
| asking for a database by name | works, and names what exists when it does not |

87 orchestrator runs including eight on the probe alone, and twenty smokes
passing.

## What this does not do

- **It does not check that the endpoint works.** A module can serve 200 at a
  mail transport and discard every message. Only using it finds that, which is
  what `bin/smoke-mail` is for.
- **It does not run on reconcile.** A module that stops serving what it declared
  after install is not noticed until something uses it. The probe is cheap
  enough to run on a reconcile pass and that would be worth doing.
- **The interface registry is still not probed.** A module can claim
  `mail.transport.v1` at an endpoint that exists and answers nothing useful, and
  the priority ordering that decides which transport wins is unchecked.
