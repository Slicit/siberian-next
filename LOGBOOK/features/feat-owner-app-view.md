---
status: shipped
branch: feat-owner-app-view
---

# The app owner sees their own app

## Intent

`siberian.test/app` is where somebody builds their phone app. It could describe
it, name it, upload a splash and press Build, and then it showed them nothing:
"Nothing built yet" under a domain with eighty builds, no preview at all, and
build buttons that did not queue a build.

## Decisions

### 2026-08-30: it was a refusal shown as an absence

The Mobile service admits `base` on `Admin::AppsController` and on nothing else.
`Admin::BuildsController` answered `base is not permitted here`, and the Base App
turned that into `Array(nil)` and drew an empty state.

Measured rather than inferred, by asking as each caller:

```
base         > MobileClient.new.builds(domain: "siberian.test")
  {"error" => "base is not permitted here", "ok" => false}
orchestrator > the same call
  50 builds
```

The same shape as the mail transport that 404ed for weeks, the retention job
that never ran, and the messages stuck in `sending`. It is the shape worth
naming: nothing here was ever red.

### 2026-08-30: admitting a caller means deciding what it may see

Adding `base` to the allowlist is one line. What it may then ask for is the
actual decision, and it had to be made rather than inherited, because
`GET /admin/builds` with no domain means every domain and `GET /admin/apps`
lists them by name.

So a **pinned caller** must name a domain, never gets the view across all of
them, and cannot read or cancel a build belonging to somebody else. A build it
may not see returns exactly what a build that never existed returns: saying
"not yours" would confirm that it is somebody's.

What this does not do, and cannot from where it is written: stop a pinned caller
naming a domain that is not its own. The Base App reaches the Mobile service
directly, so the domain is claimed rather than stamped by the Router. The trust
that remains is therefore explicit and narrow: a compromised Base App can name
another domain, an uncompromised one cannot do so by accident, and the accident
is the failure that was actually available.

Closing the rest means routing core-to-core calls through the Router so it
asserts the domain the way it already does for modules. That is a wider change
than this page needed and is deliberately not made here.

### 2026-08-30: the queue counts stay across every domain

The list is scoped and the counts are not, which looks inconsistent and is not.
There is one builder; the page already says so in as many words; and "two builds
ahead of you" is only useful if it counts the ones actually ahead. A count
carries no detail about whose they are, and a queue position computed against
one domain's builds would be a number that means nothing.

### 2026-08-30: the preview refused to serve its own JavaScript

Rails will not send a JavaScript response to a request it cannot prove came from
this site, which is right for a page about the person asking and wrong for a
build artifact. The action serves bytes from an export, changes nothing, and
reads its domain from the Router, so forgery protection is skipped there and
only there.

The frame also has to name `index.html` rather than the bare route. The export
links its assets relatively so it can be served under any prefix, and a browser
resolves those against the directory it believes it is in: at `/app/preview` it
asks for `/app/_expo/...` and gets nothing.

Worth recording because neither failure is visible. A 422 on the bundle renders
a blank white phone, not an error.


### 2026-08-30: they could look at a theme and not choose one

The three palettes were switchable from the Backoffice and nowhere else, so the
app owner saw whichever one an operator had set. Trying one on is a query string
the built app already answers, which costs a reload of the frame rather than a
build; keeping one is the button next to it, because looking is not choosing.

Adding the picker exposed a constant that had been one short circuit from a 500
for several commits: the Base App never required `mobile_themes`, and the frame
only named the default when no theme was saved. It is in the shared contract
now, next to `mobile_capabilities`, rather than in a third service's
initializer. A list two of three services remembered to require is a mistake
waiting to be made a second time.


### 2026-08-30: the Backoffice had already solved this, differently

The Base App's preview was skipping forgery protection with
`skip_forgery_protection only: :preview`. The Backoffice, which proxies the same
export, was skipping `verify_same_origin_request` directly, and had been all
along. The first grep for it missed the line because it names neither
`skip_forgery` nor `verify_authenticity_token`, which is why the two behaved
differently for a while with no explanation.

The Backoffice's is the better one and both now use it.
`skip_forgery_protection` turns off the token check for the whole action, which
is harmless for a GET and wrong in principle: it would also switch off real
protection if the action ever answered a POST. `skip_after_action
:verify_same_origin_request` turns off exactly the check that is wrong here and
leaves token verification alone.

Worth recording because the divergence was invisible from either side. Each app
worked, and only comparing them showed that one of them was solving the problem
twice as broadly as it needed to.

### 2026-08-30: the test for it proved nothing until it was made to

Forgery protection is off in the test environment, so the example asserting that
the preview serves its own JavaScript passed against a controller with the skip
removed. It was written that way first, and caught nothing when that was tried.

It now switches the protection on for the length of the example. Removing the
skip fails it, which is the check that was run before trusting it.

## Outcome

The page lists the domain's builds, says where a waiting one is in line, says
plainly when the queue could not be reached rather than calling that an empty
queue, and shows the built app running in a phone-shaped frame with the theme
that is saved, which they can change to either of the others and keep.

`bin/smoke-owner-app` drives it as an app owner and reads what the page says
rather than what it answered, because it answered 200 the whole time it was
showing nothing. Eleven tests in `core/mobile/test/integration/pinned_caller_test.rb`
pin what a caller for one domain may ask for, including that a build belonging
to somebody else is byte for byte indistinguishable from one that never existed.
