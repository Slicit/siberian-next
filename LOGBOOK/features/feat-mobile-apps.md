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

1. ~~The `mobile` service: app per domain, capability configuration, build queue.~~
2. ~~The capability catalogue, and the manifest surface for requiring one.~~
3. ~~The Backoffice: an app per domain, the capabilities behind it, build history.~~
4. ~~The `mobile-builder` container: assemble, prebuild, compile Android, archive iOS.~~
5. ~~`/m/<module>/` through the Router, with the module identity set by the Router.~~
6. ~~A smoke that queues a build for a domain and watches it come out.~~

## Decisions

### 2026-08-19

- **Decision:** a new core service, `mobile`, plus a `mobile-builder` worker, rather than the Orchestrator running builds.
- **Why:** a build takes minutes and a request takes milliseconds. The Mailer already answers this question the same way, and the Orchestrator is the one container holding the engine socket, which is the last thing that should also be running a third party's JavaScript through npm.
- **Impact:** the builder holds no socket, no admin token, and no Storage credential. It claims one build, receives the plan for it, and can ask the service nothing else.

- **Decision:** the native capabilities are a fixed catalogue in `lib/`, not a field a manifest fills in.
- **Why:** each one is a package that has to be in the build, a config plugin that has to be applied, and in several cases a sentence Apple shows somebody before asking permission. None of that can arrive from a third party at install time.
- **Impact:** adding a capability is a change to `lib/mobile_capabilities.rb` and nothing else. A manifest naming one that does not exist fails validation with the list.

- **Decision:** a module requires a capability; an operator enables it. A requirement that is not met leaves the module as the WebView it would have had anyway.
- **Why:** the storage quota rule again. A manifest is written by a third party, and every capability here is something the app can then do to somebody. If asking were enough to get it, the configuration page would be a suggestion.
- **Impact:** the install review screen lists native requirements next to database and storage grants. An unmet requirement is not an error anywhere: it is a feature that stays switched off, and the Backoffice says which capability would switch it on.

- **Decision:** modules ship React Native code, and the fallback is a WebView on the module's existing UI.
- **Why:** asked for. A module that wants a native feel should be able to have one, and a module whose UI is a form does not improve by being compiled.
- **Impact:** third-party JavaScript is inside the app binary. That is a real narrowing and it is written down rather than discovered: in a browser, module isolation is the origin and the browser enforces it, but an app has no origins and every module's code runs in one JavaScript context. Nothing on the device can stop module A calling module B's endpoint.

- **Decision:** so the boundary moves to the door. Module endpoints are addressed at `/m/<module>/<path>`, and the Router sets the module identity from the path segment.
- **Why:** it is the only place left that can enforce anything. A header the caller writes is not an identity, and the caller is code somebody else wrote.
- **Impact:** the call is authorised as the user, against `module.<name>.use`, which the permission catalogue already carries, and a module's own data stays behind a database credential no other module holds. Two segments, because the Base App already answers `/m/<capability-id>` for a framed page and has no second segment; a regex location wins over a prefix one, so the two coexist without either knowing about the other.

- **Decision:** iOS produces the configured Xcode project, not an `.ipa`.
- **Why:** Apple's toolchain runs on macOS. This is not a design choice that can be revisited in a Dockerfile.
- **Impact:** the Android path is real, end to end, on the box. The iOS button says what it does before it does it, and what comes out is what a macOS runner or EAS needs.

- **Decision:** the artifact travels back through the Mobile service into Storage, rather than the builder uploading it.
- **Why:** the builder runs third-party code, so it holds no credential that could reach another domain's files. Putting the app where every other file lives also means the quotas an operator already set govern it.
- **Impact:** a domain that has filled its storage cannot store a new build of its app, and the refusal names the limit rather than failing somewhere in Gradle. The cost is that a 60 MB artifact transits Rails, which is fine at this scale and would not be at another.

- **Decision:** the build plan is resolved when a build is queued and kept on the row.
- **Why:** a build is a thing that happened. Explaining one after the configuration behind it has changed is otherwise guesswork.
- **Impact:** changing a capability does not change a queued build. Asking again is how you get the new configuration, which is also what an operator expects from a queue.

## Outcome
