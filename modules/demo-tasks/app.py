"""Demo Tasks: a module that uses the whole core and is not written in Ruby.

The point of this file is the contract, not the to-do list. It talks to the core
over plain HTTP with the credentials it was handed at install, connects to its
own Postgres database directly, and never sees an S3 client.

What it exercises:

  auth      who is looking at this page, from the cookie the browser already has
  database  its own tables, over a direct connection with issued credentials
  system    a granted read of core.configuration.settings, which is audited
  storage   an attachment per task, written, handed out as a URL, and deleted
            with the task

It uses the first-party SDK, which is optional and always will be: the contract
is HTTP and a DSN, and a module that hand-rolls both is exactly as valid. What
the SDK is here for is that the hand-rolled version of this file got three
things wrong, and every module copying it inherited all three: a new Postgres
connection per request, `CREATE TABLE IF NOT EXISTS` on every page view, and an
HTTP round trip to Auth for every mention of the current user.
"""

import os

from flask import Flask, jsonify, request, redirect, url_for, Response
from markupsafe import escape

from siberian import Module, Refused

app = Flask(__name__)

# Applied once per domain, not once per request. The statements are the same
# ones that used to sit in the connection helper; what changed is when they run.
SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS tasks (
      id          serial PRIMARY KEY,
      user_email  text NOT NULL,
      title       text NOT NULL,
      done        boolean NOT NULL DEFAULT false,
      archived    boolean NOT NULL DEFAULT false,
      attachment  text,
      created_at  timestamptz NOT NULL DEFAULT now()
    )
    """,
    # Added after the first release. IF NOT EXISTS rather than a migration
    # runner, because a module owning one table does not need one.
    "ALTER TABLE tasks ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false",
]

siberian = Module("demo-tasks", schema=SCHEMA)


def current_user():
    """Who is looking at this page.

    The browser already carries the session cookie, because the module is framed
    on a subdomain of the domain it was set on. The module cannot read it as a
    credential; it hands it to Auth, which is the only service that can.

    Cached for 30 seconds by the SDK, which is the same ceiling the core
    services use and the reason a page can ask this four times without paying
    for it four times.
    """
    return siberian.current_user()


def product_settings():
    """A granted read of a table this module does not own. Audited by the core."""
    try:
        rows = siberian.granted_read("core.configuration", "settings")
        return {row["key"]: row["value"] for row in rows}
    except Exception:
        # A module that will not render because an optional read failed is worse
        # than a module that renders with defaults.
        return {}


# --- its own database -------------------------------------------------------

def db():
    """A pooled connection, with the credentials the core issued at install.

    Nothing proxies this. The core handed over a DSN and got out of the way;
    the SDK keeps one pool per domain so that staying out of the way does not
    mean a fresh TCP connection and an authentication round trip per page view.
    """
    siberian.db.migrate()
    return siberian.db.connection()


def owned_task(connection, task_id, email):
    """A task, only if it belongs to the person asking.

    user_email in the WHERE clause, not only in the INSERT. One tenant's
    database still holds several people.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, title, done, archived, attachment FROM tasks WHERE id = %s AND user_email = %s",
            (task_id, email),
        )
        return cursor.fetchone()


# --- pages ------------------------------------------------------------------

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{title}</title>
<style>{style}</style>
</head><body><div class="wrap">{body}</div></body></html>"""

STYLE = """
:root{color-scheme:light dark;--bg:#fff;--fg:#16191d;--muted:#5c6570;--line:#e3e6ea;
--accent:#1f6feb;--ok:#1a7f47;--danger:#b3261e;--surface:#f7f8fa}
@media(prefers-color-scheme:dark){:root{--bg:#171b21;--fg:#e8ecf1;--muted:#9aa4b1;
--line:#2a313a;--accent:#4c8dff;--ok:#4ac07d;--danger:#ef6b62;--surface:#1e242c}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif}
.wrap{padding:1.2rem 1.4rem 2.5rem;max-width:760px}
h1{font-size:1.2rem;margin:0 0 .15rem}
.muted{color:var(--muted)}.small{font-size:.82rem}
.row{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap}
.spread{display:flex;align-items:center;justify-content:space-between;gap:1rem}
.tabs{display:flex;gap:.9rem;margin:1rem 0 .2rem;border-bottom:1px solid var(--line)}
.tabs a{padding:.4rem 0;color:var(--muted);text-decoration:none;border-bottom:2px solid transparent}
.tabs a.on{color:var(--fg);border-bottom-color:var(--accent);font-weight:600}
form.new{display:flex;gap:.5rem;margin:1rem 0 1.2rem}
input[type=text]{flex:1;font:inherit;padding:.5rem .65rem;border:1px solid var(--line);
border-radius:6px;background:var(--bg);color:var(--fg)}
button,.button{font:inherit;font-weight:600;padding:.4rem .75rem;border-radius:6px;
border:1px solid var(--line);background:var(--surface);color:var(--fg);cursor:pointer;
text-decoration:none;display:inline-block}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
button.danger,.button.danger{color:var(--danger);border-color:var(--danger);background:transparent}
button.quiet,.button.quiet{border-color:transparent;background:transparent;color:var(--muted);padding:.3rem .4rem}
button.quiet:hover{color:var(--fg)}
ul{list-style:none;padding:0;margin:0}
li{display:flex;align-items:center;gap:.6rem;padding:.55rem .2rem;border-bottom:1px solid var(--line)}
li:last-child{border-bottom:0}
.title{flex:1}
.done .title{text-decoration:line-through;color:var(--muted)}
.pill{font-size:.72rem;padding:.1rem .45rem;border-radius:999px;background:var(--surface);color:var(--muted)}
.empty{padding:2rem 0;color:var(--muted);text-align:center}
.foot{margin-top:1.8rem;padding-top:.8rem;border-top:1px solid var(--line)}
a{color:var(--accent)}
.confirm{border:1px solid var(--danger);border-radius:8px;padding:1rem 1.1rem;margin-top:1rem}
"""


def render(body, title="Tasks"):
    return Response(PAGE.format(style=STYLE, body=body, title=title), mimetype="text/html")


def signed_out():
    return render(
        "<h1>Not signed in</h1><p class='muted'>This module could not identify you. "
        "The core owns sign-in, so there is nothing here to log into.</p>"
    )


@app.get("/up")
def up():
    return {"ok": True}


# --- the API the native screen reads ---------------------------------------
#
# The phone renders tasks as native components rather than as this module's
# HTML, so it needs the same rows as data. The web face below and this one
# read the same table through the same ownership rule: a task belongs to the
# person it was created by, in the WHERE clause and not only in the INSERT.
#
# This was missing. The native screen shipped calling `tasks.json` and the
# module never served it, so every phone and every preview showed "the module
# answered 404" from the day it was written. Nothing caught it because the
# mobile smoke checks that an app builds, not that its screens can load.
@app.get("/tasks.json")
def tasks_json():
    user = current_user()
    if not user:
        # 401 rather than a redirect: the caller is a phone, and an HTML login
        # page parsed as JSON is a worse error message than the status code.
        return jsonify({"error": "not signed in"}), 401

    showing_archived = request.args.get("archived") == "1"

    with db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT id, title, done, attachment FROM tasks "
                "WHERE user_email = %s AND archived = %s ORDER BY done, id DESC",
                (user["email"], showing_archived),
            )
            rows = cursor.fetchall()

    return jsonify([
        {"id": row[0], "title": row[1], "done": row[2], "attachment": row[3]}
        for row in rows
    ])


@app.get("/")
def index():
    user = current_user()
    if not user:
        return signed_out()

    showing_archived = request.args.get("archived") == "1"
    settings = product_settings()
    brand = settings.get("brand_name", "the product")

    with db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT id, title, done, attachment, created_at FROM tasks "
                "WHERE user_email = %s AND archived = %s ORDER BY done, id DESC",
                (user["email"], showing_archived),
            )
            rows = cursor.fetchall()
            cursor.execute(
                "SELECT count(*) FROM tasks WHERE user_email = %s AND archived = true", (user["email"],)
            )
            archived_count = cursor.fetchone()[0]

    items = []
    for task_id, title, done, attachment, created_at in rows:
        if attachment:
            attach = (
                f"<a class='small' href='{url_for('download', task_id=task_id)}'>"
                f"{escape(attachment)}</a>"
            )
        else:
            attach = (
                f"<form method='post' action='{url_for('attach', task_id=task_id)}' "
                f"enctype='multipart/form-data' style='display:inline'>"
                f"<input type='file' name='file' style='width:140px;font-size:.72rem'>"
                f"<button class='quiet small'>Attach</button></form>"
            )

        if showing_archived:
            actions = (
                f"<form method='post' action='{url_for('unarchive', task_id=task_id)}'>"
                f"<button class='quiet small' title='Put it back'>Restore</button></form>"
            )
        else:
            actions = (
                f"<form method='post' action='{url_for('archive', task_id=task_id)}'>"
                f"<button class='quiet small' title='Out of the way, not gone'>Archive</button></form>"
            )

        items.append(
            f"<li class='{'done' if done else ''}'>"
            f"<form method='post' action='{url_for('toggle', task_id=task_id)}'>"
            f"<button class='quiet' title='toggle'>{'&#10003;' if done else '&#9675;'}</button></form>"
            f"<span class='title'>{escape(title)}</span>"
            f"{attach}"
            f"<span class='pill'>{created_at.strftime('%Y-%m-%d')}</span>"
            f"{actions}"
            f"<a class='button quiet small' href='{url_for('confirm_delete', task_id=task_id)}'>Delete</a>"
            f"</li>"
        )

    empty_message = (
        "Nothing archived." if showing_archived else "Nothing yet. Add the first one."
    )
    listing = "".join(items) or f"<div class='empty'>{empty_message}</div>"

    new_form = (
        ""
        if showing_archived
        else (
            f"<form class='new' method='post' action='{url_for('create')}'>"
            f"<input type='text' name='title' placeholder='What needs doing?' required autofocus>"
            f"<button class='primary'>Add</button></form>"
        )
    )

    return render(
        f"<h1>Tasks</h1>"
        f"<div class='muted small'>{escape(user['name'])}, in {escape(brand)}.</div>"
        f"<div class='tabs'>"
        f"<a href='{url_for('index')}' class='{'' if showing_archived else 'on'}'>Active</a>"
        f"<a href='{url_for('index')}?archived=1' class='{'on' if showing_archived else ''}'>"
        f"Archived{f' ({archived_count})' if archived_count else ''}</a>"
        f"</div>"
        f"{new_form}"
        f"<ul>{listing}</ul>"
        f"<div class='foot muted small'>"
        f"This module is written in Python. It reached auth, its own Postgres database, "
        f"a granted core table, and file storage over plain HTTP, without an SDK."
        f"</div>"
    )


@app.post("/tasks")
def create():
    user = current_user()
    if not user:
        return signed_out()

    # Form from the browser, JSON from the phone. The native screen posts
    # JSON and the web page posts a form, and both mean the same thing, so
    # this reads whichever arrived rather than making the caller care.
    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or request.form.get("title") or "").strip()
    created = None
    if title:
        with db() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "INSERT INTO tasks (user_email, title) VALUES (%s, %s) RETURNING id",
                    (user["email"], title),
                )
                created = cursor.fetchone()[0]

    # Answered in the shape it was asked in. A phone that posted JSON and got
    # a redirect to an HTML page has to follow it to find out nothing went
    # wrong, and the page it lands on is not one it can render.
    if payload:
        return jsonify({"id": created, "title": title, "done": False}), 201

    return redirect(url_for("index"))


@app.post("/tasks/<int:task_id>/toggle")
def toggle(task_id):
    user = current_user()
    if not user:
        return signed_out()

    with db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE tasks SET done = NOT done WHERE id = %s AND user_email = %s",
                (task_id, user["email"])
            )
    return redirect(request.referrer or url_for("index"))


@app.post("/tasks/<int:task_id>/archive")
def archive(task_id):
    return set_archived(task_id, True)


@app.post("/tasks/<int:task_id>/unarchive")
def unarchive(task_id):
    return set_archived(task_id, False)


def set_archived(task_id, archived):
    """Archiving is reversible, which is the whole reason it exists next to delete."""
    user = current_user()
    if not user:
        return signed_out()

    with db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE tasks SET archived = %s WHERE id = %s AND user_email = %s",
                (archived, task_id, user["email"]),
            )

    return redirect(url_for("index", archived="1" if not archived else None))


@app.get("/tasks/<int:task_id>/delete")
def confirm_delete(task_id):
    """A page, not a JavaScript confirm.

    The module renders inside a frame, and a dialog that a frame throws at you
    is both easy to miss and impossible to test. A page says what will happen,
    and works with scripting turned off.
    """
    user = current_user()
    if not user:
        return signed_out()

    with db() as connection:
        task = owned_task(connection, task_id, user["email"])

    if not task:
        return redirect(url_for("index"))

    _, title, _, _, attachment = task
    extra = (
        f"<p class='muted small'>Its attachment <strong>{escape(attachment)}</strong> "
        f"will be deleted from storage too.</p>"
        if attachment
        else ""
    )

    return render(
        f"<h1>Delete this task?</h1>"
        f"<div class='confirm'>"
        f"<p><strong>{escape(title)}</strong></p>"
        f"{extra}"
        f"<p class='muted small'>There is no undo. To put it out of the way instead, archive it.</p>"
        f"<div class='row'>"
        f"<form method='post' action='{url_for('destroy', task_id=task_id)}'>"
        f"<button class='danger'>Delete it</button></form>"
        f"<form method='post' action='{url_for('archive', task_id=task_id)}'>"
        f"<button>Archive instead</button></form>"
        f"<a class='button quiet' href='{url_for('index')}'>Cancel</a>"
        f"</div></div>",
        "Delete task",
    )


@app.post("/tasks/<int:task_id>/delete")
def destroy(task_id):
    user = current_user()
    if not user:
        return signed_out()

    with db() as connection:
        task = owned_task(connection, task_id, user["email"])

        if not task:
            return redirect(url_for("index"))

        _, _, _, _, attachment = task

        # The file goes with the task. A module that deletes rows and leaves
        # files behind quietly bills its owner for storage nothing can reach.
        if attachment:
            try:
                siberian.storage.delete(f"tasks/{task_id}/{attachment}")
            except Exception:
                # The row still goes. A file the storage service could not
                # delete is a smaller problem than a task that refuses to die.
                pass

        with connection.cursor() as cursor:
            cursor.execute("DELETE FROM tasks WHERE id = %s AND user_email = %s",
                           (task_id, user["email"]))

    return redirect(url_for("index"))


@app.post("/tasks/<int:task_id>/attach")
def attach(task_id):
    user = current_user()
    if not user:
        return signed_out()

    uploaded = request.files.get("file")
    if not uploaded or not uploaded.filename:
        return redirect(url_for("index"))

    name = os.path.basename(uploaded.filename)[:120]

    try:
        siberian.storage.put(
            f"tasks/{task_id}/{name}",
            uploaded.read(),
            content_type=uploaded.mimetype or "application/octet-stream",
        )
    except Refused as refusal:
        # A full quota is not a crash. It is a sentence somebody can act on,
        # and the operator who can raise it is a different person from the one
        # looking at this page.
        return render(
            f"<h1>That file could not be stored</h1>"
            f"<p class='muted'>{escape(str(refusal))}</p>"
            f"<p><a class='button' href='{url_for('index')}'>Back</a></p>",
            title="Attachment refused",
        )

    with db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE tasks SET attachment = %s WHERE id = %s AND user_email = %s",
                (name, task_id, user["email"]),
            )

    return redirect(request.referrer or url_for("index"))


@app.get("/tasks/<int:task_id>/file")
def download(task_id):
    """The attachment, fetched from the object store rather than through here.

    This used to read the whole file into this process and copy it out again,
    which is two extra copies of every byte and a whole file in the module's
    memory for as long as the download takes.

    The authorisation question is still this module's, and it is answered first:
    only the person who owns the task gets a URL at all. What Storage guarantees
    is the narrower half, that the URL reaches exactly one object and expires.
    """
    user = current_user()
    if not user:
        return signed_out()

    with db() as connection:
        task = owned_task(connection, task_id, user["email"])

    if not task or not task[4]:
        return redirect(url_for("index"))

    return redirect(siberian.storage.signed_url(f"tasks/{task_id}/{task[4]}"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
