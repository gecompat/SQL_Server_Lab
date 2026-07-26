# Welle 1 – Review der Framework-Sicherheits- und Vertragsbasis

| Merkmal | Wert |
|---|---|
| Arbeitspakete | `FWK-001`, `FWK-002`, `FWK-008`, `FWK-009`, `FWK-012` |
| Status | `IMPLEMENTED` |
| Prüfdatum | 2026-07-24 |
| Runtime-Status | `NOT_RUN` |
| Nächster Workstream | `FWK-003` bis `FWK-007`, `FWK-010`, `FWK-011` |

## 1. Ziel

Das Paket legt vor Datengenerator, Messrahmen, Multi-Session-Orchestrierung und Pilotdemos die verbindlichen Sicherheits- und Zustandsverträge fest. Dadurch entstehen keine späteren Helfer auf ungesicherten Annahmen über Ziel-Datenbank, Berechtigungen, Hochlastfreigabe, Fehlerbehandlung oder Cleanup.

## 2. Implementierte Artefakte

| Arbeitspaket | Ergebnis | Abnahmeevidenz |
|---|---|---|
| `FWK-001` | read-only Preflight mit Engine-, Datenbank-, Berechtigungs-, Sicherheits- und optionaler Ressourcenprüfung | Preflight-Vertrag und `Templates/00_Preflight.sql` |
| `FWK-002` | deterministisches Namensschema, Extended-Property-Marker sowie markergeprüfte Aktionen `CREATE`, `VALIDATE`, `DROP` | Lifecycle-Vertrag und `Sql/FWK_TestDatabaseLifecycle.sql` |
| `FWK-008` | technisch erzwungene Bestätigungen und Abbruchanforderungen für `GREEN`, `YELLOW`, `RED` | Sicherheitsvertrag und Preflight-Safety-Gate |
| `FWK-009` | vollständige README-Vorlage mit Lernziel, Evidenz, Hardwareminimum, Ablauf, Tests und Traceability | `Templates/README_TEMPLATE.md` |
| `FWK-012` | einheitliche Outcomes, Codes, Resultsetschema und Fehlernummern | Statusvertrag, Preflight und Lifecycle |

## 3. Wesentliche Designentscheidungen

### 3.1 Keine dauerhaft installierte Steuerdatenbank

Die Framework-Basis besteht aus kopierbaren Vorlagen und einem eigenständigen Lifecycle-Batch. Dies hält fachliche Demos lesbar, verhindert versteckte Abhängigkeiten und vermeidet dauerhafte Objekte in `master`.

### 3.2 Datenbankname und Eigentum werden getrennt geprüft

Das Namensschema reduziert Verwechslungen, ersetzt aber keine Eigentumsprüfung. Vor `DROP` müssen Projekt, Vertragsversion, Demo-ID und Run-Token als Datenbank-Extended-Properties übereinstimmen. Eine unmarkierte oder nicht lesbare Datenbank bleibt unangetastet.

### 3.3 `SKIP` ist kein Fehler

Nicht unterstützte Versionen, fehlende optionale Berechtigungen oder nicht verfügbare Ressourcenprofile erzeugen kontrollierte `SKIP`-Codes. Sicherheits-, Zustands-, Ausführungs- und Cleanup-Fehler bleiben `FAIL` und führen nach Ausgabe der Evidenz zu `THROW`.

### 3.4 Safety-Gates sind explizit

Eine Produktions- oder Laborumgebung kann nicht zuverlässig aus Namen oder Edition abgeleitet werden. Gelbe und rote Demos erfordern deshalb ausdrückliche, im Preflight geprüfte Bestätigungen.

## 4. Statische Validierung

Der Python-Linter verwendet ausschließlich die Standardbibliothek und prüft:

- Vorhandensein aller Vertrags- und Referenzdateien,
- definierte Outcome- und Fehlercodes,
- Marker- und Bestätigungslogik des Lifecycle-Skripts,
- Vollständigkeit der README-Vorlage,
- Ausschluss unzulässiger Hochrisikomuster außerhalb des eng begrenzten Lifecycle-Pfads.

Der Workflow ist auf betroffene Pfade begrenzt. Dokumentationsänderungen außerhalb des Frameworks starten diesen Check nicht.

## 5. Nicht ausgeführte Prüfungen

Eine SQL-Runtime-Validierung wurde in diesem Paket nicht durchgeführt. In der verfügbaren Bearbeitungslaufzeit besteht keine SQL-Server-Verbindung. Die statische Prüfung ersetzt deshalb weder Parse-/Deploy-Tests noch die spätere Matrix SQL Server 2019/2022/2025.

Die SQL-Skripte bleiben bis zur ersten erfolgreichen Runtime-Matrix `IMPLEMENTED`, nicht `VALIDATED`.

## 6. Offene Folgearbeiten

1. `FWK-003` deterministischer synthetischer Datengenerator.
2. `FWK-004` Messrahmen und Delta-Scope.
3. `FWK-005` Plan- und Statistik-Evidenz.
4. `FWK-006` Multi-Session-Orchestrierung.
5. `FWK-007` Query-Store- und Extended-Events-Helfer.
6. `FWK-010` Test-Harness einschließlich Summary-Auswertung.
7. `FWK-011` Ergebnisnormalisierung und hardwareunabhängige Erwartungsverträge.
8. Runtime-Validierung der Framework-Basis auf SQL Server 2019, 2022 und 2025.

## 7. Ergebnis

Die Sicherheits- und Vertragsbasis ist implementiert und statisch prüfbar. `CFL-007` aus dem Konfliktlog ist damit aufgelöst. Gate B ist noch nicht erreicht, weil Mess-, Daten-, Orchestrierungs- und Runtime-Harness sowie die vier Pilotdemos fehlen.
