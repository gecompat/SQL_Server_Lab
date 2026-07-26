#!/usr/bin/env python3
"""Validate the Docker/Podman quick-test Compose contract foundation."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


VERSIONS = (2019, 2022, 2025)
EXPECTED_PORTS = {2019: 14331, 2022: 14332, 2025: 14335}
EXPECTED_GATES = {
    "LAB-GATE-QUICKTEST-DOCKER": "DOCKER_ENGINE",
    "LAB-GATE-QUICKTEST-PODMAN": "PODMAN_ENGINE",
}
ALLOWED_BLOCKING_SCOPES = {
    "QUICKTEST_RUNTIME_NOT_IMPLEMENTED",
    "QUICKTEST_EXTERNAL_EVIDENCE_PENDING",
}
REQUIRED_FILES = (
    ".github/workflows/lab-contract-validation.yml",
    "Documentation/Architecture/Docker_Podman_Quick_Test_System_Requirements.md",
    "Lab/Containers/quick-test.compose.yaml",
    "Lab/Containers/quick-test.compose.docker.yaml",
    "Lab/Containers/quick-test.compose.podman.yaml",
    "Metadata/Quality/Docker_Podman_Quick_Test_Status.json",
    "Metadata/Quality/Lab_External_Evidence_Gates.csv",
)


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def read_text(root: Path, relative_path: str) -> str:
    return (root / relative_path).read_text(encoding="utf-8")


def validate_core(root: Path, findings: list[str]) -> None:
    core = read_text(root, "Lab/Containers/quick-test.compose.yaml")

    require(
        "x-quicktest-healthcheck: &quicktest-healthcheck" in core,
        "Quick-test Compose core lacks the shared SQL healthcheck.",
        findings,
    )
    for fragment in (
        "command -v sqlcmd",
        "SERVERPROPERTY('ProductMajorVersion')",
        'SQLCMDPASSWORD="$$MSSQL_SA_PASSWORD"',
        "MSSQL_COLLATION=SQL_Latin1_General_CP1_CS_AS",
        "MSSQL_MEMORY_LIMIT_MB=${QTLAB_SQL_MEMORY_MB",
        "qt-lab.owner: SQL_SERVER_ANALYZE",
        "qt-lab.scope:",
        "qt-lab.run-id:",
        "quicktest-data:",
    ):
        require(fragment in core, f"Quick-test Compose core lacks {fragment}.", findings)

    require(
        core.count("- MSSQL_SA_PASSWORD") == 1,
        "The SQL credential must be inherited once and not embedded per service.",
        findings,
    )
    require(
        'restart: "no"' in core,
        "Quick-test services must not enable an unbounded restart policy.",
        findings,
    )

    for version in VERSIONS:
        service = f"sql{version}:"
        profile = f"profiles: [sql{version}]"
        image = f"mcr.microsoft.com/mssql/server:{version}-latest"
        port = f"QTLAB_SQL{version}_PORT:-{EXPECTED_PORTS[version]}"
        version_label = f'qt-lab.sql-version: "{version}"'
        for fragment in (service, profile, image, port, version_label):
            require(
                fragment in core,
                f"SQL Server {version} Compose contract lacks {fragment}.",
                findings,
            )
        for role in ("DATA", "LOG", "BACKUP"):
            require(
                f"QTLAB_SQL{version}_{role}_DIR" in core,
                f"SQL Server {version} lacks the {role} bind contract.",
                findings,
            )


def validate_overrides(root: Path, findings: list[str]) -> None:
    for runtime in ("docker", "podman"):
        path = f"Lab/Containers/quick-test.compose.{runtime}.yaml"
        text = read_text(root, path)
        for fragment in (
            "pull_policy: missing",
            "mem_limit: ${QTLAB_MEMORY_LIMIT",
            "cpus: ${QTLAB_CPU_LIMIT",
            f"qt-lab.runtime: {runtime.upper()}",
            "sql2019:",
            "sql2022:",
            "sql2025:",
        ):
            require(fragment in text, f"{runtime} override lacks {fragment}.", findings)
        require(
            "privileged:" not in text and "network_mode: host" not in text,
            f"{runtime} override expands the quick-test privilege boundary.",
            findings,
        )


def validate_status(root: Path, findings: list[str]) -> None:
    status = json.loads(
        read_text(root, "Metadata/Quality/Docker_Podman_Quick_Test_Status.json")
    )
    require(
        status.get("WorkItemId") == "LAB-QUICKTEST-001"
        and status.get("ContractStatus")
        in {
            "VALIDATED_FOUNDATION",
            "IMPLEMENTED_AUTOMATED_GATE",
            "IMPLEMENTED_ACTIONS_GATE",
        }
        and status.get("RuntimeStatus")
        in {"NOT_EXECUTED", "IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING"}
        and status.get("DataClassification") == "PUBLIC_AND_SYNTHETIC",
        "Quick-test Compose status is missing or overstated.",
        findings,
    )
    delivered = " ".join(status.get("DeliveredScope", []))
    for fragment in (
        "SQL Server 2019, 2022, and 2025",
        "Docker and Podman",
        "SQL query",
        "bind contracts",
    ):
        require(fragment in delivered, f"Delivered scope lacks {fragment}.", findings)
    open_scope = " ".join(status.get("OpenScope", []))
    for fragment in (
        "Native Docker runtime evidence",
        "Native Podman runtime evidence",
    ):
        require(fragment in open_scope, f"Open scope lacks {fragment}.", findings)


def validate_gates(root: Path, findings: list[str]) -> None:
    gate_path = root / "Metadata/Quality/Lab_External_Evidence_Gates.csv"
    with gate_path.open(newline="", encoding="utf-8") as handle:
        gates = {row["GateId"]: row for row in csv.DictReader(handle)}
    for gate_id, capability in EXPECTED_GATES.items():
        row = gates.get(gate_id, {})
        require(
            row.get("ScenarioGroup") == "QUICK_TEST_SYSTEM"
            and row.get("RequiredPlatform") == "CONTAINER_LINUX"
            and row.get("RequiredCapability") == capability
            and row.get("ExecutionMode") == "LINUX_NATIVE"
            and row.get("Status") == "NOT_EXECUTED"
            and row.get("EvidencePolicy") == "SYNTHETIC_SUMMARY_ONLY"
            and row.get("BlockingScope") in ALLOWED_BLOCKING_SCOPES,
            f"{gate_id} is missing or overstated.",
            findings,
        )


def validate_integration(root: Path, findings: list[str]) -> None:
    workflow = read_text(root, ".github/workflows/lab-contract-validation.yml")
    for fragment in (
        "Validate_Docker_Podman_QuickTest_ComposeFoundation.py",
        "Validate Docker Podman quick-test Compose foundation",
        "quick-test.compose.docker.yaml",
        "quick-test.compose.podman.yaml",
        "Validate quick-test Docker and Podman Compose models",
    ):
        require(fragment in workflow, f"Workflow integration lacks {fragment}.", findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []

    for relative_path in REQUIRED_FILES:
        require(
            (root / relative_path).is_file(),
            f"Missing required quick-test Compose file: {relative_path}",
            findings,
        )

    if not findings:
        validate_core(root, findings)
        validate_overrides(root, findings)
        validate_status(root, findings)
        validate_gates(root, findings)
        validate_integration(root, findings)

    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1

    print(
        "Docker/Podman quick-test Compose foundation validated: "
        "versions=3 runtimes=2 external_evidence=NOT_EXECUTED."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
