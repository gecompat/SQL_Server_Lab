#!/usr/bin/env python3
"""Validate the frozen SQL25-004 readable-secondary statistics contract."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Iterable


EXPECTED_FIELDS = {
    "IsTemporary",
    "CurrentReplicaRole",
    "CurrentReplicaRoleStatus",
    "ReplicaRoleId",
    "ReplicaRoleDesc",
    "ReplicaName",
    "ReplicaMetadataStatus",
}
EXPECTED_STATUS_CODES = {
    "AVAILABLE",
    "NOT_RECORDED",
    "PARTIAL_METADATA",
    "UNAVAILABLE_VERSION",
    "UNAVAILABLE_COLUMNS",
    "DENIED_METADATA",
    "TIMEOUT",
    "CAPABILITY_ERROR",
}
EXPECTED_CURRENT_ROLES = {
    "HADR_DISABLED",
    "PRIMARY",
    "SECONDARY",
    "NOT_IN_AG_OR_UNKNOWN",
}
EXPECTED_CURRENT_ROLE_STATUSES = {
    "AVAILABLE",
    "NOT_APPLICABLE",
    "DENIED_PERMISSION",
    "TIMEOUT",
    "ERROR_HANDLED",
}
EXPECTED_ROLE_MAPPING = {
    "1": "Primary",
    "2": "Secondary",
    "3": "Geo Secondary",
    "4": "Geo HA Secondary",
}
EXPECTED_RUNTIME_CASES = {
    "named-table-json",
    "current-replica-role",
    "unavailable-version",
    "sql2025-catalog",
    "primary-or-not-recorded",
    "secondary-role-mapping",
    "partial-metadata-mapping",
    "bounded-output",
    "empty-or-restricted-scope",
    "restricted-metadata",
    "lock-timeout-restoration",
}


def require_tokens(
    text: str, tokens: Iterable[str], label: str, errors: list[str]
) -> None:
    for token in tokens:
        if token not in text:
            errors.append(f"{label}: missing token {token!r}")


def read_text(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8-sig")


def read_csv(root: Path, relative: str) -> list[dict[str, str]]:
    with (root / relative).open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def validate_contract_object(data: dict) -> list[str]:
    errors: list[str] = []
    expected_scalars = {
        "contractId": "SQL25-004-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-004",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.19",
        "frameworkContractVersion": "1.23",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "dedicatedProcedureAdded": False,
        "procedure": "monitor.USP_Statistics",
        "resultName": "statistics",
        "schemaVersion": 2,
        "documentation": (
            "Documentation/Architecture/"
            "SQL_Server_2025_Readable_Secondary_Statistics.md"
        ),
    }
    for key, expected in expected_scalars.items():
        if data.get(key) != expected:
            errors.append(f"contract: {key} must be {expected!r}")

    if set(data.get("replicaFields", [])) != EXPECTED_FIELDS:
        errors.append("contract: replicaFields do not match the frozen schema")
    if set(data.get("replicaMetadataStatusCodes", [])) != EXPECTED_STATUS_CODES:
        errors.append("contract: replicaMetadataStatusCodes are incomplete")
    if set(data.get("currentReplicaRoleCodes", [])) != EXPECTED_CURRENT_ROLES:
        errors.append("contract: currentReplicaRoleCodes are incomplete")
    if (
        set(data.get("currentReplicaRoleStatusCodes", []))
        != EXPECTED_CURRENT_ROLE_STATUSES
    ):
        errors.append("contract: currentReplicaRoleStatusCodes are incomplete")
    if data.get("replicaRoleMapping") != EXPECTED_ROLE_MAPPING:
        errors.append("contract: replicaRoleMapping is not the documented 1..4 map")

    sources = {
        item.get("object"): item
        for item in data.get("sources", [])
    }
    for source in (
        "sys.stats",
        "sys.all_views | sys.all_columns | sys.schemas",
        "sys.fn_hadr_is_primary_replica",
    ):
        row = sources.get(source)
        if not row:
            errors.append(f"contract: missing source {source}")
        elif row.get("maximumReadsPerDatabaseInvocation") != 1:
            errors.append(f"contract: {source} must have a one-read invariant")

    runtime = data.get("runtimeMatrix", {})
    if runtime.get("productMajorVersions") != [15, 16, 17]:
        errors.append("contract: productMajorVersions must be [15, 16, 17]")
    if set(runtime.get("requiredCases", [])) != EXPECTED_RUNTIME_CASES:
        errors.append("contract: runtimeMatrix.requiredCases is incomplete")
    if runtime.get("availabilityGroupContainerRequired") is not False:
        errors.append("contract: container gate must not claim an Availability Group")

    privacy = data.get("privacy", {})
    for key in (
        "userTableRowsRead",
        "histogramValuesCollected",
        "queryTextCollected",
        "planXmlCollected",
    ):
        if privacy.get(key) is not False:
            errors.append(f"contract: privacy.{key} must be false")
    if privacy.get("statisticsDefinitionMetadataCollected") is not True:
        errors.append(
            "contract: privacy.statisticsDefinitionMetadataCollected must be true"
        )
    if len(data.get("falsePositiveBoundaries", [])) < 6:
        errors.append("contract: false-positive boundaries are incomplete")
    return errors


def validate_repository(root: Path) -> list[str]:
    errors: list[str] = []
    contract_path = (
        root
        / "Metadata/Quality/"
        "SQL25_Readable_Secondary_Statistics_Public_Contract.json"
    )
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"contract: cannot read valid JSON: {exc}"]
    errors.extend(validate_contract_object(contract))

    procedure = read_text(
        root, "Code/03_ObjectIndex/040_USP_Statistics.sql"
    )
    require_tokens(
        procedure,
        (
            "@ProductMajorVersion",
            "COALESCE(@ProductMajorVersion,0)<17",
            "sys.all_views AS [v] WITH (NOLOCK)",
            "sys.all_columns AS [c] WITH (NOLOCK)",
            "sys.fn_hadr_is_primary_replica(@pDbName)",
            "[st].[replica_role_id]",
            "[st].[replica_role_desc]",
            "[st].[replica_name]",
            "[st].[replica_role_desc] COLLATE Latin1_General_100_CI_AI=",
            "[st].[is_temporary]",
            "[IsTemporary] bit NULL",
            "[CurrentReplicaRole] varchar(40) NULL",
            "[CurrentReplicaRoleStatus] varchar(40) NOT NULL",
            "[ReplicaRoleId] tinyint NULL",
            "[ReplicaRoleDesc] nvarchar(60) NULL",
            "[ReplicaName] sysname NULL",
            "[ReplicaMetadataStatus] varchar(40) NOT NULL",
            "@ModuleName [resultName],2 [schemaVersion]",
            "UNAVAILABLE_VERSION",
            "UNAVAILABLE_COLUMNS",
            "DENIED_METADATA",
            "CAPABILITY_ERROR",
            "('AVAILABLE','UNAVAILABLE_VERSION','UNAVAILABLE_COLUMNS')",
            "NOT_RECORDED",
            "PARTIAL_METADATA",
            "HADR_DISABLED",
            "NOT_IN_AG_OR_UNKNOWN",
            "RowScope=",
            "EMPTY_OR_RESTRICTED",
            "FROM #Statistics_Result AS [base]",
            "@OriginalLockTimeout",
            "IF @@LOCK_TIMEOUT<>@OriginalLockTimeout",
            "hat den äußeren LOCK_TIMEOUT verändert",
        ),
        "USP_Statistics",
        errors,
    )
    if "\n        SET LOCK_TIMEOUT 0;" in procedure:
        errors.append(
            "USP_Statistics: outer procedure scope must not change LOCK_TIMEOUT"
        )
    if procedure.count("FROM sys.stats AS [st] WITH (NOLOCK)") != 1:
        errors.append("USP_Statistics: sys.stats must be read exactly once")
    if procedure.count(
        "SELECT @pIsPrimary=sys.fn_hadr_is_primary_replica(@pDbName)"
    ) != 1:
        errors.append(
            "USP_Statistics: current replica role must be resolved exactly once"
        )
    if procedure.count(
        "FROM sys.all_views AS [v] WITH (NOLOCK)"
    ) != 1:
        errors.append(
            "USP_Statistics: replica-column capability must be read exactly once"
        )

    runtime = read_text(
        root,
        "Code/Tests/ObjectIndex/"
        "123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql",
    )
    require_tokens(
        runtime,
        (
            "NAMED-TABLE-JSON",
            "CURRENT-REPLICA-ROLE",
            "UNAVAILABLE-VERSION",
            "SQL2025-CATALOG",
            "PRIMARY-OR-NOT-RECORDED",
            "SECONDARY-ROLE-MAPPING",
            "PARTIAL-METADATA-MAPPING",
            "BOUNDED-OUTPUT",
            "EMPTY-OR-RESTRICTED-SCOPE",
            "RESTRICTED-METADATA",
            "LOCK-TIMEOUT-RESTORATION",
            "ExampleReadableSecondaryStatistics",
            "ExampleSecondaryReplica",
            "(1,N'PRIMARY',NULL,'AVAILABLE')",
            "WHERE [StatusCode]='AVAILABLE'",
            "stellt LOCK_TIMEOUT nicht wieder her",
            "CI-Container bilden keine Availability Group",
        ),
        "runtime contract",
        errors,
    )
    for forbidden in (
        "http://",
        "https://",
        "C:\\",
        "/home/",
        "@@SERVERNAME",
        "SERVERPROPERTY(N'ServerName')",
        "SERVERPROPERTY('ServerName')",
    ):
        if forbidden in runtime:
            errors.append(
                f"runtime contract: forbidden locator token {forbidden!r}"
            )

    release_gate = read_text(root, "Code/Tests/Run_Release_Gate.sql")
    if release_gate.count(
        ":r ObjectIndex/"
        "123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql"
    ) != 1:
        errors.append("release gate: SQL25-004 runtime contract must run once")

    result_rows = [
        row
        for row in read_csv(root, "Metadata/Inventory/ResultSets.csv")
        if row.get("ProcedureName") == "USP_Statistics"
        and row.get("ResultName") == "statistics"
    ]
    if len(result_rows) != 1:
        errors.append("inventory: USP_Statistics statistics result must exist once")
    else:
        row = result_rows[0]
        if row.get("SchemaVersion") != "2":
            errors.append("inventory: statistics schema version must be 2")
        schema = row.get("SourceSchema", "")
        for field in EXPECTED_FIELDS:
            if f"[{field}]" not in schema:
                errors.append(f"inventory: statistics schema is missing {field}")

    source_rows = {
        row.get("SystemSource"): row
        for row in read_csv(root, "Metadata/Inventory/SystemSources.csv")
    }
    for source in (
        "sys.stats",
        "sys.all_views",
        "sys.all_columns",
        "sys.fn_hadr_is_primary_replica",
    ):
        row = source_rows.get(source)
        modules = row.get("FrameworkModules", "") if row else ""
        if "040_USP_Statistics.sql" not in modules:
            errors.append(f"inventory: missing USP_Statistics mapping for {source}")
    stats_row = source_rows.get("sys.stats") or {}
    if "SQL25-004" not in stats_row.get("MinimumVersionOrCondition", ""):
        errors.append("inventory: sys.stats availability must name SQL25-004")

    for procedure_path in (root / "Code").glob("**/*.sql"):
        if "Tests" in procedure_path.parts:
            continue
        text = procedure_path.read_text(encoding="utf-8-sig")
        if "CREATE OR ALTER PROCEDURE [monitor].[USP_ReadableSecondary" in text:
            errors.append(
                "inventory: SQL25-004 must not add a dedicated public procedure"
            )
            break

    backlog = read_text(
        root, "Metadata/Quality/Future_Enhancement_Backlog.csv"
    )
    implementation = read_text(
        root, "Metadata/Quality/Implementation_Status.csv"
    )
    require_tokens(
        backlog,
        ("SQL25-004", "IMPLEMENTED_ACTIONS_GATE"),
        "backlog",
        errors,
    )
    require_tokens(
        implementation,
        (
            "SQL25-004,IMPLEMENTED_ACTIONS_GATE",
            "SQL_Server_2025_Readable_Secondary_Statistics.md",
        ),
        "implementation status",
        errors,
    )

    catalog = read_text(root, "Code/01_Common/021_VW_AnalysisCatalog.sql")
    search = read_text(root, "Code/01_Common/022_VW_AnalysisSearchTerm.sql")
    require_tokens(
        catalog,
        (
            "Statistikzustand, Änderungen und Replikatherkunft",
            "Replica-Herkunft",
        ),
        "navigator catalog",
        errors,
    )
    require_tokens(
        search,
        (
            "lesbare Secondary Statistik Replikat Herkunft",
            "readable secondary statistics replica origin",
        ),
        "navigator search",
        errors,
    )

    framework = read_text(root, "Code/01_Common/077_FrameworkVersion.sql")
    require_tokens(
        framework,
        (
            "1.1.0-special.19",
            "[ContractVersion]='1.23'",
            "SQL25-004",
        ),
        "version",
        errors,
    )

    documentation = read_text(
        root,
        "Documentation/Architecture/"
        "SQL_Server_2025_Readable_Secondary_Statistics.md",
    )
    require_tokens(
        documentation,
        (
            "replica_role_id",
            "replica_role_desc",
            "replica_name",
            "is_temporary",
            "CurrentReplicaRole",
            "CurrentReplicaRoleStatus",
            "NOT_RECORDED",
            "PARTIAL_METADATA",
            "kein Verwendungsnachweis",
            "IMPLEMENTED_ACTIONS_GATE",
        ),
        "architecture documentation",
        errors,
    )

    workflow = read_text(root, ".github/workflows/documentation-validation.yml")
    require_tokens(
        workflow,
        (
            "989_Validate_SQL25_Readable_Secondary_Statistics_Contract.py",
            "SQL25_Readable_Secondary_Statistics_Public_Contract.json",
            "Validate SQL25-004 readable-secondary statistics contract",
        ),
        "documentation workflow",
        errors,
    )
    output_pilot = read_text(
        root, ".github/workflows/framework-output-pilot.yml"
    )
    require_tokens(
        output_pilot,
        (
            "Code/03_ObjectIndex/040_USP_Statistics.sql",
            "123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql",
        ),
        "output-pilot workflow",
        errors,
    )
    return errors


def run_self_test() -> None:
    valid = {
        "contractId": "SQL25-004-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-004",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.19",
        "frameworkContractVersion": "1.23",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "dedicatedProcedureAdded": False,
        "procedure": "monitor.USP_Statistics",
        "resultName": "statistics",
        "schemaVersion": 2,
        "documentation": (
            "Documentation/Architecture/"
            "SQL_Server_2025_Readable_Secondary_Statistics.md"
        ),
        "replicaFields": sorted(EXPECTED_FIELDS),
        "replicaMetadataStatusCodes": sorted(EXPECTED_STATUS_CODES),
        "currentReplicaRoleCodes": sorted(EXPECTED_CURRENT_ROLES),
        "currentReplicaRoleStatusCodes": sorted(
            EXPECTED_CURRENT_ROLE_STATUSES
        ),
        "replicaRoleMapping": EXPECTED_ROLE_MAPPING,
        "sources": [
            {
                "object": "sys.stats",
                "maximumReadsPerDatabaseInvocation": 1,
            },
            {
                "object": (
                    "sys.all_views | sys.all_columns | sys.schemas"
                ),
                "maximumReadsPerDatabaseInvocation": 1,
            },
            {
                "object": "sys.fn_hadr_is_primary_replica",
                "maximumReadsPerDatabaseInvocation": 1,
            },
        ],
        "runtimeMatrix": {
            "productMajorVersions": [15, 16, 17],
            "requiredCases": sorted(EXPECTED_RUNTIME_CASES),
            "availabilityGroupContainerRequired": False,
        },
        "privacy": {
            "userTableRowsRead": False,
            "histogramValuesCollected": False,
            "queryTextCollected": False,
            "planXmlCollected": False,
            "statisticsDefinitionMetadataCollected": True,
        },
        "falsePositiveBoundaries": ["a", "b", "c", "d", "e", "f"],
    }
    if validate_contract_object(valid):
        raise AssertionError("self-test valid fixture was rejected")
    invalid = json.loads(json.dumps(valid))
    invalid["runtimeMatrix"]["availabilityGroupContainerRequired"] = True
    if not validate_contract_object(invalid):
        raise AssertionError("self-test invalid fixture was accepted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        print("SQL25-004 validator self-test passed.")
        return 0
    errors = validate_repository(args.repository_root.resolve())
    if errors:
        for error in sorted(set(errors)):
            print(error, file=sys.stderr)
        return 1
    print("SQL25-004 readable-secondary statistics contract passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
