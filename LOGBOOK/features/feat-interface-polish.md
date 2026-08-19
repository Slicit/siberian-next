---
status: shipped
branch: feat-interface-polish
---

# A menu that cannot lose entries, and actions that look like what they do

## Intent

Four complaints, one cause between the first two: the interface had grown by
accretion and nothing checked it against itself.

Entries went missing from the left hand menu. Breadcrumbs did not exist, so a
page reached from a list looked the same as a page reached from anywhere else
and the way back was the browser button. Destructive actions asked for
confirmation through the browser's own grey box, which looks identical whether
you are renaming a domain or destroying one. And a toggle said what pressing it
does rather than what the state is, which is the wrong half.

Out of scope for this feature:

- Rewriting the permission model. Where a page asks for a permission that is
  arguably the wrong one, this makes the menu agree with the page rather than
  changing what the page asks.
- The login screen and the refusal page, which have no menu to fix.

## Plan

1. ~~The menu becomes data, and a test checks every entry against its controller.~~
2. ~~Breadcrumbs on every page, from the same data, with a leaf for detail pages.~~
3. ~~A confirmation dialog in the page, shared by every interface.~~
4. ~~Destructive actions that read as destructive, and toggles that carry state.~~

## Decisions

### 2026-08-19

- **Decision:** the menu is a list in `lib/navigation.rb`, and the layout renders it.
- **Why:** as conditionals in a template, the permission on a link and the permission on the page it leads to were written in two files on two different days, and they drifted. The Catalogue link asked for `core.modules.install` while the Catalogue page asks only for `core.modules.read`, so somebody allowed to browse the catalogue had no way in. Nothing reported it, because a menu with one fewer entry looks exactly like a menu.
- **Impact:** `test/navigation_test.rb` reads the controllers and asserts each entry asks for what its page requires. Reintroducing the original bug fails it by name, which was checked rather than assumed.

- **Decision:** a group whose entries are all hidden is dropped.
- **Why:** a heading with nothing under it reads as a menu that lost something, which is the complaint this feature started from.
- **Impact:** somebody with one permission sees one group with one entry, rather than three headings and one link.

- **Decision:** the breadcrumb's middle level comes from the same list as the menu.
- **Why:** two sources would let a page sit under one heading in the menu and claim another above the title, and nobody would notice for months.
- **Impact:** `Home > Access > People > Ophelia Operator`. A detail page sets one variable and gets its fourth level.

- **Decision:** confirmation is a dialog in the page, and the confirm button turns red when the control that asked was destructive.
- **Why:** `window.confirm` is chrome furniture. It cannot be styled, it says nothing about whether the thing is reversible, and the same box asks about a rename and a deletion.
- **Impact:** one file, `lib/ui/confirm.js`, wired into every interface by `bin/wire-shared-lib` for the same reason the stylesheet is: an interface that asks "are you sure" differently in two places has taught nobody anything. Destructive is read from the control's own class rather than guessed from the wording, so a button somebody meant to be ordinary stays ordinary. Cancel takes focus, so a stray Enter does nothing rather than the thing being asked about.

- **Decision:** a toggle carries its state in colour, and the state is written beside it.
- **Why:** a button reading "Turn off" tells you what pressing it does, which leaves you to infer the state from the verb. Colour says it without a step.
- **Impact:** green when on, muted when off, with a dot and a word next to it. Switching on a capability marked "asks a lot" now asks first; switching it off does not, because that is not the direction worth interrupting.

## Outcome

Shipped 2026-08-19. The menu renders from data for every role, verified both by
unit tests against the controllers and by `bin/smoke-backoffice`, which reports
what an operator actually sees on the page rather than what the data intended:
nine entries, everything except Roles.

Breadcrumbs are on both interfaces. The dialog is pinned, served, and parses;
how it looks is a browser question this box cannot answer, and nothing here
claims to have watched it open.
