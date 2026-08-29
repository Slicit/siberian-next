"""Example Mail Relay: a module that answers a core interface.

The other reference modules extend the product. This one extends the core: it
implements `mail.transport.v1`, so once installed the Mailer routes through it
instead of through the transport the core ships with, and never learns that a
module answered.

It was a stock nginx image declaring an endpoint nginx cannot serve, which meant
it accepted the interface and 404ed every delivery. A 4xx is the Mailer being
told the message is wrong and will never be right, so every message in the
system died on its first attempt. A reference implementation that does not
implement the thing is worse than no reference implementation, because the core
believes it.

What it does instead is what a transport minimally must: accept the message,
keep its own record of it, and answer. It does not send anything anywhere, and
says so, because a transport that discards mail and reports success is the same
bug in a nicer disguise.
"""

import os
from datetime import datetime, timezone

from flask import Flask, jsonify, request
from markupsafe import escape

from siberian import Module
from siberian.theme import bridge as theme_bridge

app = Flask(__name__)

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS deliveries (
      id serial PRIMARY KEY,
      message_id text,
      recipient text NOT NULL,
      sender text,
      subject text,
      text_body text,
      html_body text,
      received_at timestamptz NOT NULL DEFAULT now()
    )
    """,
    "CREATE INDEX IF NOT EXISTS deliveries_received_at ON deliveries (received_at DESC)",
]

siberian = Module("example-relay", schema=SCHEMA)


@app.get("/up")
def up():
    return jsonify({"ok": True, "transport": "example-relay"})


@app.post("/internal/mail")
def deliver():
    """One message, handed over by the Mailer.

    Reached over the internal network by module short name. There is no session
    here and there is not meant to be: the caller is the core, not a person.

    The answer is the whole contract. 2xx means delivered and the Mailer stops
    asking; 4xx means the message is wrong and no retry will help, which is why
    the only 4xx here is for a message with no recipient. Anything else that
    goes wrong is a 5xx, so the Mailer keeps the message and tries again.
    """
    payload = request.get_json(silent=True) or {}
    recipient = (payload.get("to") or "").strip()

    if not recipient:
        # Permanent, and correctly so: a message with nobody to send it to will
        # not become sendable later.
        return jsonify({"error": "no recipient"}), 400

    siberian.db.migrate()

    with siberian.db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO deliveries
                  (message_id, recipient, sender, subject, text_body, html_body)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (str(payload.get("id") or ""), recipient,
                 payload.get("module_name"), payload.get("subject"),
                 payload.get("text_body"), payload.get("html_body")),
            )

    return jsonify({"accepted": True, "recorded": True, "sent": False}), 200


STYLE = """
:root { color-scheme: light dark;
  --bg:#f6f7f9; --surface:#fff; --line:#e3e6ea; --fg:#16191d; --muted:#5c6570;
  --accent:#1f6feb; --danger:#b3261e; }
@media (prefers-color-scheme: dark) { :root {
  --bg:#14171a; --surface:#1b1f23; --line:#2c3238; --fg:#e7eaee; --muted:#9aa3ad; } }
* { box-sizing:border-box; }
body { margin:0; padding:1.4rem; background:var(--bg); color:var(--fg);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
h1 { font-size:1.3rem; margin:0 0 .2rem; }
.muted { color:var(--muted); }
.small { font-size:.84rem; }
.note { background:var(--surface); border:1px solid var(--line); border-radius:10px;
  padding:.9rem 1rem; margin:.7rem 0; }
.note h2 { font-size:.98rem; margin:0 0 .3rem; }
pre { white-space:pre-wrap; word-break:break-word; margin:.5rem 0 0;
  font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; color:var(--muted); }
a { color:var(--accent); }
"""

PAGE = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title><style>{style}</style></head><body>{body}</body></html>"""


@app.get("/")
def index():
    """What this transport has been handed.

    Worth a page rather than only a table: in development nothing is actually
    sent anywhere, so this is where somebody confirms that a password reset
    email was produced and what link it carried.
    """
    siberian.db.migrate()

    with siberian.db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, recipient, sender, subject, text_body, received_at
                FROM deliveries ORDER BY received_at DESC LIMIT 50
                """
            )
            rows = cursor.fetchall()

    body = [
        "<h1>Mail relay</h1>",
        "<p class='muted small'>This module implements <code>mail.transport.v1</code>. "
        "It records what the Mailer hands it and sends nothing onward, which is what "
        "makes it useful in development and useless in production.</p>",
    ]

    if not rows:
        body.append("<p class='muted'>Nothing handed over yet.</p>")

    for row in rows:
        received = row[5].astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        body.append(
            f"<div class='note'><h2>{escape(row[3] or '(no subject)')}</h2>"
            f"<div class='muted small'>to {escape(row[1])}"
            f"{' from ' + escape(row[2]) if row[2] else ''} &middot; {received}</div>"
            f"<pre>{escape((row[4] or '')[:2000])}</pre></div>"
        )

    style = STYLE + theme_bridge(siberian.theme)
    return PAGE.format(title="Mail relay", style=style, body="".join(body))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), threaded=True)
