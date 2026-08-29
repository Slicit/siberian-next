"""The app's colours, for a module rendering inside it.

A module has two faces. The native one is drawn by the app and inherits its
palette for free. The web one is HTML the module renders itself, and inside a
WebView it is the one part of the app that would ignore the theme, which is
exactly where it shows: a dark app with a white page in the middle of it.

So the shell puts the palette in the query string and this turns it into CSS
variables. Modules already style with variables, so adopting it is one line in a
template rather than a redesign, and a module that does nothing still works.

    <style>{{ siberian.theme.css() }}</style>

Nothing here is trusted for anything but colour. The values land inside a
stylesheet, so they are filtered to things that cannot end one: a caller who
controls the query string controls the palette of a page they are already
looking at, and must not be able to control anything else on it.
"""

import re
from urllib.parse import parse_qs, urlencode

# What a colour may look like. Hex, rgb/rgba, hsl/hsla, or a plain CSS keyword.
#
# Deliberately narrow. A value that reaches a stylesheet unescaped can close the
# declaration and open another rule, so this is an allowlist of shapes rather
# than an attempt to remove the dangerous characters from an arbitrary string.
COLOUR = re.compile(
    r"""\A(
        \#[0-9a-fA-F]{3,8}
        | rgba?\(\s*[\d.\s,%/]+\)
        | hsla?\(\s*[\d.\s,%/deg]+\)
        | [a-zA-Z]{3,20}
    )\Z""",
    re.VERBOSE,
)

# The fields a theme carries, and what to fall back to when a page is opened
# outside the app. Someone visiting a module in a browser gets a sensible light
# palette rather than an unstyled page.
DEFAULTS = {
    "background": "#f7f8fa",
    "surface": "#ffffff",
    "text": "#111827",
    "muted": "#6b7280",
    "line": "#e5e7eb",
    "accent": "#2563eb",
    "onAccent": "#ffffff",
    "danger": "#b3261e",
    "dangerSurface": "#fee2e2",
}

SCHEMES = ("light", "dark")

# Where the palette is left for the rest of the module.
#
# Session scoped and set only on a request that carried one, so a module opened
# in an ordinary browser is never given a theme it then cannot get rid of.
COOKIE = "siberian_theme"


class Theme:
    """The palette for the current request."""

    def __init__(self, source):
        self._source = source
        self._cookie = None

    @property
    def key(self):
        """Which theme, by name. For a page that wants to say so."""
        asked = self._get("theme") or ""
        return asked if re.fullmatch(r"[a-z0-9_-]{1,32}", asked) else "default"

    @property
    def applied(self):
        """Whether an app asked for a palette at all.

        A module opened directly in a browser gets none, and must keep its
        own styling including its own dark mode. Overriding unconditionally
        would make every module render light for everybody, which is a
        regression dressed as a feature.
        """
        return bool(self._get("theme"))

    @property
    def scheme(self):
        """light or dark, so a page can set color-scheme and get native form
        controls that match rather than white boxes on a dark background."""
        asked = self._get("theme_scheme")
        return asked if asked in SCHEMES else "light"

    def colours(self):
        """Every field, from the request where valid and from the defaults
        otherwise. Never partially applied: a page with three of nine colours
        overridden looks worse than one with none."""
        return {
            field: self._colour(f"theme_{field}", fallback)
            for field, fallback in DEFAULTS.items()
        }

    def css(self, selector=":root"):
        """The palette as CSS custom properties, ready to drop into a style tag.

        Variable names are kebab-cased, which is the CSS convention and what a
        module's existing stylesheet already uses: `--bg` stays whatever the
        module called it, and these arrive as `--theme-accent`.
        """
        declarations = "".join(
            f"--theme-{_kebab(field)}:{value};" for field, value in self.colours().items()
        )
        return f"{selector}{{color-scheme:{self.scheme};{declarations}}}"

    def _get(self, name):
        asked = self._parameter(name)
        if asked:
            return asked

        # Not in the query string, so this is a page the app navigated to
        # rather than the one it opened. See COOKIE below.
        return self._remembered().get(name)

    def _parameter(self, name):
        try:
            return self._source.args.get(name)
        except Exception:
            # No request, or not a Flask one. The defaults are the answer.
            return None

    def _remembered(self):
        if self._cookie is None:
            try:
                raw = self._source.cookies.get(COOKIE) or ""
            except Exception:
                raw = ""
            # Every value is revalidated on the way out, so a hand-edited
            # cookie is exactly as harmless as a hand-edited query string.
            self._cookie = {key: values[0] for key, values in parse_qs(raw).items()}

        return self._cookie

    def remember(self, response, path=None):
        """Carry the palette to the rest of this module.

        The shell opens one URL with the palette on it. Every link, form and
        redirect after that is the module's own, and none of them can be
        expected to thread nine colours through by hand: the second page would
        render unstyled and going back would change the colours again, which is
        worse than never having themed it.

        So the first themed request leaves the palette behind, scoped to this
        module's own path, and lives only as long as the browser session. A
        module reached without a palette never sets one and never reads one,
        which is what keeps an ordinary browser visit unthemed.
        """
        if not self._asked_directly():
            return response

        remembered = urlencode({
            "theme": self.key,
            "theme_scheme": self.scheme,
            **{f"theme_{field}": value for field, value in self.colours().items()},
        })

        response.set_cookie(COOKIE, remembered, path=path or self._module_path(),
                            samesite="Lax", secure=True, httponly=False)
        return response

    def _module_path(self):
        """This module's own prefix, so one module's palette is not another's.

        The Router sets the module name on the way in and it is the one part of
        the external path a module can know: it never sees its own prefix,
        because the Router strips it before proxying.
        """
        try:
            name = self._source.headers.get("X-Siberian-Module")
        except Exception:
            name = None

        return f"/m/{name}" if name else "/"

    def _asked_directly(self):
        return bool(self._parameter("theme"))

    def _colour(self, name, fallback):
        value = self._get(name)
        if value and COLOUR.fullmatch(value.strip()):
            return value.strip()
        return fallback


def _kebab(field):
    return re.sub(r"(?<!^)(?=[A-Z])", "-", field).lower()


# How a module's own variable names map onto the theme's.
#
# The reference modules style with short names of their own choosing, which is
# the right thing for a module to do: it should not have to know what the app
# calls a colour. This maps one onto the other, so adopting the app's palette is
# a line in a template rather than a rename throughout a stylesheet.
#
# A module with different names passes its own mapping.
REFERENCE_VARIABLES = {
    "--bg": "background",
    "--fg": "text",
    "--muted": "muted",
    "--line": "line",
    "--accent": "accent",
    "--danger": "danger",
    "--surface": "surface",
}


def bridge(theme, variables=None, selector=":root"):
    """A stylesheet fragment that points a module's variables at the app's.

    Emitted only when an app actually asked for a theme, so a module opened
    directly in a browser keeps its own styling and its own dark mode.

    Placed after the module's own rules, because these are the same specificity
    and the later one wins. Anything the module defines and the theme does not
    is left alone rather than blanked.
    """
    if not theme.applied:
        return ""

    mapping = variables or REFERENCE_VARIABLES
    declarations = "".join(
        f"{name}:var(--theme-{_kebab(field)});" for name, field in mapping.items()
    )
    return f"{theme.css(selector)}{selector}{{{declarations}}}"
