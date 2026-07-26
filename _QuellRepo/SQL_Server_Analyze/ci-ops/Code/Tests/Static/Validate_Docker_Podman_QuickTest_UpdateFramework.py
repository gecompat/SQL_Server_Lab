#!/usr/bin/env python3
"""Validate the bounded Docker/Podman quick-test UpdateFramework action."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REQUIRED_FILES = {
    ".github/workflows/quicktest-lifecycle-validation.yml",
    ".github/workflows/quicktest-updateframework-validation.yml",
    "Lab/Update-Framework.ps1",
    "Lab/QuickTest/Public/Update-QuickTestFramework.ps1",
    "Lab/QuickTest/QuickTestLab.psm1",
    "Lab/QuickTest/README.md",
    "Lab/Validation/Invoke-LabQuickTestUpdateFrameworkTests.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/Installer.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Install-LabContainerFramework.ps1",
    "Metadata/Quality/Docker_Podman_Quick_Test_Status.json",
}


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def text(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def fragments(content: str, required: tuple[str, ...], scope: str, findings: list[str]) -> None:
    for fragment in required:
        require(fragment in content, f"{scope} lacks {fragment}.", findings)


def validate_container_installer(root: Path, findings: list[str]) -> None:
    wrapper = text(root, "Lab/Orchestration/Modules/DiagnosticLab/Public/Install-LabContainerFramework.ps1")
    fragments(wrapper, (
        "Classify_Framework.sql", "FRAMEWORK_EXISTING", "FRAMEWORK_MISSING",
        "'UPDATED'", "'INSTALLED'", "Install-LabFramework", "Verify_Framework.sql",
        "FRAMEWORK_READY", "VerificationStatus = 'FRAMEWORK_READY'",
    ), "Container framework installer", findings)
    classify = wrapper.find("Classify_Framework.sql")
    install = wrapper.find("Install-LabFramework", classify)
    verify = wrapper.find("Verify_Framework.sql", install)
    require(-1 not in (classify, install, verify) and classify < install < verify,
            "Container framework installer does not classify, install, and verify in order.", findings)
    installer = text(root, "Lab/Orchestration/Modules/DiagnosticLab/Private/Installer.ps1")
    fragments(installer, (
        "Build-StandaloneInstaller.ps1", "Install_All.generated.sql",
        "Prepare_Framework_Database.sql", "IF DB_ID(N'LabAnalyze') IS NULL", "Invoke-LabSqlFile",
    ), "Canonical framework installer", findings)


def validate_scope_action(root: Path, findings: list[str]) -> None:
    update = text(root, "Lab/QuickTest/Public/Update-QuickTestFramework.ps1")
    fragments(update, (
        "function Update-QuickTestFramework", "FRAMEWORK_STATE_INVALID",
        "FRAMEWORK_SCOPE_NOT_READY", "FRAMEWORK_SCOPE_CONFLICT",
        "FRAMEWORK_OWNERSHIP_MISMATCH", "FRAMEWORK_UPDATE_FAILED",
        "LifecycleStatus -ne 'READY'", "Get-QuickTestLabStatus",
        "Get-QuickTestResourcesByRunId", "qt-lab.run-id", "qt-lab.owner",
        "SQL_SERVER_ANALYZE", "SERVERPROPERTY('ProductMajorVersion')",
        "Install-LabContainerFramework", "FrameworkUpdateStatus", "FrameworkInstances",
        "FrameworkAction", "SuccessfulCount", "FailedCount", "Status = 'WHATIF'",
    ), "UpdateFramework scope action", findings)
    ready_check = update.find("LifecycleStatus -ne 'READY'")
    status_check = update.find("Get-QuickTestLabStatus", ready_check)
    discovery = update.find("Get-QuickTestResourcesByRunId", status_check)
    approval = update.find("$PSCmdlet.ShouldProcess", discovery)
    state = update.find("FrameworkUpdateStatus", approval)
    install = update.find("Install-LabContainerFramework", state)
    final = update.rfind("Status = 'READY'")
    require(-1 not in (ready_check, status_check, discovery, approval, state, install, final)
            and ready_check < status_check < discovery < approval < state < install < final,
            "UpdateFramework does not validate, confirm, persist, install, and report in order.", findings)
    for forbidden in ("Invoke-QuickTestCompose", "AdminSecret", "MSSQL_SA_PASSWORD",
                      "Remove-Item", "container rm", "network rm", "prune"):
        require(forbidden not in update, f"UpdateFramework contains {forbidden}.", findings)


def validate_entrypoint_and_module(root: Path, findings: list[str]) -> None:
    entry = text(root, "Lab/Update-Framework.ps1")
    module = text(root, "Lab/QuickTest/QuickTestLab.psm1")
    fragments(entry, ("SupportsShouldProcess", "Update-QuickTestFramework", "ScopeName",
                      "StateRoot", "Confirm = $false"), "UpdateFramework entrypoint", findings)
    for forbidden in ("AdminSecret", "AcceptEula", "SqlVersions", "Ports", "Runtime =", "GenerateSecret"):
        require(forbidden not in entry, f"UpdateFramework entrypoint exposes {forbidden}.", findings)
    fragments(module, ("Public/Update-QuickTestFramework.ps1", "'Update-QuickTestFramework'"),
              "Quick-test module", findings)


def validate_tests_and_workflow(root: Path, findings: list[str]) -> None:
    tests = text(root, "Lab/Validation/Invoke-LabQuickTestUpdateFrameworkTests.ps1")
    focused = text(root, ".github/workflows/quicktest-lifecycle-validation.yml")
    static_gate = text(root, ".github/workflows/quicktest-updateframework-validation.yml")
    fragments(tests, (
        "FrameworkAction -ne 'INSTALLED'", "FrameworkAction -ne 'UPDATED'",
        "FRAMEWORK_READY", "FrameworkUpdateStatus", "UpdateFramework changed runtime identity",
        "UpdateFramework recreated the container through Compose", "Classify_Framework.sql",
        "Verify_Framework.sql",
    ), "UpdateFramework tests", findings)
    fragments(focused, ("Invoke-LabQuickTestUpdateFrameworkTests.ps1",
                        "Run focused UpdateFramework contract",
                        "Analyze quick-test UpdateFramework action"),
              "Focused lifecycle workflow", findings)
    fragments(static_gate, ("Validate_Docker_Podman_QuickTest_UpdateFramework.py",
                            "Validate static UpdateFramework contract"),
              "UpdateFramework static workflow", findings)


def validate_status_and_docs(root: Path, findings: list[str]) -> None:
    status = json.loads(text(root, "Metadata/Quality/Docker_Podman_Quick_Test_Status.json"))
    delivered = " ".join(status.get("DeliveredScope", []))
    opened = " ".join(status.get("OpenScope", []))
    fragments(delivered, ("UpdateFramework action", "INSTALLED", "UPDATED", "per-instance", "FRAMEWORK_READY"),
              "Delivered UpdateFramework status", findings)
    fragments(opened, ("UpdateFramework execution evidence", "Native Docker runtime evidence",
                       "Native Podman runtime evidence"), "Open external evidence", findings)
    readme = text(root, "Lab/QuickTest/README.md")
    fragments(readme, ("## UpdateFramework", "Lab/Update-Framework.ps1", "fully verified `READY`",
                       "`INSTALLED`", "`UPDATED`", "`FRAMEWORK_READY`",
                       "does not recreate containers",
                       "does not require an externally supplied SQL credential",
                       "FRAMEWORK_UPDATE_FAILED", "NOT_EXECUTED"),
              "Quick-test README", findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []
    for path in sorted(REQUIRED_FILES):
        require((root / path).is_file(), f"Missing UpdateFramework file: {path}", findings)
    if not findings:
        validate_container_installer(root, findings)
        validate_scope_action(root, findings)
        validate_entrypoint_and_module(root, findings)
        validate_tests_and_workflow(root, findings)
        validate_status_and_docs(root, findings)
    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1
    print("Docker/Podman quick-test UpdateFramework validated: classification=INSTALLED_OR_UPDATED verification=FRAMEWORK_READY external_evidence=NOT_EXECUTED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
