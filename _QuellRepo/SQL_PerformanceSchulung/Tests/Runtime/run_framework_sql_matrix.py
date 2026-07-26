#!/usr/bin/env python3
"""Runtime matrix for FWK-001 through FWK-012."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT / "Demos" / "00_Framework"
SUMMARY_PATTERN = re.compile(
    r"(?:^SQLPERF_SUMMARY|(?:^|\n)\s*\d+\|[^|\r\n]*\|SUMMARY)\|"
    r"(PASS|WARN|SKIP|FAIL)\|([A-Z][A-Z0-9_]*)",
    flags=re.MULTILINE,
)


class MatrixFailure(RuntimeError):
    pass


def _container_sqlcmd(container: str) -> str:
    result = subprocess.run(
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
    if result.returncode != 0:
        raise MatrixFailure("sqlcmd not found inside container")
    return result.stdout.strip()


def _run_sql(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
    sql_text: str,
    timeout_seconds: int = 120,
) -> str:
    command = [
        "docker",
        "exec",
        "-i",
        "-e",
        "SQLCMDPASSWORD",
        container,
        sqlcmd_path,
        "-S",
        "localhost",
        "-d",
        database,
        "-U",
        "sa",
        "-C",
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
    ]
    result = subprocess.run(
        command,
        input=sql_text,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout_seconds,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).strip()
        raise MatrixFailure(
            f"sqlcmd failed in database {database}: {diagnostic[-2000:]}"
        )
    return result.stdout


def _replace_declarations(text: str, replacements: dict[str, str]) -> str:
    for name, sql_value in replacements.items():
        pattern = re.compile(
            rf"(?m)^(DECLARE\s+@{re.escape(name)}\s+[^=;\r\n]+?=\s*)"
            rf"([^;\r\n]+)(;[^\r\n]*)$"
        )
        text, count = pattern.subn(rf"\g<1>{sql_value}\g<3>", text, count=1)
        if count != 1:
            raise MatrixFailure(f"could not replace DECLARE @{name}")
    return text


def _summary(output: str) -> tuple[str, str] | None:
    matches = SUMMARY_PATTERN.findall(output)
    return matches[-1] if matches else None


def _require_summary(
    output: str, allowed: Iterable[str] = ("PASS", "WARN")
) -> tuple[str, str]:
    parsed = _summary(output)
    if parsed is None:
        raise MatrixFailure("structured SQLPERF summary missing")
    if parsed[0] not in set(allowed):
        raise MatrixFailure(f"unexpected SQLPERF summary: {parsed[0]}/{parsed[1]}")
    return parsed


def _lifecycle_sql(
    *,
    action: str,
    demo_id: str,
    run_token: str,
    compatibility_level: int,
    confirm_drop: bool = False,
) -> str:
    text = (FRAMEWORK / "Sql" / "FWK_TestDatabaseLifecycle.sql").read_text(
        encoding="utf-8"
    )
    return _replace_declarations(
        text,
        {
            "Action": f"'{action}'",
            "DemoId": f"'{demo_id}'",
            "RunToken": f"'{run_token}'",
            "RequestedCompatibilityLevel": str(compatibility_level),
            "ConfirmLabUse": "1" if action in {"CREATE", "DROP"} else "0",
            "ConfirmDrop": "1" if confirm_drop else "0",
            "EmitEnvironmentDetails": "0",
        },
    )


def _create_database(
    *,
    container: str,
    sqlcmd_path: str,
    demo_id: str,
    run_token: str,
    compatibility_level: int,
) -> str:
    output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database="master",
        sql_text=_lifecycle_sql(
            action="CREATE",
            demo_id=demo_id,
            run_token=run_token,
            compatibility_level=compatibility_level,
        ),
        timeout_seconds=180,
    )
    _require_summary(output)
    return f"SQLPERF_LAB_{demo_id.replace('-', '')}_{run_token}"


def _drop_database(
    *,
    container: str,
    sqlcmd_path: str,
    demo_id: str,
    run_token: str,
    compatibility_level: int,
) -> None:
    output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database="master",
        sql_text=_lifecycle_sql(
            action="DROP",
            demo_id=demo_id,
            run_token=run_token,
            compatibility_level=compatibility_level,
            confirm_drop=True,
        ),
        timeout_seconds=180,
    )
    _require_summary(output)


def _patch_action_script(
    relative_path: str,
    replacements: dict[str, str],
) -> str:
    text = (FRAMEWORK / relative_path).read_text(encoding="utf-8")
    return _replace_declarations(text, replacements)


def _verify_engine(
    *,
    container: str,
    sqlcmd_path: str,
    expected_major: int,
) -> None:
    output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database="master",
        sql_text=(
            "SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), "
            "CONVERT(int, SERVERPROPERTY('EngineEdition'));"
        ),
    )
    if not re.search(rf"(?m)^{expected_major}\|[234]\s*$", output):
        raise MatrixFailure(
            f"engine identity mismatch; expected major {expected_major}"
        )


def _test_qry_database(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
    expected_major: int,
    compatibility_level: int,
) -> None:
    preflight = (FRAMEWORK / "Templates" / "00_Preflight.sql").read_text(
        encoding="utf-8"
    )
    preflight = _replace_declarations(
        preflight,
        {
            "MinimumMajorVersion": str(expected_major),
            "MaximumMajorVersion": str(expected_major),
            "MinimumCompatibilityLevel": str(compatibility_level),
            "MaximumCompatibilityLevel": str(compatibility_level),
            "TargetDatabase": f"N'{database}'",
            "RequireViewServerState": "1",
            "RequireViewServerPerformanceState": (
                "1" if expected_major >= 16 else "0"
            ),
        },
    )
    _require_summary(
        _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database="master",
            sql_text=preflight,
        )
    )

    generator = (FRAMEWORK / "Sql" / "FWK_SyntheticDataGenerator.sql").read_text(
        encoding="utf-8"
    )
    _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=generator,
        timeout_seconds=180,
    )

    generate_batch = """
EXEC lab.USP_GenerateSyntheticData
    @DemoId = 'QRY-001',
    @RunToken = 'LOCAL',
    @RowCount = 10000,
    @Seed = 42,
    @DistinctKeys = 100,
    @SkewPercent = 80,
    @HotKeyPercent = 20,
    @CorrelationPercent = 80,
    @PayloadBytes = 80,
    @StartDate = '20200101',
    @DateSpanDays = 365,
    @ResetExistingData = 1;
SELECT TOP (1)
    ActualRows,
    DataFingerprint
FROM lab.SyntheticGeneratorManifest
ORDER BY ManifestId DESC;
"""
    first = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=generate_batch,
        timeout_seconds=180,
    )
    second = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=generate_batch,
        timeout_seconds=180,
    )
    fingerprint_pattern = re.compile(r"(?m)^10000\|(-?\d+)\s*$")
    first_match = fingerprint_pattern.search(first)
    second_match = fingerprint_pattern.search(second)
    if not first_match or not second_match:
        raise MatrixFailure("generator fingerprint output missing")
    if first_match.group(1) != second_match.group(1):
        raise MatrixFailure("deterministic generator fingerprint changed")

    measurement = (FRAMEWORK / "Sql" / "FWK_Measurement.sql").read_text(
        encoding="utf-8"
    )
    _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=measurement,
        timeout_seconds=180,
    )
    measurement_batch = """
DECLARE @MeasurementRunId uniqueidentifier;
DECLARE @Rows bigint;
EXEC lab.USP_BeginMeasurement
    @DemoId = 'QRY-001',
    @RunToken = 'LOCAL',
    @Phase = 'BASELINE',
    @Iteration = 1,
    @CaptureSessionWaits = 1,
    @MeasurementRunId = @MeasurementRunId OUTPUT;
SELECT @Rows = COUNT_BIG(*) FROM lab.SyntheticFact WHERE SkewKey = 1;
EXEC lab.USP_EndMeasurement
    @DemoId = 'QRY-001',
    @RunToken = 'LOCAL',
    @MeasurementRunId = @MeasurementRunId,
    @ResultRows = @Rows;
IF NOT EXISTS
(
    SELECT 1
    FROM lab.MeasurementRun
    WHERE MeasurementRunId = @MeasurementRunId
      AND EndedAtUtc IS NOT NULL
      AND ElapsedMs >= 0
      AND CpuMs >= 0
      AND LogicalReads >= 0
      AND Writes >= 0
)
    THROW 51002, 'FAIL_STATE: Measurement runtime assertion failed.', 1;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
"""
    _require_summary(
        _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database=database,
            sql_text=measurement_batch,
        )
    )

    evidence = (
        FRAMEWORK / "Templates" / "40_Plan_Statistics_Evidence.sql"
    ).read_text(encoding="utf-8")
    evidence = _replace_declarations(evidence, {"EmitActualPlan": "1"})
    evidence_output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=evidence,
        timeout_seconds=180,
    )
    if (
        "STATISTICS_METADATA" not in evidence_output
        or "ACTUAL_PLAN" not in evidence_output
    ):
        raise MatrixFailure("plan/statistics evidence output incomplete")


def _test_orchestration(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
    proxy_path: Path,
) -> None:
    install = _patch_action_script(
        "Sql/FWK_MultiSessionControl.sql",
        {"Action": "'INSTALL'", "DemoId": "'CON-004'", "RunToken": "'LOCAL'"},
    )
    _require_summary(
        _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database=database,
            sql_text=install,
        )
    )

    environment = os.environ.copy()
    environment["SQLPERF_SQL_CONTAINER"] = container
    command = [
        sys.executable,
        str(FRAMEWORK / "Tools" / "orchestrate_sessions.py"),
        str(FRAMEWORK / "Examples" / "FWK-006" / "manifest.json"),
        "--server",
        "container-proxy",
        "--database",
        database,
        "--auth",
        "sql",
        "--username",
        "sa",
        "--sqlcmd",
        str(proxy_path),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=90,
        env=environment,
    )
    if result.returncode != 0 or "SQLPERF_SUMMARY|PASS|OK" not in result.stdout:
        raise MatrixFailure(
            "FWK-006 real SQL orchestration failed: "
            f"{(result.stderr or result.stdout)[-2000:]}"
        )


def _test_query_store(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
) -> None:
    status = _patch_action_script(
        "Sql/FWK_QueryStoreLifecycle.sql",
        {"Action": "'STATUS'", "DemoId": "'DGN-003'", "RunToken": "'LOCAL'"},
    )
    status_output = _run_sql(
        container=container,
        sqlcmd_path=sqlcmd_path,
        database=database,
        sql_text=status,
    )
    if "QUERY_STORE_STATUS" not in status_output:
        raise MatrixFailure("Query Store STATUS output missing")

    enable = _patch_action_script(
        "Sql/FWK_QueryStoreLifecycle.sql",
        {"Action": "'ENABLE'", "DemoId": "'DGN-003'", "RunToken": "'LOCAL'"},
    )
    _require_summary(
        _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database=database,
            sql_text=enable,
            timeout_seconds=180,
        )
    )

    restore = _patch_action_script(
        "Sql/FWK_QueryStoreLifecycle.sql",
        {
            "Action": "'RESTORE'",
            "DemoId": "'DGN-003'",
            "RunToken": "'LOCAL'",
            "ConfirmRestore": "1",
        },
    )
    _require_summary(
        _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database=database,
            sql_text=restore,
            timeout_seconds=180,
        )
    )


def _test_extended_events(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
) -> None:
    for action, extra in (
        ("STATUS", {}),
        ("CREATE", {"ConfirmLabUse": "1"}),
        ("START", {"ConfirmLabUse": "1"}),
        ("STATUS", {}),
        ("STOP", {"ConfirmLabUse": "1"}),
        ("DROP", {"ConfirmLabUse": "1", "ConfirmDrop": "1"}),
    ):
        replacements = {
            "Action": f"'{action}'",
            "DemoId": "'DGN-005'",
            "RunToken": "'LOCAL'",
            **extra,
        }
        sql_text = _patch_action_script(
            "Sql/FWK_ExtendedEventsLifecycle.sql",
            replacements,
        )
        output = _run_sql(
            container=container,
            sqlcmd_path=sqlcmd_path,
            database=database,
            sql_text=sql_text,
            timeout_seconds=180,
        )
        if action == "STATUS":
            if "XE_STATUS" not in output:
                raise MatrixFailure("Extended Events STATUS output missing")
        else:
            _require_summary(output)


def _test_runtime_harness(
    *,
    container: str,
    proxy_path: Path,
) -> None:
    environment = os.environ.copy()
    environment["SQLPERF_SQL_CONTAINER"] = container
    command = [
        sys.executable,
        str(FRAMEWORK / "Tools" / "run_demo.py"),
        str(FRAMEWORK / "Examples" / "FWK-010" / "manifest.json"),
        "--server",
        "container-proxy",
        "--auth",
        "sql",
        "--username",
        "sa",
        "--sqlcmd",
        str(proxy_path),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=90,
        env=environment,
    )
    if result.returncode != 0 or "SQLPERF_SUMMARY|PASS|OK" not in result.stdout:
        raise MatrixFailure(
            "FWK-010 real SQL harness failed: "
            f"{(result.stderr or result.stdout)[-2000:]}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", required=True)
    parser.add_argument("--expected-major", required=True, type=int)
    parser.add_argument("--compatibility-level", required=True, type=int)
    args = parser.parse_args()

    if args.expected_major not in {15, 16, 17}:
        print("matrix: FAIL - unsupported expected major", file=sys.stderr)
        return 1
    if args.compatibility_level != args.expected_major * 10:
        print("matrix: FAIL - major/compatibility mismatch", file=sys.stderr)
        return 1
    if not os.environ.get("SQLCMDPASSWORD"):
        print("matrix: FAIL - SQLCMDPASSWORD missing", file=sys.stderr)
        return 1

    sqlcmd_path = _container_sqlcmd(args.container)
    proxy_path = (
        ROOT / "Tests" / "Runtime" / "docker_sqlcmd_proxy.py"
    ).resolve()
    databases: list[tuple[str, str, str]] = []
    exit_code = 0

    try:
        _verify_engine(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            expected_major=args.expected_major,
        )

        for demo_id in ("QRY-001", "CON-004", "DGN-003", "DGN-005"):
            database = _create_database(
                container=args.container,
                sqlcmd_path=sqlcmd_path,
                demo_id=demo_id,
                run_token="LOCAL",
                compatibility_level=args.compatibility_level,
            )
            databases.append((demo_id, "LOCAL", database))

        database_by_demo = {
            demo_id: database for demo_id, _, database in databases
        }
        _test_qry_database(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["QRY-001"],
            expected_major=args.expected_major,
            compatibility_level=args.compatibility_level,
        )
        _test_orchestration(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["CON-004"],
            proxy_path=proxy_path,
        )
        _test_query_store(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["DGN-003"],
        )
        _test_extended_events(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["DGN-005"],
        )
        _test_runtime_harness(
            container=args.container,
            proxy_path=proxy_path,
        )

        print(
            f"SQLPERF_MATRIX_SUMMARY|PASS|SQL{args.expected_major}|"
            f"CL{args.compatibility_level}"
        )
    except (MatrixFailure, subprocess.TimeoutExpired) as exc:
        exit_code = 1
        print(
            f"SQLPERF_MATRIX_SUMMARY|FAIL|SQL{args.expected_major}|"
            f"CL{args.compatibility_level}",
            file=sys.stderr,
        )
        print(str(exc), file=sys.stderr)
    finally:
        cleanup_errors: list[str] = []
        for demo_id, run_token, _ in reversed(databases):
            try:
                _drop_database(
                    container=args.container,
                    sqlcmd_path=sqlcmd_path,
                    demo_id=demo_id,
                    run_token=run_token,
                    compatibility_level=args.compatibility_level,
                )
            except Exception as exc:
                cleanup_errors.append(f"{demo_id}/{run_token}: {exc}")
        if cleanup_errors:
            exit_code = 1
            print("matrix cleanup findings:", file=sys.stderr)
            for error in cleanup_errors:
                print(f"- {error}", file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
