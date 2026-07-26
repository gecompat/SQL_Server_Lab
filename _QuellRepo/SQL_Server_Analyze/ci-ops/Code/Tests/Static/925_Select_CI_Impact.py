#!/usr/bin/env python3
"""Select runtime checks from semantic SQL changes and object dependencies."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field


OBJECT_PATTERN = re.compile(
    r"(?:\[(?P<bracket_schema>monitor|snapshot)\]|(?P<plain_schema>monitor|snapshot))"
    r"\s*\.\s*(?:\[(?P<bracket_name>[^\]]+)\]|(?P<plain_name>[A-Za-z_][A-Za-z0-9_]*))",
    re.IGNORECASE,
)
DEFINITION_PATTERN = re.compile(
    r"\bCREATE\s+(?:OR\s+ALTER\s+)?"
    r"(?:PROCEDURE|PROC|FUNCTION|VIEW|TRIGGER|TABLE)\s+"
    r"(?:\[(?P<bracket_schema>monitor|snapshot)\]|(?P<plain_schema>monitor|snapshot))"
    r"\s*\.\s*(?:\[(?P<bracket_name>[^\]]+)\]|(?P<plain_name>[A-Za-z_][A-Za-z0-9_]*))",
    re.IGNORECASE,
)

IMPACT_SCRIPT = "Code/Tests/Static/925_Select_CI_Impact.py"
CORE_WORKFLOWS = {
    ".github/workflows/framework-output-pilot.yml",
    ".github/workflows/sqlserver-2019-linux-release-gate.yml",
    ".github/workflows/sqlserver-2022-linux-release-gate.yml",
    ".github/workflows/sqlserver-2025-linux-release-gate.yml",
}
SNAPSHOT_WORKFLOW = ".github/workflows/snapshot-baseline-release-gate.yml"

CORE_AREA_TESTS = {
    "00_Setup": ("Integration/110_Smoke_Test.sql",),
    "01_Common": ("Common/090_Test_und_Abnahme_Phase1A.sql",),
    "02_CurrentState": ("CurrentState/110_Test_und_Abnahme_Phase1B.sql",),
    "03_ObjectIndex": ("ObjectIndex/110_Test_und_Abnahme_Phase2.sql",),
    "04_PlanCache": ("PlanCache/110_Test_und_Abnahme_Phase3.sql",),
    "05_QueryStore": ("QueryStore/110_Test_und_Abnahme_Phase4.sql",),
    "06_ExtendedEvents": ("ExtendedEvents/110_Test_und_Abnahme_Phase5.sql",),
    "07_Infrastructure": ("Infrastructure/110_Test_und_Abnahme_Phase6.sql",),
    "08_ServerHealth": ("ServerHealth/110_Test_und_Abnahme_Phase7.sql",),
    "09_VersionAdaptive": ("Integration/179_P2_Special_Feature_Inventory_Runtime_Contract.sql",),
}

SPECIAL_TESTS = {
    "Permissions/110_SQL_Server_2019_Permission_Matrix.sql": "permission_matrix",
    "Permissions/110_SQL_Server_2022_Permission_Matrix.sql": "permission_matrix",
    "VersionAdaptive/120_SQL_Server_2025_Regex_Matrix.sql": "regex_matrix",
    "Integration/193_ExecutionPlanAnalysis_Standalone_Runtime_Contract.sql": "plan_standalone",
}


@dataclass(frozen=True)
class Change:
    path: str
    old_text: str | None
    new_text: str | None


@dataclass
class Plan:
    scope: str
    run_runtime: bool = False
    full_suite: bool = False
    executable_paths: list[str] = field(default_factory=list)
    documentation_only_sql_paths: list[str] = field(default_factory=list)
    affected_objects: list[str] = field(default_factory=list)
    selected_tests: list[str] = field(default_factory=list)
    permission_matrix: bool = False
    regex_matrix: bool = False
    plan_standalone: bool = False
    snapshot_runtime: bool = False
    snapshot_concurrency: bool = False
    reasons: list[str] = field(default_factory=list)

    @property
    def run_release_tests(self) -> bool:
        return self.full_suite or bool(self.selected_tests)

    def as_dict(self) -> dict[str, object]:
        return {
            "scope": self.scope,
            "run_runtime": self.run_runtime,
            "full_suite": self.full_suite,
            "run_release_tests": self.run_release_tests,
            "executable_paths": self.executable_paths,
            "documentation_only_sql_paths": self.documentation_only_sql_paths,
            "affected_objects": self.affected_objects,
            "selected_tests": self.selected_tests,
            "permission_matrix": self.permission_matrix,
            "regex_matrix": self.regex_matrix,
            "plan_standalone": self.plan_standalone,
            "snapshot_runtime": self.snapshot_runtime,
            "snapshot_concurrency": self.snapshot_concurrency,
            "reasons": self.reasons,
        }


def run_git(repository_root: pathlib.Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository_root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="strict",
    )
    return completed.stdout


def git_text(repository_root: pathlib.Path, revision: str, path: str) -> str | None:
    completed = subprocess.run(
        ["git", "-C", str(repository_root), "show", f"{revision}:{path}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.decode("utf-8-sig", errors="strict")


def changed_files(
    repository_root: pathlib.Path, base_sha: str, head_sha: str
) -> list[Change]:
    names = run_git(
        repository_root,
        "diff",
        "--name-only",
        "--diff-filter=ACDMRTUXB",
        base_sha,
        head_sha,
        "--",
    ).splitlines()
    return [
        Change(
            path=path,
            old_text=git_text(repository_root, base_sha, path),
            new_text=git_text(repository_root, head_sha, path),
        )
        for path in names
        if path
    ]


def strip_sql_comments(text: str) -> str:
    """Remove SQL comments while preserving quoted literals and identifiers."""
    output: list[str] = []
    index = 0
    state = "code"
    block_depth = 0
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == "'":
                state = "string"
                output.append(char)
            elif char == '"':
                state = "quoted_identifier"
                output.append(char)
            elif char == "[":
                state = "bracket_identifier"
                output.append(char)
            elif char == "-" and following == "-":
                state = "line_comment"
                output.append(" ")
                index += 1
            elif char == "/" and following == "*":
                state = "block_comment"
                block_depth = 1
                output.append(" ")
                index += 1
            else:
                output.append(char)
        elif state == "string":
            output.append(char)
            if char == "'":
                if following == "'":
                    output.append(following)
                    index += 1
                else:
                    state = "code"
        elif state == "quoted_identifier":
            output.append(char)
            if char == '"':
                if following == '"':
                    output.append(following)
                    index += 1
                else:
                    state = "code"
        elif state == "bracket_identifier":
            output.append(char)
            if char == "]":
                if following == "]":
                    output.append(following)
                    index += 1
                else:
                    state = "code"
        elif state == "line_comment":
            if char in "\r\n":
                output.append(char)
                state = "code"
        elif state == "block_comment":
            if char == "/" and following == "*":
                block_depth += 1
                index += 1
            elif char == "*" and following == "/":
                block_depth -= 1
                index += 1
                if block_depth == 0:
                    state = "code"
                    output.append(" ")
            elif char in "\r\n":
                output.append(char)
        index += 1
    return "".join(output)


def normalize_executable_sql(text: str | None) -> str | None:
    if text is None:
        return None
    stripped = strip_sql_comments(text.lstrip("\ufeff"))
    output: list[str] = []
    index = 0
    state = "code"
    whitespace_pending = False
    while index < len(stripped):
        char = stripped[index]
        following = stripped[index + 1] if index + 1 < len(stripped) else ""
        if state == "code":
            if char.isspace():
                whitespace_pending = True
            else:
                if whitespace_pending and output:
                    output.append(" ")
                whitespace_pending = False
                output.append(char)
                if char == "'":
                    state = "string"
                elif char == '"':
                    state = "quoted_identifier"
                elif char == "[":
                    state = "bracket_identifier"
        else:
            output.append(char)
            if state == "string" and char == "'":
                if following == "'":
                    output.append(following)
                    index += 1
                else:
                    state = "code"
            elif state == "quoted_identifier" and char == '"':
                if following == '"':
                    output.append(following)
                    index += 1
                else:
                    state = "code"
            elif state == "bracket_identifier" and char == "]":
                if following == "]":
                    output.append(following)
                    index += 1
                else:
                    state = "code"
        index += 1
    return "".join(output).strip()


def object_key(match: re.Match[str]) -> str:
    schema = match.group("bracket_schema") or match.group("plain_schema")
    name = match.group("bracket_name") or match.group("plain_name")
    return f"{schema}.{name}".casefold()


def definitions(text: str) -> set[str]:
    return {object_key(match) for match in DEFINITION_PATTERN.finditer(strip_sql_comments(text))}


def references(text: str) -> set[str]:
    return {object_key(match) for match in OBJECT_PATTERN.finditer(strip_sql_comments(text))}


def is_snapshot_path(path: str) -> bool:
    return (
        path.startswith("Code/10_SnapshotBaseline/")
        or "SnapshotBaseline" in path
        or "Snapshot_Baseline" in path
    )


def is_core_sql_path(path: str) -> bool:
    return path.startswith("Code/") and path.endswith(".sql") and not is_snapshot_path(path)


def is_snapshot_runtime_path(path: str) -> bool:
    if path.startswith("Code/10_SnapshotBaseline/") and path.endswith(".sql"):
        return True
    if path.startswith("Code/Install/") and "SnapshotBaseline" in path:
        return path.endswith(".sql") or path.endswith(".ps1")
    return path.startswith("Code/Tests/Integration/") and "SnapshotBaseline" in path and path.endswith(".sql")


def production_sql_paths(repository_root: pathlib.Path, head_sha: str, scope: str) -> list[str]:
    paths = run_git(repository_root, "ls-tree", "-r", "--name-only", head_sha, "--", "Code").splitlines()
    if scope == "snapshot":
        return [path for path in paths if path.startswith("Code/10_SnapshotBaseline/") and path.endswith(".sql")]
    return [
        path
        for path in paths
        if re.match(r"Code/(?:0[0-9]_[^/]+)/.+\.sql$", path)
        and not path.startswith("Code/10_SnapshotBaseline/")
    ]


def test_sql_paths(repository_root: pathlib.Path, head_sha: str, scope: str) -> list[str]:
    paths = run_git(repository_root, "ls-tree", "-r", "--name-only", head_sha, "--", "Code/Tests").splitlines()
    if scope == "snapshot":
        return [path for path in paths if "SnapshotBaseline" in path and path.endswith(".sql")]
    return [path for path in paths if path.endswith(".sql") and not is_snapshot_path(path)]


def force_full_path(path: str, scope: str) -> bool:
    if path == IMPACT_SCRIPT:
        return True
    if scope == "snapshot":
        return path == SNAPSHOT_WORKFLOW or (
            path.startswith("Code/Install/") and "SnapshotBaseline" in path
        )
    return (
        path in CORE_WORKFLOWS
        or path == "Code/Install/Install_All.sql"
        or path.startswith("Code/00_Setup/")
        or path == "Code/Tests/Run_Release_Gate.sql"
    )


def direct_test_name(path: str) -> str | None:
    prefix = "Code/Tests/"
    if path.startswith(prefix) and path.endswith(".sql"):
        return path[len(prefix) :]
    return None


def plan_changes(
    repository_root: pathlib.Path,
    head_sha: str,
    changes: list[Change],
    scope: str,
) -> Plan:
    plan = Plan(scope=scope)
    executable: list[Change] = []
    for change in changes:
        relevant = is_snapshot_runtime_path(change.path) if scope == "snapshot" else is_core_sql_path(change.path)
        if change.path == IMPACT_SCRIPT or force_full_path(change.path, scope):
            relevant = True
        if not relevant:
            continue
        if change.path.endswith(".sql"):
            if normalize_executable_sql(change.old_text) == normalize_executable_sql(change.new_text):
                plan.documentation_only_sql_paths.append(change.path)
                continue
        executable.append(change)

    plan.executable_paths = sorted(change.path for change in executable)
    plan.documentation_only_sql_paths.sort()
    if not executable:
        plan.reasons.append("No executable SQL or runtime infrastructure changed.")
        return plan

    plan.run_runtime = True
    if any(force_full_path(change.path, scope) for change in executable):
        plan.full_suite = True
        plan.permission_matrix = scope == "core"
        plan.regex_matrix = scope == "core"
        plan.plan_standalone = scope == "core"
        plan.snapshot_runtime = scope == "snapshot"
        plan.snapshot_concurrency = scope == "snapshot"
        plan.reasons.append("A central installer, setup, workflow, runner, or impact rule changed.")
        return plan

    direct_tests = {
        test_name
        for change in executable
        if (test_name := direct_test_name(change.path)) is not None
    }

    changed_objects: set[str] = set()
    changed_production_paths: list[str] = []
    for change in executable:
        if change.path.startswith("Code/Tests/"):
            continue
        old_defs = definitions(change.old_text or "")
        new_defs = definitions(change.new_text or "")
        internal_refs = references(change.old_text or "") | references(change.new_text or "")
        changed_objects.update(old_defs | new_defs)
        if not old_defs and not new_defs:
            changed_objects.update(internal_refs)
        changed_production_paths.append(change.path)

    production_definitions: dict[str, set[str]] = {}
    reverse_dependencies: dict[str, set[str]] = {}
    for path in production_sql_paths(repository_root, head_sha, scope):
        text = git_text(repository_root, head_sha, path) or ""
        file_definitions = definitions(text)
        production_definitions[path] = file_definitions
        for referenced in references(text) - file_definitions:
            reverse_dependencies.setdefault(referenced, set()).update(file_definitions)

    affected = set(changed_objects)
    pending = list(changed_objects)
    while pending:
        current = pending.pop()
        for dependent in reverse_dependencies.get(current, set()):
            if dependent not in affected:
                affected.add(dependent)
                pending.append(dependent)
    plan.affected_objects = sorted(affected)

    selected = set(direct_tests)
    dependency_test_count = 0
    for path in test_sql_paths(repository_root, head_sha, scope):
        test_name = path.removeprefix("Code/Tests/")
        if references(git_text(repository_root, head_sha, path) or "") & affected:
            selected.add(test_name)
            dependency_test_count += 1

    if scope == "core" and changed_production_paths:
        selected.add("Integration/110_Smoke_Test.sql")
        for path in changed_production_paths:
            parts = pathlib.PurePosixPath(path).parts
            if len(parts) >= 2:
                selected.update(CORE_AREA_TESTS.get(parts[1], ()))

    if changed_production_paths and (not changed_objects or dependency_test_count == 0):
        plan.full_suite = True
        plan.permission_matrix = scope == "core"
        plan.regex_matrix = scope == "core"
        plan.plan_standalone = scope == "core"
        plan.snapshot_runtime = scope == "snapshot"
        plan.snapshot_concurrency = scope == "snapshot"
        plan.reasons.append("A production change could not be mapped safely to dependent tests.")
        return plan

    generic_tests: set[str] = set()
    for test_name in selected:
        special = SPECIAL_TESTS.get(test_name)
        if special is not None:
            setattr(plan, special, True)
        elif scope == "snapshot" and test_name == "Integration/195_SnapshotBaseline_Runtime_Contract.sql":
            plan.snapshot_runtime = True
        elif scope == "snapshot" and test_name in {
            "Integration/196_SnapshotBaseline_Concurrency_Holder.sql",
            "Integration/197_SnapshotBaseline_Concurrency_Assert.sql",
        }:
            plan.snapshot_concurrency = True
        elif scope != "snapshot" and "SnapshotBaseline" not in test_name:
            generic_tests.add(test_name)
    plan.selected_tests = sorted(generic_tests)
    plan.reasons.append(
        f"Selected {len(plan.selected_tests)} runtime test file(s) from direct and transitive dependencies."
    )
    return plan


def full_plan(scope: str, reason: str) -> Plan:
    return Plan(
        scope=scope,
        run_runtime=True,
        full_suite=True,
        permission_matrix=scope == "core",
        regex_matrix=scope == "core",
        plan_standalone=scope == "core",
        snapshot_runtime=scope == "snapshot",
        snapshot_concurrency=scope == "snapshot",
        reasons=[reason],
    )


def write_github_output(path: pathlib.Path, plan: Plan) -> None:
    values = {
        "run_runtime": str(plan.run_runtime).lower(),
        "full_suite": str(plan.full_suite).lower(),
        "run_release_tests": str(plan.run_release_tests).lower(),
        "permission_matrix": str(plan.permission_matrix).lower(),
        "regex_matrix": str(plan.regex_matrix).lower(),
        "plan_standalone": str(plan.plan_standalone).lower(),
        "snapshot_runtime": str(plan.snapshot_runtime).lower(),
        "snapshot_concurrency": str(plan.snapshot_concurrency).lower(),
        "selected_test_count": str(len(plan.selected_tests)),
    }
    with path.open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def write_runner(path: pathlib.Path, plan: Plan) -> None:
    if plan.full_suite:
        path.write_text(":ON ERROR EXIT\n:r Run_Release_Gate.sql\n", encoding="utf-8")
        return
    lines = [":ON ERROR EXIT", ""]
    total = len(plan.selected_tests)
    for index, test_name in enumerate(plan.selected_tests, start=1):
        label = pathlib.PurePosixPath(test_name).name.replace("'", "")
        lines.append(
            f"RAISERROR(N'IMPACT_GATE {index}/{total}: {label}',10,1) WITH NOWAIT;"
        )
        lines.append(f":r {test_name}")
        lines.append("")
    lines.extend(
        [
            "SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],",
            "       CAST(0 AS bit) AS [IsPartial],",
            f"       CAST({total} AS int) AS [ExecutedTestFiles],",
            "       N'Impact-selected runtime tests completed.' AS [Detail];",
            "GO",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def run_self_test() -> None:
    assert normalize_executable_sql("-- note\nSELECT 1;\n") == normalize_executable_sql(
        "/* revised note */\nSELECT   1; -- tail\n"
    )
    assert normalize_executable_sql("SELECT 'a -- b';") != normalize_executable_sql(
        "SELECT 'a -- c';"
    )
    assert references("EXEC [monitor].[USP_Consumer];") == {"monitor.usp_consumer"}
    assert definitions(
        "CREATE OR ALTER PROCEDURE [monitor].[USP_Helper] AS SELECT 1;"
    ) == {"monitor.usp_helper"}
    comment_change = Change(
        "Code/02_CurrentState/010_USP_CurrentSessions.sql",
        "-- old\nSELECT 1;",
        "-- new\nSELECT 1;",
    )
    assert normalize_executable_sql(comment_change.old_text) == normalize_executable_sql(
        comment_change.new_text
    )
    assert is_core_sql_path(comment_change.path)
    assert not is_core_sql_path("Code/10_SnapshotBaseline/010_Config.sql")
    assert is_snapshot_runtime_path("Code/10_SnapshotBaseline/010_Config.sql")
    assert force_full_path("Code/Install/Install_All.sql", "core")
    assert not force_full_path("Documentation/README.md", "core")

    with tempfile.TemporaryDirectory() as temporary_directory:
        root = pathlib.Path(temporary_directory)
        (root / "Code/01_Common").mkdir(parents=True)
        (root / "Code/02_CurrentState").mkdir(parents=True)
        (root / "Code/Tests/Integration").mkdir(parents=True)
        (root / "Code/Tests/Common").mkdir(parents=True)
        (root / "Code/Tests/CurrentState").mkdir(parents=True)
        (root / "Code/01_Common/010_Helper.sql").write_text(
            "CREATE OR ALTER FUNCTION [monitor].[TVF_Helper]() RETURNS TABLE AS RETURN SELECT 1 AS [Value];\n",
            encoding="utf-8",
        )
        (root / "Code/02_CurrentState/010_Consumer.sql").write_text(
            "CREATE OR ALTER PROCEDURE [monitor].[USP_Consumer] AS SELECT * FROM [monitor].[TVF_Helper]();\n",
            encoding="utf-8",
        )
        (root / "Code/Tests/Integration/110_Smoke_Test.sql").write_text(
            "EXEC [monitor].[USP_Consumer];\n", encoding="utf-8"
        )
        (root / "Code/Tests/Common/090_Test_und_Abnahme_Phase1A.sql").write_text(
            "SELECT * FROM [monitor].[TVF_Helper]();\n", encoding="utf-8"
        )
        (root / "Code/Tests/CurrentState/110_Test_und_Abnahme_Phase1B.sql").write_text(
            "EXEC [monitor].[USP_Consumer];\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        synthetic_identity = [
            "-c",
            "user.name=CI Impact Self Test",
            "-c",
            "user.email=" + "ci-impact" + "@example.invalid",
        ]
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(root), *synthetic_identity, "commit", "--quiet", "-m", "base"],
            check=True,
        )
        base_sha = run_git(root, "rev-parse", "HEAD").strip()

        helper_path = root / "Code/01_Common/010_Helper.sql"
        helper_path.write_text(
            "-- revised documentation only\n"
            "CREATE OR ALTER FUNCTION [monitor].[TVF_Helper]() RETURNS TABLE AS RETURN SELECT 1 AS [Value];\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(root), *synthetic_identity, "commit", "--quiet", "-m", "docs"],
            check=True,
        )
        docs_sha = run_git(root, "rev-parse", "HEAD").strip()
        docs_plan = plan_changes(root, docs_sha, changed_files(root, base_sha, docs_sha), "core")
        assert not docs_plan.run_runtime
        assert docs_plan.documentation_only_sql_paths == ["Code/01_Common/010_Helper.sql"]

        helper_path.write_text(
            "CREATE OR ALTER FUNCTION [monitor].[TVF_Helper]() RETURNS TABLE AS RETURN SELECT 2 AS [Value];\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(root), *synthetic_identity, "commit", "--quiet", "-m", "code"],
            check=True,
        )
        code_sha = run_git(root, "rev-parse", "HEAD").strip()
        code_plan = plan_changes(root, code_sha, changed_files(root, docs_sha, code_sha), "core")
        assert code_plan.run_runtime
        assert not code_plan.full_suite
        assert "monitor.usp_consumer" in code_plan.affected_objects
        assert "CurrentState/110_Test_und_Abnahme_Phase1B.sql" in code_plan.selected_tests


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--base-sha", default="")
    parser.add_argument("--head-sha", default="HEAD")
    parser.add_argument("--scope", choices=("core", "snapshot"), default="core")
    parser.add_argument("--github-output", type=pathlib.Path)
    parser.add_argument("--plan-json", type=pathlib.Path)
    parser.add_argument("--write-runner", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()

    if arguments.self_test:
        run_self_test()
        print("CI impact selector self-test passed.")
        return 0

    repository_root = arguments.repository_root.resolve()
    if not arguments.base_sha:
        plan = full_plan(arguments.scope, "No base revision was supplied; using the conservative full gate.")
    else:
        try:
            changes = changed_files(repository_root, arguments.base_sha, arguments.head_sha)
            plan = plan_changes(repository_root, arguments.head_sha, changes, arguments.scope)
        except (OSError, UnicodeError, subprocess.CalledProcessError) as error:
            print(f"Impact analysis failed: {type(error).__name__}", file=sys.stderr)
            return 1

    if arguments.github_output:
        write_github_output(arguments.github_output, plan)
    if arguments.plan_json:
        arguments.plan_json.write_text(
            json.dumps(plan.as_dict(), indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    if arguments.write_runner:
        write_runner(arguments.write_runner, plan)
    print(json.dumps(plan.as_dict(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
