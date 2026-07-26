# FWK-007 – Query-Store- und Extended-Events-Vertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | Query Store in der markierten Testdatenbank und serverweite Extended-Events-Referenzsession |
| Systemobjekte | `sys.database_query_store_options`, `sys.server_event_sessions`, `sys.dm_xe_sessions`, `sys.dm_xe_session_targets` |
| User-defined Tools | `FWK_QueryStoreLifecycle.sql`, `FWK_ExtendedEventsLifecycle.sql` |
| Drittanbieter-Tools | keine |

## 1. Zweck

Der Vertrag stellt kontrollierte Lifecycle-Operationen bereit, ohne Telemetrie dauerhaft außerhalb des Labors zu hinterlassen. Query Store wird ausschließlich in der vollständig markierten Testdatenbank verändert. Die Extended-Events-Referenzsession verwendet einen deterministischen Namen, `STARTUP_STATE = OFF` und ausschließlich das flüchtige `ring_buffer`-Target.

## 2. Query Store

`FWK_QueryStoreLifecycle.sql` unterstützt:

- `STATUS`,
- `ENABLE`,
- `CLEAR`,
- `RESTORE`.

Vor der ersten Änderung wird der ursprüngliche gewünschte Zustand samt relevanter Konfiguration in `fwk.QueryStoreBaseline` erfasst. `RESTORE` stellt diesen Zustand wieder her und entfernt den Baseline-Datensatz erst nach erfolgreicher Rücksetzung.

`CLEAR` benötigt eine ausdrückliche Bestätigung. Ein vorhandener benutzerdefinierter `CUSTOM`-Capture-Mode wird nicht unvollständig rekonstruiert; eine solche Ausgangskonfiguration führt vor der Änderung zu `SKIP_CONFIGURATION`.

## 3. Extended Events

`FWK_ExtendedEventsLifecycle.sql` unterstützt:

- `STATUS`,
- `CREATE`,
- `START`,
- `STOP`,
- `DROP`.

Der Name folgt:

```text
SQLPERF_<DEMO-ID OHNE BINDESTRICH>_<RUN-TOKEN>
```

Die Referenzsession erfasst ausschließlich `sqlserver.error_reported` mit Fehlernummern ab 50000 und filtert auf die markierte Testdatenbank. Das Target ist `package0.ring_buffer` mit höchstens 1024 KB. Es werden kein `event_file`, kein Startup-Autostart und keine fremde Session übernommen.

SQL Server 2022 oder höher kann die granularen Berechtigungen `CREATE ANY EVENT SESSION` und `DROP ANY EVENT SESSION` verwenden. `ALTER ANY EVENT SESSION` bleibt als kompatible Berechtigung zulässig. Fehlende Berechtigungen ergeben `SKIP_PERMISSION`.

## 4. Datenschutz und Output

Query Store und Extended Events können zur Laufzeit SQL-Texte, Literalwerte oder Fehlermeldungen enthalten. Das Framework:

- persistiert keine Exporte,
- erzeugt keine `.xel`-Dateien,
- gibt `ring_buffer`-XML nur auf ausdrückliche Anforderung interaktiv aus,
- behandelt jeden Export als neues, separat zu prüfendes Artefakt.

## 5. Cleanup

- Query Store wird über `RESTORE` in den erfassten Ausgangszustand zurückgeführt.
- Die Extended-Events-Session wird gestoppt und nach doppelter Bestätigung gelöscht.
- Ein Cleanup-Fehler ist `FAIL_CLEANUP`, nicht `SKIP`.
- Fremde Query-Store-Konfigurationen oder Event-Sessions werden nicht übernommen oder gelöscht.

## 6. Quellen

Die verwendete Syntax und Berechtigungslogik stützen sich auf die aktuellen Microsoft-Learn-Dokumente zu `ALTER DATABASE ... SET QUERY_STORE`, `CREATE EVENT SESSION`, `DROP EVENT SESSION` und Extended-Events-Targets. Die projektweite Zuordnung steht in `Documentation/Research/FRAMEWORK_SOURCES_W1.md`.

## 7. Abnahmekriterien

`FWK-007` ist `IMPLEMENTED`, wenn Query-Store-Baseline/Restore, bestätigtes Clear, deterministische XE-Namen, Ring-Buffer-Begrenzung, Berechtigungs-Skips und statische Tests vorhanden sind. Die tatsächliche Telemetrieerfassung auf SQL Server 2019, 2022 und 2025 bleibt Runtime-Folgearbeit.
