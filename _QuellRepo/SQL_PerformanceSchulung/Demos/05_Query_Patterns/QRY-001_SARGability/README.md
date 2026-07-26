# QRY-001 – SARGable und Non-SARGable Prädikate

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Sicherheitsstufe | `GREEN` |
| Primäre Zielversion | SQL Server 2025 |
| Unterstützte Versionen | SQL Server 2019, 2022 und 2025 |
| Compatibility Level | 150, 160 und 170 |
| Edition / Plattform | Database Engine; Windows oder Linux |
| Sessions | 1 |
| Laufzeitklasse | S |
| Testprofil | `TP-RUN` |

## 1. Lernziel

Nach Abschluss kann die lernende Person erklären, warum eine Funktion auf einer indizierten Prädikatspalte das Suchargument verdecken kann, und eine fachlich gleichwertige Bereichsbedingung formulieren und messen.

## 2. Fachliche Kernaussage

**Evidenzklasse:** `DOKUMENTIERT` und `EMPIRISCH`

Ein Prädikat ist nicht aufgrund seiner Schreibweise allein schnell oder langsam. Entscheidend ist, ob der Optimierer aus der Bedingung einen geeigneten Suchbereich für den vorhandenen Zugriffspfad ableiten kann. Die Demo hält Ergebnismenge und Datenbestand konstant und vergleicht Planform sowie statementbezogene Logical Reads.

## 3. Nichtziel

Die Demo behauptet nicht, dass jeder Seek günstiger als jeder Scan ist. Sie bewertet ausschließlich zwei äquivalente Prädikate bei selektiver Datumsbedingung und passendem, abdeckendem Index.

## 4. Voraussetzungen

### 4.1 Version und Konfiguration

SQL Server 2019 bis 2025; Compatibility Level entsprechend der Engine-Hauptversion. Es werden keine instanzweiten Optionen verändert.

### 4.2 Berechtigungen

Für den vollständigen automatisierten Lauf werden `CREATE DATABASE`, `SHOWPLAN` sowie `VIEW SERVER STATE` auf SQL Server 2019 beziehungsweise `VIEW SERVER PERFORMANCE STATE` ab SQL Server 2022 benötigt. `sysadmin` erfüllt diese Anforderungen im isolierten Schulungssystem.

### 4.3 Mindestanforderungen an die Host-Hardware

Mindestens 2 logische CPU-Kerne, 2 GB RAM und 300 MB freier Datenträgerspeicher. Es ist nur eine SQL-Server-Instanz erforderlich.

## 5. Sicherheits- und Abbruchrahmen

Die Demo ist grün. Sie erzeugt 300.000 synthetische Zeilen in einer eigenen markierten Testdatenbank. Das Harness-Zeitbudget beträgt 240 Sekunden. Abbruch und Recovery erfolgen über `FWK-010`; die Datenbank wird ausschließlich nach vollständiger Markerprüfung entfernt.

## 6. Synthetisches Datenmodell

`lab.SearchData` enthält einen ganzzahligen Schlüssel, einen `datetime2`-Wert, einen Messwert und eine kurze Nutzlast. Die Datumswerte werden deterministisch über eine modulare Abbildung verteilt. Der Index `IX_SearchData_EventDateTime` enthält `EventDateTime` als Schlüssel und `MeasureValue` als eingeschlossene Spalte.

## 7. Ablauf

| Phase | Datei | Zweck |
|---|---|---|
| Preflight | `00_Preflight.sql` | Version, Berechtigungen und kanonische Zielkennung prüfen |
| Setup | `10_Setup.sql` | Testdatenbank, Daten und Index anlegen |
| Baseline | `20_Baseline.sql` | SARGable Bereichsabfrage messen |
| Demonstration | `30_Demonstration.sql` | fachlich äquivalente Stringkonvertierung auf der Indexspalte messen |
| Observation | `40_Observation.sql` | Ergebnisequivalenz, Planform und Reads prüfen |
| Mitigation | `50_Mitigation.sql` | Bereichsprädikat als Gegenmaßnahme festhalten |
| Comparison | `60_Comparison.sql` | SARGable Variante erneut messen und relationale Erwartung prüfen |
| Cleanup | `90_Cleanup.sql` | markierte Testdatenbank entfernen |

## 8. Erwartete Beobachtung

Die Baseline und der Vergleich verwenden einen Index Seek. Die Non-SARGable Variante liefert dieselbe fachliche Ergebnissumme, liest jedoch mehr Seiten und verwendet in diesem kontrollierten Datenmodell einen Index Scan. Die Abnahme verwendet keine feste Laufzeitgrenze.

## 9. Interpretation

Die Funktion `CONVERT(char(10), EventDateTime, 120)` muss für Indexwerte ausgewertet werden und stellt dem Zugriffspfad keinen direkten Datumsbereich bereit. Die halboffene Bedingung `>= Start` und `< Folgetag` beschreibt denselben fachlichen Zeitraum als Suchbereich. Der beobachtete Unterschied gilt für dieses Datenmodell und diesen Index; er ist kein allgemeines Seek-versus-Scan-Werturteil.

## 10. Cleanup und Wiederherstellung

`90_Cleanup.sql` liest Projekt-, Vertrags-, Demo- und Run-Marker aus der Zieldatenbank. Nur bei vollständiger Übereinstimmung wird die Datenbank in `SINGLE_USER` versetzt und entfernt. Nach Abbruch führt `FWK-010` denselben Cleanup-Pfad aus.

## 11. Tests

Die statische Prüfung kontrolliert Manifest, Pflichtphasen, Marker und unerlaubte Hochrisikomuster. Die Runtime-Matrix führte die Demo im Lauf `30108023315` je Version zweimal aus und prüfte Ergebnisequivalenz, Seek/Scan-Evidenz, relationale statementbezogene Logical-Read-Erwartung und vollständiges Cleanup.

## 12. Bekannte Grenzen

Planentscheidungen hängen von Datenmenge, Selektivität, Indexbreite und Kostenmodell ab. Die Demo verwendet absichtlich eine selektive Bedingung und einen abdeckenden Index, damit die Ursache-Wirkungs-Beziehung stabil sichtbar wird.

## 13. Quellen

| Quellen-ID | Aussagebezug | Gültigkeitsbereich | Abrufdatum |
|---|---|---|---|
| `SRC-012` | Indexdesign und Suchprädikate | SQL Server 2019–2025 | 2026-07-24 |
| Microsoft Learn: Troubleshoot high CPU | Funktionen auf Prädikatspalten und SARGability | unterstützte SQL-Server-Versionen | 2026-07-24 |

## 14. Traceability

| Element | Zuordnung |
|---|---|
| Lernziel | `LO-M03-01` |
| Folie / Claim | `CLM-037`, Folie 37 |
| Demo-ID | `QRY-001` |
| Testprofil | `TP-RUN` |
