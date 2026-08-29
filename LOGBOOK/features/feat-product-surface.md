---
status: shipped
branch: feat-product-surface
---

# What a person sees

## Intent

Three gaps left where the product meets the person using it, rather than the
operator configuring it.

The theme was one choice for everybody, so a phone set to dark showed a light
app. The theme contract was implemented twice and written down nowhere, so a
module in a third language had two examples and no specification. And attaching
a file worked in the browser and not on the phone, which was written down as a
deliberate gap and stayed one.

## Decisions

### 2026-08-29: a palette is not a light-or-dark decision

This is the idea the whole appearance change rests on, and it is what lets the
operator's choice and the phone's setting both be honoured rather than one
overriding the other.

An app set to Meadow stays Meadow on every phone set to light, which is most of
them. Only a phone that has asked for dark is shown something else, and then it
is shown the dark theme rather than nothing. The operator's palette wins
whenever it fits.

Because that is true, following the device could be **on by default**, including
for apps that already exist. An operator who wants their palette regardless can
turn it off, and the page says which it is doing rather than leaving it to be
found: "A phone set to dark sees Midnight, one set to light sees Daylight."

### 2026-08-29: the device setting is the per-viewer preference

There is no in-app appearance screen and no stored choice, and that is the
design rather than an omission.

A person already has a light-or-dark preference, they set it once, it persists
by itself, and it applies to everything on their phone. An app that asks again
is asking somebody to maintain the same setting twice. `useColorScheme` is a
hook, so changing it re-renders the app rather than needing a restart.

The alternative was a stored per-device choice, which would have meant a storage
dependency compiled into every Android build to remember something the operating
system already remembers.

### 2026-08-29: the contract is written down once

`docs/theming-a-module.md`. Every parameter, the filtering rule, the cookie
rule, and which of the Router's two doors decides the cookie path.

No PHP helper, deliberately. `example-notes` implements the whole contract in
about eighty lines with no SDK at all, which is the demonstration that this
needs none in any language, and a second copy of that code that nothing runs
would be a file to keep in step rather than a thing that works.

Four rules, and the fourth is the one that gets missed: carry the palette past
the first page. Without it the first screen is themed and everything reached
from it is not, which reads as the theme being broken rather than as the link
having dropped it. That was a real bug report before it was a rule.

### 2026-08-29: attaching a file is a capability, so the whole screen depends on it

The native tasks screen now declares `document_picker` as a requirement, which
means an operator who declines it gets the WebView instead of the native screen.

That reads as heavy-handed and is the existing design working correctly: the
WebView has had attachments all along, so declining the picker costs the native
rendering and nothing a person can do. The alternative, a native screen with a
button that is there or not depending on approval, cannot be built anyway,
because the package is only installed when the capability is approved and Metro
resolves imports before anything knows about approvals.

## Outcome

| | |
|---|---|
| Meadow on a light phone | Meadow |
| Meadow on a dark phone | the dark theme |
| Midnight on a light phone | the light theme |
| an operator who turns it off | their palette on every phone |
| the page | names both themes by name |
| the theme contract | one document, four rules |
| attaching on the phone | a capability an operator approves |
| declining that capability | the WebView, which has attachments |

132 lib runs including seven on the scheme resolution, and `bin/smoke-appearance`
against the running stack.

## What this does not do

- **No in-app theme picker.** The device setting is the preference, by design.
  Somebody who wants Meadow on a dark phone cannot have it.
- **Two schemes, three themes.** Meadow and Daylight are both light, so a light
  phone gets whichever the operator chose and a dark one always gets Midnight.
  A second dark theme would need a rule for choosing between them.
- **Verified through a build, but not on a device.** Build 78 exported the web
  preview and the shipped bundle carries `getDocumentAsync`, `useColorScheme`
  and `followDeviceScheme`, with `document_picker` in the approved capability
  list, so the package resolves and the screen bundles. Whether the system
  picker then behaves on a real Android or iOS phone is a question this box
  cannot answer at all.
- **No size limit before the upload starts.** A large file is refused by the
  storage quota after being sent, which is the wrong end.
