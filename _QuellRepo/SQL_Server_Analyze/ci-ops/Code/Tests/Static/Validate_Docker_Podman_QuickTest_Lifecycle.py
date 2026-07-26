#!/usr/bin/env python3
"""Validate the bounded Docker/Podman quick-test runtime lifecycle."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

REQUIRED_FILES = {
    ".github/workflows/lab-contract-validation.yml",
    ".github/workflows/quicktest-lifecycle-validation.yml",
    "Lab/Install-Lab.ps1",
    "Lab/Uninstall-Lab.ps1",
    "Lab/QuickTest/Public/Install-QuickTestLab.ps1",
    "Lab/QuickTest/Public/Get-QuickTestLabStatus.ps1",
    "Lab/QuickTest/Public/Invoke-QuickTestLabDown.ps1",
    "Lab/QuickTest/Public/Start-QuickTestLab.ps1",
    "Lab/QuickTest/Public/Start-QuickTestStoppedLab.ps1",
    "Lab/QuickTest/Public/Stop-QuickTestLab.ps1",
    "Lab/QuickTest/Public/Restart-QuickTestLab.ps1",
    "Lab/QuickTest/Public/Reset-QuickTestLab.ps1",
    "Lab/QuickTest/Public/Remove-QuickTestLab.ps1",
    "Lab/QuickTest/QuickTestLab.psm1",
    "Lab/QuickTest/README.md",
    "Lab/Validation/Invoke-LabQuickTestLifecycleTests.ps1",
    "Lab/Validation/Invoke-LabQuickTestStopTests.ps1",
    "Lab/Validation/Invoke-LabQuickTestRestartTests.ps1",
    "Lab/Validation/Invoke-LabQuickTestResetTests.ps1",
    "Metadata/Quality/Docker_Podman_Quick_Test_Status.json",
    "Metadata/Quality/Lab_External_Evidence_Gates.csv",
}

EXPECTED_GATES = {
    "LAB-GATE-QUICKTEST-DOCKER": "DOCKER_ENGINE",
    "LAB-GATE-QUICKTEST-PODMAN": "PODMAN_ENGINE",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def text(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def fragments(
    content: str, required: tuple[str, ...], scope: str, findings: list[str]
) -> None:
    for fragment in required:
        require(fragment in content, f"{scope} lacks {fragment}.", findings)


def validate_entrypoint(root: Path, findings: list[str]) -> None:
    entry = text(root, "Lab/Install-Lab.ps1")
    loader = text(root, "Lab/QuickTest/QuickTestLab.psm1")
    fragments(
        entry,
        (
            "'Preflight', 'Install', 'Status', 'Stop', 'Restart', 'Reset', 'Down', 'Start', 'Destroy'",
            "Stop-QuickTestLab",
            "Restart-QuickTestLab",
            "Reset-QuickTestLab",
            "Start-QuickTestStoppedLab",
            "Start-QuickTestLab",
            "Get-QuickTestLabStatus",
            "-Force is supported only with -Action Down, Reset, or Destroy.",
            "Reset requires the existing SQL credential and cannot generate a new one.",
            "RESET_CREDENTIAL_REQUIRED",
        ),
        "Install entrypoint",
        findings,
    )
    prompt = entry.find("if (-not $PSBoundParameters.ContainsKey('Runtime'))")
    for action in ("Stop", "Restart", "Reset", "Start"):
        require(
            0 <= entry.find(f"if ($Action -eq '{action}')") < prompt,
            f"{action} is dispatched after install-time prompts.",
            findings,
        )
    fragments(
        loader,
        (
            "Public/Stop-QuickTestLab.ps1",
            "Public/Restart-QuickTestLab.ps1",
            "Public/Reset-QuickTestLab.ps1",
            "Public/Start-QuickTestStoppedLab.ps1",
            "'Stop-QuickTestLab'",
            "'Restart-QuickTestLab'",
            "'Reset-QuickTestLab'",
            "'Start-QuickTestStoppedLab'",
        ),
        "Module loader",
        findings,
    )


def validate_install_down(root: Path, findings: list[str]) -> None:
    install = text(root, "Lab/QuickTest/Public/Install-QuickTestLab.ps1")
    preflight = install.find("Invoke-QuickTestPreflight")
    approval = install.find("$PSCmdlet.ShouldProcess")
    state = install.find("LifecycleStatus = 'INSTALLING'")
    write = install.find("Write-QuickTestJson", state)
    mutation = install.find("Invoke-QuickTestCompose", write)
    require(
        -1 not in (preflight, approval, state, write, mutation)
        and preflight < approval < state < write < mutation,
        "Install does not persist recovery state before mutation.",
        findings,
    )
    fragments(
        install,
        (
            "LifecycleStatus = 'READY'",
            "LifecycleStatus = 'RECOVERY_CLEANUP'",
            "RecoveryContainerIds",
            "RecoveryNetworkIds",
            "Wait-QuickTestContainerHealthy",
            "SERVERPROPERTY('ProductMajorVersion')",
        ),
        "Install lifecycle",
        findings,
    )

    down = text(root, "Lab/QuickTest/Public/Invoke-QuickTestLabDown.ps1")
    down_state = down.find("LifecycleStatus = 'DOWN_IN_PROGRESS'")
    down_write = down.find("Write-QuickTestJson", down_state)
    down_remove = down.find("Remove-QuickTestRuntimeResources", down_write)
    down_final = down.find("LifecycleStatus = 'DOWN'", down_remove)
    require(
        -1 not in (down_state, down_write, down_remove, down_final)
        and down_state < down_write < down_remove < down_final,
        "Down does not bracket removal with recovery state.",
        findings,
    )
    require("Remove-Item" not in down, "Down deletes local files.", findings)


def validate_stop_start_restart(root: Path, findings: list[str]) -> None:
    stop = text(root, "Lab/QuickTest/Public/Stop-QuickTestLab.ps1")
    fragments(
        stop,
        (
            "STOP_STATE_INVALID",
            "STOP_SCOPE_CONFLICT",
            "LifecycleStatus = 'STOPPING'",
            "LifecycleStatus = 'STOPPED'",
            "LifecycleStatus = 'STOP_FAILED'",
            "qt-lab.run-id",
            "qt-lab.owner",
            "AlreadyStopped",
            "NetworkPreserved = $true",
            "DataPreserved = $true",
        ),
        "Stop lifecycle",
        findings,
    )
    stop_state = stop.find("LifecycleStatus = 'STOPPING'")
    stop_write = stop.find("Write-QuickTestJson", stop_state)
    stop_mutation = stop.find("'stop'", stop_write)
    stop_final = stop.find("LifecycleStatus = 'STOPPED'", stop_mutation)
    require(
        -1 not in (stop_state, stop_write, stop_mutation, stop_final)
        and stop_state < stop_write < stop_mutation < stop_final,
        "Stop does not persist STOPPING before container stop.",
        findings,
    )
    require("Remove-Item" not in stop, "Stop deletes local files.", findings)

    stopped_start = text(root, "Lab/QuickTest/Public/Start-QuickTestStoppedLab.ps1")
    fragments(
        stopped_start,
        (
            "LifecycleStatus -ne 'STOPPED'",
            "START_SCOPE_CONFLICT",
            "LifecycleStatus = 'STARTING'",
            "'container', 'start'",
            "Wait-QuickTestContainerHealthy",
            "SERVERPROPERTY('ProductMajorVersion')",
            "FRAMEWORK_READY",
            "LifecycleStatus = 'READY'",
            "START_STOPPED_RECOVERY",
            "START_STOPPED_RECOVERY_FAILED",
            "RecreatedContainers = $false",
            "LoadedStoredCredential = $false",
        ),
        "Stopped Start lifecycle",
        findings,
    )
    start_state = stopped_start.find("LifecycleStatus = 'STARTING'")
    start_write = stopped_start.find("Write-QuickTestJson", start_state)
    start_mutation = stopped_start.find("'start'", start_write)
    require(
        -1 not in (start_state, start_write, start_mutation)
        and start_state < start_write < start_mutation,
        "Stopped Start does not persist STARTING before container start.",
        findings,
    )
    require(
        "Invoke-QuickTestCompose" not in stopped_start,
        "Stopped Start uses Compose.",
        findings,
    )
    require("AdminSecret" not in stopped_start, "Stopped Start requests a credential.", findings)
    require("Remove-Item" not in stopped_start, "Stopped Start deletes local files.", findings)

    restart = text(root, "Lab/QuickTest/Public/Restart-QuickTestLab.ps1")
    fragments(
        restart,
        (
            "RESTART_STATE_INVALID",
            "RESTART_STOP_FAILED",
            "RESTART_START_FAILED",
            "Stop-QuickTestLab",
            "Start-QuickTestStoppedLab",
            "RuntimeIdentityPreserved",
            "ContainersRestarted",
            "NetworkPreserved = $true",
            "Restarted = $true",
            "Status = 'WHATIF'",
        ),
        "Restart lifecycle",
        findings,
    )
    stop_call = restart.find("Stop-QuickTestLab")
    start_call = restart.find("Start-QuickTestStoppedLab", stop_call)
    final_status = restart.rfind("Get-QuickTestLabStatus")
    require(
        -1 not in (stop_call, start_call, final_status)
        and stop_call < start_call < final_status,
        "Restart does not compose Stop then stopped Start then final Status.",
        findings,
    )
    for forbidden in (
        "Invoke-QuickTestExternalCommand",
        "Invoke-QuickTestCompose",
        "AdminSecret",
        "MSSQL_SA_PASSWORD",
        "Remove-Item",
    ):
        require(forbidden not in restart, f"Restart contains direct operation {forbidden}.", findings)


def validate_reset(root: Path, findings: list[str]) -> None:
    reset = text(root, "Lab/QuickTest/Public/Reset-QuickTestLab.ps1")
    fragments(
        reset,
        (
            "function Reset-QuickTestLab",
            "READ_ONLY_RESET_PREFLIGHT",
            "RESET_PERSISTENT_SCOPE_BLOCKED",
            "RESET_STATE_INVALID",
            "RESET_CREDENTIAL_REQUIRED",
            "RESET_SCOPE_CONFLICT",
            "RESET_SCOPE_INCOMPLETE",
            "RESET_CONFIRMATION_REQUIRED",
            "RESET_INSTALL_FAILED",
            "PersistenceMode -ne 'TEMPORARY'",
            "GeneratedCredentialStored",
            "Test-QuickTestOwnedDirectory",
            "Get-QuickTestResourcesByRunId",
            "Remove-QuickTestLab",
            "Install-QuickTestLab",
            "PreviousRunId",
            "ResetPerformed = $true",
            "DataRecreated = $true",
            "LoadedStoredCredential",
            "Reset did not create a new run ID.",
        ),
        "Reset lifecycle",
        findings,
    )
    persistence_block = reset.find("RESET_PERSISTENT_SCOPE_BLOCKED")
    discovery = reset.find("Get-QuickTestResourcesByRunId")
    approval = reset.find("$PSCmdlet.ShouldProcess")
    destroy = reset.find("Remove-QuickTestLab", approval)
    install = reset.find("Install-QuickTestLab", destroy)
    new_run_check = reset.find("Reset did not create a new run ID.", install)
    require(
        -1 not in (
            persistence_block,
            discovery,
            approval,
            destroy,
            install,
            new_run_check,
        )
        and persistence_block < discovery < approval < destroy < install < new_run_check,
        "Reset does not validate, confirm, destroy, reinstall, and verify in order.",
        findings,
    )
    for forbidden in (
        "Remove-Item",
        "system prune",
        "container prune",
        "network prune",
        "volume prune",
        "compose down",
        "rm -rf",
    ):
        require(forbidden not in reset, f"Reset contains direct operation {forbidden}.", findings)


def validate_status_destroy(root: Path, findings: list[str]) -> None:
    status = text(root, "Lab/QuickTest/Public/Get-QuickTestLabStatus.ps1")
    fragments(
        status,
        (
            "Status = 'DOWN'",
            "'READY'",
            "'STOPPED'",
            "Stopped = $stopped",
            "NetworkPreserved",
            "OwnershipValid",
        ),
        "Status lifecycle",
        findings,
    )
    destroy = text(root, "Lab/QuickTest/Public/Remove-QuickTestLab.ps1")
    fragments(
        destroy,
        (
            "DESTROY_CONFIRMATION_REQUIRED",
            "Remove-QuickTestRuntimeResources",
            "Test-QuickTestOwnedDirectory",
            "Status = 'DESTROYED'",
            "DataRemoved = $true",
        ),
        "Destroy lifecycle",
        findings,
    )
    require("RemoveData" not in destroy, "Destroy exposes partial cleanup.", findings)


def validate_metadata(root: Path, findings: list[str]) -> None:
    status = json.loads(text(root, "Metadata/Quality/Docker_Podman_Quick_Test_Status.json"))
    require(
        status.get("ContractStatus") == "IMPLEMENTED_ACTIONS_GATE"
        and status.get("RuntimeStatus") == "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"
        and status.get("DataClassification") == "PUBLIC_AND_SYNTHETIC",
        "Quick-test status is missing or overstated.",
        findings,
    )
    delivered = " ".join(status.get("DeliveredScope", []))
    opened = " ".join(status.get("OpenScope", []))
    fragments(
        delivered,
        (
            "Install action",
            "Stop action",
            "Restart action",
            "Reset action",
            "Down action",
            "Start action",
            "Destroy action",
        ),
        "Delivered scope",
        findings,
    )
    fragments(
        opened,
        (
            "UpdateFramework",
            "Native Docker runtime evidence",
            "Native Podman runtime evidence",
        ),
        "Open scope",
        findings,
    )
    require("Reset" not in opened, "Delivered Reset remains open.", findings)

    with (root / "Metadata/Quality/Lab_External_Evidence_Gates.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        gates = {row["GateId"]: row for row in csv.DictReader(handle)}
    for gate_id, capability in EXPECTED_GATES.items():
        row = gates.get(gate_id, {})
        require(
            row.get("RequiredCapability") == capability
            and row.get("Status") == "NOT_EXECUTED"
            and row.get("EvidencePolicy") == "SYNTHETIC_SUMMARY_ONLY",
            f"{gate_id} overstates external evidence.",
            findings,
        )


def validate_integration(root: Path, findings: list[str]) -> None:
    lab = text(root, ".github/workflows/lab-contract-validation.yml")
    focused = text(root, ".github/workflows/quicktest-lifecycle-validation.yml")
    reset_tests = text(root, "Lab/Validation/Invoke-LabQuickTestResetTests.ps1")
    readme = text(root, "Lab/QuickTest/README.md")
    require(
        "Validate_Docker_Podman_QuickTest_Lifecycle.py" in lab,
        "LAB workflow no longer runs the lifecycle validator.",
        findings,
    )
    fragments(
        focused,
        (
            "Invoke-LabQuickTestResetTests.ps1",
            "Run focused Reset lifecycle contract",
            "Analyze quick-test Reset lifecycle",
        ),
        "Focused lifecycle workflow",
        findings,
    )
    fragments(
        reset_tests,
        (
            "RESET_PERSISTENT_SCOPE_BLOCKED",
            "READ_ONLY_RESET_PREFLIGHT",
            "Reset WhatIf",
            "ResetPerformed",
            "DataRecreated",
            "PreviousRunId",
            "reset-sentinel.txt",
            "fresh canonical runtime identity",
            "container rm --force",
            "network rm",
        ),
        "Reset tests",
        findings,
    )
    fragments(
        readme,
        (
            "## Reset",
            "TEMPORARY",
            "RESET_PERSISTENT_SCOPE_BLOCKED",
            "new run ID",
            "existing SQL credential",
            "Destroy always removes the complete scope",
            "NOT_EXECUTED",
        ),
        "Quick-test README",
        findings,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []
    for path in sorted(REQUIRED_FILES):
        require((root / path).is_file(), f"Missing lifecycle file: {path}", findings)
    if not findings:
        validate_entrypoint(root, findings)
        validate_install_down(root, findings)
        validate_stop_start_restart(root, findings)
        validate_reset(root, findings)
        validate_status_destroy(root, findings)
        validate_metadata(root, findings)
        validate_integration(root, findings)
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print(
        "Docker/Podman quick-test lifecycle validated: "
        "actions=Install,Status,Stop,Restart,Reset,Down,Start,Destroy "
        "external_evidence=NOT_EXECUTED."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
