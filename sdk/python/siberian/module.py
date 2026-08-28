"""One object a module builds once, holding the clients it needs.

Everything here is read from the environment the Orchestrator injected at
install. A module is handed its credentials and the address of the core; it
never discovers them, and it never learns a container name.
"""

import os

from .auth import SESSION_COOKIE, AuthClient
from .core import DEFAULT_CORE_URL, CoreClient
from .database import Database
from .storage import Storage


class Module:
    """The SDK's entry point.

        siberian = Module("demo-tasks", schema=SCHEMA)

    The current domain and the session cookie both come from the request being
    served, so they are supplied by a request adapter rather than held here. In
    Flask that is done for you; anywhere else, pass `request_adapter`.
    """

    def __init__(self, name, schema=None, core_url=None, request_adapter=None,
                 database_token=None, storage_token=None, mail_token=None):
        self.name = name

        self._adapter = request_adapter or _flask_adapter()
        if self._adapter is None:
            raise RuntimeError(
                "no request adapter: install flask, or pass request_adapter= "
                "with .domain() and .session_token() methods"
            )

        self.core = CoreClient(
            core_url or os.environ.get("SIBERIAN_CORE_URL", DEFAULT_CORE_URL),
            self._adapter.domain,
        )

        self.database_token = database_token or os.environ.get("SIBERIAN_DATABASE_TOKEN", "")
        self.storage_token = storage_token or os.environ.get("SIBERIAN_STORAGE_TOKEN", "")
        self.mail_token = mail_token or os.environ.get("SIBERIAN_MAIL_TOKEN", "")

        self.auth = AuthClient(self.core, self._adapter.session_token)
        self.db = Database(self.core, self.database_token, self._adapter.domain, schema=schema)
        self.storage = Storage(self.core, self.storage_token, name, self._adapter.domain)

    @property
    def domain(self):
        """The domain this request is being served for."""
        return self._adapter.domain()

    def current_user(self, fresh=False):
        return self.auth.current_user(fresh=fresh)

    def granted_read(self, database, table):
        """A read of a table this module does not own.

        Table by table, against a grant an operator approved with a stated
        reason, and audited every time including the refusals. A module that
        wants this has already said so in its manifest; this is only the call.
        """
        payload = self.core.call(f"/database/v1/system/{database}/{table}", self.database_token)
        return payload.get("rows", [])

    def send_mail(self, to, subject, body, **extra):
        """Hand a message to the queue and stop thinking about it."""
        import json

        return self.core.call(
            "/mailer/v1/messages",
            self.mail_token,
            method="POST",
            body=json.dumps({"to": to, "subject": subject, "body": body, **extra}).encode(),
            content_type="application/json",
        )


class FlaskAdapter:
    """Where the domain and the session come from, when Flask is serving.

    Both are properties of the request rather than of the module: one container
    serves every domain and every visitor.
    """

    def __init__(self, flask_request):
        self._request = flask_request

    def domain(self):
        # The header the Router set, falling back to the host for the case
        # where something is being driven directly in development.
        return (self._request.headers.get("X-Siberian-Domain")
                or self._request.host.split(":")[0])

    def session_token(self):
        # Read, never interpreted. Only Auth can say what this means, which is
        # what stops a module treating a cookie as proof of anything.
        return self._request.cookies.get(SESSION_COOKIE)


def _flask_adapter():
    try:
        from flask import request
    except ImportError:
        return None

    return FlaskAdapter(request)
