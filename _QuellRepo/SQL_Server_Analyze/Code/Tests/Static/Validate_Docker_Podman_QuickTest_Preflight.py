#!/usr/bin/env python3
"""Validate the read-only Docker/Podman quick-test Preflight delivery."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED_FILES = {
    ".github/workflows/lab-contract-validation.yml",
    "Code/Tests/Static/Validate_Docker_Podman_QuickTest_ComposeFoundation.py",
    "Code/Tests/Static/Validate_Docker_Podman_QuickTest_Preflight.py",
    "Documentation/Architecture/Docker_Podman_Quick_Test_System_Requirements.md",
    "Lab/Install-Lab.ps1",
    "Lab/QuickTest/Private/Common.ps1",
    "Lab/QuickTest/Public/Invoke-QuickTestPreflight.ps1",
    "Lab/QuickTest/QuickTestLab.psm1",
    "Lab/QuickTest/README.md",
    "Lab/Validation/Invoke-LabQuickTestPreflightTests.ps1",
    "Metadata/Quality/Docker_Podman_Quick_Test_Status.json",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def read_text(root: Path, relative_path: str) -> str:
    return (root / relative_path).read_text(encoding="utf-8")


def validate_entrypoint(root: Path, findings: list[str]) -> None:
    entrypoint = read_text(root, "Lab/Install-Lab.ps1")
    loader = read_text(root, "Lab/QuickTest/QuickTestLab.psm1")
    common = read_text(root, "Lab/QuickTest/Private/Common.ps1")
    preflight = read_text(
        root, "Lab/QuickTest/Public/Invoke-QuickTestPreflight.ps1"
    )
    preflight_scope = "\n".join((common, preflight))

    for fragment in (
        "'Preflight', 'Install', 'Status', 'Stop', 'Restart', 'Reset', 'Down', 'Start', 'Destroy'",
        "'DOCKER', 'PODMAN'",
        "SqlVersions",
        "Ports",
        "AdminLogin",
        "AdminSecret",
        "SecretEnvironmentVariable",
        "GenerateSecret",
        "ResourceProfile",
        "PersistenceMode",
        "DataRoot",
        "AcceptEula",
        "NonInteractive",
        "SkipImageAvailabilityCheck",
        "QuickTest/QuickTestLab.psm1",
        "Invoke-QuickTestPreflight",
        "Read-Host 'Administrative SQL secret' -AsSecureString",
    ):
        require(fragment in entrypoint, f"Install-Lab.ps1 lacks {fragment}.", findings)

    for fragment in (
        "function Test-QuickTestPassword",
        "function New-QuickTestPassword",
        "function Resolve-QuickTestRuntime",
        "function Test-QuickTestPortAvailable",
        "function Test-QuickTestWritablePath",
        "function Test-QuickTestScopeConflict",
        "function Get-QuickTestAvailableMemoryMiB",
        "function Invoke-QuickTestPreflight",
        "RUNTIME_UNAVAILABLE",
        "COMPOSE_UNAVAILABLE",
        "PORT_CONFLICT",
        "RESOURCE_LIMIT_EXCEEDED",
        "DATA_ROOT_UNAVAILABLE",
        "SECRET_COMPLEXITY_FAILED",
        "EULA_ACCEPTANCE_REQUIRED",
        "SCOPE_CONFLICT",
        "IMAGE_UNAVAILABLE",
        "MutationBoundary = 'READ_ONLY_PREFLIGHT'",
    ):
        require(
            fragment in preflight_scope,
            f"Preflight implementation lacks {fragment}.",
            findings,
        )

    for forbidden in (
        "compose', 'up'",
        "container', 'run'",
        "container', 'create'",
        "container', 'rm'",
        "network', 'create'",
        "network', 'rm'",
        "Set-Content",
        "Add-Content",
        "Out-File",
    ):
        require(
            forbidden not in preflight_scope,
            f"Read-only Preflight contains mutating fragment {forbidden}.",
            findings,
        )
    for forbidden in (
        "Write-Host $plainValue",
        "Write-Output $plainValue",
        "Write-Verbose $plainValue",
        "Write-Debug $plainValue",
    ):
        require(
            forbidden not in preflight_scope,
            f"Credential exposure output fragment detected: {forbidden}.",
            findings,
        )

    require(
        "Invoke-QuickTestPreflight" in loader,
        "Quick-test module no longer exports Preflight.",
        findings,
    )


def validate_status(root: Path, findings: list[str]) -> None:
    status = json.loads(
        read_text(root, "Metadata/Quality/Docker_Podman_Quick_Test_Status.json")
    )
    require(
        status.get("WorkItemId") == "LAB-QUICKTEST-001"
        and status.get("ContractStatus")
        in {"IMPLEMENTED_AUTOMATED_GATE", "IMPLEMENTED_ACTIONS_GATE"}
        and status.get("PreflightStatus") == "IMPLEMENTED_AUTOMATED_GATE"
        and status.get("RuntimeStatus")
        in {"NOT_EXECUTED", "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"}
        and status.get("DataClassification") == "PUBLIC_AND_SYNTHETIC",
        "Quick-test Preflight status is missing or overstated.",
        findings,
    )
    delivered = " ".join(status.get("DeliveredScope", []))
    open_scope = " ".join(status.get("OpenScope", []))
    for fragment in (
        "Interactive and non-interactive PowerShell 7 Preflight entrypoint",
        "runtime and Compose capability detection",
        "host-port, memory, path, image, EULA, and credential-policy checks",
        "Structured READY or PREFLIGHT_FAILED result",
        "Preflight and lifecycle contract tests",
    ):
        require(fragment in delivered, f"Delivered scope lacks {fragment}.", findings)
    for fragment in (
        "Native Docker runtime evidence",
        "Native Podman runtime evidence",
    ):
        require(fragment in open_scope, f"Open scope lacks {fragment}.", findings)


def validate_integration(root: Path, findings: list[str]) -> None:
    workflow = read_text(root, ".github/workflows/lab-contract-validation.yml")
    tests = read_text(root, "Lab/Validation/Invoke-LabQuickTestPreflightTests.ps1")
    readme = read_text(root, "Lab/QuickTest/README.md")
    requirements = read_text(
        root,
        "Documentation/Architecture/Docker_Podman_Quick_Test_System_Requirements.md",
    )

    for fragment in (
        "Validate_Docker_Podman_QuickTest_Preflight.py",
        "Invoke-LabQuickTestPreflightTests.ps1",
        "Run Docker Podman quick-test Preflight tests",
        "Invoke-ScriptAnalyzer",
        "Lab/QuickTest",
        "Install-Lab.ps1",
    ):
        require(fragment in workflow, f"Workflow lacks {fragment}.", findings)
    for fragment in (
        "System.Management.Automation.Language.Parser",
        "Generated quick-test credential",
        "Quick-test default ports",
        "Duplicate quick-test ports",
        "Synthetic ready Preflight",
        "READ_ONLY_PREFLIGHT",
        "RUNTIME_UNAVAILABLE",
    ):
        require(fragment in tests, f"Preflight tests lack {fragment}.", findings)
    for fragment in (
        "read-only",
        "Install-Lab.ps1",
        "Docker",
        "Podman",
        "2019",
        "2022",
        "2025",
        "READ_ONLY_PREFLIGHT",
        "Stop",
        "Restart",
        "Reset",
        "Down",
        "Start",
        "Destroy",
    ):
        require(fragment in readme, f"Quick-test README lacks {fragment}.", findings)
    for fragment in ("Preflight", "Zugangsdaten", "Install-Lab.ps1", "Docker", "Podman"):
        require(
            fragment in requirements,
            f"Preflight delivery is not traceable to requirement fragment {fragment}.",
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
            f"Missing quick-test Preflight file: {relative_path}",
            findings,
        )

    if not findings:
        validate_entrypoint(root, findings)
        validate_status(root, findings)
        validate_integration(root, findings)

    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1

    print("Docker/Podman quick-test Preflight contracts passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
