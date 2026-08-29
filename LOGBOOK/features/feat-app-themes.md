---
status: shipped
branch: feat-app-themes
---

# Themes, and a screen you can actually use

## Intent

Two things, and the first one is the important one.

**The tasks screen could show a task as done and not mark one.** Reported from
the preview. A screen that reads but cannot act is not a smaller version of the
feature, it is a picture of one, and the phone is where most people will use
this. Parity with the browser is the requirement rather than the ambition.

**Themes.** Three palettes, switchable and previewable without a rebuild, and
applying to a module's web face when the app frames it. A dark app with a white
page in the middle of it is where the seam shows most, so an embedded page that
ignores the theme is the part worth getting right rather than the part to leave
until later.

## Decisions

### 2026-08-29: parity means the actions, not only the rows

The native screen now ticks, archives, restores and deletes, and switches
between open and archived. Every action the browser offers on a list, on the
list.

Attaching a file is not there, and is absent rather than half present: it needs
a document picker, which is a capability the app would have to declare and an
operator approve. A greyed-out button that explains why would be a worse answer
than an honest gap.

The module now answers in the shape it was asked in on every action, not just
the ones added today: a form gets a redirect, JSON gets the row. `wants_json`
is one predicate rather than a branch repeated four times.

The tick is optimistic, because a checkbox that waits for a round trip feels
broken on a phone, and `load` puts the real answer back either way including
after a failure, so a row never keeps showing something that did not happen.

### 2026-08-29: a theme is data the app carries, not a build it bakes

The obvious design is to build an app with its colours compiled in. Then trying
a theme costs a ten minute Android build, which means nobody tries one.

So the app carries every palette and picks by key at render time, and the
preview passes `?theme=`. Switching is a reload of an iframe. What the built app
uses by default is still the saved setting, and the query string only overrides
on the web: on a phone there is no address bar to reach it from, so honouring it
there would be a setting with no way to change it.

### 2026-08-29: the colours travel to a module, the name does not

A module's web face inside a WebView gets the palette as query parameters and
turns it into CSS variables. Values rather than a theme name, for two reasons: a
module never has to carry a copy of the catalogue, and a palette tuned here
reaches an already-installed module without changing it.

The module keeps its own variable names. `siberian.theme` and
`siberian.theme.bridge` map one onto the other, so adopting the app's palette is
one line in a template rather than a rename through a stylesheet.

**Only when an app asks.** A module opened directly in a browser gets no theme
parameters and keeps its own styling, including its own dark mode. Overriding
unconditionally would make every module render light for everybody, which is a
regression dressed as a feature. Verified both ways.

### 2026-08-29: theme values are filtered, because they end up in a stylesheet

A colour from a query string is written into a `<style>` block, so a value that
can close a declaration can open a rule. The filter is an allowlist of shapes,
hex, rgb, hsl or a bare keyword, rather than an attempt to strip dangerous
characters from arbitrary text.

Checked against the running module rather than reasoned about:
`theme_accent=red;}body{display:none;}` renders the fallback and no
`display:none`, and `url(http://evil.test/x)` renders the fallback and no
`evil.test`.

### 2026-08-29: two ways a build reported success and delivered the old app

Neither of these was a theme bug, and both were only visible because the themes
gave the preview something new to show. They are worth writing down because the
shape is the same: everything upstream said it worked.

**The builder was running code it had already loaded.** `core/mobile-builder`
is bind mounted, so an edit shows up inside the container immediately and
`grep` inside it confirms the new line is there. Node does not reread a module
after loading it, and that process had been up for days. Builds kept succeeding
and kept emitting the previous `siberian.config.js`, so the app had no palettes
in it while the plan that produced it had all three.

The worker now hashes its own source between builds, never during one, and
exits when it differs. Compose restarts it. Restarting by hand after an edit
would also have worked and is exactly the step that gets forgotten.

**The preview could not load its own bundle.** Expo exports asset references
root-absolute, `/_expo/static/js/...`, which is right for a site at the root of
a host. The preview is served under `/mobile/:id/preview/`, so the browser asked
the Backoffice root for the bundle and got a 404 and a blank frame. Rewritten in
the export rather than in the page that frames it, so the directory works
wherever it is put down.

### 2026-08-29: the CPU cap made Android builds roughly three times slower

Not a decision so much as a measured consequence, recorded because it is the
kind of trade that is easy to forget having made.

The builder is capped at one core of two so a build cannot starve Postgres. An
Android build that took about ten minutes now takes over thirty five, at 99
percent of its single core and 2.5 GB of its 3 GB ceiling.

The cap is doing exactly what it was set to do. Whether one core is the right
number is a different question from whether a cap was right, and it wants a
measurement rather than a guess: raising it to 1.5 would leave half a core for
everything else, which may well be enough, and that is worth testing on a box
with more disk to spare.

## Outcome

Three palettes in `lib/mobile_themes.rb`: Daylight, Midnight and Meadow. One
list, read by the builder, the Backoffice picker and a module inside a WebView.

Verified against the running stack:

| | |
|---|---|
| module with no theme asked | keeps its own styling, no override emitted |
| module framed in Midnight | `color-scheme:dark`, accent mapped through |
| a value trying to close the declaration | falls back, no injected rule |
| a `url()` value | falls back, no request |

Twelve tests on the catalogue, including contrast floors: text against
background, accent against surface, and a button label against its button. A
palette where two colours that must differ do not is a theme somebody cannot
read, and that is worth failing a build over rather than noticing later.
