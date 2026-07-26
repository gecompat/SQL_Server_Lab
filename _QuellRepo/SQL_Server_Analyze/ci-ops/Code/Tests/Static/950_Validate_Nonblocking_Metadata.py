#!/usr/bin/env python3
"""Validate nonblocking metadata access and collision-resistant temp names."""

from __future__ import annotations

import collections
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[3]
CODE = ROOT / "Code"

FORBIDDEN_METADATA_FUNCTIONS = (
    "OBJECT_ID",
    "OBJECT_NAME",
    "OBJECT_SCHEMA_NAME",
    "SCHEMA_NAME",
    "DB_NAME",
    "COL_LENGTH",
    "OBJECT_DEFINITION",
    "SCHEMA_ID",
    "DATABASEPROPERTYEX",
)

SYS_SOURCE = re.compile(
    r"\b(?:FROM|JOIN)\s+"
    r"(?P<source>(?:(?:\[[^\]\r\n]+\]|[A-Za-z_][A-Za-z0-9_]*)\.)?"
    r"\[?sys\]?\.\[?[A-Za-z_][A-Za-z0-9_]*\]?)",
    re.IGNORECASE,
)
SYSTEM_DATABASE_SOURCE = re.compile(
    r"\b(?:FROM|JOIN)\s+"
    r"(?P<source>\[?(?:master|msdb|tempdb)\]?\."
    r"\[?(?:dbo|sys|cdc)\]?\.\[?[A-Za-z_][A-Za-z0-9_]*\]?)",
    re.IGNORECASE,
)
NOLOCK_AFTER_SOURCE = re.compile(
    r"^\s*(?:(?:AS\s+)?(?:\[[A-Za-z_][A-Za-z0-9_]*\]|[A-Za-z_][A-Za-z0-9_]*)\s+)?"
    r"WITH\s*\(\s*NOLOCK\s*\)",
    re.IGNORECASE,
)
TEMP_CREATE = re.compile(
    r"(?:CREATE\s+TABLE|INTO)\s+\[?(?P<name>#(?!#)[A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE,
)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def file_token(path: pathlib.Path) -> str:
    stem = re.sub(r"^\d+_", "", path.stem)
    stem = re.sub(r"^USP_", "", stem, flags=re.IGNORECASE)
    return re.sub(r"[^A-Za-z0-9]", "", stem).casefold()


def normalized_temp_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "", name[1:]).casefold()


errors: list[str] = []
temp_owners: dict[str, list[str]] = collections.defaultdict(list)

for path in sorted(CODE.rglob("*.sql")):
    if "Install" in path.parts:
        continue

    relative = path.relative_to(ROOT)
    text = path.read_text(encoding="utf-8-sig")

    if relative.as_posix() == "Code/02_CurrentState/030_USP_CurrentBlocking.sql":
        executable_text = re.sub(r"N?'(?:''|[^'])*'", "''", text, flags=re.DOTALL)
        executable_text = re.sub(r"/\*.*?\*/", "", executable_text, flags=re.DOTALL)
        executable_text = re.sub(r"--[^\r\n]*", "", executable_text)
        if re.search(r"\bSET\s+LOCK_TIMEOUT\s+0\b", executable_text, re.IGNORECASE):
            errors.append(
                f"{relative}: LOCK_TIMEOUT 0 darf den Blocking-Kern nicht global beeinflussen; "
                "nur einzelne Anreicherungs-Batches sind zulässig"
            )
        if len(re.findall(r"N'SET\s+LOCK_TIMEOUT\s+0\s*;", text, re.IGNORECASE)) < 5:
            errors.append(
                f"{relative}: isolierte LOCK_TIMEOUT-0-Batches für Datenbank, Datei, "
                "benannte Ressource, Page und Katalog fehlen"
            )

    for function_name in FORBIDDEN_METADATA_FUNCTIONS:
        match = re.search(rf"\b{function_name}\s*\(", text, re.IGNORECASE)
        if match:
            errors.append(
                f"{relative}:{line_number(text, match.start())}: "
                f"blockierende Metadatenfunktion {function_name} ist nicht zulässig"
            )

    for match in re.finditer(r"\bDB_ID\s*\(\s*[^)\s]", text, re.IGNORECASE):
        errors.append(
            f"{relative}:{line_number(text, match.start())}: "
            "DB_ID(name) muss über master.sys.databases WITH (NOLOCK) ersetzt werden"
        )

    if re.search(r"CREATE\s+OR\s+ALTER\s+PROCEDURE", text, re.IGNORECASE):
        uses_zero_timeout = re.search(r"SET\s+LOCK_TIMEOUT\s+0", text, re.IGNORECASE)
        captures_timeout = re.search(
            r"DECLARE\s+@OriginalLockTimeout\s+int\s*=\s*@@LOCK_TIMEOUT", text, re.IGNORECASE
        )
        restores_timeout = re.search(
            r"SET\s+@LockTimeoutSql\s*=\s*N?'SET\s+LOCK_TIMEOUT\s+'\s*\+\s*"
            r"CONVERT\s*\(\s*nvarchar\s*\(\s*20\s*\)\s*,\s*@OriginalLockTimeout\s*\)",
            text,
            re.IGNORECASE,
        )
        uses_isolated_parameter_timeout = re.search(
            r"N'SET\s+LOCK_TIMEOUT\s+'\s*\+\s*"
            r"CONVERT\s*\(\s*nvarchar\s*\(\s*11\s*\)\s*,\s*@LockTimeoutMs\s*\)",
            text,
            re.IGNORECASE,
        )
        asserts_unchanged_timeout = re.search(
            r"IF\s+@@LOCK_TIMEOUT\s*<>\s*@OriginalLockTimeout",
            text,
            re.IGNORECASE,
        )
        if (
            not uses_zero_timeout
            and not (captures_timeout and restores_timeout)
            and not (
                captures_timeout
                and uses_isolated_parameter_timeout
                and asserts_unchanged_timeout
            )
        ):
            errors.append(
                f"{relative}: Procedure setzt keinen nichtblockierenden LOCK_TIMEOUT "
                "oder stellt den ursprünglichen Wert nicht nachweisbar wieder her"
            )

    catalog_matches = list(SYS_SOURCE.finditer(text)) + list(SYSTEM_DATABASE_SOURCE.finditer(text))
    seen_offsets: set[int] = set()
    for match in sorted(catalog_matches, key=lambda item: item.start()):
        if match.start() in seen_offsets:
            continue
        seen_offsets.add(match.start())
        tail = text[match.end() : match.end() + 180]
        if re.match(r"^\s*\(", tail):
            continue
        if not NOLOCK_AFTER_SOURCE.match(tail):
            errors.append(
                f"{relative}:{line_number(text, match.start())}: "
                f"Systemquelle {match.group('source')} ohne direktes WITH (NOLOCK)"
            )

    expected_prefix = file_token(path)
    for match in TEMP_CREATE.finditer(text):
        name = match.group("name")
        owner_key = name.casefold()
        temp_owners[owner_key].append(str(relative))
        if len(name) > 116:
            errors.append(
                f"{relative}:{line_number(text, match.start())}: "
                f"lokaler Temp-Name {name} überschreitet 116 Zeichen"
            )
        if not normalized_temp_name(name).startswith(expected_prefix):
            errors.append(
                f"{relative}:{line_number(text, match.start())}: "
                f"Temp-Name {name} besitzt keinen Bezug zu {path.stem}"
            )

for name, owners in sorted(temp_owners.items()):
    distinct_owners = sorted(set(owners))
    if len(owners) > 1:
        errors.append(
            f"{name}: derselbe logische Temp-Name wird mehrfach erzeugt: "
            + ", ".join(distinct_owners)
        )

if errors:
    print("Nonblocking-Metadaten-/Temp-Namensvertrag verletzt:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Nonblocking-Metadaten-/Temp-Namensvertrag erfüllt: "
    f"{len(temp_owners)} eindeutige lokale Temp-Namen geprüft."
)
