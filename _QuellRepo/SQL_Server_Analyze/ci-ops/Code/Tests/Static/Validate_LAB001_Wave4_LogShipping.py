#!/usr/bin/env python3
"""Validate the bounded LAB-LS-001 Log Shipping action contract."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

SCENARIO = "LAB-LS-001"
SCENARIO_ROOT = Path("Lab/Scenarios/Infrastructure/LAB-LS-001")
REQUIRED_FILES = {
    ".github/workflows/lab-wave4-logshipping-validation.yml",
    "Lab/Run-LogShipping-Lab.ps1",
    "Lab/Containers/wave4.compose.yaml",
    "Lab/Contracts/scenario-runbook.schema.json",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/InfrastructureScenarioRuntime.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabLogShippingScenario.ps1",
    "Lab/Validation/Invoke-LabWave4LogShippingTests.ps1",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/scenario.json",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/runbook.json",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Setup_Primary.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Setup_Secondary.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Primary_Backup_Cycle.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Secondary_Copy_Restore_Cycle.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Observe_Primary.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Observe_Secondary.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Cleanup_Primary.sql",
    "Lab/Scenarios/Infrastructure/LAB-LS-001/Cleanup_Secondary.sql",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def text(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def load_json(root: Path, relative: str) -> dict[str, object]:
    return json.loads(text(root, relative))


def load_csv(root: Path, relative: str) -> list[dict[str, str]]:
    with (root / relative).open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def fragments(content: str, expected: tuple[str, ...], scope: str, findings: list[str]) -> None:
    for fragment in expected:
        require(fragment in content, f"{scope} lacks {fragment}.", findings)


def validate_contract(root: Path, findings: list[str]) -> None:
    scenario = load_json(root, str(SCENARIO_ROOT / "scenario.json"))
    runbook = load_json(root, str(SCENARIO_ROOT / "runbook.json"))
    require(
        scenario.get("ScenarioId") == SCENARIO
        and scenario.get("TopologyId") == "CTR-PAIR"
        and scenario.get("ResourceProfile") == "Standard"
        and scenario.get("DataClassification") == "SYNTHETIC"
        and scenario.get("SqlVersions") == [2019, 2022, 2025],
        "LAB-LS-001 scenario boundary is invalid.",
        findings,
    )
    require(
        set(scenario.get("RequiredCapabilities", []))
        == {"DOCKER_ENGINE", "COMPOSE_PROVIDER", "MULTI_CONTAINER_NETWORK", "SQL_AGENT"},
        "LAB-LS-001 capability boundary is invalid.",
        findings,
    )
    expected_codes = {
        "LOG_SHIPPING_HEALTHY_CYCLE_OBSERVED",
        "LOG_SHIPPING_LAG_VISIBLE",
        "BACKUP_CHAIN_VISIBLE",
    }
    finding = (scenario.get("ExpectedFindings") or [{}])[0]
    require(
        finding.get("Analyzer") == "USP_LogShippingStatus"
        and set(finding.get("ExpectedFindingCodes", [])) == expected_codes
        and "exact lag duration" in str(finding.get("AssertionBoundary", "")),
        "LAB-LS-001 finding contract is incomplete.",
        findings,
    )
    require(
        runbook.get("RuntimeAction") == "MULTI_CONTAINER_LOG_SHIPPING"
        and runbook.get("PrimaryAnalyzer") == "USP_LogShippingStatus"
        and runbook.get("WorkerCount") == 0
        and runbook.get("ResetPolicy") == "EXACT_SYNTHETIC_SCOPE",
        "LAB-LS-001 runbook boundary is invalid.",
        findings,
    )
    schema = text(root, "Lab/Contracts/scenario-runbook.schema.json")
    require(
        '"MULTI_CONTAINER_LOG_SHIPPING"' in schema,
        "Runbook schema does not allow the bounded Log Shipping action.",
        findings,
    )


def validate_sql(root: Path, findings: list[str]) -> None:
    primary_setup = text(root, str(SCENARIO_ROOT / "Setup_Primary.sql"))
    secondary_setup = text(root, str(SCENARIO_ROOT / "Setup_Secondary.sql"))
    primary_cycle = text(root, str(SCENARIO_ROOT / "Primary_Backup_Cycle.sql"))
    secondary_cycle = text(root, str(SCENARIO_ROOT / "Secondary_Copy_Restore_Cycle.sql"))
    primary_observe = text(root, str(SCENARIO_ROOT / "Observe_Primary.sql"))
    secondary_observe = text(root, str(SCENARIO_ROOT / "Observe_Secondary.sql"))
    primary_cleanup = text(root, str(SCENARIO_ROOT / "Cleanup_Primary.sql"))
    secondary_cleanup = text(root, str(SCENARIO_ROOT / "Cleanup_Secondary.sql"))

    fragments(
        primary_setup,
        (
            "CREATE DATABASE [LabLs001]",
            "ALTER DATABASE [LabLs001] SET RECOVERY FULL",
            "BACKUP DATABASE [LabLs001]",
            "sp_add_log_shipping_primary_database",
            "sp_add_log_shipping_primary_secondary",
            "LAB_LS_001_Backup",
            "@overwrite = 1",
        ),
        "Primary setup",
        findings,
    )
    fragments(
        secondary_setup,
        (
            "RESTORE DATABASE [LabLs001]",
            "NORECOVERY",
            "sp_add_log_shipping_secondary_primary",
            "sp_add_log_shipping_secondary_database",
            "LAB_LS_001_Copy",
            "LAB_LS_001_Restore",
            "@overwrite = 1",
        ),
        "Secondary setup",
        findings,
    )
    fragments(
        primary_cycle,
        (
            "sp_start_job",
            "sysjobhistory",
            "DATEADD(SECOND, 120",
            "WAITFOR DELAY '00:00:01'",
            "run_status",
            "CycleOrdinal",
        ),
        "Primary backup cycle",
        findings,
    )
    fragments(
        secondary_cycle,
        (
            "LAB_LS_001_Copy",
            "LAB_LS_001_Restore",
            "sp_start_job",
            "DATEADD(SECOND, 120",
            "WAITFOR DELAY '00:00:01'",
        ),
        "Secondary copy/restore cycle",
        findings,
    )
    fragments(
        primary_observe,
        (
            "USP_LogShippingStatus",
            "USP_BackupChainAnalysis",
            "USP_InfrastructureAnalysis",
            "@DatabaseNames = N'LabLs001'",
            "LAB_ANALYZER_JSON=",
        ),
        "Primary observation",
        findings,
    )
    fragments(
        secondary_observe,
        ("USP_LogShippingStatus", "LAB_ANALYZER_JSON="),
        "Secondary observation",
        findings,
    )
    fragments(
        primary_cleanup,
        (
            "sp_delete_log_shipping_primary_secondary",
            "sp_delete_log_shipping_primary_database",
            "sp_delete_job",
            "DROP DATABASE",
            "LAB_CLEANUP_JSON=",
        ),
        "Primary cleanup",
        findings,
    )
    fragments(
        secondary_cleanup,
        (
            "sp_delete_log_shipping_secondary_database",
            "sp_delete_job",
            "DROP DATABASE",
            "LAB_CLEANUP_JSON=",
        ),
        "Secondary cleanup",
        findings,
    )
    all_sql = "\n".join(
        text(root, str(path.relative_to(root)))
        for path in (root / SCENARIO_ROOT).glob("*.sql")
    )
    for forbidden in (
        "xp_cmdshell",
        "sp_configure",
        "SHUTDOWN",
        "KILL ",
        "ALTER SERVER CONFIGURATION",
        "sp_delete_database_backuphistory",
    ):
        require(forbidden.lower() not in all_sql.lower(), f"Scenario SQL contains {forbidden}.", findings)
    require(
        not re.search(r"WAITFOR\s+DELAY\s+'00:0[1-9]:", all_sql, re.IGNORECASE),
        "Scenario SQL uses an unbounded timing assertion.",
        findings,
    )


def validate_runtime(root: Path, findings: list[str]) -> None:
    runtime = text(
        root,
        "Lab/Orchestration/Modules/DiagnosticLab/Private/InfrastructureScenarioRuntime.ps1",
    )
    public = text(
        root,
        "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabLogShippingScenario.ps1",
    )
    entry = text(root, "Lab/Run-LogShipping-Lab.ps1")
    compose = text(root, "Lab/Containers/wave4.compose.yaml")
    fragments(
        runtime,
        (
            "ValidateSet('LAB-LS-001')",
            "TopologyId -ne 'CTR-PAIR'",
            "SQL_PRIMARY_CONTAINER",
            "SQL_SECONDARY_CONTAINER",
            "Assert-LabWave4ContainerOwnership",
            "ScenarioPhase = 'HEALTHY_BACKUP_COPY_RESTORE'",
            "ScenarioPhase = 'VISIBLE_LAG_BACKUP_ONLY'",
            "LOG_SHIPPING_HEALTHY_CYCLE_OBSERVED",
            "LOG_SHIPPING_LAG_VISIBLE",
            "BACKUP_CHAIN_VISIBLE",
            ".lab-scenario-owner",
            "[IO.Directory]::Delete",
        ),
        "Infrastructure runtime",
        findings,
    )
    healthy = runtime.find("ScenarioPhase = 'HEALTHY_BACKUP_COPY_RESTORE'")
    lag = runtime.find("ScenarioPhase = 'VISIBLE_LAG_BACKUP_ONLY'")
    cleanup = runtime.find("ScenarioPhase = 'CLEANUP'")
    require(
        -1 not in (healthy, lag, cleanup) and healthy < lag < cleanup,
        "LAB-LS-001 phases are not ordered.",
        findings,
    )
    for forbidden in (
        "Invoke-LabWave4DockerCompose",
        "container restart",
        "network disconnect",
        "tc netem",
        "iptables",
        "ForEach-Object -Parallel",
        "Remove-Item",
    ):
        require(forbidden.lower() not in runtime.lower(), f"Infrastructure runtime contains {forbidden}.", findings)
    fragments(
        public,
        (
            "Invoke-LabLogShippingScenario",
            "Test-LabLogShippingScenario",
            "ValidateSet('LAB-LS-001')",
            "CleanupStatus -ne 'PASS'",
        ),
        "Public Log Shipping action",
        findings,
    )
    fragments(
        entry,
        ("SupportsShouldProcess", "Invoke-LabLogShippingScenario", "Test-LabLogShippingScenario"),
        "Log Shipping entrypoint",
        findings,
    )
    require(compose.count('MSSQL_AGENT_ENABLED: "true"') == 3, "SQL Agent is not enabled on all Welle 4 nodes.", findings)


def validate_status(root: Path, findings: list[str]) -> None:
    catalog = load_json(root, "Lab/Scenarios/Catalog/scenarios.json")
    catalog_rows = {item["ScenarioId"]: item for item in catalog.get("Scenarios", [])}
    require(
        catalog_rows.get(SCENARIO, {}).get("ImplementationStatus") == "IMPLEMENTED_ACTIONS_GATE",
        "LAB-LS-001 catalog status is not implemented.",
        findings,
    )
    contracts = {row["ScenarioId"]: row for row in load_csv(root, "Lab/Scenarios/Infrastructure/wave4-contracts.csv")}
    require(
        contracts.get(SCENARIO, {}).get("RuntimeImplementationStatus") == "IMPLEMENTED_ACTIONS_GATE",
        "LAB-LS-001 Welle 4 contract status is not implemented.",
        findings,
    )
    for scenario_id, row in contracts.items():
        if scenario_id != SCENARIO:
            require(
                row.get("RuntimeImplementationStatus") == "PLANNED_NOT_IMPLEMENTED",
                f"{scenario_id}: unrelated Welle 4 scenario was marked implemented.",
                findings,
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []
    for relative in sorted(REQUIRED_FILES):
        require((root / relative).is_file(), f"Missing LAB-LS-001 file: {relative}", findings)
    if not findings:
        validate_contract(root, findings)
        validate_sql(root, findings)
        validate_runtime(root, findings)
        validate_status(root, findings)
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print("LAB-LS-001 Log Shipping action validated: healthy-cycle=required visible-lag=ordered-file-evidence native-evidence=NOT_EXECUTED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
