#!/usr/bin/env python3
"""Shared process wrapper for the external Microsoft sqlcmd command-line tool.

The module never writes captured output to disk. Callers decide whether raw
interactive output may be shown. Passwords are accepted only through the
SQLCMDPASSWORD environment variable and are never placed on the command line.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
from typing import Mapping, Sequence


SUMMARY_PATTERN = re.compile(
    r"^SQLPERF_SUMMARY\|(PASS|WARN|SKIP|FAIL)\|([A-Z][A-Z0-9_]*)$",
    flags=re.MULTILINE,
)
RESULTSET_SUMMARY_PATTERN = re.compile(
    r"^\s*\d+\|[^|]*\|SUMMARY\|(PASS|WARN|SKIP|FAIL)\|([A-Z][A-Z0-9_]*)\|",
    flags=re.MULTILINE,
)


@dataclass(frozen=True)
class SqlcmdResult:
    command: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool
    duration_seconds: float

    @property
    def succeeded(self) -> bool:
        return self.returncode == 0 and not self.timed_out


def resolve_sqlcmd(explicit_path: str | None = None) -> str:
    """Resolve sqlcmd without invoking a shell."""

    if explicit_path:
        candidate = Path(explicit_path).expanduser()
        if not candidate.is_file():
            raise FileNotFoundError(f"sqlcmd executable not found: {candidate}")
        return str(candidate.resolve())

    discovered = shutil.which("sqlcmd")
    if discovered is None:
        raise FileNotFoundError("sqlcmd executable not found in PATH")
    return discovered


def _validate_connection_text(value: str, field_name: str) -> str:
    value = value.strip()
    if not value or any(ch in value for ch in "\r\n\x00"):
        raise ValueError(f"invalid {field_name}")
    return value


def build_sqlcmd_command(
    *,
    executable: str,
    server: str,
    database: str,
    script: Path,
    auth: str,
    username: str | None = None,
    variables: Mapping[str, str] | None = None,
) -> list[str]:
    """Build a sqlcmd command as an argument vector."""

    server = _validate_connection_text(server, "server")
    database = _validate_connection_text(database, "database")
    script = script.resolve()

    if not script.is_file() or script.suffix.lower() != ".sql":
        raise ValueError(f"SQL script does not exist or is not .sql: {script}")

    command = [
        executable,
        "-b",
        "-r",
        "1",
        "-W",
        "-s",
        "|",
        "-h",
        "-1",
        "-w",
        "65535",
        "-S",
        server,
        "-d",
        database,
        "-i",
        str(script),
    ]

    normalized_auth = auth.strip().lower()
    if normalized_auth == "integrated":
        command.append("-E")
    elif normalized_auth == "sql":
        if not username:
            raise ValueError("SQL authentication requires --username")
        if not os.environ.get("SQLCMDPASSWORD"):
            raise ValueError(
                "SQL authentication requires SQLCMDPASSWORD in the process environment"
            )
        command.extend(["-U", _validate_connection_text(username, "username")])
    elif normalized_auth == "aad":
        command.append("-G")
    else:
        raise ValueError("auth must be integrated, sql, or aad")

    if variables:
        normalized: list[str] = []
        for name, value in sorted(variables.items()):
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", name):
                raise ValueError(f"invalid sqlcmd variable name: {name}")
            if any(ch in value for ch in "\r\n\x00"):
                raise ValueError(f"invalid sqlcmd variable value for {name}")
            normalized.append(f"{name}={value}")
        if normalized:
            command.extend(["-v", *normalized])

    return command


def _terminate_process_tree(process: subprocess.Popen[str]) -> None:
    """Hard-stop sqlcmd and any descendants after timeout or fail-fast."""

    if process.poll() is not None:
        return

    try:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            process.kill()
        except (ProcessLookupError, PermissionError, OSError):
            pass

    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def start_sqlcmd(
    command: Sequence[str],
    *,
    environment: Mapping[str, str] | None = None,
) -> subprocess.Popen[str]:
    """Start sqlcmd in a separate process group."""

    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    return subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=dict(environment) if environment is not None else None,
        shell=False,
        start_new_session=(os.name != "nt"),
        creationflags=creationflags,
    )


def collect_process(
    process: subprocess.Popen[str],
    command: Sequence[str],
    *,
    timeout_seconds: float,
) -> SqlcmdResult:
    """Collect output and enforce a hard timeout."""

    started = time.monotonic()
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        _terminate_process_tree(process)
        stdout, stderr = process.communicate(timeout=5)

    return SqlcmdResult(
        command=tuple(command),
        returncode=process.returncode if process.returncode is not None else -1,
        stdout=stdout,
        stderr=stderr,
        timed_out=timed_out,
        duration_seconds=time.monotonic() - started,
    )


def run_sqlcmd(
    command: Sequence[str],
    *,
    timeout_seconds: float,
    environment: Mapping[str, str] | None = None,
) -> SqlcmdResult:
    process = start_sqlcmd(command, environment=environment)
    return collect_process(process, command, timeout_seconds=timeout_seconds)


def extract_summary(*texts: str) -> tuple[str, str] | None:
    """Return the last machine-readable summary marker."""

    matches: list[tuple[str, str]] = []
    for text in texts:
        matches.extend(SUMMARY_PATTERN.findall(text))
        matches.extend(RESULTSET_SUMMARY_PATTERN.findall(text))
    return matches[-1] if matches else None
