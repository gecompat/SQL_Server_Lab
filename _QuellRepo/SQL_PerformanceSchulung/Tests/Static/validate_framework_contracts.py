#!/usr/bin/env python3
"""Static validation for the SQL Performance training framework.

The validator uses only the Python standard library. It reports paths and
aggregate findings, but never copies matched environment or secret values into
artifacts.
"""

from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT / "Demos" / "00_Framework"

REQUIRED_FILES = {
    FRAMEWORK / "README.md",
    FRAMEWORK / "Contracts" / "FWK-001_Preflight_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-002_TestDatabase_Lifecycle_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-003_Synthetic_Data_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-004_Measurement_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-005_Plan_Statistics_Evidence_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-008_Safety_Abort_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-011_Result_Normalization_Contract.md",
    FRAMEWORK / "Contracts" / "FWK-012_Status_Error_Skip_Contract.md",
    FRAMEWORK / "Templates" / "README_TEMPLATE.md",
    FRAMEWORK / "Templates" / "00_Preflight.sql",
    FRAMEWORK / "Templates" / "40_Plan_Statistics_Evidence.sql",
    FRAMEWORK / "Sql" / "FWK_TestDatabaseLifecycle.sql",
    FRAMEWORK / "Sql" / "FWK_SyntheticDataGenerator.sql",
    FRAMEWORK / "Sql" / "FWK_Measurement.sql",
    FRAMEWORK / "Tools" / "evaluate_result_contract.py",
    FRAMEWORK / "Examples" / "FWK-011_ResultContract.example.json",
    FRAMEWORK / "Examples" / "FWK-011_Evidence.pass.example.json",
    FRAMEWORK / "Examples" / "FWK-011_Evidence.fail.example.json",
    ROOT / "Tests" / "Static" / "test_result_contract_evaluator.py",
}

OUTCOMES = {"PASS", "WARN", "SKIP", "FAIL"}
STATUS_CODES = {
    "OK",
    "WARN_ENVIRONMENT_DETAIL_SUPPRESSED",
    "WARN_RESOURCE_PROBE_APPROXIMATE",
    "WARN_EMPIRICAL_VARIANCE",
    "SKIP_VERSION",
    "SKIP_COMPATIBILITY_LEVEL",
    "SKIP_EDITION",
    "SKIP_PLATFORM",
    "SKIP_PERMISSION",
    "SKIP_CONFIGURATION",
    "SKIP_RESOURCE_PROFILE",
    "SKIP_MANUAL_APPROVAL",
    "SKIP_EVIDENCE_MISSING",
    "FAIL_CONTRACT",
    "FAIL_SAFETY",
    "FAIL_STATE",
    "FAIL_EXECUTION",
    "FAIL_CLEANUP",
    "FAIL_RESULT_CONTRACT",
}

README_SECTIONS = {
    "## 1. Lernziel",
    "## 2. Fachliche Kernaussage",
    "## 4. Voraussetzungen",
    "## 5. Sicherheits- und Abbruchrahmen",
    "## 6. Synthetisches Datenmodell",
    "## 7. Ablauf",
    "## 8. Erwartete Beobachtung",
    "## 10. Cleanup und Wiederherstellung",
    "## 11. Tests",
    "## 13. Quellen",
    "## 14. Traceability",
}

LIFECYCLE_MARKERS = {
    "SQLPERF.Project",
    "SQLPERF.ContractVersion",
    "SQLPERF.DemoId",
    "SQLPERF.RunToken",
    "SQLPERF.CreatedUtc",
}

FORBIDDEN_GLOBAL_PATTERNS = {
    r"\bTRUSTWORTHY\s+ON\b": "TRUSTWORTHY ON",
    r"\bDBCC\s+FREEPROCCACHE\b": "DBCC FREEPROCCACHE",
    r"\bDBCC\s+DROPCLEANBUFFERS\b": "DBCC DROPCLEANBUFFERS",
    r"\bxp_cmdshell\b": "xp_cmdshell",
    r"\bSHUTDOWN\b": "SHUTDOWN",
    r"\bALTER\s+SERVER\s+CONFIGURATION\b": "ALTER SERVER CONFIGURATION",
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def check_tokens(
    findings: list[str],
    label: str,
    text: str,
    tokens: set[str],
) -> None:
    for token in sorted(tokens):
        if token not in text:
            findings.append(f"{label} missing required token: {token}")


def check_tsql_lexical(findings: list[str], path: Path) -> None:
    """Check comments, string literals, delimited identifiers and parentheses."""
    text = read_text(path)
    index = 0
    length = len(text)
    parentheses = 0
    state = "normal"

    while index < length:
        char = text[index]
        nxt = text[index + 1] if index + 1 < length else ""

        if state == "normal":
            if char == "-" and nxt == "-":
                state = "line_comment"
                index += 2
                continue
            if char == "/" and nxt == "*":
                state = "block_comment"
                index += 2
                continue
            if char == "'":
                state = "string"
                index += 1
                continue
            if char == "[":
                state = "identifier"
                index += 1
                continue
            if char == "(":
                parentheses += 1
            elif char == ")":
                parentheses -= 1
                if parentheses < 0:
                    findings.append(f"unbalanced parenthesis: {relative(path)}")
                    return
            index += 1
            continue

        if state == "line_comment":
            if char in "\r\n":
                state = "normal"
            index += 1
            continue

        if state == "block_comment":
            if char == "*" and nxt == "/":
                state = "normal"
                index += 2
            else:
                index += 1
            continue

        if state == "string":
            if char == "'" and nxt == "'":
                index += 2
            elif char == "'":
                state = "normal"
                index += 1
            else:
                index += 1
            continue

        if state == "identifier":
            if char == "]" and nxt == "]":
                index += 2
            elif char == "]":
                state = "normal"
                index += 1
            else:
                index += 1

    if state in {"block_comment", "string", "identifier"}:
        findings.append(f"unterminated T-SQL lexical construct: {relative(path)}")
    if parentheses != 0:
        findings.append(f"unbalanced parenthesis: {relative(path)}")


def validate_json_example(findings: list[str], path: Path) -> dict[str, object] | None:
    try:
        value = json.loads(
            read_text(path),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
    except (json.JSONDecodeError, ValueError):
        findings.append(f"invalid or non-finite JSON example: {relative(path)}")
        return None
    if not isinstance(value, dict):
        findings.append(f"JSON example must be an object: {relative(path)}")
        return None
    return value


def main() -> int:
    findings: list[str] = []

    missing = sorted(path for path in REQUIRED_FILES if not path.is_file())
    findings.extend(f"missing required file: {relative(path)}" for path in missing)

    if missing:
        print(f"framework-contracts: FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print(f"- {finding}")
        return 1

    preflight = read_text(FRAMEWORK / "Templates" / "00_Preflight.sql")
    lifecycle = read_text(FRAMEWORK / "Sql" / "FWK_TestDatabaseLifecycle.sql")
    generator = read_text(FRAMEWORK / "Sql" / "FWK_SyntheticDataGenerator.sql")
    measurement = read_text(FRAMEWORK / "Sql" / "FWK_Measurement.sql")
    evidence = read_text(FRAMEWORK / "Templates" / "40_Plan_Statistics_Evidence.sql")
    evaluator_path = FRAMEWORK / "Tools" / "evaluate_result_contract.py"
    evaluator = read_text(evaluator_path)
    status_contract = read_text(
        FRAMEWORK / "Contracts" / "FWK-012_Status_Error_Skip_Contract.md"
    )
    readme_template = read_text(FRAMEWORK / "Templates" / "README_TEMPLATE.md")

    for outcome in sorted(OUTCOMES):
        if outcome not in preflight or outcome not in status_contract or outcome not in evaluator:
            findings.append(f"outcome not consistently defined: {outcome}")

    for code in sorted(STATUS_CODES):
        if code not in status_contract:
            findings.append(f"status contract missing code: {code}")

    check_tokens(
        findings,
        "preflight",
        preflight,
        {
            "SERVERPROPERTY('ProductMajorVersion')",
            "sys.databases",
            "HAS_PERMS_BY_NAME",
            "@ConfirmIsolatedLab",
            "@HighImpactConfirmed",
            "@DisposableEnvironmentConfirmed",
            "@RecoveryPlanConfirmed",
            "WARN_ENVIRONMENT_DETAIL_SUPPRESSED",
            "CheckId, Outcome, Code",
            "'SUMMARY'",
            "THROW 51000",
        },
    )

    for marker in sorted(LIFECYCLE_MARKERS):
        if marker not in lifecycle:
            findings.append(f"lifecycle missing ownership marker: {marker}")

    check_tokens(
        findings,
        "lifecycle",
        lifecycle,
        {
            "SQLPERF_LAB_",
            "@ConfirmLabUse",
            "@ConfirmDrop",
            "CREATE DATABASE",
            "SINGLE_USER WITH ROLLBACK IMMEDIATE",
            "DROP DATABASE",
            "sys.extended_properties",
            "@CreatedInThisBatch",
            "FAIL_CLEANUP",
        },
    )

    check_tokens(
        findings,
        "generator",
        generator,
        {
            "lab.USP_GenerateSyntheticData",
            "lab.SyntheticFact",
            "lab.SyntheticGeneratorManifest",
            "@RowCount",
            "@Seed",
            "@DistinctKeys",
            "@SkewPercent",
            "@CorrelationPercent",
            "@PayloadBytes",
            "SQLPERF.Project",
            "CHECKSUM_AGG",
            "OPTION (MAXDOP 1)",
        },
    )
    if re.search(r"\bNEWID\s*\(", generator, flags=re.IGNORECASE):
        findings.append("generator uses NEWID and is not value-deterministic")
    if re.search(r"\bRAND\s*\(", generator, flags=re.IGNORECASE):
        findings.append("generator uses RAND and is not value-deterministic")
    if re.search(r"\bsys\.(all_|objects|columns|tables)", generator, flags=re.IGNORECASE):
        findings.append("generator derives row count from system catalog objects")

    check_tokens(
        findings,
        "measurement",
        measurement,
        {
            "lab.USP_BeginMeasurement",
            "lab.USP_EndMeasurement",
            "sys.dm_exec_sessions",
            "sys.dm_exec_session_wait_stats",
            "DATEDIFF_BIG",
            "UPDLOCK, HOLDLOCK",
            "WARN_RESOURCE_PROBE_APPROXIMATE",
            "MeasurementRunId",
            "ResultRows",
        },
    )

    check_tokens(
        findings,
        "plan-statistics evidence",
        evidence,
        {
            "sys.dm_db_stats_properties",
            "sys.dm_db_stats_histogram",
            "SET STATISTICS XML ON",
            "SET STATISTICS XML OFF",
            "HAS_PERMS_BY_NAME",
            "SHOWPLAN",
            "OPTION (RECOMPILE, MAXDOP 1)",
        },
    )

    check_tokens(
        findings,
        "result evaluator",
        evaluator,
        {
            "EXACT",
            "RANGE",
            "RATIO_MAX",
            "RATIO_MIN",
            "DIRECTION",
            "FAIL_RESULT_CONTRACT",
            "SKIP_EVIDENCE_MISSING",
            "WARN_EMPIRICAL_VARIANCE",
            "allow_nan=False",
        },
    )
    try:
        ast.parse(evaluator, filename=relative(evaluator_path))
    except SyntaxError:
        findings.append(f"invalid Python syntax: {relative(evaluator_path)}")

    for sql_path in FRAMEWORK.rglob("*.sql"):
        text = read_text(sql_path)
        if "DROP DATABASE" in text and sql_path.name != "FWK_TestDatabaseLifecycle.sql":
            findings.append(f"DROP DATABASE outside lifecycle implementation: {relative(sql_path)}")

    for section in sorted(README_SECTIONS):
        if section not in readme_template:
            findings.append(f"README template missing section: {section}")

    for path in FRAMEWORK.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {
            ".sql", ".md", ".py", ".yml", ".yaml", ".json"
        }:
            continue
        text = read_text(path)
        for pattern, label in FORBIDDEN_GLOBAL_PATTERNS.items():
            if re.search(pattern, text, flags=re.IGNORECASE):
                findings.append(f"forbidden high-risk pattern {label}: {relative(path)}")

    for sql_path in FRAMEWORK.rglob("*.sql"):
        text = read_text(sql_path)
        if re.search(r"<[A-Z][A-Z0-9_| -]{2,}>", text):
            findings.append(f"unresolved placeholder in executable SQL: {relative(sql_path)}")
        check_tsql_lexical(findings, sql_path)

    contract_example = validate_json_example(
        findings, FRAMEWORK / "Examples" / "FWK-011_ResultContract.example.json"
    )
    pass_example = validate_json_example(
        findings, FRAMEWORK / "Examples" / "FWK-011_Evidence.pass.example.json"
    )
    fail_example = validate_json_example(
        findings, FRAMEWORK / "Examples" / "FWK-011_Evidence.fail.example.json"
    )
    if contract_example and pass_example and fail_example:
        metadata = {
            (
                contract_example.get("contract_version"),
                contract_example.get("demo_id"),
                contract_example.get("profile"),
            ),
            (
                pass_example.get("contract_version"),
                pass_example.get("demo_id"),
                pass_example.get("profile"),
            ),
            (
                fail_example.get("contract_version"),
                fail_example.get("demo_id"),
                fail_example.get("profile"),
            ),
        }
        if len(metadata) != 1:
            findings.append("FWK-011 example metadata is inconsistent")

    if findings:
        print(f"framework-contracts: FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print(
        "framework-contracts: PASS "
        f"({len(REQUIRED_FILES)} required files, "
        f"{len(STATUS_CODES)} status codes, "
        f"{len(LIFECYCLE_MARKERS)} ownership markers)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
