"""What can go wrong, in three kinds a caller might treat differently."""


class SiberianError(RuntimeError):
    """Anything the core refused or could not answer."""

    def __init__(self, message, status=None, detail=None):
        super().__init__(message)
        self.status = status
        self.detail = detail


class NotFound(SiberianError):
    """The object, row, or route is not there.

    Separate from the rest because it is usually a normal outcome rather than a
    fault: a task with no attachment is not an error.
    """


class Refused(SiberianError):
    """The core said no, and will keep saying no.

    A quota that is full, a space the manifest never asked for, a token that
    was revoked. Retrying does not help, and the message is written to be shown
    to somebody who can act on it.
    """
