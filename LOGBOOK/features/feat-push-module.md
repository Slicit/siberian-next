---
status: shipped
branch: feat-push-module
---

# Push notifications, and an inbox that outlives the tray

## Intent

A notification dismissed from the tray is not a notification that never
happened. Somewhere it still has to exist, be readable, and be got rid of on
purpose rather than by swiping it away while doing something else.

This is also the first module that needs something from the phone the browser
cannot give it, so it is the first one to exercise the capability rule from the
other side: it requires push, and until an operator approves that it is a module
with an inbox and no way to interrupt anybody.

Out of scope for this feature:

- Sending to anybody but the person asking. An audience is a product decision.
- FCM and APNs credentials. Reaching a real handset needs them and this box has
  none; the module talks to Expo's push service, which is where they would go.
- Scheduling, grouping, or quiet hours.

## Plan

1. ~~`push_notifications` in the capability catalogue, and a test that the catalogue and the manifest schema agree.~~
2. ~~Device registration, after the operating system said yes and never before.~~
3. ~~An inbox with read, archive, and delete kept as three different things.~~
4. ~~A native screen, and registration as a hook rather than part of it.~~

## Decisions

### 2026-08-20

- **Decision:** the catalogue gained a `prompts` flag, separate from severity.
- **Why:** a test asserting that every high-severity capability explains itself failed on in-app purchases, and the test was wrong rather than the data. Severity is how much a capability asks for. Prompting is whether the operating system stops somebody with a dialog. Purchases is serious and prompts for nothing; the network state is mild and prompts for nothing; Apple rejects a build that prompts without a sentence.
- **Impact:** three facts instead of two, and the test now checks the one that matters for a build.

- **Decision:** read, archive, and delete are three separate things.
- **Why:** they answer different questions. Read is having seen it, archive is being done with it while it still happened, and delete is deciding it never needs to exist again. Collapsing archive into delete loses the record; collapsing read into archive loses the difference between glanced at and dealt with.
- **Impact:** only delete asks for confirmation, because only delete loses anything. Archiving marks it read on the way, because nobody archives something they have not seen.

- **Decision:** registration is a hook, not part of the screen.
- **Why:** it is the part with rules. Ask the operating system first, register only if the answer was yes, and never pretend the answer was yes. Mixed into a screen those rules eventually get reordered by somebody fixing something else.
- **Impact:** `usePushRegistration` returns a status the screen shows in a banner, so a device that never registered says so instead of looking like it worked.

- **Decision:** the static `expo-notifications` import is safe.
- **Why:** the module's native code is copied into a build only when the capability it requires has been approved. Unapproved, the module falls back to a WebView and none of that file is in the bundle.
- **Impact:** no conditional imports and no runtime capability checks in the component. The gate is the manifest, which is where it belongs.

## Outcome

Shipped 2026-08-20. Every state transition was driven through the API and
behaved: unread to read drops the unread count, archiving leaves the inbox and
appears under archived, unarchiving returns it, deleting answers 200 and then
404 on a second attempt.

The rule showed both faces. Before approval the module reported
`{kind: "webview", reason: "requires push_notifications"}` and its inbox worked
anyway; after approval it became native, and the compiled bundle inside the
built APK carries `NotificationInbox`, `usePushRegistration`,
`getExpoPushTokenAsync` and the `api/devices` call.

What is not verified is delivery to a handset. That needs FCM and APNs
credentials this box does not have, and the module says so precisely rather
than silently: the first send recorded "no device has registered for this
person" against the notification itself.
