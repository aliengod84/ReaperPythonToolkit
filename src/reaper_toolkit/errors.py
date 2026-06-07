from __future__ import annotations

from typing import Any


class ReaperToolkitError(Exception):
    """Base class for toolkit errors."""


class ConnectionError(ReaperToolkitError):
    pass


class HandshakeError(ConnectionError):
    pass


class IncompatibleHostError(HandshakeError):
    pass


class MissingCapabilityError(HandshakeError):
    pass


class CommandTimeoutError(ReaperToolkitError):
    pass


class ConnectionLostError(ConnectionError):
    pass


class CommandError(ReaperToolkitError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        retryable: bool = False,
        request_id: str | None = None,
        method: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.request_id = request_id
        self.method = method
        self.details = details or {}


class InvalidRequestError(CommandError):
    pass


class ResourceNotFoundError(CommandError):
    pass


class ResourceBusyError(CommandError):
    pass


class OwnershipError(CommandError):
    pass


class ReaperOperationError(CommandError):
    pass


ERROR_TYPES: dict[str, type[CommandError]] = {
    "invalid_request": InvalidRequestError,
    "invalid_params": InvalidRequestError,
    "resource_not_found": ResourceNotFoundError,
    "resource_busy": ResourceBusyError,
    "ownership_error": OwnershipError,
    "reaper_operation_failed": ReaperOperationError,
}


def command_error(payload: dict[str, Any], request_id: str, method: str) -> CommandError:
    code = str(payload.get("code", "reaper_operation_failed"))
    cls = ERROR_TYPES.get(code, CommandError)
    return cls(
        code,
        str(payload.get("message", code)),
        retryable=bool(payload.get("retryable", False)),
        request_id=request_id,
        method=method,
        details=dict(payload.get("details") or {}),
    )

