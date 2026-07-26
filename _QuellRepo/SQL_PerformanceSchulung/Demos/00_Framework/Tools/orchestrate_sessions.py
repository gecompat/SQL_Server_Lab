#!/usr/bin/env python3
"""FWK-006 multi-session process orchestrator.

Database-side ordering is implemented by FWK_MultiSessionControl.sql. This
process starts independent sqlcmd sessions, applies launch delays, enforces one
global timeout, and terminates remaining sessions after the first failure.
Raw sqlcmd output is shown only with --show-output and is never written to disk.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any

from sqlcmd_process import build_sqlcmd_command, collect_process, resolve_sqlcmd, start_sqlcmd

SESSION_ID_PATTERN = re.compile(r"[A-Z][A-Z0-9_]{0,31}")
DEMO_ID_PATTERN = re.compile(r"(STL|OPT|QRY|IDX|CON|RES|DGN)-[0-9]{3}")
RUN_TOKEN_PATTERN = re.compile(r"[A-Z0-9][A-Z0-9_]{0,19}")


@dataclass(frozen=True)
class SessionSpec:
    session_id: str
    script: Path
    launch_delay_ms: int


@dataclass(frozen=True)
class OrchestrationResult:
    outcome: str
    code: str
    message: str
    session_returncodes: dict[str, int]
    timed_out_sessions: tuple[str, ...]

    @property
    def exit_code(self) -> int:
        if self.outcome in {"PASS", "WARN", "SKIP"}:
            return 0
        return 3 if self.code == "FAIL_TIMEOUT" else 2


def _load_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid manifest: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("manifest root must be a JSON object")
    return value


def _resolve_relative_sql(base: Path, value: str) -> Path:
    candidate = (base / value).resolve()
    try:
        candidate.relative_to(base.resolve())
    except ValueError as exc:
        raise ValueError("session script escapes the manifest directory") from exc
    if not candidate.is_file() or candidate.suffix.lower() != ".sql":
        raise ValueError(f"session script missing or not .sql: {value}")
    return candidate


def load_manifest(path: Path) -> tuple[str, str, int, bool, list[SessionSpec]]:
    payload = _load_json_object(path)
    if payload.get("contract_version") != "1.0":
        raise ValueError("contract_version must be 1.0")

    demo_id = payload.get("demo_id")
    run_token = payload.get("run_token")
    timeout_seconds = payload.get("timeout_seconds")
    abort_on_first_failure = payload.get("abort_on_first_failure", True)
    raw_sessions = payload.get("sessions")

    if not isinstance(demo_id, str) or not DEMO_ID_PATTERN.fullmatch(demo_id):
        raise ValueError("invalid demo_id")
    if not isinstance(run_token, str) or not RUN_TOKEN_PATTERN.fullmatch(run_token):
        raise ValueError("invalid run_token")
    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 3600:
        raise ValueError("timeout_seconds must be an integer from 1 through 3600")
    if not isinstance(abort_on_first_failure, bool):
        raise ValueError("abort_on_first_failure must be boolean")
    if not isinstance(raw_sessions, list) or not 1 <= len(raw_sessions) <= 32:
        raise ValueError("sessions must contain 1 through 32 entries")

    seen: set[str] = set()
    sessions: list[SessionSpec] = []
    for raw in raw_sessions:
        if not isinstance(raw, dict):
            raise ValueError("each session must be an object")
        session_id = raw.get("id")
        script = raw.get("script")
        delay = raw.get("launch_delay_ms", 0)
        if not isinstance(session_id, str) or not SESSION_ID_PATTERN.fullmatch(session_id):
            raise ValueError(f"invalid session id: {session_id!r}")
        if session_id in seen:
            raise ValueError(f"duplicate session id: {session_id}")
        if not isinstance(script, str):
            raise ValueError(f"session {session_id} requires a script")
        if not isinstance(delay, int) or not 0 <= delay <= 60000:
            raise ValueError(f"session {session_id} launch_delay_ms must be 0 through 60000")
        seen.add(session_id)
        sessions.append(SessionSpec(session_id, _resolve_relative_sql(path.parent, script), delay))

    sessions.sort(key=lambda item: (item.launch_delay_ms, item.session_id))
    return demo_id, run_token, timeout_seconds, abort_on_first_failure, sessions


def run_manifest(
    *,
    manifest_path: Path,
    server: str,
    database: str,
    auth: str,
    username: str | None,
    sqlcmd_path: str | None,
    show_output: bool,
    timeout_override_seconds: int | None = None,
) -> OrchestrationResult:
    demo_id, run_token, timeout_seconds, abort_on_first_failure, sessions = load_manifest(manifest_path.resolve())
    if timeout_override_seconds is not None:
        if timeout_override_seconds < 1:
            raise ValueError("timeout_override_seconds must be positive")
        timeout_seconds = min(timeout_seconds, timeout_override_seconds)

    executable = resolve_sqlcmd(sqlcmd_path)
    variables = {"DemoId": demo_id, "RunToken": run_token}
    started_at = time.monotonic()
    deadline = started_at + timeout_seconds
    pending = list(sessions)
    running: dict[str, tuple[Any, list[str]]] = {}
    completed: dict[str, tuple[int, str, str, bool]] = {}
    failure_detected = False
    global_timeout = False

    while pending or running:
        now = time.monotonic()
        while pending and now - started_at >= pending[0].launch_delay_ms / 1000:
            spec = pending.pop(0)
            command = build_sqlcmd_command(
                executable=executable,
                server=server,
                database=database,
                script=spec.script,
                auth=auth,
                username=username,
                variables=variables,
            )
            running[spec.session_id] = (start_sqlcmd(command, environment=os.environ), command)

        for session_id, (process, command) in list(running.items()):
            if process.poll() is None:
                continue
            result = collect_process(process, command, timeout_seconds=0.1)
            completed[session_id] = (result.returncode, result.stdout, result.stderr, False)
            del running[session_id]
            if result.returncode != 0:
                failure_detected = True

        if failure_detected and abort_on_first_failure:
            break
        if time.monotonic() >= deadline:
            global_timeout = True
            break
        time.sleep(0.05)

    if global_timeout:
        for session_id, (process, command) in list(running.items()):
            result = collect_process(process, command, timeout_seconds=0.01)
            completed[session_id] = (result.returncode, result.stdout, result.stderr, True)
            del running[session_id]
        for spec in pending:
            completed[spec.session_id] = (-1, "", "", True)
    elif failure_detected and abort_on_first_failure:
        for session_id, (process, command) in list(running.items()):
            result = collect_process(process, command, timeout_seconds=0.01)
            completed[session_id] = (result.returncode, result.stdout, result.stderr, False)
            del running[session_id]
        for spec in pending:
            completed[spec.session_id] = (-1, "", "", False)
    pending.clear()

    if show_output:
        for session_id in sorted(completed):
            _, stdout, stderr, _ = completed[session_id]
            for line in stdout.rstrip().splitlines() if stdout else ():
                print(f"[{session_id}:stdout] {line}")
            for line in stderr.rstrip().splitlines() if stderr else ():
                print(f"[{session_id}:stderr] {line}", file=sys.stderr)

    timeout_ids = tuple(sorted(key for key, value in completed.items() if value[3]))
    returncodes = {key: value[0] for key, value in sorted(completed.items())}
    if global_timeout:
        return OrchestrationResult("FAIL", "FAIL_TIMEOUT", "Die Multi-Session-Ausführung überschritt das Zeitbudget.", returncodes, timeout_ids)
    if any(returncode != 0 for returncode in returncodes.values()):
        return OrchestrationResult("FAIL", "FAIL_EXECUTION", "Mindestens eine Session ist fehlgeschlagen oder wurde nach Fail-fast beendet.", returncodes, ())
    return OrchestrationResult("PASS", "OK", "Alle Sessions wurden innerhalb des Zeitbudgets abgeschlossen.", returncodes, ())


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a FWK-006 session manifest.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--server", default=os.environ.get("SQLPERF_SQL_SERVER"))
    parser.add_argument("--database", default=os.environ.get("SQLPERF_SQL_DATABASE"))
    parser.add_argument("--auth", choices=("integrated", "sql", "aad"), default=os.environ.get("SQLPERF_SQL_AUTH", "integrated"))
    parser.add_argument("--username", default=os.environ.get("SQLPERF_SQL_USERNAME"))
    parser.add_argument("--sqlcmd", dest="sqlcmd_path")
    parser.add_argument("--show-output", action="store_true")
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    if not args.server or not args.database:
        print("SQLPERF_SUMMARY|FAIL|FAIL_CONTRACT\nserver and database are required by argument or environment", file=sys.stderr)
        return 1
    try:
        result = run_manifest(
            manifest_path=args.manifest,
            server=args.server,
            database=args.database,
            auth=args.auth,
            username=args.username,
            sqlcmd_path=args.sqlcmd_path,
            show_output=args.show_output,
        )
    except FileNotFoundError as exc:
        print(f"SQLPERF_SUMMARY|SKIP|SKIP_TOOL_MISSING\n{exc}")
        return 0
    except (OSError, ValueError) as exc:
        print(f"SQLPERF_SUMMARY|FAIL|FAIL_CONTRACT\n{exc}", file=sys.stderr)
        return 1

    print(f"SQLPERF_SUMMARY|{result.outcome}|{result.code}")
    print(result.message)
    for session_id, returncode in result.session_returncodes.items():
        print(f"{session_id}: returncode={returncode}")
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
