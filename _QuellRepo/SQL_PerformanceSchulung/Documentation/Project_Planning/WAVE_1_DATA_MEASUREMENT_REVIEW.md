# Review – Welle-1-Daten-, Mess- und Ergebnisbasis

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Stand | 2026-07-24 |
| Basis-Commit | `1a4156678f06e76f7f19a402cdd4594f5bbf0fd8` |
| Arbeitspakete | `FWK-003`, `FWK-004`, `FWK-005`, `FWK-011` |
| Runtime-Validierung | offen; derzeit steht kein SQL-Server-Host zur Verfügung |

## 1. Umfang

Diese Stufe ergänzt die vorhandene Sicherheits- und Lifecycle-Basis um:

- deterministische synthetische Datenprofile,
- sessionbezogene Baseline-, Demonstrations- und Vergleichsmessungen,
- Statistikproperties, Histogramm und interaktive Actual-Plan-Evidenz,
- maschinenunabhängige Ergebnisassertionen mit strukturierten Outcomes.

## 2. Implementierte Artefakte

| Paket | Referenzimplementierung | Technische Grenze |
|---|---|---|
| `FWK-003` | `Demos/00_Framework/Sql/FWK_SyntheticDataGenerator.sql` | ausschließlich vollständig markierte Testdatenbank; maximal 10 Millionen Zeilen |
| `FWK-004` | `Demos/00_Framework/Sql/FWK_Measurement.sql` | Start und Ende in derselben Session; Wait-Erfassung optional |
| `FWK-005` | `Demos/00_Framework/Templates/40_Plan_Statistics_Evidence.sql` | interaktive Ausgabe; keine automatische Planpersistenz |
| `FWK-011` | `Demos/00_Framework/Tools/evaluate_result_contract.py` | ausschließlich synthetische oder aggregierte JSON-Evidenz |

## 3. Sicherheits- und Datenschutzprüfung

Die SQL-Referenzen prüfen vor Änderungen die Marker aus `FWK-002`. Es werden keine Server-, Host-, Login-, Programm- oder Dateipfadwerte persistiert. Der Generator verwendet keine realen Daten, keine öffentlichen Beispieldatenbanken und keine nicht deterministischen Zufallsquellen. Plan-XML wird nur interaktiv ausgegeben; ein Export bleibt ein gesondert zu prüfendes Artefakt.

Die Repository-Artefakte enthalten ausschließlich synthetische Kennungen und Werte. Es wurden keine Screenshots, Office-Dateien, Logs oder realen Diagnoseausgaben ergänzt.

## 4. Statische Tests

Der Framework-Linter prüft nun:

- 20 verpflichtende Framework-Dateien,
- 19 Statuscodes,
- fünf Eigentumsmarker,
- lexikalisch ausgeglichene T-SQL-Dateien,
- fehlende Hochrisikomuster,
- deterministische Generatorregeln,
- Python-Syntax und JSON-Metadaten,
- konsistente `FWK-011`-Beispiele.

Der `FWK-011`-Selbsttest umfasst einen erfolgreichen und einen absichtlich fehlschlagenden Ergebnisvertrag sowie die Ablehnung nicht endlicher Werte und einer Nullbasis für Verhältnisassertionen.

## 5. Nicht ausgeführte Prüfungen

Mangels verfügbarem SQL-Server-Host wurden nicht ausgeführt:

- Parse und Installation auf SQL Server 2019, 2022 und 2025,
- zwei identische Generatorläufe mit Vergleich der fachlichen Werte,
- Messungsstart und -ende einschließlich Wait-Deltas,
- Histogramm- und Actual-Plan-Ausgabe,
- vollständiger Lifecycle mit Setup und Cleanup.

Daher lautet der Status `IMPLEMENTED`, nicht `VALIDATED`.

## 6. Nächster Workstream

Als nächste abhängige Stufe folgen:

1. `FWK-006` Multi-Session-Orchestrierung,
2. `FWK-007` Query-Store- und Extended-Events-Helfer,
3. `FWK-010` vollständiger Runtime-Harness,
4. anschließend SQL-Server-Matrix und vier Gate-B-Pilotdemos.

Gate B ist mit diesem Stand noch nicht erreicht.
