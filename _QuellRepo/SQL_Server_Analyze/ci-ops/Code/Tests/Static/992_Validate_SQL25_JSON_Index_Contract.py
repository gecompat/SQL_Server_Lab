#!/usr/bin/env python3
"""Validate the frozen public SQL25-002 JSON-index inventory contract."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Iterable


EXPECTED_OBJECT_FIELDS = {
    "IsJsonIndex",
    "OptimizeForArraySearch",
    "JsonPathCount",
    "JsonPaths",
    "JsonIndexStatusCode",
    "JsonIndexEvidenceLimit",
}
EXPECTED_DATABASE_STATUS_FIELDS = {
    "JsonIndexStatusCode",
    "JsonIndexRowCount",
    "JsonPathRowCount",
    "JsonIndexErrorNumber",
    "JsonIndexErrorMessage",
    "JsonIndexEvidenceLimit",
}
EXPECTED_REQUIRED_CASES = {
    "unavailable-version",
    "feature-active-or-explicit-unavailable",
    "object-analysis-routing",
    "capability-inventory",
    "special-feature-routing",
    "named-table-output",
}
EXPECTED_CONDITIONAL_CASES = {
    "visible-index-and-paths",
    "empty-visible-scope",
    "restricted-metadata",
    "bounded-output",
    "special-index-inventory",
}
EXPECTED_PREREQUISITES = {
    "Compatibility level 170",
    "PREVIEW_FEATURES enabled",
    "sys.json_indexes and sys.json_index_paths exposed with required columns by the SQL Server 2025 build",
    "native json type available",
}


def require_tokens(
    text: str, tokens: Iterable[str], label: str, errors: list[str]
) -> None:
    for token in tokens:
        if token not in text:
            errors.append(f"{label}: missing token {token!r}")


def read_text(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def read_csv(root: Path, relative: str) -> list[dict[str, str]]:
    with (root / relative).open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def validate_contract_object(data: dict) -> list[str]:
    errors: list[str] = []
    expected_scalars = {
        "contractId": "SQL25-002-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-002",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.17",
        "frameworkContractVersion": "1.21",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "dedicatedProcedureAdded": False,
        "orchestrator": "monitor.USP_ObjectAnalysis",
        "capabilityFeature": "JSON_INDEX_METADATA",
        "documentation": "Documentation/Architecture/SQL_Server_2025_JSON_Index_Inventory.md",
    }
    for key, expected in expected_scalars.items():
        if data.get(key) != expected:
            errors.append(f"contract: {key} must be {expected!r}")

    if set(data.get("procedures", [])) != {
        "monitor.USP_ObjectInventory",
        "monitor.USP_ServerFeatureCapabilities",
    }:
        errors.append("contract: procedures must contain the two existing inventory paths")
    if set(data.get("objectInventoryFields", [])) != EXPECTED_OBJECT_FIELDS:
        errors.append("contract: objectInventoryFields do not match the frozen fields")
    if set(data.get("databaseStatusFields", [])) != EXPECTED_DATABASE_STATUS_FIELDS:
        errors.append("contract: databaseStatusFields do not match the frozen fields")

    runtime = data.get("runtimeMatrix", {})
    if runtime.get("productMajorVersions") != [15, 16, 17]:
        errors.append("contract: productMajorVersions must be [15, 16, 17]")
    if set(runtime.get("requiredCases", [])) != EXPECTED_REQUIRED_CASES:
        errors.append("contract: runtimeMatrix.requiredCases is incomplete")
    if set(runtime.get("capabilityConditionalCases", [])) != EXPECTED_CONDITIONAL_CASES:
        errors.append("contract: runtimeMatrix.capabilityConditionalCases is incomplete")
    if set(runtime.get("activationPrerequisites", [])) != EXPECTED_PREREQUISITES:
        errors.append("contract: runtimeMatrix.activationPrerequisites is incomplete")

    sources = {item.get("object"): item for item in data.get("sources", [])}
    for source in ("sys.json_indexes", "sys.json_index_paths"):
        row = sources.get(source)
        if not row:
            errors.append(f"contract: missing source {source}")
        elif row.get("maximumReadsPerDatabaseInvocationAndProcedure") != 1:
            errors.append(f"contract: {source} must have a one-read invariant")

    privacy = data.get("privacy", {})
    for key in (
        "jsonDocumentValuesCollected",
        "userTableRowsRead",
        "queryTextCollected",
        "planXmlCollected",
    ):
        if privacy.get(key) is not False:
            errors.append(f"contract: privacy.{key} must be false")
    if privacy.get("jsonPathMetadataCollected") is not True:
        errors.append("contract: privacy.jsonPathMetadataCollected must be true")
    if len(data.get("falsePositiveBoundaries", [])) < 4:
        errors.append("contract: false-positive boundaries are incomplete")
    return errors


def validate_repository(root: Path) -> list[str]:
    errors: list[str] = []
    contract_path = root / "Metadata/Quality/SQL25_JSON_Index_Public_Contract.json"
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"contract: cannot read valid JSON: {exc}"]
    errors.extend(validate_contract_object(contract))

    inventory = read_text(root, "Code/03_ObjectIndex/010_USP_ObjectInventory.sql")
    require_tokens(
        inventory,
        (
            "@ProductMajorVersion IS NULL OR @ProductMajorVersion<17",
            "@JsonIndexesSchemaValid",
            "@JsonIndexPathsSchemaValid",
            "#ObjectInventory_JsonIndexes",
            "#ObjectInventory_JsonPathAgg",
            "UNAVAILABLE_VERSION",
            "UNAVAILABLE_FEATURE",
            "UNAVAILABLE_SOURCE_SCHEMA",
            "AVAILABLE_EMPTY_OR_RESTRICTED",
            "AVAILABLE_LIMITED",
            "DENIED_PERMISSION",
            "TIMEOUT",
            "IsJsonIndex",
            "OptimizeForArraySearch",
            "JsonPathCount",
            "JsonPaths",
            "JsonIndexStatusCode",
            "JsonIndexEvidenceLimit",
            "@OriginalLockTimeout",
        ),
        "object inventory",
        errors,
    )
    if inventory.count("FROM [sys].[json_indexes]") != 1:
        errors.append("object inventory: sys.json_indexes must have one source read")
    if inventory.count("FROM [sys].[json_index_paths]") != 1:
        errors.append("object inventory: sys.json_index_paths must have one source read")

    capabilities = read_text(
        root, "Code/09_VersionAdaptive/010_USP_ServerFeatureCapabilities.sql"
    )
    require_tokens(
        capabilities,
        (
            "JSON_INDEX_METADATA",
            "@Major",
            "@JsonIndexesSchemaValid",
            "@JsonIndexPathsSchemaValid",
            "CASE WHEN @HasJsonIndexPaths=1 AND @JsonIndexPathsSchemaValid=1",
            "N''JSON''",
            "path_count=",
            "UNAVAILABLE_VERSION",
            "UNAVAILABLE_FEATURE",
            "UNAVAILABLE_SOURCE_SCHEMA",
            "AVAILABLE_EMPTY_OR_RESTRICTED",
            "AVAILABLE_LIMITED",
            "@OriginalLockTimeout",
        ),
        "feature capabilities",
        errors,
    )
    if capabilities.count("FROM [sys].[json_indexes]") != 2:
        errors.append(
            "feature capabilities: the two exclusive path-available/path-unavailable "
            "branches must each contain one sys.json_indexes read"
        )
    if capabilities.count("FROM [sys].[json_index_paths]") != 1:
        errors.append("feature capabilities: sys.json_index_paths must have one source read")

    for product_text, label in (
        (inventory, "object inventory"),
        (capabilities, "feature capabilities"),
    ):
        for forbidden in (
            "[Payload]",
            "JSON_VALUE([Payload]",
            "OPENJSON([Payload]",
            "FROM [dbo].[",
        ):
            if forbidden in product_text:
                errors.append(f"{label}: forbidden user-payload token {forbidden!r}")

    orchestrator = read_text(root, "Code/03_ObjectIndex/080_USP_ObjectAnalysis.sql")
    require_tokens(
        orchestrator,
        (
            "SQL25-002",
            "EXEC [monitor].[USP_ObjectInventory]",
            '"objectInventory"',
        ),
        "object-analysis routing",
        errors,
    )

    special = read_text(
        root, "Code/09_VersionAdaptive/020_USP_SpecialFeatureInventory.sql"
    )
    require_tokens(
        special,
        (
            "JSON-Index- und Pfadmetadaten",
            "N''USP_ObjectInventory''",
            "''IMPLEMENTED''",
            "@OriginalLockTimeout",
        ),
        "special-feature inventory",
        errors,
    )

    release_gate = read_text(root, "Code/Tests/Run_Release_Gate.sql")
    if (
        release_gate.count(
            ":r ObjectIndex/121_SQL25_JSON_Index_Inventory_Runtime_Contract.sql"
        )
        != 1
    ):
        errors.append("release gate: SQL25-002 runtime contract must run exactly once")

    runtime_test = read_text(
        root, "Code/Tests/ObjectIndex/121_SQL25_JSON_Index_Inventory_Runtime_Contract.sql"
    )
    require_tokens(
        runtime_test,
        (
            "UNAVAILABLE-VERSION",
            "FEATURE-UNAVAILABLE-EXPLICIT",
            "VISIBLE-INDEX-AND-PATHS",
            "EMPTY-VISIBLE-SCOPE",
            "RESTRICTED-METADATA",
            "BOUNDED-OUTPUT",
            "SPECIAL-INDEX-INVENTORY",
            "CAPABILITY-INVENTORY",
            "SPECIAL-FEATURE-ROUTING",
            "OBJECT-ANALYSIS-ROUTING",
            "NAMED-TABLE-OUTPUT",
            "CREATE JSON INDEX",
            "ExampleJsonIndexA",
            "PREVIEW_FEATURES=OFF",
            "SET COMPATIBILITY_LEVEL=",
            "stellt LOCK_TIMEOUT nicht wieder her",
        ),
        "runtime contract",
        errors,
    )
    if any(
        token in runtime_test
        for token in ("http://", "https://", "C:\\", "/home/", "INSERT [dbo].[ExampleJson")
    ):
        errors.append("runtime contract: locator or JSON-document row insertion detected")

    result_rows = [
        row
        for row in read_csv(root, "Metadata/Inventory/ResultSets.csv")
        if row.get("ProcedureName") == "USP_ObjectInventory"
        and row.get("ResultName") == "objects"
    ]
    if len(result_rows) != 1:
        errors.append("inventory: ObjectInventory objects result must exist exactly once")
    else:
        schema = result_rows[0].get("SourceSchema", "")
        for field in EXPECTED_OBJECT_FIELDS:
            if f"[{field}]" not in schema:
                errors.append(f"inventory: ObjectInventory schema is missing {field}")

    source_rows = {
        row.get("SystemSource"): row
        for row in read_csv(root, "Metadata/Inventory/SystemSources.csv")
    }
    for source in ("sys.json_indexes", "sys.json_index_paths"):
        row = source_rows.get(source)
        modules = row.get("FrameworkModules", "") if row else ""
        if (
            "010_USP_ObjectInventory.sql" not in modules
            or "010_USP_ServerFeatureCapabilities.sql" not in modules
        ):
            errors.append(f"inventory: missing module mapping for {source}")

    for procedure_path in (root / "Code").glob("**/*.sql"):
        if "Tests" in procedure_path.parts:
            continue
        procedure_text = procedure_path.read_text(encoding="utf-8-sig")
        if "CREATE OR ALTER PROCEDURE [monitor].[USP_JsonIndex" in procedure_text:
            errors.append(
                "inventory: SQL25-002 must not add a dedicated JSON-index procedure"
            )
            break

    backlog = read_text(root, "Metadata/Quality/Future_Enhancement_Backlog.csv")
    implementation = read_text(root, "Metadata/Quality/Implementation_Status.csv")
    require_tokens(
        backlog,
        ("SQL25-002", "IMPLEMENTED_ACTIONS_GATE"),
        "backlog",
        errors,
    )
    require_tokens(
        implementation,
        (
            "SQL25-002,IMPLEMENTED_ACTIONS_GATE",
            "Documentation/Architecture/SQL_Server_2025_JSON_Index_Inventory.md",
        ),
        "implementation status",
        errors,
    )

    catalog = read_text(root, "Code/01_Common/021_VW_AnalysisCatalog.sql")
    search = read_text(root, "Code/01_Common/022_VW_AnalysisSearchTerm.sql")
    require_tokens(
        catalog,
        (
            "JSON-Index",
            "USP_ObjectInventory",
            "USP_ServerFeatureCapabilities",
        ),
        "navigator catalog",
        errors,
    )
    if search.count("JSON-Index") < 2 or search.count("json index") < 2:
        errors.append("navigator: JSON-index search terms must cover both routes and languages")
    navigator_validator = read_text(
        root, "Code/Tests/Static/905_Validate_Analysis_Navigator.py"
    )
    navigator_runtime = read_text(
        root, "Code/Tests/Integration/196_Analysis_Navigator_Runtime_Contract.sql"
    )
    for text, label in (
        (navigator_validator, "navigator static contract"),
        (navigator_runtime, "navigator runtime contract"),
    ):
        require_tokens(
            text,
            (
                "JSON-Index Pfade inventarisieren",
                "JSON-Index Capability Preview",
            ),
            label,
            errors,
        )

    framework = read_text(root, "Code/01_Common/077_FrameworkVersion.sql")
    require_tokens(
        framework,
        ("1.1.0-special.19", "[ContractVersion]='1.23'", "SQL25-004"),
        "version",
        errors,
    )

    documentation = read_text(
        root, "Documentation/Architecture/SQL_Server_2025_JSON_Index_Inventory.md"
    )
    require_tokens(
        documentation,
        (
            "sys.json_indexes",
            "sys.json_index_paths",
            "keine eigene JSON-Index-Procedure",
            "kein Health-",
            "JSON-Dokumentwerte",
            "IMPLEMENTED_ACTIONS_GATE",
        ),
        "architecture documentation",
        errors,
    )

    workflow = read_text(root, ".github/workflows/documentation-validation.yml")
    require_tokens(
        workflow,
        (
            "992_Validate_SQL25_JSON_Index_Contract.py",
            "SQL25_JSON_Index_Public_Contract.json",
            "Validate SQL25-002 JSON-index contract",
        ),
        "documentation workflow",
        errors,
    )
    return errors


def run_self_test() -> None:
    valid = {
        "contractId": "SQL25-002-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-002",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.17",
        "frameworkContractVersion": "1.21",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "dedicatedProcedureAdded": False,
        "procedures": [
            "monitor.USP_ObjectInventory",
            "monitor.USP_ServerFeatureCapabilities",
        ],
        "orchestrator": "monitor.USP_ObjectAnalysis",
        "objectInventoryFields": sorted(EXPECTED_OBJECT_FIELDS),
        "databaseStatusFields": sorted(EXPECTED_DATABASE_STATUS_FIELDS),
        "capabilityFeature": "JSON_INDEX_METADATA",
        "documentation": "Documentation/Architecture/SQL_Server_2025_JSON_Index_Inventory.md",
        "sources": [
            {
                "object": "sys.json_indexes",
                "maximumReadsPerDatabaseInvocationAndProcedure": 1,
            },
            {
                "object": "sys.json_index_paths",
                "maximumReadsPerDatabaseInvocationAndProcedure": 1,
            },
        ],
        "privacy": {
            "jsonDocumentValuesCollected": False,
            "userTableRowsRead": False,
            "queryTextCollected": False,
            "planXmlCollected": False,
            "jsonPathMetadataCollected": True,
        },
        "falsePositiveBoundaries": ["a", "b", "c", "d"],
        "runtimeMatrix": {
            "productMajorVersions": [15, 16, 17],
            "requiredCases": sorted(EXPECTED_REQUIRED_CASES),
            "capabilityConditionalCases": sorted(EXPECTED_CONDITIONAL_CASES),
            "activationPrerequisites": sorted(EXPECTED_PREREQUISITES),
        },
    }
    if validate_contract_object(valid):
        raise AssertionError("self-test valid fixture was rejected")
    invalid = json.loads(json.dumps(valid))
    invalid["privacy"]["jsonDocumentValuesCollected"] = True
    if not validate_contract_object(invalid):
        raise AssertionError("self-test invalid fixture was accepted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        print("SQL25-002 validator self-test passed.")
        return 0
    errors = validate_repository(args.repository_root.resolve())
    if errors:
        for error in sorted(set(errors)):
            print(error, file=sys.stderr)
        return 1
    print("SQL25-002 JSON-index public contract passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
