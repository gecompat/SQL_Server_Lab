#!/usr/bin/env python3
"""Minimal sqlcmd-compatible proxy for the containerized SQL Server matrix.

The proxy accepts the argument vector emitted by Demos/00_Framework/Tools/
sqlcmd_process.py, reads the referenced host-side SQL file, and executes it
through sqlcmd inside the ephemeral SQL Server container. It never places the
SQL password on the command line.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


VALUE_FLAGS = {"-r", "-s", "-h", "-w", "-S", "-d", "-i", "-U"}
BOOLEAN_FLAGS = {"-b", "-W", "-E", "-G"}


def _parse_args(argv: list[str]) -> tuple[str, Path, str, list[str], list[str]]:
    database = "master"
    script: Path | None = None
    username: str | None = None
    variables: list[str] = []
    passthrough: list[str] = []
    index = 0

    while index < len(argv):
        arg = argv[index]
        if arg in BOOLEAN_FLAGS:
            passthrough.append(arg)
            index += 1
            continue
        if arg in VALUE_FLAGS:
            if index + 1 >= len(argv):
                raise ValueError(f"missing value for {arg}")
            value = argv[index + 1]
            if arg == "-d":
                database = value
            elif arg == "-i":
                script = Path(value).resolve()
            elif arg == "-U":
                username = value
            elif arg not in {"-S"}:
                passthrough.extend([arg, value])
            index += 2
            continue
        if arg == "-v":
            index += 1
            while index < len(argv) and not argv[index].startswith("-"):
                variables.append(argv[index])
                index += 1
            continue
        raise ValueError(f"unsupported sqlcmd argument: {arg}")

    if script is None or not script.is_file() or script.suffix.lower() != ".sql":
        raise ValueError("a readable .sql file is required through -i")
    if username is None:
        raise ValueError("the runtime matrix requires SQL authentication through -U")
    if any(ch in database for ch in "\r\n\x00") or not database:
        raise ValueError("invalid database")
    return database, script, username, variables, passthrough


def _sqlcmd_path(container: str) -> str:
    probe = subprocess.run(
        [
            "docker",
            "exec",
            container,
            "sh",
            "-lc",
            (
                "if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then "
                "printf /opt/mssql-tools18/bin/sqlcmd; "
                "elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then "
                "printf /opt/mssql-tools/bin/sqlcmd; "
                "else exit 127; fi"
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if probe.returncode != 0:
        raise FileNotFoundError("sqlcmd was not found inside the SQL Server container")
    return probe.stdout.strip()


def main() -> int:
    try:
        database, script, username, variables, passthrough = _parse_args(sys.argv[1:])
        container = os.environ.get("SQLPERF_SQL_CONTAINER")
        password = os.environ.get("SQLCMDPASSWORD")
        if not container:
            raise ValueError("SQLPERF_SQL_CONTAINER is required")
        if not password:
            raise ValueError("SQLCMDPASSWORD is required")

        command = [
            "docker",
            "exec",
            "-i",
            "-e",
            "SQLCMDPASSWORD",
            container,
            _sqlcmd_path(container),
            "-S",
            "localhost",
            "-d",
            database,
            "-U",
            username,
            "-C",
            *passthrough,
        ]
        if variables:
            command.extend(["-v", *variables])

        result = subprocess.run(
            command,
            input=script.read_text(encoding="utf-8"),
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=os.environ.copy(),
        )
        if result.stdout:
            sys.stdout.write(result.stdout)
        if result.stderr:
            sys.stderr.write(result.stderr)
        return result.returncode
    except (FileNotFoundError, OSError, ValueError) as exc:
        print(f"docker-sqlcmd-proxy: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
