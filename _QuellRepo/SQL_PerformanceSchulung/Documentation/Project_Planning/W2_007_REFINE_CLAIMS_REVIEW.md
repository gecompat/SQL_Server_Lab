# W2-007 – Review der vier präzisierten Claims

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W2-007` |
| Status | `VALIDATED` |
| Prüfdatum | 2026-07-24 |
| Aktiver Foliensatz | `Presentations/Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx` |
| SHA-256 | `3ad528c2eb6ad531c1bbf5a26bee17e35004f764357b5061c9fc15bc04807a18` |
| Folienumfang | 84 |
| Betroffene Claims | `CLM-032`, `CLM-034`, `CLM-042`, `CLM-043` |

## 1. Ziel und Abgrenzung

`W2-007` schließt die vier in der kritischen Aussagenprüfung verbliebenen `REFINE`-Entscheidungen. Geändert wurden ausschließlich sichtbarer Text, Tabelleninhalte und Speaker Notes der Folien 32, 34, 42 und 43 sowie die dazugehörigen Steuerungsdokumente. Layoutsystem, Folienreihenfolge, Brandingstatus und die übrigen 80 Claims bleiben unverändert.

Die Abnahme bestätigt fachliche Präzision und Präsentationskonsistenz. Sie ersetzt keine noch nicht implementierte Runtime-Demo für `OPT-007`, `QRY-008` oder `QRY-009`. Die Notes der Folie 42 dürfen auf die bereits validierte `OPT-013`-Evidenz verweisen, ohne daraus eine allgemeine Produktgarantie abzuleiten.

## 2. Abgeschlossene Präzisierungen

| Folie / Claim | früheres Risiko | umgesetzte Aussage | fachlicher Nachweis |
|---|---|---|---|
| 32 / `CLM-032` | Cache-Key-Abweichung wurde mit Invalidierung vermischt | Abweichende SET-Optionen können zusätzliche Cacheeinträge erzeugen; Eviction, Invalidierung und Recompile werden getrennt diagnostiziert | Query Processing Architecture Guide; Query-Store-Dokumentation |
| 34 / `CLM-034` | MGF-Persistenz/Perzentilmodus wurde zu eng an CL 160 gebunden | SQL Server 2022+, CL 140 und Query Store `READ_WRITE`; PSP, CE-/DOP-Feedback bleiben CL-160-Funktionen; OPPO ist auf SQL Server 2025/CL 170 begrenzt | IQP-, MGF- und OPPO-Dokumentation |
| 42 / `CLM-042` | „klein und planstabil“ konnte als feste Produktgrenze gelesen werden | TVDC nutzt bei CL 150 die erste Zeilenzahl, erzeugt aber keine Spaltenhistogramme; Planwiederverwendung und Verteilung bleiben relevant; keine feste Zeilengrenze | IQP- und Table-Variable-Dokumentation; validierte `OPT-013`-Laborevidenz |
| 43 / `CLM-043` | MSTVFs wurden ohne moderne Ausnahme als dauerhaft fest geschätzt beschrieben | Interleaved Execution kann geeignete MSTVFs ab CL 140 mit der ersten Ist-Kardinalität optimieren; Scalar UDF Inlining bleibt ab CL 150 eligibility- und planabhängig | IQP-Details, UDF- und Scalar-UDF-Inlining-Dokumentation |

## 3. Speaker Notes und Quellen

Jede betroffene Folie besitzt Notes mit folgenden Rollen: Einordnung der dokumentierten Produkteigenschaft, Diagnosegrenze, Versions- und Konfigurationsvoraussetzung, Quellen-URLs und Claim-Traceability. Die Notes vermeiden allgemeine Performanceversprechen und trennen dokumentierte Funktion, querybezogene Eligibility und empirische Laborbeobachtung.

Verwendete Primärquellen:

- Microsoft Learn: Query Processing Architecture Guide
- Microsoft Learn: Monitoring Performance by Using the Query Store
- Microsoft Learn: Intelligent Query Processing
- Microsoft Learn: Memory Grant Feedback
- Microsoft Learn: Optional Parameter Plan Optimization
- Microsoft Learn: Table data type
- Microsoft Learn: Intelligent Query Processing Details
- Microsoft Learn: Create user-defined functions
- Microsoft Learn: Scalar UDF Inlining

Die stabilen Quellen-IDs im Repository bleiben `SRC-001`, `SRC-007`, `SRC-008`, `SRC-009`, `SRC-026` und `SRC-027`.

## 4. Technische Validierung

Die PPTX-Datei wurde als Office-Open-XML-Paket geprüft. Das Archiv ist fehlerfrei lesbar, enthält 84 Slides und keine VBA-Projektdatei. Die vier Ziel-Slides sowie die zugehörigen Notes enthalten die erwarteten präzisierten Textfragmente; die abgelösten Pauschalformulierungen sind nicht mehr vorhanden.

Die Präsentation wurde mit LibreOffice erfolgreich nach PDF konvertiert. Die Folien 32, 34, 42 und 43 wurden im Render visuell auf Überlauf, abgeschnittene Texte, Tabellenbreite, Zeilenumbruch und Konsistenz mit dem bestehenden Designsystem geprüft. Für PowerPoint unter Windows wurde in dieser Laufzeit kein separater Render erzeugt; Struktur und Standard-OOXML bleiben unverändert.

## 5. Datenschutz und Branding

Die Änderung fügt keine Bilder, Medien, eingebetteten Dateien oder externen Datenverbindungen hinzu. Neu enthalten sind ausschließlich fachliche Texte und öffentliche Microsoft-Learn-Quellen. Es wurden keine Firmen-, Host-, Datenbank-, Kontakt- oder Benutzerdaten ergänzt. Die einzige weiterhin zulässige reale Namensangabe des Projekts bleibt `Gerhard Pisch`; sie wird durch `W2-007` nicht neu verwendet.

## 6. Ergebnis

Die Claims `CLM-032`, `CLM-034`, `CLM-042` und `CLM-043` wechseln von `REFINE` zu `KEEP`. Damit besitzt der aktive Foliensatz 84 `KEEP`-Entscheidungen und keine offenen `REFINE`-, `REPLACE`- oder `REMOVE`-Entscheidungen. Der nächste Inhaltsarbeitsschritt ist nicht mehr die Claim-Korrektur, sondern die weitere Welle-2-Umsetzung mit Beispielklassifikation, Teilnehmerunterlagen und konkreten Query-Store-/Extended-Events-Diagnosepfaden.
