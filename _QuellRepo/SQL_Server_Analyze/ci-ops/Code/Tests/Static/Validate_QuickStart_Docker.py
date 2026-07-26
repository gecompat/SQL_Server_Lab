#!/usr/bin/env python3
"""Validate the isolated Docker QuickStart contract without starting containers."""

from __future__ import annotations

import argparse
from pathlib import Path

REQUIRED_FILES = (
    ".gitignore",
    "QuickStart/README.md",
    "QuickStart/Docker/Setup.ps1",
    "QuickStart/Docker/Internal/Common.ps1",
    "QuickStart/Docker/Internal/PathSafety.ps1",
    "QuickStart/Docker/Internal/Configuration.ps1",
    "QuickStart/Docker/Internal/Configuration/Parameters.ps1",
    "QuickStart/Docker/Internal/Configuration/Environment.ps1",
    "QuickStart/Docker/Internal/Configuration/Storage.ps1",
    "QuickStart/Docker/Internal/Configuration/SetupConfiguration.ps1",
    "QuickStart/Docker/Internal/Runtime.ps1",
    "QuickStart/Docker/Internal/Lifecycle.ps1",
    "QuickStart/Docker/Validation/Invoke-QuickStartPathSafetyTests.ps1",
    "QuickStart/Docker/README.md",
    "QuickStart/Docker/.env.example",
    "QuickStart/Docker/docker-compose.yml",
    "QuickStart/Docker/docker-compose.slow-io.yml",
    ".github/workflows/quickstart-docker-validation.yml",
)


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def read(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def require_fragments(
    content: str, fragments: tuple[str, ...], scope: str, findings: list[str]
) -> None:
    for fragment in fragments:
        require(fragment in content, f"{scope} lacks required fragment: {fragment}", findings)


def validate_setup(root: Path, findings: list[str]) -> None:
    script_paths = (
        "QuickStart/Docker/Setup.ps1",
        "QuickStart/Docker/Internal/Common.ps1",
        "QuickStart/Docker/Internal/PathSafety.ps1",
        "QuickStart/Docker/Internal/Configuration.ps1",
        "QuickStart/Docker/Internal/Configuration/Parameters.ps1",
        "QuickStart/Docker/Internal/Configuration/Environment.ps1",
        "QuickStart/Docker/Internal/Configuration/Storage.ps1",
        "QuickStart/Docker/Internal/Configuration/SetupConfiguration.ps1",
        "QuickStart/Docker/Internal/Runtime.ps1",
        "QuickStart/Docker/Internal/Lifecycle.ps1",
    )
    setup = "\n".join(read(root, path) for path in script_paths)
    require_fragments(
        setup,
        (
            "Assert-SafeEmptyRoot",
            "Assert-RootsDoNotOverlap",
            "Assert-NoReparsePointInExistingPath",
            "Read-RootMarker",
            "Assert-ManagedRoots",
            "Assert-EnvContract",
            "Assert-DockerResourceOwnership",
            "Set-LinuxPersistentStoragePermissions",
            "Assert-OnlyExpectedTopLevelEntries",
            "QUICKSTART_SCOPE_ID",
            "SINGLE_ROOT",
            "SPLIT_DATA_LOG",
            "DOCKER_DESKTOP_WINDOWS",
            "HYPERV_LINUX_DOCKER",
            "Test-LinuxSlowIoConfiguration",
            "SQL_Latin1_General_CP1_CS_AS",
            "MSSQL_AGENT_ENABLED",
            "Build-StandaloneInstaller.ps1",
            "FRAMEWORK_READY",
            "127.0.0.1",
            "Remove-Environment",
        ),
        "Docker QuickStart PowerShell scripts",
        findings,
    )

    prohibited = (
        "docker system prune",
        "docker volume prune",
        "docker image prune",
        "Get-VM |",
        "Remove-VM",
        "Remove-Item -Path *",
        "Remove-Item -LiteralPath '*'",
        "MSSQL_SA_PASSWORD=Example",
    )
    for fragment in prohibited:
        require(fragment not in setup, f"Docker QuickStart scripts contain prohibited fragment: {fragment}", findings)

    require(
        "Remove-Item -LiteralPath $root -Recurse -Force" in setup,
        "Managed root deletion must use an exact literal path.",
        findings,
    )
    require(
        "Assert-OnlyExpectedTopLevelEntries" in setup,
        "Managed data deletion must validate expected top-level entries.",
        findings,
    )


def validate_compose(root: Path, findings: list[str]) -> None:
    compose = read(root, "QuickStart/Docker/docker-compose.yml")
    slow = read(root, "QuickStart/Docker/docker-compose.slow-io.yml")

    require_fragments(
        compose,
        (
            "profiles: [sql2019]",
            "profiles: [sql2022]",
            "profiles: [sql2025]",
            "mcr.microsoft.com/mssql/server:2019-latest",
            "mcr.microsoft.com/mssql/server:2022-latest",
            "mcr.microsoft.com/mssql/server:2025-latest",
            "host_ip: ${BIND_ADDRESS:-127.0.0.1}",
            "MSSQL_COLLATION",
            "MSSQL_DATA_DIR: /var/opt/mssql/data",
            "MSSQL_LOG_DIR: /var/opt/mssql/log",
            "MSSQL_AGENT_ENABLED",
            "quickstart.owner: SQL_SERVER_ANALYZE_QUICKSTART",
            "quickstart.scope:",
            "internal: true",
            "read_only: true",
        ),
        "docker-compose.yml",
        findings,
    )
    require("container_name:" not in compose, "Compose must rely on project-scoped names.", findings)
    require("privileged:" not in compose, "Compose must not use privileged containers.", findings)

    require_fragments(
        slow,
        (
            "blkio_config:",
            "device_read_bps:",
            "device_write_bps:",
            "SLOW_IO_DEVICE",
            "SLOW_IO_READ_BPS",
            "SLOW_IO_WRITE_BPS",
        ),
        "docker-compose.slow-io.yml",
        findings,
    )


def validate_docs_and_ignore(root: Path, findings: list[str]) -> None:
    ignore = read(root, ".gitignore")
    require(
        "QuickStart/Docker/.env" in ignore,
        ".gitignore does not exclude the local QuickStart .env file.",
        findings,
    )
    require(
        "QuickStart/Docker/.env.*.tmp" in ignore,
        ".gitignore does not exclude atomic temporary .env files.",
        findings,
    )

    example = read(root, "QuickStart/Docker/.env.example")
    require("CHANGE_ME_WITH_SETUP_PS1" in example, ".env.example lacks a synthetic secret placeholder.", findings)
    require("SQL_Latin1_General_CP1_CS_AS" in example, ".env.example lacks the required collation.", findings)
    require("MSSQL_SA_PASSWORD='CHANGE_ME_WITH_SETUP_PS1'" in example, ".env.example secret must remain synthetic.", findings)

    quickstart_readme = read(root, "QuickStart/Docker/README.md")
    require_fragments(
        quickstart_readme,
        (
            "Ein Einstiegspunkt",
            "./QuickStart/Docker/Setup.ps1",
            "vom umfangreicheren Verzeichnis `Lab/` getrennt",
            "Single Root",
            "Separate Data/Log Roots",
            "Slow-I/O",
            "Hyper-V",
            "docker system prune",
            "vollständig leer",
        ),
        "QuickStart README",
        findings,
    )

    quickstart_index = read(root, "QuickStart/README.md")
    require(
        "./QuickStart/Docker/Setup.ps1" in quickstart_index,
        "QuickStart index does not expose the single Docker entry point.",
        findings,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []

    for relative in REQUIRED_FILES:
        require((root / relative).is_file(), f"Required file is missing: {relative}", findings)

    if not findings:
        validate_setup(root, findings)
        validate_compose(root, findings)
        validate_docs_and_ignore(root, findings)

    if findings:
        print("Docker QuickStart validation failed:")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print("Docker QuickStart static contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
