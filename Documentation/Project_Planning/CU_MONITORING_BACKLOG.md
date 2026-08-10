# CU Monitoring – Backlog

## Status

`ACTIVE`

Die automatische monatliche Überwachung neuer SQL-Server-Cumulative-Updates ist im Projekt umgesetzt und läuft über einen geplanten GitHub-Workflow.

## Implementierung

Aktiv: `.github/workflows/sql-cu-monthly-monitor.yml` führt `.github/prompts/sql-cu-monthly-monitor.prompt.md`/`ops/sql-cu-policy.md` zugrunde liegende Logik automatisiert aus.

## Erhaltener fachlicher Ansatz

Ein späterer Umsetzungsschritt kann folgende Punkte erneut bewerten:

- monatlicher geplanter Lauf sowie manueller Dry-Run (Workflow manuell über `workflow_dispatch` auslösbar).
- SQL Server 2019, 2022 und 2025;
- Microsoft Learn als autoritative Build-/CU-Quelle;
- optionale zweite Quelle nur als Frühindikator;
- explizite Kennzeichnung nicht bestätigter Abweichungen;
- Erstellung eines GitHub-Issues bei bestätigten neuen Builds;
- persistierter, nachvollziehbarer Monitoring-State;
- keine externen Python-Abhängigkeiten, sofern dies weiterhin sinnvoll ist.

## Wiederaufnahme

Die Umsetzung erfolgt aktuell auf dem bestehenden `main`. Bei Anpassungen sind Quellen, Katalogmodell, Workflow-Berechtigungen, Schreibzugriffe und Fehlerverhalten weiterhin bei jeder Änderung erneut zu prüfen.

Historischer Kontext: Der frühere Draft-PR `#2` wurde bewusst geschlossen, weil er gegenüber dem aktuellen Runtime-Stand stark divergiert war und nicht zum unmittelbaren Umgebungsbereitstellungsvertrag für `SQL_Server_Analyze` und `SQL_PerformanceSchulung` gehört.

Die Backlog-Notiz bewahrt nur die fachliche Absicht. Sie übernimmt weder den alten Workflow noch den alten Python-Code als aktuellen Implementierungsstand. Der spätere Neustart erfolgt als eigener, kleiner Änderungssatz vom aktuellen `main`.
