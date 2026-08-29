"""An inbox for push notifications.

Two things a module has to do to send one. It has to know where to send it,
which means storing a device token the app registers after somebody agrees to
be interrupted. And it has to keep what it sent, because a notification that
was dismissed from the tray is not a notification that never happened: the
inbox is where it still exists.

Read, archive, and delete are three different things and the module keeps them
that way. Read is "I have seen this". Archive is "I am done with it but it
happened". Delete is "this never needs to exist again", and only that one loses
anything.
"""

import json
import os
import urllib.error
import urllib.request

from flask import Flask, g, jsonify, redirect, request, url_for
from markupsafe import escape

from siberian import Module
from siberian.theme import bridge as theme_bridge

app = Flask(__name__)

# Expo's push service. The token the app registers is an ExponentPushToken, and
# this is the only thing that knows how to turn one into a delivery.
#
# Reached with urllib rather than through the SDK, and deliberately: the SDK
# talks to the core, and Expo is a third party on the internet. A client that
# blurred the two would make "who is this module talking to" a question about
# reading the call site rather than the import.
EXPO_ENDPOINT = os.environ.get("EXPO_PUSH_ENDPOINT", "https://exp.host/--/api/v2/push/send")
EXPO_ACCESS_TOKEN = os.environ.get("EXPO_ACCESS_TOKEN", "")

# Applied once per domain rather than on every request, which is where these
# statements used to run: inside the connection helper, as DDL, on every call.
SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS devices (
      id          serial PRIMARY KEY,
      user_email  text NOT NULL,
      token       text NOT NULL UNIQUE,
      platform    text,
      last_seen   timestamptz NOT NULL DEFAULT now(),
      created_at  timestamptz NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS notifications (
      id           serial PRIMARY KEY,
      user_email   text NOT NULL,
      title        text NOT NULL,
      body         text NOT NULL DEFAULT '',
      data         jsonb NOT NULL DEFAULT '{}'::jsonb,
      read_at      timestamptz,
      archived_at  timestamptz,
      delivery     jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_at   timestamptz NOT NULL DEFAULT now()
    )
    """,
    "CREATE INDEX IF NOT EXISTS notifications_for_person ON notifications (user_email, archived_at, created_at DESC)",
]

siberian = Module("example-push", schema=SCHEMA)


# --- talking to the core ----------------------------------------------------

def current_domain():
    return siberian.domain


def current_user():
    """Who is looking at this page.

    The module hands the cookie to Auth, which is the only service that can say
    what it means. Cached for thirty seconds by the SDK, the same ceiling the
    core services use.
    """
    return siberian.current_user()


def db():
    """One pooled connection, shared by everything in this request.

    Held on the request context rather than handed out fresh: a pooled
    connection has to be given back, and the previous version never closed one
    at all, which worked only because Python eventually collected them.
    """
    if "push_connection" not in g:
        siberian.db.migrate()
        g.push_pooled = siberian.db.connection()
        g.push_connection = g.push_pooled.__enter__()

    return g.push_connection


@app.teardown_appcontext
def return_connection(error):
    """Give the connection back when the request ends, however it ends."""
    pooled = g.pop("push_pooled", None)
    g.pop("push_connection", None)
    if pooled is None:
        return

    if error is None:
        pooled.__exit__(None, None, None)
    else:
        pooled.__exit__(type(error), error, error.__traceback__)


# --- sending ----------------------------------------------------------------

def tokens_for(connection, email):
    with connection.cursor() as cursor:
        cursor.execute("SELECT token FROM devices WHERE user_email = %s", (email,))
        return [row[0] for row in cursor.fetchall()]


def push(tokens, title, body, data):
    """Hands the message to Expo, and says what happened.

    Never raises into a request. A notification that reached the inbox and not
    the tray is a notification somebody can still read; one that took the whole
    page down with it is not. The outcome is recorded on the row so the reason
    survives the request that caused it.
    """
    if not tokens:
        return {"sent": 0, "detail": "no device has registered for this person"}

    messages = [{"to": token, "title": title, "body": body, "data": data} for token in tokens]
    payload = json.dumps(messages).encode()

    req = urllib.request.Request(EXPO_ENDPOINT, method="POST", data=payload)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if EXPO_ACCESS_TOKEN:
        req.add_header("Authorization", f"Bearer {EXPO_ACCESS_TOKEN}")

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            answer = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return {"sent": 0, "detail": f"Expo refused it: {error.code}"}
    except Exception as error:
        # No egress, no DNS, no Expo. Worth saying precisely, because "it did
        # not arrive" sends somebody looking at the phone.
        return {"sent": 0, "detail": f"could not reach the push service: {error}"}

    tickets = answer.get("data") or []
    accepted = [ticket for ticket in tickets if ticket.get("status") == "ok"]
    refused = [ticket.get("message") for ticket in tickets if ticket.get("status") != "ok"]

    return {"sent": len(accepted), "detail": "; ".join(filter(None, refused)) or "accepted by the push service"}


def deliver(connection, email, title, body, data=None):
    outcome = push(tokens_for(connection, email), title, body, data or {})

    with connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO notifications (user_email, title, body, data, delivery) VALUES (%s, %s, %s, %s, %s) RETURNING id",
            (email, title, body, json.dumps(data or {}), json.dumps(outcome)),
        )
        identifier = cursor.fetchone()[0]

    return identifier, outcome


def serialise(row):
    return {
        "id": row[0],
        "title": row[1],
        "body": row[2],
        "data": row[3] or {},
        "read": row[4] is not None,
        "archived": row[5] is not None,
        "created_at": row[6].isoformat() if row[6] else None,
        "delivery": row[7] or {},
    }


def notifications_for(connection, email, archived=False):
    clause = "archived_at IS NOT NULL" if archived else "archived_at IS NULL"
    with connection.cursor() as cursor:
        cursor.execute(
            f"""SELECT id, title, body, data, read_at, archived_at, created_at, delivery
                FROM notifications WHERE user_email = %s AND {clause}
                ORDER BY created_at DESC, id DESC LIMIT 200""",
            (email,),
        )
        return [serialise(row) for row in cursor.fetchall()]


# --- the API both faces read ------------------------------------------------

@app.get("/up")
def up():
    return {"status": "ok"}


@app.post("/api/devices")
def register_device():
    """A phone saying where to reach it.

    Sent after somebody agreed to be interrupted, never before: the app asks
    the operating system first and only registers if the answer was yes.
    """
    user = current_user()
    if not user:
        return jsonify({"error": "not signed in"}), 401

    payload = request.get_json(silent=True) or {}
    token = (payload.get("token") or "").strip()
    if not token:
        return jsonify({"error": "no token"}), 422

    connection = db()
    with connection.cursor() as cursor:
        # One row per token, and the person on it can change: a shared phone
        # signed into a second account should reach the second account.
        cursor.execute(
            """INSERT INTO devices (user_email, token, platform) VALUES (%s, %s, %s)
               ON CONFLICT (token) DO UPDATE SET user_email = EXCLUDED.user_email,
                                                 platform = EXCLUDED.platform,
                                                 last_seen = now()""",
            (user["email"], token, (payload.get("platform") or "")[:20]),
        )

    return jsonify({"registered": True})


@app.get("/api/notifications")
def api_notifications():
    user = current_user()
    if not user:
        return jsonify({"error": "not signed in"}), 401

    archived = request.args.get("state") == "archived"
    connection = db()

    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT count(*) FROM notifications WHERE user_email = %s AND archived_at IS NULL AND read_at IS NULL",
            (user["email"],),
        )
        unread = cursor.fetchone()[0]

    return jsonify({
        "notifications": notifications_for(connection, user["email"], archived=archived),
        "unread": unread,
        "registered_devices": len(tokens_for(connection, user["email"])),
    })


@app.post("/api/notifications")
def api_send():
    """Sends one to whoever is asking. A demonstration, not an audience."""
    user = current_user()
    if not user:
        return jsonify({"error": "not signed in"}), 401

    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or "").strip()[:120]
    if not title:
        return jsonify({"error": "a notification needs a title"}), 422

    connection = db()
    identifier, outcome = deliver(connection, user["email"], title, (payload.get("body") or "").strip()[:1000])

    return jsonify({"id": identifier, "delivery": outcome})


def act_on(identifier, column, value):
    user = current_user()
    if not user:
        return jsonify({"error": "not signed in"}), 401

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute(
            f"UPDATE notifications SET {column} = {value} WHERE id = %s AND user_email = %s",
            (identifier, user["email"]),
        )
        changed = cursor.rowcount

    return jsonify({"ok": changed == 1}), (200 if changed == 1 else 404)


@app.post("/api/notifications/<int:identifier>/read")
def api_read(identifier):
    return act_on(identifier, "read_at", "now()")


@app.post("/api/notifications/<int:identifier>/unread")
def api_unread(identifier):
    return act_on(identifier, "read_at", "NULL")


@app.post("/api/notifications/<int:identifier>/archive")
def api_archive(identifier):
    # Archiving implies reading it. Nobody archives something they have not seen.
    act_on(identifier, "read_at", "COALESCE(read_at, now())")
    return act_on(identifier, "archived_at", "now()")


@app.post("/api/notifications/<int:identifier>/unarchive")
def api_unarchive(identifier):
    return act_on(identifier, "archived_at", "NULL")


@app.delete("/api/notifications/<int:identifier>")
def api_delete(identifier):
    user = current_user()
    if not user:
        return jsonify({"error": "not signed in"}), 401

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute("DELETE FROM notifications WHERE id = %s AND user_email = %s", (identifier, user["email"]))
        changed = cursor.rowcount

    return jsonify({"deleted": changed == 1}), (200 if changed == 1 else 404)


# --- the web face -----------------------------------------------------------

SHELL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title><style>__STYLE__</style></head><body>__BODY__</body></html>"""

STYLE = """
:root { color-scheme: light dark;
  --bg:#f6f7f9; --surface:#fff; --line:#e3e6ea; --text:#16191d; --muted:#5c6570;
  --accent:#1f6feb; --ok:#1a7f47; --danger:#b3261e; }
@media (prefers-color-scheme: dark) { :root {
  --bg:#14171a; --surface:#1b1f23; --line:#2c3238; --text:#e7eaee; --muted:#9aa3ad; } }
* { box-sizing:border-box; }
body { margin:0; padding:1.4rem; background:var(--bg); color:var(--text);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
h1 { font-size:1.35rem; margin:0 0 .2rem; }
.muted { color:var(--muted); }
.bar { display:flex; align-items:center; justify-content:space-between; gap:1rem; margin-bottom:1rem; flex-wrap:wrap; }
.card { background:var(--surface); border:1px solid var(--line); border-radius:10px; padding:1rem; margin-bottom:.9rem; }
.row { display:flex; align-items:center; gap:.5rem; flex-wrap:wrap; }
.grow { flex:1; }
input[type=text] { width:100%; font:inherit; color:var(--text); background:var(--surface);
  padding:.5rem .6rem; border:1px solid var(--line); border-radius:6px; }
button, .button { font:inherit; font-weight:600; cursor:pointer; text-decoration:none; color:var(--text);
  display:inline-flex; align-items:center; gap:.35rem; padding:.4rem .75rem; border-radius:6px;
  border:1px solid var(--line); background:var(--surface); }
button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
button.danger { color:var(--danger); border-color:var(--danger); }
.note { border:1px solid var(--line); border-radius:8px; padding:.7rem .8rem; margin-bottom:.6rem; }
.note.unread { border-left:3px solid var(--accent); background:color-mix(in srgb, var(--accent) 5%, var(--surface)); }
.note h2 { font-size:1rem; margin:0 0 .2rem; }
.note p { margin:0 0 .5rem; color:var(--muted); }
.when { font-size:.76rem; color:var(--muted); }
.tabs { display:flex; gap:.4rem; margin-bottom:.8rem; }
.tabs a { padding:.35rem .7rem; border-radius:6px; text-decoration:none; color:var(--text); border:1px solid var(--line); }
.tabs a.on { background:var(--accent); border-color:var(--accent); color:#fff; font-weight:600; }
.empty { padding:1.4rem; text-align:center; color:var(--muted); }
"""


# This module names its text variable --text rather than the SDK reference
# --fg, so the mapping is spelled out here rather than renaming a stylesheet to
# suit a default.
THEME_VARIABLES = {"--bg": "background", "--surface": "surface", "--text": "text",
                   "--muted": "muted", "--line": "line", "--accent": "accent",
                   "--danger": "danger"}


def render(body, title="Notifications"):
    style = STYLE + theme_bridge(siberian.theme, THEME_VARIABLES)
    return SHELL.replace("__TITLE__", escape(title)).replace("__STYLE__", style).replace("__BODY__", body)


def signed_out():
    return render('<div class="card empty">Sign in to the product to use this module.</div>'), 401


@app.get("/")
def index():
    user = current_user()
    if not user:
        return signed_out()

    archived = request.args.get("state") == "archived"
    connection = db()
    notes = notifications_for(connection, user["email"], archived=archived)
    devices = len(tokens_for(connection, user["email"]))

    drawn = "".join(note_html(note, archived) for note in notes)
    if not drawn:
        drawn = f'<div class="empty">{"Nothing archived." if archived else "No notifications."}</div>'

    reach = (f'{devices} device(s) registered'
             if devices else 'No device has registered. The phone app registers one when push is switched on.')

    body = f"""
      <div class="bar">
        <div><h1>Notifications</h1><p class="muted" style="margin:0">{reach}</p></div>
      </div>

      <div class="card">
        <form method="post" action="/send" class="row">
          <input class="grow" type="text" name="title" placeholder="Something happened" required>
          <input class="grow" type="text" name="body" placeholder="A sentence about it">
          <button class="primary" type="submit">Send to myself</button>
        </form>
      </div>

      <div class="tabs">
        <a href="/" class="{'' if archived else 'on'}">Inbox</a>
        <a href="/?state=archived" class="{'on' if archived else ''}">Archived</a>
      </div>

      {drawn}"""

    return render(body)


def note_html(note, archived):
    title = escape(note["title"])
    body = escape(note["body"] or "")
    when = escape((note["created_at"] or "")[:19].replace("T", " "))
    delivery = escape(note["delivery"].get("detail") or "")
    unread = "" if note["read"] else " unread"

    if archived:
        actions = (f'<form method="post" action="/notifications/{note["id"]}/unarchive" style="display:inline">'
                   '<button type="submit">Move to inbox</button></form>')
    else:
        actions = (f'<form method="post" action="/notifications/{note["id"]}/'
                   f'{"unread" if note["read"] else "read"}" style="display:inline">'
                   f'<button type="submit">Mark {"unread" if note["read"] else "read"}</button></form>'
                   f'<form method="post" action="/notifications/{note["id"]}/archive" style="display:inline">'
                   '<button type="submit">Archive</button></form>')

    return f"""
      <div class="note{unread}">
        <h2>{title}</h2>
        <p>{body}</p>
        <div class="row">
          <span class="when">{when} · {delivery}</span>
          <span class="grow"></span>
          {actions}
          <form method="post" action="/notifications/{note['id']}/delete" style="display:inline"
                onsubmit="return confirm('Delete this notification? Archiving keeps it.')">
            <button class="danger" type="submit">Delete</button></form>
        </div>
      </div>"""


# --- the web face writes ----------------------------------------------------

@app.post("/send")
def send():
    user = current_user()
    if not user:
        return signed_out()

    title = (request.form.get("title") or "").strip()[:120]
    if not title:
        return redirect(url_for("index"))

    connection = db()
    deliver(connection, user["email"], title, (request.form.get("body") or "").strip()[:1000])

    return redirect(url_for("index"))


def web_action(identifier, column, value):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute(
            f"UPDATE notifications SET {column} = {value} WHERE id = %s AND user_email = %s",
            (identifier, user["email"]),
        )

    return redirect(request.referrer or url_for("index"))


@app.post("/notifications/<int:identifier>/read")
def web_read(identifier):
    return web_action(identifier, "read_at", "now()")


@app.post("/notifications/<int:identifier>/unread")
def web_unread(identifier):
    return web_action(identifier, "read_at", "NULL")


@app.post("/notifications/<int:identifier>/archive")
def web_archive(identifier):
    web_action(identifier, "read_at", "COALESCE(read_at, now())")
    return web_action(identifier, "archived_at", "now()")


@app.post("/notifications/<int:identifier>/unarchive")
def web_unarchive(identifier):
    return web_action(identifier, "archived_at", "NULL")


@app.post("/notifications/<int:identifier>/delete")
def web_delete(identifier):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute("DELETE FROM notifications WHERE id = %s AND user_email = %s", (identifier, user["email"]))

    return redirect(request.referrer or url_for("index"))
