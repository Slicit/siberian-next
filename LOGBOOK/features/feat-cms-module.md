---
status: shipped
branch: feat-pages-module
---

# A CMS module, drawn twice from one description

## Intent

The reference modules so far each proved one thing: that a module can be
written in any language, that it gets its own database and storage, that it can
ship native code. None of them proved the thing the native half is actually
for, which is a module with two faces over one set of data.

Pages assembled from blocks is a good shape for that. Title, text, image,
carousel and video are five different rendering problems, and every one of them
has to look right in a browser and on a phone without being described twice.

Out of scope for this feature:

- Anything a CMS would need to be a product: drafts with history, scheduling,
  roles per page, or a rich text editor. This is a reference module.
- Blocks contributed by other modules. The kinds are a list on the server.

## Plan

1. ~~Pages and blocks, with ordering, in the module's own database.~~
2. ~~A web face the Base App frames: navigation, an editor, a rendered page.~~
3. ~~A JSON API describing blocks in one shape.~~
4. ~~React Native components, one per kind, reusable rather than a screen.~~
5. ~~Media in the public space, reachable from both doors.~~

## Decisions

### 2026-08-20

- **Decision:** the block kinds live in one dictionary on the server and both faces read it.
- **Why:** the whole point of the exercise. Two lists would drift, and the drift would show up as a block that looks right in the browser and wrong in the app, which is the hardest kind of difference to notice.
- **Impact:** adding a kind is a line here and a component there. The API shape does not change and neither does storage.

- **Decision:** the carousel is a snapping ScrollView and the video is a WebView.
- **Why:** a dependency in this module is a dependency in every app it is installed into. A native video player would also mean this module requires a native capability, and an operator would have to approve something before a page could show a video at all.
- **Impact:** no capability is required to render anything. The video block plays an uploaded file and an embedded URL through the same component.

- **Decision:** an unknown block kind renders as a line saying so, and the page still draws.
- **Why:** the phone in somebody's pocket is older than the server it talks to. Refusing the page because one block is from a newer version is the wrong trade.
- **Impact:** the dispatcher falls back rather than throwing.

- **Decision:** block media goes in the `public` space and is served through the module.
- **Why:** a native screen draws an image without a session, so a URL that needs one is a URL that shows nothing. Serving it through the module rather than handing out an object store URL keeps the module the only thing that knows where its files are.
- **Impact:** the URL depends on which door the request arrived through, which the Router already makes knowable by setting the module name on the app door and nowhere else.

- **Decision:** pages link to pages two ways, and both are explicit.
- **Why:** they answer different questions. A navigation block is a list somebody chose to put on a page; next and previous are a path for somebody reading straight through. Taking the path from the menu ordering would conflate them, and a page can sit fourth in the menu and still be the one that follows the first.
- **Impact:** a `nav` block holds slugs, and a page carries `next_slug` and `prev_slug`. Neither can name the page it is on, and both resolve to titles on the server so a deleted page stops being a link somebody can tap and land nowhere.

- **Decision:** the picker is an input bound to a `datalist`.
- **Why:** a select cannot be filtered and a combo box built by hand is a script, in a module that has none. A datalist filters as somebody types, shows the title beside the slug, and submits the slug.
- **Impact:** one helper serves the nav block and both ends of the path, so they cannot behave differently.

## Outcome

Shipped 2026-08-20. A page with one of every block renders in the browser, and
the same page comes back through the app door as JSON with absolute media URLs
that resolve from both doors.

The proof that the two faces are one module is in the artifact: the JavaScript
bundle inside the built APK carries `PageNavigator`, `CarouselBlock` and
`VideoBlock` along with the `api/pages` call, next to `TaskList` from the other
native module.

Linking came later and added two more block-shaped things: a navigation block
and a path through the pages. Both are driven by the smoke, which checks that a
page is never offered a link to itself and that the picker lists the others.

Building a module that had never been installed before found four bugs that
reinstalling an existing one never would: media URLs built from the wrong
scheme, media URLs that ignored which door the request came through, a module
absent from its own upstream map while installing, and a superseded config file
still being included from a volume that outlived the image that wrote it.
