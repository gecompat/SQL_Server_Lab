# FWK-006 – Multi-Session-Orchestrierungsvertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | deterministische Ausführung mehrerer SQL-Sessions in einer markierten Testdatenbank |
| Systemobjekte | `sys.extended_properties`, `sys.sp_addextendedproperty` |
| User-defined Tools | `fwk.USP_Signal`, `fwk.USP_WaitForSignal`, `fwk.USP_ClearSignals`, `orchestrate_sessions.py` |
| Drittanbieter-Tool | externes Microsoft-Tool `sqlcmd` |

## 1. Zweck

Der Vertrag trennt fachliche Sessionreihenfolge von Prozessstart und Betriebssystem-Timing. Sessionabhängigkeiten werden nicht durch zufällige Wartezeiten modelliert, sondern durch benannte Signale innerhalb der vollständig markierten Testdatenbank. Der Prozess-Orchestrator startet unabhängige `sqlcmd`-Prozesse, erzwingt ein globales Zeitbudget und beendet verbleibende Prozesse nach Fehler oder Timeout.

## 2. Datenbankseitige Signale

`FWK_MultiSessionControl.sql` installiert ausschließlich in einer nach `FWK-002` markierten Testdatenbank:

- `fwk.SessionSignal`,
- `fwk.USP_Signal`,
- `fwk.USP_WaitForSignal`,
- `fwk.USP_ClearSignals`.

Ein Signal gehört exakt zu `DemoId`, `RunToken` und `SignalName`. Signalnamen bestehen ausschließlich aus Großbuchstaben, Ziffern und Unterstrich. `USP_WaitForSignal` verwendet eine begrenzte Polling-Schleife mit `WAITFOR DELAY`; ein Timeout erzeugt `FAIL_TIMEOUT`.

Die Objekte enthalten keine Login-, Host-, Programm- oder SQL-Textdaten.

## 3. Prozessmanifest

Das JSON-Manifest enthält ausschließlich synthetische und repositorylokale Angaben:

```json
{
  "contract_version": "1.0",
  "demo_id": "CON-004",
  "run_token": "LOCAL",
  "timeout_seconds": 60,
  "abort_on_first_failure": true,
  "sessions": [
    {
      "id": "BLOCKER",
      "script": "Sessions/10_Blocker.sql",
      "launch_delay_ms": 0
    },
    {
      "id": "WAITER",
      "script": "Sessions/20_Waiter.sql",
      "launch_delay_ms": 250
    }
  ]
}
```

Server, Datenbank und Authentifizierung sind keine Manifestfelder. Sie werden zur Laufzeit über Argumente oder die Umgebungsvariablen `SQLPERF_SQL_SERVER`, `SQLPERF_SQL_DATABASE`, `SQLPERF_SQL_AUTH` und `SQLPERF_SQL_USERNAME` übergeben.

## 4. Authentifizierung

`orchestrate_sessions.py` unterstützt:

- `integrated`: `sqlcmd -E`,
- `sql`: Benutzername als Argument und Passwort ausschließlich über `SQLCMDPASSWORD`,
- `aad`: `sqlcmd -G`.

Passwörter dürfen weder im Manifest noch als Kommandozeilenargument vorkommen. Das Tool verwendet kein `shell=True`.

## 5. Zeit- und Fehlervertrag

- Das Manifest besitzt ein positives globales Zeitbudget.
- Maximal 32 Sessions sind zulässig.
- Ein Launch Delay steuert nur den Prozessstart; fachliche Reihenfolge verwendet Datenbanksignale.
- Bei `abort_on_first_failure = true` werden verbleibende Prozesse nach dem ersten Fehler beendet.
- Timeout ergibt `FAIL_TIMEOUT`.
- Nicht erfolgreicher Sessionprozess ergibt `FAIL_EXECUTION`.
- Fehlendes `sqlcmd` ergibt kontrolliert `SKIP_TOOL_MISSING`.
- Rohoutput wird nur mit `--show-output` interaktiv angezeigt und nie durch das Framework persistiert.

## 6. Cleanup

Demo-Cleanup ruft `fwk.USP_ClearSignals` für die exakte Demo-/Run-Kombination auf. Ein optionales Uninstall entfernt die Frameworkobjekte nur nach ausdrücklicher Bestätigung und nur innerhalb der markierten Testdatenbank.

## 7. Abnahmekriterien

`FWK-006` ist `IMPLEMENTED`, wenn Signalobjekte, Prozessmanifest, Orchestrator, Timeoutbehandlung, Prozessabbruch und SQL-Server-unabhängige positive sowie negative Selbsttests vorhanden sind. Runtime-Validierung mit realem Blocking bleibt bis zur Gate-B-Pilotdemo offen.
