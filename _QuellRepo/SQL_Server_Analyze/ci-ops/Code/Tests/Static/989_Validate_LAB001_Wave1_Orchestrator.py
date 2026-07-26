#!/usr/bin/env python3
"""Validate the LAB-001 Welle 1 orchestration and cleanup safety contracts."""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REQUIRED_FILES = (
    "Lab/Orchestration/Invoke-DiagnosticLab.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1",
    "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/Configuration.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/HostCapability.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/SecretProvider.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/State.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/HostAdapters/LinuxNative.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/HostAdapters/RemoteHost.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Private/HostAdapters/WindowsHyperV.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Get-LabStatus.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabCleanup.ps1",
    "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabPreflight.ps1",
    "Lab/Validation/Invoke-LabWave1Tests.ps1",
)

PUBLIC_FUNCTIONS = (
    "Get-LabStatus",
    "Invoke-LabCleanup",
    "Invoke-LabPreflight",
)

FORBIDDEN_RUNTIME_PREFIXES = (
    "Lab/.artifacts/",
    "Lab/.cache/",
    "Lab/.secrets/",
    "Lab/.state/",
)

FORBIDDEN_SOURCE_PATTERNS = (
    (re.compile(r"(?i)\bInvoke-Expression\b"), "POWERSHELL_INVOKE_EXPRESSION"),
    (re.compile(r"(?i)\bRemove-Item\b[^\r\n]*\s-Recurse\b"), "CLEANUP_RECURSIVE_DELETE"),
    (re.compile(r"(?i)\bRemove-Item\b[^\r\n]*\s-Path\b"), "CLEANUP_NON_LITERAL_PATH"),
    (re.compile(r"(?i)\bRemove-Item\b[^\r\n]*[\*\?\[]"), "CLEANUP_WILDCARD_DELETE"),
    (re.compile(r"(?i)\b(rm|del)\s+(-r[f]?\s+)?[/~]"), "CLEANUP_SHELL_DELETE"),
)


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str


def read_text(path: Path, findings: list[Finding]) -> str:
    try:
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            findings.append(Finding("UTF8_BOM_UNEXPECTED", path.as_posix()))
        if b"\x00" in raw:
            findings.append(Finding("SOURCE_CONTAINS_NUL", path.as_posix()))
        return raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        findings.append(Finding("SOURCE_READ_FAILED", path.as_posix()))
        return ""


def load_csv(path: Path, findings: list[Finding]) -> list[dict[str, str]]:
    try:
        with path.open("r", encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream))
    except (OSError, csv.Error):
        findings.append(Finding("CSV_INVALID", path.as_posix()))
        return []


def load_json(path: Path, findings: list[Finding]) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        findings.append(Finding("JSON_INVALID", path.as_posix()))
        return None


def tracked_or_present_paths(repository_root: Path) -> list[str]:
    if (repository_root / ".git").exists():
        try:
            result = subprocess.run(
                ["git", "-C", str(repository_root), "ls-files", "-z"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            return [
                item.decode("utf-8")
                for item in result.stdout.split(b"\0")
                if item
            ]
        except (OSError, subprocess.CalledProcessError):
            pass
    return [
        path.relative_to(repository_root).as_posix()
        for path in repository_root.rglob("*")
        if path.is_file()
    ]


def validate_required_files(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for relative_path in REQUIRED_FILES:
        path = repository_root / relative_path
        if not path.is_file():
            findings.append(Finding("WAVE1_FILE_MISSING", relative_path))
            continue
        if path.stat().st_size == 0:
            findings.append(Finding("WAVE1_FILE_EMPTY", relative_path))
    return findings


def validate_public_contract(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    script_path = repository_root / "Lab/Orchestration/Invoke-DiagnosticLab.ps1"
    manifest_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1"
    )
    module_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1"
    )
    script = read_text(script_path, findings)
    manifest = read_text(manifest_path, findings)
    module = read_text(module_path, findings)

    for action in ("Preflight", "Status", "Down", "RecoveryCleanup"):
        if f"'{action}'" not in script:
            findings.append(Finding("CLI_ACTION_MISSING", f"{script_path.as_posix()}:{action}"))
    for future_action in (
        "BuildImage",
        "Observe",
        "Reset",
        "Clean",
    ):
        validate_set_match = re.search(
            r"\[ValidateSet\(([^\]]+)\)\]\s*\[string\]\s*\$Action",
            script,
            re.DOTALL,
        )
        if validate_set_match and f"'{future_action}'" in validate_set_match.group(1):
            findings.append(
                Finding(
                    "FUTURE_ACTION_EXPOSED",
                    f"{script_path.as_posix()}:{future_action}",
                )
            )

    if "SupportsShouldProcess" not in script or "$PSCmdlet.ShouldProcess" not in script:
        findings.append(Finding("CLI_WHATIF_CONTRACT_MISSING", script_path.as_posix()))
    if "AllowRemoteExecution" not in script:
        findings.append(Finding("CLI_REMOTE_CONFIRMATION_MISSING", script_path.as_posix()))

    for function_name in PUBLIC_FUNCTIONS:
        if f"'{function_name}'" not in manifest:
            findings.append(
                Finding(
                    "MODULE_EXPORT_MISSING",
                    f"{manifest_path.as_posix()}:{function_name}",
                )
            )
        if f"'{function_name}'" not in module:
            findings.append(
                Finding(
                    "ROOT_MODULE_EXPORT_MISSING",
                    f"{module_path.as_posix()}:{function_name}",
                )
            )
    return findings


def validate_cleanup_contract(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    source_root = repository_root / "Lab/Orchestration"
    source_texts: dict[str, str] = {}
    for path in source_root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".ps1", ".psm1", ".psd1"}:
            source_texts[path.as_posix()] = read_text(path, findings)

    for path, text in source_texts.items():
        for pattern, rule in FORBIDDEN_SOURCE_PATTERNS:
            if pattern.search(text):
                findings.append(Finding(rule, path))

    cleanup_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabCleanup.ps1"
    )
    cleanup = source_texts.get(cleanup_path.as_posix(), "")
    for required_fragment in (
        "OwnerRunId",
        "ResourceId",
        "ExactLocator",
        "Test-LabPathWithinRoot",
        "WildcardPattern",
        "Remove-Item -LiteralPath",
        "CLEANUP_INCOMPLETE",
        "SupportsShouldProcess",
    ):
        if required_fragment not in cleanup:
            findings.append(
                Finding(
                    "CLEANUP_GUARD_MISSING",
                    f"{cleanup_path.as_posix()}:{required_fragment}",
                )
            )

    state_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/State.ps1"
    )
    state = source_texts.get(state_path.as_posix(), "")
    for required_fragment in (
        "FileShare]::None",
        "Move-Item -LiteralPath",
        "WildcardPattern",
        "LOCAL_FILESYSTEM",
        "Test-LabPathWithinRoot",
        "LOCAL_RUNTIME_STATE",
    ):
        if required_fragment not in state:
            findings.append(
                Finding(
                    "STATE_SAFETY_GUARD_MISSING",
                    f"{state_path.as_posix()}:{required_fragment}",
                )
            )
    return findings


def validate_host_and_secret_contract(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    preflight_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabPreflight.ps1"
    )
    mode_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/HostCapability.ps1"
    )
    remote_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/HostAdapters/RemoteHost.ps1"
    )
    secret_path = (
        repository_root
        / "Lab/Orchestration/Modules/DiagnosticLab/Private/SecretProvider.ps1"
    )
    preflight = read_text(preflight_path, findings)
    mode = read_text(mode_path, findings)
    remote = read_text(remote_path, findings)
    secret_provider = read_text(secret_path, findings)

    for fragment in (
        "Get-LabWindowsHyperVHostCapability",
        "Get-LabLinuxHostCapability",
        "Get-LabRemoteHostCapability",
        "Resolve-LabExecutionMode",
        "Test-LabSecretAvailability",
        "Test-LabImageLock",
        "Test-LabNetworkPolicy",
        "host-capabilities.json",
        "preflight-summary.json",
    ):
        if fragment not in preflight:
            findings.append(
                Finding(
                    "PREFLIGHT_COMPONENT_MISSING",
                    f"{preflight_path.as_posix()}:{fragment}",
                )
            )

    for fragment in (
        "DISTRIBUTED",
        "LINUX_NATIVE",
        "WINDOWS_SINGLE_HOST",
        "REQUESTED_MODE_UNAVAILABLE",
        "NO_COMPATIBLE_MODE",
        "FAULT_TARGET_NOT_ISOLATED",
        "MEMORY_RESERVE_UNAVAILABLE",
    ):
        if fragment not in mode:
            findings.append(
                Finding(
                    "CAPABILITY_RULE_MISSING",
                    f"{mode_path.as_posix()}:{fragment}",
                )
            )

    for fragment in (
        "RemoteHostConfiguration.Approved",
        "AllowRemoteExecution",
        "REMOTE_EXECUTION_NOT_CONFIRMED",
        "Remove-PSSession",
        "REMOTE_PREFLIGHT_FAILED",
    ):
        if fragment not in remote:
            findings.append(
                Finding(
                    "REMOTE_GUARD_MISSING",
                    f"{remote_path.as_posix()}:{fragment}",
                )
            )

    for fragment in (
        "ENVIRONMENT",
        "SECRET_MANAGEMENT",
        "INTERACTIVE",
        "ConvertTo-LabSecureString",
        "LAB001_SECRET_",
    ):
        if fragment not in secret_provider:
            findings.append(
                Finding(
                    "SECRET_PROVIDER_CONTRACT_MISSING",
                    f"{secret_path.as_posix()}:{fragment}",
                )
            )
    if "-AsPlainText" in secret_provider:
        findings.append(
            Finding("PLAIN_TEXT_SECURE_STRING_CONVERSION", secret_path.as_posix())
        )
    return findings


def validate_automated_tests(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    test_path = repository_root / "Lab/Validation/Invoke-LabWave1Tests.ps1"
    tests = read_text(test_path, findings)
    for fragment in (
        "PowerShell parser reported an error",
        "Host-class boundary",
        "AUTO must prefer",
        "Network-range collision detection",
        "synthetic image lock",
        "concurrent state lock",
        "WhatIf must not remove",
        "exact registered resource",
        "Repeated cleanup must be idempotent",
        "Wildcard cleanup registration",
        "foreign owner",
        "Sensitive logging properties",
        "Repeated Preflight",
        "Runtime capability vector",
    ):
        if fragment not in tests:
            findings.append(
                Finding(
                    "WAVE1_TEST_CASE_MISSING",
                    f"{test_path.as_posix()}:{fragment}",
                )
            )
    return findings


def validate_status(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    wave_path = repository_root / "Metadata/Quality/Lab_Wave_Status.csv"
    status_path = repository_root / "Metadata/Quality/Implementation_Status.csv"
    scenario_path = repository_root / "Lab/Scenarios/Catalog/scenarios.json"

    wave_rows = load_csv(wave_path, findings)
    wave_map = {row.get("WaveId"): row for row in wave_rows}
    wave_one = wave_map.get("LAB-001-WAVE1", {})
    if wave_one.get("ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE1_CONTRACT_STATUS_INVALID", wave_path.as_posix()))
    if wave_one.get("RuntimeStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("WAVE1_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_two = wave_map.get("LAB-001-WAVE2", {})
    if wave_two.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE2_CONTRACT_STATUS_INVALID", wave_path.as_posix()))
    if wave_two.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE2_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_three = wave_map.get("LAB-001-WAVE3", {})
    if wave_three.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE3_CONTRACT_STATUS_INVALID", wave_path.as_posix()))
    if wave_three.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE3_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    wave_four = wave_map.get("LAB-001-WAVE4", {})
    if wave_four.get("ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("WAVE4_CONTRACT_STATUS_INVALID", wave_path.as_posix()))
    if wave_four.get("RuntimeStatus") != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING":
        findings.append(Finding("WAVE4_RUNTIME_STATUS_INVALID", wave_path.as_posix()))
    for number in range(5, 11):
        row = wave_map.get(f"LAB-001-WAVE{number}", {})
        if row.get("ContractStatus") != "PLANNED":
            findings.append(Finding("FUTURE_WAVE_STATUS_INVALID", wave_path.as_posix()))
        if row.get("RuntimeStatus") != "NOT_EXECUTED":
            findings.append(
                Finding("FUTURE_WAVE_RUNTIME_STATUS_INVALID", wave_path.as_posix())
            )

    status_rows = load_csv(status_path, findings)
    lab_rows = [row for row in status_rows if row.get("WorkItemId") == "LAB-001"]
    if len(lab_rows) != 1:
        findings.append(Finding("IMPLEMENTATION_STATUS_ROW_INVALID", status_path.as_posix()))
    elif lab_rows[0].get("ProductStatus") != "PARTIAL_PRODUCT_FUNCTION":
        findings.append(Finding("IMPLEMENTATION_STATUS_INVALID", status_path.as_posix()))

    scenario_catalog = load_json(scenario_path, findings)
    if not isinstance(scenario_catalog, dict):
        return findings
    if scenario_catalog.get("ProductStatus") != "PARTIAL_PRODUCT_FUNCTION":
        findings.append(Finding("SCENARIO_PRODUCT_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave1ContractStatus") != "IMPLEMENTED_AUTOMATED_GATE":
        findings.append(Finding("SCENARIO_WAVE1_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave2ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("SCENARIO_WAVE2_STATUS_INVALID", scenario_path.as_posix()))
    if scenario_catalog.get("Wave3ContractStatus") != "IMPLEMENTED_ACTIONS_GATE":
        findings.append(Finding("SCENARIO_WAVE3_STATUS_INVALID", scenario_path.as_posix()))
    if (
        scenario_catalog.get("Wave3RuntimeStatus")
        != "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"
    ):
        findings.append(Finding("SCENARIO_WAVE3_RUNTIME_INVALID", scenario_path.as_posix()))
    scenarios = scenario_catalog.get("Scenarios")
    if not isinstance(scenarios, list) or any(
        item.get("ImplementationStatus")
        not in {
            "PLANNED_NOT_IMPLEMENTED",
            "PLANNED_FIXTURE_NOT_IMPLEMENTED",
            "WAVE0_CONTRACT_ONLY",
            "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING",
            "IMPLEMENTED_ACTIONS_GATE",
            "IMPLEMENTED_CONTRACT_FIXTURE",
        }
        for item in scenarios
        if isinstance(item, dict)
    ):
        findings.append(Finding("SCENARIO_RUNTIME_STATUS_OVERSTATED", scenario_path.as_posix()))
    return findings


def validate_privacy_boundary(repository_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in tracked_or_present_paths(repository_root):
        if path == "Lab/Config/lab.config.psd1":
            findings.append(Finding("LOCAL_CONFIG_TRACKED", path))
        if any(path.startswith(prefix) for prefix in FORBIDDEN_RUNTIME_PREFIXES):
            findings.append(Finding("LOCAL_RUNTIME_STATE_TRACKED", path))

    example_path = repository_root / "Lab/Config/lab.config.example.psd1"
    example = read_text(example_path, findings)
    for pattern, rule in (
        (r"(?i)[A-Z]:\\Users\\", "EXAMPLE_WINDOWS_USER_PATH"),
        (r"(?i)/home/[^'\s]+", "EXAMPLE_LINUX_USER_PATH"),
        (r"\b(?:10|127|169\.254|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)\.\d+\.\d+\.\d+\b", "EXAMPLE_PRIVATE_IP"),
        (r"(?i)(Password|Token|PrivateKey)\s*=\s*'[^']+'", "EXAMPLE_SECRET_LITERAL"),
    ):
        if re.search(pattern, example):
            findings.append(Finding(rule, example_path.as_posix()))

    orchestration_root = repository_root / "Lab/Orchestration"
    for path in orchestration_root.rglob("*"):
        if not path.is_file():
            continue
        text = read_text(path, findings)
        if re.search(r"(?i)\bWrite-(Host|Output|Verbose|Debug)\b[^\r\n]*(secret|password|credential|token)", text):
            findings.append(Finding("SENSITIVE_LOGGING_RISK", path.as_posix()))
    return findings


def report(findings: Iterable[Finding]) -> int:
    ordered = sorted(set(findings), key=lambda item: (item.rule, item.path))
    for finding in ordered:
        safe_path = json.dumps(finding.path, ensure_ascii=True)
        print(f"LAB-001 Welle 1 finding: rule={finding.rule} path={safe_path}")
    if ordered:
        print(f"LAB-001 Welle 1 validation failed: findings={len(ordered)}")
        return 1
    print("LAB-001 Welle 1 validation passed: findings=0")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repository_root = args.repository_root.resolve()
    findings: list[Finding] = []
    findings.extend(validate_required_files(repository_root))
    findings.extend(validate_public_contract(repository_root))
    findings.extend(validate_cleanup_contract(repository_root))
    findings.extend(validate_host_and_secret_contract(repository_root))
    findings.extend(validate_automated_tests(repository_root))
    findings.extend(validate_status(repository_root))
    findings.extend(validate_privacy_boundary(repository_root))
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
