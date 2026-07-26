#!/usr/bin/env python3
"""Validate the frozen public SQL25-001 Vector-index analysis contract."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Iterable


EXPECTED_RESULTS = {
    "moduleStatus",
    "vectorIndexes",
    "maintenance",
    "findings",
    "sourceStatus",
    "warnings",
}
EXPECTED_CASES = {
    "unavailable-version",
    "feature-active-or-explicit-unavailable",
    "object-analysis-routing",
    "named-table-output",
}
EXPECTED_CONDITIONAL_CASES = {
    "feature-active",
    "maintenance-visible",
    "empty-filter",
    "denied-runtime",
    "bounded-output",
    "cross-database",
}
EXPECTED_ACTIVATION_PREREQUISITES = {
    "Compatibility level 170",
    "PREVIEW_FEATURES enabled",
    "sys.vector_indexes and sys.dm_db_vector_indexes exposed by the SQL Server 2025 build",
}


def require_tokens(text: str, tokens: Iterable[str], label: str, errors: list[str]) -> None:
    for token in tokens:
        if token not in text:
            errors.append(f"{label}: missing token {token!r}")


def validate_contract_object(data: dict) -> list[str]:
    errors: list[str] = []
    expected_scalars = {
        "contractId": "SQL25-001-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-001",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.16",
        "frameworkContractVersion": "1.20",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "procedure": "monitor.USP_VectorIndexAnalysis",
        "orchestrator": "monitor.USP_ObjectAnalysis",
    }
    for key, expected in expected_scalars.items():
        if data.get(key) != expected:
            errors.append(f"contract: {key} must be {expected!r}")

    if set(data.get("resultSets", [])) != EXPECTED_RESULTS:
        errors.append("contract: resultSets do not match the six frozen names")
    if set(data.get("runtimeMatrix", {}).get("requiredCases", [])) != EXPECTED_CASES:
        errors.append("contract: runtimeMatrix.requiredCases is incomplete")
    if (
        set(data.get("runtimeMatrix", {}).get("capabilityConditionalCases", []))
        != EXPECTED_CONDITIONAL_CASES
    ):
        errors.append("contract: runtimeMatrix.capabilityConditionalCases is incomplete")
    if (
        set(data.get("runtimeMatrix", {}).get("activationPrerequisites", []))
        != EXPECTED_ACTIVATION_PREREQUISITES
    ):
        errors.append("contract: runtimeMatrix.activationPrerequisites is incomplete")
    if data.get("runtimeMatrix", {}).get("productMajorVersions") != [15, 16, 17]:
        errors.append("contract: productMajorVersions must be [15, 16, 17]")

    sources = {item.get("object"): item for item in data.get("sources", [])}
    for source in ("sys.vector_indexes", "sys.dm_db_vector_indexes"):
        row = sources.get(source)
        if not row:
            errors.append(f"contract: missing source {source}")
        elif row.get("maximumReadsPerDatabaseInvocation") != 1:
            errors.append(f"contract: {source} must have a one-read invariant")

    privacy = data.get("privacy", {})
    for key in (
        "vectorValuesCollected",
        "buildParametersCollected",
        "queryTextCollected",
        "planXmlCollected",
    ):
        if privacy.get(key) is not False:
            errors.append(f"contract: privacy.{key} must be false")
    if len(data.get("falsePositiveBoundaries", [])) < 4:
        errors.append("contract: false-positive boundaries are incomplete")
    return errors


def read_text(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def read_csv(root: Path, relative: str) -> list[dict[str, str]]:
    with (root / relative).open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def validate_repository(root: Path) -> list[str]:
    errors: list[str] = []
    contract_path = root / "Metadata/Quality/SQL25_Vector_Index_Public_Contract.json"
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"contract: cannot read valid JSON: {exc}"]
    errors.extend(validate_contract_object(contract))

    procedure = read_text(root, "Code/03_ObjectIndex/075_USP_VectorIndexAnalysis.sql")
    require_tokens(
        procedure,
        (
            "CREATE OR ALTER PROCEDURE [monitor].[USP_VectorIndexAnalysis]",
            "@ProductMajorVersion IS NULL OR @ProductMajorVersion<17",
            "@VectorCatalogSchemaValid",
            "@VectorRuntimeSchemaValid",
            "UNAVAILABLE_VERSION",
            "UNAVAILABLE_FEATURE",
            "UNAVAILABLE_SOURCE_SCHEMA",
            "DENIED_PERMISSION",
            "VECTOR_INDEX_DISABLED",
            "VECTOR_BACKGROUND_TASK_FAILED",
            "VECTOR_STALENESS_REVIEW",
            "hasMoreVectorIndexRows",
            "moduleStatus|vectorIndexes|maintenance|findings|sourceStatus|warnings",
        ),
        "procedure",
        errors,
    )
    if procedure.count("FROM [sys].[vector_indexes]") != 1:
        errors.append("procedure: sys.vector_indexes must have exactly one source read")
    if procedure.count("FROM [sys].[dm_db_vector_indexes]") != 1:
        errors.append("procedure: sys.dm_db_vector_indexes must have exactly one source read")
    for forbidden in (
        "[v].[build_parameters]",
        "JSON_VALUE([v].[build_parameters]",
        "[Embedding]",
        "VECTOR_SEARCH(",
        "AI_GENERATE_EMBEDDINGS",
    ):
        if forbidden in procedure:
            errors.append(f"procedure: forbidden payload or search token {forbidden!r}")

    orchestrator = read_text(root, "Code/03_ObjectIndex/080_USP_ObjectAnalysis.sql")
    require_tokens(
        orchestrator,
        (
            "@MitVectorIndexes",
            "EXEC [monitor].[USP_VectorIndexAnalysis]",
            "@JsonVectorIndexes OUTPUT",
            '"vectorIndexAnalysis"',
            "'UNAVAILABLE_VERSION','UNAVAILABLE_FEATURE','NOT_ENABLED'",
        ),
        "orchestrator",
        errors,
    )

    inventory = read_text(root, "Code/09_VersionAdaptive/020_USP_SpecialFeatureInventory.sql")
    require_tokens(
        inventory,
        ("N''USP_VectorIndexAnalysis''", "''IMPLEMENTED''", "N''sys.columns|sys.types''"),
        "special-feature inventory",
        errors,
    )

    installer = read_text(root, "Code/Install/Install_All.sql")
    if installer.count(":r ../03_ObjectIndex/075_USP_VectorIndexAnalysis.sql") != 1:
        errors.append("installer: Vector-index procedure must be included exactly once")
    release_gate = read_text(root, "Code/Tests/Run_Release_Gate.sql")
    if release_gate.count(":r ObjectIndex/120_SQL25_Vector_Index_Runtime_Contract.sql") != 1:
        errors.append("release gate: SQL25-001 runtime contract must run exactly once")

    runtime_test = read_text(
        root, "Code/Tests/ObjectIndex/120_SQL25_Vector_Index_Runtime_Contract.sql"
    )
    require_tokens(
        runtime_test,
        (
            "UNAVAILABLE-VERSION",
            "FEATURE-UNAVAILABLE-EXPLICIT",
            "FEATURE-ACTIVE",
            "MAINTENANCE-VISIBLE",
            "EMPTY-FILTER",
            "DENIED-RUNTIME",
            "BOUNDED-OUTPUT",
            "CROSS-DATABASE",
            "OBJECT-ANALYSIS-ROUTING",
            "NAMED-TABLE-OUTPUT",
            "CREATE VECTOR INDEX",
            "ExampleVectorRuntimeA",
        ),
        "runtime contract",
        errors,
    )
    if any(token in runtime_test for token in ("http://", "https://", "C:\\", "/home/")):
        errors.append("runtime contract: environment or network locator detected")

    objects = read_csv(root, "Metadata/Inventory/Objects.csv")
    object_rows = [
        row for row in objects if row.get("ObjectName") == "USP_VectorIndexAnalysis"
    ]
    if object_rows != [
        {
            "ObjectType": "PROCEDURE",
            "ObjectName": "USP_VectorIndexAnalysis",
            "SourcePath": "Code/03_ObjectIndex/075_USP_VectorIndexAnalysis.sql",
        }
    ]:
        errors.append("inventory: Objects.csv Vector-index row is missing or duplicated")

    parameters = {
        row["ParameterName"]
        for row in read_csv(root, "Metadata/Inventory/Parameters.csv")
        if row["ProcedureName"] == "USP_VectorIndexAnalysis"
    }
    if {
        "DatabaseNames",
        "IndexNames",
        "StalenessReviewPercent",
        "ResultSetArt",
        "ResultTablesJson",
        "Json",
        "StatusCodeOut",
        "IsPartialOut",
        "ErrorNumberOut",
        "ErrorMessageOut",
    } - parameters:
        errors.append("inventory: Parameters.csv Vector-index API is incomplete")

    result_rows = [
        row
        for row in read_csv(root, "Metadata/Inventory/ResultSets.csv")
        if row["ProcedureName"] == "USP_VectorIndexAnalysis"
    ]
    if {row["ResultName"] for row in result_rows} != EXPECTED_RESULTS:
        errors.append("inventory: ResultSets.csv must contain the six frozen results")
    if any(row["IsTableExportable"] != "1" for row in result_rows):
        errors.append("inventory: every SQL25-001 result must be TABLE-exportable")

    sources = {
        row["SystemSource"]: row
        for row in read_csv(root, "Metadata/Inventory/SystemSources.csv")
    }
    for source in ("sys.vector_indexes", "sys.dm_db_vector_indexes"):
        row = sources.get(source)
        if not row or "075_USP_VectorIndexAnalysis.sql" not in row["FrameworkModules"]:
            errors.append(f"inventory: missing module mapping for {source}")

    backlog = read_text(root, "Metadata/Quality/Future_Enhancement_Backlog.csv")
    implementation = read_text(root, "Metadata/Quality/Implementation_Status.csv")
    require_tokens(
        backlog,
        ("SQL25-001", "IMPLEMENTED_ACTIONS_GATE"),
        "backlog",
        errors,
    )
    require_tokens(
        implementation,
        (
            "SQL25-001,IMPLEMENTED_ACTIONS_GATE",
            "Documentation/Architecture/SQL_Server_2025_Vector_Index_Analysis.md",
        ),
        "implementation status",
        errors,
    )

    catalog = read_text(root, "Code/01_Common/021_VW_AnalysisCatalog.sql")
    search = read_text(root, "Code/01_Common/022_VW_AnalysisSearchTerm.sql")
    relations = read_text(root, "Code/01_Common/023_VW_AnalysisRelation.sql")
    require_tokens(catalog, ("USP_VectorIndexAnalysis", "USP_VectorIndexAnalysis.md"), "catalog", errors)
    if search.count("N'USP_VectorIndexAnalysis'") < 2:
        errors.append("navigator: Vector-index search terms must cover both languages")
    require_tokens(
        relations,
        (
            "N'USP_ObjectAnalysis','REFINE_WITH',N'USP_VectorIndexAnalysis'",
            "N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_VectorIndexAnalysis'",
        ),
        "relations",
        errors,
    )

    framework = read_text(root, "Code/01_Common/077_FrameworkVersion.sql")
    require_tokens(framework, ("1.1.0-special.19", "[ContractVersion]='1.23'"), "version", errors)

    for relative in (
        "Documentation/Architecture/SQL_Server_2025_Vector_Index_Analysis.md",
        "Documentation/Analysis_Guides/Procedures/USP_VectorIndexAnalysis.md",
    ):
        text = read_text(root, relative)
        require_tokens(
            text,
            (
                "sys.vector_indexes",
                "sys.dm_db_vector_indexes",
                "automatische",
            ),
            relative,
            errors,
        )
    return errors


def run_self_test() -> None:
    valid = {
        "contractId": "SQL25-001-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-001",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.16",
        "frameworkContractVersion": "1.20",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "procedure": "monitor.USP_VectorIndexAnalysis",
        "orchestrator": "monitor.USP_ObjectAnalysis",
        "resultSets": sorted(EXPECTED_RESULTS),
        "sources": [
            {
                "object": "sys.vector_indexes",
                "maximumReadsPerDatabaseInvocation": 1,
            },
            {
                "object": "sys.dm_db_vector_indexes",
                "maximumReadsPerDatabaseInvocation": 1,
            },
        ],
        "privacy": {
            "vectorValuesCollected": False,
            "buildParametersCollected": False,
            "queryTextCollected": False,
            "planXmlCollected": False,
        },
        "falsePositiveBoundaries": ["a", "b", "c", "d"],
        "runtimeMatrix": {
            "productMajorVersions": [15, 16, 17],
            "requiredCases": sorted(EXPECTED_CASES),
            "capabilityConditionalCases": sorted(EXPECTED_CONDITIONAL_CASES),
            "activationPrerequisites": sorted(EXPECTED_ACTIVATION_PREREQUISITES),
        },
    }
    if validate_contract_object(valid):
        raise AssertionError("self-test valid fixture was rejected")
    invalid = json.loads(json.dumps(valid))
    invalid["privacy"]["vectorValuesCollected"] = True
    if not validate_contract_object(invalid):
        raise AssertionError("self-test invalid fixture was accepted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        print("SQL25-001 validator self-test passed.")
        return 0
    errors = validate_repository(args.repository_root.resolve())
    if errors:
        for error in sorted(set(errors)):
            print(error, file=sys.stderr)
        return 1
    print("SQL25-001 Vector-index public contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
