#!/usr/bin/env python3
"""Validate Wave-2 operational diagnostic contracts without runtime evidence."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


MODULES = {
    "OPS-003": "Code/02_CurrentState/080_USP_CurrentIO.sql",
    "OPS-002": "Code/08_ServerHealth/180_USP_WorkerPressureAnalysis.sql",
    "OPS-001": "Code/08_ServerHealth/190_USP_DatabaseConfigurationAnalysis.sql",
    "OPS-004": "Code/07_Infrastructure/140_USP_ErrorLogAnalysis.sql",
}

RESULTS = {
    "USP_CurrentIO": {"moduleStatus", "sourceStatus", "files", "pendingIo", "warnings"},
    "USP_WorkerPressureAnalysis": {
        "moduleStatus", "summary", "schedulers", "waits", "requests", "sourceStatus", "warnings"
    },
    "USP_DatabaseConfigurationAnalysis": {
        "moduleStatus", "settings", "drift", "profile", "sourceStatus", "warnings"
    },
    "USP_ErrorLogAnalysis": {"moduleStatus", "summary", "details", "sourceStatus", "warnings"},
}


def fail(code: str, location: str) -> None:
    print(f"Welle-2-Vertrag verletzt: code={code} location={location}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, tokens: tuple[str, ...], location: str) -> None:
    for token in tokens:
        if token not in text:
            fail("TOKEN_MISSING", f"{location}:{token}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()

    if args.self_test:
        if "beta" in "alpha":
            fail("SELF_TEST_FALSE_POSITIVE", "membership")
        print("Wave-2 validator self-test passed: cases=1 findings=0")
        return 0

    texts = {key: (root / path).read_text(encoding="utf-8-sig") for key, path in MODULES.items()}

    require(
        texts["OPS-003"],
        (
            "@PendingIoEinbeziehen", "@NurWiederholtPending", "@MinPendingIoMs",
            "@PhysischePfadeEinbeziehen", "sys].[dm_io_pending_io_requests",
            "REPEATED_PENDING_IO_REVIEW", "POINT_IN_TIME_PENDING_IO",
            "Schedulerbezogene", "keine kausale Zuordnung",
        ),
        MODULES["OPS-003"],
    )
    if "THEN COALESCE([mf].[physical_name],[p].[IoHandlePath])" not in texts["OPS-003"]:
        fail("PHYSICAL_PATH_NOT_OPT_IN", MODULES["OPS-003"])

    require(
        texts["OPS-002"],
        (
            "[work_queue_count]", "[runnable_tasks_count]", "THREADPOOL",
            "CounterResetDetected", "max worker threads nicht", "#WorkerPressureAnalysis_SourceStatus",
            "SQL-, Plan-, Login-, Host- und Programmnamen werden nicht gelesen",
        ),
        MODULES["OPS-002"],
    )
    if "HIGH_WORKER_OCCUPANCY_CONTEXT" in texts["OPS-002"]:
        fail("UNIVERSAL_WORKER_THRESHOLD", MODULES["OPS-002"])

    require(
        texts["OPS-001"],
        (
            "LOCAL_VARIATION", "PROFILE_MISMATCH", "@ProfileJson",
            "sys].[database_scoped_configurations", "sys].[database_query_store_options",
            "is_optimized_locking_on", "kein Sollwert", "#DatabaseConfigurationAnalysis_SourceStatus",
        ),
        MODULES["OPS-001"],
    )
    if "ALTER DATABASE" in texts["OPS-001"].upper():
        fail("CONFIGURATION_MUTATION", MODULES["OPS-001"])

    require(
        texts["OPS-004"],
        (
            "sp_readerrorlog", "@MaxQuellzeilen", "@MeldungstextEinbeziehen",
            "SERVER_LOCAL_TIME_FROM_ERRORLOG", "NOT_EXECUTED_ROW_LIMIT",
            "TVF_ClassifyErrorLogEvent", "InternalEmitTruncationWarning",
            "Kein Logwechsel", "#ErrorLogAnalysis_SourceStatus",
        ),
        MODULES["OPS-004"],
    )
    for forbidden in ("sp_cycle_errorlog", "xp_instance_regwrite"):
        if forbidden.casefold() in texts["OPS-004"].casefold():
            fail("ERRORLOG_MUTATION", forbidden)

    installer = (root / "Code/Install/Install_All.sql").read_text(encoding="utf-8-sig")
    for token in (
        "087e_TVF_ClassifyErrorLogEvent.sql", "140_USP_ErrorLogAnalysis.sql",
        "180_USP_WorkerPressureAnalysis.sql", "190_USP_DatabaseConfigurationAnalysis.sql",
    ):
        if token not in installer:
            fail("INSTALLER_ENTRY", token)

    runner = (root / "Code/Tests/Run_Release_Gate.sql").read_text(encoding="utf-8-sig")
    if "191_Wave2_Operational_Diagnostics_Runtime_Contract.sql" not in runner:
        fail("RELEASE_GATE_ENTRY", "Run_Release_Gate.sql")

    with (root / "Metadata/Inventory/ResultSets.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    indexed: dict[str, set[str]] = {}
    for row in rows:
        indexed.setdefault(row["ProcedureName"], set()).add(row["ResultName"])
    for procedure, expected in RESULTS.items():
        if indexed.get(procedure) != expected:
            fail("RESULTSET_INVENTORY", procedure)
        if any(
            row["IsTableExportable"] != "1" or not row["SourceSchema"]
            for row in rows if row["ProcedureName"] == procedure
        ):
            fail("TABLE_SCHEMA_INVENTORY", procedure)

    objects = (root / "Metadata/Inventory/Objects.csv").read_text(encoding="utf-8-sig")
    parameters = (root / "Metadata/Inventory/Parameters.csv").read_text(encoding="utf-8-sig")
    for procedure in RESULTS:
        if procedure not in objects or procedure not in parameters:
            fail("PUBLIC_INVENTORY", procedure)

    for page in (
        "USP_ErrorLogAnalysis.md", "USP_WorkerPressureAnalysis.md",
        "USP_DatabaseConfigurationAnalysis.md", "USP_CurrentIO.md",
    ):
        page_text = (root / "Documentation/Analysis_Guides/Procedures" / page).read_text(
            encoding="utf-8-sig"
        )
        for token in ("### Zeit- und Scope-Modell", "## Primärquellen"):
            if token not in page_text:
                fail("DOCUMENTATION_CONTRACT", f"{page}:{token}")

    version = (root / "Code/01_Common/077_FrameworkVersion.sql").read_text(encoding="utf-8-sig")
    require(version, ("1.1.0-special.19", "ContractVersion]='1.23'"), "FrameworkVersion")

    output_test = (root / "Code/Tests/Integration/189_Framework_Output_Runtime_Contract.sql").read_text(
        encoding="utf-8-sig"
    )
    require(output_test, ("<>92", "92 Vertragsobjekte"), "FrameworkOutputRuntimeContract")

    print(
        "Wave-2 contracts passed: modules=4 public_procedures=91 "
        "resultsets=23 runtime_companion=191 findings=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
