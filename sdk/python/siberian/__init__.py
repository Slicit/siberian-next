"""The Siberian module SDK for Python.

A module never needs this. The contract is HTTP plus a Postgres DSN, and a
module that hand-rolls both is exactly as valid as one that imports this
(LOGBOOK.md, Non-goals). What this exists for is that the hand-rolled version
kept being written the same wrong way.

Three patterns, each of which was in every reference module before this
existed, and each of which is the kind of mistake that works perfectly until
there is traffic:

  * a new Postgres connection per request, and `CREATE TABLE IF NOT EXISTS` on
    every page view, because the schema call was in the connection helper
  * an HTTP round trip to Auth per request to answer "who is this", with no
    cache, on a service that already caches the same answer for 30 seconds
  * files read into the module's own memory and copied out again, when the
    object store can serve them and the module only has to say who may look

The fix for all three is in here, so that the next module gets them right by
importing rather than by remembering.

Usage is deliberately small:

    from siberian import Module

    siberian = Module("demo-tasks")

    @app.get("/")
    def index():
        user = siberian.auth.current_user()
        with siberian.db.connection() as connection:
            ...
"""

from .module import Module
from .errors import SiberianError, Refused, NotFound

__all__ = ["Module", "SiberianError", "Refused", "NotFound"]
