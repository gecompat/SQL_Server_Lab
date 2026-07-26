#!/usr/bin/env python3
"""Reject known documentation-style regressions without judging technical prose heuristically."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


MARKDOWN_RULES: tuple[tuple[str, str], ...] = (
    ("LEGACY_READER_LABEL", "**So lesen:**"),
    ("LEGACY_NEXT_STEP_LABEL", "**Danach:**"),
    ("LEGACY_NEGATIVE_INSTRUCTION_LABEL", "**Nicht tun:**"),
)

PUBLIC_TERMINOLOGY_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "AMBIGUOUS_FAMILY_FALLBACK",
        re.compile(
            r"\b(?:Familien-?Fallbacks?|familienbasierter\s+Fallback)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "AMBIGUOUS_FAMILY_GUIDE",
        re.compile(r"\bFamilienguides?\b", re.IGNORECASE),
    ),
    (
        "AMBIGUOUS_FAMILY_COMPOUND",
        re.compile(
            r"\b(?:Code|Framework|Objekt|Analyse|Quell|Katalog|Wait|Funktions)"
            r"familien?\b|\bfamilien(?:weise|uebergreifend|\u00fcbergreifend|bezogen\w*)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "AMBIGUOUS_FEATURE_POSITIVE",
        re.compile(r"\bfeature[- ]positive\w*\b", re.IGNORECASE),
    ),
    (
        "TYPO_FAMILY_SUM",
        re.compile(r"\bFamilienSumme\b"),
    ),
    (
        "AWKWARD_PROCEDURE_COMPOUND",
        re.compile(r"\bprocedurespezifisch\w*\b", re.IGNORECASE),
    ),
    (
        "UNSUPPORTED_FUTURE_PROOF_CLAIM",
        re.compile(r"\bzukunftssicher\w*\b", re.IGNORECASE),
    ),
)

PROCEDURE_MARKDOWN_RULES: tuple[tuple[str, str], ...] = (
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Problematisch wird ein Signal erst durch die Kombination aus technischer Abweichung",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Die feste Reihenfolge lautet: **(1)** Status und Partialität",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Die Identität einer Zeile muss daher zusammen mit Resultsetname",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Die Auswertung ist eine Triage- und Eingrenzungshilfe.",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Die im Beispiel verwendeten Bezeichner",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Nicht ableitbar sind außerdem Daten außerhalb der Filter",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Kostenklassen sind qualitative Betriebsrisiken",
    ),
    (
        "GENERIC_PROCEDURE_BOILERPLATE",
        "Insbesondere sind kleine Nenner, geplante Betriebsphasen",
    ),
    ("LEGACY_UNRESOLVED_LABEL", "**Noch nicht entscheidbar:**"),
    ("FRAGMENTED_TIME_CONTRACT", "Der Zeitvertrag lautet:"),
    ("FRAGMENTED_TIME_CONTRACT", "Ihr Zeitvertrag lautet ausdrücklich:"),
    ("FRAGMENTED_SOURCE_SELECT", "Kein einzelnes Grundselect:"),
)

PROCEDURE_GUIDE_PREFIX = "Documentation/Analysis_Guides/Procedures/USP_"

SQL_HELP_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("HELP_PURPOSE_FRAGMENT", re.compile(r"PRINT\s+N'Zweck:\s*", re.IGNORECASE)),
    (
        "HELP_NOMINAL_FRAGMENT",
        re.compile(
            r"PRINT\s+N'(?:Read-only Tiefenanalyse|Rein lesende [^']*Momentaufnahme|"
            r"Leichtgewichtige Nutzungsinventur|Leichte Offline-Bewertung|"
            r"Korrelierte read-only Sicht|Sicherer Wegweiser)",
            re.IGNORECASE,
        ),
    ),
    (
        "HELP_NEGATIVE_FRAGMENT",
        re.compile(
            r"PRINT\s+N'Keine (?:Datenbank-Vorabbegrenzung|Failover-|"
            r"ALTER RESOURCE GOVERNOR)",
            re.IGNORECASE,
        ),
    ),
)

PURPOSE_PATTERN = re.compile(r"^\s*Zweck\s*:\s*(\S.*)$", re.MULTILINE)
PURPOSE_SENTENCE_START = re.compile(
    r"^(?:Aktiviert|Aggregiert|Analysiert|Automatisiert|Berechnet|Beschreibt|"
    r"Bewertet|Definiert|Die|Der|Das|Dokumentiert|Enthält|Entfernt|Erkennt|"
    r"Ermittelt|Ermöglicht|Erstellt|Erzeugt|Es|Extrahiert|Findet|Führt|Gibt|"
    r"Hält|Installiert|Interpretiert|Inventarisiert|Katalogisiert|Klassifiziert|"
    r"Konvertiert|Kopiert|Korreliert|Liefert|Liest|Löscht|Misst|Normalisiert|"
    r"Ordnet|Orchestriert|Parst|Persistiert|Projiziert|Prüft|Rendert|Schreibt|"
    r"Selektiert|Stellt|Trennt|Typisiert|Unterstützt|Validiert|Vergleicht|"
    r"Vertieft|Wertet|Zeigt|Zerlegt)\b"
)

EXCLUDED_MARKDOWN = {
    Path("AI_Metadata/Internal_Documentation/Quality/NextSteps_External_Note.md"),
    Path("LICENSE.md"),
}
EXCLUDED_MARKDOWN_PREFIX = Path("AI_Metadata/Internal_Documentation/private_Note")


@dataclass(frozen=True)
class Finding:
    rule_code: str
    path: str
    line: int


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def scan_public_terminology(text: str, path: str) -> list[Finding]:
    if path.startswith("AI_Metadata/"):
        return []
    findings: list[Finding] = []
    for rule_code, pattern in PUBLIC_TERMINOLOGY_RULES:
        findings.extend(
            Finding(rule_code, path, line_number(text, match.start()))
            for match in pattern.finditer(text)
        )
    return findings


def scan_markdown(text: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    rules = MARKDOWN_RULES
    if path.startswith(PROCEDURE_GUIDE_PREFIX):
        rules += PROCEDURE_MARKDOWN_RULES
    for rule_code, marker in rules:
        start = 0
        while True:
            offset = text.find(marker, start)
            if offset < 0:
                break
            findings.append(Finding(rule_code, path, line_number(text, offset)))
            start = offset + len(marker)
    findings.extend(scan_public_terminology(text, path))
    return findings


def scan_sql(text: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    for rule_code, pattern in SQL_HELP_RULES:
        findings.extend(
            Finding(rule_code, path, line_number(text, match.start()))
            for match in pattern.finditer(text)
        )
    for match in PURPOSE_PATTERN.finditer(text):
        if not PURPOSE_SENTENCE_START.match(match.group(1)):
            findings.append(
                Finding("SQL_PURPOSE_SENTENCE_FRAGMENT", path, line_number(text, match.start()))
            )
    findings.extend(scan_public_terminology(text, path))
    return findings


def markdown_paths(repository_root: Path) -> list[Path]:
    candidates = repository_root.rglob("*.md")
    result: list[Path] = []
    for path in candidates:
        if not path.is_file():
            continue
        relative = path.relative_to(repository_root)
        if relative in EXCLUDED_MARKDOWN or EXCLUDED_MARKDOWN_PREFIX in relative.parents:
            continue
        result.append(path)
    return sorted(set(result))


def metadata_text_paths(repository_root: Path) -> list[Path]:
    metadata_root = repository_root / "Metadata"
    return sorted(
        path
        for suffix in ("*.csv", "*.json")
        for path in metadata_root.rglob(suffix)
        if path.is_file()
    )


def scan_repository(repository_root: Path) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    markdown = markdown_paths(repository_root)
    sql = sorted((repository_root / "Code").rglob("*.sql"))
    metadata_text = metadata_text_paths(repository_root)
    for path in markdown:
        relative = path.relative_to(repository_root).as_posix()
        findings.extend(scan_markdown(path.read_text(encoding="utf-8"), relative))
    for path in sql:
        relative = path.relative_to(repository_root).as_posix()
        findings.extend(scan_sql(path.read_text(encoding="utf-8-sig"), relative))
    for path in metadata_text:
        relative = path.relative_to(repository_root).as_posix()
        findings.extend(
            scan_public_terminology(path.read_text(encoding="utf-8-sig"), relative)
        )
    return findings, len(markdown) + len(sql) + len(metadata_text)


def run_self_test() -> list[Finding]:
    failures: list[Finding] = []
    markdown_cases = {
        "VALID": ("**Auswertung:** Lesen Sie zuerst den Status.\n", 0),
        "INVALID_LABEL": ("**So lesen:** Status zuerst.\n", 1),
        "INVALID_TERMINOLOGY": ("Ein Familienfallback wird verwendet.\n", 1),
        "INVALID_FAMILY_VARIANTS": ("Familien-Fallbacks und FamilienSumme.\n", 2),
        "INVALID_FEATURE_TERM": ("Feature-positive Evidenz fehlt.\n", 1),
        "Documentation/Analysis_Guides/Procedures/USP_Example.md": (
            "Die Auswertung ist eine Triage- und Eingrenzungshilfe.\n",
            1,
        ),
    }
    sql_cases = {
        "VALID": ("Zweck        : Liefert einen technischen Status.\n", 0),
        "INVALID_PURPOSE": ("Zweck        : Technischer Status.\n", 1),
        "INVALID_HELP": ("PRINT N'Zweck: technischer Status.';\n", 1),
        "INVALID_SQL_TERMINOLOGY": ("-- zukunftssicherer Fallback\n", 1),
    }
    for case_id, (text, expected) in markdown_cases.items():
        if len(scan_markdown(text, case_id)) != expected:
            failures.append(Finding("SELF_TEST_MARKDOWN", case_id, 1))
    for case_id, (text, expected) in sql_cases.items():
        if len(scan_sql(text, case_id)) != expected:
            failures.append(Finding("SELF_TEST_SQL", case_id, 1))
    return failures


def report(findings: Iterable[Finding], scope: str, file_count: int) -> int:
    ordered = sorted(findings, key=lambda item: (item.path, item.line, item.rule_code))
    counts = Counter((item.rule_code, item.path, item.line) for item in ordered)
    for (rule_code, path, line), count in sorted(counts.items()):
        print(
            "Documentation style finding: "
            f"scope={scope} rule={rule_code} "
            f"path={json.dumps(path, ensure_ascii=True)} line={line} count={count}"
        )
    if ordered:
        print(
            "Documentation style validation blocked: "
            f"scope={scope} files={file_count} findings={len(ordered)}"
        )
        return 1
    print(
        "Documentation style validation passed: "
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
        return report(run_self_test(), "SELF_TEST", 11)
    findings, file_count = scan_repository(args.repository_root.resolve())
    return report(findings, "REPOSITORY", file_count)


if __name__ == "__main__":
    sys.exit(main())
