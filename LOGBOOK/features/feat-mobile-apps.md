---
status: active
branch: feat-mobile-apps
---

# One React Native app per domain, built on demand

## Intent

A domain serves a product through a browser. It should also be able to serve one
through a phone, without a module author learning a build system and without an
operator learning Xcode.

One app per domain, because a domain is the tenant boundary everywhere else. The
app is assembled from what the domain already has: its installed modules, their
native screens where they ship them, their web UI where they do not, and the
native capabilities an operator has switched on.

Builds run in a shared Node container behind a queue. Containers are installed
once and shared across every domain, so two domains asking for a build at the
same moment are two rows in a queue, not two containers.

Out of scope for this feature:

- iOS binaries. Apple's toolchain is macOS only, so a Linux container produces
  the configured iOS project and stops there. Signing and `.ipa` need a macOS
  runner or EAS, later.
- Over the air updates. A build produces an artifact; pushing one to a phone
  that already has the app is a different mechanism.
- Store submission.
- Scaling the builder. One worker, one queue. Replicas come later, and the
  claim query is already written for more than one.

## Design

### Where it lives

A new core service, `mobile`, Rails and API only, next to Mailer and Storage. It
owns the app record for each domain, which capabilities are enabled, and the
build queue. A second container, `mobile-builder`, is the worker: it claims a
build, assembles an Expo project, compiles Android, archives the iOS project,
and puts both in Storage.

Two containers rather than one for the same reason the Mailer has a worker: a
build takes minutes and a request takes milliseconds, and a service that does
both is a service whose queue stops when a request is slow.

The builder never talks to the engine. Only the Orchestrator holds the socket.

### Native capabilities

A fixed catalogue in `lib/mobile_capabilities.rb`, the shape `lib/permissions.rb`
already uses: an id, the package that implements it, what it is for, and whether
it needs configuration of its own. Ten to begin with, the industry standard set.

A module may declare that it requires one. That is a request, not a switch: the
operator sees it on the install review screen next to the database and storage
grants, and an operator can also enable a capability with no module asking. A
capability a module requires and an operator has not enabled leaves that
module's native screen switched off, which is what an unmatched capability
already does everywhere else in this system.

This is the rule that keeps coming up: an operator setting caps a manifest,
never the reverse.

### What a module ships

Optional. A module that ships nothing native still appears in the app, as a
WebView on the module's existing web UI, which is the same UI the Base App
frames. A module that ships native code declares it in its manifest and gets a
real screen.

The fallback is not a lesser path to be migrated away from. A module whose UI is
a form does not become better by being compiled.

### The `/m/<module>/` boundary

In a browser, module isolation is the origin: a module frame is served from
`<module>.apps.<domain>` and the browser enforces the rest. An app has no
origins. Every module's native code runs in one JavaScript context, in one
process, so nothing on the device can stop module A's code from calling module
B's endpoint.

So the boundary moves to the API. Module endpoints are addressed at
`/m/<module>/<path>` on the domain, the Router sets the module identity from the
path segment rather than trusting anything the client sends, and the call is
authorised as the user, against `module.<name>.use`, which the permission
catalogue already carries. A module's own data stays behind its own database
credential, which no other module holds.

Stated plainly, because it is a real narrowing: bundling third party code into
one binary means the app cannot enforce module to module isolation on the
device. It can only be enforced where it was always enforced, at the door.

## Plan

1. The `mobile` service: app per domain, capability configuration, build queue.
2. The capability catalogue, and the manifest surface for requiring one.
3. The Backoffice: an app per domain, the capabilities behind it, build history.
4. The `mobile-builder` container: assemble, prebuild, compile Android, archive iOS.
5. `/m/<module>/` through the Router, with the module identity set by the Router.
6. A smoke that queues a build for a domain and watches it come out.

## Decisions

## Outcome
