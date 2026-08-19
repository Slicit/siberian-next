"""Pages, assembled from blocks.

Two faces over one set of data. The browser gets HTML the Base App frames; the
phone app gets JSON and renders the same blocks as native components. The block
kinds are described once, here, and both sides read that list rather than each
carrying their own idea of what a page can contain.

Written in Python for the same reason its neighbours are in PHP and Python: the
core has no opinion, and the contract is HTTP plus a Postgres DSN.
"""

import json
import os
import urllib.error
import urllib.request

import psycopg
from flask import Flask, jsonify, redirect, request, send_file, url_for
from markupsafe import escape

app = Flask(__name__)

CORE = os.environ.get("SIBERIAN_CORE_URL", "http://core")
DATABASE_TOKEN = os.environ.get("SIBERIAN_DATABASE_TOKEN", "")
STORAGE_TOKEN = os.environ.get("SIBERIAN_STORAGE_TOKEN", "")
SESSION_COOKIE = "siberian_session"

_dsn_cache = {}

# The block kinds, in one place.
#
# The native side reads the same names, so adding a kind is a change here and a
# component there, and never a change to the storage or the API in between.
BLOCK_KINDS = {
    "title": {"label": "Title", "media": None},
    "text": {"label": "Text", "media": None},
    "image": {"label": "Image", "media": "single"},
    "carousel": {"label": "Carousel", "media": "many"},
    "video": {"label": "Video", "media": "single"},
}


# --- talking to the core ----------------------------------------------------

def core_call(path, token, method="GET", body=None, content_type=None, raw=False):
    """One helper for every core call. No SDK, no signing, no client library."""
    req = urllib.request.Request(f"{CORE}{path}", method=method, data=body)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-Siberian-Domain", current_domain())
    if content_type:
        req.add_header("Content-Type", content_type)

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            payload = response.read()
            return payload if raw else json.loads(payload or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"{method} {path} -> {error.code}: {detail}") from error


def current_domain():
    return request.headers.get("X-Siberian-Domain") or request.host.split(":")[0]


def current_user():
    """Who is looking at this page.

    The module never reads the session cookie as a credential. It hands it to
    Auth, which is the only service that can say what it means.
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


def product_name():
    """A granted read of a table this module does not own. Audited by the core."""
    try:
        payload = core_call("/database/v1/system/core.configuration/settings", DATABASE_TOKEN)
        rows = {row["key"]: row["value"] for row in payload.get("rows", [])}
        return rows.get("product_name", "Pages")
    except Exception:
        return "Pages"


# --- its own database -------------------------------------------------------

def db():
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
            CREATE TABLE IF NOT EXISTS pages (
              id         serial PRIMARY KEY,
              slug       text NOT NULL UNIQUE,
              title      text NOT NULL,
              position   integer NOT NULL DEFAULT 0,
              published  boolean NOT NULL DEFAULT true,
              created_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS blocks (
              id         serial PRIMARY KEY,
              page_id    integer NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
              kind       text NOT NULL,
              position   integer NOT NULL DEFAULT 0,
              data       jsonb NOT NULL DEFAULT '{}'::jsonb,
              created_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
        # Ordering is what a page builder is for, so it is indexed rather than
        # sorted in the application.
        cursor.execute("CREATE INDEX IF NOT EXISTS blocks_page_position ON blocks (page_id, position)")


def slugify(value, fallback="page"):
    kept = [character.lower() if character.isalnum() else "-" for character in value.strip()]
    slug = "".join(kept).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug[:60] or fallback


def unique_slug(connection, base):
    with connection.cursor() as cursor:
        slug, suffix = base, 2
        while True:
            cursor.execute("SELECT 1 FROM pages WHERE slug = %s", (slug,))
            if cursor.fetchone() is None:
                return slug
            slug, suffix = f"{base}-{suffix}", suffix + 1


# --- reading pages ----------------------------------------------------------

def all_pages(connection, published_only=False):
    clause = "WHERE published" if published_only else ""
    with connection.cursor() as cursor:
        cursor.execute(f"SELECT id, slug, title, position, published FROM pages {clause} ORDER BY position, id")
        rows = cursor.fetchall()

    return [
        {"id": row[0], "slug": row[1], "title": row[2], "position": row[3], "published": row[4]}
        for row in rows
    ]


def page_by_slug(connection, slug):
    with connection.cursor() as cursor:
        cursor.execute("SELECT id, slug, title, position, published FROM pages WHERE slug = %s", (slug,))
        row = cursor.fetchone()

    if row is None:
        return None

    return {"id": row[0], "slug": row[1], "title": row[2], "position": row[3], "published": row[4]}


def blocks_for(connection, page_id):
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, kind, position, data FROM blocks WHERE page_id = %s ORDER BY position, id",
            (page_id,),
        )
        rows = cursor.fetchall()

    return [{"id": row[0], "kind": row[1], "position": row[2], "data": row[3] or {}} for row in rows]


def public_media_url(path):
    """An absolute URL a phone can fetch without a session.

    Block media lives in the public space precisely so the native side does not
    have to carry a credential to draw a picture.
    """
    if not path:
        return None
    if path.startswith("http://") or path.startswith("https://"):
        return path

    # X-Forwarded-Proto, not request.scheme. The Router terminates TLS and
    # proxies onward over plain HTTP, so the scheme this process sees is http
    # while the page it is building is https: an http image URL on an https
    # page is mixed content, and the browser drops it without drawing anything.
    scheme = request.headers.get("X-Forwarded-Proto") or request.scheme

    # Which door this request came through decides the prefix. Framed in a
    # browser the module is its own origin and the path is bare; from the phone
    # app it is reached at /m/<module>/, and a URL without that prefix points at
    # the product shell, which has no idea what /media means. The Router sets
    # the module name on the app door and nowhere else, which is what makes the
    # difference knowable here.
    module = request.headers.get("X-Siberian-Module")
    prefix = f"/m/{module}" if module else ""

    return f"{scheme}://{request.host}{prefix}/media/{path.lstrip(chr(47))}"


def serialise(block):
    """One block, in the shape both faces read.

    The web templates and the React components take the same keys. A block that
    renders differently in the two places is a bug rather than a design.
    """
    data = dict(block["data"] or {})

    return {
        "id": block["id"],
        "kind": block["kind"],
        "position": block["position"],
        "text": data.get("text"),
        "caption": data.get("caption"),
        "url": data.get("url"),
        "media": [public_media_url(item) for item in data.get("media", []) if item],
    }


# --- the JSON API, which both faces read ------------------------------------

@app.get("/up")
def up():
    return {"status": "ok"}


@app.get("/api/pages")
def api_pages():
    """Navigation. The phone app draws its own list from this."""
    if not current_user():
        return jsonify({"error": "not signed in"}), 401

    connection = db()
    return jsonify({"pages": all_pages(connection, published_only=True), "product": product_name()})


@app.get("/api/pages/<slug>")
def api_page(slug):
    if not current_user():
        return jsonify({"error": "not signed in"}), 401

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None or not page["published"]:
        return jsonify({"error": "no such page"}), 404

    return jsonify({"page": page, "blocks": [serialise(block) for block in blocks_for(connection, page["id"])]})


@app.get("/media/<path:path>")
def media(path):
    """Block media, proxied out of the public space.

    Proxied rather than linked directly because a module has no business
    handing out an object store URL, and because the phone and the browser then
    fetch the same address.
    """
    try:
        payload = core_call(f"/storage/v1/public/{path}", STORAGE_TOKEN, raw=True)
    except RuntimeError:
        return {"error": "not found"}, 404

    import io

    guessed = "image/jpeg"
    lowered = path.lower()
    for suffix, kind in (
        (".png", "image/png"),
        (".gif", "image/gif"),
        (".webp", "image/webp"),
        (".svg", "image/svg+xml"),
        (".mp4", "video/mp4"),
        (".webm", "video/webm"),
    ):
        if lowered.endswith(suffix):
            guessed = kind
            break

    return send_file(io.BytesIO(payload), mimetype=guessed, download_name=os.path.basename(path))


# --- the web face -----------------------------------------------------------

SHELL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title><style>__STYLE__</style></head>
<body>__BODY__</body></html>"""

STYLE = """
:root { color-scheme: light dark;
  --bg:#f6f7f9; --surface:#fff; --line:#e3e6ea; --text:#16191d; --muted:#5c6570;
  --accent:#1f6feb; --danger:#b3261e; --radius:10px; }
@media (prefers-color-scheme: dark) { :root {
  --bg:#14171a; --surface:#1b1f23; --line:#2c3238; --text:#e7eaee; --muted:#9aa3ad; } }
* { box-sizing:border-box; }
body { margin:0; padding:1.4rem; background:var(--bg); color:var(--text);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
a { color:var(--accent); }
h1 { font-size:1.35rem; margin:0 0 .2rem; }
h2 { font-size:1.05rem; margin:0 0 .6rem; }
.muted { color:var(--muted); }
.bar { display:flex; align-items:center; justify-content:space-between; gap:1rem; margin-bottom:1.1rem; flex-wrap:wrap; }
.card { background:var(--surface); border:1px solid var(--line); border-radius:var(--radius); padding:1rem; margin-bottom:.9rem; }
.row { display:flex; align-items:center; gap:.5rem; flex-wrap:wrap; }
.grow { flex:1; }
input[type=text], input[type=url], textarea, select {
  width:100%; font:inherit; color:var(--text); background:var(--surface);
  padding:.5rem .6rem; border:1px solid var(--line); border-radius:6px; }
textarea { min-height:5rem; resize:vertical; }
button, .button { font:inherit; font-weight:600; cursor:pointer; text-decoration:none;
  display:inline-flex; align-items:center; gap:.35rem; padding:.42rem .8rem; border-radius:6px;
  border:1px solid var(--line); background:var(--surface); color:var(--text); }
button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
button.danger { color:var(--danger); border-color:var(--danger); background:transparent; }
.nav a { display:block; padding:.5rem .6rem; border-radius:6px; text-decoration:none; color:var(--text); }
.nav a:hover { background:var(--bg); }
.nav a.current { background:var(--accent); color:#fff; font-weight:600; }
.block { border:1px solid var(--line); border-radius:8px; padding:.8rem; margin-bottom:.7rem; }
.block > header { display:flex; justify-content:space-between; align-items:center; gap:.6rem; margin-bottom:.5rem; }
.kind { font-size:.72rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); font-weight:700; }
.render h2 { font-size:1.5rem; margin:1.2rem 0 .4rem; }
.render p { margin:.4rem 0 1rem; white-space:pre-wrap; }
.render img { max-width:100%; border-radius:8px; display:block; }
.render figcaption { font-size:.85rem; color:var(--muted); margin-top:.35rem; }
.strip { display:flex; gap:.6rem; overflow-x:auto; padding-bottom:.4rem; scroll-snap-type:x mandatory; }
.strip img { flex:none; width:min(78%,420px); scroll-snap-align:center; }
.empty { padding:1.4rem; text-align:center; color:var(--muted); }
.grid { display:grid; grid-template-columns:220px 1fr; gap:1rem; align-items:start; }
@media (max-width:720px) { .grid { grid-template-columns:1fr; } }
"""


def render(body, title="Pages"):
    return SHELL.replace("__TITLE__", escape(title)).replace("__STYLE__", STYLE).replace("__BODY__", body)


def signed_out():
    return render('<div class="card empty">Sign in to the product to use this module.</div>'), 401


def navigation(pages, current=None):
    if not pages:
        return '<div class="empty">No pages yet.</div>'

    links = []
    for page in pages:
        state = " class=\"current\"" if current and page["slug"] == current else ""
        label = escape(page["title"])
        if not page["published"]:
            label += ' <span class="muted">(draft)</span>'
        links.append(f'<a href="/{page["slug"]}"{state}>{label}</a>')

    return '<nav class="nav">' + "".join(links) + "</nav>"


def render_block(block):
    """One block as HTML.

    The same keys the React components take. Two renderers, one shape, so a
    block that looks different in the two places is a bug and not a decision.
    """
    kind = block["kind"]
    caption = escape(block["caption"] or "")
    caption_html = f'<figcaption>{caption}</figcaption>' if caption else ""

    if kind == "title":
        return f"<h2>{escape(block['text'] or '')}</h2>"

    if kind == "text":
        return f"<p>{escape(block['text'] or '')}</p>"

    if kind == "image":
        source = block["media"][0] if block["media"] else None
        if not source:
            return '<p class="muted">An image block with no image.</p>'
        return f'<figure><img src="{escape(source)}" alt="{caption}">{caption_html}</figure>'

    if kind == "carousel":
        if not block["media"]:
            return '<p class="muted">A carousel with nothing in it.</p>'
        images = "".join(f'<img src="{escape(source)}" alt="">' for source in block["media"])
        return f'<figure><div class="strip">{images}</div>{caption_html}</figure>'

    if kind == "video":
        source = block["media"][0] if block["media"] else block["url"]
        if not source:
            return '<p class="muted">A video block with no video.</p>'
        if block["media"]:
            player = f'<video controls playsinline style="width:100%;border-radius:8px" src="{escape(source)}"></video>'
        else:
            # An embed somebody pasted. Framed rather than fetched, because this
            # module has no business proxying a third party's player.
            player = (f'<iframe src="{escape(source)}" style="width:100%;aspect-ratio:16/9;border:0;border-radius:8px"'
                      ' allowfullscreen loading="lazy"></iframe>')
        return f"<figure>{player}{caption_html}</figure>"

    return f'<p class="muted">A {escape(kind)} block, which this version does not know how to draw.</p>'


@app.get("/")
def index():
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    pages = all_pages(connection)

    if pages:
        return redirect(url_for("show", slug=pages[0]["slug"]))

    body = f"""
      <div class="bar"><div><h1>{escape(product_name())}</h1>
      <p class="muted" style="margin:0">Pages, assembled from blocks.</p></div></div>
      <div class="card">
        <h2>The first page</h2>
        <form method="post" action="/pages" class="row">
          <input class="grow" type="text" name="title" placeholder="Welcome" required>
          <button class="primary" type="submit">Create</button>
        </form>
      </div>"""

    return render(body, product_name())


@app.get("/<slug>")
def show(slug):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return render('<div class="card empty">No page by that name.</div>', "Not found"), 404

    blocks = [serialise(block) for block in blocks_for(connection, page["id"])]
    drawn = "".join(render_block(block) for block in blocks) or '<div class="empty">This page has no blocks yet.</div>'

    body = f"""
      <div class="bar">
        <div><h1>{escape(page['title'])}</h1>
        <p class="muted" style="margin:0">{'Published' if page['published'] else 'Draft'} · {len(blocks)} block(s)</p></div>
        <a class="button" href="/{escape(page['slug'])}/edit">Edit</a>
      </div>
      <div class="grid">
        <div class="card">{navigation(all_pages(connection), page['slug'])}
          <form method="post" action="/pages" class="row" style="margin-top:.6rem">
            <input class="grow" type="text" name="title" placeholder="New page" required>
            <button type="submit">Add</button>
          </form>
        </div>
        <div class="card render">{drawn}</div>
      </div>"""

    return render(body, page["title"])


@app.get("/<slug>/edit")
def edit(slug):
    user = current_user()
    if not user:
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return render('<div class="card empty">No page by that name.</div>', "Not found"), 404

    blocks = blocks_for(connection, page["id"])
    editors = "".join(block_editor(page, block) for block in blocks)
    choices = "".join(f'<option value="{kind}">{escape(spec["label"])}</option>' for kind, spec in BLOCK_KINDS.items())

    body = f"""
      <div class="bar">
        <div><h1>Editing {escape(page['title'])}</h1>
        <p class="muted" style="margin:0">/{escape(page['slug'])}</p></div>
        <div class="row">
          <a class="button" href="/{escape(page['slug'])}">View</a>
          <form method="post" action="/{escape(page['slug'])}/publish">
            <button type="submit">{'Unpublish' if page['published'] else 'Publish'}</button>
          </form>
          <form method="post" action="/{escape(page['slug'])}/delete"
                onsubmit="return confirm('Delete this page and every block on it?')">
            <button class="danger" type="submit">Delete page</button>
          </form>
        </div>
      </div>

      <div class="card">
        <h2>Add a block</h2>
        <form method="post" action="/{escape(page['slug'])}/blocks" class="row">
          <select name="kind" style="max-width:12rem">{choices}</select>
          <button class="primary" type="submit">Add</button>
        </form>
      </div>

      {editors or '<div class="card empty">No blocks yet. Add one above.</div>'}"""

    return render(body, f"Editing {page['title']}")


def block_editor(page, block):
    kind = block["kind"]
    spec = BLOCK_KINDS.get(kind, {})
    data = block["data"] or {}
    slug = escape(page["slug"])
    base = f"/{slug}/blocks/{block['id']}"

    fields = []
    if kind in ("title", "text"):
        control = "textarea" if kind == "text" else "input"
        if control == "textarea":
            fields.append(f'<textarea name="text" placeholder="Words">{escape(data.get("text") or "")}</textarea>')
        else:
            fields.append(f'<input type="text" name="text" value="{escape(data.get("text") or "")}" placeholder="Heading">')
    else:
        fields.append(f'<input type="text" name="caption" value="{escape(data.get("caption") or "")}" placeholder="Caption">')

    if kind == "video":
        fields.append(f'<input type="url" name="url" value="{escape(data.get("url") or "")}" '
                      'placeholder="Or paste an embed URL">')

    media = data.get("media") or []
    media_html = ""
    if spec.get("media"):
        thumbs = "".join(
            f'<img src="{escape(public_media_url(item))}" alt="" style="height:56px;border-radius:6px">'
            for item in media
        )
        multiple = " multiple" if spec["media"] == "many" else ""
        accept = "video/*,image/*" if kind == "video" else "image/*"
        media_html = f"""
          <div class="row" style="margin-top:.5rem">{thumbs}</div>
          <form method="post" action="{base}/media" enctype="multipart/form-data" class="row" style="margin-top:.5rem">
            <input type="file" name="file" accept="{accept}"{multiple} required>
            <button type="submit">Upload</button>
          </form>"""

    return f"""
      <div class="card block">
        <header>
          <span class="kind">{escape(spec.get("label", kind))}</span>
          <div class="row">
            <form method="post" action="{base}/move"><input type="hidden" name="direction" value="up">
              <button type="submit" title="Move up">↑</button></form>
            <form method="post" action="{base}/move"><input type="hidden" name="direction" value="down">
              <button type="submit" title="Move down">↓</button></form>
            <form method="post" action="{base}/delete"
                  onsubmit="return confirm('Delete this block?')">
              <button class="danger" type="submit">Delete</button></form>
          </div>
        </header>
        <form method="post" action="{base}">
          {"".join(fields)}
          <div class="row" style="margin-top:.5rem"><button type="submit">Save</button></div>
        </form>
        {media_html}
      </div>"""


# --- writes -----------------------------------------------------------------

@app.post("/pages")
def create_page():
    if not current_user():
        return signed_out()

    title = (request.form.get("title") or "").strip()[:120]
    if not title:
        return redirect(url_for("index"))

    connection = db()
    slug = unique_slug(connection, slugify(title))

    with connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO pages (slug, title, position) VALUES (%s, %s, COALESCE((SELECT MAX(position) + 1 FROM pages), 0))",
            (slug, title),
        )

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/publish")
def toggle_published(slug):
    if not current_user():
        return signed_out()

    connection = db()
    with connection.cursor() as cursor:
        cursor.execute("UPDATE pages SET published = NOT published WHERE slug = %s", (slug,))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/delete")
def delete_page(slug):
    if not current_user():
        return signed_out()

    connection = db()
    # The blocks go with it, by the foreign key. A page builder that leaves
    # orphan blocks behind is a page builder with a growing table nobody reads.
    with connection.cursor() as cursor:
        cursor.execute("DELETE FROM pages WHERE slug = %s", (slug,))

    return redirect(url_for("index"))


@app.post("/<slug>/blocks")
def add_block(slug):
    if not current_user():
        return signed_out()

    kind = request.form.get("kind")
    if kind not in BLOCK_KINDS:
        return redirect(url_for("edit", slug=slug))

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    with connection.cursor() as cursor:
        cursor.execute(
            """INSERT INTO blocks (page_id, kind, position)
               VALUES (%s, %s, COALESCE((SELECT MAX(position) + 1 FROM blocks WHERE page_id = %s), 0))""",
            (page["id"], kind, page["id"]),
        )

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/blocks/<int:block_id>")
def save_block(slug, block_id):
    if not current_user():
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    with connection.cursor() as cursor:
        cursor.execute("SELECT data FROM blocks WHERE id = %s AND page_id = %s", (block_id, page["id"]))
        row = cursor.fetchone()
        if row is None:
            return redirect(url_for("edit", slug=slug))

        data = dict(row[0] or {})
        for field in ("text", "caption", "url"):
            if field in request.form:
                data[field] = (request.form.get(field) or "").strip()[:4000]

        cursor.execute("UPDATE blocks SET data = %s WHERE id = %s", (json.dumps(data), block_id))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/blocks/<int:block_id>/move")
def move_block(slug, block_id):
    if not current_user():
        return signed_out()

    direction = -1 if request.form.get("direction") == "up" else 1
    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    blocks = blocks_for(connection, page["id"])
    order = [block["id"] for block in blocks]
    if block_id not in order:
        return redirect(url_for("edit", slug=slug))

    at = order.index(block_id)
    target = at + direction
    if 0 <= target < len(order):
        order[at], order[target] = order[target], order[at]

        # Rewritten whole rather than swapping two rows: positions drift when
        # blocks are deleted, and a full rewrite is the same cost at this size.
        with connection.cursor() as cursor:
            for position, identifier in enumerate(order):
                cursor.execute("UPDATE blocks SET position = %s WHERE id = %s", (position, identifier))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/blocks/<int:block_id>/delete")
def delete_block(slug, block_id):
    if not current_user():
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    with connection.cursor() as cursor:
        cursor.execute("DELETE FROM blocks WHERE id = %s AND page_id = %s", (block_id, page["id"]))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/blocks/<int:block_id>/media")
def upload_media(slug, block_id):
    """Media into the public space.

    Public because a phone renders these without a session: an image a native
    screen cannot fetch is an image that is not there. Nothing private belongs
    in a block.
    """
    if not current_user():
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    with connection.cursor() as cursor:
        cursor.execute("SELECT kind, data FROM blocks WHERE id = %s AND page_id = %s", (block_id, page["id"]))
        row = cursor.fetchone()

    if row is None:
        return redirect(url_for("edit", slug=slug))

    kind, data = row[0], dict(row[1] or {})
    single = BLOCK_KINDS.get(kind, {}).get("media") == "single"
    stored = [] if single else list(data.get("media") or [])

    for uploaded in request.files.getlist("file"):
        if not uploaded or not uploaded.filename:
            continue

        name = os.path.basename(uploaded.filename)[:120]
        path = f"blocks/{block_id}/{name}"
        core_call(
            f"/storage/v1/public/{path}",
            STORAGE_TOKEN,
            method="PUT",
            body=uploaded.read(),
            content_type=uploaded.mimetype or "application/octet-stream",
        )
        stored.append(path)
        if single:
            break

    data["media"] = stored
    with connection.cursor() as cursor:
        cursor.execute("UPDATE blocks SET data = %s WHERE id = %s", (json.dumps(data), block_id))

    return redirect(url_for("edit", slug=slug))
