#!/usr/bin/env python3
"""FWK-010 runtime harness for one SQL Server performance demo.

The harness invokes the external Microsoft sqlcmd tool without a shell, parses
machine-readable SQLPERF summaries, enforces one global phase budget, and runs
cleanup after a started setup phase. It never writes captured SQL output to
disk. Raw output is shown only with --show-output.
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

from orchestrate_sessions import run_manifest as run_session_manifest
from sqlcmd_process import (
    build_sqlcmd_command,
    extract_summary,
    resolve_sqlcmd,
    run_sqlcmd,
)


DEMO_ID_PATTERN = re.compile(r"(STL|OPT|QRY|IDX|CON|RES|DGN)-[0-9]{3}")
RUN_TOKEN_PATTERN = re.compile(r"[A-Z0-9][A-Z0-9_]{0,19}")
PHASE_ID_PATTERN = re.compile(r"[A-Z][A-Z0-9_]{0,31}")
OUTCOME_PRIORITY = {"PASS": 0, "WARN": 1, "SKIP": 2, "FAIL": 3}


@dataclass(frozen=True)
class PhaseSpec:
    phase_id: str
    kind: str
    path: Path
    database_selector: str
    required: bool
    require_summary: bool
    timeout_seconds: int | None


@dataclass(frozen=True)
class DemoManifest:
    demo_id: str
    run_token: str
    safety_level: str
    timeout_seconds: int
    cleanup_timeout_seconds: int
    phases: tuple[PhaseSpec, ...]
    cleanup: PhaseSpec | None


@dataclass(frozen=True)
class PhaseResult:
    phase_id: str
    outcome: str
    code: str
    message: str
    duration_seconds: float


@dataclass(frozen=True)
class HarnessResult:
    outcome: str
    code: str
    message: str
    phases: tuple[PhaseResult, ...]

    @property
    def exit_code(self) -> int:
        if self.outcome in {"PASS", "WARN", "SKIP"}:
            return 0
        if self.code == "FAIL_TIMEOUT":
            return 3
        if self.code == "FAIL_CLEANUP":
            return 4
        return 2


def _load_json_object(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid demo manifest: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("demo manifest root must be a JSON object")
    return payload


def _resolve_local_path(base: Path, relative_value: str, suffixes: set[str]) -> Path:
    candidate = (base / relative_value).resolve()
    try:
        candidate.relative_to(base.resolve())
    except ValueError as exc:
        raise ValueError("manifest path escapes its directory") from exc
    if not candidate.is_file() or candidate.suffix.lower() not in suffixes:
        raise ValueError(f"manifest file missing or has invalid suffix: {relative_value}")
    return candidate


def _parse_phase(raw: Any, base: Path, *, cleanup: bool = False) -> PhaseSpec:
    if not isinstance(raw, dict):
        raise ValueError("each phase must be a JSON object")

    phase_id = raw.get("id")
    kind = raw.get("kind", "sql")
    path_value = raw.get("script" if kind == "sql" else "manifest")
    database_selector = raw.get("database", "target")
    required = raw.get("required", True)
    require_summary = raw.get("require_summary", phase_id == "PREFLIGHT")
    timeout_seconds = raw.get("timeout_seconds")

    if not isinstance(phase_id, str) or not PHASE_ID_PATTERN.fullmatch(phase_id):
        raise ValueError(f"invalid phase id: {phase_id!r}")
    if kind not in {"sql", "multi_session"}:
        raise ValueError(f"invalid phase kind for {phase_id}")
    if not isinstance(path_value, str):
        raise ValueError(f"phase {phase_id} requires a file path")
    if database_selector not in {"master", "target"}:
        raise ValueError(f"phase {phase_id} database must be master or target")
    if not isinstance(required, bool) or not isinstance(require_summary, bool):
        raise ValueError(f"phase {phase_id} required/require_summary must be boolean")
    if timeout_seconds is not None and (
        not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 3600
    ):
        raise ValueError(f"phase {phase_id} timeout_seconds must be 1 through 3600")
    if cleanup and kind != "sql":
        raise ValueError("cleanup must be a SQL phase")

    suffixes = {".sql"} if kind == "sql" else {".json"}
    return PhaseSpec(
        phase_id=phase_id,
        kind=kind,
        path=_resolve_local_path(base, path_value, suffixes),
        database_selector=database_selector,
        required=required,
        require_summary=require_summary,
        timeout_seconds=timeout_seconds,
    )


def load_manifest(path: Path) -> DemoManifest:
    payload = _load_json_object(path)
    if payload.get("contract_version") != "1.0":
        raise ValueError("contract_version must be 1.0")

    demo_id = payload.get("demo_id")
    run_token = payload.get("run_token")
    safety_level = payload.get("safety_level")
    timeout_seconds = payload.get("timeout_seconds")
    cleanup_timeout_seconds = payload.get("cleanup_timeout_seconds", 60)

    if not isinstance(demo_id, str) or not DEMO_ID_PATTERN.fullmatch(demo_id):
        raise ValueError("invalid demo_id")
    if not isinstance(run_token, str) or not RUN_TOKEN_PATTERN.fullmatch(run_token):
        raise ValueError("invalid run_token")
    if safety_level not in {"GREEN", "YELLOW", "RED"}:
        raise ValueError("safety_level must be GREEN, YELLOW, or RED")
    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 7200:
        raise ValueError("timeout_seconds must be 1 through 7200")
    if not isinstance(cleanup_timeout_seconds, int) or not 1 <= cleanup_timeout_seconds <= 900:
        raise ValueError("cleanup_timeout_seconds must be 1 through 900")

    raw_phases = payload.get("phases")
    if not isinstance(raw_phases, list) or not 1 <= len(raw_phases) <= 20:
        raise ValueError("phases must contain 1 through 20 entries")

    phases = tuple(_parse_phase(raw, path.parent) for raw in raw_phases)
    ids = [phase.phase_id for phase in phases]
    if len(ids) != len(set(ids)):
        raise ValueError("phase ids must be unique")
    if "PREFLIGHT" not in ids:
        raise ValueError("a PREFLIGHT phase is required")

    cleanup_raw = payload.get("cleanup")
    cleanup = _parse_phase(cleanup_raw, path.parent, cleanup=True) if cleanup_raw is not None else None

    return DemoManifest(
        demo_id=demo_id,
        run_token=run_token,
        safety_level=safety_level,
        timeout_seconds=timeout_seconds,
        cleanup_timeout_seconds=cleanup_timeout_seconds,
        phases=phases,
        cleanup=cleanup,
    )


def target_database_name(demo_id: str, run_token: str) -> str:
    return f"SQLPERF_LAB_{demo_id.replace('-', '')}_{run_token}"


def _combine_result(current: tuple[str, str], candidate: tuple[str, str]) -> tuple[str, str]:
    if OUTCOME_PRIORITY[candidate[0]] > OUTCOME_PRIORITY[current[0]]:
        return candidate
    return current


def _emit_raw_output(phase_id: str, stdout: str, stderr: str) -> None:
    if stdout:
        for line in stdout.rstrip().splitlines():
            print(f"[{phase_id}:stdout] {line}")
    if stderr:
        for line in stderr.rstrip().splitlines():
            print(f"[{phase_id}:stderr] {line}", file=sys.stderr)


def _execute_sql_phase(
    *,
    phase: PhaseSpec,
    executable: str,
    server: str,
    target_database: str,
    auth: str,
    username: str | None,
    timeout_seconds: float,
    variables: dict[str, str],
    show_output: bool,
) -> PhaseResult:
    database = "master" if phase.database_selector == "master" else target_database
    command = build_sqlcmd_command(
        executable=executable,
        server=server,
        database=database,
        script=phase.path,
        auth=auth,
        username=username,
        variables=variables,
    )
    started = time.monotonic()
    result = run_sqlcmd(command, timeout_seconds=timeout_seconds, environment=os.environ)
    if show_output:
        _emit_raw_output(phase.phase_id, result.stdout, result.stderr)

    if result.timed_out:
        return PhaseResult(phase.phase_id, "FAIL", "FAIL_TIMEOUT", "Die SQL-Phase überschritt ihr Zeitbudget.", time.monotonic() - started)
    if result.returncode != 0:
        return PhaseResult(phase.phase_id, "FAIL", "FAIL_EXECUTION", "sqlcmd meldete einen Fehler für diese Phase.", time.monotonic() - started)

    summary = extract_summary(result.stdout, result.stderr)
    if summary is None:
        if phase.require_summary:
            return PhaseResult(phase.phase_id, "FAIL", "FAIL_CONTRACT", "Die erforderliche SQLPERF-Summary fehlt.", time.monotonic() - started)
        return PhaseResult(phase.phase_id, "PASS", "OK", "Die Phase wurde ohne strukturierten Fehler abgeschlossen.", time.monotonic() - started)

    outcome, code = summary
    if outcome == "SKIP" and not phase.required:
        return PhaseResult(phase.phase_id, "WARN", "WARN_OPTIONAL_EVIDENCE_SKIPPED", f"Optionale Phase wurde kontrolliert übersprungen: {code}.", time.monotonic() - started)
    return PhaseResult(phase.phase_id, outcome, code, "Strukturierte Phase-Summary wurde ausgewertet.", time.monotonic() - started)


def run_demo(
    *,
    manifest_path: Path,
    server: str,
    auth: str,
    username: str | None,
    sqlcmd_path: str | None,
    confirm_isolated_lab: bool,
    allow_red: bool,
    show_output: bool,
) -> HarnessResult:
    manifest = load_manifest(manifest_path.resolve())

    if manifest.safety_level == "YELLOW" and not confirm_isolated_lab:
        return HarnessResult("FAIL", "FAIL_SAFETY", "Gelbe Demo benötigt --confirm-isolated-lab.", ())
    if manifest.safety_level == "RED" and not allow_red:
        return HarnessResult("FAIL", "FAIL_SAFETY", "Rote Demo benötigt --allow-red.", ())

    executable = resolve_sqlcmd(sqlcmd_path)
    target_database = target_database_name(manifest.demo_id, manifest.run_token)
    variables = {
        "DemoId": manifest.demo_id,
        "RunToken": manifest.run_token,
        "TargetDatabase": target_database,
        "SafetyLevel": manifest.safety_level,
        "ConfirmIsolatedLab": "1" if confirm_isolated_lab else "0",
        "HighImpactConfirmed": "1" if confirm_isolated_lab or allow_red else "0",
        "DisposableEnvironmentConfirmed": "1" if allow_red else "0",
        "RecoveryPlanConfirmed": "1" if allow_red else "0",
        "MaximumRuntimeSeconds": str(manifest.timeout_seconds),
    }

    deadline = time.monotonic() + manifest.timeout_seconds
    phase_results: list[PhaseResult] = []
    aggregate = ("PASS", "OK")
    setup_started = False
    stop_regular_phases = False

    for phase in manifest.phases:
        if stop_regular_phases:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            result = PhaseResult(phase.phase_id, "FAIL", "FAIL_TIMEOUT", "Das globale Harness-Zeitbudget ist abgelaufen.", 0.0)
        else:
            phase_timeout = min(remaining, phase.timeout_seconds or remaining)
            if phase.kind == "sql":
                if phase.phase_id == "SETUP":
                    setup_started = True
                result = _execute_sql_phase(
                    phase=phase,
                    executable=executable,
                    server=server,
                    target_database=target_database,
                    auth=auth,
                    username=username,
                    timeout_seconds=phase_timeout,
                    variables=variables,
                    show_output=show_output,
                )
            else:
                orchestration = run_session_manifest(
                    manifest_path=phase.path,
                    server=server,
                    database=target_database,
                    auth=auth,
                    username=username,
                    sqlcmd_path=executable,
                    show_output=show_output,
                    timeout_override_seconds=max(1, int(phase_timeout)),
                )
                result = PhaseResult(phase.phase_id, orchestration.outcome, orchestration.code, orchestration.message, 0.0)

        phase_results.append(result)
        aggregate = _combine_result(aggregate, (result.outcome, result.code))
        if result.outcome == "FAIL" or (result.outcome == "SKIP" and phase.required):
            stop_regular_phases = True

    if setup_started and manifest.cleanup is not None:
        cleanup = _execute_sql_phase(
            phase=manifest.cleanup,
            executable=executable,
            server=server,
            target_database=target_database,
            auth=auth,
            username=username,
            timeout_seconds=manifest.cleanup_timeout_seconds,
            variables=variables,
            show_output=show_output,
        )
        if cleanup.outcome != "PASS":
            cleanup = PhaseResult(cleanup.phase_id, "FAIL", "FAIL_CLEANUP", f"Cleanup nicht erfolgreich; ursprünglicher Code: {cleanup.code}.", cleanup.duration_seconds)
        phase_results.append(cleanup)
        aggregate = _combine_result(aggregate, (cleanup.outcome, cleanup.code))

    outcome, code = aggregate
    if outcome == "PASS":
        message = "Alle erforderlichen Phasen wurden erfolgreich abgeschlossen."
    elif outcome == "WARN":
        message = "Die Demo wurde abgeschlossen; mindestens eine optionale Evidenz war eingeschränkt."
    elif outcome == "SKIP":
        message = "Eine erforderliche Voraussetzung war nicht erfüllt; zustandsverändernde Folgephasen wurden nicht fortgesetzt."
    else:
        message = "Mindestens eine Phase oder das Cleanup ist fehlgeschlagen."
    return HarnessResult(outcome, code, message, tuple(phase_results))


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a FWK-010 demo manifest.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--server", default=os.environ.get("SQLPERF_SQL_SERVER"))
    parser.add_argument("--auth", choices=("integrated", "sql", "aad"), default=os.environ.get("SQLPERF_SQL_AUTH", "integrated"))
    parser.add_argument("--username", default=os.environ.get("SQLPERF_SQL_USERNAME"))
    parser.add_argument("--sqlcmd", dest="sqlcmd_path")
    parser.add_argument("--confirm-isolated-lab", action="store_true")
    parser.add_argument("--allow-red", action="store_true")
    parser.add_argument("--show-output", action="store_true")
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    if not args.server:
        print("SQLPERF_SUMMARY|FAIL|FAIL_CONTRACT\nserver is required by argument or SQLPERF_SQL_SERVER", file=sys.stderr)
        return 1

    try:
        result = run_demo(
            manifest_path=args.manifest,
            server=args.server,
            auth=args.auth,
            username=args.username,
            sqlcmd_path=args.sqlcmd_path,
            confirm_isolated_lab=args.confirm_isolated_lab,
            allow_red=args.allow_red,
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
    for phase in result.phases:
        print(f"{phase.phase_id}: {phase.outcome}/{phase.code} ({phase.duration_seconds:.3f}s) - {phase.message}")
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
