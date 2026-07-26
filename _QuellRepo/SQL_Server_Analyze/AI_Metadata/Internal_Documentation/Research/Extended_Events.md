# Recherche Phase 5 – Extended Events

Primärquellen: Microsoft Learn, Stand 2026-07-14.

## Dokumentierte Kernaussagen

- `system_health` wird standardmäßig mit SQL Server installiert und automatisch gestartet. Die Session soll nicht als Voraussetzung des Frameworks verändert, gestoppt oder gelöscht werden.
- `system_health` enthält unter anderem `xml_deadlock_report` und besitzt typischerweise `ring_buffer`- und `event_file`-Targets.
- `sys.fn_xe_file_target_read_file` liest vorhandene XEL-Dateien und liefert Eventname, UTC-Zeitstempel, Datei, Offset und XML-Eventdaten.
- `sys.dm_xe_session_targets` liefert Laufzeit-Targetdaten. Das Abfragen dieser DMV kann gesammelte Sessiondaten in das Target flushen und wird deshalb nur nach expliziter Bestätigung verwendet.
- Katalogviews unter `sys.server_event_session_*` beschreiben vorhandene Sessiondefinitionen, ohne Targetdaten zu lesen.
- `blocked_process_report` steht nur zur Verfügung, wenn eine entsprechende XE-Session existiert und der Serverwert `blocked process threshold (s)` größer als 0 konfiguriert ist. Phase 5 liest diesen Zustand nur.
- SQL Server 2019 verwendet für die serverweiten XE-Katalog-/DMV-Zugriffe regelmäßig `VIEW SERVER STATE`; ab SQL Server 2022 gilt für viele Performanceobjekte `VIEW SERVER PERFORMANCE STATE`.

## Architekturfolgen

1. Extended Events bleiben eine optionale Zusatzquelle. Standardpfade des Frameworks basieren weiterhin auf Current-State-DMVs, Plan Cache und Query Store.
2. Das leichte Sessioninventar liest ausschließlich Katalogviews und optional `sys.dm_xe_sessions`; keine Targetdaten.
3. Eventfile-, Ringbuffer-, Targetruntime-, Deadlock- und Blocked-Process-Auswertungen prüfen `EXTENDED_EVENTS_FORENSICS_DEEP`.
4. Ein Ringbuffer- oder Targetruntime-Zugriff verlangt `@BestaetigeTargetFlush = 1`.
5. Kein Objekt erstellt, startet, stoppt, ändert oder löscht eine XE-Session.
6. Fehler, fehlende Rechte, nicht vorhandene Sessions, Targets oder Dateien erzeugen strukturierte Teilstatus statt eines Frameworkabbruchs.

## Quellen

- https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session
- https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-xe-file-target-read-file-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-xe-session-targets-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events-system-catalog-views
- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-deadlocks-guide
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/blocked-process-threshold-server-configuration-option
