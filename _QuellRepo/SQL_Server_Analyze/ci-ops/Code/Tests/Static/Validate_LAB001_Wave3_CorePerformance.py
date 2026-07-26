#!/usr/bin/env python3
"""Validate LAB-001 Welle 3 core-performance action contracts."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


EXPECTED_SCENARIOS = {
    "LAB-CPU-001",
    "LAB-CPU-002",
    "LAB-CPU-003",
    "LAB-MEM-001",
    "LAB-MEM-002",
    "LAB-MEM-003",
    "LAB-TEMP-001",
    "LAB-TEMP-002",
    "LAB-TEMP-003",
    "LAB-TEMP-005",
    "LAB-IO-004",
    "LAB-LOG-001",
    "LAB-LOG-002",
    "LAB-REC-001",
    "LAB-CONC-001",
    "LAB-CONC-002",
    "LAB-DEAD-001",
    "LAB-DEAD-002",
    "LAB-DEAD-003",
    "LAB-DEAD-004",
    "LAB-LATCH-001",
    "LAB-LATCH-002",
    "LAB-LATCH-003",
    "LAB-PLAN-001",
    "LAB-PLAN-002",
    "LAB-PLAN-003",
    "LAB-PLAN-004",
    "LAB-PLAN-005",
    "LAB-QS-001",
    "LAB-QS-002",
    "LAB-IDX-001",
    "LAB-IDX-002",
    "LAB-IDX-003",
    "LAB-COL-001",
    "LAB-XE-001",
    "LAB-VERSION-001",
    "LAB-VECTOR-001",
    "LAB-EXECPLAN-001",
    "LAB-CAP-001",
}

REQUIRED_FILES = {
    "Lab/Contracts/scenario-runbook.schema.json",
    "Lab/Contracts/contract-fixture.schema.json",
    "Lab/Scenarios/Performance/_Shared/Setup.sql",
    "Lab/Scenarios/Performance/_Shared/Worker.sql",
    "Lab/Scenarios/Performance/_Shared/Observe.sql",
    "Lab/Scenarios/Performance/_Shared/Cleanup.sql",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabVersionMatrix.ps1",
    "Lab/Validation/Invoke-LabWave3Tests.ps1",
    "Metadata/Quality/Lab_Wave_Status.csv",
    "Metadata/Quality/Lab_External_Evidence_Gates.csv",
}

FORBIDDEN_RUNTIME_PATTERNS = {
    r"docker\s+(?:system|container|image|network|volume)\s+prune": "broad Docker prune",
    r"\brm\s+-rf\b": "recursive filesystem deletion",
    r"Remove-Item\s+[^;\r\n]*-[Rr]ecurse[^;\r\n]*\*": "wildcard recursive deletion",
    r"DROP\s+DATABASE\s+(?!\[Lab001Wave3\])": "non-synthetic database drop",
    r"\bUSE\s+\[": "database context switch in versioned lab SQL",
}


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def validate_scenarios(root: Path, findings: list[str]) -> None:
    catalog = load_json(root / "Lab/Scenarios/Catalog/scenarios.json")
    planned = {
        item["ScenarioId"]: item
        for item in catalog["Scenarios"]
        if item.get("PlannedWave") == 3
    }
    require(
        set(planned) == EXPECTED_SCENARIOS,
        "Welle 3 catalog membership is not the declared 39-scenario set.",
        findings,
    )

    performance_root = root / "Lab/Scenarios/Performance"
    actual_directories = {
        path.name
        for path in performance_root.iterdir()
        if path.is_dir() and path.name != "_Shared"
    }
    require(
        actual_directories == EXPECTED_SCENARIOS,
        "Welle 3 scenario directories do not match the catalog.",
        findings,
    )

    for scenario_id in sorted(EXPECTED_SCENARIOS):
        scenario_dir = performance_root / scenario_id
        manifest_path = scenario_dir / "scenario.json"
        runbook_path = scenario_dir / "runbook.json"
        require(manifest_path.is_file(), f"{scenario_id}: scenario.json missing.", findings)
        require(runbook_path.is_file(), f"{scenario_id}: runbook.json missing.", findings)
        if not manifest_path.is_file() or not runbook_path.is_file():
            continue

        manifest = load_json(manifest_path)
        runbook = load_json(runbook_path)
        require(
            manifest.get("ScenarioId") == scenario_id
            and runbook.get("ScenarioId") == scenario_id,
            f"{scenario_id}: identity mismatch.",
            findings,
        )
        require(
            manifest.get("SqlVersions") == runbook.get("SqlVersions"),
            f"{scenario_id}: SQL-version mismatch.",
            findings,
        )
        require(
            runbook.get("FixedSeed") == 1701,
            f"{scenario_id}: fixed seed is not 1701.",
            findings,
        )
        require(
            isinstance(runbook.get("WorkerCount"), int)
            and 0 <= runbook["WorkerCount"] <= 8,
            f"{scenario_id}: worker count is unbounded.",
            findings,
        )
        require(
            runbook.get("ScenarioTimeoutSeconds", 0) <= 600
            and runbook.get("WorkerTimeoutSeconds", 0) <= 120,
            f"{scenario_id}: timeout exceeds the contract.",
            findings,
        )
        expectations = manifest.get("ExpectedFindings", [])
        finding_codes = {
            code
            for expectation in expectations
            for code in expectation.get("ExpectedFindingCodes", [])
        }
        require(
            runbook.get("FindingCode") in finding_codes,
            f"{scenario_id}: runbook finding is absent from the manifest.",
            findings,
        )
        require(
            runbook.get("PrimaryAnalyzer") in manifest.get("Observe", {}).get(
                "Analyzers", []
            ),
            f"{scenario_id}: primary analyzer is absent from Observe.",
            findings,
        )
        require(
            "exact wait" in manifest.get("ExpectedFindings", [{}])[0]
            .get("AssertionBoundary", "")
            .lower(),
            f"{scenario_id}: exact-wait assertion boundary is missing.",
            findings,
        )

        is_fixture = scenario_id == "LAB-DEAD-004"
        if is_fixture:
            fixture_path = scenario_dir / "fixture.json"
            require(fixture_path.is_file(), "LAB-DEAD-004 fixture is missing.", findings)
            if fixture_path.is_file():
                fixture = load_json(fixture_path)
                require(
                    fixture.get("RuntimeEvidenceClaim") == "NOT_CLAIMED"
                    and fixture.get("DataClassification") == "PUBLIC_FIXTURE"
                    and fixture.get("Status") == "IMPLEMENTED_CONTRACT_FIXTURE",
                    "LAB-DEAD-004 overstates fixture evidence.",
                    findings,
                )
            require(
                runbook.get("RuntimeAction") == "CONTRACT_FIXTURE"
                and manifest.get("TopologyId") == "FIXTURE-ONLY"
                and planned[scenario_id].get("ImplementationStatus")
                == "IMPLEMENTED_CONTRACT_FIXTURE",
                "LAB-DEAD-004 fixture boundary is inconsistent.",
                findings,
            )
        else:
            require(
                runbook.get("RuntimeAction") in {"SQL_ONLY", "CONTAINER_RESTART"}
                and manifest.get("TopologyId") == "CTR-SINGLE"
                and manifest.get("DataClassification") == "SYNTHETIC"
                and planned[scenario_id].get("ImplementationStatus")
                == "IMPLEMENTED_ACTIONS_GATE",
                f"{scenario_id}: runtime action status is inconsistent.",
                findings,
            )


def validate_version_lane(root: Path, findings: list[str]) -> None:
    image_lock = load_json(root / "Lab/Config/image-lock.example.json")
    expected_references = {
        "2019": "mcr.microsoft.com/mssql/server:2019-latest",
        "2022": "mcr.microsoft.com/mssql/server:2022-latest",
        "2025": "mcr.microsoft.com/mssql/server:2025-latest",
    }
    images = {
        image["ProductVersion"]: image
        for image in image_lock.get("Images", [])
        if image.get("ProductFamily") == "SQL_SERVER"
    }
    require(
        set(images) == {"2019", "2022", "2025"},
        "The public image lock does not contain exactly three SQL version lanes.",
        findings,
    )
    for version, image in images.items():
        require(
            image.get("Status") == "UNRESOLVED_EXAMPLE"
            and image.get("Digest") == "SHA256_DIGEST_REQUIRED"
            and image.get("ReadableReference") == expected_references[version]
            and re.fullmatch(
                r"mcr\.microsoft\.com/mssql/server:[A-Za-z0-9._-]+",
                image.get("ReadableReference", ""),
            )
            is not None,
            f"SQL Server {version} image-lock example is not safely unresolved.",
            findings,
        )

    configuration = (
        root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/Configuration.ps1"
    ).read_text(encoding="utf-8")
    resolver = (
        root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/ContainerRuntime.ps1"
    ).read_text(encoding="utf-8")
    matrix = (
        root
        / "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabVersionMatrix.ps1"
    ).read_text(encoding="utf-8")
    require(
        "ContainerImageLogicalIds = $containerImageLogicalIds" in configuration
        and "AcceptSqlServerEula = [bool] $configuration.AcceptSqlServerEula"
        in configuration,
        "Resolved configuration omits the image map or explicit EULA flag.",
        findings,
    )
    require(
        "[ValidateSet(2019, 2022, 2025)]" in resolver
        and "ContainerImageLogicalIds[[string] $SqlVersion]" in resolver,
        "Container image resolution is not version-bound.",
        findings,
    )
    require(
        "foreach ($sqlVersion in $requiredVersions)" in matrix
        and "Invoke-LabCleanup" in matrix
        and "finally" in matrix,
        "The sequential version matrix lacks per-version cleanup.",
        findings,
    )


def validate_runtime_safety(root: Path, findings: list[str]) -> None:
    files = [
        root / "Lab/Scenarios/Performance/_Shared/Setup.sql",
        root / "Lab/Scenarios/Performance/_Shared/Worker.sql",
        root / "Lab/Scenarios/Performance/_Shared/Observe.sql",
        root / "Lab/Scenarios/Performance/_Shared/Cleanup.sql",
        root
        / "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabScenario.ps1",
        root
        / "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabVersionMatrix.ps1",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in files)
    for pattern, label in FORBIDDEN_RUNTIME_PATTERNS.items():
        if re.search(pattern, combined, flags=re.IGNORECASE):
            findings.append(f"Forbidden {label} detected.")

    cleanup = files[3].read_text(encoding="utf-8")
    setup = files[0].read_text(encoding="utf-8")
    require(
        "context_info] = @ContextToken" in cleanup
        and "@DatabaseOwner <> @LabRunId" in cleanup
        and "@NamedServerObjectExists = 1" in cleanup
        and "Cleanup refused an unowned fixed server-object name" in cleanup
        and "DBCC FREEPROCCACHE(@PlanHandle)" in cleanup
        and "DROP DATABASE [Lab001Wave3]" in cleanup,
        "Cleanup lacks run-token, database-marker, or targeted-plan boundaries.",
        findings,
    )
    require(
        "A fixed synthetic server-object name is already in use" in setup
        and "CLASSIFIER_FUNCTION = NULL" not in cleanup,
        "Server-object collision or Resource Governor preservation is unsafe.",
        findings,
    )
    scenario_runtime = files[4].read_text(encoding="utf-8")
    require(
        "Get-LabDockerObjectLabel" in scenario_runtime
        and "$currentOwner -ne $LabRunId" in scenario_runtime
        and "Complete-LabSqlWorkers" in scenario_runtime
        and "CleanupStatus PASS" in scenario_runtime,
        "Scenario orchestration lacks ownership or cleanup verification.",
        findings,
    )
    observe = files[2].read_text(encoding="utf-8")
    require(
        "wait_time_ms" not in observe.lower()
        and "LAB_ASSERTION_JSON=" in observe
        and "AlternativeEvidenceUsed" in observe,
        "Observe.sql uses an exact wait assertion or lacks alternative evidence.",
        findings,
    )


def validate_status(root: Path, findings: list[str]) -> None:
    with (root / "Metadata/Quality/Lab_Wave_Status.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        rows = {row["WaveId"]: row for row in csv.DictReader(handle)}
    wave = rows.get("LAB-001-WAVE3", {})
    require(
        wave.get("ContractStatus") == "IMPLEMENTED_ACTIONS_GATE"
        and wave.get("RuntimeStatus") == "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING",
        "Welle 3 status is missing or overstated.",
        findings,
    )

    with (root / "Metadata/Quality/Lab_External_Evidence_Gates.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        gates = {row["GateId"]: row for row in csv.DictReader(handle)}
    gate = gates.get("LAB-GATE-WAVE3-VERSION-MATRIX", {})
    require(
        gate.get("Status") == "NOT_EXECUTED"
        and gate.get("BlockingScope") == "WAVE3_EXTERNAL_EVIDENCE",
        "Welle 3 external evidence gate is missing or overstated.",
        findings,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []

    for relative_path in sorted(REQUIRED_FILES):
        require(
            (root / relative_path).is_file(),
            f"Missing required Welle 3 file: {relative_path}",
            findings,
        )
    validate_scenarios(root, findings)
    validate_version_lane(root, findings)
    validate_runtime_safety(root, findings)
    validate_status(root, findings)

    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print("LAB-001 Welle 3 core-performance contracts validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
