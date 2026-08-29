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

from flask import Flask, g, jsonify, redirect, request, url_for
from markupsafe import escape

from siberian import Module, Refused

app = Flask(__name__)

# This module's own name, which is the segment the Router's public media path
# is addressed by. It matches `name:` in module.yml; a module that renamed
# itself in one place and not the other would serve broken images.
MODULE_NAME = "example-cms"

# Applied once per domain rather than on every request. These are the same
# statements that used to sit inside the connection helper, where they ran as
# DDL on every page view: Postgres takes an ACCESS EXCLUSIVE lock to decide it
# has nothing to do, and a page builder holding that twice per render is a page
# builder that stops working under load.
SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS pages (
      id         serial PRIMARY KEY,
      slug       text NOT NULL UNIQUE,
      title      text NOT NULL,
      position   integer NOT NULL DEFAULT 0,
      published  boolean NOT NULL DEFAULT true,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS blocks (
      id         serial PRIMARY KEY,
      page_id    integer NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
      kind       text NOT NULL,
      position   integer NOT NULL DEFAULT 0,
      data       jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """,
    # Ordering is what a page builder is for, so it is indexed rather than
    # sorted in the application.
    "CREATE INDEX IF NOT EXISTS blocks_page_position ON blocks (page_id, position)",
    # Added after the first release. A column rather than a migration runner,
    # because a module owning two tables does not need one.
    "ALTER TABLE pages ADD COLUMN IF NOT EXISTS next_slug text",
    "ALTER TABLE pages ADD COLUMN IF NOT EXISTS prev_slug text",
]

siberian = Module(MODULE_NAME, schema=SCHEMA)

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
    # A block of links to other pages. The only kind whose content is other
    # pages rather than words or files, which is why it resolves titles on the
    # way out: a client should not have to fetch the page list to draw a label.
    "nav": {"label": "Navigation", "media": None},
}


# --- talking to the core -----------------------------------------------------

def current_domain():
    return siberian.domain


def current_user():
    """Who is looking at this page.

    The module never reads the session cookie as a credential. It hands it to
    Auth, which is the only service that can say what it means.

    Cached for thirty seconds by the SDK, the same ceiling the core services
    use. A page that draws a nav, a block list and a footer asks this several
    times, and it used to be a round trip every time.
    """
    return siberian.current_user()


def product_name():
    """A granted read of a table this module does not own. Audited by the core."""
    try:
        rows = {row["key"]: row["value"]
                for row in siberian.granted_read("core.configuration", "settings")}
        return rows.get("product_name", "Pages")
    except Exception:
        # A module that will not render because an optional read failed is worse
        # than one that renders with a default name.
        return "Pages"


# --- its own database -------------------------------------------------------

def db():
    """One pooled connection, shared by everything in this request.

    Nothing proxies this. The core handed over a DSN and got out of the way; the
    SDK keeps one pool per domain so that staying out of the way does not mean a
    fresh connection and an authentication round trip on every page view.

    Held on the request context rather than handed out fresh, for two reasons.
    A page here calls this several times, and it used to open a connection for
    each. And a pooled connection has to be given back: the previous version
    never closed one at all, which worked only because Python eventually
    collected them, and against a pool would empty it instead.
    """
    if "cms_connection" not in g:
        siberian.db.migrate()
        # The context manager is kept so teardown can close it the way the
        # `with` block it replaces would have.
        g.cms_pooled = siberian.db.connection()
        g.cms_connection = g.cms_pooled.__enter__()

    return g.cms_connection


@app.teardown_appcontext
def return_connection(error):
    """Give the connection back when the request ends, however it ends."""
    pooled = g.pop("cms_pooled", None)
    g.pop("cms_connection", None)
    if pooled is None:
        return

    # The exception is passed on when there was one, so the pool rolls back
    # rather than handing a connection mid-transaction to whoever asks next.
    if error is None:
        pooled.__exit__(None, None, None)
    else:
        pooled.__exit__(type(error), error, error.__traceback__)


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
        cursor.execute(
            f"SELECT id, slug, title, position, published, next_slug, prev_slug FROM pages {clause} ORDER BY position, id"
        )
        rows = cursor.fetchall()

    return [as_page(row) for row in rows]


def as_page(row):
    return {
        "id": row[0], "slug": row[1], "title": row[2], "position": row[3],
        "published": row[4], "next_slug": row[5], "prev_slug": row[6],
    }


def titles_for(connection):
    """slug to title, for anything that has to draw a link to a page."""
    return {page["slug"]: page["title"] for page in all_pages(connection)}


def page_by_slug(connection, slug):
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, slug, title, position, published, next_slug, prev_slug FROM pages WHERE slug = %s",
            (slug,),
        )
        row = cursor.fetchone()

    return as_page(row) if row else None


def blocks_for(connection, page_id):
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, kind, position, data FROM blocks WHERE page_id = %s ORDER BY position, id",
            (page_id,),
        )
        rows = cursor.fetchall()

    return [{"id": row[0], "kind": row[1], "position": row[2], "data": row[3] or {}} for row in rows]


def neighbours(page, titles):
    """The pages either side of this one, if somebody said which.

    Explicit rather than taken from the ordering. Pages are ordered for the
    menu, and a reader walking through them in that order is a different
    intention from a menu: a page can sit fourth in the list and still be the
    one that follows the first.
    """
    return {
        side: ({"slug": slug, "title": titles[slug]} if slug in titles else None)
        for side, slug in (("next", page.get("next_slug")), ("prev", page.get("prev_slug")))
    }


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

    # An address on the product domain, served by the Router straight out of
    # Storage. This module never sees the bytes.
    #
    # It used to proxy them: every image was fetched from Storage into this
    # process and copied out again, which put an entire file in Python's memory
    # for no reason other than that the URL pointed here. It also meant the
    # content type had to be guessed from the file extension, because the real
    # one was lost on the way through.
    #
    # Absolute, and on the domain rather than on request.host, because the same
    # URL has to work from three places that do not share an origin: framed in
    # the browser this module answers on <module>.apps.<domain>, the phone app
    # reaches it at /m/<module>/, and the preview runs on core.<domain>. Only
    # the product domain serves /-/public, so naming it is what makes one URL
    # correct everywhere instead of three URLs that are each correct once.
    #
    # The domain is the header the Router sets, which is the domain being
    # served rather than whatever host this process was addressed by.
    domain = request.headers.get("X-Siberian-Domain") or request.host

    return f"{scheme}://{domain}/-/public/{MODULE_NAME}/{path.lstrip(chr(47))}"


def serialise(block, titles=None):
    """One block, in the shape both faces read.

    The web templates and the React components take the same keys. A block that
    renders differently in the two places is a bug rather than a design.
    """
    data = dict(block["data"] or {})
    known = titles or {}

    # Links resolve to a title here rather than on the client. A page that was
    # deleted or unpublished simply is not in the list any more: a link to it
    # would be a link somebody could tap and land nowhere.
    links = [
        {"slug": slug, "title": known[slug]}
        for slug in data.get("links", [])
        if slug in known
    ]

    return {
        "id": block["id"],
        "kind": block["kind"],
        "position": block["position"],
        "text": data.get("text"),
        "caption": data.get("caption"),
        "url": data.get("url"),
        "media": [public_media_url(item) for item in data.get("media", []) if item],
        "links": links,
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

    titles = titles_for(connection)

    return jsonify({
        "page": page,
        "blocks": [serialise(block, titles) for block in blocks_for(connection, page["id"])],
        **neighbours(page, titles),
    })




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
.pager { display:flex; justify-content:space-between; gap:.6rem; margin-top:1.4rem; padding-top:1rem; border-top:1px solid var(--line); }
.links { list-style:none; margin:0 0 1rem; padding:0; }
.links li + li { margin-top:.3rem; }
.links a { display:block; padding:.55rem .7rem; border:1px solid var(--line); border-radius:8px; text-decoration:none; color:var(--text); }
.links a:hover { border-color:var(--accent); color:var(--accent); }
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

    if kind == "nav":
        if not block["links"]:
            return '<p class="muted">A navigation block with no links.</p>'
        items = "".join(
            f'<li><a href="/{escape(link["slug"])}">{escape(link["title"])}</a></li>'
            for link in block["links"]
        )
        return f'<ul class="links">{items}</ul>' + (f"<p>{caption}</p>" if caption else "")

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


def neighbour_html(sides):
    """Next and previous, at the foot of a page.

    Laid out so previous is on the left and next on the right even when only
    one of them exists, because a single link that moves depending on which one
    it is makes somebody read it before clicking.
    """
    if not sides.get("next") and not sides.get("prev"):
        return ""

    def side(which, label):
        page = sides.get(which)
        if not page:
            return '<span></span>'
        return f'<a class="button" href="/{escape(page["slug"])}">{label} {escape(page["title"])}</a>'

    return ('<nav class="pager">'
            + side("prev", "&larr;")
            + side("next", "&rarr;")
            + "</nav>")


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

    titles = titles_for(connection)
    blocks = [serialise(block, titles) for block in blocks_for(connection, page["id"])]
    drawn = "".join(render_block(block) for block in blocks) or '<div class="empty">This page has no blocks yet.</div>'
    drawn += neighbour_html(neighbours(page, titles))

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

    pages = all_pages(connection)
    blocks = blocks_for(connection, page["id"])
    editors = "".join(block_editor(page, block, pages) for block in blocks)
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

      <div class="card">
        <h2>Where this page leads</h2>
        <p class="muted" style="margin:0 0 .6rem; font-size:.88rem">
          Somebody reading straight through. Set either, both, or neither: this
          is a path through the pages, which is not the same thing as the order
          they appear in the menu.
        </p>
        <form method="post" action="/{escape(page["slug"])}/neighbours" class="row">
          <div class="grow">
            <label class="muted" style="font-size:.8rem">Previous</label>
            {page_picker("prev_slug", pages, exclude=page["slug"], current=page["prev_slug"])}
          </div>
          <div class="grow">
            <label class="muted" style="font-size:.8rem">Next</label>
            {page_picker("next_slug", pages, exclude=page["slug"], current=page["next_slug"])}
          </div>
          <button type="submit">Save</button>
        </form>
      </div>

      {editors or '<div class="card empty">No blocks yet. Add one above.</div>'}"""

    return render(body, f"Editing {page['title']}")


def page_picker(name, pages, exclude=None, current=None, placeholder="Type to filter pages"):
    """A filterable page picker, with no JavaScript.

    An input bound to a datalist: typing filters, and the browser shows the
    title beside the slug. A plain select cannot be filtered and a combo box
    built by hand would be a script in a module that has none.
    """
    listing = f"pages-{name}"
    options = "".join(
        f'<option value="{escape(candidate["slug"])}" label="{escape(candidate["title"])}">'
        for candidate in pages if candidate["slug"] != exclude
    )

    return (f'<input type="text" name="{name}" list="{listing}" value="{escape(current or "")}"'
            f' placeholder="{escape(placeholder)}" autocomplete="off">'
            f'<datalist id="{listing}">{options}</datalist>')


def block_editor(page, block, pages=None):
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

    links_html = ""
    if kind == "nav":
        known = {candidate["slug"]: candidate["title"] for candidate in (pages or [])}
        chosen = "".join(
            f'<li><span class="grow">{escape(known[slug])}</span>'
            f'<form method="post" action="{base}/links/remove" style="display:inline">'
            f'<input type="hidden" name="slug" value="{escape(slug)}">'
            '<button type="submit">Remove</button></form></li>'
            for slug in (data.get("links") or []) if slug in known
        )
        links_html = f"""
          <ul class="links" style="margin:.4rem 0">{chosen}</ul>
          <form method="post" action="{base}/links" class="row">
            {page_picker(f"slug", pages or [], exclude=page["slug"], placeholder="Add a page")}
            <button type="submit">Add link</button>
          </form>"""

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
        {links_html}
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
        try:
            siberian.storage.put(
                path, uploaded.read(), space="public",
                content_type=uploaded.mimetype or "application/octet-stream",
            )
        except Refused as refusal:
            # A full quota is not a crash. It is a sentence somebody can act on,
            # and the operator who can raise it is not the person looking at
            # this page.
            return render(
                f"<h1>That file could not be stored</h1>"
                f"<p class='muted'>{escape(str(refusal))}</p>"
                f"<p><a class='button' href='{url_for('edit', slug=slug)}'>Back</a></p>",
                title="Upload refused",
            )
        stored.append(path)
        if single:
            break

    data["media"] = stored
    with connection.cursor() as cursor:
        cursor.execute("UPDATE blocks SET data = %s WHERE id = %s", (json.dumps(data), block_id))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/neighbours")
def set_neighbours(slug):
    """Where this page leads, and what led here.

    A slug that names no page is stored as nothing rather than refused: the
    picker offers real pages, and somebody who typed something else meant to
    clear it more often than they meant to break it.
    """
    if not current_user():
        return signed_out()

    connection = db()
    known = titles_for(connection)

    values = {}
    for side in ("next_slug", "prev_slug"):
        candidate = (request.form.get(side) or "").strip()
        values[side] = candidate if candidate in known and candidate != slug else None

    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE pages SET next_slug = %s, prev_slug = %s WHERE slug = %s",
            (values["next_slug"], values["prev_slug"], slug),
        )

    return redirect(url_for("edit", slug=slug))


def edit_links(slug, block_id, change):
    if not current_user():
        return signed_out()

    connection = db()
    page = page_by_slug(connection, slug)
    if page is None:
        return redirect(url_for("index"))

    target = (request.form.get("slug") or "").strip()

    with connection.cursor() as cursor:
        cursor.execute("SELECT data FROM blocks WHERE id = %s AND page_id = %s", (block_id, page["id"]))
        row = cursor.fetchone()
        if row is None:
            return redirect(url_for("edit", slug=slug))

        data = dict(row[0] or {})
        links = list(data.get("links") or [])
        data["links"] = change(links, target, titles_for(connection), page["slug"])

        cursor.execute("UPDATE blocks SET data = %s WHERE id = %s", (json.dumps(data), block_id))

    return redirect(url_for("edit", slug=slug))


@app.post("/<slug>/blocks/<int:block_id>/links")
def add_link(slug, block_id):
    def append(links, target, known, here):
        # A page cannot link to itself, and a link already there is not added
        # twice: both are mistakes with no useful reading.
        if target in known and target != here and target not in links:
            links.append(target)
        return links

    return edit_links(slug, block_id, append)


@app.post("/<slug>/blocks/<int:block_id>/links/remove")
def remove_link(slug, block_id):
    return edit_links(slug, block_id, lambda links, target, _known, _here: [s for s in links if s != target])
