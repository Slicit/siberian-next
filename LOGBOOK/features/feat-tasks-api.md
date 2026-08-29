---
status: shipped
branch: feat-tasks-api
---

# The screen the module never answered

## Intent

Reported from the mobile preview: the tasks app showed "the module answered
404".

That string is in `modules/demo-tasks/native/index.js`, which the native screen
prints when its own API call fails. It calls `siberian.call("tasks.json")`, and
`demo-tasks` served no such route.

## Decisions

### 2026-08-29: it was never there, rather than removed

Worth establishing before fixing, because the module had just been ported to the
SDK and the obvious suspicion was that the port dropped a route.

`git log -S "tasks.json" -- modules/demo-tasks/app.py` returns nothing. No
commit ever added it and none removed it. The native screen shipped in
`c7f87dd` calling an endpoint that had not been written, so every phone and
every preview has shown this error since the day the screen existed.

### 2026-08-29: both faces answer in the shape they were asked in

The web page posts a form and expects a redirect. The native screen posts JSON
and expects JSON. `POST /tasks` now reads whichever arrived and answers to
match, rather than making one of the two callers accommodate the other.

A phone that posted JSON and received a 302 to an HTML page has to follow the
redirect to learn that nothing went wrong, and the page it lands on is not one
it can render.

`GET /tasks.json` answers 401 rather than redirecting for the same reason: an
HTML login page parsed as JSON is a worse error message than a status code.

Both read the same table through the same ownership rule the web face uses,
`user_email` in the WHERE clause and not only in the INSERT.

### 2026-08-29: the smoke checked the door, not the screen

`smoke-mobile` passed throughout. Its step 7 checks that `/m/demo-tasks/`
answers 200, that an unknown module answers 404 rather than 502, and that a
capability id still frames. All true, all passing, and none of it touches the
call the screen actually makes.

A door that opens is not a screen that loads. The step now fetches the screen's
own data and fails if it is not a JSON list, which is the check that would have
caught this on the day it was introduced.

## Outcome

Fixed and verified end to end through the app door:

| | |
|---|---|
| `GET /m/demo-tasks/tasks.json` | **200**, with the signed-in person's tasks |
| `POST` with JSON, the Add button | **201**, and the task appears in the list |
| `POST` with a form, the web page | **302**, unchanged |

The sweep is 20/20, and `smoke-mobile` now covers the path that was broken.
