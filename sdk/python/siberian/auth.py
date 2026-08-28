"""Who is looking at this page.

The module never reads the session cookie as a credential. It hands the cookie
to Auth, which is the only service that can say what it means, and Auth answers
with the user and their resolved permissions.

The part this adds over doing it by hand is the cache. Without one, a page that
renders a nav bar, a list, and a footer asks Auth three times over HTTP for an
answer that cannot have changed in between. The core services already cache the
same lookup for 30 seconds and LOGBOOK states the ceiling that buys:

    Access is resolved once per session and checked in memory. The cost is a
    stated ceiling: a withdrawn permission can survive up to 30 seconds, and
    anything that cannot tolerate that asks Auth for a fresh answer.

So this caches for the same 30 seconds, and `current_user(fresh=True)` is the
escape hatch for the handful of actions where that is not good enough.
"""

import threading
import time

SESSION_COOKIE = "siberian_session"

# The same ceiling the core services use. Deliberately not longer: a module
# that outlives the core's own cache would keep letting somebody in after
# everything else had stopped.
CACHE_TTL_SECONDS = 30


class Identity:
    """A signed-in person, and what they may do."""

    def __init__(self, payload):
        self._payload = payload or {}
        self.user = self._payload.get("user") or {}
        self.permissions = list(self._payload.get("permissions") or [])

    @property
    def email(self):
        return self.user.get("email")

    @property
    def name(self):
        return self.user.get("name")

    def allows(self, permission):
        """Whether this person holds `permission`.

        Wildcards are resolved by Auth before they get here, so this is a
        membership test rather than a pattern match: a module must not have its
        own opinion about what `core.*` covers.
        """
        return permission in self.permissions

    def __bool__(self):
        return bool(self.user)


class AuthClient:
    def __init__(self, core, session_token_source, ttl=CACHE_TTL_SECONDS):
        self._core = core
        self._session_token_source = session_token_source
        self._ttl = ttl
        # Keyed on the session token, so two people using one container do not
        # see each other. Guarded because a threaded server reaches it from
        # several requests at once.
        self._cache = {}
        self._lock = threading.Lock()

    def current_user(self, fresh=False):
        """The signed-in person, or None.

        Returns None rather than raising when Auth cannot be reached: a module
        that will not render because the identity service hiccuped is worse
        than one that renders signed out. A caller that needs the difference
        should ask `identify` instead.
        """
        identity = self.identify(fresh=fresh)
        return identity.user if identity else None

    def identify(self, fresh=False):
        token = self._session_token_source()
        if not token:
            return None

        if not fresh:
            cached = self._read_cache(token)
            if cached is not None:
                return cached

        try:
            payload = self._core.call(
                "/auth/internal/session",
                timeout=5,
                headers={"X-Siberian-Session": token},
            )
        except Exception:
            # Not cached. A failure is a moment, not an answer, and caching it
            # would turn one bad second into thirty.
            return None

        if not payload.get("authenticated"):
            # Cached, because "not signed in" is a real answer and the usual
            # one for anonymous traffic. Without this every request from a
            # signed-out visitor is a round trip.
            self._write_cache(token, None)
            return None

        identity = Identity(payload)
        self._write_cache(token, identity)
        return identity

    def _read_cache(self, token):
        with self._lock:
            entry = self._cache.get(token)
            if entry is None:
                return None
            expires_at, identity = entry
            if expires_at < time.monotonic():
                del self._cache[token]
                return None
            # None is a cached "signed out", which is different from "not
            # cached". The caller checks for None either way, so this returns a
            # falsey Identity rather than None to keep the two apart here.
            return identity if identity is not None else _SIGNED_OUT

    def _write_cache(self, token, identity):
        with self._lock:
            # A module container is shared by every domain and every visitor,
            # so this could grow without bound on a busy day. Cleared wholesale
            # rather than evicted cleverly: entries live 30 seconds, so the
            # cost of forgetting all of them is one round trip each.
            if len(self._cache) > 2048:
                self._cache.clear()
            self._cache[token] = (time.monotonic() + self._ttl, identity)


class _SignedOut(Identity):
    """A cached "nobody is signed in", which is falsey like the real thing."""

    def __init__(self):
        super().__init__({})


_SIGNED_OUT = _SignedOut()
