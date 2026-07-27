#!/usr/bin/env python3
"""
cu_monitor.py – Monthly Cumulative Update Monitor for SQL Server 2019, 2022, 2025

Checks two sources per version:
  Signal source:    https://sqlserverupdates.com/sql-server-{year}-builds/
  Authority source: https://learn.microsoft.com/de-de/troubleshoot/sql/releases/sqlserver-{year}/build-versions

Logic:
  - If both sources agree on a newer CU → confirmed update → create GitHub Issue
  - If sources disagree → pending_verification → create GitHub Issue with warning
  - If only one source is available → use it with a warning label
  - If no update found → write clean job summary and exit 0

Usage:
    python tools/cu_monitor.py [--dry-run]

Exit codes:
    0 – Completed successfully (with or without updates)
    1 – Fatal error during execution
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

VERSIONS: List[str] = ["2019", "2022", "2025"]

# Primary signal source (version-specific pages)
SIGNAL_URLS: Dict[str, str] = {
    "2019": "https://sqlserverupdates.com/sql-server-2019-builds/",
    "2022": "https://sqlserverupdates.com/sql-server-2022-builds/",
    "2025": "https://sqlserverupdates.com/sql-server-2025-builds/",
}

# Authoritative verification (Microsoft Learn, German)
AUTHORITY_URLS: Dict[str, str] = {
    "2019": "https://learn.microsoft.com/de-de/troubleshoot/sql/releases/sqlserver-2019/build-versions",
    "2022": "https://learn.microsoft.com/de-de/troubleshoot/sql/releases/sqlserver-2022/build-versions",
    "2025": "https://learn.microsoft.com/de-de/troubleshoot/sql/releases/sqlserver-2025/build-versions",
}

# Build major version numbers per release year
MAJOR_VERSIONS: Dict[str, int] = {"2019": 15, "2022": 16, "2025": 17}

# HTTP settings
MAX_RETRIES: int = 3
RETRY_DELAY: int = 5      # seconds between retries
REQUEST_TIMEOUT: int = 30  # seconds per attempt

# GitHub settings (populated from environment)
GITHUB_API = "https://api.github.com"
GH_REPO = os.environ.get("GITHUB_REPOSITORY", "")
GH_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GH_SUMMARY_FILE = os.environ.get("GITHUB_STEP_SUMMARY", "")

# Repository paths
REPO_ROOT = Path(__file__).parent.parent
STATE_FILE = REPO_ROOT / "Documentation" / "Architecture" / "cu-tracking.json"

USER_AGENT = (
    "SQL_Server_Lab-CU-Monitor/1.0 "
    "(+https://github.com/gecompat/SQL_Server_Lab)"
)

# German month name → zero-padded month number
_DE_MONTHS: Dict[str, str] = {
    "januar": "01", "februar": "02", "märz": "03", "april": "04",
    "mai": "05", "juni": "06", "juli": "07", "august": "08",
    "september": "09", "oktober": "10", "november": "11", "dezember": "12",
}


# ─────────────────────────────────────────────────────────────────────────────
# Minimal HTML Table Parser (stdlib only)
# ─────────────────────────────────────────────────────────────────────────────

class _TableParser(HTMLParser):
    """Parses HTML and collects all top-level table data.

    Each table is stored as a list of rows; each row is a list of cell texts.
    Nested tables are skipped (depth > 1).
    """

    def __init__(self) -> None:
        super().__init__()
        self.tables: List[List[List[str]]] = []
        self._table: Optional[List[List[str]]] = None
        self._row: Optional[List[str]] = None
        self._in_cell: bool = False
        self._cell_buf: List[str] = []
        self._depth: int = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag == "table":
            self._depth += 1
            if self._depth == 1:
                self._table = []
                self.tables.append(self._table)
        elif tag == "tr" and self._depth == 1 and self._table is not None:
            self._row = []
            self._table.append(self._row)
        elif tag in ("td", "th") and self._depth == 1:
            self._in_cell = True
            self._cell_buf = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "table":
            self._depth -= 1
            if self._depth == 0:
                self._table = None
                self._row = None
        elif tag == "tr" and self._depth == 1:
            self._row = None
        elif tag in ("td", "th") and self._depth == 1 and self._in_cell:
            if self._row is not None:
                self._row.append(" ".join(self._cell_buf).strip())
            self._in_cell = False
            self._cell_buf = []

    def handle_data(self, data: str) -> None:
        if self._in_cell:
            text = data.strip()
            if text:
                self._cell_buf.append(text)

    def handle_entityref(self, name: str) -> None:
        if self._in_cell:
            _ENTS = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'", "nbsp": " "}
            self._cell_buf.append(_ENTS.get(name, ""))

    def handle_charref(self, name: str) -> None:
        if self._in_cell:
            try:
                char = chr(int(name[1:], 16) if name.startswith("x") else int(name))
                self._cell_buf.append(char)
            except (ValueError, OverflowError):
                pass


def _parse_html_tables(html: str) -> List[List[List[str]]]:
    """Return all top-level tables from HTML as nested lists."""
    parser = _TableParser()
    parser.feed(html)
    return parser.tables


# ─────────────────────────────────────────────────────────────────────────────
# HTTP Utilities
# ─────────────────────────────────────────────────────────────────────────────

def fetch_url(url: str) -> Optional[str]:
    """Fetch a URL with retry logic.

    Returns the response body as a string, or None on failure.
    """
    headers = {"User-Agent": USER_AGENT, "Accept": "text/html,*/*"}
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                encoding = resp.headers.get_content_charset("utf-8")
                content = resp.read().decode(encoding, errors="replace")
                log(f"  [HTTP {resp.status}] {url}")
                return content
        except urllib.error.HTTPError as exc:
            log(f"  [HTTP {exc.code}] {url} (attempt {attempt}/{MAX_RETRIES})")
            if exc.code in (404, 410):
                break  # Not found – no point retrying
        except urllib.error.URLError as exc:
            log(f"  [URLError] {url} – {exc.reason} (attempt {attempt}/{MAX_RETRIES})")
        except Exception as exc:  # noqa: BLE001
            log(f"  [Error] {url} – {exc} (attempt {attempt}/{MAX_RETRIES})")

        if attempt < MAX_RETRIES:
            log(f"  Warte {RETRY_DELAY}s vor erneutem Versuch …")
            time.sleep(RETRY_DELAY)

    log(f"  [WARN] Alle {MAX_RETRIES} Versuche fehlgeschlagen: {url}")
    return None


# ─────────────────────────────────────────────────────────────────────────────
# CU Parsing Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _parse_build(build_str: Optional[str]) -> Tuple[int, ...]:
    """Parse '15.0.4385.2' → (15, 0, 4385, 2) for numeric comparison."""
    if not build_str:
        return ()
    try:
        return tuple(int(x) for x in build_str.strip().split("."))
    except ValueError:
        return ()


def _extract_cu_number(cu_str: Optional[str]) -> int:
    """Extract the integer from a CU string.

    Examples: 'CU28' → 28, 'CU 28' → 28, 'CTP' / 'RTM' → 0, unknown → -1.
    """
    if cu_str is None:
        return -1
    match = re.search(r"\d+", cu_str)
    return int(match.group()) if match else 0


def _parse_de_date(text: str) -> Optional[str]:
    """Convert various date formats to ISO 'YYYY-MM-DD'.

    Handles:
    - ISO:         '2025-02-13'
    - German long: '13. Februar 2025'
    - German short:'13.02.2025'
    """
    # ISO already
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    if m:
        return m.group(1)

    # German long: "13. Februar 2025"
    m = re.search(r"(\d{1,2})\.\s*(\w+)\s+(\d{4})", text)
    if m:
        day, month_name, year = m.group(1), m.group(2).lower(), m.group(3)
        month = _DE_MONTHS.get(month_name)
        if month:
            return f"{year}-{month}-{int(day):02d}"

    # German short: "13.02.2025"
    m = re.search(r"\b(\d{1,2})\.(\d{2})\.(\d{4})\b", text)
    if m:
        return f"{m.group(3)}-{m.group(2)}-{int(m.group(1)):02d}"

    return None


def _extract_cu_from_row(row_cells: List[str], version: str) -> Optional[Dict]:
    """Extract CU info from a single table row if it represents a CU release.

    Returns a dict with keys: cu, cu_number, build, kb, released.
    Returns None if the row is not a CU row.
    """
    row_text = " ".join(row_cells)

    # Skip pure GDR rows (Security patches without a CU)
    has_gdr = bool(re.search(r"\bGDR\b", row_text, re.IGNORECASE))
    has_cu = bool(
        re.search(
            r"\bCU\s*\d+\b|\bCumulative Update\s+\d+\b|\bKumulatives Update\s+\d+\b",
            row_text,
            re.IGNORECASE,
        )
    )
    if has_gdr and not has_cu:
        return None

    # Must contain a CU reference
    cu_match = re.search(
        r"CU\s*(\d+)|Cumulative Update\s+(\d+)|Kumulatives Update\s+(\d+)",
        row_text,
        re.IGNORECASE,
    )
    if not cu_match:
        return None

    cu_num = int(next(g for g in cu_match.groups() if g is not None))
    major = MAJOR_VERSIONS.get(version, 15)

    build_match = re.search(rf"\b{major}\.\d+\.\d+\.\d+\b", row_text)
    kb_match = re.search(r"\bKB\s*(\d{7})\b", row_text, re.IGNORECASE)

    released = _parse_de_date(row_text)

    return {
        "cu": f"CU{cu_num}",
        "cu_number": cu_num,
        "build": build_match.group() if build_match else None,
        "kb": f"KB{kb_match.group(1)}" if kb_match else None,
        "released": released,
    }


def _is_build_table_header(header_cells: List[str]) -> bool:
    """Heuristic: does this row look like a build-table header?"""
    if not header_cells:
        return False
    combined = " ".join(header_cells).lower()
    keywords = ["build", "version", "kb", "update", "datum", "date", "beschreibung", "description"]
    return sum(1 for k in keywords if k in combined) >= 2


def _find_latest_cu_in_tables(tables: List[List[List[str]]], version: str) -> Optional[Dict]:
    """Search all HTML tables for the latest CU entry."""
    for table in tables:
        if len(table) < 2:
            continue

        # Find the header row (first row with keyword matches)
        start_row = 0
        if _is_build_table_header(table[0]):
            start_row = 1

        for row in table[start_row:]:
            result = _extract_cu_from_row(row, version)
            if result:
                return result

    return None


def _regex_fallback(html: str, version: str) -> Optional[Dict]:
    """Last-resort extraction: scan raw HTML with regex patterns.

    Looks for the first occurrence of a CU reference near a build number.
    """
    major = MAJOR_VERSIONS.get(version, 15)
    # Find all CU occurrences with surrounding context
    pattern = re.compile(
        rf"(CU\s*\d+|Cumulative Update\s+\d+|Kumulatives Update\s+\d+)"
        rf".{{0,300}}"
        rf"({major}\.\d+\.\d+\.\d+)",
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(html)
    if not match:
        # Try reversed order: build first, then CU
        pattern = re.compile(
            rf"({major}\.\d+\.\d+\.\d+)"
            rf".{{0,300}}"
            rf"(CU\s*\d+|Cumulative Update\s+\d+|Kumulatives Update\s+\d+)",
            re.IGNORECASE | re.DOTALL,
        )
        match = pattern.search(html)
        if not match:
            return None
        build_str, cu_str = match.group(1), match.group(2)
    else:
        cu_str, build_str = match.group(1), match.group(2)

    cu_num_match = re.search(r"\d+", cu_str)
    if not cu_num_match:
        return None
    cu_num = int(cu_num_match.group())

    # Try to find KB near the match
    context = html[max(0, match.start() - 200):match.end() + 200]
    kb_match = re.search(r"\bKB\s*(\d{7})\b", context, re.IGNORECASE)

    return {
        "cu": f"CU{cu_num}",
        "cu_number": cu_num,
        "build": build_str,
        "kb": f"KB{kb_match.group(1)}" if kb_match else None,
        "released": _parse_de_date(context),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Source Fetchers
# ─────────────────────────────────────────────────────────────────────────────

def fetch_cu_from_signal(version: str) -> Optional[Dict]:
    """Fetch and parse the latest CU from sqlserverupdates.com."""
    url = SIGNAL_URLS[version]
    log(f"[Signal]    Fetching {url}")
    html = fetch_url(url)
    if html is None:
        return None

    tables = _parse_html_tables(html)
    result = _find_latest_cu_in_tables(tables, version)
    if result:
        result["source_url"] = url
        return result

    log(f"  [WARN] Tabellenparsing ohne Ergebnis, versuche Regex-Fallback …")
    result = _regex_fallback(html, version)
    if result:
        result["source_url"] = url
    return result


def fetch_cu_from_authority(version: str) -> Optional[Dict]:
    """Fetch and parse the latest CU from Microsoft Learn."""
    url = AUTHORITY_URLS[version]
    log(f"[Authority] Fetching {url}")
    html = fetch_url(url)
    if html is None:
        return None

    tables = _parse_html_tables(html)
    result = _find_latest_cu_in_tables(tables, version)
    if result:
        result["source_url"] = url
        return result

    log(f"  [WARN] Tabellenparsing ohne Ergebnis, versuche Regex-Fallback …")
    result = _regex_fallback(html, version)
    if result:
        result["source_url"] = url
    return result


# ─────────────────────────────────────────────────────────────────────────────
# State Management
# ─────────────────────────────────────────────────────────────────────────────

def load_state() -> Dict:
    """Load the CU tracking state from disk.

    Returns the parsed JSON dict; creates a default state if the file is absent.
    """
    if STATE_FILE.exists():
        try:
            with STATE_FILE.open(encoding="utf-8") as fh:
                return json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            log(f"[WARN] Konnte State-Datei nicht lesen: {exc} – verwende Standardwerte")

    return _default_state()


def save_state(state: Dict) -> None:
    """Persist the CU tracking state to disk."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with STATE_FILE.open("w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    log(f"[State] Gespeichert: {STATE_FILE}")


def _default_state() -> Dict:
    """Return an initial state based on the known catalog values."""
    now = _utcnow()
    return {
        "_comment": (
            "CU-Tracking-State für SQL Server 2019, 2022, 2025. "
            "Wird automatisch vom CU Monitor Workflow aktualisiert."
        ),
        "_last_checked": now,
        "versions": {
            "2019": {
                "cu": "CU28",
                "cu_number": 28,
                "build": "15.0.4385.2",
                "kb": "KB5039747",
                "released": "2024-06-13",
                "status": "confirmed",
                "last_checked": now,
            },
            "2022": {
                "cu": "CU18",
                "cu_number": 18,
                "build": "16.0.4175.1",
                "kb": "KB5044865",
                "released": "2025-02-13",
                "status": "confirmed",
                "last_checked": now,
            },
            "2025": {
                "cu": "CTP",
                "cu_number": 0,
                "build": None,
                "kb": None,
                "released": "2025-05-01",
                "status": "preview",
                "last_checked": now,
            },
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# Update Detection
# ─────────────────────────────────────────────────────────────────────────────

def is_newer(candidate: Dict, known: Dict) -> bool:
    """Return True if candidate represents a newer release than known.

    Comparison order:
      1. CU number (higher = newer)
      2. Build tuple (lexicographic on integer parts, higher = newer)
    """
    c_num = candidate.get("cu_number", -1)
    k_num = known.get("cu_number", -1)

    if c_num < 0 or k_num < 0:
        return False  # Cannot compare unknown states
    if c_num > k_num:
        return True
    if c_num < k_num:
        return False

    # Equal CU numbers → compare build
    c_build = _parse_build(candidate.get("build"))
    k_build = _parse_build(known.get("build"))
    return bool(c_build and k_build and c_build > k_build)


def reconcile_sources(
    signal: Optional[Dict],
    authority: Optional[Dict],
    version: str,
) -> Optional[Dict]:
    """Reconcile signal and authority into a single result.

    Returns a dict with an extra 'status' field:
      - 'confirmed'           – both sources agree
      - 'pending_verification' – sources disagree (signal ahead of authority)
      - 'authority_only'      – only Microsoft Learn responded
      - 'signal_only'         – only sqlserverupdates.com responded
    Returns None if both sources failed.
    """
    if signal is None and authority is None:
        log(f"  [WARN] SQL Server {version}: Beide Quellen nicht verfügbar.")
        return None

    if signal is None:
        log(f"  [WARN] SQL Server {version}: Signal-Quelle nicht verfügbar, nutze nur Authority.")
        authority["status"] = "authority_only"
        return authority

    if authority is None:
        log(f"  [WARN] SQL Server {version}: Authority-Quelle nicht verfügbar, nutze nur Signal.")
        signal["status"] = "signal_only"
        return signal

    sig_num = signal.get("cu_number", -1)
    auth_num = authority.get("cu_number", -1)

    if sig_num == auth_num:
        # Agree on CU number: take the authority data (more trusted), mark confirmed
        result = dict(authority)
        # Prefer signal build if authority has none
        if not result.get("build") and signal.get("build"):
            result["build"] = signal["build"]
        result["status"] = "confirmed"
        return result

    if sig_num > auth_num:
        # Signal is ahead – authority hasn't published yet
        log(
            f"  [WARN] SQL Server {version}: Signal ({signal.get('cu')}) "
            f"ist neuer als Authority ({authority.get('cu')}). → pending_verification"
        )
        result = dict(signal)
        result["status"] = "pending_verification"
        result["authority_cu"] = authority.get("cu")
        result["authority_build"] = authority.get("build")
        return result

    # Authority is ahead of signal (unusual)
    log(
        f"  [INFO] SQL Server {version}: Authority ({authority.get('cu')}) "
        f"ist neuer als Signal ({signal.get('cu')}). → confirmed (authority)"
    )
    result = dict(authority)
    result["status"] = "confirmed"
    return result


# ─────────────────────────────────────────────────────────────────────────────
# GitHub Integration
# ─────────────────────────────────────────────────────────────────────────────

def create_github_issue(title: str, body: str, labels: Optional[List[str]] = None) -> bool:
    """Create a GitHub Issue via the REST API.

    Returns True on success, False on failure.
    Requires GH_TOKEN and GH_REPO to be set.
    """
    if not GH_TOKEN or not GH_REPO:
        log("[ERROR] GITHUB_TOKEN oder GITHUB_REPOSITORY nicht gesetzt – Issue wird nicht erstellt.")
        return False

    payload = {"title": title, "body": body}
    if labels:
        payload["labels"] = labels

    data = json.dumps(payload).encode("utf-8")
    url = f"{GITHUB_API}/repos/{GH_REPO}/issues"
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": "Bearer " + GH_TOKEN,
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            response_body = json.loads(resp.read().decode("utf-8"))
            issue_url = response_body.get("html_url", "(URL nicht verfügbar)")
            log(f"[GitHub] Issue erstellt: {issue_url}")
            return True
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        log(f"[ERROR] GitHub Issue Erstellung fehlgeschlagen: HTTP {exc.code} – {error_body[:300]}")
    except Exception as exc:  # noqa: BLE001
        log(f"[ERROR] GitHub Issue Erstellung fehlgeschlagen: {exc}")
    return False


# ─────────────────────────────────────────────────────────────────────────────
# Output Formatting
# ─────────────────────────────────────────────────────────────────────────────

def _version_table_md(version: str, update: Dict, known: Dict) -> str:
    """Format a Markdown section for one version's update."""
    signal_url = SIGNAL_URLS[version]
    authority_url = AUTHORITY_URLS[version]

    known_cu = known.get("cu", "unbekannt")
    known_build = known.get("build") or "–"
    known_released = known.get("released") or "–"
    new_cu = update.get("cu", "–")
    new_build = update.get("build") or "–"
    new_released = update.get("released") or "–"
    new_kb = update.get("kb") or "–"
    status = update.get("status", "confirmed")

    status_note = ""
    if status == "pending_verification":
        authority_cu = update.get("authority_cu", "–")
        status_note = (
            f"\n> ⚠️ **Pending Verification**: sqlserverupdates.com zeigt **{new_cu}**, "
            f"Microsoft Learn zeigt noch **{authority_cu}**. "
            "Bitte manuell prüfen, bevor Maßnahmen ergriffen werden.\n"
        )
    elif status == "signal_only":
        status_note = (
            "\n> ⚠️ **Nur Signal-Quelle**: Microsoft Learn war nicht erreichbar. "
            "Bitte manuell gegen die Authority-Quelle verifizieren.\n"
        )
    elif status == "authority_only":
        status_note = (
            "\n> ℹ️ **Nur Authority-Quelle**: sqlserverupdates.com war nicht erreichbar.\n"
        )

    kb_link = f"[{new_kb}](https://support.microsoft.com/help/{new_kb[2:]})" if new_kb != "–" else "–"

    return (
        f"### SQL Server {version}\n"
        f"{status_note}\n"
        f"| Eigenschaft | Wert |\n"
        f"|---|---|\n"
        f"| Bisheriger Stand | {known_cu} / Build {known_build} ({known_released}) |\n"
        f"| **Neuer Stand** | **{new_cu}** / Build {new_build} ({new_released}) |\n"
        f"| KB-Artikel | {kb_link} |\n"
        f"| Quelle (sqlserverupdates.com) | {signal_url} |\n"
        f"| Quelle (Microsoft Learn) | {authority_url} |\n"
    )


def format_issue_body(updates: List[Tuple[str, Dict, Dict]], checked_at: str) -> str:
    """Build the full Markdown body for the GitHub Issue."""
    has_pending = any(u["status"] == "pending_verification" for _, u, _ in updates)

    lines = [
        "## Neue Cumulative Updates erkannt",
        "",
        f"**Prüfzeitpunkt:** `{checked_at}`",
        "",
    ]

    if has_pending:
        lines += [
            "> ⚠️ Mindestens ein Update konnte nicht von beiden Quellen bestätigt werden.",
            "> Bitte prüfe die mit **⚠️ Pending Verification** markierten Versionen manuell.",
            "",
        ]

    lines.append("---")
    lines.append("")
    for version, update, known in updates:
        lines.append(_version_table_md(version, update, known))
        lines.append("")

    lines += [
        "---",
        "",
        "*Dieser Issue wurde automatisch erstellt durch den "
        "[CU Monitor Workflow](../../actions/workflows/cu-monitor.yml).*",
    ]
    return "\n".join(lines)


def write_summary(content: str) -> None:
    """Write content to the GitHub Actions step summary file."""
    if GH_SUMMARY_FILE:
        try:
            with open(GH_SUMMARY_FILE, "a", encoding="utf-8") as fh:
                fh.write(content + "\n")
        except OSError as exc:
            log(f"[WARN] Job-Summary konnte nicht geschrieben werden: {exc}")
    else:
        # Not running in GitHub Actions; print to stdout instead
        print(content)


# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────

def log(message: str) -> None:
    """Print a timestamped log message to stdout."""
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {message}", flush=True)


def _utcnow() -> str:
    """Return current UTC time as ISO 8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Monthly CU Monitor for SQL Server 2019, 2022, 2025"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=os.environ.get("DRY_RUN", "").lower() == "true",
        help="Check sources but do not create issues or save state",
    )
    parser.add_argument(
        "--versions",
        nargs="+",
        default=VERSIONS,
        choices=VERSIONS,
        help="Versions to check (default: all)",
    )
    args = parser.parse_args()

    checked_at = _utcnow()
    log("=" * 70)
    log(f"SQL Server CU Monitor – Start: {checked_at}")
    if args.dry_run:
        log("[DRY RUN] Kein Issue wird erstellt, State-Datei wird nicht gespeichert.")
    log("=" * 70)

    # Load current state
    state = load_state()
    known_versions: Dict = state.setdefault("versions", {})

    updates_found: List[Tuple[str, Dict, Dict]] = []  # (version, new_cu, known_cu)
    errors: List[str] = []

    for version in args.versions:
        log(f"\n── SQL Server {version} ──────────────────────────────────────")
        known = known_versions.get(version, {})
        log(f"  Bekannter Stand: {known.get('cu', 'unbekannt')} / {known.get('build', '–')}")

        signal = fetch_cu_from_signal(version)
        authority = fetch_cu_from_authority(version)

        if signal is None and authority is None:
            errors.append(f"SQL Server {version}: Keine Quelle erreichbar.")
            log(f"  [ERROR] Keine Quelle für SQL Server {version} erreichbar – überspringe.")
            continue

        reconciled = reconcile_sources(signal, authority, version)
        if reconciled is None:
            errors.append(f"SQL Server {version}: Quellabgleich fehlgeschlagen.")
            continue

        log(
            f"  Erkannter Stand: {reconciled.get('cu', '–')} / "
            f"{reconciled.get('build', '–')} "
            f"[{reconciled.get('status', '?')}]"
        )

        if is_newer(reconciled, known):
            log(f"  → NEUES UPDATE GEFUNDEN für SQL Server {version}!")
            updates_found.append((version, reconciled, known))
        else:
            log(f"  → Kein neues Update.")

        # Update state entry regardless (refreshes last_checked)
        known_versions[version] = {
            "cu": reconciled.get("cu") or known.get("cu"),
            "cu_number": reconciled.get("cu_number", known.get("cu_number", -1)),
            "build": reconciled.get("build") or known.get("build"),
            "kb": reconciled.get("kb") or known.get("kb"),
            "released": reconciled.get("released") or known.get("released"),
            "status": reconciled.get("status", "confirmed"),
            "last_checked": checked_at,
        }

    state["_last_checked"] = checked_at

    # ── Issue creation ────────────────────────────────────────────────────────
    issue_created = False
    if updates_found:
        log(f"\n[GitHub] {len(updates_found)} neue CU(s) gefunden – erstelle Issue …")
        affected = ", ".join(f"SQL Server {v}" for v, _, _ in updates_found)
        has_pending = any(u["status"] == "pending_verification" for _, u, _ in updates_found)
        prefix = "[CU Monitor] ⚠️ Pending Verification" if has_pending else "[CU Monitor]"
        title = f"{prefix} Neues Cumulative Update verfügbar – {affected}"
        body = format_issue_body(updates_found, checked_at)

        if args.dry_run:
            log("[DRY RUN] Issue würde erstellt mit Titel:")
            log(f"  {title}")
        else:
            issue_labels = ["cu-update", "sql-server", "automation"]
            if has_pending:
                issue_labels.append("pending-verification")
            issue_created = create_github_issue(title, body, issue_labels)
    else:
        log("\n[OK] Kein neues Cumulative Update gefunden.")

    # ── Save state ────────────────────────────────────────────────────────────
    if not args.dry_run:
        save_state(state)

    # ── Job summary ───────────────────────────────────────────────────────────
    summary_lines = [
        "## SQL Server CU Monitor",
        "",
        f"**Prüfzeitpunkt:** `{checked_at}`",
        "",
        "| SQL Server | Stand | Status |",
        "|---|---|---|",
    ]
    for version in args.versions:
        entry = known_versions.get(version, {})
        cu = entry.get("cu", "–")
        build = entry.get("build") or "–"
        status = entry.get("status", "–")
        updated = any(v == version for v, _, _ in updates_found)
        flag = " ✅ Neu" if updated else ""
        summary_lines.append(f"| {version} | {cu} / {build} | {status}{flag} |")

    if errors:
        summary_lines += ["", "### ⚠️ Fehler", ""]
        for e in errors:
            summary_lines.append(f"- {e}")

    if updates_found and issue_created:
        summary_lines += ["", f"**GitHub Issue erstellt** für: {affected}"]
    elif updates_found and args.dry_run:
        summary_lines += ["", f"*Dry run – kein Issue erstellt* ({affected})"]

    write_summary("\n".join(summary_lines))

    log("\n" + "=" * 70)
    log(f"SQL Server CU Monitor – Ende: {_utcnow()}")
    if errors:
        log(f"[WARN] {len(errors)} Fehler aufgetreten (siehe oben).")
    log("=" * 70)

    return 0


if __name__ == "__main__":
    sys.exit(main())
