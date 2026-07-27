# CU Monitoring – Backlog

## Status

`DEFERRED`

Die automatische monatliche Überwachung neuer SQL-Server-Cumulative-Updates ist nicht Bestandteil des aktuell freigegebenen Container-Core und wird nicht mit der Umstellung der Schwester-Repositories auf `SQL_Server_Lab` gekoppelt.

## Erhaltener fachlicher Ansatz

Ein späterer Umsetzungsschritt kann folgende Punkte erneut bewerten:

- monatlicher geplanter Lauf sowie manueller Dry-Run;
- SQL Server 2019, 2022 und 2025;
- Microsoft Learn als autoritative Build-/CU-Quelle;
- optionale zweite Quelle nur als Frühindikator;
- explizite Kennzeichnung nicht bestätigter Abweichungen;
- Erstellung eines GitHub-Issues bei bestätigten neuen Builds;
- persistierter, nachvollziehbarer Monitoring-State;
- keine externen Python-Abhängigkeiten, sofern dies weiterhin sinnvoll ist.

## Wiederaufnahme

Die Umsetzung soll später neu vom dann aktuellen `main` aus erfolgen. Vor einer Übernahme sind Quellen, Katalogmodell, Workflow-Berechtigungen, Schreibzugriffe und Fehlerverhalten erneut zu prüfen.

Historischer Kontext: Der frühere Draft-PR `#2` wurde bewusst geschlossen, weil er gegenüber dem aktuellen Runtime-Stand stark divergiert war und nicht zum unmittelbaren Umgebungsbereitstellungsvertrag für `SQL_Server_Analyze` und `SQL_PerformanceSchulung` gehört.

Die Backlog-Notiz bewahrt nur die fachliche Absicht. Sie übernimmt weder den alten Workflow noch den alten Python-Code als aktuellen Implementierungsstand.
