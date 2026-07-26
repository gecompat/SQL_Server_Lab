# Execution-Plan-Analyse – Installations- und Paketvertrag

## Zweck

PLAN-001 kann unabhängig vom vollständigen SQL Server Analyze Framework installiert werden. Der Teilinstaller stellt ausschließlich den Plananalysekern und seine zwingenden Abhängigkeiten bereit. Er installiert keine Current-State-, Query-Store-, Extended-Events-, Infrastruktur-, Server-Health- oder Navigator-Komponenten.

## Installationswege

| Weg | Datei | SQLCMD erforderlich |
|---|---|---:|
| Include-Installer | `Code/Install/Install_ExecutionPlanAnalysis.sql` | ja |
| eingebetteter Einzelinstaller | `Code/Install/generated/Install_ExecutionPlanAnalysis.generated.sql` aus `Build-ExecutionPlanAnalysisInstaller.ps1` | nein |
| vollständiges Framework | `Code/Install/Install_All.sql` oder dessen eingebettete Ausgabe | abhängig vom gewählten Weg |

Vor jedem Weg ist `[DeineDatenbank]` durch die gewählte Frameworkdatenbank zu ersetzen. Der Installer erstellt die Datenbank nicht.

## Öffentliche Objekte

Nach erfolgreicher Teilinstallation sind mindestens vorhanden:

- `[monitor].[USP_ExecutionPlanAnalysis]`
- `[monitor].[USP_CreateExecutionEvidenceJson]`

Beide besitzen im Teil- und Gesamtpaket identische Signaturen, Resultsets, JSON- und TABLE-Verträge.

## Zwingende Abhängigkeiten

Der Teilinstaller enthält:

- Preflight und Schema `[monitor]`;
- gemeinsame Status-, Analyseklassen- und Capability-Metadaten, soweit vom Kern benötigt;
- gemeinsame Parser-, Text-, XML-, TABLE- und CONSOLE-Helfer;
- Plananalyseprofile, Schwellenwerte und Zuordnungen;
- `STATISTICS IO`-/`STATISTICS TIME`-Parser;
- Objekt-, Statistik- und Spaltenreferenz-TVFs;
- interne Planmetadatensammlung und Analysekern;
- beide öffentlichen PLAN-001-Procedures.

Die exakte Abhängigkeitsschließung steht in `Metadata/Inventory/ExecutionPlanAnalysisDependencies.csv`. Kein Objekt darf auf einen nicht mitinstallierten Frameworkbestandteil verweisen.

## Bewusste Nichtabhängigkeiten

Der Standalone-Kern benötigt nicht:

- `USP_QueryStats`, `USP_ShowplanAnalysis` oder `USP_PlanCacheAnalysis`;
- Query-Store-Analyseprocedures;
- Current-State-Procedures;
- Extended-Events-Procedures;
- Infrastruktur- oder Server-Health-Orchestratoren;
- `USP_AnalysisNavigator` und dessen drei Katalogviews;
- das Snapshot-/Baseline-Paket.

Die direkte Auflösung eines einzelnen Query-Store-Plans ist Teil des öffentlichen Plananalyse-Einstiegs. Sie ist ein begrenzter Quellenadapter und keine Abhängigkeit von `USP_QueryStoreAnalysis`.

## Installationsreihenfolge

1. Prüfen Sie Preflight, Version und Collation.
2. Schema und gemeinsame statische Kataloge bereitstellen.
3. Parser, TVFs und interne Ausgabehelper bereitstellen.
4. Profiltabellen und deren sichere Defaultwerte bereitstellen.
5. interne Plananalyseobjekte bereitstellen.
6. öffentliche Procedures zuletzt bereitstellen.
7. Führen Sie die Hilfe- und Smoke-Aufrufe aus.

Die Reihenfolge verhindert, dass eine Procedure während der Installation auf ein noch nicht vorhandenes Objekt verweist.

## Wiederholbarkeit

Die SQL-Objekte verwenden idempotente Anlage- beziehungsweise Aktualisierungsmuster. Ein erneuter Lauf darf bestehende Benutzerprofile und bewusste Profilzuordnungen nicht unkontrolliert verwerfen. Statische Defaultwerte werden nach ihrem dokumentierten Schlüssel gepflegt.

Eine Teilinstallation über einen bereits vollständigen Frameworkstand und eine spätere vollständige Installation über einen Teilstand müssen denselben öffentlichen PLAN-001-Vertrag ergeben.

## Datenbank- und Plattformgrenze

- SQL Server 2019 oder neuer;
- freigegebene Server-, `tempdb`- und Installationsdatenbank-Collation gemäß [Installationsanleitung](../Reference/Installation.md);
- DDL-Rechte für die Installation;
- Laufzeitrechte abhängig von Planquelle und optionalem Metadatenpfad.

Der Installer vergibt keine Benutzer- oder Serverrechte. Query-Store- oder fremde Datenbankrechte werden nicht vorausgesetzt, wenn ausschließlich ein direkt übergebenes Plan-XML ohne Metadatenauflösung untersucht wird.

## Planquellen nach Teilinstallation

| Quelle | Mindestvoraussetzung |
|---|---|
| `@PlanXml` | gültiges Showplan-XML |
| `@PlanHandle` | sichtbarer aktueller Cacheeintrag und entsprechende Server-State-Sicht |
| Query Store | bekannte Datenbank und Query-/Planidentität, Query Store lesbar und Plan noch vorhanden |
| externe Evidence | gültiger versionierter JSON-Envelope |
| Objekt-/Statistikauflösung | expliziter Scope und lesbare Zielkataloge |
| Histogramme | explizite Freigabe, enge Grenzen und ausreichende Rechte |

Nicht verfügbare optionale Quellen führen zu strukturiertem Status oder partieller Evidenz, nicht zur stillen Auswahl einer anderen Quelle.

## Profiltabellen

`PlanAnalysisProfile`, `PlanAnalysisRuleThreshold` und `PlanAnalysisProfileAssignment` sind Teil des Kerns. Sie speichern nur typisierte Konfiguration:

- keine freien SQL-Fragmente;
- keine ausführbaren Ausdrücke;
- keine Zugangsdaten oder Secrets;
- keine Plan-, Query- oder Benutzerdaten;
- keine Abhängigkeit von einem externen Regeldienst.

Direkte DML ist kein normaler Betriebsweg. Änderungen müssen die dokumentierten Schlüssel, Datentypen, Grenzen und Rollbackanforderungen einhalten.

## Prüfung nach Installation

```sql
EXEC [monitor].[USP_ExecutionPlanAnalysis] @Hilfe = 1;
EXEC [monitor].[USP_CreateExecutionEvidenceJson] @Hilfe = 1;
```

Zusätzlich müssen Schema, Profiltabellen, TVFs und interne Procedures gemäß dem Abhängigkeitsinventar vorhanden sein. Ein Hilfeaufruf führt keine Plananalyse aus.

Ein fachlicher Test verwendet ausschließlich ein bewusst ausgewähltes synthetisches oder freigegebenes Plan-XML und zunächst kleine Grenzen. Die Prüfung muss mindestens Status, statements, operators, findings sowie JSON- oder TABLE-Vertrag abdecken.

## Upgrade und Koexistenz

- PLAN-001-Objekte werden unter denselben Namen wie im Gesamtframework geführt.
- Der vollständige Installer darf den Teilstand aktualisieren, ohne eine zweite parallele Objektgruppe anzulegen.
- Der Teilinstaller verändert keine Frameworkobjekte außerhalb seines definierten Abhängigkeitsumfangs.
- Resultset-Schemaversionen bleiben Bestandteil des öffentlichen Vertrags.
- Nicht mehr unterstützte Tabellen- oder Spaltenstände benötigen einen expliziten Migrationspfad; stille Datenverluste sind ausgeschlossen.

## Datenschutz

Installationsskripte enthalten keine Laufzeitpläne oder Evidence. Die späteren Analyseausgaben können jedoch SQL-Text, Namen, Parameterdarstellungen, Plan-XML und Histogrammwerte enthalten. Siehe [Datenschutz und Laufzeitausgaben](Runtime_Data_Privacy.md).

## Abgrenzung zum Analysis Navigator

Der Navigator gehört bewusst nicht zum Teilpaket. Eine eigenständige Plananalyse bleibt dadurch klein und unabhängig. Im vollständigen Framework kann der Navigator `USP_ExecutionPlanAnalysis` über Suchbegriffe wie `Plan XML analysieren` finden; die Plananalyse selbst liest den Navigator-Katalog nicht.

## Weiterführende Dokumentation

- [Plananalyse – Architektur und Laufzeitvertrag](Execution_Plan_Analysis_Design.md)
- [Vollständige Installation](../Reference/Installation.md)
- [Procedure-Seite `USP_ExecutionPlanAnalysis`](../Analysis_Guides/Procedures/USP_ExecutionPlanAnalysis.md)
- [Procedure-Seite `USP_CreateExecutionEvidenceJson`](../Analysis_Guides/Procedures/USP_CreateExecutionEvidenceJson.md)
- [Objektreferenz](../Reference/Object_Reference.md)
