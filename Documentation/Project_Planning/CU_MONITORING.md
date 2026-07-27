# CU Monitoring – Dokumentation

| Merkmal | Wert |
|---|---|
| Komponente | `tools/cu_monitor.py` |
| Workflow | `.github/workflows/cu-monitor.yml` |
| State-Datei | `Documentation/Architecture/cu-tracking.json` |
| Stand | 2026-07-27 |

---

## 1. Zweck

Monatlich automatisch prüfen, ob für SQL Server 2019, 2022 oder 2025 ein neues
Cumulative Update (CU) veröffentlicht wurde.  
Bei einem Fund wird ein GitHub Issue erstellt, das alle relevanten Details
(Version, bisheriger Stand, neuer Stand, Quelllinks, Prüfzeitpunkt) enthält.

---

## 2. Datenfluss

```
┌────────────────────────────────────────────────────────────────┐
│  GitHub Actions (monatlicher Cron oder workflow_dispatch)      │
└────────────────────────┬───────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────┐
│  tools/cu_monitor.py                                           │
│                                                                │
│  Für jede Version (2019 / 2022 / 2025):                       │
│   1. Fetch Signal-Quelle  → sqlserverupdates.com              │
│   2. Fetch Authority-Quelle → Microsoft Learn                 │
│   3. Abgleich beider Quellen:                                  │
│      - Übereinstimmung   → status: confirmed                  │
│      - Signal > Authority → status: pending_verification      │
│      - Nur eine Quelle   → status: signal_only / authority_only│
│   4. Vergleich mit bekanntem Stand (cu-tracking.json)         │
│      - Neuerer CU erkannt → zu Updates-Liste hinzufügen       │
│      - Kein neues CU      → nur last_checked aktualisieren    │
└───────┬───────────────────────────────────┬────────────────────┘
        │                                   │
        ▼ (bei neuem CU)                    ▼ (immer)
┌──────────────────┐              ┌─────────────────────────────┐
│  GitHub Issue    │              │  cu-tracking.json           │
│  (REST API)      │              │  (State-Datei, Git-Commit)  │
└──────────────────┘              └─────────────────────────────┘
        │
        ▼ (immer)
┌──────────────────┐
│  Job Summary     │
│  (Aktionsbericht)│
└──────────────────┘
```

---

## 3. Quellen

| Quelle | Rolle | URL |
|---|---|---|
| sqlserverupdates.com | Primäre Signalquelle | `https://sqlserverupdates.com/sql-server-{year}-builds/` |
| Microsoft Learn | Autoritative Verifikation | `https://learn.microsoft.com/de-de/troubleshoot/sql/releases/sqlserver-{year}/build-versions` |

**Warum zwei Quellen?**  
sqlserverupdates.com spiegelt neue CUs meist zeitnah wider.  
Microsoft Learn ist die offizielle Microsoft-Dokumentation und gilt als Referenz.  
Stimmen beide Quellen überein, gilt das Update als `confirmed`.  
Ist sqlserverupdates.com weiter als Learn, wird das Update als
`pending_verification` markiert, und das GitHub Issue enthält einen
entsprechenden Warnhinweis.

---

## 4. State-Datei

**Pfad:** `Documentation/Architecture/cu-tracking.json`

```json
{
  "_comment": "Automatisch aktualisiert.",
  "_last_checked": "2026-07-27T08:00:00Z",
  "versions": {
    "2022": {
      "cu": "CU18",
      "cu_number": 18,
      "build": "16.0.4175.1",
      "kb": "KB5044865",
      "released": "2025-02-13",
      "status": "confirmed",
      "last_checked": "2026-07-27T08:00:00Z"
    }
  }
}
```

| Feld | Bedeutung |
|---|---|
| `cu` | CU-Bezeichner (z. B. `CU18`) |
| `cu_number` | Numerischer CU-Index für Vergleiche |
| `build` | SQL-Server-Build (z. B. `16.0.4175.1`) |
| `kb` | KB-Artikel-Nummer |
| `released` | Veröffentlichungsdatum (ISO) |
| `status` | `confirmed` / `pending_verification` / `signal_only` / `authority_only` / `preview` |
| `last_checked` | Letzter Prüfzeitpunkt (UTC) |

Die State-Datei wird nach jedem erfolgreichen Workflow-Lauf automatisch
committed und gepusht (ausser im Dry-Run-Modus).

---

## 5. Manueller Aufruf (Workflow Dispatch)

### Über GitHub UI

1. Repository öffnen → **Actions** → **SQL Server CU Monitor**.
2. **Run workflow** → Branch wählen → optional **Dry Run** aktivieren → **Run workflow**.

### Über GitHub CLI

```bash
# Normaler Lauf
gh workflow run cu-monitor.yml

# Dry Run (kein Issue, kein Commit)
gh workflow run cu-monitor.yml --field dry_run=true
```

### Lokal

```bash
# Voraussetzungen: Python 3.10+, keine weiteren Abhängigkeiten
cd SQL_Server_Lab

# Dry run (keine externen Schreibzugriffe)
python tools/cu_monitor.py --dry-run

# Nur bestimmte Versionen prüfen
python tools/cu_monitor.py --dry-run --versions 2022 2025

# Produktiv (überschreibt State-Datei, erstellt kein Issue ohne GITHUB_TOKEN)
export GITHUB_TOKEN=<token>
export GITHUB_REPOSITORY=gecompat/SQL_Server_Lab
python tools/cu_monitor.py
```

---

## 6. GitHub Issues

Bei einem neuen CU wird ein Issue erstellt:

- **Titel:** `[CU Monitor] Neues Cumulative Update verfügbar – SQL Server 2022`
- **Labels:** `cu-update`, `sql-server`, `automation`  
  (Bei `pending_verification` zusätzlich: `pending-verification`)

**Issue-Body enthält:**

- Prüfzeitpunkt (UTC)
- Pro betroffener Version:
  - Bisheriger bekannter Stand
  - Neuer Stand (CU, Build, KB)
  - Links zu beiden Quellen

---

## 7. Robustheit

| Mechanismus | Umsetzung |
|---|---|
| Netzwerkfehler | 3 Wiederholungsversuche mit 5 s Pause |
| HTTP-Timeout | 30 s pro Anfrage |
| 404 / dauerhafter Fehler | Kein Retry, Warnung im Log |
| Beide Quellen nicht erreichbar | Version wird übersprungen, Fehler im Job Summary |
| Quellen-Widerspruch | Status `pending_verification`, Warnung im Issue |
| State-Datei fehlt | Automatische Initialisierung mit bekannten Startwerten |
| Ungültige State-Datei | Fallback auf Standardwerte, Warnung im Log |

---

## 8. Troubleshooting

### Issue wird nicht erstellt

- `GITHUB_TOKEN` fehlt oder hat keine `issues: write`-Berechtigung.
- Prüfe den Workflow unter **Actions** → Laufprotokoll → Schritt **CU Monitor ausführen**.

### State-Datei wird nicht aktualisiert

- Workflow läuft im Dry-Run-Modus.
- `GITHUB_TOKEN` hat keine `contents: write`-Berechtigung.
- Git-Konflikt beim Push (selten bei reinen Tool-Commits).

### HTTP-Fehler bei Quellabfrage

- Kann vorübergehend sein (Netzwerk, Site-Wartung).
- Das Script versucht bis zu 3 Mal.
- Bei dauerhaftem Fehler: Version für diesen Lauf übersprungen.  
  Nächster monatlicher Lauf versucht es erneut.

### CU-Erkennung liefert falsches Ergebnis

- HTML-Struktur der Quellseiten kann sich ändern.
- Das Script hat zwei Parsing-Strategien: Tabellenparsing und Regex-Fallback.
- Bei anhaltenden Problemen: Parsing-Logik in `_extract_cu_from_row()` und
  `_regex_fallback()` in `tools/cu_monitor.py` anpassen.
- Lokaler Test: `python tools/cu_monitor.py --dry-run` und Log prüfen.

### Manually bekannten Stand korrigieren

Wenn der Stand in der State-Datei falsch ist, kann er manuell angepasst werden:

```json
"2022": {
  "cu": "CU20",
  "cu_number": 20,
  "build": "16.0.4200.1",
  "kb": "KB5050000",
  "released": "2025-06-12",
  "status": "confirmed",
  "last_checked": "2026-07-27T00:00:00Z"
}
```

Dann normalen Commit erstellen. Beim nächsten Lauf wird der korrigierte Stand
als Basis verwendet.

---

## 9. Abhängigkeiten

Das Script verwendet ausschliesslich Python-Standardbibliothek (≥ 3.10):

| Modul | Verwendung |
|---|---|
| `urllib.request` | HTTP-Anfragen |
| `urllib.error` | Fehlerbehandlung |
| `html.parser` | HTML-Tabellen-Parsing |
| `json` | State-Datei lesen/schreiben |
| `re` | Regex-Mustersuche (Fallback-Parsing) |
| `pathlib` | Dateipfade |
| `argparse` | CLI-Parameter |
| `datetime` | Zeitstempel |

Keine externen Pip-Pakete erforderlich.
