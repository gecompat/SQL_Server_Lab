#!/usr/bin/env python3
"""Reject numeric comparisons applied to the SQL Server 2025 REGEXP_LIKE predicate."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


RULE_CODE = "REGEXP_LIKE_NUMERIC_COMPARISON"
COMPARISON_PATTERN = re.compile(
    r"\bREGEXP_LIKE\s*\((?:(?!;).)*?\)\s*(?:<>|!=|=)\s*[01](?![0-9])",
    re.IGNORECASE | re.DOTALL,
)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int


def mask_sql_comments(text: str) -> str:
    """Mask comments while preserving strings, length, and line positions."""
    result = list(text)
    index = 0
    state = "CODE"
    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if state == "CODE":
            if current == "'":
                state = "STRING"
                index += 1
                continue
            if current == "-" and following == "-":
                result[index] = result[index + 1] = " "
                state = "LINE_COMMENT"
                index += 2
                continue
            if current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                state = "BLOCK_COMMENT"
                index += 2
                continue
        elif state == "STRING":
            if current == "'" and following == "'":
                index += 2
                continue
            if current == "'":
                state = "CODE"
                index += 1
                continue
        elif state == "LINE_COMMENT":
            if current in "\r\n":
                state = "CODE"
            else:
                result[index] = " "
        elif state == "BLOCK_COMMENT":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                state = "CODE"
                index += 2
                continue
            if current not in "\r\n":
                result[index] = " "
        index += 1

    return "".join(result)


def scan_text(text: str, path: str) -> list[Finding]:
    masked = mask_sql_comments(text)
    return [
        Finding(path=path, line=masked.count("\n", 0, match.start()) + 1)
        for match in COMPARISON_PATTERN.finditer(masked)
    ]


def scan_repository(repository_root: Path) -> tuple[list[Finding], int]:
    code_root = repository_root / "Code"
    findings: list[Finding] = []
    files = sorted(code_root.rglob("*.sql")) if code_root.is_dir() else []
    for path in files:
        relative_path = path.relative_to(repository_root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            findings.append(Finding(relative_path, 1))
            continue
        findings.extend(scan_text(text, relative_path))
    return findings, len(files)


def run_self_test() -> list[Finding]:
    cases = {
        "VALID_DIRECT": ("WHERE REGEXP_LIKE([Value], @Pattern, @Flags);", 0),
        "VALID_NEGATED": ("WHERE NOT REGEXP_LIKE([Value], @Pattern);", 0),
        "VALID_LINE_COMMENT": ("-- REGEXP_LIKE([Value], @Pattern) = 1\nSELECT 1;", 0),
        "VALID_BLOCK_COMMENT": ("/* REGEXP_LIKE([Value], @Pattern) <> 0 */\nSELECT 1;", 0),
        "INVALID_DIRECT": ("WHERE REGEXP_LIKE([Value], @Pattern) = 1;", 1),
        "INVALID_MULTILINE": (
            "WHERE REGEXP_LIKE(\n    [Value],\n    @Pattern,\n    @Flags\n) <> 0;",
            1,
        ),
        "INVALID_NESTED": (
            "WHERE REGEXP_LIKE(COALESCE([Value], N''), @Pattern) != 1;",
            1,
        ),
        "INVALID_DYNAMIC": (
            "SET @Sql = N'WHERE REGEXP_LIKE([Value], @Pattern) = 0;';",
            1,
        ),
    }
    failures: list[Finding] = []
    for case_id, (sql_text, expected_count) in cases.items():
        actual_count = len(scan_text(sql_text, case_id))
        if actual_count != expected_count:
            failures.append(Finding(case_id, 1))
    return failures


def report(findings: Iterable[Finding], scope: str, file_count: int) -> int:
    ordered = sorted(findings, key=lambda item: (item.path, item.line))
    counts = Counter((item.path, item.line) for item in ordered)
    for (path, line), count in sorted(counts.items()):
        print(
            "Regex predicate validation finding: "
            f"scope={scope} rule={RULE_CODE} "
            f"path={json.dumps(path, ensure_ascii=True)} line={line} count={count}"
        )
    if ordered:
        print(
            "Regex predicate validation blocked: "
            f"scope={scope} files={file_count} findings={len(ordered)}"
        )
        return 1
    print(
        "Regex predicate validation passed: "
        f"scope={scope} files={file_count} findings=0"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return report(run_self_test(), "SELF_TEST", 8)
    findings, file_count = scan_repository(args.repository_root.resolve())
    return report(findings, "REPOSITORY", file_count)


if __name__ == "__main__":
    sys.exit(main())
