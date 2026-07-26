#!/usr/bin/env python3
"""Validate the W2-007 presentation refinements using Python standard library only."""
from __future__ import annotations
import hashlib
from pathlib import Path
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
DECK = ROOT / "Presentations" / "Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx"
REGISTER = ROOT / "Documentation" / "Inventories" / "SLIDE_STATEMENT_REGISTER.md"
REVIEW = ROOT / "Documentation" / "Project_Planning" / "W2_007_REFINE_CLAIMS_REVIEW.md"
A_NS = "{http://schemas.openxmlformats.org/drawingml/2006/main}"

REQUIRED = {
    32: ["Cache-Schlüssel und Invalidierung sind zu trennen", "zusätzliche Cacheeinträge", "ohne einen vorhandenen Plan zu invalidieren"],
    34: ["2022 / CL 140–160", "MGF-Persistenz/Perzentil", "Query Store READ_WRITE", "2025 / CL 160–170", "OPPO"],
    42: ["keine klassischen Spaltenstatistiken oder Histogramme", "Verteilung bleibt unsichtbar", "nicht pauschal „klein“"],
    43: ["Interleaved Execution ab CL 140", "Scalar UDF Inlining ab CL 150", "is_inlineable ist nur ein Hinweis"],
}
NOTE_REQUIRED = {
    32: ["Cache-Key-Mismatch", "query-processing-architecture-guide", "monitoring-performance-by-using-the-query-store", "CLM-032"],
    34: ["Query Store", "READ_WRITE", "intelligent-query-processing-memory-grant-feedback", "optional-parameter-optimization", "CLM-034"],
    42: ["Deferred Compilation", "keine klassischen Spaltenstatistiken", "OPT-013", "CLM-042"],
    43: ["Interleaved Execution", "is_inlineable", "scalar-udf-inlining", "CLM-043"],
}
FORBIDDEN = [
    "kleine, planstabile Zwischenmengen",
    "Multi-Statement TVF mit begrenzter Schätzung",
    "relevante Optionänderungen können invalidieren",
    "BI-Automation",
    "SQL_Server_Analyze",
]


def xml_text(data: bytes) -> str:
    root = ET.fromstring(data)
    return " | ".join((e.text or "") for e in root.iter(A_NS + "t"))


def main() -> int:
    findings: list[str] = []
    if not DECK.is_file():
        print("w2-007-presentation: FAIL (deck missing)")
        return 1
    digest = hashlib.sha256(DECK.read_bytes()).hexdigest()
    try:
        with zipfile.ZipFile(DECK) as zf:
            bad = zf.testzip()
            if bad:
                findings.append(f"corrupt ZIP member: {bad}")
            names = set(zf.namelist())
            slides = [n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)]
            if len(slides) != 84:
                findings.append(f"expected 84 slides, found {len(slides)}")
            if "ppt/vbaProject.bin" in names:
                findings.append("VBA project is not allowed")
            all_text: list[str] = []
            for number, fragments in REQUIRED.items():
                path = f"ppt/slides/slide{number}.xml"
                if path not in names:
                    findings.append(f"slide {number} missing")
                    continue
                text = xml_text(zf.read(path))
                all_text.append(text)
                for fragment in fragments:
                    if fragment not in text:
                        findings.append(f"slide {number} missing fragment: {fragment}")
                notes = f"ppt/notesSlides/notesSlide{number}.xml"
                if notes not in names:
                    findings.append(f"notes for slide {number} missing")
                    continue
                note_text = xml_text(zf.read(notes))
                all_text.append(note_text)
                for fragment in NOTE_REQUIRED[number]:
                    if fragment not in note_text:
                        findings.append(f"notes {number} missing fragment: {fragment}")
            joined = "\n".join(all_text)
            for fragment in FORBIDDEN:
                if fragment in joined:
                    findings.append(f"forbidden legacy/privacy fragment remains: {fragment}")
    except (zipfile.BadZipFile, ET.ParseError, OSError) as exc:
        findings.append(f"deck cannot be parsed: {exc}")

    register = REGISTER.read_text(encoding="utf-8") if REGISTER.is_file() else ""
    review = REVIEW.read_text(encoding="utf-8") if REVIEW.is_file() else ""
    if f"**SHA-256:** `{digest}`" not in register:
        findings.append("statement register does not contain current deck SHA-256")
    for claim in ("CLM-032", "CLM-034", "CLM-042", "CLM-043"):
        row = next((line for line in register.splitlines() if line.startswith(f"| {claim} |")), "")
        if "| KEEP |" not in row:
            findings.append(f"{claim} is not KEEP in statement register")
    if "| `KEEP` | 84 |" not in register or "| `REFINE` | 0 |" not in register:
        findings.append("statement register decision balance is not 84 KEEP / 0 REFINE")
    if f"| SHA-256 | `{digest}` |" not in review or "| Status | `VALIDATED` |" not in review:
        findings.append("W2-007 review does not identify the validated deck")

    if findings:
        print(f"w2-007-presentation: FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print(f"- {finding}")
        return 1
    print(f"w2-007-presentation: PASS (84 slides; SHA-256 {digest})")
    return 0

if __name__ == "__main__":
    sys.exit(main())
