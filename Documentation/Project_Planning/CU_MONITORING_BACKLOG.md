# CU Monitoring – Backlog

## Status

`ACTIVE`

Die automatische monatliche Überwachung neuer SQL-Server-Cumulative-Updates ist im Projekt umgesetzt und läuft über einen geplanten GitHub-Workflow. Der enge Ausbau
ergänzt genau katalogisiertes SqlPackage über den vorhandenen Resource-Watch-Core;
die echte Abnahme dieses Ausbaus steht separat aus.

Konfigurierter Monatsplan und tatsächlich erfolgreicher Lauf sind getrennte
Nachweise: Schedule-Lauf `33500598035` vom 2026-09-01 endete erfolgreich. Das
bestätigt keine heutige Quellenaktualität oder allgemeine Ressourcenüberwachung.

Die bisherige Einzel-CU-Reportprojektion verwendet den aktuellen `Sources`-/`LatestCatalog`-Vertrag
und veröffentlicht keine lokalen Katalogpfade oder rohen Diagnosefelder.
Synthetische Prüfungen sichern neue Builds, leere/unklare Ergebnisse und
ungeeignete Quellen vor Veröffentlichung ab. Ein neuer realer Watch-Lauf nach
dieser Änderung bleibt separat auszuführen.

## Konsolidierter Ressourcenauftrag

Die vorhandene CU-Lane ist Ausgangspunkt des Resource Watch aus dem
[konsolidierten Auftrag](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md), kein zweiter
Scheduler oder Backlog. Offen bleiben: Windows-/SQL-Neuversionen, KI-Runtimes,
Modellrevisionen, Samples und Tools; persistente lokale Quellenoverrides samt
Herkunft/Reset und Fachdialogen; getrennte Offline-/Timeout-/Rate-Limit-/Parser-
Diagnose; ressourcen- und
revisionsgebundene statt ausschließlich monatliche Issue-Deduplizierung für
weitere Ressourcenfamilien. CU plus SqlPackage verwenden jetzt eine gemeinsame
bereinigte Projektion mit monatsunabhängigen Ressourcen-/Revisionsmarkern;
Dispatch-, Issue- und Cronabnahme dieses Ausbaus bleiben getrennt offen.
Lokale deterministische Prüfung funktioniert ohne KI, recherchierende KI bleibt
optional. Ein Issue startet keinen Agenten. Neue Releases erteilen keine
Installations- oder Supportfreigabe.

Der CU-Prüfadapter erzeugt bei einer Exception des Quellen-/Katalogchecks oder
der Berichtserstellung einen bereinigten `UNCLEAR`-Bericht mit getrenntem
Fehlercode. Der ressourcen-/revisionsgebundene Issuepfad wird anschließend
versucht; danach bleibt der Workflow rot. Auch ein reguläres `UNCLEAR` ergibt
keinen erfolgreichen Prüflauf. Checkout-/Runner-/Timeoutausfälle vor oder
außerhalb dieses Adapters sowie fehlende GitHub-Issueberechtigungen können damit
keinen Issuehinweis garantieren; GitHub-Fehlerstatus bleibt sichtbar. Eine reale
End-to-End-Abnahme dieses Fehlerpfads ist noch offen.

## Implementierung

Aktiv: `.github/workflows/sql-cu-monthly-monitor.yml` führt
`Tools/Invoke-VersionCatalogResourceWatch.ps1` gemäß `ops/sql-cu-policy.md`
aus. Cron und Concurrency bleiben erhalten; der Prompt ist ein optionaler
manueller CU-Recherchepfad, kein Agentstart durch Issues.
Vertrag und begrenzte eigene Abnahme:
[Resource-Watch-Automation](../Architecture/RESOURCE_WATCH_AUTOMATION.md).

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
