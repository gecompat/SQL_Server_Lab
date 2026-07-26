#!/usr/bin/env python3
"""Validate LAB-001 Welle 2 container-baseline contracts."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REQUIRED_FILES = (
    "Lab/Containers/compose.yaml",
    "Lab/Containers/compose.docker.yaml",
    "Lab/Containers/Scripts/bootstrap-linux.sh",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/ContainerRuntime.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/Installer.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/ResourceMeasurement.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/ScenarioRuntime.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabUp.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabScenario.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Test-LabScenario.ps1",
    "Lab/Scenarios/Core/LAB-BASE-001/scenario.json",
    "Lab/Scenarios/Core/LAB-BASE-001/scenario.sql",
    "Lab/Scenarios/Core/LAB-BASE-002/scenario.json",
    "Lab/Scenarios/Core/LAB-BASE-002/scenario.sql",
)


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str


def read_text(path: Path, findings: list[Finding]) -> str:
    try:
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            findings.append(Finding("UTF8_BOM_UNEXPECTED", path.as_posix()))
        if b"\x00" in raw:
            findings.append(Finding("SOURCE_CONTAINS_NUL", path.as_posix()))
        return raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        findings.append(Finding("SOURCE_READ_FAILED", path.as_posix()))
        return ""


def load_json(path: Path, findings: list[Finding]) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        findings.append(Finding("JSON_INVALID", path.as_posix()))
        return None


def load_csv(path: Path, findings: list[Finding]) -> list[dict[str, str]]:
    try:
        with path.open("r", encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream))
    except (OSError, csv.Error):
        findings.append(Finding("CSV_INVALID", path.as_posix()))
        return []


def validate_required_files(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for relative_path in REQUIRED_FILES:
        path = repository_root / relative_path
        if not path.is_file():
            findings.append(Finding("WAVE2_FILE_MISSING", relative_path))
        elif path.stat().st_size == 0:
            findings.append(Finding("WAVE2_FILE_EMPTY", relative_path))
    return findings


def validate_compose(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    core_path = repository_root / "Lab/Containers/compose.yaml"
    override_path = repository_root / "Lab/Containers/compose.docker.yaml"
    core = read_text(core_path, findings)
    override = read_text(override_path, findings)

    required_core = (
        "${LAB_SQL_IMAGE:",
        "${LAB_SQL_SA_PASSWORD:",
        "${LAB_RUNTIME_DIR:",
        "${LAB_DATA_DIR:",
        "${LAB_RUN_ID:",
        "MSSQL_COLLATION: SQL_Latin1_General_CP1_CS_AS",
        "MSSQL_MEMORY_LIMIT_MB: \"2048\"",
        "lab001.run-id:",
        "internal: true",
        "/opt/mssql-tools18/bin/sqlcmd",
    )
    for fragment in required_core:
        if fragment not in core:
            findings.append(Finding("COMPOSE_GUARD_MISSING", fragment))
    for forbidden in (
        re.compile(r"(?m)^\s*ports\s*:"),
        re.compile(r"(?i)MSSQL_SA_PASSWORD\s*:\s*['\"]?[^\s$]"),
        re.compile(r"(?i)\bSA_PASSWORD\b"),
        re.compile(r"(?i)\bnetwork_mode\s*:\s*host\b"),
        re.compile(r"(?i)\bprivileged\s*:\s*true\b"),
    ):
        if forbidden.search(core):
            findings.append(Finding("COMPOSE_UNSAFE_SETTING", core_path.as_posix()))
    for fragment in ("pull_policy: never", "mem_limit: 3g", "cpus: 2.0"):
        if fragment not in override:
            findings.append(Finding("DOCKER_LIMIT_MISSING", fragment))
    return findings


def validate_scenarios(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    expected = {
        "LAB-BASE-001": "BASELINE_OUTPUT_VALID",
        "LAB-BASE-002": "PERMISSION_BOUNDARY_OBSERVED",
    }
    for scenario_id, finding_code in expected.items():
        base = repository_root / "Lab/Scenarios/Core" / scenario_id
        manifest = load_json(base / "scenario.json", findings)
        sql = read_text(base / "scenario.sql", findings)
        if not isinstance(manifest, dict):
            continue
        checks = (
            manifest.get("ScenarioId") == scenario_id,
            manifest.get("TopologyId") == "CTR-SINGLE",
            manifest.get("ResourceProfile") == "Compact",
            manifest.get("SqlVersions") == [2025],
            manifest.get("DataClassification") == "SYNTHETIC",
        )
        if not all(checks):
            findings.append(Finding("SCENARIO_BOUNDARY_INVALID", scenario_id))
        serialized = json.dumps(manifest, sort_keys=True)
        if finding_code not in serialized or finding_code not in sql:
            findings.append(Finding("SCENARIO_ASSERTION_MISSING", scenario_id))
        if "LAB_ASSERTION_JSON=" not in sql:
            findings.append(Finding("SCENARIO_OUTPUT_ENVELOPE_MISSING", scenario_id))
        if re.search(r"(?i)\bDROP\s+DATABASE\b|\bSHUTDOWN\b|\bDBCC\s+WRITEPAGE\b", sql):
            findings.append(Finding("SCENARIO_DESTRUCTIVE_SQL", scenario_id))
    return findings


def validate_orchestration(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    orchestration_root = repository_root / "Lab/Orchestration"
    source = "\n".join(
        read_text(path, findings)
        for path in orchestration_root.rglob("*")
        if path.is_file() and path.suffix.lower() in {".ps1", ".psm1", ".psd1"}
    )
    for fragment in (
        "Invoke-LabUp",
        "Invoke-LabScenario",
        "Test-LabScenario",
        "Resolve-LabSqlContainerImage",
        "Invoke-LabLinuxContainerBootstrap",
        "Register-LabResource",
        "Remove-LabDockerResource",
        "Assert-LabResourceBudget",
        "Measure-LabContainerResources",
        "HYPERV_LINUX_RUNTIME_GATE_REQUIRED",
        "PODMAN_COMPATIBILITY_ASSIGNED_TO_WAVE9",
    ):
        if fragment not in source:
            findings.append(Finding("WAVE2_ORCHESTRATION_GUARD_MISSING", fragment))
    for pattern, rule in (
        (r"(?i)\bInvoke-Expression\b", "POWERSHELL_INVOKE_EXPRESSION"),
        (r"(?i)\bdocker\s+system\s+prune\b", "DOCKER_BROAD_PRUNE"),
        (r"(?i)\bdocker\s+(container|network|volume)\s+prune\b", "DOCKER_BROAD_PRUNE"),
        (r"(?i)\bRemove-Item\b[^\r\n]*\s-Recurse\b", "RECURSIVE_DELETE"),
    ):
        if re.search(pattern, source):
            findings.append(Finding(rule, orchestration_root.as_posix()))
    return findings


def validate_status(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    rows = load_csv(
        repository_root / "Metadata/Quality/Lab_Wave_Status.csv",
        findings,
    )
    wave = next((row for row in rows if row.get("WaveId") == "LAB-001-WAVE2"), None)
    if wave is None:
        findings.append(Finding("WAVE2_STATUS_MISSING", "Lab_Wave_Status.csv"))
    elif (
        wave.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE"
        or wave.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"
    ):
        findings.append(Finding("WAVE2_STATUS_INVALID", "Lab_Wave_Status.csv"))

    catalog = load_json(
        repository_root / "Lab/Scenarios/Catalog/scenarios.json",
        findings,
    )
    if isinstance(catalog, dict):
        if catalog.get("Wave2ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
            findings.append(Finding("WAVE2_CATALOG_STATUS_INVALID", "scenarios.json"))
        scenarios = {
            item.get("ScenarioId"): item
            for item in catalog.get("Scenarios", [])
            if isinstance(item, dict)
        }
        for scenario_id in ("LAB-BASE-001", "LAB-BASE-002"):
            if scenarios.get(scenario_id, {}).get("ImplementationStatus") != (
                "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"
            ):
                findings.append(Finding("BASELINE_CATALOG_STATUS_INVALID", scenario_id))
    return findings


def report(findings: list[Finding]) -> int:
    if not findings:
        print("LAB-001 Welle 2 container-baseline validation passed.")
        return 0
    for finding in findings:
        print(f"{finding.rule}: {finding.path}", file=sys.stderr)
    print(f"{len(findings)} finding(s).", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.repository_root.resolve()
    findings: list[Finding] = []
    findings.extend(validate_required_files(root))
    findings.extend(validate_compose(root))
    findings.extend(validate_scenarios(root))
    findings.extend(validate_orchestration(root))
    findings.extend(validate_status(root))
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
