#!/usr/bin/env python3
"""Validate the frozen PLAN-001 public contract against canonical sources."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path


CONTRACT_PATH = Path("Metadata/Quality/ExecutionPlanAnalysis_Public_Contract.json")


def normalize_space(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def normalize_type(value: str) -> str:
    return re.sub(r"\s+", "", value.strip()).lower()


def extract_parameters(sql_text: str, procedure_name: str) -> list[tuple[str, str, str]]:
    match = re.search(
        rf"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+\[monitor\]\.\[{re.escape(procedure_name)}\]\s*(.*?)^AS\s*$",
        sql_text,
        re.IGNORECASE | re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise ValueError(f"Procedure declaration not found: {procedure_name}")

    block = re.sub(r"(?m)--.*$", "", match.group(1))
    declarations = re.split(r",\s*(?=@[A-Za-z_])", block.strip().lstrip(",").strip())
    parameters: list[tuple[str, str, str]] = []
    pattern = re.compile(
        r"^@(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s+"
        r"(?P<data_type>[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^)]*\))?)\s*=\s*"
        r"(?P<default>.+)$",
        re.IGNORECASE | re.DOTALL,
    )
    for declaration in declarations:
        parameter = pattern.match(normalize_space(declaration))
        if not parameter:
            raise ValueError(f"Unparseable parameter declaration: {declaration!r}")
        parameters.append(
            (
                parameter.group("name"),
                normalize_type(parameter.group("data_type")),
                normalize_space(parameter.group("default")),
            )
        )
    return parameters


def expected_parameters(rows: list[dict[str, str]], procedure_name: str) -> list[tuple[str, str, str]]:
    return [
        (
            row["ParameterName"],
            normalize_type(row["DataType"]),
            normalize_space(row["DefaultExpression"]),
        )
        for row in rows
        if row["ProcedureName"] == procedure_name
    ]


def require_fragments(text: str, fragments: list[str], label: str, errors: list[str]) -> None:
    for fragment in fragments:
        if fragment not in text:
            errors.append(f"Missing {label}: {fragment}")


def validate(repository_root: Path) -> list[str]:
    errors: list[str] = []
    contract_file = repository_root / CONTRACT_PATH
    if not contract_file.is_file():
        return [f"Missing public contract: {contract_file}"]

    contract = json.loads(contract_file.read_text(encoding="utf-8"))
    if contract.get("contractId") != "PLAN-001-PUBLIC-V3" or contract.get("contractVersion") != 3:
        errors.append("Unexpected PLAN-001 contract identity or version.")
    if contract.get("releaseState") != "IMPLEMENTED_ACTIONS_GATE":
        errors.append("PLAN-001 public contract is not in the verified Actions-gate state.")
    if contract.get("targetSqlServerMajorVersions") != [15, 16, 17]:
        errors.append("Target SQL Server major-version matrix must remain 15, 16 and 17.")

    release_evidence = contract.get("releaseEvidence", {})
    if not re.fullmatch(r"[0-9a-f]{40}", release_evidence.get("verifiedHeadSha", "")):
        errors.append("Verified PLAN-001 head SHA is missing or invalid.")
    if release_evidence.get("verifiedDate") != "2026-07-21":
        errors.append("PLAN-001 verification date is missing or unexpected.")
    if release_evidence.get("environment") != "ACTIONS_SYNTHETIC_LINUX":
        errors.append("PLAN-001 verification environment is not explicit.")
    target_evidence = release_evidence.get("targets", [])
    if [target.get("majorVersion") for target in target_evidence] != [15, 16, 17]:
        errors.append("PLAN-001 release evidence does not cover SQL Server 2019, 2022 and 2025 in order.")
    for target in target_evidence:
        major_version = target.get("majorVersion")
        if not re.fullmatch(rf"{major_version}\.[0-9]+\.[0-9]+\.[0-9]+", target.get("productVersion", "")):
            errors.append(f"Invalid PLAN-001 product version for major {major_version}.")
        if not re.fullmatch(
            r"mcr\.microsoft\.com/mssql/server@sha256:[0-9a-f]{64}",
            target.get("containerImageDigest", ""),
        ):
            errors.append(f"Invalid PLAN-001 image digest for major {major_version}.")
        if target.get("releaseGate") != "PASS" or target.get("permissionMatrix") != "PASS":
            errors.append(f"Incomplete PLAN-001 gate evidence for major {major_version}.")
        if not re.fullmatch(
            r"https://github\.com/gecompat/SQL_Server_Analyze/actions/runs/[0-9]+",
            target.get("runUrl", ""),
        ):
            errors.append(f"Invalid PLAN-001 run URL for major {major_version}.")
    sql_2025_evidence = target_evidence[-1] if target_evidence else {}
    if sql_2025_evidence.get("regexMatrix") != "PASS" or sql_2025_evidence.get("isolatedStandaloneInstaller") != "PASS":
        errors.append("SQL Server 2025 regex or isolated standalone evidence is incomplete.")
    output_evidence = release_evidence.get("outputMatrix", {})
    if output_evidence.get("targetMajorVersions") != [15, 16, 17] or output_evidence.get("status") != "PASS":
        errors.append("PLAN-001 output matrix evidence is incomplete.")
    if not re.fullmatch(
        r"https://github\.com/gecompat/SQL_Server_Analyze/actions/runs/[0-9]+",
        output_evidence.get("runUrl", ""),
    ):
        errors.append("Invalid PLAN-001 output-matrix run URL.")

    inventory_paths = contract["canonicalInventories"]
    for relative_path in inventory_paths.values():
        if not (repository_root / relative_path).is_file():
            errors.append(f"Missing canonical inventory: {relative_path}")

    with (repository_root / inventory_paths["parameters"]).open(encoding="utf-8-sig", newline="") as handle:
        parameter_rows = list(csv.DictReader(handle))
    with (repository_root / inventory_paths["resultSets"]).open(encoding="utf-8-sig", newline="") as handle:
        result_rows = list(csv.DictReader(handle))
    with (repository_root / inventory_paths["dependencies"]).open(encoding="utf-8-sig", newline="") as handle:
        dependency_rows = list(csv.DictReader(handle))

    source_texts: dict[str, str] = {}
    for procedure_name, procedure_contract in contract["publicProcedures"].items():
        source_path = repository_root / procedure_contract["sourcePath"]
        if not source_path.is_file():
            errors.append(f"Missing procedure source: {source_path}")
            continue
        source_text = source_path.read_text(encoding="utf-8-sig")
        source_texts[procedure_name] = source_text

        actual_parameters = extract_parameters(source_text, procedure_name)
        inventory_parameters = expected_parameters(parameter_rows, procedure_name)
        if len(actual_parameters) != procedure_contract["parameterCount"]:
            errors.append(f"Parameter count changed: {procedure_name}")
        if actual_parameters != inventory_parameters:
            errors.append(f"Source and parameter inventory differ: {procedure_name}")

        frozen_defaults = contract["frozenDefaults"][procedure_name]
        actual_by_name = {name: default for name, _data_type, default in actual_parameters}
        for parameter_name, expected_default in frozen_defaults.items():
            if actual_by_name.get(parameter_name) != expected_default:
                errors.append(f"Frozen default changed: {procedure_name}.@{parameter_name}")

        procedure_result_rows = [
            row for row in result_rows if row["ProcedureName"] == procedure_name
        ]
        actual_result_names = [row["ResultName"] for row in procedure_result_rows]
        if actual_result_names != procedure_contract["resultSets"]:
            errors.append(f"Result-set order or names changed: {procedure_name}")
        if any(row["SchemaVersion"] != "1" for row in procedure_result_rows):
            errors.append(f"Result-set schema version changed without a contract version: {procedure_name}")
        console_defaults = [
            row["ResultName"] for row in procedure_result_rows if row["IsConsoleDefault"] == "1"
        ]
        if console_defaults != [procedure_contract["consoleDefaultResult"]]:
            errors.append(f"CONSOLE default changed: {procedure_name}")

        allowed_match = re.search(r"@AllowedResultNames\s*=\s*N'([^']+)'", source_text)
        allowed_names = allowed_match.group(1).split("|") if allowed_match else []
        if allowed_names != procedure_contract["resultSets"]:
            errors.append(f"TABLE allowlist differs from frozen result sets: {procedure_name}")

        json_fragments = []
        for index, property_name in enumerate(procedure_contract["jsonTopLevelProperties"]):
            prefix = "{" if index == 0 else ","
            json_fragments.append(f'N\'{prefix}"{property_name}":')
        require_fragments(source_text, json_fragments, f"JSON property in {procedure_name}", errors)
        expected_result_name = (
            "ExecutionEvidence"
            if procedure_name == "USP_CreateExecutionEvidenceJson"
            else "ExecutionPlanAnalysis"
        )
        schema_marker = (
            f"SELECT N'{expected_result_name}' [resultName],"
            f"{procedure_contract['jsonSchemaVersion']} [schemaVersion]"
        )
        if schema_marker not in source_text:
            errors.append(f"JSON schema marker changed: {procedure_name}")

    analysis_text = source_texts.get("USP_ExecutionPlanAnalysis", "")
    evidence_text = source_texts.get("USP_CreateExecutionEvidenceJson", "")
    internal_text = (repository_root / "Code/04_PlanCache/051_InternalAnalyzeExecutionPlan.sql").read_text(
        encoding="utf-8-sig"
    )
    collector_text = (repository_root / "Code/04_PlanCache/049_InternalCollectExecutionPlanMetadata.sql").read_text(
        encoding="utf-8-sig"
    )
    showplan_text = (repository_root / "Code/04_PlanCache/050_USP_ShowplanAnalysis.sql").read_text(
        encoding="utf-8-sig"
    )
    diag005_runtime_text = (
        repository_root / "Code/Tests/PlanCache/123_DIAG005_Plan_Optimizer_Runtime_Contract.sql"
    ).read_text(encoding="utf-8-sig")
    combined_text = "\n".join((analysis_text, evidence_text, internal_text, collector_text, showplan_text))

    diag003 = contract["diag003ParameterEvidence"]
    parameter_rows = [
        row
        for row in result_rows
        if row["ProcedureName"] == "USP_ExecutionPlanAnalysis"
        and row["ResultName"] == diag003["canonicalResultSet"]
    ]
    if len(parameter_rows) != 1:
        errors.append("DIAG-003 canonical parameter result-set inventory row is missing or duplicated.")
    else:
        schema = parameter_rows[0]["SourceSchema"]
        for column_name in diag003["requiredColumns"]:
            if f"[{column_name}]" not in schema:
                errors.append(f"DIAG-003 parameter schema misses column: {column_name}")

    if internal_text.count(
        """.nodes('.//*[local-name(.)="ParameterList"]/*[local-name(.)="ColumnReference"]')"""
    ) != 1:
        errors.append("DIAG-003 must shred the Showplan ParameterList exactly once per analyzed plan.")
    require_fragments(
        combined_text,
        diag003["valueStatuses"],
        "DIAG-003 value status",
        errors,
    )
    require_fragments(
        combined_text,
        diag003["valueSources"],
        "DIAG-003 value source",
        errors,
    )
    require_fragments(
        analysis_text,
        [
            "#ExecutionPlanAnalysis_ParameterEvidence",
            """N',"parameters":'""",
            "WHEN N'parameters' THEN N'#ExecutionPlanAnalysis_ParameterEvidence'",
        ],
        "DIAG-003 execution-plan projection",
        errors,
    )
    require_fragments(
        showplan_text,
        [
            "#ShowplanAnalysis_Parameters",
            "OPENJSON(@ChildJson,N'$.parameters')",
            "@AllowedResultNames=N'parameters|planWarnings|optimizerContext|runtimeFeedback|queryStoreContext|feedbackAndVariants|findings'",
        ],
        "DIAG-003 multi-plan projection",
        errors,
    )
    if "ParameterList" in showplan_text:
        errors.append("USP_ShowplanAnalysis must not shred ParameterList a second time.")

    diag005 = contract["diag005PlanOptimizerContext"]
    execution_result_names = [
        row["ResultName"]
        for row in result_rows
        if row["ProcedureName"] == "USP_ExecutionPlanAnalysis"
    ]
    for result_name in diag005["canonicalResultSets"]:
        if execution_result_names.count(result_name) != 1:
            errors.append(f"DIAG-005 canonical result set is missing or duplicated: {result_name}")
    require_fragments(
        analysis_text,
        [
            "#ExecutionPlanAnalysis_PlanWarnings",
            "#ExecutionPlanAnalysis_OptimizerContext",
            "#ExecutionPlanAnalysis_RuntimeFeedback",
            "#ExecutionPlanAnalysis_QueryStoreContext",
            "#ExecutionPlanAnalysis_FeedbackAndVariants",
            "N',\"planWarnings\":'",
            "N',\"optimizerContext\":'",
            "N',\"runtimeFeedback\":'",
            "N',\"queryStoreContext\":'",
            "N',\"feedbackAndVariants\":'",
        ],
        "DIAG-005 execution-plan projection",
        errors,
    )
    require_fragments(
        showplan_text,
        [
            "#ShowplanAnalysis_ExecutionPlanSourceContext",
            "OPENJSON(@ChildJson,N'$.planWarnings')",
            "OPENJSON(@ChildJson,N'$.optimizerContext')",
            "OPENJSON(@ChildJson,N'$.runtimeFeedback')",
            "OPENJSON(@ChildJson,N'$.queryStoreContext')",
            "OPENJSON(@ChildJson,N'$.feedbackAndVariants')",
        ],
        "DIAG-005 multi-plan projection",
        errors,
    )
    if (
        showplan_text.count("FROM [sys].[dm_exec_query_stats]") != 1
        or "ELSE N'[sys].[dm_exec_query_stats]'" not in showplan_text
    ):
        errors.append("DIAG-005 ShowplanAnalysis must retain one broad and one mutually exclusive targeted query-stats path.")
    if "sys].[query_store_query_text" in analysis_text:
        errors.append("DIAG-005 must not read Query Store query text.")
    require_fragments(
        combined_text,
        diag005["evidenceStatusCodes"],
        "DIAG-005 evidence status",
        errors,
    )
    require_fragments(
        combined_text,
        diag005["evidenceSources"],
        "DIAG-005 evidence source",
        errors,
    )
    require_fragments(
        diag005_runtime_text,
        [
            "$.planWarnings",
            "$.optimizerContext",
            "$.runtimeFeedback",
            "$.queryStoreContext",
            "$.feedbackAndVariants",
            "@ResultSetArt='TABLE'",
            "@QueryStorePlanId=-1",
        ],
        "DIAG-005 runtime contract",
        errors,
    )
    release_gate_text = (
        repository_root / "Code/Tests/Run_Release_Gate.sql"
    ).read_text(encoding="utf-8-sig")
    if ":r PlanCache/123_DIAG005_Plan_Optimizer_Runtime_Contract.sql" not in release_gate_text:
        errors.append("DIAG-005 runtime contract is not integrated into the release gate.")

    require_fragments(combined_text, contract["directStatusCodes"], "direct status code", errors)
    require_fragments(internal_text, contract["capabilityCodes"], "capability code", errors)
    require_fragments(internal_text, contract["findingCodes"], "finding code", errors)
    require_fragments(evidence_text, contract["evidenceWarningCodes"], "evidence warning code", errors)

    privacy_markers = [
        "Jede externe oder intern erzeugte Evidenz wird vor der",
        "@MitSqlText=1 AND @SensitiveDataConfirmed<>1",
        "UPDATE [#ExecutionPlanAnalysis_HistogramSummaries]",
        "UPDATE [#ExecutionPlanAnalysis_HistogramSteps]",
        "UPDATE [#ExecutionPlanAnalysis_PredicateHistogramMappings]",
        "UPDATE [#ExecutionPlanAnalysis_ParameterEvidence]",
        "UPDATE [#ExecutionPlanAnalysis_QueryStoreContext]",
        "@EvidencePrivacyMode=''TOKENIZED''",
    ]
    require_fragments(analysis_text, privacy_markers, "analysis privacy invariant", errors)
    evidence_privacy_markers = [
        "@RawMode='INCLUDE'",
        "@SensitiveDataConfirmed<>1 OR @IdentifierMode<>'RAW'",
        "@PrivacyMode IN ('RAW','TOKENIZED') THEN [RangeHighKey]",
    ]
    require_fragments(evidence_text, evidence_privacy_markers, "evidence privacy invariant", errors)

    standalone_objects = [
        row["ObjectName"] for row in dependency_rows if row["StandaloneRequired"] == "1"
    ]
    if standalone_objects != contract["standaloneObjects"]:
        errors.append("Standalone dependency closure differs from the frozen public contract.")

    for document in (
        "AI_Metadata/Internal_Documentation/Architecture/Execution_Plan_Analysis_Design_History.md",
        "AI_Metadata/Internal_Documentation/Architecture/Execution_Plan_Analysis_Installation_Contract_History.md",
    ):
        text = (repository_root / document).read_text(encoding="utf-8-sig")
        if "IMPLEMENTED_ACTIONS_GATE" not in text:
            errors.append(f"Verified contract state missing from {document}")

    return errors


def run_self_test() -> None:
    sample = """
CREATE OR ALTER PROCEDURE [monitor].[USP_Example]
      @ExampleId int = NULL
    , @Mode varchar(16) = 'AUTO'
    , @Value nvarchar(max) = NULL OUTPUT
AS
BEGIN
    RETURN;
END;
"""
    expected = [
        ("ExampleId", "int", "NULL"),
        ("Mode", "varchar(16)", "'AUTO'"),
        ("Value", "nvarchar(max)", "NULL OUTPUT"),
    ]
    actual = extract_parameters(sample, "USP_Example")
    if actual != expected:
        raise AssertionError(f"Parameter parser self-test failed: {actual!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        print("Execution Plan Analysis public-contract validator self-test passed.")
        return 0

    errors = validate(args.repository_root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Execution Plan Analysis public contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
