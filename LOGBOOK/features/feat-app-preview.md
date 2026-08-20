---
status: shipped
branch: feat-app-preview
---

# Looking at the app without building it

## Intent

Configuring a phone app meant choosing capabilities, uploading a splash, and
then waiting fifteen minutes for an APK to find out what any of it looked like.
The feedback loop was longer than the decisions it was supposed to inform.

Also: the shell was a list of links. A phone app has a bottom bar.

Out of scope for this feature:

- A dev server with hot reload. The preview is a build, queued like the others,
  because a long-running process per domain is a different thing to operate.
- Previewing on a real device. That is what the Android build is for.

## Plan

1. ~~A bottom tab bar, and a back to home button on every screen but Home.~~
2. ~~`web` as a third platform: React Native for Web, exported as a static site.~~
3. ~~The export travels back through the Mobile service and into Storage.~~
4. ~~The Backoffice frames it in a phone-shaped panel.~~

## Decisions

### 2026-08-20

- **Decision:** React Native for Web, not Expo Snack.
- **Why:** Snack is an editor with a preview attached, and it runs on somebody else's servers. The point here is to look at *this* app: the same shell, the same generated module registry, the same blocks a device build compiles. A preview of anything else agrees with the app only by accident, and shipping third-party module source off the box to get one is a poor trade for a system built around keeping that code contained.
- **Impact:** the preview is the same project the device build assembles, exported with `expo export --platform web`.

- **Decision:** the preview is a build on the existing queue rather than a dev server.
- **Why:** a dev server per domain is a process to supervise, restart, and reason about. A build is a row in a table the system already knows how to run, retry, and explain.
- **Impact:** no prebuild and no compile, so it finishes in about a minute rather than fifteen. It shows what a build made then, not what the configuration says now, and the panel says so.

- **Decision:** the interface that owns the address supplies it.
- **Why:** a static export writes absolute asset paths, so it has to know where it will be served from before it is built, and the Mobile service does not know what route the Backoffice will frame it at.
- **Impact:** the Backoffice passes `preview_base_url` when queueing, and it becomes `experiments.baseUrl`. Without it every asset is fetched from the root of whatever host framed the preview.

- **Decision:** on the web, a WebView is an iframe.
- **Why:** React Native for Web has no WebView. Left alone, every module without native code renders as an empty panel, which is exactly the modules whose fallback the preview exists to show.
- **Impact:** one `Platform.OS === "web"` branch in the shell.

## Outcome

Shipped 2026-08-20, after four failed exports that each named their own cause:
a missing `@expo/metro-runtime`, a host crash, a full disk, and `output:
"static"` pre-rendering through `expo-router` which this shell does not use.

Verified rather than assumed. `index.html` serves at 200 with its script tag
already prefixed `/mobile/2/preview/`, the bundle serves at 200 as
`text/javascript`, and it contains `createBottomTabNavigator`, `iframe`,
`PageNavigator`, `NotificationInbox` and `TaskList`: the tab bar, the web
fallback, and all three native modules.

The last obstacle was worth writing down. Rails refuses to serve a JavaScript
response to a request that is not XHR, which is a real protection against
leaking a signed-in person's data through a script tag on another site. It
decides the response is JavaScript from the path ending in `.js`, so proxying a
static bundle trips it, and the browser gets a 422 error page with a JavaScript
content type. Skipping it as a `before_action` did nothing at all, silently,
because it is an `after_action`.

An export now takes about a minute where it took ten. Most of that ten was npm
install running from nothing on every build, because the workspace is deleted
afterwards to stop the disk filling: the dependency set is now cached under a
key of what was asked for and hardlinked in.
