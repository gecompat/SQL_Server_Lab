# FWK-010 – Runtime-Harness-Vertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | sequenzielle Demoausführung, Multi-Session-Phasen, Summary-Auswertung und Cleanup |
| User-defined Tools | `run_demo.py`, `orchestrate_sessions.py`, `sqlcmd_process.py` |
| Drittanbieter-Tool | externes Microsoft-Tool `sqlcmd` |

## 1. Zweck

Der Runtime-Harness führt eine Demo nach dem dokumentierten Phasenvertrag aus. Er ersetzt keine fachliche Demo, sondern steuert vorhandene repositorylokale Skripte, wertet `SQLPERF_SUMMARY`-Marker aus und erzwingt Cleanup nach gestarteter Setup-Phase.

## 2. Manifest

Ein Manifest enthält:

- Vertragsversion,
- kanonische Demo-ID,
- synthetischen Run-Token,
- Sicherheitsstufe,
- globales Zeitbudget,
- geordnete SQL- oder Multi-Session-Phasen,
- optionales Cleanup.

Datenbankselektoren sind ausschließlich `master` oder `target`. Der Zielname wird deterministisch als `SQLPERF_LAB_<DEMO>_<RUN>` abgeleitet. Pfade müssen innerhalb des Manifestverzeichnisses liegen.

## 3. Phasenverhalten

- `PREFLIGHT` benötigt einen maschinenlesbaren Marker `SQLPERF_SUMMARY|OUTCOME|CODE` oder eine pipe-separierte `SUMMARY`-Resultsetzeile.
- SQL-Phasen mit Exitcode 0 und ohne Marker gelten außerhalb des Preflights als `PASS`.
- Ein strukturierter `SKIP` einer erforderlichen Phase stoppt weitere zustandsverändernde Phasen.
- Ein optionaler `SKIP` wird als sichtbare Warnung behandelt und blockiert die übrigen Phasen nicht.
- Multi-Session-Phasen delegieren an `FWK-006`.
- Das globale Harness-Zeitbudget gilt über alle regulären Phasen.
- Nach gestarteter Setup-Phase wird das konfigurierte Cleanup unabhängig vom vorherigen Ergebnis ausgeführt.
- Cleanup-Fehler überschreiben das Gesamtergebnis mit `FAIL_CLEANUP`, ohne den ursprünglichen Fehlerkontext zu verbergen.

## 4. Sicherheitsstufen

- `GREEN` benötigt keine zusätzliche Harness-Bestätigung.
- `YELLOW` benötigt `--confirm-isolated-lab`.
- `RED` benötigt `--allow-red`; ein dokumentierter Resetpfad bleibt zusätzlich im Demo-README verpflichtend.
- Rote Demos werden nicht automatisch durch den Standard-CI-Harness ausgeführt.

## 5. Authentifizierung und Datenschutz

Die Verbindungsregeln entsprechen `FWK-006`. `SQLCMDPASSWORD` ist die einzige unterstützte Passwortquelle. Der Harness schreibt weder Rohoutput noch Verbindungsdaten in Dateien. `--show-output` ist eine interaktive Diagnoseoption.

## 6. Prozess- und Ergebnisvertrag

- Fehlendes `sqlcmd`: `SKIP_TOOL_MISSING`.
- Manifestfehler: `FAIL_CONTRACT`.
- Prozessfehler: `FAIL_EXECUTION`.
- Timeout: `FAIL_TIMEOUT`.
- Cleanupfehler: `FAIL_CLEANUP`.
- Gesamtergebnispriorität: `FAIL > SKIP > WARN > PASS`.
- Prozess-Exitcode 0 gilt für `PASS`, `WARN` und kontrollierten `SKIP`; Fehler erhalten einen von null verschiedenen Exitcode.

## 7. Abnahmekriterien

`FWK-010` ist `IMPLEMENTED`, wenn sequenzielle Phasen, Multi-Session-Delegation, Sicherheitsbestätigungen, Summary-Parsing, globale Zeitlimits, Cleanup-Priorität und SQL-Server-unabhängige Selbsttests vorhanden sind. Die SQL-Server-Matrix bleibt bis zu einer verfügbaren Runtime offen.
