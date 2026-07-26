#!/usr/bin/env python3
"""Run every Gate-B pilot twice against one ephemeral SQL Server container."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "Tests" / "Runtime"
FRAMEWORK_TOOLS = ROOT / "Demos" / "00_Framework" / "Tools"

sys.path.insert(0, str(RUNTIME))
from run_framework_sql_matrix import (  # noqa: E402
    _container_sqlcmd,
    _run_sql,
    _verify_engine,
)

PILOTS = (
    (
        "QRY-001",
        ROOT / "Demos" / "05_Query_Patterns" / "QRY-001_SARGability" / "manifest.json",
        False,
    ),
    (
        "OPT-002",
        ROOT / "Demos" / "04_Optimizer_Statistics_Plans" / "OPT-002_Statistics_Anatomy" / "manifest.json",
        False,
    ),
    (
        "CON-004",
        ROOT / "Demos" / "07_Concurrency" / "CON-004_Blocking_Chain" / "manifest.json",
        True,
    ),
    (
        "OPT-013",
        ROOT / "Demos" / "04_Optimizer_Statistics_Plans" / "OPT-013_Controlled_Spill" / "manifest.json",
        True,
    ),
)

SUMMARY = re.compile(r"^SQLPERF_SUMMARY\|(PASS|WARN|SKIP|FAIL)\|([A-Z][A-Z0-9_]*)$", re.MULTILINE)


class GateBFailure(RuntimeError):
    pass


def target_database(demo_id: str) -> str:
    return f"SQLPERF_LAB_{demo_id.replace('-', '')}_LOCAL"


def assert_database_absent(container: str, sqlcmd_path: str, demo_id: str) -> None:
    database = target_database(demo_id)
    output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database="master",
        sql_text=(
            f"IF DB_ID(N'{database}') IS NOT NULL "
            "THROW 51004, 'FAIL_CLEANUP: Gate-B-Testdatenbank ist nach dem Harness-Lauf noch vorhanden.', 1; "
            "SELECT N'ABSENT';"
        ),
        timeout_seconds=30,
    )
    if "ABSENT" not in output:
        raise GateBFailure(f"{demo_id}: cleanup verification did not return ABSENT")


def run_pilot(
    *,
    demo_id: str,
    manifest: Path,
    yellow: bool,
    container: str,
    proxy: Path,
    sqlcmd_path: str,
    repetition: int,
) -> None:
    if not manifest.is_file():
        raise GateBFailure(f"{demo_id}: manifest missing")

    command = [
        sys.executable,
        str(FRAMEWORK_TOOLS / "run_demo.py"),
        str(manifest),
        "--server",
        "localhost",
        "--auth",
        "sql",
        "--username",
        "sa",
        "--sqlcmd",
        str(proxy),
    ]
    if yellow:
        command.append("--confirm-isolated-lab")

    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=os.environ.copy(),
        timeout=900,
    )
    combined = "\n".join(part for part in (result.stdout, result.stderr) if part)
    summaries = SUMMARY.findall(combined)
    final_summary = summaries[-1] if summaries else None

    if result.returncode != 0 or final_summary != ("PASS", "OK"):
        diagnostic = combined[-6000:].replace(os.environ.get("SQLCMDPASSWORD", ""), "***")
        raise GateBFailure(
            f"{demo_id} repetition {repetition}: harness failed; "
            f"returncode={result.returncode}; summary={final_summary}; diagnostic={diagnostic}"
        )

    assert_database_absent(container, sqlcmd_path, demo_id)
    print(f"GATE_B_STAGE|{demo_id}|RUN_{repetition}|PASS|OK")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all Gate-B pilots twice.")
    parser.add_argument("--container", required=True)
    parser.add_argument("--expected-major", required=True, type=int)
    args = parser.parse_args()

    proxy = RUNTIME / "docker_sqlcmd_proxy.py"
    if not proxy.is_file():
        print("GATE_B_SUMMARY|FAIL|FAIL_CONTRACT|docker sqlcmd proxy missing")
        return 1

    try:
        sqlcmd_path = _container_sqlcmd(args.container)
        _verify_engine(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            expected_major=args.expected_major,
        )
        print(f"GATE_B_STAGE|ENGINE_{args.expected_major}|IDENTITY|PASS|OK")

        for demo_id, manifest, yellow in PILOTS:
            for repetition in (1, 2):
                run_pilot(
                    demo_id=demo_id,
                    manifest=manifest,
                    yellow=yellow,
                    container=args.container,
                    proxy=proxy,
                    sqlcmd_path=sqlcmd_path,
                    repetition=repetition,
                )

        print(f"GATE_B_SUMMARY|PASS|OK|major={args.expected_major}; pilots=4; repetitions=2")
        return 0
    except (GateBFailure, OSError, subprocess.TimeoutExpired, ValueError) as exc:
        message = str(exc).replace(os.environ.get("SQLCMDPASSWORD", ""), "***")
        print(f"GATE_B_SUMMARY|FAIL|FAIL_EXECUTION|major={args.expected_major}; {message}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
