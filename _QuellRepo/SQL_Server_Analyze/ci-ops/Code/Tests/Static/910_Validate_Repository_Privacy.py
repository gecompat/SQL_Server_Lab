#!/usr/bin/env python3
"""Validate repository and ZIP artifacts without echoing matched values."""

from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Iterator


BLOCK_SENTINEL = "REPOSITORY_" + "PRIVACY_BLOCK"
EXPECTED_ZIP_ROOT = "SQL_Server_Analyze"
ALLOWLIST_HEADER = ("RuleCode", "Path", "MatchSha256", "ReasonCode")
GENERIC_DATABASE_NAMES = {
    "DeineDatenbank",
    "master",
    "model",
    "msdb",
    "tempdb",
    "distribution",
}
FORBIDDEN_ARCHIVE_SUFFIXES = (
    ".bak",
    ".generated.sql",
    ".log",
    ".sqlplan",
    ".tmp",
    ".xel",
    ".zip",
)


def _private_key_pattern() -> re.Pattern[str]:
    marker = "-" * 5 + "BEGIN "
    return re.compile(re.escape(marker) + r"(?:RSA |EC |OPENSSH )?PRIVATE KEY" + re.escape("-" * 5))


TEXT_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("BLOCK_SENTINEL", re.compile(re.escape(BLOCK_SENTINEL))),
    (
        "EMAIL_ADDRESS",
        re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"),
    ),
    (
        "GUID_VALUE",
        re.compile(
            r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
            r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"
        ),
    ),
    (
        "UNC_PATH",
        re.compile(r"\\\\[^\s\\/]+\\[^\s\\]+"),
    ),
    (
        "USER_PROFILE_PATH",
        re.compile(r"(?i)\b[A-Z]:\\Users\\[^\\\s]+"),
    ),
    (
        "POSIX_HOME_PATH",
        re.compile(r"(?i)(?<![A-Za-z0-9_])/(?:home|Users)/[A-Za-z0-9._-]+/"),
    ),
    ("PRIVATE_KEY_MATERIAL", _private_key_pattern()),
    (
        "SECRET_LITERAL",
        re.compile(
            r"(?i)\b(?:password|pwd|token|secret|connectionstring)\b\s*[:=]\s*"
            r"(?:N)?(?:'[^'\r\n]+'|\"[^\"\r\n]+\"|[^\s,;\r\n]+)"
        ),
    ),
)
IPV4_CANDIDATE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
DATABASE_CONTEXT = re.compile(r"(?im)^\s*USE\s+\[([^\]\r\n]+)\]")


@dataclass(frozen=True)
class Finding:
    rule_code: str
    path: str
    count: int = 1


def match_digest(rule_code: str, path: str, value: str) -> str:
    normalized_value = value.replace("\r\n", "\n").replace("\r", "\n")
    payload = "\0".join((rule_code, path, normalized_value)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def iter_rule_matches(text: str) -> Iterator[tuple[str, str]]:
    for rule_code, pattern in TEXT_RULES:
        for match in pattern.finditer(text):
            yield rule_code, match.group(0)

    for match in IPV4_CANDIDATE.finditer(text):
        candidate = match.group(0)
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if address.version == 4:
            yield "IPV4_ADDRESS", candidate

    for match in DATABASE_CONTEXT.finditer(text):
        database_name = match.group(1)
        if database_name not in GENERIC_DATABASE_NAMES:
            yield "NON_GENERIC_DATABASE_CONTEXT", match.group(0)


def load_allowlist(path: Path) -> tuple[set[tuple[str, str, str]], list[Finding]]:
    allowed: set[tuple[str, str, str]] = set()
    errors: list[Finding] = []
    if not path.is_file():
        return allowed, [Finding("ALLOWLIST_MISSING", path.as_posix())]

    with path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.reader(stream)
        rows = list(reader)

    if not rows or tuple(rows[0]) != ALLOWLIST_HEADER:
        return allowed, [Finding("ALLOWLIST_HEADER_INVALID", path.as_posix())]

    for row_number, row in enumerate(rows[1:], 2):
        location = f"{path.as_posix()}:{row_number}"
        if len(row) != len(ALLOWLIST_HEADER):
            errors.append(Finding("ALLOWLIST_ROW_INVALID", location))
            continue
        rule_code, relative_path, digest, reason_code = row
        if rule_code in {"BLOCK_SENTINEL", "ZIP_ROOT_INVALID", "ZIP_PATH_INVALID"}:
            errors.append(Finding("ALLOWLIST_RULE_FORBIDDEN", location))
            continue
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            errors.append(Finding("ALLOWLIST_DIGEST_INVALID", location))
            continue
        if not relative_path or PurePosixPath(relative_path).is_absolute() or ".." in PurePosixPath(relative_path).parts:
            errors.append(Finding("ALLOWLIST_PATH_INVALID", location))
            continue
        if not re.fullmatch(r"[A-Z0-9_]+", reason_code):
            errors.append(Finding("ALLOWLIST_REASON_INVALID", location))
            continue
        allowed.add((rule_code, relative_path, digest))

    return allowed, errors


def scan_text(text: str, path: str, allowlist: set[tuple[str, str, str]]) -> list[Finding]:
    counts: Counter[str] = Counter()
    for rule_code, value in iter_rule_matches(text):
        digest = match_digest(rule_code, path, value)
        if (rule_code, path, digest) not in allowlist:
            counts[rule_code] += 1
    return [Finding(rule_code, path, count) for rule_code, count in sorted(counts.items())]


def scan_bytes(data: bytes, path: str, allowlist: set[tuple[str, str, str]]) -> list[Finding]:
    if b"\0" in data:
        return [Finding("BINARY_CONTENT", path)]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [Finding("NON_UTF8_CONTENT", path)]
    return scan_text(text, path, allowlist)


def repository_paths(repository_root: Path) -> tuple[list[str], list[Finding]]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "ls-files", "-z"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return [], [Finding("REPOSITORY_INVENTORY_FAILED", ".")]

    paths = [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]
    return paths, []


def validate_relative_path(path: str) -> list[Finding]:
    pure_path = PurePosixPath(path)
    if not path or "\\" in path or pure_path.is_absolute() or ".." in pure_path.parts:
        return [Finding("REPOSITORY_PATH_INVALID", path or "<empty>")]
    if ".git" in pure_path.parts:
        return [Finding("GIT_METADATA_PRESENT", path)]
    if path.lower().endswith(FORBIDDEN_ARCHIVE_SUFFIXES):
        return [Finding("FORBIDDEN_ARTIFACT_FILE", path)]
    return []


def scan_repository(
    repository_root: Path,
    allowlist: set[tuple[str, str, str]],
) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    paths, inventory_findings = repository_paths(repository_root)
    findings.extend(inventory_findings)

    for relative_path in paths:
        path_findings = validate_relative_path(relative_path)
        findings.extend(path_findings)
        if path_findings:
            continue
        full_path = repository_root / relative_path
        if not full_path.is_file():
            findings.append(Finding("TRACKED_FILE_MISSING", relative_path))
            continue
        findings.extend(scan_bytes(full_path.read_bytes(), relative_path, allowlist))

    return findings, len(paths)


def scan_archive(
    archive_path: Path,
    allowlist: set[tuple[str, str, str]],
) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    scanned_files = 0
    try:
        archive = zipfile.ZipFile(archive_path, "r")
    except (OSError, zipfile.BadZipFile):
        return [Finding("ZIP_OPEN_FAILED", archive_path.name)], 0

    with archive:
        seen: set[str] = set()
        for info in archive.infolist():
            name = info.filename
            pure_path = PurePosixPath(name)
            parts = pure_path.parts
            if (
                not name
                or "\\" in name
                or pure_path.is_absolute()
                or ".." in parts
                or not parts
                or parts[0] != EXPECTED_ZIP_ROOT
            ):
                findings.append(Finding("ZIP_ROOT_INVALID", name or "<empty>"))
                continue
            if name in seen:
                findings.append(Finding("ZIP_DUPLICATE_PATH", name))
                continue
            seen.add(name)
            if ".git" in parts:
                findings.append(Finding("GIT_METADATA_PRESENT", name))
                continue
            if name.lower().endswith(FORBIDDEN_ARCHIVE_SUFFIXES):
                findings.append(Finding("FORBIDDEN_ARTIFACT_FILE", name))
                continue
            if info.is_dir():
                continue

            relative_path = PurePosixPath(*parts[1:]).as_posix()
            scanned_files += 1
            try:
                data = archive.read(info)
            except (OSError, RuntimeError, zipfile.BadZipFile):
                findings.append(Finding("ZIP_ENTRY_READ_FAILED", name))
                continue
            findings.extend(scan_bytes(data, relative_path, allowlist))

    return findings, scanned_files


def _write_zip(path: Path, entries: dict[str, str]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries.items():
            archive.writestr(name, content)


def run_self_test(fixtures_path: Path) -> list[Finding]:
    try:
        manifest = json.loads(fixtures_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return [Finding("SELF_TEST_FIXTURE_INVALID", fixtures_path.as_posix())]

    expected_cases = {
        "REPOSITORY_SAFE_GENERIC": "PASS",
        "REPOSITORY_BLOCK_SENTINEL": "BLOCK",
        "ZIP_SAFE_ROOT": "PASS",
        "ZIP_BLOCK_SENTINEL": "BLOCK",
        "ZIP_INVALID_ROOT": "BLOCK",
    }
    declared_cases = {
        item.get("caseId"): item.get("expectedStatus")
        for item in manifest.get("cases", [])
        if isinstance(item, dict)
    }
    if declared_cases != expected_cases:
        return [Finding("SELF_TEST_FIXTURE_CONTRACT_MISMATCH", fixtures_path.as_posix())]

    failures: list[Finding] = []
    line_ending_path = "synthetic-database-context.sql"
    line_ending_rule = "NON_GENERIC_DATABASE_CONTEXT"
    lf_value = "\nUSE [SyntheticDatabase]"
    crlf_value = "\r\nUSE [SyntheticDatabase]"
    allowed_digest = match_digest(line_ending_rule, line_ending_path, lf_value)
    allowed = {(line_ending_rule, line_ending_path, allowed_digest)}
    if scan_text(crlf_value, line_ending_path, allowed):
        failures.append(Finding("SELF_TEST_LINE_ENDING_NORMALIZATION_FAILED", "CRLF"))

    with tempfile.TemporaryDirectory(prefix="repository-privacy-self-test-") as temp_name:
        temp_root = Path(temp_name)
        repository = temp_root / "repository"
        repository.mkdir()
        subprocess.run(
            ["git", "init", "--quiet", str(repository)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        (repository / "safe.txt").write_text("SYNTHETIC_GENERIC_FIXTURE\n", encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(repository), "add", "safe.txt"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        findings, _ = scan_repository(repository, set())
        if findings:
            failures.append(Finding("SELF_TEST_SAFE_REPOSITORY_FAILED", "REPOSITORY_SAFE_GENERIC"))

        (repository / "blocked.txt").write_text(BLOCK_SENTINEL + "\n", encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(repository), "add", "blocked.txt"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        findings, _ = scan_repository(repository, set())
        if not any(item.rule_code == "BLOCK_SENTINEL" for item in findings):
            failures.append(Finding("SELF_TEST_BLOCK_REPOSITORY_FAILED", "REPOSITORY_BLOCK_SENTINEL"))

        safe_zip = temp_root / "safe.zip"
        _write_zip(safe_zip, {f"{EXPECTED_ZIP_ROOT}/safe.txt": "SYNTHETIC_GENERIC_FIXTURE\n"})
        findings, _ = scan_archive(safe_zip, set())
        if findings:
            failures.append(Finding("SELF_TEST_SAFE_ZIP_FAILED", "ZIP_SAFE_ROOT"))

        blocked_zip = temp_root / "blocked.zip"
        _write_zip(blocked_zip, {f"{EXPECTED_ZIP_ROOT}/blocked.txt": BLOCK_SENTINEL + "\n"})
        findings, _ = scan_archive(blocked_zip, set())
        if not any(item.rule_code == "BLOCK_SENTINEL" for item in findings):
            failures.append(Finding("SELF_TEST_BLOCK_ZIP_FAILED", "ZIP_BLOCK_SENTINEL"))

        invalid_zip = temp_root / "invalid-root.zip"
        _write_zip(invalid_zip, {"UnexpectedRoot/safe.txt": "SYNTHETIC_GENERIC_FIXTURE\n"})
        findings, _ = scan_archive(invalid_zip, set())
        if not any(item.rule_code == "ZIP_ROOT_INVALID" for item in findings):
            failures.append(Finding("SELF_TEST_INVALID_ROOT_FAILED", "ZIP_INVALID_ROOT"))

    return failures


def report(findings: Iterable[Finding], scope: str, scanned_files: int) -> int:
    ordered = sorted(findings, key=lambda item: (item.rule_code, item.path, item.count))
    for finding in ordered:
        safe_path = json.dumps(finding.path, ensure_ascii=True)
        print(
            "Repository privacy gate finding: "
            f"scope={scope} rule={finding.rule_code} path={safe_path} count={finding.count}"
        )
    if ordered:
        print(
            "Repository privacy gate blocked: "
            f"scope={scope} files={scanned_files} findings={sum(item.count for item in ordered)}"
        )
        return 1
    print(f"Repository privacy gate passed: scope={scope} files={scanned_files} findings=0")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument("--archive-path", type=Path)
    parser.add_argument("--allowlist-path", type=Path)
    parser.add_argument("--fixtures-path", type=Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repository_root = args.repository_root.resolve()
    script_root = Path(__file__).resolve().parent
    fixtures_path = args.fixtures_path or script_root / "Repository_Privacy_Fixtures.json"

    if args.self_test:
        failures = run_self_test(fixtures_path.resolve())
        return report(failures, "SELF_TEST", 5)

    allowlist_path = args.allowlist_path or (
        repository_root / "Metadata/Quality/Repository_Privacy_Allowlist.csv"
    )
    allowlist, allowlist_findings = load_allowlist(allowlist_path.resolve())
    repository_findings, repository_count = scan_repository(repository_root, allowlist)
    status = report(
        [*allowlist_findings, *repository_findings],
        "REPOSITORY",
        repository_count,
    )

    if args.archive_path is not None:
        archive_findings, archive_count = scan_archive(args.archive_path.resolve(), allowlist)
        status |= report(archive_findings, "ZIP", archive_count)

    return status


if __name__ == "__main__":
    sys.exit(main())
