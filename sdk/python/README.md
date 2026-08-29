# Siberian SDK for Python

A module never needs this. The contract is HTTP plus a Postgres DSN, and a
module that hand-rolls both is exactly as valid as one that imports this
(`LOGBOOK.md`, Non-goals).

What it exists for is that the hand-rolled version kept being written the same
wrong way. Three patterns were in every reference module, and each is the kind
of mistake that works perfectly until there is traffic:

| Written by hand | What it costs | What the SDK does |
|---|---|---|
| `psycopg.connect(...)` per request | a TCP connection, a handshake, and an auth round trip per page view | one pool per domain |
| `CREATE TABLE IF NOT EXISTS` in the connection helper | DDL on every request, taking an `ACCESS EXCLUSIVE` lock to decide it has nothing to do | schema applied once per domain |
| an HTTP call to Auth per `current_user()` | three round trips to render one page | cached for 30 seconds, the same ceiling the core uses |
| files read into the module and copied out | two extra copies, and a whole file in the module's memory | a URL the browser follows to the object store |

## Using it

```python
from flask import Flask
from siberian import Module

app = Flask(__name__)

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS tasks (
      id serial PRIMARY KEY,
      title text NOT NULL
    )
    """,
]

siberian = Module("demo-tasks", schema=SCHEMA)


@app.get("/")
def index():
    siberian.db.migrate()               # once per domain, cheap to call often

    user = siberian.current_user()      # cached for 30 seconds
    if not user:
        return "sign in", 401

    with siberian.db.connection() as connection:      # pooled
        with connection.cursor() as cursor:
            cursor.execute("SELECT id, title FROM tasks ORDER BY id")
            rows = cursor.fetchall()

    return {"tasks": [{"id": row[0], "title": row[1]} for row in rows]}
```

## Files

```python
siberian.storage.put("tasks/1/report.pdf", data, content_type="application/pdf")

# A private file: the module decides who may have it, then sends them to the
# object store rather than fetching it and copying it out.
return redirect(siberian.storage.signed_url("tasks/1/report.pdf"))

# A public file: a stable address, no round trip, served straight from the
# object store by the Router.
url = siberian.storage.public_url("logos/header.png")
```

### Large files, in

`put` sends the bytes through the Storage service. For anything big, hand out an
address instead and let whoever holds the bytes write to the object store
directly:

```python
mint = siberian.storage.upload_url("builds/app.apk", content_length=size,
                                   content_type="application/vnd.android.package-archive")

# The caller PUTs to mint["url"] with exactly mint["headers"], because the
# content type is signed into the signature.

siberian.storage.confirm("builds/app.apk")   # so the quota catches up
```

The quota is checked against the length you declare, which is what the ordinary
write already does with `Content-Length`. Skipping `confirm` does not lose the
file; it leaves the counters behind until something recounts. Calling it twice
is free, because it recounts rather than adds.

## What is deliberately not here

- **An S3 client.** A module never holds an object store credential. Storage
  signs and the module passes on the URL.
- **A permission model.** `identity.allows("module.tasks.use")` is a membership
  test against what Auth already resolved. A module must not have its own
  opinion about what `core.*` covers.
- **Retries.** `Refused` means the core will keep saying no: a full quota, a
  space that was never granted, a revoked token. Retrying those is how a module
  turns one refusal into a loop.

## Installing it into a module image

The SDK is copied into the image at build time. Module images build with the
repository root as their context, so:

```dockerfile
COPY sdk/python/siberian /app/siberian
RUN pip install --no-cache-dir "psycopg[binary]==3.2.1" "psycopg_pool==3.2.2"
```
