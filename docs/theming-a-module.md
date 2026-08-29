# Theming a module

A module has two faces. The native one is drawn by the app and inherits its
palette for free. The web one is HTML the module renders itself, and inside a
WebView it is the one part of the app that would ignore the theme, which is
exactly where it shows: a dark app with a white page in the middle of it.

This is the whole contract. It is a query string and a cookie, which is why
adopting it is a few lines in any language rather than an SDK you have to have.

## What arrives

The app opens a module's page with the palette on the URL:

```
https://notes.apps.example.test/?theme=midnight&theme_scheme=dark
  &theme_background=%230f1117&theme_surface=%23181b23&theme_text=%23e8ecf1
  &theme_muted=%239aa4b1&theme_line=%232a313a&theme_accent=%238b7bf7
  &theme_onAccent=%230f1117&theme_danger=%23ef6b62&theme_dangerSurface=%232c1a1a
```

| Parameter | What it is |
|---|---|
| `theme` | the name, for a page that wants to say which one |
| `theme_scheme` | `light` or `dark` |
| `theme_background` | the page behind everything |
| `theme_surface` | a card or a row on it |
| `theme_text` | ordinary text |
| `theme_muted` | secondary text |
| `theme_line` | borders and rules |
| `theme_accent` | links, and the fill of a primary button |
| `theme_onAccent` | text drawn on that fill |
| `theme_danger` | destructive text and borders |
| `theme_dangerSurface` | the fill behind a destructive message |

Colours travel as values rather than as a theme name, for two reasons: a module
never has to carry a copy of the catalogue, and a palette tuned in the core
reaches an already-installed module without changing it.

## The four rules

**1. Emit nothing when nothing was asked.** A module opened directly in a
browser has no `theme` parameter and must keep its own styling, including its
own dark mode. Overriding unconditionally makes every module render light for
everybody, which is a regression dressed as a feature.

**2. Filter every value.** These land inside a `<style>` block, so a value that
can close a declaration can open a rule. Use an allowlist of shapes, not an
attempt to strip dangerous characters:

```
hex        #abc  #aabbcc  #aabbccdd
functional rgb(...)  rgba(...)  hsl(...)  hsla(...)
keyword    3 to 20 letters
```

Anything else falls back to your own default. `theme_accent=red;}body{display:none;}`
must render your default and no `display:none`.

**3. Set `color-scheme` from `theme_scheme`.** Without it, native form controls
stay white boxes on a dark page.

**4. Carry it past the first page.** The app puts the palette on one URL. Every
link, form and redirect after that is yours, and threading ten colours through
each of them is not a contract anybody keeps. Leave the palette in a session
cookie, scoped to the module's own path, set only when one arrived and read only
when one was set.

That last rule is the one that gets missed. Without it the first screen is
themed and everything reached from it is not, and going back changes the colours
again, which reads as the theme being broken rather than as the link having
dropped it.

## Which path you are on

The Router has two doors and the cookie path differs:

- `<origin>.apps.<domain>/` is where the app frames a WebView module. The module
  is at the root, so the cookie path is `/`.
- `/m/<name>/` on the served domain is the other door. The Router sets
  `X-Siberian-Module` there and not on the first, so that header is how a module
  tells which one it is on: present means `/m/<name>`, absent means `/`.

## Python

The SDK does all four rules:

```python
from siberian.theme import bridge as theme_bridge

style = MY_STYLESHEET + theme_bridge(siberian.theme)
```

```python
@app.after_request
def remember_theme(response):
    return siberian.theme.remember(response)
```

`bridge` defines `--theme-*` variables and points your own names at them. If
your stylesheet does not use the reference names (`--bg`, `--fg`, `--muted`,
`--line`, `--accent`, `--danger`, `--surface`), pass a mapping:

```python
theme_bridge(siberian.theme, {"--paper": "background", "--ink": "text"})
```

## Any other language

`modules/example-relay` and `modules/example-notes` are both worth reading:
example-notes is PHP with no SDK at all, and implements every rule above in
about eighty lines. That is deliberate, and it is the demonstration that this
contract needs no SDK in any language.

The shape, whatever you write it in:

```
if no `theme` parameter and no remembered cookie:
    emit nothing

for each of the ten colour fields:
    value = parameter, or cookie, or your own default
    unless value matches the colour allowlist:
        value = your own default

emit:  :root { color-scheme: <scheme>; --theme-<field>: <value>; ... }
       :root { --your-name: var(--theme-<field>); ... }

if a `theme` parameter arrived:
    set the cookie, scoped to the path above, for this browser session
```

## What the app decides

Which palette arrives is not the module's business, and the answer has three
inputs: the query string on the web preview, the phone's own light or dark
setting when the operator allows it, and the theme the operator chose. A module
that renders whatever it is handed is correct on all three.
