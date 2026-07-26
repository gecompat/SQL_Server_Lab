#!/usr/bin/env python3
"""Validate the LAB-001 Welle 4 CTR-PAIR and CTR-TRIPLE runtime."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REQUIRED_FILES = {
    ".github/workflows/lab-wave4-runtime-validation.yml",
    "Lab/Containers/wave4.compose.yaml",
    "Lab/Containers/wave4.compose.docker.yaml",
    "Lab/Config/resource-profiles.json",
    "Lab/Orchestration/Invoke-DiagnosticLab.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/MultiContainerRuntime.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/ResourceMeasurement.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabMultiContainerUp.ps1",
    "Lab/Validation/Invoke-LabWave4RuntimeTests.ps1",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def text(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def fragments(content: str, required: tuple[str, ...], scope: str, findings: list[str]) -> None:
    for fragment in required:
        require(fragment in content, f"{scope} lacks {fragment}.", findings)


def validate_compose(root: Path, findings: list[str]) -> None:
    compose = text(root, "Lab/Containers/wave4.compose.yaml")
    override = text(root, "Lab/Containers/wave4.compose.docker.yaml")
    for service, role in (
        ("sql-primary", "SQL_PRIMARY"),
        ("sql-secondary", "SQL_SECONDARY"),
        ("sql-tertiary", "SQL_TERTIARY"),
    ):
        fragments(compose, (service + ":", f"lab001.role: {role}"), "Welle 4 Compose", findings)
    fragments(compose, (
        "lab-management:", "lab-data:", "lab001.segment: LAB_MANAGEMENT",
        "lab001.segment: LAB_DATA", "internal: true", "lab001.run-id:",
        "lab001.topology:", "lab001.owner: SQL_SERVER_ANALYZE",
        "MSSQL_COLLATION: SQL_Latin1_General_CP1_CS_AS",
    ), "Welle 4 Compose", findings)
    require(
        compose.count('MSSQL_AGENT_ENABLED: "true"') == 3,
        "Welle 4 Compose does not enable SQL Agent on all nodes.",
        findings,
    )
    fragments(override, (
        "pull_policy: never", "LAB_W4_CONTAINER_MEMORY_LIMIT",
        "LAB_W4_CONTAINER_CPU_LIMIT", "sql-secondary:", "sql-tertiary:",
    ), "Welle 4 Docker override", findings)
    for forbidden in ("ports:", "network_mode: host", "privileged: true", "cap_add:"):
        require(forbidden not in compose.lower(), f"Welle 4 Compose contains {forbidden}.", findings)


def validate_runtime(root: Path, findings: list[str]) -> None:
    private = text(root, "Lab/Orchestration/Modules/DiagnosticLab/Private/MultiContainerRuntime.ps1")
    public = text(root, "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabMultiContainerUp.ps1")
    fragments(private, (
        "CTR-PAIR", "CTR-TRIPLE", "SQL_PRIMARY", "SQL_SECONDARY", "SQL_TERTIARY",
        "DOCKER_EXEC_OUT_OF_BAND", "LAB_MANAGEMENT", "LAB_DATA",
        "Get-LabWave4ServiceContainerId", "^[a-f0-9]{64}$",
        "Get-LabWave4NetworkResources", "lab001.owner", "lab001.run-id",
        "lab001.topology", "lab001.role", "lab001.segment",
        "exactly one management and one data network",
    ), "Welle 4 private runtime", findings)
    fragments(public, (
        "function Invoke-LabMultiContainerUp", "TOPOLOGY_CREATING",
        "Invoke-LabWave4DockerCompose", "@('up', '--detach', $node.ServiceName)",
        "Register-LabResource", "Wait-LabSqlContainerHealthy",
        "SERVERPROPERTY('ProductMajorVersion')", "Install-LabContainerFramework",
        "FRAMEWORK_READY", "Measure-LabContainerResources", "TOPOLOGY_READY",
        "Register-LabDiscoveredDockerResources", "Invoke-LabCleanup",
        "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING", "PODMAN_COMPATIBILITY_ASSIGNED_TO_WAVE9",
    ), "Welle 4 public runtime", findings)
    state = public.find("LifecycleStatus = 'TOPOLOGY_CREATING'")
    pull = public.find("@('image', 'pull', $imageReference)")
    loop = public.find("foreach ($node in $plan.Nodes)", pull)
    compose = public.find("Invoke-LabWave4DockerCompose", loop)
    register = public.find("Register-LabResource", compose)
    health = public.find("Wait-LabSqlContainerHealthy", register)
    framework = public.find("Install-LabContainerFramework", health)
    require(-1 not in (state, pull, loop, compose, register, health, framework)
            and state < pull < loop < compose < register < health < framework,
            "Welle 4 does not persist, start, register, verify, and install sequentially.", findings)
    for forbidden in (
        "system prune", "container prune", "network prune", "volume prune",
        "compose down", "rm -rf", "--name", "tc qdisc", "iptables", "nft ",
    ):
        require(forbidden not in public.lower() and forbidden not in private.lower(),
                f"Welle 4 runtime contains forbidden operation {forbidden}.", findings)


def validate_budget_and_integration(root: Path, findings: list[str]) -> None:
    profiles = json.loads(text(root, "Lab/Config/resource-profiles.json"))
    standard = next(item for item in profiles["ResourceProfiles"] if item["ResourceProfileId"] == "Standard")
    sql = standard["Roles"]["SQL_CONTAINER"]
    require(sql == {
        "MemoryMiB": 4096,
        "LogicalProcessors": 2,
        "SqlMemoryLimitMiB": 3072,
        "MaximumStorageGiB": 48,
    }, "Standard SQL container budget changed unexpectedly.", findings)
    resource = text(root, "Lab/Orchestration/Modules/DiagnosticLab/Private/ResourceMeasurement.ps1")
    fragments(resource, (
        "function Get-LabContainerBudget", "'Compact', 'Standard'",
        "InstanceCount", "$Budget.MemoryMiB * $InstanceCount",
        "$Budget.MaximumStorageGiB * $InstanceCount",
    ), "Resource measurement", findings)
    orchestrator = text(root, "Lab/Orchestration/Invoke-DiagnosticLab.ps1")
    module = text(root, "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1")
    manifest = text(root, "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1")
    fragments(orchestrator, (
        "'CTR-SINGLE', 'CTR-PAIR', 'CTR-TRIPLE'", "'Compact', 'Standard'",
        "Invoke-LabMultiContainerUp", "CTR-PAIR and CTR-TRIPLE require the Standard resource profile.",
    ), "LAB orchestrator", findings)
    fragments(module, ("Private/MultiContainerRuntime.ps1", "Public/Invoke-LabMultiContainerUp.ps1",
                       "'Invoke-LabMultiContainerUp'"), "DiagnosticLab module", findings)
    fragments(manifest, ("ModuleVersion = '0.6.0'", "'Invoke-LabMultiContainerUp'", "'MultiContainer'"),
              "DiagnosticLab manifest", findings)


def validate_tests_and_workflow(root: Path, findings: list[str]) -> None:
    tests = text(root, "Lab/Validation/Invoke-LabWave4RuntimeTests.ps1")
    workflow = text(root, ".github/workflows/lab-wave4-runtime-validation.yml")
    fragments(tests, (
        "Get-LabWave4TopologyPlan", "CTR-PAIR", "CTR-TRIPLE",
        "Get-LabContainerBudget", "TOPOLOGY_CREATING", "Invoke-LabWave4DockerCompose",
        "Management.Automation.Language.Parser",
    ), "Welle 4 runtime tests", findings)
    fragments(workflow, (
        "Validate_LAB001_Wave4_MultiContainerRuntime.py",
        "Invoke-LabWave4RuntimeTests.ps1",
        "Validate Welle 4 multi-container Compose model",
        "Analyze Welle 4 multi-container runtime",
    ), "Welle 4 workflow", findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []
    for relative in REQUIRED_FILES:
        require((root / relative).is_file(), f"Missing Welle 4 runtime file: {relative}", findings)
    if not findings:
        validate_compose(root, findings)
        validate_runtime(root, findings)
        validate_budget_and_integration(root, findings)
        validate_tests_and_workflow(root, findings)
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print("LAB-001 Welle 4 multi-container runtime validated: topologies=CTR-PAIR,CTR-TRIPLE sql_agent=enabled external_evidence=NOT_EXECUTED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
