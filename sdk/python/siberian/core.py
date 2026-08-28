"""The call convention: one place that knows how a module addresses the core.

Every module was writing this function. It is nine lines and they were the same
nine lines, which is fine until one of them needs to change and there are
eleven copies.
"""

import json
import urllib.error
import urllib.request

from .errors import NotFound, Refused, SiberianError

# The Router answers to this name on every module network. A module has no
# route to a core service directly and never learns a container name, so this
# is not a default to be overridden lightly.
DEFAULT_CORE_URL = "http://core"


class CoreClient:
    """Talks to the core over HTTP, with the domain attached to every call."""

    def __init__(self, base_url, domain_source):
        self._base = base_url.rstrip("/")
        # A callable rather than a value: the domain is a property of the
        # request being served, and a module container serves every domain.
        self._domain_source = domain_source

    def call(self, path, token=None, method="GET", body=None,
             content_type=None, raw=False, timeout=10, headers=None):
        request = urllib.request.Request(f"{self._base}{path}", method=method, data=body)

        if token:
            request.add_header("Authorization", f"Bearer {token}")

        # The domain travels with every request. The Router set it on the way
        # in, and the core needs it on the way out to resolve per-domain data:
        # containers are shared across domains and only the data is not.
        domain = self._domain_source()
        if domain:
            request.add_header("X-Siberian-Domain", domain)

        if content_type:
            request.add_header("Content-Type", content_type)

        for key, value in (headers or {}).items():
            request.add_header(key, value)

        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                return payload if raw else json.loads(payload or b"{}")
        except urllib.error.HTTPError as error:
            raise self._translate(error, method, path) from error
        except urllib.error.URLError as error:
            raise SiberianError(f"{method} {path}: the core is unreachable: {error.reason}") from error

    @staticmethod
    def _translate(error, method, path):
        detail = error.read().decode("utf-8", "replace")[:500]

        # The core answers in JSON and puts something readable in "error". A
        # module showing a person what went wrong should show that, not a
        # status code.
        message = detail
        try:
            parsed = json.loads(detail or "{}")
            message = parsed.get("error") or detail
        except ValueError:
            pass

        if error.code == 404:
            return NotFound(message, status=404, detail=detail)

        # 507 is a full quota, 403 a space that was never granted, 401 a token
        # that is gone. None of them improve on a retry, and each of them has a
        # person who can fix it.
        if error.code in (401, 402, 403, 409, 413, 507):
            return Refused(message, status=error.code, detail=detail)

        return SiberianError(f"{method} {path} -> {error.code}: {message}",
                             status=error.code, detail=detail)
