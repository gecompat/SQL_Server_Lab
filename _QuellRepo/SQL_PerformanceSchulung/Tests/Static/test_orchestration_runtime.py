#!/usr/bin/env python3
"""SQL-Server-independent self-tests for FWK-006 and FWK-010."""

from __future__ import annotations

import json
from pathlib import Path
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "Demos" / "00_Framework" / "Tools"
sys.path.insert(0, str(TOOLS))

from orchestrate_sessions import run_manifest as run_session_manifest  # noqa: E402
from run_demo import run_demo  # noqa: E402


FAKE_SQLCMD = r'''#!/usr/bin/env python3
import pathlib
import sys
import time

args = sys.argv[1:]
try:
    script = pathlib.Path(args[args.index("-i") + 1])
except (ValueError, IndexError):
    print("missing -i", file=sys.stderr)
    raise SystemExit(2)

name = script.stem.lower()
if "timeout" in name:
    time.sleep(5)
    print("SQLPERF_SUMMARY|PASS|OK")
    raise SystemExit(0)
if "cleanup_fail" in name or "session_fail" in name or "execution_fail" in name:
    print("synthetic execution failure", file=sys.stderr)
    raise SystemExit(1)
if "preflight_skip" in name or "optional_skip" in name:
    print("SQLPERF_SUMMARY|SKIP|SKIP_CONFIGURATION")
    raise SystemExit(0)
if "no_summary" in name:
    print("synthetic output without summary")
    raise SystemExit(0)
print("SQLPERF_SUMMARY|PASS|OK")
raise SystemExit(0)
'''


def write(path: Path, content: str = "-- synthetic\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def write_json(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path


def fake_sqlcmd(root: Path) -> Path:
    path = root / "fake_sqlcmd.py"
    path.write_text(FAKE_SQLCMD, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def session_manifest(root: Path, names: list[str], timeout: int = 3) -> Path:
    sessions = []
    for index, name in enumerate(names, start=1):
        filename = f"{index:02d}_{name}.sql"
        write(root / filename)
        sessions.append(
            {
                "id": f"S{index}",
                "script": filename,
                "launch_delay_ms": 0,
            }
        )
    return write_json(
        root / "sessions.json",
        {
            "contract_version": "1.0",
            "demo_id": "CON-004",
            "run_token": "TEST",
            "timeout_seconds": timeout,
            "abort_on_first_failure": True,
            "sessions": sessions,
        },
    )


def demo_manifest(
    root: Path,
    *,
    preflight: str = "preflight_pass",
    demo: str = "demo_pass",
    cleanup: str = "cleanup_pass",
    safety: str = "GREEN",
    optional: str | None = None,
) -> Path:
    for name in (preflight, "setup_pass", demo, cleanup):
        write(root / f"{name}.sql")

    phases = [
        {
            "id": "PREFLIGHT",
            "kind": "sql",
            "script": f"{preflight}.sql",
            "database": "master",
            "required": True,
            "require_summary": True,
        },
        {
            "id": "SETUP",
            "kind": "sql",
            "script": "setup_pass.sql",
            "database": "target",
            "required": True,
            "require_summary": True,
        },
    ]
    if optional is not None:
        write(root / f"{optional}.sql")
        phases.append(
            {
                "id": "OPTIONAL_EVIDENCE",
                "kind": "sql",
                "script": f"{optional}.sql",
                "database": "target",
                "required": False,
                "require_summary": True,
            }
        )
    phases.append(
        {
            "id": "DEMONSTRATION",
            "kind": "sql",
            "script": f"{demo}.sql",
            "database": "target",
            "required": True,
            "require_summary": True,
        }
    )

    return write_json(
        root / "demo.json",
        {
            "contract_version": "1.0",
            "demo_id": "QRY-001",
            "run_token": "TEST",
            "safety_level": safety,
            "timeout_seconds": 4,
            "cleanup_timeout_seconds": 2,
            "phases": phases,
            "cleanup": {
                "id": "CLEANUP",
                "kind": "sql",
                "script": f"{cleanup}.sql",
                "database": "target",
                "required": True,
                "require_summary": True,
            },
        },
    )


def assert_equal(actual: object, expected: object, message: str) -> None:
    if actual != expected:
        raise AssertionError(f"{message}: expected={expected!r}, actual={actual!r}")


def test_sessions_pass(base: Path, executable: Path) -> None:
    result = run_session_manifest(
        manifest_path=session_manifest(base / "sessions_pass", ["session_pass", "session_pass"]),
        server="synthetic",
        database="SQLPERF_LAB_CON004_TEST",
        auth="integrated",
        username=None,
        sqlcmd_path=str(executable),
        show_output=False,
    )
    assert_equal((result.outcome, result.code), ("PASS", "OK"), "multi-session pass")


def test_sessions_fail(base: Path, executable: Path) -> None:
    result = run_session_manifest(
        manifest_path=session_manifest(base / "sessions_fail", ["session_fail", "timeout"]),
        server="synthetic",
        database="SQLPERF_LAB_CON004_TEST",
        auth="integrated",
        username=None,
        sqlcmd_path=str(executable),
        show_output=False,
    )
    assert_equal((result.outcome, result.code), ("FAIL", "FAIL_EXECUTION"), "multi-session fail-fast")


def test_sessions_timeout(base: Path, executable: Path) -> None:
    result = run_session_manifest(
        manifest_path=session_manifest(base / "sessions_timeout", ["timeout"], timeout=1),
        server="synthetic",
        database="SQLPERF_LAB_CON004_TEST",
        auth="integrated",
        username=None,
        sqlcmd_path=str(executable),
        show_output=False,
    )
    assert_equal((result.outcome, result.code), ("FAIL", "FAIL_TIMEOUT"), "multi-session timeout")


def run_harness(manifest: Path, executable: Path, *, confirm: bool = False):
    return run_demo(
        manifest_path=manifest,
        server="synthetic",
        auth="integrated",
        username=None,
        sqlcmd_path=str(executable),
        confirm_isolated_lab=confirm,
        allow_red=False,
        show_output=False,
    )


def test_harness_pass(base: Path, executable: Path) -> None:
    result = run_harness(demo_manifest(base / "harness_pass"), executable)
    assert_equal((result.outcome, result.code), ("PASS", "OK"), "harness pass")
    assert_equal(result.phases[-1].phase_id, "CLEANUP", "cleanup executed")


def test_harness_cleanup_failure(base: Path, executable: Path) -> None:
    result = run_harness(demo_manifest(base / "cleanup_failure", cleanup="cleanup_fail"), executable)
    assert_equal((result.outcome, result.code), ("FAIL", "FAIL_CLEANUP"), "cleanup priority")


def test_harness_preflight_skip(base: Path, executable: Path) -> None:
    result = run_harness(demo_manifest(base / "preflight_skip", preflight="preflight_skip"), executable)
    assert_equal((result.outcome, result.code), ("SKIP", "SKIP_CONFIGURATION"), "preflight skip")
    assert_equal(len(result.phases), 1, "no state-changing phase after required skip")


def test_harness_optional_skip(base: Path, executable: Path) -> None:
    result = run_harness(demo_manifest(base / "optional_skip", optional="optional_skip"), executable)
    assert_equal((result.outcome, result.code), ("WARN", "WARN_OPTIONAL_EVIDENCE_SKIPPED"), "optional evidence skip")
    assert_equal(result.phases[-1].phase_id, "CLEANUP", "cleanup after optional skip")


def test_harness_yellow_confirmation(base: Path, executable: Path) -> None:
    manifest = demo_manifest(base / "yellow", safety="YELLOW")
    denied = run_harness(manifest, executable, confirm=False)
    assert_equal((denied.outcome, denied.code), ("FAIL", "FAIL_SAFETY"), "yellow without confirmation")
    allowed = run_harness(manifest, executable, confirm=True)
    assert_equal((allowed.outcome, allowed.code), ("PASS", "OK"), "yellow with confirmation")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="sqlperf-orchestration-") as temporary:
        base = Path(temporary)
        executable = fake_sqlcmd(base)
        test_sessions_pass(base, executable)
        test_sessions_fail(base, executable)
        test_sessions_timeout(base, executable)
        test_harness_pass(base, executable)
        test_harness_cleanup_failure(base, executable)
        test_harness_preflight_skip(base, executable)
        test_harness_optional_skip(base, executable)
        test_harness_yellow_confirmation(base, executable)

    print("orchestration-runtime: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
