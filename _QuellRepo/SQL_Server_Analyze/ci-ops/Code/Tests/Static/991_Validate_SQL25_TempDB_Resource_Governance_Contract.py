#!/usr/bin/env python3
"""Validate the frozen public SQL25-003 TempDB Resource Governance contract."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path


EXPECTED_FIELDS = [
    "GroupId",
    "GroupName",
    "PoolId",
    "PoolName",
    "ConfiguredGroupMaxTempdbDataMb",
    "ConfiguredGroupMaxTempdbDataPercent",
    "TempdbMaximumSizeMb",
    "EffectiveGroupMaxTempdbDataMb",
    "EffectiveLimitSource",
    "IsPercentLimitEffective",
    "TempdbDataSpaceMb",
    "PeakTempdbDataSpaceMb",
    "EffectiveLimitUtilizationPercent",
    "TotalTempdbDataLimitViolationCount",
    "HasRecordedLimitViolation",
    "StatisticsStartTime",
    "IsResourceGovernorEnabled",
    "ReconfigurationPending",
    "SourceStatusCode",
    "IsPartial",
    "EvidenceLimit",
]
EXPECTED_STATUS = {
    "AVAILABLE",
    "AVAILABLE_EMPTY_OR_RESTRICTED",
    "AVAILABLE_LIMITED",
    "UNAVAILABLE_VERSION",
    "UNAVAILABLE_SOURCE_SCHEMA",
    "DENIED_PERMISSION",
    "TIMEOUT",
    "ERROR_HANDLED",
}
EXPECTED_LIMIT_SOURCES = {
    "NO_LIMIT_CONFIGURED",
    "FIXED_MB_EFFECTIVE",
    "PERCENT_EFFECTIVE",
    "PERCENT_NOT_EFFECTIVE",
    "RESOURCE_GOVERNOR_DISABLED",
    "RECONFIGURATION_PENDING",
    "UNAVAILABLE",
}
PRODUCT_PATHS = (
    "Code/02_CurrentState/070_USP_CurrentTempDB.sql",
    "Code/07_Infrastructure/030_USP_ResourceGovernorAnalysis.sql",
)
SNAPSHOT_PATH = "Code/02_CurrentState/005_InternalCaptureCurrentStateSnapshot.sql"
OVERVIEW_PATH = "Code/02_CurrentState/100_USP_CurrentOverview.sql"
RUNTIME_PATH = (
    "Code/Tests/Infrastructure/"
    "122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql"
)
CONTRACT_PATH = (
    "Metadata/Quality/"
    "SQL25_TempDB_Resource_Governance_Public_Contract.json"
)
DOC_PATH = (
    "Documentation/Architecture/"
    "SQL_Server_2025_TempDB_Resource_Governance.md"
)


def read_text(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8-sig")


def require_tokens(
    content: str,
    tokens: tuple[str, ...] | list[str],
    location: str,
    errors: list[str],
) -> None:
    for token in tokens:
        if token not in content:
            errors.append(f"{location}: missing token {token!r}")


def source_read_count(content: str, object_name: str) -> int:
    pattern = (
        r"\b(?:FROM|JOIN)\s+"
        + re.escape(object_name)
        + r"\s+(?:AS\s+)?\[[A-Za-z][A-Za-z0-9_]*\]"
    )
    return len(re.findall(pattern, content, flags=re.IGNORECASE))


def parse_result_inventory(root: Path) -> dict[tuple[str, str], dict[str, str]]:
    path = root / "Metadata/Inventory/ResultSets.csv"
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    return {(row["ProcedureName"], row["ResultName"]): row for row in rows}


def self_test() -> None:
    errors: list[str] = []
    require_tokens("FIXED_MB_EFFECTIVE PERCENT_NOT_EFFECTIVE", (
        "FIXED_MB_EFFECTIVE",
        "PERCENT_NOT_EFFECTIVE",
    ), "positive", errors)
    if errors:
        raise SystemExit("SQL25-003 validator self-test positive case failed")

    negative: list[str] = []
    require_tokens("FIXED_MB_EFFECTIVE", ("PERCENT_NOT_EFFECTIVE",), "negative", negative)
    if len(negative) != 1:
        raise SystemExit("SQL25-003 validator self-test negative case failed")

    sample = (
        "FROM [sys].[dm_resource_governor_workload_groups] AS [g] "
        "JOIN [sys].[resource_governor_workload_groups] AS [c] ON 1=1"
    )
    if source_read_count(
        sample, "[sys].[dm_resource_governor_workload_groups]"
    ) != 1:
        raise SystemExit("SQL25-003 validator source-read self-test failed")

    print("SQL25-003 validator self-test passed: cases=3 findings=0")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0

    root = Path(args.repository_root).resolve()
    errors: list[str] = []

    contract = json.loads(read_text(root, CONTRACT_PATH))
    expected_header = {
        "contractId": "SQL25-003-PUBLIC-V1",
        "contractVersion": 1,
        "workItemId": "SQL25-003",
        "releaseState": "IMPLEMENTED_ACTIONS_GATE",
        "frameworkVersion": "1.1.0-special.18",
        "frameworkContractVersion": "1.22",
        "minimumFrameworkProductMajorVersion": 15,
        "featureProductMajorVersion": 17,
        "dedicatedProcedureAdded": False,
        "orchestrator": "monitor.USP_CurrentOverview",
        "resultName": "tempdbGovernance",
    }
    for key, expected in expected_header.items():
        if contract.get(key) != expected:
            errors.append(
                f"contract: {key} expected={expected!r} "
                f"actual={contract.get(key)!r}"
            )

    if contract.get("procedures") != [
        "monitor.USP_CurrentTempDB",
        "monitor.USP_ResourceGovernorAnalysis",
    ]:
        errors.append("contract: procedures must name exactly the two existing procedures")
    if contract.get("resultFields") != EXPECTED_FIELDS:
        errors.append("contract: resultFields differ from frozen order")
    if set(contract.get("outputModes", [])) != {
        "CONSOLE", "RAW", "TABLE", "NONE", "JSON"
    }:
        errors.append("contract: outputModes incomplete")
    if set(contract.get("sourceStatusCodes", [])) != EXPECTED_STATUS:
        errors.append("contract: sourceStatusCodes incomplete")
    if set(contract.get("effectiveLimitSources", [])) != EXPECTED_LIMIT_SOURCES:
        errors.append("contract: effectiveLimitSources incomplete")

    runtime_matrix = contract.get("runtimeMatrix", {})
    if runtime_matrix.get("productMajorVersions") != [15, 16, 17]:
        errors.append("contract: runtime product matrix must be 15/16/17")
    required_cases = set(runtime_matrix.get("requiredCases", []))
    for case in (
        "unavailable-version",
        "no-limit-configured",
        "mb-limit-precedence",
        "percent-limit-effective-or-explicitly-ineffective",
        "current-and-peak-usage",
        "violation-and-reset-window-semantics",
        "restricted-permission",
        "named-table-output",
        "json-output",
        "current-overview-parent-routing",
        "lock-timeout-restoration",
    ):
        if case not in required_cases:
            errors.append(f"contract: missing runtime case {case}")

    source_objects = {source["object"]: source for source in contract.get("sources", [])}
    for name in (
        "sys.resource_governor_workload_groups",
        "sys.dm_resource_governor_workload_groups",
        "sys.resource_governor_configuration | sys.dm_resource_governor_configuration",
        "master.sys.master_files",
        "tempdb.sys.dm_db_session_space_usage",
    ):
        if name not in source_objects:
            errors.append(f"contract: missing source {name}")
    for source in contract.get("sources", []):
        if source.get("maximumReadsPerInvocationAndProcedure") != 1:
            errors.append(
                f"contract: source {source.get('name')} lacks single-read limit"
            )

    privacy = contract.get("privacy", {})
    for key in (
        "persistenceAdded",
        "userTableRowsRead",
        "queryTextCollected",
        "planXmlCollected",
        "sessionIdentityAddedToGovernanceResult",
    ):
        if privacy.get(key) is not False:
            errors.append(f"contract: privacy flag {key} must be false")
    if not str(privacy.get("runtimeFixtures", "")).startswith("Synthetic Example"):
        errors.append("contract: runtime fixtures must be explicitly synthetic")

    result_schemas: list[str] = []
    for relative in PRODUCT_PATHS:
        content = read_text(root, relative)
        require_tokens(
            content,
            [
                "Version      : ",
                "@OriginalLockTimeout int=@@LOCK_TIMEOUT",
                "@ResultTablesJson",
                "tempdbGovernance",
                "group_max_tempdb_data_mb",
                "group_max_tempdb_data_percent",
                "tempdb_data_space_kb",
                "peak_tempdb_data_space_kb",
                "total_tempdb_data_limit_violation_count",
                "statistics_start_time",
                "@TempdbFileStatus",
                "FIXED_MB_EFFECTIVE",
                "PERCENT_EFFECTIVE",
                "PERCENT_NOT_EFFECTIVE",
                "NO_LIMIT_CONFIGURED",
                "RESOURCE_GOVERNOR_DISABLED",
                "RECONFIGURATION_PENDING",
                "UNAVAILABLE_VERSION",
                "UNAVAILABLE_SOURCE_SCHEMA",
                "DENIED_PERMISSION",
                "SET LOCK_TIMEOUT ",
                "[sys].[sp_executesql]",
            ],
            relative,
            errors,
        )
        for object_name in (
            "[sys].[resource_governor_workload_groups]",
            "[sys].[dm_resource_governor_workload_groups]",
            "[master].[sys].[master_files]",
        ):
            count = source_read_count(content, object_name)
            if count != 1:
                errors.append(
                    f"{relative}: {object_name} source reads expected=1 actual={count}"
                )
        if content.count("group_max_tempdb_data_mb") < 2:
            errors.append(f"{relative}: SQL25 catalog fields not materialized")
        inventory = parse_result_inventory(root)
        proc = (
            "USP_CurrentTempDB"
            if "CurrentTempDB" in relative
            else "USP_ResourceGovernorAnalysis"
        )
        row = inventory.get((proc, "tempdbGovernance"))
        if row is None:
            errors.append(f"ResultSets.csv: missing {proc}/tempdbGovernance")
        else:
            result_schemas.append(row["SourceSchema"])

    if len(result_schemas) != 2 or len(set(result_schemas)) != 1:
        errors.append("ResultSets.csv: governance schemas must be identical")

    snapshot = read_text(root, SNAPSHOT_PATH)
    require_tokens(
        snapshot,
        [
            "TEMPDB_GOVERNANCE",
            "configured_group_max_tempdb_data_mb",
            "effective_group_max_tempdb_data_mb",
            "tempdb_governance_status_code",
            "@TempdbFileStatus",
            "master].[sys].[master_files",
        ],
        SNAPSHOT_PATH,
        errors,
    )
    for object_name in (
        "[sys].[resource_governor_workload_groups]",
        "[sys].[dm_resource_governor_workload_groups]",
        "[master].[sys].[master_files]",
    ):
        count = source_read_count(snapshot, object_name)
        if count != 1:
            errors.append(
                f"{SNAPSHOT_PATH}: {object_name} source reads expected=1 actual={count}"
            )

    overview = read_text(root, OVERVIEW_PATH)
    require_tokens(
        overview,
        [
            "#CurrentOverview_TempDBGovernance",
            '\"tempdbGovernance\":\"#CurrentOverview_TempDBGovernance\"',
            "WHEN @ExportResultName=N'tempdbGovernance' THEN @MitTempDB",
            "@CaptureResourceGovernor=CASE WHEN @MitRequests=1 "
            "OR @MitMemoryGrants=1 OR @MitTempDB=1 THEN 1 ELSE 0 END",
            "@OriginalLockTimeout int=@@LOCK_TIMEOUT",
        ],
        OVERVIEW_PATH,
        errors,
    )

    runtime = read_text(root, RUNTIME_PATH)
    require_tokens(
        runtime,
        [
            "SQL25-003",
            "ExampleTempdbGovernance",
            "UNAVAILABLE_VERSION",
            "NO_LIMIT_CONFIGURED",
            "FIXED_MB_EFFECTIVE",
            "PERCENT_EFFECTIVE",
            "PERCENT_NOT_EFFECTIVE",
            "ALTER RESOURCE GOVERNOR RESET STATISTICS",
            "TotalTempdbDataLimitViolationCount",
            "StatisticsStartTime",
            "EXECUTE AS USER",
            "REVERT",
            "@ResultSetArt=''TABLE''",
            "@JsonErzeugen=1",
            "@@LOCK_TIMEOUT",
            "DROP WORKLOAD GROUP",
        ],
        RUNTIME_PATH,
        errors,
    )
    seed_targets = set(
        re.findall(
            r"CREATE TABLE \[(#SQL25TempDBResourceGovernanceRuntimeContract_"
            r"[A-Za-z0-9_]+)\]\(\[Seed\] bit NULL\);",
            runtime,
        )
    )
    mapped_targets = re.findall(
        r'tempdbGovernance":"(#SQL25TempDBResourceGovernanceRuntimeContract_'
        r'[A-Za-z0-9_]+)"',
        runtime,
    )
    if (
        len(seed_targets) != 6
        or len(mapped_targets) != 6
        or len(set(mapped_targets)) != 6
        or set(mapped_targets) != seed_targets
    ):
        errors.append(
            "runtime: every TABLE invocation must use its own canonical Seed target"
        )
    if "TRUNCATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_" in runtime:
        errors.append("runtime: materialized TABLE targets must not be reused")

    if re.search(r"(?i)(?:password|pwd|token|secret)\s*=", runtime):
        errors.append("runtime: credential-like assignment is forbidden")
    if re.search(r"(?i)(?:https?://|[A-Z]:\\|/(?:home|users)/)", runtime):
        errors.append("runtime: environment or network locator detected")

    release_gate = read_text(root, "Code/Tests/Run_Release_Gate.sql")
    if release_gate.count(
        "Infrastructure/122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql"
    ) != 1:
        errors.append("release gate: SQL25-003 runtime contract must run exactly once")

    framework = read_text(root, "Code/01_Common/077_FrameworkVersion.sql")
    require_tokens(
        framework,
        ["1.1.0-special.19", "[ContractVersion]='1.23'", "SQL25-004"],
        "framework version",
        errors,
    )

    with (
        root / "Metadata/Quality/Implementation_Status.csv"
    ).open(encoding="utf-8", newline="") as handle:
        status_rows = {
            row["WorkItemId"]: row for row in csv.DictReader(handle)
        }
    status_row = status_rows.get("SQL25-003")
    if not status_row or status_row.get("ProductStatus") != "IMPLEMENTED_ACTIONS_GATE":
        errors.append("Implementation_Status.csv: SQL25-003 status missing")
    if status_row and status_row.get("EvidenceReference") != DOC_PATH:
        errors.append("Implementation_Status.csv: SQL25-003 documentation mismatch")

    with (
        root / "Metadata/Quality/Future_Enhancement_Backlog.csv"
    ).open(encoding="utf-8", newline="") as handle:
        future = {
            row["EnhancementId"]: row for row in csv.DictReader(handle)
        }
    future_row = future.get("SQL25-003")
    if not future_row or future_row.get("ImplementationStatus") != "IMPLEMENTED_ACTIONS_GATE":
        errors.append("Future_Enhancement_Backlog.csv: SQL25-003 status missing")

    system_sources = read_text(root, "Metadata/Inventory/SystemSources.csv")
    require_tokens(
        system_sources,
        [
            "sys.resource_governor_workload_groups",
            "sys.dm_resource_governor_workload_groups",
            "master.sys.master_files",
            "030_USP_ResourceGovernorAnalysis.sql",
            "070_USP_CurrentTempDB.sql",
        ],
        "SystemSources.csv",
        errors,
    )

    catalog = read_text(root, "Code/01_Common/021_VW_AnalysisCatalog.sql")
    navigator = read_text(root, "Code/01_Common/022_VW_AnalysisSearchTerm.sql")
    navigator_runtime = read_text(
        root, "Code/Tests/Integration/196_Analysis_Navigator_Runtime_Contract.sql"
    )
    require_tokens(
        catalog,
        ["TempDB", "Resource-Governor", "Peak", "Verletzung"],
        "analysis catalog",
        errors,
    )
    for token in (
        "TempDB Workload Group Limit Verletzung",
        "TempDB Resource Governance Wirksamkeit",
    ):
        require_tokens(navigator, [token], "navigator terms", errors)
        require_tokens(navigator_runtime, [token], "navigator runtime", errors)

    documentation = read_text(root, DOC_PATH)
    require_tokens(
        documentation,
        [
            "IMPLEMENTED_ACTIONS_GATE",
            "SQL25-003",
            "FIXED_MB_EFFECTIVE",
            "PERCENT_NOT_EFFECTIVE",
            "StatisticsStartTime",
            "ALTER RESOURCE GOVERNOR RESET STATISTICS",
            "Version Store",
            "TempDB-Log",
            "SQL25_TempDB_Resource_Governance_Public_Contract.json",
            "learn.microsoft.com",
        ],
        DOC_PATH,
        errors,
    )
    for relative in (
        "Documentation/Analysis_Guides/Procedures/USP_CurrentTempDB.md",
        "Documentation/Analysis_Guides/Procedures/USP_ResourceGovernorAnalysis.md",
        "Documentation/Analysis_Guides/Procedures/USP_CurrentOverview.md",
        "Documentation/Analysis_Guides/02_Current_State.md",
        "Documentation/Analysis_Guides/07_Infrastructure.md",
        "Documentation/README.md",
        "README.md",
    ):
        require_tokens(
            read_text(root, relative),
            ["tempdbGovernance" if "README.md" not in relative else "TempDB"],
            relative,
            errors,
        )

    objects = read_text(root, "Metadata/Inventory/Objects.csv")
    if re.search(r"(?i)USP_.*TempDB.*Resource.*Governance", objects):
        errors.append("inventory: SQL25-003 must not add a dedicated procedure")

    doc_workflow = read_text(
        root, ".github/workflows/documentation-validation.yml"
    )
    require_tokens(
        doc_workflow,
        [
            "991_Validate_SQL25_TempDB_Resource_Governance_Contract.py",
            "SQL25_TempDB_Resource_Governance_Public_Contract.json",
        ],
        "documentation workflow",
        errors,
    )
    output_workflow = read_text(
        root, ".github/workflows/framework-output-pilot.yml"
    )
    for token in (
        "005_InternalCaptureCurrentStateSnapshot.sql",
        "070_USP_CurrentTempDB.sql",
        "100_USP_CurrentOverview.sql",
        "030_USP_ResourceGovernorAnalysis.sql",
        "122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql",
    ):
        require_tokens(output_workflow, [token], "output pilot workflow", errors)

    if errors:
        for error in errors:
            print(f"SQL25-003 contract violation: {error}", file=sys.stderr)
        print(
            f"SQL25-003 contract validation failed: findings={len(errors)}",
            file=sys.stderr,
        )
        return 1

    print(
        "SQL25-003 contract passed: procedures=2 result_fields=21 "
        "sources=5 versions=3 runtime_cases=12 findings=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
