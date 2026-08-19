"""Demo Tasks: a module that uses the whole core and is not written in Ruby.

The point of this file is the contract, not the to-do list. It talks to the core
over plain HTTP with the credentials it was handed at install, connects to its
own Postgres database directly, and never imports an SDK or an S3 client.

What it exercises:

  auth      who is looking at this page, from the cookie the browser already has
  database  its own tables, over a direct connection with issued credentials
  system    a granted read of core.configuration.settings, which is audited
  storage   an attachment per task, written, read back, and deleted with the task
"""

import os
import io
import json
import urllib.request
import urllib.error

import psycopg
from flask import Flask, request, redirect, url_for, Response, send_file
from markupsafe import escape

app = Flask(__name__)

CORE = os.environ.get("SIBERIAN_CORE_URL", "http://core")
DATABASE_TOKEN = os.environ.get("SIBERIAN_DATABASE_TOKEN", "")
STORAGE_TOKEN = os.environ.get("SIBERIAN_STORAGE_TOKEN", "")
SESSION_COOKIE = "siberian_session"

_dsn_cache = {}


# --- talking to the core ----------------------------------------------------

def core_call(path, token, method="GET", body=None, content_type=None, raw=False):
    """One helper for every core call. No SDK, no signing, no client library."""
    req = urllib.request.Request(f"{CORE}{path}", method=method, data=body)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    # The domain travels with every request. The Router set it on the way in and
    # the core needs it on the way out to resolve per-domain data.
    req.add_header("X-Siberian-Domain", current_domain())
    if content_type:
        req.add_header("Content-Type", content_type)

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            payload = response.read()
            return payload if raw else json.loads(payload or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"{method} {path} -> {error.code}: {detail}") from error


def current_domain():
    return request.headers.get("X-Siberian-Domain") or request.host.split(":")[0]


def current_user():
    """Who is looking at this page.

    The browser already carries the session cookie, because the module is framed
    on a subdomain of the domain it was set on. The module cannot read it as a
    credential; it hands it to Auth, which is the only service that can.
    """
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None

    req = urllib.request.Request(f"{CORE}/auth/internal/session")
    req.add_header("X-Siberian-Session", token)
    req.add_header("X-Siberian-Domain", current_domain())
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            payload = json.loads(response.read() or b"{}")
    except Exception:
        return None

    return payload.get("user") if payload.get("authenticated") else None


def product_settings():
    """A granted read of a table this module does not own. Audited by the core."""
    try:
        payload = core_call("/database/v1/system/core.configuration/settings", DATABASE_TOKEN)
        return {row["key"]: row["value"] for row in payload.get("rows", [])}
    except Exception:
        # A module that will not render because an optional read failed is worse
        # than a module that renders with defaults.
        return {}


# --- its own database -------------------------------------------------------

def db():
    """A direct connection, with the credentials the core issued at install.

    Nothing proxies this. The core handed over a DSN and got out of the way.
    """
    domain = current_domain()
    if domain not in _dsn_cache:
        _dsn_cache[domain] = core_call("/database/v1/credentials", DATABASE_TOKEN)["url"]

    connection = psycopg.connect(_dsn_cache[domain], autocommit=True)
    ensure_schema(connection)
    return connection


def ensure_schema(connection):
    with connection.cursor() as cursor:
        cursor.execute(
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
            """
        )
        # Added after the first release. IF NOT EXISTS rather than a migration
        # runner, because a module owning one table does not need one.
        cursor.execute("ALTER TABLE tasks ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false")


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


@app.get("/")
def index():
    user = current_user()
    if not user:
        return signed_out()

    showing_archived = request.args.get("archived") == "1"
    settings = product_settings()
    brand = settings.get("brand_name", "the product")

    connection = db()
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
    connection.close()

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

    title = (request.form.get("title") or "").strip()
    if title:
        connection = db()
        with connection.cursor() as cursor:
            cursor.execute("INSERT INTO tasks (user_email, title) VALUES (%s, %s)", (user["email"], title))
        connection.close()

    return redirect(url_for("index"))


@app.post("/tasks/<int:task_id>/toggle")
def toggle(task_id):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE tasks SET done = NOT done WHERE id = %s AND user_email = %s", (task_id, user["email"])
        )
    connection.close()
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

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE tasks SET archived = %s WHERE id = %s AND user_email = %s",
            (archived, task_id, user["email"]),
        )
    connection.close()

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

    connection = db()
    task = owned_task(connection, task_id, user["email"])
    connection.close()

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

    connection = db()
    task = owned_task(connection, task_id, user["email"])

    if not task:
        connection.close()
        return redirect(url_for("index"))

    _, _, _, _, attachment = task

    # The file goes with the task. A module that deletes rows and leaves files
    # behind quietly bills its owner for storage nothing can reach.
    if attachment:
        try:
            core_call(
                f"/storage/v1/files/tasks/{task_id}/{attachment}", STORAGE_TOKEN, method="DELETE"
            )
        except Exception:
            # The row still goes. A file the storage service could not delete is
            # a smaller problem than a task that refuses to die.
            pass

    with connection.cursor() as cursor:
        cursor.execute("DELETE FROM tasks WHERE id = %s AND user_email = %s", (task_id, user["email"]))
    connection.close()

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

    core_call(
        f"/storage/v1/files/tasks/{task_id}/{name}",
        STORAGE_TOKEN,
        method="PUT",
        body=uploaded.read(),
        content_type=uploaded.mimetype or "application/octet-stream",
    )

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE tasks SET attachment = %s WHERE id = %s AND user_email = %s",
            (name, task_id, user["email"]),
        )
    connection.close()

    return redirect(request.referrer or url_for("index"))


@app.get("/tasks/<int:task_id>/file")
def download(task_id):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    task = owned_task(connection, task_id, user["email"])
    connection.close()

    if not task or not task[4]:
        return redirect(url_for("index"))

    name = task[4]
    content = core_call(f"/storage/v1/files/tasks/{task_id}/{name}", STORAGE_TOKEN, raw=True)
    return send_file(io.BytesIO(content), download_name=name, as_attachment=True)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
