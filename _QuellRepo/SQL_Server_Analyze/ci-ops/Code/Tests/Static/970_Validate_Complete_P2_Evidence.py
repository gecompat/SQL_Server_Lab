#!/usr/bin/env python3
"""Validate the complete P2 evidence contract without reading runtime output."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

# P2 suite rows retain their first complete evidence; the target matrix and
# RELEASE_GATE_ALL rows point to the latest full framework revalidation.
P2_EVIDENCE_COMMIT = "40d54fdc195b5cfa0015e2cbe281da595e427ab0"
P2_MODULES = {'USP_ServiceBrokerAnalysis', 'USP_SpecialFeatureInventory', 'USP_EncryptionAnalysis', 'USP_TemporalAnalysis', 'USP_InMemoryOltpAnalysis', 'USP_FullTextAnalysis', 'USP_DataCaptureDeepAnalysis', 'USP_MaintenanceOperations'}
P2_SUITE_IDS = {'P2_FEATURE_INVENTORY_RUNTIME', 'P2_BROKER_RUNTIME', 'P2_FULLTEXT_RUNTIME', 'P2_ENCRYPTION_RUNTIME', 'P2_DATA_CAPTURE_RUNTIME', 'P2_XTP_RUNTIME', 'P2_MAINTENANCE_RUNTIME', 'P2_TEMPORAL_RUNTIME'}
TARGET_IDS = {'SQL2025-LINUX', 'SQL2019-LINUX', 'SQL2022-LINUX'}
P2_SUITE_FILES = ('179_P2_Special_Feature_Inventory_Runtime_Contract.sql', '180_P2_InMemory_Oltp_Runtime_Contract.sql', '181_P2_Temporal_Runtime_Contract.sql', '182_P2_Service_Broker_Runtime_Contract.sql', '183_P2_FullText_Runtime_Contract.sql', '184_P2_Data_Capture_Runtime_Contract.sql', '185_P2_Encryption_Runtime_Contract.sql', '186_P2_Maintenance_Runtime_Contract.sql')
TEMPORARY_PATTERNS = (
    "Code/Tests/P2_Validation_Trigger.sql",
    ".github/workflows/fix-p2-",
    ".github/workflows/diagnose-p2-",
    ".github/workflows/finalize-p2-",
    ".github/scripts/finalize_p2_",
)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    matrix = read_csv(root / "Metadata/Quality/Test_Matrix.csv")
    current_target_rows = [row for row in matrix if row.get("TargetId") in TARGET_IDS]
    current_commits = {row.get("CommitSha", "") for row in current_target_rows}
    current_release_commit = next(iter(current_commits), "") if len(current_commits) == 1 else ""
    if not re.fullmatch(r"[0-9a-f]{40}", current_release_commit):
        errors.append("Canonical current release commit differs.")

    cases = read_csv(root / "Metadata/Quality/Special_Case_Test_Cases.csv")
    p2_rows = [row for row in cases if row.get("Module") in P2_MODULES]
    if len(p2_rows) != 124:
        errors.append(f"P2 case row count differs: {len(p2_rows)}")
    for row in p2_rows:
        case_id = row.get("CaseId", "UNKNOWN")
        if row.get("ExecutionStatus") != "PASS_WITH_LIMITATIONS":
            errors.append(f"P2 case is not evidenced: {case_id}")
        if not row.get("EvidenceReference", "").startswith("https://github.com/gecompat/SQL_Server_Analyze/actions/runs/"):
            errors.append(f"P2 evidence URL is invalid: {case_id}")

    evidence = read_csv(root / "Metadata/Quality/Release_Gate_Evidence.csv")
    for target_id in TARGET_IDS:
        release_rows = [row for row in evidence if row.get("TargetId") == target_id and row.get("SuiteId") == "RELEASE_GATE_ALL"]
        if len(release_rows) != 1:
            errors.append(f"Release-gate row count differs: {target_id}")
        elif release_rows[0].get("CommitSha") != current_release_commit or release_rows[0].get("TestStatus") != "PASS":
            errors.append(f"Release-gate evidence differs: {target_id}")
        for suite_id in P2_SUITE_IDS:
            rows = [row for row in evidence if row.get("TargetId") == target_id and row.get("SuiteId") == suite_id]
            if len(rows) != 1:
                errors.append(f"P2 suite row count differs: {target_id}/{suite_id}")
            elif rows[0].get("CommitSha") != P2_EVIDENCE_COMMIT or rows[0].get("TestStatus") != "PASS_WITH_LIMITATIONS":
                errors.append(f"P2 suite evidence differs: {target_id}/{suite_id}")

    for row in matrix:
        if row.get("TargetId") in TARGET_IDS:
            if row.get("CommitSha") != current_release_commit or row.get("TestStatus") != "PASS_WITH_LIMITATIONS":
                errors.append(f"P2 target matrix differs: {row.get('TargetId')}")

    backlog = read_csv(root / "Metadata/Quality/Special_Case_Gap_Backlog.csv")
    for gap_id in [f"SC-{value:03d}" for value in range(15, 23)]:
        rows = [row for row in backlog if row.get("GapId") == gap_id]
        if len(rows) != 1 or rows[0].get("ImplementationStatus") != "IMPLEMENTED_ACTIONS_GATE":
            errors.append(f"P2 backlog status differs: {gap_id}")

    runner = (root / "Code/Tests/Run_Release_Gate.sql").read_text(encoding="utf-8")
    if "CAST(34 AS int) AS [ExecutedSuites]" not in runner:
        errors.append("Release gate does not report 34 suites.")
    for suite_file in P2_SUITE_FILES:
        if suite_file not in runner:
            errors.append(f"Release gate is missing P2 suite: {suite_file}")

    audit = json.loads((root / "Metadata/Quality/Special_Case_Release_Audit.json").read_text(encoding="utf-8"))
    docs = audit.get("testDocumentation", {})
    if docs.get("specialCaseRowsNotExecuted") != 0:
        errors.append("Release audit still reports open special cases.")
    if docs.get("specialCaseRowsPassWithLimitations") != 181:
        errors.append("Release audit evidenced case count differs.")
    if docs.get("actionEvidence", {}).get("commitSha") != current_release_commit:
        errors.append("Release audit runtime commit differs.")
    checks = audit.get("staticChecks", {})
    for key in (
        "p2FeatureInventoryRuntimeContract", "p2XtpRuntimeContract",
        "p2TemporalRuntimeContract", "p2BrokerRuntimeContract",
        "p2FullTextRuntimeContract", "p2DataCaptureRuntimeContract",
        "p2EncryptionRuntimeContract", "p2MaintenanceRuntimeContract",
    ):
        if checks.get(key, {}).get("validatedCommit") != P2_EVIDENCE_COMMIT:
            errors.append(f"Release audit P2 contract differs: {key}")

    next_steps = (root / "AI_Metadata/Internal_Documentation/Quality/Next_Steps.md").read_text(encoding="utf-8")
    if "keine offenen P0-, P1- oder P2-Zeilen" not in next_steps:
        errors.append("Next-steps summary still reports repository P2 work.")

    for path in root.rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue
        relative = path.relative_to(root).as_posix()
        if any(relative == pattern or relative.startswith(pattern) for pattern in TEMPORARY_PATTERNS):
            errors.append(f"Temporary P2 artifact remains: {relative}")
    return sorted(set(errors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=None)
    args = parser.parse_args()
    root = Path(args.repository_root).resolve() if args.repository_root else Path(__file__).resolve().parents[3]
    errors = validate(root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Complete P2 evidence validation succeeded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
