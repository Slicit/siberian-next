---
status: shipped
branch: feat-module-upgrade
---

# Upgrading a module is one action

## Intent

Moving a module to a new version meant removing it and installing it again, by
hand, four times in one afternoon while getting the theme work onto the box.

That is worse than it sounds. It revokes the module's credentials, detaches its
network, drops its containers, and gives it a new uuid. Every one of those is
fine until a step fails, and then there is no module. It also offers an operator
no way back when the new version turns out to be broken: the old one is already
gone.

## Decisions

### 2026-08-29: the module keeps its identity, so it keeps its data

The uuid names the network, the containers, and every provisioned database and
bucket. An upgrade keeps all of it and replaces only what the manifest changed,
which is the whole reason this is not a remove and an install wearing a nicer
label.

### 2026-08-29: a failed upgrade puts the working version back

The thing uninstall-and-install could never do. A snapshot of what was running
is taken first, and if the new containers do not come up, or come up and fail
the probe, they are removed and the previous ones recreated from the manifest
recorded at install.

Rollback is best effort on each step and says what it could not do, because
something the engine has already lost must not stop the rest of the old version
coming back.

### 2026-08-29: the same version with the same images says so

Rebuilding an image under an unchanged tag changes nothing that is running. An
operator told "upgraded" would go looking for their fix in the wrong place, and
that exact confusion cost an afternoon before this existed.

The comparison is version **and** images, not version alone: a manifest can move
its version without moving an image, and a tag can move without the version.
Only one of those is worth restarting containers over, and it is not the one you
would guess from the version number.

### 2026-08-29: the button appears only when there is something to install

The module page reads what the catalogue holds and offers an upgrade only when
it differs. A button that is always there is a question; one that appears when
there is an answer is information.

### 2026-08-29: a gateway error is not evidence that an endpoint exists

Found by upgrading, and it was a real hole in the install probe shipped an hour
earlier.

nginx caches a container's address for ten seconds. A container that has just
been replaced therefore answers 502 for a moment, and the probe treated anything
that was not a 404 as "the endpoint is there". So a version declaring a path it
did not serve upgraded cleanly, and the probe that exists to catch exactly that
waved it through.

`502`, `503` and `504` now join `404` and no-answer: retried while the Router
catches up, and refused if that is still the answer. Three tests hold it,
because the failure is invisible from anywhere except an upgrade.

## Outcome

| | |
|---|---|
| a new version | containers replaced, uuid and network kept |
| its databases and buckets | untouched, and its rows still there |
| the same version, same images | succeeds and says nothing changed |
| the same version, a moved tag | treated as a real change |
| a version that does not serve what it declares | refused |
| after that refusal | the working version running, one container not two |
| a manifest for another module | refused outright |

Eleven tests on the upgrader, three more on the probe, and a smoke that breaks
an upgrade on purpose and asserts what is left running.

## What this does not do

- **No downtime window.** The old containers are removed before the new ones are
  created, because they hold the container names, so the module is unreachable
  for a few seconds. Blue-green would need a second set of names.
- **No migration hook.** A version whose schema changed has to handle that
  itself, on its own first request, the way `migrate` already works.
- **No downgrade.** Installing an older manifest works and is called an upgrade
  by every message on the way through.
- **The catalogue is the only source.** An operator cannot upgrade to a manifest
  that is not on disk.
