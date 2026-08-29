"""Files, without the module carrying them.

The Storage service is a facade over an S3 compatible object store, and the
whole reason it is a facade is that a module should not need an S3 SDK, a
signature, or a credential. What a module does need is a way to hand a visitor
a file, and the obvious way is the expensive one: fetch it from Storage and
copy it out of the module's own process.

That is two extra copies of every byte and it puts a whole file in the module's
memory. There are two better ways and this offers both:

  * `public_url` for anything in the `public` space. A stable address on the
    product domain, served straight from the object store. No call at all.
  * `signed_url` for a private file. The module decides whether this visitor
    may have it, then sends them to the object store with a URL that reaches
    one object and expires.

`get` still exists, because a module that needs the bytes for itself, to resize
an image or read a manifest, genuinely needs the bytes.
"""

import json

from .errors import SiberianError

SPACES = ("files", "tmp", "public")


class Storage:
    def __init__(self, core, token, module_name, domain_source):
        self._core = core
        self._token = token
        self._module = module_name
        self._domain_source = domain_source

    def put(self, path, body, space="files", content_type=None):
        """Write a file. Returns what Storage recorded, including what is left
        of the quota, which is the number worth showing somebody."""
        self._check_space(space)
        data = body if isinstance(body, (bytes, bytearray)) else str(body).encode()

        return self._core.call(
            f"/storage/v1/{space}/{self._clean(path)}",
            self._token,
            method="PUT",
            body=data,
            content_type=content_type or "application/octet-stream",
        )

    def get(self, path, space="files"):
        """The bytes themselves.

        Prefer `signed_url` when the destination is a browser: this reads the
        whole object into the module.
        """
        self._check_space(space)
        return self._core.call(f"/storage/v1/{space}/{self._clean(path)}",
                               self._token, raw=True)

    def delete(self, path, space="files"):
        self._check_space(space)
        self._core.call(f"/storage/v1/{space}/{self._clean(path)}",
                        self._token, method="DELETE", raw=True)
        return True

    def list(self, space="files", prefix=None, limit=100, cursor=None):
        self._check_space(space)
        query = []
        if prefix:
            query.append(f"prefix={prefix}")
        if limit:
            query.append(f"limit={int(limit)}")
        if cursor:
            query.append(f"cursor={cursor}")
        suffix = f"?{'&'.join(query)}" if query else ""
        return self._core.call(f"/storage/v1/{space}{suffix}", self._token)

    def exists(self, path, space="files"):
        try:
            self._core.call(f"/storage/v1/{space}/{self._clean(path)}",
                            self._token, method="HEAD", raw=True)
            return True
        except SiberianError as error:
            if getattr(error, "status", None) == 404:
                return False
            raise

    def upload_url(self, path, content_length, space="files",
                   content_type=None, expires_in=None):
        """An address to write one object to, so the bytes skip this process.

        The other direction of `signed_url`. `put` sends the file through the
        Storage service; this hands back a URL the browser, or whatever holds
        the bytes, writes to directly.

        `content_length` is what the quota is checked against, and is declared
        rather than measured, which is exactly what the ordinary write already
        does: it checks the Content-Length the client chose. Call `confirm`
        afterwards so the accounting catches up with what actually arrived.

        Returns the whole reply, because the caller needs the headers as well as
        the URL: the content type is signed into the signature, so a PUT that
        sends a different one is refused.
        """
        self._check_space(space)
        payload = {"content_length": int(content_length)}
        if content_type:
            payload["content_type"] = content_type
        if expires_in:
            payload["expires_in"] = int(expires_in)

        return self._core.call(
            f"/storage/v1/uploads/{space}/{self._clean(path)}",
            self._token,
            method="POST",
            body=json.dumps(payload).encode(),
            content_type="application/json",
        )

    def confirm(self, path, space="files"):
        """Tell Storage the direct write landed, so the quota catches up.

        Skipping this does not lose the file. It leaves the counters behind
        until something recounts, which the Backoffice does on request. Calling
        it twice is harmless: it recounts rather than adds.
        """
        self._check_space(space)
        return self._core.call(
            f"/storage/v1/uploads/{space}/{self._clean(path)}/confirm",
            self._token,
            method="POST",
            body=b"{}",
            content_type="application/json",
        )

    def signed_url(self, path, space="files", expires_in=None):
        """An address a browser can follow, for one object, for a while.

        The module is the only thing that knows whether this visitor may have
        this file, so it decides that first and calls this second. Storage
        guarantees the narrower half: the URL is for this module's bucket on
        this domain, reaches exactly one object, and stops working.
        """
        self._check_space(space)
        query = f"?expires_in={int(expires_in)}" if expires_in else ""
        payload = self._core.call(
            f"/storage/v1/urls/{space}/{self._clean(path)}{query}", self._token
        )
        return payload["url"]

    def public_url(self, path, domain=None, scheme="https"):
        """The stable address of something in the `public` space.

        No round trip: the shape is fixed, and it is served by the Router
        straight from the object store. Anything in `public` is world readable
        by definition, so there is nothing here to authorise.

        Absolute, and on the product domain rather than on whatever host the
        module was addressed by, because the same URL has to work from three
        places that do not share an origin: framed in a browser the module
        answers on <module>.apps.<domain>, the phone app reaches it at
        /m/<module>/, and the preview runs on core.<domain>.
        """
        domain = domain or self._domain_source()
        return f"{scheme}://{domain}/-/public/{self._module}/{self._clean(path)}"

    @staticmethod
    def _clean(path):
        return str(path).lstrip("/")

    @staticmethod
    def _check_space(space):
        if space not in SPACES:
            raise ValueError(f"unknown space {space!r}, expected one of {', '.join(SPACES)}")
