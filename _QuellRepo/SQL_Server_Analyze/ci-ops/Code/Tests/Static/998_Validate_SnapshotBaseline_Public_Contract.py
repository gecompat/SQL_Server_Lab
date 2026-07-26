#!/usr/bin/env python3
"""Validate the optional SC-023 public, installer, and repository boundary."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import tempfile
from dataclasses import dataclass


FRAMEWORK_INSTALLER = pathlib.PurePosixPath(
    "Code/Install/Install_SnapshotBaseline_Framework.sql"
)
TARGET_INSTALLER = pathlib.PurePosixPath(
    "Code/Install/Install_SnapshotBaseline_Target.sql"
)
INSTALL_ALL = pathlib.PurePosixPath("Code/Install/Install_All.sql")
SNAPSHOT_BUILDER = pathlib.PurePosixPath(
    "Code/Install/Build-SnapshotBaselineInstallers.ps1"
)
GENERATED_FRAMEWORK_INSTALLER = pathlib.PurePosixPath(
    "Code/Install/generated/Install_SnapshotBaseline_Framework.generated.sql"
)
GENERATED_TARGET_INSTALLER = pathlib.PurePosixPath(
    "Code/Install/generated/Install_SnapshotBaseline_Target.generated.sql"
)
SOURCE_ROOT = pathlib.PurePosixPath("Code/10_SnapshotBaseline")
PUBLIC_CONTRACT = pathlib.PurePosixPath(
    "Metadata/Quality/SnapshotBaseline_Public_Contract.json"
)

EXPECTED_FRAMEWORK_INCLUDES = (
    "Code/00_Setup/000_Preflight_und_Schema.sql",
    "Code/10_SnapshotBaseline/010_SnapshotTargetConfiguration.sql",
    "Code/10_SnapshotBaseline/080_USP_ConfigureSnapshotTarget.sql",
    "Code/10_SnapshotBaseline/090_USP_RunSnapshotCollectionCycle.sql",
    "Code/10_SnapshotBaseline/100_USP_PurgeSnapshotData.sql",
)

EXPECTED_TARGET_INCLUDES = (
    "Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql",
    "Code/10_SnapshotBaseline/020_InternalConfigureSnapshotPolicy.sql",
    "Code/10_SnapshotBaseline/040_InternalPrepareCollectionCycle.sql",
    "Code/10_SnapshotBaseline/050_InternalCompletePerformanceCounterCycle.sql",
    "Code/10_SnapshotBaseline/060_InternalFinalizeCollectionCycle.sql",
    "Code/10_SnapshotBaseline/070_InternalPurgeExpiredData.sql",
)

PUBLIC_APIS = (
    "USP_ConfigureSnapshotTarget",
    "USP_RunSnapshotCollectionCycle",
    "USP_PurgeSnapshotData",
)

TARGET_TABLES = (
    "PackageVersion",
    "RetentionPolicy",
    "CollectorPolicy",
    "CaptureRun",
    "ModuleStatus",
    "Scope",
    "MetricDefinition",
    "MetricSample",
    "PayloadSnapshot",
    "PurgeRun",
)

TARGET_INTERNAL_PROCEDURES = (
    "InternalConfigureSnapshotPolicy",
    "InternalPrepareCollectionCycle",
    "InternalCompletePerformanceCounterCycle",
    "InternalFinalizeCollectionCycle",
    "InternalPurgeExpiredData",
)


@dataclass(frozen=True)
class ExpectedParameter:
    name: str
    data_type: str
    default: str | None
    output: bool = False


# Frozen public V1 surface: names, order, types, defaults and OUTPUT directions
# may not silently drift.
EXPECTED_PARAMETERS: dict[str, tuple[ExpectedParameter, ...]] = {
    "USP_ConfigureSnapshotTarget": (
        ExpectedParameter("TargetDatabaseName", "sysname", None),
        ExpectedParameter("IsEnabled", "bit", "1"),
        ExpectedParameter("SchedulerType", "varchar(16)", "'EXTERNAL'"),
        ExpectedParameter("CollectionIntervalSeconds", "smallint", "30"),
        ExpectedParameter("MaxRows", "int", "1000"),
        ExpectedParameter("PayloadEnabled", "bit", "0"),
        ExpectedParameter("RawRetentionDays", "smallint", "14"),
        ExpectedParameter("PayloadRetentionDays", "smallint", "7"),
        ExpectedParameter("RollupRetentionDays", "smallint", "180"),
        ExpectedParameter("SoftBudgetMB", "int", "10240"),
        ExpectedParameter("PurgeIntervalMinutes", "smallint", "60"),
        ExpectedParameter("PurgeBatchRows", "int", "10000"),
        ExpectedParameter("BudgetAction", "varchar(32)", "'PURGE_EXPIRED_THEN_STOP'"),
        ExpectedParameter("PrintMeldungen", "bit", "1"),
        ExpectedParameter("Hilfe", "bit", "0"),
        ExpectedParameter("StatusCodeOut", "varchar(40)", "NULL", True),
        ExpectedParameter("IsPartialOut", "bit", "NULL", True),
        ExpectedParameter("ErrorNumberOut", "int", "NULL", True),
        ExpectedParameter("ErrorMessageOut", "nvarchar(2048)", "NULL", True),
    ),
    "USP_RunSnapshotCollectionCycle": (
        ExpectedParameter("SchedulerType", "varchar(16)", "'EXTERNAL'"),
        ExpectedParameter("RunEvenIfNotDue", "bit", "0"),
        ExpectedParameter("ResultSetArt", "varchar(16)", "'CONSOLE'"),
        ExpectedParameter("ResultTablesJson", "nvarchar(max)", "NULL"),
        ExpectedParameter("JsonErzeugen", "bit", "0"),
        ExpectedParameter("Json", "nvarchar(max)", "NULL", True),
        ExpectedParameter("PrintMeldungen", "bit", "1"),
        ExpectedParameter("Hilfe", "bit", "0"),
        ExpectedParameter("CaptureRunIdOut", "bigint", "NULL", True),
        ExpectedParameter("StatusCodeOut", "varchar(40)", "NULL", True),
        ExpectedParameter("IsPartialOut", "bit", "NULL", True),
        ExpectedParameter("ErrorNumberOut", "int", "NULL", True),
        ExpectedParameter("ErrorMessageOut", "nvarchar(2048)", "NULL", True),
    ),
    "USP_PurgeSnapshotData": (
        ExpectedParameter("MaxBatches", "int", "10"),
        ExpectedParameter("Force", "bit", "0"),
        ExpectedParameter("ResultSetArt", "varchar(16)", "'CONSOLE'"),
        ExpectedParameter("ResultTablesJson", "nvarchar(max)", "NULL"),
        ExpectedParameter("JsonErzeugen", "bit", "0"),
        ExpectedParameter("Json", "nvarchar(max)", "NULL", True),
        ExpectedParameter("PrintMeldungen", "bit", "1"),
        ExpectedParameter("Hilfe", "bit", "0"),
        ExpectedParameter("PurgeRunIdOut", "bigint", "NULL", True),
        ExpectedParameter("StatusCodeOut", "varchar(40)", "NULL", True),
        ExpectedParameter("IsPartialOut", "bit", "NULL", True),
        ExpectedParameter("ErrorNumberOut", "int", "NULL", True),
        ExpectedParameter("ErrorMessageOut", "nvarchar(2048)", "NULL", True),
    ),
}

ALLOWED_USE_CONTEXTS = {
    "DeineDatenbank",
    "DeineSnapshotDatenbank",
    "master",
    "model",
    "msdb",
    "tempdb",
}

INCLUDE_PATTERN = re.compile(r"(?m)^\s*:r\s+(.+?)\s*$")
PROCEDURE_PATTERN = re.compile(
    r"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+"
    r"\[(?P<schema>[^\]]+)\]\.\[(?P<name>[^\]]+)\]"
    r"(?P<parameters>.*?)\bAS\s*\bBEGIN\b",
    re.IGNORECASE | re.DOTALL,
)
USE_PATTERN = re.compile(r"(?im)^\s*USE\s+\[([^\]\r\n]+)\]")

FORBIDDEN_MUTATIONS = (
    ("RIGHTS_DDL", re.compile(r"(?im)^\s*(?:GRANT|DENY|REVOKE)\s+")),
    (
        "PRINCIPAL_DDL",
        re.compile(r"(?im)^\s*CREATE\s+(?:LOGIN|USER|ROLE)\b"),
    ),
    (
        "ROLE_MEMBERSHIP",
        re.compile(r"(?im)^\s*ALTER\s+ROLE\b.*\b(?:ADD|DROP)\s+MEMBER\b"),
    ),
    (
        "AGENT_JOB_DDL",
        re.compile(r"(?i)\bsp_(?:add|update|delete)_job(?:step|server)?\b"),
    ),
    (
        "AGENT_SCHEDULE_DDL",
        re.compile(r"(?i)\bsp_(?:add|update|delete)_schedule\b"),
    ),
)

SENSITIVE_LITERAL_PATTERNS = (
    ("EMAIL_ADDRESS", re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")),
    ("USER_PROFILE_PATH", re.compile(r"(?i)\b[A-Z]:\\Users\\[^\\\s]+")),
    (
        "POSIX_HOME_PATH",
        re.compile(r"(?i)(?<![A-Za-z0-9_])/(?:home|Users)/[A-Za-z0-9._-]+/"),
    ),
    (
        "SECRET_LITERAL",
        re.compile(
            r"(?i)\b(?:password|pwd|token|secret|connectionstring)\b\s*[:=]\s*"
            r"(?:N)?(?:'[^'\r\n]+'|\"[^\"\r\n]+\"|[^\s,;\r\n]+)"
        ),
    ),
)


def normalize_type(value: str) -> str:
    return re.sub(r"\s+", "", value).casefold()


def normalize_default(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = re.sub(r"\s+", "", value).upper()
    while normalized.startswith("(") and normalized.endswith(")"):
        normalized = normalized[1:-1]
    if normalized.startswith("N'"):
        normalized = normalized[1:]
    return normalized


def split_parameters(text: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    in_string = False
    index = 0
    while index < len(text):
        char = text[index]
        if char == "'":
            if in_string and index + 1 < len(text) and text[index + 1] == "'":
                index += 2
                continue
            in_string = not in_string
        elif not in_string:
            if char == "(":
                depth += 1
            elif char == ")" and depth > 0:
                depth -= 1
            elif char == "," and depth == 0:
                parts.append(text[start:index])
                start = index + 1
        index += 1
    parts.append(text[start:])
    return [part.strip() for part in parts if part.strip()]


PARAMETER_PATTERN = re.compile(
    r"^@(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s+"
    r"(?P<type>[A-Za-z]+(?:\s*\(\s*(?:MAX|\d+)"
    r"(?:\s*,\s*\d+)?\s*\))?)"
    r"(?:\s*=\s*(?P<default>.*?))?"
    r"(?:\s+(?P<output>OUTPUT))?$",
    re.IGNORECASE | re.DOTALL,
)


def parse_parameters(text: str) -> dict[str, ExpectedParameter]:
    parsed: dict[str, ExpectedParameter] = {}
    for fragment in split_parameters(text):
        match = PARAMETER_PATTERN.match(fragment)
        if not match:
            continue
        default = match.group("default")
        output = match.group("output") is not None
        if default and re.search(r"\s+OUTPUT\s*$", default, re.IGNORECASE):
            default = re.sub(r"\s+OUTPUT\s*$", "", default, flags=re.IGNORECASE)
            output = True
        parameter = ExpectedParameter(
            name=match.group("name"),
            data_type=normalize_type(match.group("type")),
            default=normalize_default(default),
            output=output,
        )
        parsed[parameter.name.casefold()] = parameter
    return parsed


def resolve_includes(
    repository_root: pathlib.Path, installer_path: pathlib.Path, errors: list[str]
) -> list[pathlib.Path]:
    if not installer_path.is_file():
        errors.append(f"INSTALLER_MISSING:{installer_path.name}")
        return []
    text = installer_path.read_text(encoding="utf-8-sig")
    include_values = [match.group(1).strip().strip('"') for match in INCLUDE_PATTERN.finditer(text)]
    if not include_values:
        errors.append(f"INSTALLER_HAS_NO_INCLUDES:{installer_path.name}")
        return []

    resolved: list[pathlib.Path] = []
    for value in include_values:
        candidate = (installer_path.parent / value).resolve()
        try:
            candidate.relative_to(repository_root.resolve())
        except ValueError:
            errors.append(f"INCLUDE_OUTSIDE_REPOSITORY:{installer_path.name}")
            continue
        if not candidate.is_file():
            errors.append(f"INCLUDE_MISSING:{installer_path.name}")
            continue
        resolved.append(candidate)
    if len(resolved) != len(set(resolved)):
        errors.append(f"DUPLICATE_INCLUDE:{installer_path.name}")
    return resolved


def combined_text(installer_path: pathlib.Path, includes: list[pathlib.Path]) -> str:
    parts: list[str] = []
    if installer_path.is_file():
        parts.append(installer_path.read_text(encoding="utf-8-sig"))
    parts.extend(path.read_text(encoding="utf-8-sig") for path in includes)
    return "\n".join(parts)


def validate_repository(repository_root: pathlib.Path) -> list[str]:
    errors: list[str] = []
    framework_path = repository_root / FRAMEWORK_INSTALLER
    target_path = repository_root / TARGET_INSTALLER
    install_all_path = repository_root / INSTALL_ALL
    source_root = repository_root / SOURCE_ROOT
    public_contract_path = repository_root / PUBLIC_CONTRACT

    if not public_contract_path.is_file():
        errors.append("PUBLIC_CONTRACT_MISSING")
    else:
        try:
            public_contract = json.loads(public_contract_path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            errors.append("PUBLIC_CONTRACT_INVALID_JSON")
        else:
            if public_contract.get("contractId") != "SC-023-PUBLIC-V1":
                errors.append("PUBLIC_CONTRACT_ID")
            if public_contract.get("contractVersion") != 1:
                errors.append("PUBLIC_CONTRACT_VERSION")
            if public_contract.get("releaseState") != "IMPLEMENTED_ACTIONS_GATE":
                errors.append("PUBLIC_CONTRACT_RELEASE_STATE")
            if public_contract.get("targetSqlServerMajorVersions") != [15, 16, 17]:
                errors.append("PUBLIC_CONTRACT_TARGET_VERSIONS")
            expected_public_procedures = [f"monitor.{name}" for name in PUBLIC_APIS]
            if public_contract.get("publicProcedures") != expected_public_procedures:
                errors.append("PUBLIC_CONTRACT_PROCEDURE_ORDER")
            package_boundary = public_contract.get("packageBoundary", {})
            if package_boundary.get("frameworkInstaller") != FRAMEWORK_INSTALLER.as_posix():
                errors.append("PUBLIC_CONTRACT_FRAMEWORK_INSTALLER")
            if package_boundary.get("targetInstaller") != TARGET_INSTALLER.as_posix():
                errors.append("PUBLIC_CONTRACT_TARGET_INSTALLER")
            if package_boundary.get("standaloneBuilder") != SNAPSHOT_BUILDER.as_posix():
                errors.append("PUBLIC_CONTRACT_STANDALONE_BUILDER")
            if package_boundary.get(
                "generatedFrameworkInstaller"
            ) != GENERATED_FRAMEWORK_INSTALLER.as_posix():
                errors.append("PUBLIC_CONTRACT_GENERATED_FRAMEWORK_INSTALLER")
            if package_boundary.get(
                "generatedTargetInstaller"
            ) != GENERATED_TARGET_INSTALLER.as_posix():
                errors.append("PUBLIC_CONTRACT_GENERATED_TARGET_INSTALLER")
            if package_boundary.get("coreInstallsPackage") is not False:
                errors.append("PUBLIC_CONTRACT_CORE_BOUNDARY")

    builder_path = repository_root / SNAPSHOT_BUILDER
    if not builder_path.is_file():
        errors.append("SNAPSHOT_STANDALONE_BUILDER_MISSING")

    framework_includes = resolve_includes(repository_root, framework_path, errors)
    target_includes = resolve_includes(repository_root, target_path, errors)
    framework_text = combined_text(framework_path, framework_includes)
    target_text = combined_text(target_path, target_includes)

    if set(framework_includes) & set(target_includes):
        errors.append("INSTALLER_CLOSURES_OVERLAP")

    observed_framework_includes = tuple(
        path.relative_to(repository_root).as_posix() for path in framework_includes
    )
    observed_target_includes = tuple(
        path.relative_to(repository_root).as_posix() for path in target_includes
    )
    if observed_framework_includes != EXPECTED_FRAMEWORK_INCLUDES:
        errors.append("FRAMEWORK_INSTALLER_CLOSURE_OR_ORDER")
    if observed_target_includes != EXPECTED_TARGET_INCLUDES:
        errors.append("TARGET_INSTALLER_CLOSURE_OR_ORDER")

    if not install_all_path.is_file():
        errors.append("INSTALL_ALL_MISSING")
        install_all_text = ""
    else:
        install_all_text = install_all_path.read_text(encoding="utf-8-sig")

    if re.search(
        r"SnapshotBaseline|SnapshotTargetConfiguration|\[snapshot\]\.",
        install_all_text,
        re.IGNORECASE,
    ):
        errors.append("OPTIONAL_PACKAGE_PRESENT_IN_INSTALL_ALL")

    snapshot_sources = set(source_root.rglob("*.sql")) if source_root.is_dir() else set()
    if not snapshot_sources:
        errors.append("SNAPSHOT_SOURCE_SET_MISSING")
    included_snapshot_sources = {
        path
        for path in framework_includes + target_includes
        if source_root in path.parents
    }
    if snapshot_sources - included_snapshot_sources:
        errors.append("SOURCE_NOT_IN_INSTALLER_CLOSURE")
    if included_snapshot_sources - snapshot_sources:
        errors.append("UNKNOWN_SOURCE_IN_INSTALLER_CLOSURE")

    procedures = list(PROCEDURE_PATTERN.finditer(framework_text))
    framework_api_matches = {
        match.group("name"): match
        for match in procedures
        if match.group("schema").casefold() == "monitor"
        and match.group("name") in PUBLIC_APIS
    }

    for api in PUBLIC_APIS:
        api_definitions = [
            item
            for item in procedures
            if item.group("schema").casefold() == "monitor"
            and item.group("name") == api
        ]
        match = framework_api_matches.get(api)
        if not api_definitions:
            errors.append(f"PUBLIC_API_MISSING:{api}")
            continue
        if len(api_definitions) != 1:
            errors.append(f"PUBLIC_API_DEFINITION_COUNT:{api}")
            continue
        if re.search(re.escape(api), target_text, re.IGNORECASE):
            errors.append(f"PUBLIC_API_IN_TARGET_INSTALLER:{api}")
        if re.search(re.escape(api), install_all_text, re.IGNORECASE):
            errors.append(f"PUBLIC_API_IN_INSTALL_ALL:{api}")

        actual = parse_parameters(match.group("parameters"))
        expected_order = tuple(parameter.name for parameter in EXPECTED_PARAMETERS[api])
        actual_order = tuple(parameter.name for parameter in actual.values())
        if actual_order != expected_order:
            errors.append(f"PARAMETER_ORDER_OR_EXTRA:{api}")
        for expected in EXPECTED_PARAMETERS[api]:
            observed = actual.get(expected.name.casefold())
            if observed is None:
                errors.append(f"PARAMETER_MISSING:{api}:{expected.name}")
                continue
            if observed.data_type != normalize_type(expected.data_type):
                errors.append(f"PARAMETER_TYPE:{api}:{expected.name}")
            if observed.default != normalize_default(expected.default):
                errors.append(f"PARAMETER_DEFAULT:{api}:{expected.name}")
            if observed.output != expected.output:
                errors.append(f"PARAMETER_DIRECTION:{api}:{expected.name}")

    if not re.search(
        r"\[monitor\]\.\[SnapshotTargetConfiguration\]",
        framework_text,
        re.IGNORECASE,
    ):
        errors.append("FRAMEWORK_CONFIGURATION_OBJECT_MISSING")
    if re.search(
        r"\[monitor\]\.\[SnapshotTargetConfiguration\]",
        target_text,
        re.IGNORECASE,
    ):
        errors.append("FRAMEWORK_CONFIGURATION_OBJECT_IN_TARGET")

    for table_name in TARGET_TABLES:
        if not re.search(
            rf"\[snapshot\]\.\[{re.escape(table_name)}\]",
            target_text,
            re.IGNORECASE,
        ):
            errors.append(f"TARGET_OBJECT_MISSING:{table_name}")
        if re.search(
            rf"CREATE\s+TABLE\s+\[snapshot\]\.\[{re.escape(table_name)}\]",
            framework_text,
            re.IGNORECASE | re.DOTALL,
        ):
            errors.append(f"TARGET_TABLE_IN_FRAMEWORK_INSTALLER:{table_name}")

    target_procedures = [
        match
        for match in PROCEDURE_PATTERN.finditer(target_text)
        if match.group("schema").casefold() == "snapshot"
    ]
    if not target_procedures:
        errors.append("TARGET_INTERNAL_PROCEDURE_MISSING")
    observed_target_procedures = tuple(
        match.group("name") for match in target_procedures
    )
    if observed_target_procedures != TARGET_INTERNAL_PROCEDURES:
        errors.append("TARGET_INTERNAL_PROCEDURE_CLOSURE_OR_ORDER")
    for match in target_procedures:
        if not match.group("name").startswith("Internal"):
            errors.append("TARGET_PUBLIC_PROCEDURE_FORBIDDEN")

    for label, text in (("FRAMEWORK", framework_text), ("TARGET", target_text)):
        for rule_code, pattern in FORBIDDEN_MUTATIONS:
            if pattern.search(text):
                errors.append(f"FORBIDDEN_{rule_code}:{label}")
        for match in USE_PATTERN.finditer(text):
            if match.group(1) not in ALLOWED_USE_CONTEXTS:
                errors.append(f"NON_SYNTHETIC_DATABASE_CONTEXT:{label}")
        for rule_code, pattern in SENSITIVE_LITERAL_PATTERNS:
            if pattern.search(text):
                errors.append(f"REPOSITORY_BOUNDARY_{rule_code}:{label}")

    return sorted(set(errors))


def write_self_test_repository(root: pathlib.Path, bad: bool = False) -> None:
    (root / "Code/Install").mkdir(parents=True)
    (root / "Code/10_SnapshotBaseline").mkdir(parents=True)
    (root / PUBLIC_CONTRACT).parent.mkdir(parents=True)

    common_parameters = """
      @PrintMeldungen bit = 1,
      @Hilfe bit = 0,
      @StatusCodeOut varchar(40) = NULL OUTPUT,
      @IsPartialOut bit = NULL OUTPUT,
      @ErrorNumberOut int = NULL OUTPUT,
      @ErrorMessageOut nvarchar(2048) = NULL OUTPUT
"""
    framework_source = f"""
CREATE TABLE [monitor].[SnapshotTargetConfiguration]([ConfigurationId] int NOT NULL);
GO
CREATE OR ALTER PROCEDURE [monitor].[USP_ConfigureSnapshotTarget]
      @TargetDatabaseName sysname,
      @IsEnabled bit = 1,
      @SchedulerType varchar(16) = 'EXTERNAL',
      @CollectionIntervalSeconds smallint = 30,
      @MaxRows int = 1000,
      @PayloadEnabled bit = 0,
      @RawRetentionDays smallint = 14,
      @PayloadRetentionDays smallint = 7,
      @RollupRetentionDays smallint = 180,
      @SoftBudgetMB int = 10240,
      @PurgeIntervalMinutes smallint = 60,
      @PurgeBatchRows int = 10000,
      @BudgetAction varchar(32) = 'PURGE_EXPIRED_THEN_STOP',
      {common_parameters}
AS BEGIN SET NOCOUNT ON; END;
GO
CREATE OR ALTER PROCEDURE [monitor].[USP_RunSnapshotCollectionCycle]
      @SchedulerType varchar(16) = 'EXTERNAL',
      @RunEvenIfNotDue bit = 0,
      @ResultSetArt varchar(16) = 'CONSOLE',
      @ResultTablesJson nvarchar(max) = NULL,
      @JsonErzeugen bit = 0,
      @Json nvarchar(max) = NULL OUTPUT,
      @PrintMeldungen bit = 1,
      @Hilfe bit = 0,
      @CaptureRunIdOut bigint = NULL OUTPUT,
      @StatusCodeOut varchar(40) = NULL OUTPUT,
      @IsPartialOut bit = NULL OUTPUT,
      @ErrorNumberOut int = NULL OUTPUT,
      @ErrorMessageOut nvarchar(2048) = NULL OUTPUT
AS BEGIN SET NOCOUNT ON; END;
GO
CREATE OR ALTER PROCEDURE [monitor].[USP_PurgeSnapshotData]
      @MaxBatches int = 10,
      @Force bit = 0,
      @ResultSetArt varchar(16) = 'CONSOLE',
      @ResultTablesJson nvarchar(max) = NULL,
      @JsonErzeugen bit = 0,
      @Json nvarchar(max) = NULL OUTPUT,
      @PrintMeldungen bit = 1,
      @Hilfe bit = 0,
      @PurgeRunIdOut bigint = NULL OUTPUT,
      @StatusCodeOut varchar(40) = NULL OUTPUT,
      @IsPartialOut bit = NULL OUTPUT,
      @ErrorNumberOut int = NULL OUTPUT,
      @ErrorMessageOut nvarchar(2048) = NULL OUTPUT
AS BEGIN SET NOCOUNT ON; END;
GO
"""
    target_source = "\n".join(
        f"CREATE TABLE [snapshot].[{name}]([Id] int NOT NULL);\nGO"
        for name in TARGET_TABLES
    )
    target_source += "\n".join(
        f"CREATE OR ALTER PROCEDURE [snapshot].[{name}]\n"
        "AS BEGIN SET NOCOUNT ON; END;\nGO"
        for name in TARGET_INTERNAL_PROCEDURES
    )
    if bad:
        target_source += "\nGRANT SELECT TO [ExampleRole];\n"

    framework_source_path = root / EXPECTED_FRAMEWORK_INCLUDES[1]
    target_source_path = root / EXPECTED_TARGET_INCLUDES[0]
    framework_source_path.write_text(framework_source, encoding="utf-8")
    target_source_path.write_text(target_source, encoding="utf-8")
    for relative_path in EXPECTED_FRAMEWORK_INCLUDES[2:]:
        path = root / relative_path
        path.write_text("-- self-test source included in framework contract\n", encoding="utf-8")
    for relative_path in EXPECTED_TARGET_INCLUDES[1:]:
        path = root / relative_path
        path.write_text("-- self-test source included in target contract\n", encoding="utf-8")
    setup_path = root / EXPECTED_FRAMEWORK_INCLUDES[0]
    setup_path.parent.mkdir(parents=True, exist_ok=True)
    setup_path.write_text("-- self-test preflight\n", encoding="utf-8")
    (root / FRAMEWORK_INSTALLER).write_text(
        "\n".join(
            ":r ../"
            + pathlib.PurePosixPath(relative_path).relative_to("Code").as_posix()
            for relative_path in EXPECTED_FRAMEWORK_INCLUDES
        )
        + "\n",
        encoding="utf-8",
    )
    (root / TARGET_INSTALLER).write_text(
        "\n".join(
            ":r ../" + pathlib.PurePosixPath(relative_path).relative_to("Code").as_posix()
            for relative_path in EXPECTED_TARGET_INCLUDES
        )
        + "\n",
        encoding="utf-8",
    )
    (root / INSTALL_ALL).write_text(":ON ERROR EXIT\n", encoding="utf-8")
    (root / SNAPSHOT_BUILDER).write_text(
        "# synthetic self-test builder\n", encoding="utf-8"
    )
    (root / PUBLIC_CONTRACT).write_text(
        json.dumps(
            {
                "contractId": "SC-023-PUBLIC-V1",
                "contractVersion": 1,
                "releaseState": "IMPLEMENTED_ACTIONS_GATE",
                "targetSqlServerMajorVersions": [15, 16, 17],
                "packageBoundary": {
                    "frameworkInstaller": FRAMEWORK_INSTALLER.as_posix(),
                    "targetInstaller": TARGET_INSTALLER.as_posix(),
                    "standaloneBuilder": SNAPSHOT_BUILDER.as_posix(),
                    "generatedFrameworkInstaller": GENERATED_FRAMEWORK_INSTALLER.as_posix(),
                    "generatedTargetInstaller": GENERATED_TARGET_INSTALLER.as_posix(),
                    "coreInstallsPackage": False,
                },
                "publicProcedures": [f"monitor.{name}" for name in PUBLIC_APIS],
            }
        ),
        encoding="utf-8",
    )


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        good_root = pathlib.Path(temporary_directory) / "good"
        write_self_test_repository(good_root)
        good_errors = validate_repository(good_root)
        if good_errors:
            raise AssertionError("positive self-test failed: " + ",".join(good_errors))

        bad_root = pathlib.Path(temporary_directory) / "bad"
        write_self_test_repository(bad_root, bad=True)
        bad_errors = validate_repository(bad_root)
        if "FORBIDDEN_RIGHTS_DDL:TARGET" not in bad_errors:
            raise AssertionError("negative self-test did not detect target GRANT")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()

    if arguments.self_test:
        run_self_test()
        print("Snapshot Baseline public-contract self-test passed.")
        return 0

    errors = validate_repository(arguments.repository_root.resolve())
    if errors:
        print("Snapshot-Baseline-Vertrag verletzt:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Snapshot Baseline public, installer, and repository contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
