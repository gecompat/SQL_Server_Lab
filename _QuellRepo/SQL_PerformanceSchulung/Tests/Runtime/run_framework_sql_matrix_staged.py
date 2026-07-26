#!/usr/bin/env python3
"""Stage-reporting entry point for the SQL Server framework matrix."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

import run_framework_sql_matrix as matrix


def _run_sql_with_messages(
    *,
    container: str,
    sqlcmd_path: str,
    database: str,
    sql_text: str,
    timeout_seconds: int = 120,
) -> str:
    """Run sqlcmd and retain informational messages from stdout and stderr."""

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
    combined = "\n".join(
        part for part in (result.stdout, result.stderr) if part
    )
    if result.returncode != 0:
        raise matrix.MatrixFailure(
            f"sqlcmd failed in database {database}: {combined.strip()[-2000:]}"
        )
    return combined


# sqlcmd -r 1 can route PRINT and other informational messages to stderr.
# Matrix assertions therefore evaluate both captured streams while the process
# return code remains the authoritative execution-failure signal.
matrix._run_sql = _run_sql_with_messages


def _announce(stage: str) -> None:
    print(f"SQLPERF_MATRIX_STAGE|{stage}", flush=True)


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

    sqlcmd_path = matrix._container_sqlcmd(args.container)
    proxy_path = (
        matrix.ROOT / "Tests" / "Runtime" / "docker_sqlcmd_proxy.py"
    ).resolve()
    databases: list[tuple[str, str, str]] = []
    stage = "INITIALIZE"
    exit_code = 0

    try:
        stage = "ENGINE_IDENTITY"
        _announce(stage)
        matrix._verify_engine(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            expected_major=args.expected_major,
        )

        for demo_id in ("QRY-001", "CON-004", "DGN-003", "DGN-005"):
            stage = f"LIFECYCLE_CREATE_{demo_id.replace('-', '')}"
            _announce(stage)
            database = matrix._create_database(
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

        stage = "QRY_FRAMEWORK"
        _announce(stage)
        matrix._test_qry_database(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["QRY-001"],
            expected_major=args.expected_major,
            compatibility_level=args.compatibility_level,
        )

        stage = "MULTI_SESSION"
        _announce(stage)
        matrix._test_orchestration(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["CON-004"],
            proxy_path=proxy_path,
        )

        stage = "QUERY_STORE"
        _announce(stage)
        matrix._test_query_store(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["DGN-003"],
        )

        stage = "EXTENDED_EVENTS"
        _announce(stage)
        matrix._test_extended_events(
            container=args.container,
            sqlcmd_path=sqlcmd_path,
            database=database_by_demo["DGN-005"],
        )

        stage = "RUNTIME_HARNESS"
        _announce(stage)
        matrix._test_runtime_harness(
            container=args.container,
            proxy_path=proxy_path,
        )

        print(
            f"SQLPERF_MATRIX_SUMMARY|PASS|SQL{args.expected_major}|"
            f"CL{args.compatibility_level}",
            flush=True,
        )
    except (matrix.MatrixFailure, subprocess.TimeoutExpired) as exc:
        exit_code = 1
        print(
            f"SQLPERF_MATRIX_SUMMARY|FAIL|SQL{args.expected_major}|"
            f"CL{args.compatibility_level}",
            file=sys.stderr,
        )
        print(f"matrix stage {stage}: {exc}", file=sys.stderr)
    finally:
        cleanup_errors: list[str] = []
        for demo_id, run_token, _ in reversed(databases):
            cleanup_stage = f"LIFECYCLE_DROP_{demo_id.replace('-', '')}"
            _announce(cleanup_stage)
            try:
                matrix._drop_database(
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
