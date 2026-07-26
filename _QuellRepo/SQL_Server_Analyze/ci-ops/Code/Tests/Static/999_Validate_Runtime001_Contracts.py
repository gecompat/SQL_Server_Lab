#!/usr/bin/env python3
"""Validate the RUNTIME-001 External Runtime and SQL CLR public contract."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path


EXTERNAL_PATH = Path("Code/09_VersionAdaptive/090_USP_ExternalRuntimeAnalysis.sql")
CLR_PATH = Path("Code/09_VersionAdaptive/100_USP_ClrAnalysis.sql")


def fail(code: str, location: str) -> None:
    print(f"RUNTIME-001 contract violated: code={code} location={location}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, tokens: tuple[str, ...], location: str) -> None:
    for token in tokens:
        if token not in text:
            fail("TOKEN_MISSING", f"{location}:{token}")


def executable_text(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"--[^\r\n]*", " ", text)
    return re.sub(r"N?'(?:''|[^'])*'", "''", text, flags=re.DOTALL)


def self_test() -> None:
    sample = "SELECT N'sp_execute_external_script is documentation'; -- CREATE ASSEMBLY"
    stripped = executable_text(sample)
    if "sp_execute_external_script" in stripped or "CREATE ASSEMBLY" in stripped:
        fail("SELF_TEST_LITERAL_STRIP", "executable_text")
    if re.search(r"\[x\]\.\[(?:content|parameters|environment_variables)\]", "[x].[content]", re.I) is None:
        fail("SELF_TEST_SENSITIVE_COLUMN", "regex")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("RUNTIME-001 validator self-test passed: cases=2 findings=0")
        return 0

    root = Path(args.repository_root).resolve()
    external = (root / EXTERNAL_PATH).read_text(encoding="utf-8-sig")
    clr = (root / CLR_PATH).read_text(encoding="utf-8-sig")

    require(
        external,
        (
            "CREATE OR ALTER PROCEDURE [monitor].[USP_ExternalRuntimeAnalysis]",
            "@AnalysisClass='EXTERNAL_RUNTIME_CURRENT'",
            "@MitDateimetadaten",
            "@MitBerechtigungsanalyse",
            "@MitSitzungskontext",
            "[sys].[external_languages]",
            "[sys].[external_language_files]",
            "[sys].[external_libraries]",
            "[sys].[external_library_files]",
            "[sys].[dm_external_script_requests]",
            "[r].[external_script_request_id]=[er].[external_script_request_id]",
            "[sys].[dm_external_script_execution_stats]",
            "[sys].[dm_resource_governor_external_resource_pools]",
            "[sys].[dm_server_services]",
            "[sys].[dm_os_performance_counters]",
            "[monitor].[TVF_InterpretPerformanceCounter]",
            "[CounterDelta]",
            "[DeltaStatus]='DELTA_AVAILABLE'",
            "RESET_BOUNDARY",
            "@RequiredServicePermission",
            "@RequiredPerformancePermission",
            "@ResultName=N'findings'",
            "@SourceTable=N'#ExternalRuntimeAnalysis_Findings'",
        ),
        str(EXTERNAL_PATH),
    )
    require(
        clr,
        (
            "CREATE OR ALTER PROCEDURE [monitor].[USP_ClrAnalysis]",
            "@AnalysisClass='CLR_CURRENT'",
            "@MitModulzuordnung",
            "@MitBerechtigungsanalyse",
            "@MitSitzungskontext",
            "[sys].[assemblies]",
            "[sys].[assembly_modules]",
            "[sys].[assembly_references]",
            "[sys].[assembly_types]",
            "[sys].[dm_clr_properties]",
            "[sys].[dm_clr_appdomains]",
            "[sys].[dm_clr_loaded_assemblies]",
            "[sys].[dm_clr_tasks]",
            "[sys].[dm_os_tasks]",
            "WHERE [a].[AppDomainAddress] IS NOT NULL",
            "[r].[executing_managed_code]=1",
            "[a].[DatabaseId]=[l].[DatabaseId] AND [a].[AssemblyId]=[l].[AssemblyId]",
            "[sys].[dm_os_memory_clerks]",
            "[monitor].[TVF_InterpretPerformanceCounter]",
            "@ResultName=N'findings'",
            "@SourceTable=N'#ClrAnalysis_Findings'",
        ),
        str(CLR_PATH),
    )

    for path, text in ((EXTERNAL_PATH, external), (CLR_PATH, clr)):
        stripped = executable_text(text)
        for forbidden in (
            "sp_execute_external_script",
            "CREATE EXTERNAL LANGUAGE",
            "CREATE EXTERNAL LIBRARY",
            "CREATE ASSEMBLY",
            "ALTER ASSEMBLY",
            "sp_configure",
            "GRANT ",
        ):
            if forbidden.casefold() in stripped.casefold():
                fail("MUTATING_OR_EXECUTING_PATH", f"{path}:{forbidden}")

    sensitive_patterns = {
        EXTERNAL_PATH: (
            r"\[(?:elf|lf)\]\.\[(?:content|parameters|environment_variables)\]",
            r"\[sys\]\.\[dm_exec_sql_text\]",
            r"\[sys\]\.\[dm_exec_query_plan\]",
        ),
        CLR_PATH: (
            r"\[sys\]\.\[assembly_files\]",
            r"\[sys\]\.\[sql_modules\]",
            r"\[sys\]\.\[dm_exec_sql_text\]",
            r"\[sys\]\.\[dm_exec_query_plan\]",
            r"\[(?:hash|description)\]\s+FROM\s+\[sys\]\.\[trusted_assemblies\]",
        ),
    }
    for path, patterns in sensitive_patterns.items():
        text = external if path == EXTERNAL_PATH else clr
        for pattern in patterns:
            if re.search(pattern, text, re.IGNORECASE | re.DOTALL):
                fail("SENSITIVE_SOURCE_REFERENCE", f"{path}:{pattern}")

    installer = (root / "Code/Install/Install_All.sql").read_text(encoding="utf-8-sig")
    if installer.find("090_USP_ExternalRuntimeAnalysis.sql") < 0 or installer.find("100_USP_ClrAnalysis.sql") < 0:
        fail("INSTALLER_ENTRY", "Code/Install/Install_All.sql")
    if installer.find("090_USP_ExternalRuntimeAnalysis.sql") > installer.find("100_USP_ClrAnalysis.sql"):
        fail("INSTALLER_ORDER", "Code/Install/Install_All.sql")

    with (root / "Metadata/Inventory/Objects.csv").open(encoding="utf-8-sig", newline="") as handle:
        objects = {row["ObjectName"] for row in csv.DictReader(handle)}
    for procedure in ("USP_ExternalRuntimeAnalysis", "USP_ClrAnalysis"):
        if procedure not in objects:
            fail("OBJECT_INVENTORY", procedure)

    with (root / "Metadata/Inventory/ResultSets.csv").open(encoding="utf-8-sig", newline="") as handle:
        results = {(row["ProcedureName"], row["ResultName"]): row for row in csv.DictReader(handle)}
    for procedure in ("USP_ExternalRuntimeAnalysis", "USP_ClrAnalysis"):
        row = results.get((procedure, "findings"))
        if row is None or row["IsTableExportable"] != "1" or not row["SourceSchema"]:
            fail("RESULTSET_INVENTORY", procedure)

    runner = (root / "Code/Tests/Run_Release_Gate.sql").read_text(encoding="utf-8-sig")
    if "198_Runtime001_External_Runtime_CLR_Runtime_Contract.sql" not in runner:
        fail("RELEASE_GATE_ENTRY", "Code/Tests/Run_Release_Gate.sql")

    version = (root / "Code/01_Common/077_FrameworkVersion.sql").read_text(encoding="utf-8-sig")
    require(version, ("1.1.0-special.19", "ContractVersion]='1.23'"), "FrameworkVersion")

    output_contract = (root / "Code/Tests/Integration/189_Framework_Output_Runtime_Contract.sql").read_text(
        encoding="utf-8-sig"
    )
    require(output_contract, ("<>92", "92 Vertragsobjekte"), "FrameworkOutputRuntimeContract")

    print("RUNTIME-001 contracts passed: modules=2 primary_resultsets=2 findings=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
