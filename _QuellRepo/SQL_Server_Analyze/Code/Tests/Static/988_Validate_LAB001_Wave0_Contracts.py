#!/usr/bin/env python3
"""Validate the static LAB-001 Welle 0 contracts without runtime access."""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SCHEMA_URI = "https://json-schema.org/draft/2020-12/schema"
SCENARIO_ID_PATTERN = re.compile(r"^LAB-[A-Z0-9]+-[0-9]{3}$")
PROCEDURE_PATTERN = re.compile(r"^USP_[A-Za-z0-9]+$")
EXPECTED_PUBLIC_PROCEDURE_COUNT = 97

SCHEMA_FILES = (
    "lab-config.schema.json",
    "host-capability.schema.json",
    "topology.schema.json",
    "scenario.schema.json",
    "evidence.schema.json",
    "finding-expectation.schema.json",
)

INSTANCE_SCHEMA_PAIRS = (
    (
        "Lab/Validation/Fixtures/Valid/lab-config.example.json",
        "Lab/Contracts/lab-config.schema.json",
    ),
    (
        "Lab/Config/host-capabilities.example.json",
        "Lab/Contracts/host-capability.schema.json",
    ),
    (
        "Lab/Validation/Fixtures/Valid/topology.example.json",
        "Lab/Contracts/topology.schema.json",
    ),
    (
        "Lab/Validation/Fixtures/Valid/scenario.example.json",
        "Lab/Contracts/scenario.schema.json",
    ),
    (
        "Lab/Validation/Fixtures/Valid/evidence.example.json",
        "Lab/Contracts/evidence.schema.json",
    ),
    (
        "Lab/Validation/Fixtures/Valid/finding-expectation.example.json",
        "Lab/Contracts/finding-expectation.schema.json",
    ),
)

COVERAGE_HEADER = (
    "ProcedureName",
    "PositiveScenarioIds",
    "PositiveEvidenceClass",
    "FixtureReasonCode",
    "BaselineScenarioId",
    "PermissionScenarioId",
    "UnsupportedScenarioId",
    "ErrorIsolationScenarioId",
    "OutputContractScenarioId",
    "CleanupScenarioId",
    "CoverageStatus",
)

FORBIDDEN_LAB_PREFIXES = (
    "Lab/.artifacts/",
    "Lab/.cache/",
    "Lab/.secrets/",
    "Lab/.state/",
    "Lab/HyperV/Images/output-",
)
FORBIDDEN_LAB_SUFFIXES = (
    ".avhdx",
    ".bak",
    ".cer",
    ".iso",
    ".key",
    ".log",
    ".pfx",
    ".sqlplan",
    ".trn",
    ".vhd",
    ".vhdx",
    ".xel",
)
@dataclass(frozen=True)
class Finding:
    rule: str
    path: str


def load_json(path: Path, findings: list[Finding]) -> Any | None:
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


def json_type_matches(value: Any, expected_type: str) -> bool:
    if expected_type == "object":
        return isinstance(value, dict)
    if expected_type == "array":
        return isinstance(value, list)
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "integer":
        return type(value) is int
    if expected_type == "number":
        return type(value) in (int, float)
    if expected_type == "boolean":
        return type(value) is bool
    if expected_type == "null":
        return value is None
    return False


def resolve_local_ref(root_schema: dict[str, Any], reference: str) -> Any | None:
    if not reference.startswith("#/"):
        return None
    current: Any = root_schema
    for part in reference[2:].split("/"):
        key = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def validate_json_schema(
    instance: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    logical_path: str,
) -> list[Finding]:
    findings: list[Finding] = []

    reference = schema.get("$ref")
    if isinstance(reference, str):
        resolved = resolve_local_ref(root_schema, reference)
        if not isinstance(resolved, dict):
            return [Finding("SCHEMA_REF_UNRESOLVED", logical_path)]
        return validate_json_schema(instance, resolved, root_schema, logical_path)

    expected_type = schema.get("type")
    if isinstance(expected_type, str) and not json_type_matches(instance, expected_type):
        return [Finding("SCHEMA_TYPE_MISMATCH", logical_path)]

    if "const" in schema and instance != schema["const"]:
        findings.append(Finding("SCHEMA_CONST_MISMATCH", logical_path))
    if isinstance(schema.get("enum"), list) and instance not in schema["enum"]:
        findings.append(Finding("SCHEMA_ENUM_MISMATCH", logical_path))

    if isinstance(instance, dict):
        required = schema.get("required", [])
        if isinstance(required, list):
            for key in required:
                if key not in instance:
                    findings.append(Finding("SCHEMA_REQUIRED_MISSING", f"{logical_path}/{key}"))

        properties = schema.get("properties", {})
        if isinstance(properties, dict):
            if schema.get("additionalProperties") is False:
                for key in instance:
                    if key not in properties:
                        findings.append(
                            Finding("SCHEMA_ADDITIONAL_PROPERTY", f"{logical_path}/{key}")
                        )
            for key, value in instance.items():
                child_schema = properties.get(key)
                if isinstance(child_schema, dict):
                    findings.extend(
                        validate_json_schema(
                            value,
                            child_schema,
                            root_schema,
                            f"{logical_path}/{key}",
                        )
                    )

    if isinstance(instance, list):
        minimum_items = schema.get("minItems")
        if isinstance(minimum_items, int) and len(instance) < minimum_items:
            findings.append(Finding("SCHEMA_MIN_ITEMS", logical_path))
        if schema.get("uniqueItems") is True:
            serialized = [json.dumps(item, sort_keys=True) for item in instance]
            if len(serialized) != len(set(serialized)):
                findings.append(Finding("SCHEMA_UNIQUE_ITEMS", logical_path))
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, value in enumerate(instance):
                findings.extend(
                    validate_json_schema(
                        value,
                        item_schema,
                        root_schema,
                        f"{logical_path}/{index}",
                    )
                )

    if isinstance(instance, str):
        minimum_length = schema.get("minLength")
        if isinstance(minimum_length, int) and len(instance) < minimum_length:
            findings.append(Finding("SCHEMA_MIN_LENGTH", logical_path))
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.fullmatch(pattern, instance) is None:
            findings.append(Finding("SCHEMA_PATTERN_MISMATCH", logical_path))

    if type(instance) in (int, float):
        minimum = schema.get("minimum")
        if type(minimum) in (int, float) and instance < minimum:
            findings.append(Finding("SCHEMA_MINIMUM", logical_path))

    return findings


def validate_schemas(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    schema_root = repository_root / "Lab/Contracts"

    for name in SCHEMA_FILES:
        path = schema_root / name
        schema = load_json(path, findings)
        if not isinstance(schema, dict):
            continue
        if schema.get("$schema") != SCHEMA_URI:
            findings.append(Finding("SCHEMA_DRAFT_INVALID", path.as_posix()))
        if schema.get("type") != "object":
            findings.append(Finding("SCHEMA_ROOT_TYPE_INVALID", path.as_posix()))
        if schema.get("additionalProperties") is not False:
            findings.append(Finding("SCHEMA_ROOT_NOT_CLOSED", path.as_posix()))

    for instance_relative, schema_relative in INSTANCE_SCHEMA_PAIRS:
        instance_path = repository_root / instance_relative
        schema_path = repository_root / schema_relative
        instance = load_json(instance_path, findings)
        schema = load_json(schema_path, findings)
        if instance is None or not isinstance(schema, dict):
            continue
        findings.extend(
            validate_json_schema(instance, schema, schema, instance_relative)
        )

    topology_catalog_path = repository_root / "Lab/Scenarios/Catalog/topologies.json"
    topology_catalog = load_json(topology_catalog_path, findings)
    topology_schema = load_json(
        repository_root / "Lab/Contracts/topology.schema.json", findings
    )
    if isinstance(topology_catalog, dict) and isinstance(topology_schema, dict):
        topologies = topology_catalog.get("Topologies")
        if not isinstance(topologies, list):
            findings.append(Finding("TOPOLOGY_CATALOG_INVALID", topology_catalog_path.as_posix()))
        else:
            for index, topology in enumerate(topologies):
                findings.extend(
                    validate_json_schema(
                        topology,
                        topology_schema,
                        topology_schema,
                        f"Lab/Scenarios/Catalog/topologies.json/Topologies/{index}",
                    )
                )

    return findings


def validate_resource_profiles(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    path = repository_root / "Lab/Config/resource-profiles.json"
    manifest = load_json(path, findings)
    if not isinstance(manifest, dict):
        return findings

    host_classes = manifest.get("HostClasses")
    expected_classes = ("HC1_COMPACT", "HC2_STANDARD", "HC3_EXTENDED")
    if not isinstance(host_classes, list):
        return [*findings, Finding("HOST_CLASSES_INVALID", path.as_posix())]

    class_ids = tuple(item.get("HostClassId") for item in host_classes if isinstance(item, dict))
    if class_ids != expected_classes:
        findings.append(Finding("HOST_CLASS_IDS_INVALID", path.as_posix()))

    for field in (
        "MinimumLogicalProcessors",
        "MinimumPhysicalMemoryMiB",
        "MinimumApprovedFreeStorageGiB",
    ):
        values = [item.get(field) for item in host_classes if isinstance(item, dict)]
        if not all(type(value) is int for value in values):
            findings.append(Finding("HOST_CLASS_THRESHOLD_INVALID", f"{path.as_posix()}/{field}"))
        elif values != sorted(values) or len(set(values)) != len(values):
            findings.append(Finding("HOST_CLASS_THRESHOLD_NOT_MONOTONIC", f"{path.as_posix()}/{field}"))

    profiles = manifest.get("ResourceProfiles")
    if not isinstance(profiles, list):
        return [*findings, Finding("RESOURCE_PROFILES_INVALID", path.as_posix())]
    profile_map = {
        item.get("ResourceProfileId"): item
        for item in profiles
        if isinstance(item, dict)
    }
    if set(profile_map) != {"Compact", "Standard", "Stress"}:
        findings.append(Finding("RESOURCE_PROFILE_IDS_INVALID", path.as_posix()))
    if profile_map.get("Stress", {}).get("RequiresExplicitBudget") is not True:
        findings.append(Finding("STRESS_BUDGET_NOT_EXPLICIT", path.as_posix()))

    for profile_id in ("Compact", "Standard"):
        roles = profile_map.get(profile_id, {}).get("Roles", {})
        if not isinstance(roles, dict):
            findings.append(Finding("RESOURCE_ROLE_MAP_INVALID", f"{path.as_posix()}/{profile_id}"))
            continue
        for role_id, budget in roles.items():
            if not isinstance(budget, dict):
                findings.append(Finding("RESOURCE_BUDGET_INVALID", f"{path.as_posix()}/{profile_id}/{role_id}"))
                continue
            sql_limit = budget.get("SqlMemoryLimitMiB")
            memory = budget.get("MemoryMiB")
            if sql_limit is not None and (
                type(sql_limit) is not int
                or type(memory) is not int
                or sql_limit >= memory
            ):
                findings.append(
                    Finding(
                        "SQL_MEMORY_LIMIT_NOT_BELOW_ROLE_LIMIT",
                        f"{path.as_posix()}/{profile_id}/{role_id}",
                    )
                )

    return findings


def validate_catalogs(repository_root: Path) -> tuple[list[Finding], set[str]]:
    findings: list[Finding] = []
    topology_path = repository_root / "Lab/Scenarios/Catalog/topologies.json"
    scenario_path = repository_root / "Lab/Scenarios/Catalog/scenarios.json"
    topology_catalog = load_json(topology_path, findings)
    scenario_catalog = load_json(scenario_path, findings)
    if not isinstance(topology_catalog, dict) or not isinstance(scenario_catalog, dict):
        return findings, set()

    topology_items = topology_catalog.get("Topologies", [])
    topology_ids = [
        item.get("TopologyId")
        for item in topology_items
        if isinstance(item, dict)
    ]
    if len(topology_ids) != len(set(topology_ids)):
        findings.append(Finding("TOPOLOGY_ID_DUPLICATE", topology_path.as_posix()))

    scenario_items = scenario_catalog.get("Scenarios", [])
    if not isinstance(scenario_items, list) or len(scenario_items) < 90:
        findings.append(Finding("SCENARIO_CATALOG_INCOMPLETE", scenario_path.as_posix()))
        return findings, set()

    scenario_ids: list[str] = []
    for index, item in enumerate(scenario_items):
        item_path = f"{scenario_path.as_posix()}/Scenarios/{index}"
        if not isinstance(item, dict):
            findings.append(Finding("SCENARIO_CATALOG_ROW_INVALID", item_path))
            continue
        scenario_id = item.get("ScenarioId")
        if not isinstance(scenario_id, str) or SCENARIO_ID_PATTERN.fullmatch(scenario_id) is None:
            findings.append(Finding("SCENARIO_ID_INVALID", item_path))
        else:
            scenario_ids.append(scenario_id)
        if item.get("TopologyId") not in topology_ids:
            findings.append(Finding("SCENARIO_TOPOLOGY_UNKNOWN", item_path))
        wave = item.get("PlannedWave")
        if type(wave) is not int or not 0 <= wave <= 10:
            findings.append(Finding("SCENARIO_WAVE_INVALID", item_path))
        if item.get("ImplementationStatus") not in {
            "PLANNED_NOT_IMPLEMENTED",
            "PLANNED_FIXTURE_NOT_IMPLEMENTED",
            "WAVE0_CONTRACT_ONLY",
            "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING",
            "IMPLEMENTED_ACTIONS_GATE",
            "IMPLEMENTED_CONTRACT_FIXTURE",
        }:
            findings.append(Finding("SCENARIO_STATUS_INVALID", item_path))

    if len(scenario_ids) != len(set(scenario_ids)):
        findings.append(Finding("SCENARIO_ID_DUPLICATE", scenario_path.as_posix()))
    if scenario_catalog.get("ProductStatus") != "PARTIAL_PRODUCT_FUNCTION":
        findings.append(Finding("LAB_PRODUCT_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave0ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE0_CONTRACT_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave1ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE1_CONTRACT_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave2ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE2_CONTRACT_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave3ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE3_CONTRACT_STATUS_INVALID", scenario_path.as_posix()))
    if (
        scenario_catalog.get("Wave3RuntimeStatus")
        != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"
    ):
        findings.append(Finding("WAVE3_RUNTIME_STATUS_INVALID", scenario_path.as_posix()))

    return findings, set(scenario_ids)


def split_scenario_ids(value: str) -> list[str]:
    return [item for item in value.split(";") if item]


def validate_coverage(
    repository_root: Path,
    scenario_ids: set[str],
    skip_inventory: bool,
) -> list[Finding]:
    findings: list[Finding] = []
    lab_path = repository_root / "Lab/Scenarios/Catalog/coverage.csv"
    quality_path = repository_root / "Metadata/Quality/Lab_Scenario_Coverage.csv"

    try:
        if lab_path.read_bytes() != quality_path.read_bytes():
            findings.append(Finding("COVERAGE_COPIES_DIFFER", quality_path.as_posix()))
    except OSError:
        findings.append(Finding("COVERAGE_FILE_MISSING", quality_path.as_posix()))
        return findings

    rows = load_csv(quality_path, findings)
    try:
        with quality_path.open("r", encoding="utf-8", newline="") as stream:
            reader = csv.reader(stream)
            header = tuple(next(reader))
    except (OSError, csv.Error, StopIteration):
        return [*findings, Finding("COVERAGE_HEADER_INVALID", quality_path.as_posix())]
    if header != COVERAGE_HEADER:
        findings.append(Finding("COVERAGE_HEADER_INVALID", quality_path.as_posix()))

    procedure_names: list[str] = []
    scenario_columns = (
        "PositiveScenarioIds",
        "BaselineScenarioId",
        "PermissionScenarioId",
        "UnsupportedScenarioId",
        "ErrorIsolationScenarioId",
        "OutputContractScenarioId",
        "CleanupScenarioId",
    )
    for index, row in enumerate(rows, 2):
        row_path = f"{quality_path.as_posix()}:{index}"
        name = row.get("ProcedureName", "")
        if PROCEDURE_PATTERN.fullmatch(name) is None:
            findings.append(Finding("COVERAGE_PROCEDURE_INVALID", row_path))
        else:
            procedure_names.append(name)

        for column in scenario_columns:
            references = split_scenario_ids(row.get(column, ""))
            if not references:
                findings.append(Finding("COVERAGE_SCENARIO_REQUIRED", f"{row_path}/{column}"))
            for reference in references:
                if reference not in scenario_ids:
                    findings.append(Finding("COVERAGE_SCENARIO_UNKNOWN", f"{row_path}/{column}"))

        evidence_class = row.get("PositiveEvidenceClass")
        fixture_reason = row.get("FixtureReasonCode")
        if evidence_class == "CONTRACT_FIXTURE" and not fixture_reason:
            findings.append(Finding("COVERAGE_FIXTURE_REASON_REQUIRED", row_path))
        if evidence_class != "CONTRACT_FIXTURE" and fixture_reason:
            findings.append(Finding("COVERAGE_FIXTURE_REASON_UNEXPECTED", row_path))
        if row.get("CoverageStatus") != "PLANNED_COMPLETE":
            findings.append(Finding("COVERAGE_STATUS_INVALID", row_path))

    if len(procedure_names) != len(set(procedure_names)):
        findings.append(Finding("COVERAGE_PROCEDURE_DUPLICATE", quality_path.as_posix()))
    if len(procedure_names) != EXPECTED_PUBLIC_PROCEDURE_COUNT:
        findings.append(Finding("COVERAGE_PROCEDURE_COUNT_INVALID", quality_path.as_posix()))

    if not skip_inventory:
        inventory_path = repository_root / "Metadata/Inventory/Objects.csv"
        inventory_rows = load_csv(inventory_path, findings)
        inventory_procedures = {
            row.get("ObjectName", "")
            for row in inventory_rows
            if row.get("ObjectType") == "PROCEDURE"
        }
        if set(procedure_names) != inventory_procedures:
            findings.append(Finding("COVERAGE_INVENTORY_MISMATCH", quality_path.as_posix()))

    return findings


def validate_status_and_gates(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    gate_path = repository_root / "Metadata/Quality/Lab_External_Evidence_Gates.csv"
    wave_path = repository_root / "Metadata/Quality/Lab_Wave_Status.csv"
    status_path = repository_root / "Metadata/Quality/Implementation_Status.csv"

    gate_rows = load_csv(gate_path, findings)
    gate_ids = [row.get("GateId") for row in gate_rows]
    if not gate_rows or len(gate_ids) != len(set(gate_ids)):
        findings.append(Finding("EXTERNAL_GATE_IDS_INVALID", gate_path.as_posix()))
    for index, row in enumerate(gate_rows, 2):
        if row.get("Status") != "NOT_EXECUTED":
            findings.append(Finding("EXTERNAL_GATE_RUNTIME_OVERSTATED", f"{gate_path.as_posix()}:{index}"))
        if row.get("EvidencePolicy") != "SYNTHETIC_SUMMARY_ONLY":
            findings.append(Finding("EXTERNAL_GATE_PRIVACY_POLICY_INVALID", f"{gate_path.as_posix()}:{index}"))

    wave_rows = load_csv(wave_path, findings)
    wave_map = {row.get("WaveId"): row for row in wave_rows}
    expected_wave_ids = {f"LAB-001-WAVE{number}" for number in range(11)}
    if set(wave_map) != expected_wave_ids:
        findings.append(Finding("WAVE_STATUS_SET_INVALID", wave_path.as_posix()))
    wave_zero = wave_map.get("LAB-001-WAVE0", {})
    if wave_zero.get("ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE0_STATUS_INVALID", wave_path.as_posix()))
    if wave_zero.get("RuntimeStatus") != "NOT_EXECUTED":
        findings.append(Finding("WAVE0_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_one = wave_map.get("LAB-001-WAVE1", {})
    if wave_one.get("ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE1_STATUS_INVALID", wave_path.as_posix()))
    if wave_one.get("RuntimeStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE1_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_two = wave_map.get("LAB-001-WAVE2", {})
    if wave_two.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE2_STATUS_INVALID", wave_path.as_posix()))
    if wave_two.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE2_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_three = wave_map.get("LAB-001-WAVE3", {})
    if wave_three.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE3_STATUS_INVALID", wave_path.as_posix()))
    if wave_three.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE3_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_four = wave_map.get("LAB-001-WAVE4", {})
    if wave_four.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE4_STATUS_INVALID", wave_path.as_posix()))
    if wave_four.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE4_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    for number in range(5, 11):
        if wave_map.get(f"LAB-001-WAVE{number}", {}).get("ContractStatus") != "PLANNED":
            findings.append(Finding("FUTURE_WAVE_STATUS_INVALID", wave_path.as_posix()))
        if wave_map.get(f"LAB-001-WAVE{number}", {}).get("RuntimeStatus") != "NOT_EXECUTED":
            findings.append(Finding("FUTURE_WAVE_RUNTIME_STATUS_INVALID", wave_path.as_posix()))

    status_rows = load_csv(status_path, findings)
    lab_rows = [row for row in status_rows if row.get("WorkItemId") == "LAB-001"]
    if len(lab_rows) != 1:
        findings.append(Finding("IMPLEMENTATION_STATUS_ROW_INVALID", status_path.as_posix()))
    elif lab_rows[0].get("ProductStatus") != "PARTIAL_PRODUCT_FUNCTION":
        findings.append(Finding("IMPLEMENTATION_STATUS_INVALID", status_path.as_posix()))

    return findings


def tracked_or_present_paths(repository_root: Path) -> list[str]:
    if (repository_root / ".git").exists():
        try:
            result = subprocess.run(
                ["git", "-C", str(repository_root), "ls-files", "-z"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            return [
                item.decode("utf-8")
                for item in result.stdout.split(b"\0")
                if item
            ]
        except (OSError, subprocess.CalledProcessError):
            pass
    return [
        path.relative_to(repository_root).as_posix()
        for path in repository_root.rglob("*")
        if path.is_file()
    ]


def validate_lab_privacy_boundary(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    paths = tracked_or_present_paths(repository_root)
    for path in paths:
        if path == "Lab/Config/lab.config.psd1":
            findings.append(Finding("LOCAL_LAB_CONFIG_TRACKED", path))
        if any(path.startswith(prefix) for prefix in FORBIDDEN_LAB_PREFIXES):
            findings.append(Finding("LAB_RUNTIME_PATH_TRACKED", path))
        if path.startswith("Lab/") and path.lower().endswith(FORBIDDEN_LAB_SUFFIXES):
            findings.append(Finding("LAB_RUNTIME_ARTIFACT_TRACKED", path))
    return findings


def report(findings: Iterable[Finding]) -> int:
    ordered = sorted(set(findings), key=lambda item: (item.rule, item.path))
    for finding in ordered:
        safe_path = json.dumps(finding.path, ensure_ascii=True)
        print(f"LAB-001 Welle 0 finding: rule={finding.rule} path={safe_path}")
    if ordered:
        print(f"LAB-001 Welle 0 validation failed: findings={len(ordered)}")
        return 1
    print("LAB-001 Welle 0 validation passed: findings=0")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--skip-inventory",
        action="store_true",
        help="Skip only the Objects.csv set comparison for an isolated fixture tree.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repository_root = args.repository_root.resolve()
    findings: list[Finding] = []
    findings.extend(validate_schemas(repository_root))
    findings.extend(validate_resource_profiles(repository_root))
    catalog_findings, scenario_ids = validate_catalogs(repository_root)
    findings.extend(catalog_findings)
    findings.extend(
        validate_coverage(repository_root, scenario_ids, args.skip_inventory)
    )
    findings.extend(validate_status_and_gates(repository_root))
    findings.extend(validate_lab_privacy_boundary(repository_root))
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
