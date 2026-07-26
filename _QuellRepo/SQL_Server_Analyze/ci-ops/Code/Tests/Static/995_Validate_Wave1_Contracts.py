#!/usr/bin/env python3
"""Validate Wave-1 output, XML, provenance, and offline version contracts."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path


TRUNCATION_PARAMETERS = (
    "MaxSqlTextZeichen",
    "TextChars",
    "MaxTargetDataZeichen",
)
XML_MODULES = (
    "Code/04_PlanCache/040_USP_PlanDetails.sql",
    "Code/05_QueryStore/020_USP_QueryStoreRuntimeStats.sql",
    "Code/05_QueryStore/040_USP_QueryStorePlanChanges.sql",
    "Code/05_QueryStore/060_USP_QueryStoreForcedPlans.sql",
    "Code/06_ExtendedEvents/020_USP_ExtendedEventsReadEvents.sql",
    "Code/06_ExtendedEvents/030_USP_ExtendedEventsDeadlocks.sql",
    "Code/06_ExtendedEvents/040_USP_ExtendedEventsBlockedProcesses.sql",
    "Code/08_ServerHealth/140_USP_CriticalEngineEvents.sql",
)
PROJECTED_MODULES = (
    "Code/02_CurrentState/010_USP_CurrentSessions.sql",
    "Code/02_CurrentState/020_USP_CurrentRequests.sql",
    "Code/02_CurrentState/030_USP_CurrentBlocking.sql",
    "Code/02_CurrentState/040_USP_CurrentWaits.sql",
    "Code/02_CurrentState/050_USP_CurrentTransactions.sql",
    "Code/02_CurrentState/060_USP_CurrentMemoryGrants.sql",
    "Code/04_PlanCache/010_USP_QueryStats.sql",
    "Code/04_PlanCache/020_USP_QueryHashAnalysis.sql",
    "Code/04_PlanCache/030_USP_PlanCacheHealth.sql",
    "Code/04_PlanCache/040_USP_PlanDetails.sql",
    "Code/05_QueryStore/020_USP_QueryStoreRuntimeStats.sql",
    "Code/05_QueryStore/030_USP_QueryStoreWaitStats.sql",
    "Code/05_QueryStore/040_USP_QueryStorePlanChanges.sql",
    "Code/05_QueryStore/050_USP_QueryStoreRegressions.sql",
    "Code/05_QueryStore/060_USP_QueryStoreForcedPlans.sql",
    "Code/05_QueryStore/070_USP_QueryStoreHints.sql",
    "Code/06_ExtendedEvents/050_USP_ExtendedEventsTargetRuntime.sql",
)
NATIVE_XML_RESULTS = {
    ("USP_PlanDetails", "plans"): "[QueryPlanXml] xml",
    ("USP_QueryStoreRuntimeStats", "runtimeStats"): "[QueryPlan] xml",
    ("USP_QueryStorePlanChanges", "plans"): "[QueryPlan] xml",
    ("USP_QueryStoreForcedPlans", "forcedPlans"): "[QueryPlan] xml",
}


def fail(code: str, location: str) -> None:
    print(f"Welle-1-Vertrag verletzt: code={code} location={location}", file=sys.stderr)
    raise SystemExit(1)


def contains_direct_parameter_truncation(text: str) -> bool:
    parameter_pattern = "|".join(re.escape(name) for name in TRUNCATION_PARAMETERS)
    return bool(
        re.search(
            rf"\bLEFT\s*\(.{{0,800}}?@(?:{parameter_pattern})\b",
            text,
            re.IGNORECASE | re.DOTALL,
        )
    )


def self_test() -> None:
    if not contains_direct_parameter_truncation(
        "SELECT LEFT([source].[query_sql_text],@MaxSqlTextZeichen);"
    ):
        fail("SELF_TEST_FALSE_NEGATIVE", "direct truncation")
    if contains_direct_parameter_truncation(
        "SELECT [projection].[ProjectedValue] FROM [monitor].[TVF_ProjectUnicodeText]"
        "([source].[query_sql_text],@MaxSqlTextZeichen) AS [projection];"
    ):
        fail("SELF_TEST_FALSE_POSITIVE", "projection helper")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()

    if args.self_test:
        self_test()
        print("Wave-1 validator self-test passed: cases=2 findings=0")
        return 0

    for relative in PROJECTED_MODULES:
        text = (root / relative).read_text(encoding="utf-8-sig")
        if contains_direct_parameter_truncation(text):
            fail("DIRECT_PARAMETER_TRUNCATION", relative)
        if "InternalEmitTruncationWarning" not in text:
            fail("TRUNCATION_WARNING_MISSING", relative)
        if not all(token in text for token in ("Characters]", "Bytes]", "IsTruncated]")):
            fail("TRUNCATION_METRICS_MISSING", relative)

    for relative in XML_MODULES:
        text = (root / relative).read_text(encoding="utf-8-sig")
        if re.search(r"\bTRY_(?:CAST|CONVERT)\s*\(\s*xml\b", text, re.IGNORECASE):
            fail("LOSSY_XML_CONVERSION", relative)

    parser_text = (root / "Code/01_Common/099a_USP_InternalParseXmlText.sql").read_text(
        encoding="utf-8-sig"
    )
    for token in ("XML_INVALID", "XML_UNAVAILABLE_LIMIT", "XML_EMPTY", "SOURCE_NULL"):
        if token not in parser_text:
            fail("XML_STATUS_MISSING", token)

    projection_text = (root / "Code/01_Common/087d_TVF_ProjectUnicodeText.sql").read_text(
        encoding="utf-8-sig"
    )
    if "Latin1_General_100_BIN2_SC" in projection_text:
        fail("INVALID_SC_COLLATION", "TVF_ProjectUnicodeText")
    if "Latin1_General_100_CI_AS_SC" not in projection_text:
        fail("SC_COLLATION_MISSING", "TVF_ProjectUnicodeText")

    inventory_path = root / "Metadata/Inventory/ResultSets.csv"
    with inventory_path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    indexed = {(row["ProcedureName"], row["ResultName"]): row for row in rows}
    for key, token in NATIVE_XML_RESULTS.items():
        if key not in indexed or token not in indexed[key]["SourceSchema"]:
            fail("NATIVE_XML_INVENTORY", "/".join(key))
    server_results = [row for row in rows if row["ProcedureName"] == "USP_ServerVersionInformation"]
    if len(server_results) != 7:
        fail("SERVER_VERSION_RESULTSET_COUNT", str(inventory_path.relative_to(root)))
    for row in server_results:
        if row["IsTableExportable"] != "1":
            fail("SERVER_VERSION_TABLE_EXPORT", row["ResultName"])

    build_text = (root / "Code/09_VersionAdaptive/011_SqlServerBuildCatalog.sql").read_text(
        encoding="utf-8-sig"
    )
    lifecycle_text = (
        root / "Code/09_VersionAdaptive/012_SqlServerLifecycleCatalog.sql"
    ).read_text(encoding="utf-8-sig")
    for token in ("15.0.4480.2", "16.0.4265.3", "17.0.4065.4", "2026-07-21"):
        if token not in build_text:
            fail("BUILD_CATALOG_SEED", token)
    for token in ("2030-01-08", "2033-01-11", "2036-01-06", "2026-07-21"):
        if token not in lifecycle_text:
            fail("LIFECYCLE_CATALOG_SEED", token)

    temporal_text = (root / "Code/09_VersionAdaptive/040_USP_TemporalAnalysis.sql").read_text(
        encoding="utf-8-sig"
    )
    first_temp = temporal_text.find("CREATE TABLE [#TemporalAnalysis_")
    lock_timeout = temporal_text.find("SET LOCK_TIMEOUT 0")
    if first_temp < 0 or lock_timeout < first_temp:
        fail("TEMPDB_DDL_AFTER_LOCK_TIMEOUT", "USP_TemporalAnalysis")

    target_text = (
        root / "Code/06_ExtendedEvents/050_USP_ExtendedEventsTargetRuntime.sql"
    ).read_text(encoding="utf-8-sig")
    if "1000000" in target_text.replace(",", ""):
        fail("ARTIFICIAL_TARGET_PAYLOAD_CEILING", "USP_ExtendedEventsTargetRuntime")

    print(
        "Wave-1 contracts passed: projected_modules=17 xml_modules=8 "
        "native_xml_results=4 server_version_results=7 findings=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
