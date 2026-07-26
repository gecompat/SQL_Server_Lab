#!/usr/bin/env python3
"""Validate the completed P1 evidence contract without constraining later phases."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

P1_EVIDENCE_COMMIT = "bdb8f66e20f015e7c563e6d3747144400897b281"
FINAL_CASE_IDS = {
    "AG-NONE", "AG-SUSPEND", "AG-QUEUE", "AG-SEED",
    "AGENT-MISSING", "AGENT-ROUTE", "AGENT-JOB", "AGENT-MAIL",
    "FIND-CORE", "FIND-PARTIAL", "FIND-OPTOUT", "FIND-COMPAT",
}
FINAL_SUITE_IDS = {"P1_AVAILABILITY_RUNTIME", "P1_AGENT_RUNTIME", "P1_FINDINGS_RUNTIME"}
TARGET_IDS = {"SQL2019-LINUX", "SQL2022-LINUX", "SQL2025-LINUX"}


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    cases = read_csv(root / "Metadata/Quality/Special_Case_Test_Cases.csv")
    rows = {row["CaseId"]: row for row in cases if row.get("CaseId") in FINAL_CASE_IDS}
    if set(rows) != FINAL_CASE_IDS:
        errors.append("Final P1 case rows are incomplete.")
    for case_id, row in rows.items():
        if row.get("ExecutionStatus") != "PASS_WITH_LIMITATIONS":
            errors.append(f"Final P1 case is not evidenced: {case_id}")
        if not row.get("EvidenceReference", "").startswith("https://github.com/gecompat/SQL_Server_Analyze/actions/runs/"):
            errors.append(f"Final P1 case evidence URL is invalid: {case_id}")

    evidence = read_csv(root / "Metadata/Quality/Release_Gate_Evidence.csv")
    for target_id in TARGET_IDS:
        for suite_id in FINAL_SUITE_IDS:
            suite_rows = [row for row in evidence if row.get("TargetId") == target_id and row.get("SuiteId") == suite_id]
            if len(suite_rows) != 1:
                errors.append(f"Final P1 suite row count differs: {target_id}/{suite_id}")
            elif suite_rows[0].get("CommitSha") != P1_EVIDENCE_COMMIT or suite_rows[0].get("TestStatus") != "PASS_WITH_LIMITATIONS":
                errors.append(f"Final P1 suite evidence differs: {target_id}/{suite_id}")

    backlog = read_csv(root / "Metadata/Quality/Special_Case_Gap_Backlog.csv")
    for gap_id in ("SC-012", "SC-013", "SC-014"):
        matches = [row for row in backlog if row.get("GapId") == gap_id]
        if len(matches) != 1 or matches[0].get("ImplementationStatus") != "IMPLEMENTED_ACTIONS_GATE":
            errors.append(f"Final P1 backlog status differs: {gap_id}")

    runner = (root / "Code/Tests/Run_Release_Gate.sql").read_text(encoding="utf-8")
    match = re.search(r"CAST\((\d+) AS int\) AS \[ExecutedSuites\]", runner)
    if match is None or int(match.group(1)) < 23:
        errors.append("Release gate no longer contains the complete P1 scope.")
    for suite_file in (
        "176_P1_Availability_Runtime_Contract.sql",
        "177_P1_Agent_Runtime_Contract.sql",
        "178_P1_Diagnostic_Findings_Runtime_Contract.sql",
    ):
        if suite_file not in runner:
            errors.append(f"Release gate is missing final P1 suite: {suite_file}")

    audit = json.loads((root / "Metadata/Quality/Special_Case_Release_Audit.json").read_text(encoding="utf-8"))
    static_checks = audit.get("staticChecks", {})
    for key in ("p1AvailabilityRuntimeContract", "p1AgentRuntimeContract", "p1FindingsRuntimeContract"):
        if static_checks.get(key, {}).get("validatedCommit") != P1_EVIDENCE_COMMIT:
            errors.append(f"Release audit final P1 contract differs: {key}")

    next_steps = (root / "AI_Metadata/Internal_Documentation/Quality/Next_Steps.md").read_text(encoding="utf-8")
    if "alle 17 P0-" not in next_steps or "40 P1-" not in next_steps:
        errors.append("Next-steps summary does not retain complete P1 evidence.")
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
    print("Complete P1 evidence validation succeeded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
