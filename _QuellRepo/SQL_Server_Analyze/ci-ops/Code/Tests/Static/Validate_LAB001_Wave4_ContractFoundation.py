#!/usr/bin/env python3
"""Validate the LAB-001 Welle 4 contracts and status boundaries."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

EXPECTED_SCENARIOS = {
    "LAB-AVAIL-001", "LAB-AVAIL-002", "LAB-LS-001", "LAB-LS-002",
    "LAB-REPL-001", "LAB-REPL-002", "LAB-REPL-003", "LAB-BACKUP-001",
    "LAB-BACKUP-002", "LAB-NET-001", "LAB-NET-002", "LAB-NET-003",
    "LAB-NET-004", "LAB-AGENT-001", "LAB-BROKER-001", "LAB-DTC-001",
    "LAB-LINK-001", "LAB-MAINT-001",
}
EXPECTED_SCENARIO_STATUS = {
    scenario_id: (
        "IMPLEMENTED_ACTIONS_GATE"
        if scenario_id == "LAB-LS-001"
        else "PLANNED_NOT_IMPLEMENTED"
    )
    for scenario_id in EXPECTED_SCENARIOS
}
EXPECTED_PROFILES = {
    "W4-CTR-SINGLE": ("CTR-SINGLE", "IMPLEMENTED_ACTIONS_GATE", 1),
    "W4-CTR-PAIR": ("CTR-PAIR", "IMPLEMENTED_ACTIONS_GATE", 2),
    "W4-CTR-TRIPLE": ("CTR-TRIPLE", "IMPLEMENTED_ACTIONS_GATE", 3),
    "W4-HV-CROSS-PLATFORM-FAULT": (
        "HV-CROSS-PLATFORM", "PLANNED_NOT_IMPLEMENTED", 2
    ),
}
REQUIRED_FILES = {
    "Lab/Contracts/wave4-topology-profile.schema.json",
    "Lab/Scenarios/Infrastructure/README.md",
    "Lab/Scenarios/Infrastructure/wave4-contracts.csv",
    "Lab/Scenarios/Infrastructure/wave4-topology-profiles.json",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/scenario.json",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/runbook.json",
    "Lab/Scenarios/Catalog/scenarios.json",
    "Lab/Scenarios/Catalog/topologies.json",
    "Metadata/Inventory/Objects.csv",
    "Metadata/Quality/Lab_External_Evidence_Gates.csv",
    "Metadata/Quality/Lab_Wave_Status.csv",
}
FORBIDDEN_PATTERNS = {
    r"(?i)[A-Z]:\\Users\\": "Windows user path",
    r"(?i)/home/[^/\s]+": "Linux user path",
    r"\b(?:10|127|169\.254|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b": "private address",
    r"(?i)\b(?:docker|podman)\s+(?:system|container|image|network|volume)\s+prune\b": "broad prune",
    r"(?i)\brm\s+-rf\b": "recursive shell deletion",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def load_json(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def split(value: str) -> list[str]:
    return [item for item in value.split(";") if item]


def validate_scenarios(root: Path, findings: list[str]) -> None:
    contracts = load_csv(root / "Lab/Scenarios/Infrastructure/wave4-contracts.csv")
    contract_map = {row["ScenarioId"]: row for row in contracts}
    catalog = load_json(root / "Lab/Scenarios/Catalog/scenarios.json")
    catalog_map = {
        item["ScenarioId"]: item
        for item in catalog.get("Scenarios", [])
        if item.get("PlannedWave") == 4
    }
    require(set(contract_map) == EXPECTED_SCENARIOS, "Welle 4 contracts are incomplete.", findings)
    require(set(catalog_map) == EXPECTED_SCENARIOS, "Welle 4 catalog membership changed.", findings)
    inventory = {row["ObjectName"] for row in load_csv(root / "Metadata/Inventory/Objects.csv")}
    for scenario_id in sorted(EXPECTED_SCENARIOS):
        row = contract_map[scenario_id]
        catalog_row = catalog_map[scenario_id]
        expected_status = EXPECTED_SCENARIO_STATUS[scenario_id]
        require(row["RuntimeImplementationStatus"] == expected_status,
                f"{scenario_id}: scenario runtime status is inconsistent.", findings)
        require(catalog_row["ImplementationStatus"] == expected_status,
                f"{scenario_id}: catalog status is inconsistent.", findings)
        require(row["TopologyId"] == catalog_row["TopologyId"],
                f"{scenario_id}: topology differs from catalog.", findings)
        require(row["CleanupPolicy"] == "REGISTERED_OBJECT_IDS_ONLY",
                f"{scenario_id}: unsafe cleanup policy.", findings)
        require(len(row["StatePreconditions"]) >= 80,
                f"{scenario_id}: preconditions are too weak.", findings)
        capabilities = set(split(row["RequiredCapabilities"]))
        gates = set(split(row["ExternalEvidenceGateIds"]))
        if "NETWORK_FAULT_LAYER" in capabilities:
            require(row["RequireExplicitApproval"] == "1" and
                    row["RequireIndependentManagementPath"] == "1" and
                    "LAB-GATE-WAVE4-NETWORK-FAULT" in gates,
                    f"{scenario_id}: fault safety contract is incomplete.", findings)
        if row["DependencyStatus"] in {"AVAILABLE", "AVAILABLE_WITH_PLATFORM_LIMIT"}:
            for analyzer in split(row["PrimaryAnalyzers"]):
                require(analyzer in inventory,
                        f"{scenario_id}: analyzer {analyzer} is absent.", findings)
        elif row["DependencyStatus"] == "BLOCKED_BY_OPS_005":
            require(scenario_id == "LAB-LINK-001" and
                    split(row["PrimaryAnalyzers"]) == ["USP_LinkedServerAnalysis"] and
                    "USP_LinkedServerAnalysis" not in inventory,
                    "OPS-005 boundary is inconsistent.", findings)
        else:
            findings.append(f"{scenario_id}: unknown dependency status.")


def validate_topologies(root: Path, findings: list[str]) -> None:
    profiles = load_json(root / "Lab/Scenarios/Infrastructure/wave4-topology-profiles.json")
    require(profiles.get("ContractStatus") == "IMPLEMENTED_ACTIONS_GATE" and
            profiles.get("RuntimeStatus") == "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING" and
            profiles.get("DataClassification") == "SYNTHETIC",
            "Welle 4 topology status is invalid.", findings)
    profile_map = {item["ProfileId"]: item for item in profiles.get("TopologyProfiles", [])}
    require(set(profile_map) == set(EXPECTED_PROFILES), "Welle 4 profiles are incomplete.", findings)
    for profile_id, (topology, status, nodes) in EXPECTED_PROFILES.items():
        item = profile_map.get(profile_id, {})
        require(item.get("TopologyId") == topology and
                item.get("RuntimeImplementationStatus") == status and
                item.get("MaximumSqlNodes") == nodes,
                f"{profile_id}: implementation status is inconsistent.", findings)
        require(item.get("ManagementPathIndependent") is True and
                {"LAB_MANAGEMENT", "LAB_DATA"}.issubset(item.get("NetworkSegments", [])) and
                item.get("CleanupPolicy") == "REGISTERED_OBJECT_IDS_ONLY",
                f"{profile_id}: network or cleanup contract is invalid.", findings)


def validate_status(root: Path, findings: list[str]) -> None:
    gates = {row["GateId"]: row for row in load_csv(root / "Metadata/Quality/Lab_External_Evidence_Gates.csv")}
    multi = gates.get("LAB-GATE-WAVE4-MULTI-CONTAINER", {})
    fault = gates.get("LAB-GATE-WAVE4-NETWORK-FAULT", {})
    require(multi.get("Status") == "NOT_EXECUTED" and
            multi.get("BlockingScope") == "WAVE4_EXTERNAL_EVIDENCE_PENDING" and
            multi.get("EvidencePolicy") == "SYNTHETIC_SUMMARY_ONLY",
            "Welle 4 multi-container evidence gate is invalid.", findings)
    require(fault.get("Status") == "NOT_EXECUTED" and
            fault.get("BlockingScope") == "WAVE4_NETWORK_FAULT_RUNTIME_NOT_IMPLEMENTED",
            "Welle 4 network-fault gate is invalid.", findings)
    waves = {row["WaveId"]: row for row in load_csv(root / "Metadata/Quality/Lab_Wave_Status.csv")}
    wave = waves.get("LAB-001-WAVE4", {})
    require(wave.get("ContractStatus") == "IMPLEMENTED_ACTIONS_GATE" and
            wave.get("RuntimeStatus") == "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING" and
            "CTR-PAIR" in wave.get("DeliveredScope", "") and
            "CTR-TRIPLE" in wave.get("DeliveredScope", "") and
            "LAB-LS-001" in wave.get("DeliveredScope", "") and
            "network-fault" in wave.get("OpenScope", "").lower(),
            "Welle 4 global status is invalid.", findings)


def validate_privacy(root: Path, findings: list[str]) -> None:
    for relative in REQUIRED_FILES:
        content = (root / relative).read_text(encoding="utf-8")
        for pattern, label in FORBIDDEN_PATTERNS.items():
            require(re.search(pattern, content) is None,
                    f"{relative}: contains {label}.", findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []
    for relative in REQUIRED_FILES:
        require((root / relative).is_file(), f"Missing Welle 4 file: {relative}", findings)
    if not findings:
        validate_scenarios(root, findings)
        validate_topologies(root, findings)
        validate_status(root, findings)
        validate_privacy(root, findings)
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print("LAB-001 Welle 4 contracts validated: topologies=CTR-PAIR,CTR-TRIPLE scenarios=LAB-LS-001_ACTION_PLUS_17_PLANNED evidence=NOT_EXECUTED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
