# OPT-013 – Kontrollierter Sort-Spill durch eingeschränkte Kardinalitätssicht

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Sicherheitsstufe | `YELLOW` |
| Primäre Zielversion | SQL Server 2025 |
| Unterstützte Versionen | SQL Server 2019, 2022 und 2025 |
| Compatibility Level | 150, 160 und 170 |
| Edition / Plattform | Database Engine; Windows oder Linux |
| Sessions | 1 |
| Laufzeitklasse | M |
| Testprofil | `TP-PERF` |

## 1. Lernziel

Nach Abschluss kann die lernende Person einen Sort-Spill als Runtime-Ereignis nachweisen, ihn mit einer eingeschränkten Kardinalitätssicht in Beziehung setzen und die Wirkung einer statistisch sichtbaren Materialisierung bei identischer Ergebnismenge prüfen.

## 2. Fachliche Kernaussage

**Evidenzklasse:** `DOKUMENTIERT` und `EMPIRISCH`

Sort- und Hashoperatoren verwenden Workspace Memory. Reicht der auf Basis der erwarteten Arbeitssatzgröße vergebene Grant nicht aus, können Arbeitssätze nach TempDB ausgelagert werden. `last_spills` in `sys.dm_exec_query_stats` beschreibt die zuletzt verschütteten Seiten eines beendeten Statements. Die Demo sortiert dieselben 300.000 breiten Zeilen zunächst aus einer Basistabelle, anschließend aus einer Table Variable mit querylokal deaktivierter Table Variable Deferred Compilation und zuletzt aus einer statistisch sichtbaren Staging-Tabelle.

## 3. Nichtziel

Die Demo definiert keinen universellen Memory-Grant-Schwellenwert und empfiehlt weder pauschale Grant-Hints noch eine globale Speichererhöhung. Sie behauptet nicht, dass Table Variables grundsätzlich ungeeignet sind; gezeigt wird ein absichtlich konservativer Kompilationspfad bei großer Datenmenge.

## 4. Voraussetzungen

SQL Server 2019 bis 2025, Compatibility Level 150 bis 170, `CREATE DATABASE` und versionsgerechte Server-State-Sichtbarkeit. Mindestanforderungen sind 2 logische CPU-Kerne, 3 GB RAM und 700 MB freier Datenträgerspeicher. Es ist nur eine Instanz erforderlich.

## 5. Sicherheits- und Abbruchrahmen

Die Demo ist gelb, weil 300.000 breite Zeilen mehrfach sortiert und ein kontrollierter TempDB-Spill erzeugt werden. Das Harness verlangt `--confirm-isolated-lab`; die maximale Laufzeit beträgt 360 Sekunden. Jede Workloadabfrage verwendet `MAXDOP 1`. Es werden keine globalen Caches geleert, keine Serveroptionen verändert und keine fremden Objekte bearbeitet. Timeout und Cleanup folgen `FWK-008` und `FWK-010`.

## 6. Synthetisches Datenmodell

`lab.SpillData` enthält 300.000 Zeilen mit deterministischem Sortierschlüssel und 200 Byte breiter Nutzlast. Die Baseline liest die relationale Basistabelle. Im Problemzustand werden dieselben Zeilen in eine Table Variable kopiert; der Statement-Hint `DISABLE_DEFERRED_COMPILATION_TV` deaktiviert ausschließlich für diese Abfrage die ab SQL Server 2019 verfügbare Deferred Compilation. Die Gegenmaßnahme materialisiert dieselben Zeilen in `lab.SpillStage` und erzeugt eine Fullscan-Statistik auf den Sortierspalten.

## 7. Ablauf

| Phase | Datei | Zweck |
|---|---|---|
| Preflight | `00_Preflight.sql` | Version, Rechte und gelbe Sicherheitsbestätigung prüfen |
| Setup | `10_Setup.sql` | Testdatenbank und 300.000 breite Zeilen anlegen |
| Baseline | `20_Baseline.sql` | Sort der Basistabelle mit sichtbarer Kardinalität und `last_spills = 0` messen |
| Demonstration | `30_Demonstration.sql` | dieselben Zeilen aus einer Table Variable ohne Deferred Compilation sortieren |
| Observation | `40_Observation.sql` | Ergebnisequivalenz, Grant, Planform und Spill gemeinsam prüfen |
| Mitigation | `50_Mitigation.sql` | statistisch sichtbare Staging-Tabelle materialisieren |
| Comparison | `60_Comparison.sql` | identischen Sort über die Staging-Tabelle ohne Spill prüfen |
| Cleanup | `90_Cleanup.sql` | markierte Testdatenbank entfernen |

## 8. Erwartete Beobachtung

Baseline, Problemzustand und Vergleich liefern denselben Checksum-Wert über 300.000 Zeilen und enthalten einen Sortoperator. Die Baseline besitzt `last_spills = 0`. Der Problemzustand besitzt einen kleineren Grant und `last_spills > 0`. Nach der Materialisierung in einer statistisch sichtbaren Staging-Tabelle besitzt der identische Sort wieder `last_spills = 0`.

## 9. Interpretation

Ein Spill ist Runtime-Evidenz für unzureichenden nutzbaren Workspace des konkreten Operators. Die Demo belegt zusätzlich eine kontrollierte Ursache für den Undergrant: Die tatsächliche Datenmenge bleibt unverändert, während die Problemabfrage absichtlich ohne Table Variable Deferred Compilation kompiliert wird. Die Beobachtung beweist nicht, dass jeder Spill durch Table Variables entsteht; geeignete Folgeanalysen müssen Schätzung, Operator, Grant, Parallelität, Datenbreite und konkurrierenden Speicherbedarf gemeinsam prüfen.

## 10. Cleanup und Wiederherstellung

Table Variable, Staging-Tabelle, Basistabelle und Evidenzobjekte sind vollständig synthetisch. Persistente Objekte liegen ausschließlich in der markierten Testdatenbank. `90_Cleanup.sql` entfernt die Datenbank nach vollständiger Markerprüfung. Ein Timeout führt über `FWK-010` in denselben Cleanup-Pfad.

## 11. Tests

Die Runtime-Matrix führte die Demo im Lauf `30108023315` je Version zweimal aus und prüfte identische Checksums, 300.000 tatsächliche Zeilen, Baseline mit Sort und Spill 0, Problemzustand mit kleinerem Grant und positivem `last_spills`, Vergleich über die Staging-Tabelle mit Spill 0 sowie vollständiges Cleanup. Es werden keine festen Laufzeit- oder TempDB-Größenverhältnisse verlangt.

## 12. Bekannte Grenzen

Die konkrete Spill-Seitenzahl hängt von verfügbarem Speicher, Engine-Build und internen Mindestgrants ab. Vertragsbestandteil ist nur die gemeinsam belegte Richtung `Basistabelle und 0 Spill → Table Variable mit deaktivierter Deferred Compilation und positiver Spill → Staging-Tabelle und 0 Spill`. Die Matrix verwendet offizielle Linux-Container; Windows- oder editionsspezifische Eigenschaften sind nicht Bestandteil dieser Demo.

## 13. Quellen

| Quellen-ID | Aussagebezug | Gültigkeitsbereich | Abrufdatum |
|---|---|---|---|
| `SRC-007` | Intelligent Query Processing und Table Variable Deferred Compilation | SQL Server 2019–2025; CL 150+ | 2026-07-24 |
| `SRC-008` | Detailgrenzen der Table Variable Deferred Compilation | versions- und CL-abhängig | 2026-07-24 |
| `SRC-029` | TempDB- und Spill-Evidenz | SQL Server 2019–2025 | 2026-07-24 |
| Microsoft Learn: `sys.dm_exec_query_stats` | Grant- und Spillzähler | SQL Server 2019–2025 | 2026-07-24 |

## 14. Traceability

| Element | Zuordnung |
|---|---|
| Lernziel | `LO-M02-05` |
| Folie / Claim | `CLM-030`, Folie 30 |
| Demo-ID | `OPT-013` |
| Testprofil | `TP-PERF` |
