#!/usr/bin/env python3
"""Static contract validation for FWK-006, FWK-007 and FWK-010."""

from __future__ import annotations

import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT / "Demos" / "00_Framework"

REQUIRED_FILES = {
    FRAMEWORK / "Contracts" / "FWK-006_MultiSession_Orchestration_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-007_QueryStore_ExtendedEvents_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-010_Runtime_Harness_Contract.md",
    FRAMEWORK / "Sql" / "FWK_MultiSessionControl.sql",
    FRAMEWORK / "Sql" / "FWK_QueryStoreLifecycle.sql",
    FRAMEWORK / "Sql" / "FWK_ExtendedEventsLifecycle.sql",
    FRAMEWORK / "Tools" / "sqlcmd_process.py",
    FRAMEWORK / "Tools" / "orchestrate_sessions.py",
    FRAMEWORK / "Tools" / "run_demo.py",
    FRAMEWORK / "Examples" / "FWK-006" / "manifest.json",
    FRAMEWORK / "Examples" / "FWK-006" / "10_Producer.sql",
    FRAMEWORK / "Examples" / "FWK-006" / "20_Consumer.sql",
    FRAMEWORK / "Examples" / "FWK-010" / "manifest.json",
    FRAMEWORK / "Examples" / "FWK-010" / "00_Preflight.sql",
    FRAMEWORK / "Examples" / "FWK-010" / "10_Setup.sql",
    FRAMEWORK / "Examples" / "FWK-010" / "30_Demonstration.sql",
    FRAMEWORK / "Examples" / "FWK-010" / "90_Cleanup.sql",
    ROOT / "Tests" / "Static" / "test_orchestration_runtime.py",
}
REQUIRED_CODES = {
    "WARN_OPTIONAL_EVIDENCE_SKIPPED",
    "SKIP_TOOL_MISSING",
    "FAIL_TIMEOUT",
    "FAIL_EXECUTION",
    "FAIL_CLEANUP",
    "FAIL_SAFETY",
}
SECRET_FIELD_PATTERN = re.compile(
    r"password|secret|token_value|connection_string|server|username|login|credential",
    flags=re.IGNORECASE,
)


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def sql_lexical_error(text: str) -> str | None:
    index = 0
    state = "normal"
    block_depth = 0
    parenthesis_depth = 0
    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""
        if state == "normal":
            if char == "'":
                state = "string"
            elif char == "[":
                state = "bracket"
            elif char == "-" and nxt == "-":
                state = "line_comment"
                index += 1
            elif char == "/" and nxt == "*":
                state = "block_comment"
                block_depth = 1
                index += 1
            elif char == "(":
                parenthesis_depth += 1
            elif char == ")":
                parenthesis_depth -= 1
                if parenthesis_depth < 0:
                    return "closing parenthesis without opening parenthesis"
        elif state == "string":
            if char == "'" and nxt == "'":
                index += 1
            elif char == "'":
                state = "normal"
        elif state == "bracket":
            if char == "]" and nxt == "]":
                index += 1
            elif char == "]":
                state = "normal"
        elif state == "line_comment":
            if char in "\r\n":
                state = "normal"
        else:
            if char == "/" and nxt == "*":
                block_depth += 1
                index += 1
            elif char == "*" and nxt == "/":
                block_depth -= 1
                index += 1
                if block_depth == 0:
                    state = "normal"
        index += 1
    if state in {"string", "bracket", "block_comment"}:
        return f"unterminated lexical state: {state}"
    if parenthesis_depth != 0:
        return f"unbalanced parentheses: {parenthesis_depth}"
    return None


def walk_json_fields(value: object, path: str = "$") -> list[str]:
    findings: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if SECRET_FIELD_PATTERN.search(str(key)):
                findings.append(f"forbidden connection/secret field {path}.{key}")
            if key == "database" and child not in {"master", "target"}:
                findings.append(f"database selector must be master or target at {path}.{key}")
            findings.extend(walk_json_fields(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            findings.extend(walk_json_fields(child, f"{path}[{index}]"))
    return findings


def require_tokens(findings: list[str], label: str, text: str, tokens: tuple[str, ...]) -> None:
    for token in tokens:
        if token not in text:
            findings.append(f"{label} missing token: {token}")


def main() -> int:
    findings: list[str] = []
    for path in sorted(REQUIRED_FILES):
        if not path.is_file():
            findings.append(f"missing required file: {relative(path)}")
    if findings:
        return report(findings)

    status_contract = read_text(FRAMEWORK / "Contracts" / "FWK-012_Status_Error_Skip_Contract.md")
    require_tokens(findings, "status contract", status_contract, tuple(sorted(REQUIRED_CODES)))

    for python_path in sorted((FRAMEWORK / "Tools").glob("*.py")):
        try:
            ast.parse(read_text(python_path), filename=relative(python_path))
        except SyntaxError as exc:
            findings.append(f"python syntax error {relative(python_path)}:{exc.lineno}: {exc.msg}")

    for sql_path in sorted((FRAMEWORK / "Sql").glob("*.sql")):
        error = sql_lexical_error(read_text(sql_path))
        if error:
            findings.append(f"T-SQL lexical error {relative(sql_path)}: {error}")

    multi = read_text(FRAMEWORK / "Sql" / "FWK_MultiSessionControl.sql")
    require_tokens(findings, "FWK-006 implementation", multi, (
        "fwk.SessionSignal", "fwk.USP_Signal", "fwk.USP_WaitForSignal",
        "fwk.USP_ClearSignals", "WAITFOR DELAY", "00:00:00.100", "FAIL_TIMEOUT",
    ))

    query_store = read_text(FRAMEWORK / "Sql" / "FWK_QueryStoreLifecycle.sql")
    require_tokens(findings, "Query Store implementation", query_store, (
        "sys.database_query_store_options", "fwk.QueryStoreBaseline",
        "SET QUERY_STORE = ON", "SET QUERY_STORE CLEAR ALL",
        "QUERY_CAPTURE_MODE = AUTO", "WAIT_STATS_CAPTURE_MODE = ON",
    ))
    status_position = query_store.find("IF @Action = 'STATUS'")
    enable_position = query_store.find("IF @Action = 'ENABLE'")
    create_schema_position = query_store.find("CREATE SCHEMA fwk")
    if min(status_position, enable_position, create_schema_position) == -1 or create_schema_position < enable_position:
        findings.append("Query Store STATUS path is not read-only: baseline creation must start inside ENABLE")

    xe = read_text(FRAMEWORK / "Sql" / "FWK_ExtendedEventsLifecycle.sql")
    require_tokens(findings, "Extended Events implementation", xe, (
        "CREATE EVENT SESSION", "ON SERVER", "package0.ring_buffer",
        "MAX_MEMORY = (1024)", "STARTUP_STATE = OFF",
        "CREATE ANY EVENT SESSION", "DROP ANY EVENT SESSION", "ALTER ANY EVENT SESSION",
    ))
    if re.search(r"event_file", xe, flags=re.IGNORECASE):
        findings.append("Extended Events reference must not use event_file")
    if re.search(r"STARTUP_STATE\s*=\s*ON", xe, flags=re.IGNORECASE):
        findings.append("Extended Events reference must not auto-start")

    wrapper = read_text(FRAMEWORK / "Tools" / "sqlcmd_process.py")
    require_tokens(findings, "sqlcmd wrapper", wrapper, ("SQLCMDPASSWORD", "shell=False", "start_new_session", "SQLPERF_SUMMARY"))
    if re.search(r"(?:-P|--password)", wrapper):
        findings.append("sqlcmd password must not be placed on the command line")

    require_tokens(findings, "orchestrator", read_text(FRAMEWORK / "Tools" / "orchestrate_sessions.py"), (
        "abort_on_first_failure", "launch_delay_ms", "FAIL_TIMEOUT", "SKIP_TOOL_MISSING",
    ))
    require_tokens(findings, "runtime harness", read_text(FRAMEWORK / "Tools" / "run_demo.py"), (
        "cleanup_timeout_seconds", "WARN_OPTIONAL_EVIDENCE_SKIPPED", "FAIL_CLEANUP", "target_database_name",
    ))

    for manifest_path in sorted((FRAMEWORK / "Examples").rglob("manifest.json")):
        try:
            payload = json.loads(read_text(manifest_path))
        except json.JSONDecodeError as exc:
            findings.append(f"invalid JSON {relative(manifest_path)}: {exc}")
            continue
        findings.extend(f"{relative(manifest_path)}: {item}" for item in walk_json_fields(payload))

    return report(findings)


def report(findings: list[str]) -> int:
    if findings:
        print(f"orchestration-runtime-contracts: FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print(f"- {finding}")
        return 1
    print(f"orchestration-runtime-contracts: PASS ({len(REQUIRED_FILES)} required files, {len(REQUIRED_CODES)} required status codes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
