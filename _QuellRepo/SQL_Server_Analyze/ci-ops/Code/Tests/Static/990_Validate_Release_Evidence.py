#!/usr/bin/env python3
"""Validate the canonical current release evidence without printing source data."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path


TARGETS = {
    "SQL2019-LINUX": ("15", "150"),
    "SQL2022-LINUX": ("16", "160"),
    "SQL2025-LINUX": ("17", "170"),
}
WINDOWS_PLANNING_TARGETS = {
    "SQL2019-WINDOWS": ("15", "150"),
    "SQL2022-WINDOWS": ("16", "160"),
    "SQL2025-WINDOWS": ("17", "170"),
}
COUNTS = {
    "ReleaseGateSuiteCount": "34",
    "P0CaseCount": "17",
    "P1CaseCount": "40",
    "P2CaseCount": "124",
}
CURRENT_DOCUMENTS = (
    "AI_Metadata/Internal_Documentation/Quality/Next_Steps.md",
    "AI_Metadata/Internal_Documentation/Quality/Known_Issues_History.md",
    "AI_Metadata/Internal_Documentation/Quality/Release_Notes_History.md",
    "AI_Metadata/Internal_Documentation/Quality/Test_Matrix_History.md",
)
WAVE1_SUITE = "WAVE1_OUTPUT_XML_VERSION_RUNTIME"
WAVE2_SUITE = "WAVE2_OPERATIONAL_DIAGNOSTICS_RUNTIME"
WINDOWS_REPOSITORY_TARGET = "WINDOWS-SELF-HOSTED"
WINDOWS_REPOSITORY_SUITE = "WINDOWS_REPOSITORY_PORTABILITY"
WINDOWS_REPOSITORY_PUBLIC_DOCUMENTS = (
    "Documentation/Quality/Test_Matrix.md",
    "Documentation/Quality/Release_Notes.md",
)
WINDOWS_REPOSITORY_INTERNAL_DOCUMENTS = (
    "AI_Metadata/Internal_Documentation/Quality/Next_Steps.md",
)
WAVE1_ENHANCEMENTS = {
    "DIAG-001",
    "DIAG-002",
    "DIAG-006",
    "DIAG-007",
    "OUT-001",
}
WAVE2_ENHANCEMENTS = {"OPS-001", "OPS-002", "OPS-003", "OPS-004"}


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
    if reader.fieldnames is None or any(
        None in row or any(value is None for value in row.values())
        for row in rows
    ):
        fail("CSV_FIELD_COUNT", path.name)
    return rows


def fail(code: str, location: str) -> None:
    print(
        f"Release-Evidence-Vertrag verletzt: code={code} location={location}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()

    matrix_path = root / "Metadata/Quality/Test_Matrix.csv"
    matrix = read_csv(matrix_path)
    windows_planning = {
        row["TargetId"]: row
        for row in matrix
        if row["TargetId"] in WINDOWS_PLANNING_TARGETS
    }
    if set(windows_planning) != set(WINDOWS_PLANNING_TARGETS):
        fail("WINDOWS_PLANNING_TARGET_SET", str(matrix_path.relative_to(root)))
    for target, (major, compatibility) in WINDOWS_PLANNING_TARGETS.items():
        row = windows_planning[target]
        if (
            row["ProductMajorVersion"] != major
            or row["CompatibilityLevel"] != compatibility
            or row["Platform"] != "WINDOWS"
        ):
            fail("WINDOWS_PLANNING_TARGET", target)
        expected = {
            "CommitSha": "",
            "TestStatus": "NOT_EXECUTED",
            "EvidenceStatus": "REPORTED",
            "TestedAtUtc": "",
            "EvidenceReference": "",
        }
        if any(row[field] != value for field, value in expected.items()) or not row["Limitations"]:
            fail("WINDOWS_PLANNING_STATUS", target)

    current = {row["TargetId"]: row for row in matrix if row["TargetId"] in TARGETS}
    if set(current) != set(TARGETS):
        fail("CURRENT_TARGET_SET", str(matrix_path.relative_to(root)))

    commits = {row["CommitSha"] for row in current.values()}
    releases = {row["FrameworkRelease"] for row in current.values()}
    if len(commits) != 1 or not re.fullmatch(r"[0-9a-f]{40}", next(iter(commits), "")):
        fail("CURRENT_COMMIT", str(matrix_path.relative_to(root)))
    if len(releases) != 1 or not next(iter(releases), ""):
        fail("CURRENT_RELEASE", str(matrix_path.relative_to(root)))
    commit = next(iter(commits))
    release = next(iter(releases))

    for target, (major, compatibility) in TARGETS.items():
        row = current[target]
        if row["ProductMajorVersion"] != major or row["CompatibilityLevel"] != compatibility:
            fail("TARGET_VERSION", target)
        if not re.fullmatch(rf"{major}\.[0-9]+\.[0-9]+\.[0-9]+", row["ProductVersion"]):
            fail("PRODUCT_VERSION", target)
        if not re.fullmatch(
            r"mcr\.microsoft\.com/mssql/server@sha256:[0-9a-f]{64}",
            row["ContainerImageDigest"],
        ):
            fail("IMAGE_DIGEST", target)
        if any(row[field] != value for field, value in COUNTS.items()):
            fail("CURRENT_COUNTS", target)
        if row["TestStatus"] != "PASS_WITH_LIMITATIONS" or row["EvidenceStatus"] != "INDEPENDENTLY_VERIFIED":
            fail("CURRENT_STATUS", target)
        if not re.fullmatch(r"https://github\.com/gecompat/SQL_Server_Analyze/actions/runs/[0-9]+", row["EvidenceReference"]):
            fail("EVIDENCE_REFERENCE", target)

    detail_path = root / "Metadata/Quality/Release_Gate_Evidence.csv"
    detail = read_csv(detail_path)
    windows_repository_rows = [
        row
        for row in detail
        if row["TargetId"] == WINDOWS_REPOSITORY_TARGET
        and row["SuiteId"] == WINDOWS_REPOSITORY_SUITE
    ]
    if len(windows_repository_rows) != 1:
        fail("WINDOWS_REPOSITORY_EVIDENCE_SET", str(detail_path.relative_to(root)))
    windows_repository = windows_repository_rows[0]
    windows_commit = windows_repository["CommitSha"]
    windows_reference = windows_repository["EvidenceReference"]
    if (
        not re.fullmatch(r"[0-9a-f]{40}", windows_commit)
        or windows_repository["TestStatus"] != "PASS"
        or windows_repository["EvidenceStatus"] != "INDEPENDENTLY_VERIFIED"
        or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
            windows_repository["TestedAtUtc"],
        )
        or windows_repository["LimitationCode"]
        != "WINDOWS_TOOLCHAIN_POWERSHELL_PRIVACY_INSTALLER_LAB_STATIC"
        or not re.fullmatch(
            r"https://github\.com/gecompat/SQL_Server_Analyze/actions/runs/[0-9]+",
            windows_reference,
        )
    ):
        fail("WINDOWS_REPOSITORY_EVIDENCE", WINDOWS_REPOSITORY_TARGET)

    for relative in WINDOWS_REPOSITORY_PUBLIC_DOCUMENTS:
        text = (root / relative).read_text(encoding="utf-8")
        if (
            WINDOWS_REPOSITORY_SUITE not in text
            or "NOT_EXECUTED" not in text
        ):
            fail("WINDOWS_REPOSITORY_DOCUMENT", relative)

    for relative in WINDOWS_REPOSITORY_INTERNAL_DOCUMENTS:
        text = (root / relative).read_text(encoding="utf-8")
        if (
            WINDOWS_REPOSITORY_SUITE not in text
            or windows_commit not in text
            or "NOT_EXECUTED" not in text
        ):
            fail("WINDOWS_REPOSITORY_DOCUMENT", relative)

    release_rows = {
        row["TargetId"]: row
        for row in detail
        if row["TargetId"] in TARGETS and row["SuiteId"] == "RELEASE_GATE_ALL"
    }
    if set(release_rows) != set(TARGETS):
        fail("RELEASE_GATE_TARGET_SET", str(detail_path.relative_to(root)))
    for target, row in release_rows.items():
        canonical = current[target]
        expected = {
            "CommitSha": canonical["CommitSha"],
            "TestedAtUtc": canonical["TestedAtUtc"],
            "EvidenceReference": canonical["EvidenceReference"],
            "TestStatus": "PASS",
            "EvidenceStatus": "INDEPENDENTLY_VERIFIED",
            "LimitationCode": "ACTIONS_SYNTHETIC_34_SUITES",
        }
        if any(row[field] != value for field, value in expected.items()):
            fail("RELEASE_GATE_DETAIL", target)

    wave1_rows = {
        row["TargetId"]: row
        for row in detail
        if row["TargetId"] in TARGETS and row["SuiteId"] == WAVE1_SUITE
    }
    if set(wave1_rows) != set(TARGETS):
        fail("WAVE1_TARGET_SET", str(detail_path.relative_to(root)))
    for target, row in wave1_rows.items():
        canonical = current[target]
        expected = {
            "CommitSha": canonical["CommitSha"],
            "TestedAtUtc": canonical["TestedAtUtc"],
            "EvidenceReference": canonical["EvidenceReference"],
            "TestStatus": "PASS",
            "EvidenceStatus": "INDEPENDENTLY_VERIFIED",
            "LimitationCode": "ACTIONS_SYNTHETIC_WAVE1_CONTRACT",
        }
        if any(row[field] != value for field, value in expected.items()):
            fail("WAVE1_DETAIL", target)

    wave2_rows = {
        row["TargetId"]: row
        for row in detail
        if row["TargetId"] in TARGETS and row["SuiteId"] == WAVE2_SUITE
    }
    if set(wave2_rows) != set(TARGETS):
        fail("WAVE2_TARGET_SET", str(detail_path.relative_to(root)))
    for target, row in wave2_rows.items():
        canonical = current[target]
        expected = {
            "CommitSha": canonical["CommitSha"],
            "TestedAtUtc": canonical["TestedAtUtc"],
            "EvidenceReference": canonical["EvidenceReference"],
            "TestStatus": "PASS",
            "EvidenceStatus": "INDEPENDENTLY_VERIFIED",
            "LimitationCode": "ACTIONS_SYNTHETIC_WAVE2_CONTRACT",
        }
        if any(row[field] != value for field, value in expected.items()):
            fail("WAVE2_DETAIL", target)

    backlog_path = root / "Metadata/Quality/Future_Enhancement_Backlog.csv"
    backlog = read_csv(backlog_path)
    wave1_backlog = {
        row["EnhancementId"]: row
        for row in backlog
        if row["EnhancementId"] in WAVE1_ENHANCEMENTS
    }
    if set(wave1_backlog) != WAVE1_ENHANCEMENTS:
        fail("WAVE1_BACKLOG_SET", str(backlog_path.relative_to(root)))
    if any(
        row["ImplementationStatus"] != "IMPLEMENTED_ACTIONS_GATE"
        for row in wave1_backlog.values()
    ):
        fail("WAVE1_BACKLOG_STATUS", str(backlog_path.relative_to(root)))

    wave2_backlog = {
        row["EnhancementId"]: row
        for row in backlog
        if row["EnhancementId"] in WAVE2_ENHANCEMENTS
    }
    if set(wave2_backlog) != WAVE2_ENHANCEMENTS:
        fail("WAVE2_BACKLOG_SET", str(backlog_path.relative_to(root)))
    if any(
        row["ImplementationStatus"] != "IMPLEMENTED_ACTIONS_GATE"
        for row in wave2_backlog.values()
    ):
        fail("WAVE2_BACKLOG_STATUS", str(backlog_path.relative_to(root)))

    audit_path = root / "Metadata/Quality/Special_Case_Release_Audit.json"
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    documentation = audit.get("testDocumentation", {})
    actions = documentation.get("actionEvidence", {})
    if audit.get("release") != release or actions.get("commitSha") != commit:
        fail("RELEASE_AUDIT_IDENTITY", str(audit_path.relative_to(root)))
    if audit.get("canonicalEvidenceSource") != "Metadata/Quality/Test_Matrix.csv":
        fail("CANONICAL_SOURCE", str(audit_path.relative_to(root)))
    if (
        "34-suite" not in audit.get("scope", "")
        or "Wave-2" not in audit.get("scope", "")
        or commit not in documentation.get("claim", "")
    ):
        fail("RELEASE_AUDIT_SCOPE", str(audit_path.relative_to(root)))

    for relative in CURRENT_DOCUMENTS:
        text = (root / relative).read_text(encoding="utf-8")
        if commit not in text or "34" not in text:
            fail("CURRENT_DOCUMENT", relative)

    print(
        "Canonical release evidence validation passed: "
        "targets=3 suites=34 wave1=5 wave2=4 p0=17 p1=40 p2=124 findings=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
