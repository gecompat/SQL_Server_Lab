#!/usr/bin/env python3
"""Validate the W2-001 legacy example classification against the neutralized archive."""

from __future__ import annotations

from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
JSON_PATH = ROOT / "Documentation" / "Inventories" / "legacy_example_classification.json"
MD_PATH = ROOT / "Documentation" / "Inventories" / "LEGACY_EXAMPLE_CLASSIFICATION.md"
SOURCE_MANIFEST = ROOT / "Documentation" / "Inventories" / "SOURCE_MANIFEST.md"
BACKLOG = ROOT / ".ai" / "BACKLOG.md"
MASTER_PLAN = ROOT / "Documentation" / "Project_Planning" / "MASTER_IMPLEMENTATION_PLAN.md"
ARCHIVE = ROOT / "Presentations" / "old" / "Performance Grundlagen V-2024.zip"

ALLOWED_DECISIONS = {"REUSE", "REFACTOR", "REBUILD", "DIAGNOSTIC_ONLY", "REMOVE"}
EXPECTED_IDS = {f"SRC-LEGACY-{number:03d}" for number in range(8, 31)}
EXPECTED_COUNTS = {
    "REUSE": 0,
    "REFACTOR": 1,
    "REBUILD": 14,
    "DIAGNOSTIC_ONLY": 4,
    "REMOVE": 4,
}
ARCHIVE_SHA256 = "78e3d1d708758d1115a066eca1df2c66d6f26ba57903b764c98e901506892041"
CANONICAL_ID_PATTERN = re.compile(r"^(?:STL|OPT|QRY|IDX|CON|RES|DGN)-\d{3}$")


def fail(findings: list[str], message: str) -> None:
    findings.append(message)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    findings: list[str] = []

    for path in (JSON_PATH, MD_PATH, SOURCE_MANIFEST, BACKLOG, MASTER_PLAN, ARCHIVE):
        if not path.is_file():
            fail(findings, f"missing required file: {path.relative_to(ROOT)}")

    if findings:
        for item in findings:
            print(f"- {item}")
        return 1

    archive_hash = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    if archive_hash != ARCHIVE_SHA256:
        fail(findings, f"reference archive SHA-256 mismatch: {archive_hash}")

    try:
        payload = json.loads(read_text(JSON_PATH))
    except json.JSONDecodeError as exc:
        fail(findings, f"classification JSON invalid: {exc}")
        payload = {}

    if payload.get("schema_version") != "1.0":
        fail(findings, "schema_version must be 1.0")
    if payload.get("work_package") != "W2-001":
        fail(findings, "work_package must be W2-001")
    if payload.get("status") != "VALIDATED":
        fail(findings, "classification status must be VALIDATED")
    if payload.get("source_archive", {}).get("sha256") != ARCHIVE_SHA256:
        fail(findings, "classification archive hash does not match the protected source archive")

    entries = payload.get("entries")
    if not isinstance(entries, list):
        fail(findings, "entries must be a list")
        entries = []

    ids = [entry.get("source_id") for entry in entries if isinstance(entry, dict)]
    if set(ids) != EXPECTED_IDS or len(ids) != len(EXPECTED_IDS):
        fail(findings, f"source IDs must be exactly SRC-LEGACY-008 through SRC-LEGACY-030; got {len(ids)} entries")
    if len(ids) != len(set(ids)):
        fail(findings, "duplicate source_id values")

    decisions = Counter(entry.get("decision") for entry in entries if isinstance(entry, dict))
    if dict(decisions) != {key: value for key, value in EXPECTED_COUNTS.items() if value}:
        fail(findings, f"decision counts mismatch: {dict(decisions)}")
    if payload.get("summary") != EXPECTED_COUNTS:
        fail(findings, "summary counts do not match the normative decision counts")
    if payload.get("global_result", {}).get("direct_reuse_candidates") != 0:
        fail(findings, "direct_reuse_candidates must remain 0")
    if payload.get("global_result", {}).get("runtime_validation_claimed") is not False:
        fail(findings, "W2-001 must not claim runtime validation of legacy scripts")

    master_text = read_text(MASTER_PLAN)
    canonical_ids = set(re.findall(r"`((?:STL|OPT|QRY|IDX|CON|RES|DGN)-\d{3})`", master_text))

    member_payloads: dict[str, bytes] = {}
    with zipfile.ZipFile(ARCHIVE) as archive:
        for name in archive.namelist():
            if name.lower().endswith((".sql", ".txt")):
                member_payloads[name] = archive.read(name)

    for entry in entries:
        if not isinstance(entry, dict):
            fail(findings, "entry is not an object")
            continue
        source_id = entry.get("source_id", "<missing>")
        decision = entry.get("decision")
        if decision not in ALLOWED_DECISIONS:
            fail(findings, f"{source_id}: invalid decision {decision}")
        archive_path = entry.get("archive_path")
        if archive_path not in member_payloads:
            fail(findings, f"{source_id}: archive member missing: {archive_path}")
            continue
        raw = member_payloads[archive_path]
        if entry.get("bytes") != len(raw):
            fail(findings, f"{source_id}: byte count mismatch")
        digest = hashlib.sha256(raw).hexdigest()
        if entry.get("sha256") != digest:
            fail(findings, f"{source_id}: SHA-256 mismatch")
        if entry.get("source_execution_allowed") is not False:
            fail(findings, f"{source_id}: historical source must not be directly executable")
        if entry.get("runtime_status") != "NOT_APPLICABLE_CLASSIFICATION":
            fail(findings, f"{source_id}: invalid runtime_status")
        target_ids = entry.get("related_demo_ids")
        if not isinstance(target_ids, list):
            fail(findings, f"{source_id}: related_demo_ids must be a list")
            target_ids = []
        for demo_id in target_ids:
            if not CANONICAL_ID_PATTERN.match(str(demo_id)) or demo_id not in canonical_ids:
                fail(findings, f"{source_id}: unknown canonical demo ID {demo_id}")
        if decision in {"REFACTOR", "REBUILD", "DIAGNOSTIC_ONLY"} and not target_ids:
            fail(findings, f"{source_id}: migration/diagnostic decision requires target IDs")
        if decision == "REMOVE" and entry.get("primary_demo_id") is not None:
            fail(findings, f"{source_id}: REMOVE must not have a primary demo ID")
        if decision == "DIAGNOSTIC_ONLY" and entry.get("execution_path") != "READ_ONLY_DIAGNOSTIC":
            fail(findings, f"{source_id}: DIAGNOSTIC_ONLY must use READ_ONLY_DIAGNOSTIC")
        for field in ("subject", "value"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                fail(findings, f"{source_id}: {field} missing")
        for field in ("findings", "required_actions"):
            if not isinstance(entry.get(field), list) or not entry[field]:
                fail(findings, f"{source_id}: {field} must contain at least one item")

    md_text = read_text(MD_PATH)
    if md_text.count("### SRC-LEGACY-") != 23:
        fail(findings, "Markdown classification must contain 23 source sections")
    for decision, count in EXPECTED_COUNTS.items():
        if f"| `{decision}` | {count} |" not in md_text:
            fail(findings, f"Markdown summary missing {decision}={count}")
    if "kein direkter `REUSE`-Kandidat" not in md_text:
        fail(findings, "Markdown must state that no direct REUSE candidate exists")

    source_manifest_text = read_text(SOURCE_MANIFEST)
    if "Klassifikation in `W2-001`" in source_manifest_text:
        fail(findings, "SOURCE_MANIFEST still contains unresolved W2-001 placeholders")
    if "[W2-001-Klassifikation](LEGACY_EXAMPLE_CLASSIFICATION.md)" not in source_manifest_text:
        fail(findings, "SOURCE_MANIFEST does not link the W2-001 classification")
    for entry in entries:
        marker = f"| `{entry['source_id']}` |"
        if marker not in source_manifest_text or f"`{entry['decision']}`" not in source_manifest_text.split(marker, 1)[1].splitlines()[0]:
            fail(findings, f"SOURCE_MANIFEST decision mismatch for {entry['source_id']}")

    backlog_text = read_text(BACKLOG)
    if "- [x] `W2-001`" not in backlog_text:
        fail(findings, "Backlog does not mark W2-001 complete")

    if findings:
        print(f"w2-001-classification: FAIL ({len(findings)} finding(s))")
        for item in findings:
            print(f"- {item}")
        return 1

    print(
        "w2-001-classification: PASS "
        f"({len(entries)} examples; "
        + ", ".join(f"{key}={EXPECTED_COUNTS[key]}" for key in ALLOWED_DECISIONS)
        + ")"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
