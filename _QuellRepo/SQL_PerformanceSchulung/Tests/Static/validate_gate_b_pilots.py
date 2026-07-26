#!/usr/bin/env python3
"""Static contract validation for the four Gate-B pilot demos.

The validator is standard-library-only so the final contract check remains independent of a SQL Server runtime.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]

PILOTS = {
    "QRY-001": {
        "path": ROOT / "Demos" / "05_Query_Patterns" / "QRY-001_SARGability",
        "safety": "GREEN",
        "phases": {"PREFLIGHT", "SETUP", "BASELINE", "DEMONSTRATION", "OBSERVATION", "MITIGATION", "COMPARISON"},
    },
    "OPT-002": {
        "path": ROOT / "Demos" / "04_Optimizer_Statistics_Plans" / "OPT-002_Statistics_Anatomy",
        "safety": "GREEN",
        "phases": {"PREFLIGHT", "SETUP", "BASELINE", "DEMONSTRATION", "OBSERVATION", "MITIGATION", "COMPARISON"},
    },
    "CON-004": {
        "path": ROOT / "Demos" / "07_Concurrency" / "CON-004_Blocking_Chain",
        "safety": "YELLOW",
        "phases": {"PREFLIGHT", "SETUP", "BASELINE", "DEMONSTRATION", "OBSERVATION", "MITIGATION", "COMPARISON", "VERIFICATION"},
    },
    "OPT-013": {
        "path": ROOT / "Demos" / "04_Optimizer_Statistics_Plans" / "OPT-013_Controlled_Spill",
        "safety": "YELLOW",
        "phases": {"PREFLIGHT", "SETUP", "BASELINE", "DEMONSTRATION", "OBSERVATION", "MITIGATION", "COMPARISON"},
    },
}

README_HEADINGS = {
    "## 1. Lernziel",
    "## 2. Fachliche Kernaussage",
    "## 3. Nichtziel",
    "## 4. Voraussetzungen",
    "## 5. Sicherheits- und Abbruchrahmen",
    "## 6. Synthetisches Datenmodell",
    "## 7. Ablauf",
    "## 8. Erwartete Beobachtung",
    "## 9. Interpretation",
    "## 10. Cleanup und Wiederherstellung",
    "## 11. Tests",
    "## 12. Bekannte Grenzen",
    "## 13. Quellen",
    "## 14. Traceability",
}

FORBIDDEN_SQL = {
    "DBCC FREEPROCCACHE",
    "DBCC DROPCLEANBUFFERS",
    "DBCC FLUSHPROCINDB",
    "DBCC SQLPERF",
    "XP_CMDSHELL",
    "SHUTDOWN",
    "ALTER SERVER CONFIGURATION",
    "SP_CONFIGURE",
    "EVENT_FILE",
    "KILL ",
    "WITH (NOLOCK)",
    "WITH(NOLOCK)",
}

SECRET_KEY = re.compile(r"password|secret|connection_string|server|username", re.IGNORECASE)


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def sql_lexical_error(text: str) -> str | None:
    index = 0
    state = "normal"
    block_depth = 0
    parens = 0
    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""
        if state == "normal":
            if char == "'":
                state = "string"
            elif char == "[":
                state = "bracket"
            elif char == "-" and nxt == "-":
                state = "line_comment"
                index += 1
            elif char == "/" and nxt == "*":
                state = "block_comment"
                block_depth = 1
                index += 1
            elif char == "(":
                parens += 1
            elif char == ")":
                parens -= 1
                if parens < 0:
                    return "closing parenthesis without opening parenthesis"
        elif state == "string":
            if char == "'" and nxt == "'":
                index += 1
            elif char == "'":
                state = "normal"
        elif state == "bracket":
            if char == "]" and nxt == "]":
                index += 1
            elif char == "]":
                state = "normal"
        elif state == "line_comment":
            if char in "\r\n":
                state = "normal"
        elif state == "block_comment":
            if char == "/" and nxt == "*":
                block_depth += 1
                index += 1
            elif char == "*" and nxt == "/":
                block_depth -= 1
                index += 1
                if block_depth == 0:
                    state = "normal"
        index += 1
    if state in {"string", "bracket", "block_comment"}:
        return f"unterminated lexical state: {state}"
    if parens != 0:
        return f"unbalanced parentheses: {parens}"
    return None


def walk_keys(value: object, path: str = "$") -> list[str]:
    findings: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if SECRET_KEY.search(str(key)):
                findings.append(f"forbidden connection/secret field {path}.{key}")
            findings.extend(walk_keys(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            findings.extend(walk_keys(child, f"{path}[{index}]"))
    return findings


def validate_manifest(demo_id: str, root: Path, expected: dict[str, object]) -> list[str]:
    findings: list[str] = []
    manifest_path = root / "manifest.json"
    try:
        payload = json.loads(read(manifest_path))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{rel(manifest_path)}: invalid JSON: {exc}"]

    if payload.get("contract_version") != "1.0":
        findings.append(f"{demo_id}: contract_version must be 1.0")
    if payload.get("demo_id") != demo_id:
        findings.append(f"{demo_id}: manifest demo_id mismatch")
    if payload.get("run_token") != "LOCAL":
        findings.append(f"{demo_id}: checked-in run_token must be LOCAL")
    if payload.get("safety_level") != expected["safety"]:
        findings.append(f"{demo_id}: safety_level mismatch")
    if expected["safety"] == "YELLOW" and payload.get("timeout_seconds", 0) > 360:
        findings.append(f"{demo_id}: yellow pilot timeout exceeds 360 seconds")

    phases = payload.get("phases")
    if not isinstance(phases, list):
        findings.append(f"{demo_id}: phases must be a list")
        return findings
    phase_ids = {phase.get("id") for phase in phases if isinstance(phase, dict)}
    missing = set(expected["phases"]) - phase_ids
    if missing:
        findings.append(f"{demo_id}: missing phases {sorted(missing)}")
    if not isinstance(payload.get("cleanup"), dict):
        findings.append(f"{demo_id}: cleanup phase missing")

    for phase in [*phases, payload.get("cleanup")]:
        if not isinstance(phase, dict):
            continue
        kind = phase.get("kind", "sql")
        field = "script" if kind == "sql" else "manifest"
        value = phase.get(field)
        if not isinstance(value, str):
            findings.append(f"{demo_id}: phase {phase.get('id')} lacks {field}")
            continue
        candidate = (root / value).resolve()
        try:
            candidate.relative_to(root.resolve())
        except ValueError:
            findings.append(f"{demo_id}: phase path escapes demo directory: {value}")
            continue
        if not candidate.is_file():
            findings.append(f"{demo_id}: phase file missing: {value}")

    for finding in walk_keys(payload):
        findings.append(f"{demo_id}: {finding}")
    return findings


def main() -> int:
    findings: list[str] = []

    for demo_id, expected in PILOTS.items():
        root = expected["path"]
        if not root.is_dir():
            findings.append(f"missing pilot directory: {rel(root)}")
            continue

        readme = root / "README.md"
        manifest = root / "manifest.json"
        if not readme.is_file():
            findings.append(f"{demo_id}: README.md missing")
        if not manifest.is_file():
            findings.append(f"{demo_id}: manifest.json missing")
            continue

        readme_text = read(readme)
        for heading in README_HEADINGS:
            if heading not in readme_text:
                findings.append(f"{demo_id}: README heading missing: {heading}")
        if f"| Demo-ID | `{demo_id}` |" not in readme_text:
            findings.append(f"{demo_id}: traceability row missing")
        if f"| Sicherheitsstufe | `{expected['safety']}` |" not in readme_text:
            findings.append(f"{demo_id}: README safety mismatch")

        findings.extend(validate_manifest(demo_id, root, expected))

        sql_files = sorted(root.rglob("*.sql"))
        if not sql_files:
            findings.append(f"{demo_id}: no SQL files")
        for sql_file in sql_files:
            text = read(sql_file)
            error = sql_lexical_error(text)
            if error:
                findings.append(f"{rel(sql_file)}: {error}")
            upper = text.upper()
            for token in FORBIDDEN_SQL:
                if token in upper:
                    findings.append(f"{rel(sql_file)}: forbidden SQL token {token}")

        cleanup_text = read(root / "90_Cleanup.sql") if (root / "90_Cleanup.sql").is_file() else ""
        for marker in ("SQLPERF.Project", "SQLPERF.ContractVersion", "SQLPERF.DemoId", "SQLPERF.RunToken"):
            if marker not in cleanup_text:
                findings.append(f"{demo_id}: cleanup missing marker {marker}")
        if "SINGLE_USER WITH ROLLBACK IMMEDIATE" not in cleanup_text or "DROP DATABASE" not in cleanup_text:
            findings.append(f"{demo_id}: cleanup does not implement protected database removal")

    for python_file in (ROOT / "Tests" / "Runtime").glob("run_gate_b*.py"):
        try:
            ast.parse(read(python_file), filename=rel(python_file))
        except SyntaxError as exc:
            findings.append(f"{rel(python_file)}:{exc.lineno}: {exc.msg}")

    if findings:
        print(f"gate-b-static: FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print(f"- {finding}")
        return 1

    sql_count = sum(len(list(expected["path"].rglob("*.sql"))) for expected in PILOTS.values())
    print(f"gate-b-static: PASS ({len(PILOTS)} pilots, {sql_count} SQL files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
