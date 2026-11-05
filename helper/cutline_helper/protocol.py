"""JSON-lines protocol between Cutline and the helper.

Cutline writes one request line to stdin:
    {"command": "ping", "args": {...}, "output_dir": "/path/for/job/files"}
The helper answers on stdout with any number of progress lines and then exactly one
result or error line:
    {"type": "progress", "fraction": 0.5, "message": "Separating vocals"}
    {"type": "result", "data": {...}}
    {"type": "error", "code": "unknown_command", "message": "..."}
Everything else the process prints (library logs, warnings) goes to stderr.
"""
import json
import os
import sys
from typing import IO, Any, Optional


class HelperError(Exception):
    """An error reported to Cutline with a stable code."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class Channel:
    """The protocol stream. Created before anything else so stray prints can't corrupt it."""

    def __init__(self, out: IO[str]):
        self._out = out

    @classmethod
    def take_stdout(cls) -> "Channel":
        # Keep a private copy of stdout for protocol lines, then send fd 1 (including
        # output from C extensions) to stderr.
        out = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1, encoding="utf-8")
        sys.stdout.flush()
        os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
        sys.stdout = sys.stderr
        return cls(out)

    def send(self, message: dict) -> None:
        self._out.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
        self._out.flush()

    def progress(self, fraction: float, message: Optional[str] = None) -> None:
        msg: dict[str, Any] = {"type": "progress", "fraction": max(0.0, min(1.0, float(fraction)))}
        if message:
            msg["message"] = message
        self.send(msg)

    def result(self, data: dict) -> None:
        self.send({"type": "result", "data": data})

    def error(self, code: str, message: str) -> None:
        self.send({"type": "error", "code": code, "message": message})


def parse_request(line: str) -> dict:
    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        raise HelperError("bad_request", f"request is not valid JSON: {e}") from None
    if not isinstance(req, dict) or not isinstance(req.get("command"), str):
        raise HelperError("bad_request", "request needs a string 'command'")
    args = req.get("args", {})
    if not isinstance(args, dict):
        raise HelperError("bad_request", "'args' must be an object")
    out = req.get("output_dir")
    if out is not None and not isinstance(out, str):
        raise HelperError("bad_request", "'output_dir' must be a string")
    return {"command": req["command"], "args": args, "output_dir": out}
