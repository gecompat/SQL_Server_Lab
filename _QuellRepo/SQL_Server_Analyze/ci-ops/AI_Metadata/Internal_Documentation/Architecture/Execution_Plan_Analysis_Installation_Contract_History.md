# Execution-Plan-Analyse – Teilinstaller- und Integrationsvertrag

**Stand:** 2026-07-21
**Status:** `IMPLEMENTED_ACTIONS_GATE`
**Zugehörige Architektur:** [`Execution_Plan_Analysis_Design.md`](Execution_Plan_Analysis_Design.md)

> Dieser Vertrag beschreibt den implementierten Teilinstaller und seine Integration in das Gesamtframework. Die exakte Abhängigkeitsschließung steht in [`ExecutionPlanAnalysisDependencies.csv`](../../Metadata/Inventory/ExecutionPlanAnalysisDependencies.csv); der eingefrorene öffentliche V1-Vertrag steht in [`ExecutionPlanAnalysis_Public_Contract.json`](../../Metadata/Quality/ExecutionPlanAnalysis_Public_Contract.json). Beide werden automatisiert gegen Installer, SQL-Quellen und Inventare geprüft.

## 1. Ziel

Die Implementierung besitzt einen eigenständigen Installer:

```text
Code/Install/Install_ExecutionPlanAnalysis.sql
```

Der Teilinstaller installiert ausschließlich:

- die eigenständige Execution-Plan-Analyse;
- den Evidenz-JSON-Erzeuger;
- die XML- und Meldungsparser;
- die Metadaten- und Regelobjekte dieses Analysebereichs;
- die tatsächlich benötigten gemeinsamen Frameworkobjekte aus der transitiven Abhängigkeitsschließung.

Er installiert nicht das vollständige Monitoringframework.

Der Gesamtinstaller:

```text
Code/Install/Install_All.sql
```

installiert dieselben Objekte in derselben Reihenfolge und anschließend die übrigen Frameworkmodule sowie die Plan-Cache-, Query-Store- und Current-State-Integrationen.

## 2. Installationsszenarien

### 2.1 Nur Standalone-Execution-Plan-Analyse

```text
Install_ExecutionPlanAnalysis.sql
```

Nach erfolgreicher Installation müssen mindestens verfügbar sein:

```text
monitor.USP_ExecutionPlanAnalysis
monitor.USP_CreateExecutionEvidenceJson
```

Der direkte Aufruf mit `@PlanXml` und optionalem `@EvidenzJson` funktioniert ohne Plan-Cache-, Query-Store-, Agent-, Extended-Events-, Infrastructure- oder Server-Health-Module.

### 2.2 Vollständiges Framework

```text
Install_All.sql
```

Der Gesamtinstaller installiert zunächst die gemeinsam benötigte Infrastruktur und die Execution-Plan-Kernobjekte. Danach folgen unter anderem:

```text
monitor.USP_ShowplanAnalysis
monitor.USP_PlanCacheAnalysis
monitor.USP_PlanDetails
monitor.USP_IntelligentQueryProcessingAnalysis
```

Diese Integrationsobjekte verwenden den bereits installierten Kern und implementieren keine zweite abweichende Planinterpretation.

### 2.3 Teilinstaller nach vollständiger Installation

Der Teilinstaller muss idempotent sein. Eine erneute Ausführung:

- verwendet `CREATE OR ALTER` für Procedures und Functions;
- verwendet `IF NOT EXISTS` und kontrollierte Schemaerweiterungen für Tabellen;
- entfernt keine Daten;
- setzt keine lokalen Profilzuordnungen zurück;
- überschreibt keine kundenspezifischen beziehungsweise umgebungsspezifischen Regelwerte;
- führt kein Downgrade gemeinsamer Frameworkobjekte durch.

## 3. Scopegrenze des Teilinstallers

### 3.1 Enthalten

#### Gemeinsame Mindestinfrastruktur

Die konkrete Dateiliste ist im Dependency-Manifest eingefroren. Sie stellt folgende Fähigkeiten bereit:

```text
Schema [monitor]
Ausgabevalidierung für RAW, CONSOLE, TABLE, NONE und JSON
benannte TABLE-Ziele
kontrollierte Console-Ausgabe
Status- und Fehlervertrag
High-Impact- und interne Berechtigungsprüfung für aktive Deep-Pfade
zentrale Pattern- und Listenparser, soweit öffentliche Parameter sie verwenden
kontrollierte Datenbankkandidatenbildung für bestätigte CURRENT_SERVER-Anreicherung
```

Gemeinsame Objekte werden nicht dupliziert oder mit einem zweiten plananalysespezifischen Output- oder Berechtigungssystem nachgebaut.

#### Neue Standalone-Kernobjekte

```text
monitor.PlanAnalysisProfile
monitor.PlanAnalysisRuleThreshold
monitor.PlanAnalysisProfileAssignment
monitor.TVF_ParseStatisticsIoText
monitor.TVF_ParseStatisticsTimeText
monitor.TVF_ExecutionPlanObjectReferences
monitor.TVF_ExecutionPlanStatisticsUsage
monitor.TVF_ExecutionPlanColumnReferences
monitor.InternalCollectExecutionPlanMetadata
monitor.InternalAnalyzeExecutionPlan
monitor.USP_CreateExecutionEvidenceJson
monitor.USP_ExecutionPlanAnalysis
```

#### Frameworkmetadaten

Der Teilinstaller installiert beziehungsweise aktualisiert die für seine Objekte erforderlichen Framework-Metadaten nur dann als Datenbankobjekte, wenn der implementierte Stand solche Laufzeitmetadaten tatsächlich verwendet. Repositoryinventare wie CSV-Dateien sind kein SQL-Installationsbestandteil.

### 3.2 Nicht enthalten

```text
monitor.USP_ShowplanAnalysis
monitor.USP_PlanCacheAnalysis
monitor.USP_PlanDetails
monitor.USP_QueryStats
monitor.USP_QueryHashAnalysis
monitor.USP_PlanCacheHealth
Query-Store-Analysefamilie
Current-State-Analysefamilie
Extended-Events-Analysefamilie
Infrastructure- und Server-Health-Module
GitHub-Actions- oder Client-Collector-Komponenten
```

Begründung: Diese Objekte sind Integrations- oder Beschaffungspfade. Der Standalone-Kern benötigt sie für die direkte Analyse eines übergebenen Plan-XML nicht.

## 4. Optionale Anreicherungen im Teilinstaller

`USP_ExecutionPlanAnalysis` und `USP_CreateExecutionEvidenceJson` dürfen optionale CURRENT_SERVER-Anreicherung anbieten, ohne weitere öffentliche Analysefamilien zu installieren. Dafür sind nur die direkt benötigten gemeinsamen Helper und Systemkatalogzugriffe zulässig.

Optional bleiben:

```text
aktuelle Objekt- und Indexmetadaten
aktuelle Statistics Properties
Histogramm SUMMARY oder STEPS
Planhandle COMPILE beziehungsweise LAST_ACTUAL
Live-Plan einer expliziten Session
```

Die gezielte Beschaffung genau eines Query-Store-Plans ist direkt im öffentlichen Einstieg implementiert und benötigt keine Query-Store-Analysefamilie. Detailliertes Query-Store-Feedback wird nicht dupliziert; der Standalone-Pfad übernimmt es bei Bedarf über `@EvidenzJson`.

## 5. Installationsreihenfolge

Die verbindliche logische Reihenfolge lautet:

```text
01  Schema und Preflight
02  VW_AnalyseClassCatalog
03  VW_AnalyseAccessPolicy
04  VW_AnalyseAccessCurrent
05  TVF_ParsePipeList
06  TVF_ParseBigintList
07  InternalCheckAnalysisPath
08  InternalWriteResultTable
09  InternalPrepareResultTables
10  InternalEmitConsoleResult
11  PlanAnalysisProfile
12  PlanAnalysisRuleThreshold
13  PlanAnalysisProfileAssignment
14  TVF_ParseStatisticsIoText
15  TVF_ParseStatisticsTimeText
16  TVF_ExecutionPlanObjectReferences
17  TVF_ExecutionPlanStatisticsUsage
18  TVF_ExecutionPlanColumnReferences
19  InternalCollectExecutionPlanMetadata
20  InternalAnalyzeExecutionPlan
21  USP_CreateExecutionEvidenceJson
22  USP_ExecutionPlanAnalysis
```

`Install_All.sql` setzt danach unter anderem fort mit:

```text
23  USP_ShowplanAnalysis
24  USP_PlanCacheAnalysis und weitere Plan-Cache-Integrationen
25  Query-Store-/IQP-Integrationen
26  übrige Frameworkmodule
```

Die Quellpfade und Ordinals stehen verbindlich im Dependency-Manifest. Ein Post-Install-Test ist kein Installerobjekt und läuft als separater synthetischer Contract.

## 6. Implementierte Repositorydateien

### 6.1 Kerncode

```text
Code/04_PlanCache/041_PlanAnalysisProfile.sql
Code/04_PlanCache/042_PlanAnalysisRuleThreshold.sql
Code/04_PlanCache/043_PlanAnalysisProfileAssignment.sql
Code/04_PlanCache/044_TVF_ParseStatisticsIoText.sql
Code/04_PlanCache/045_TVF_ParseStatisticsTimeText.sql
Code/04_PlanCache/046_TVF_ExecutionPlanObjectReferences.sql
Code/04_PlanCache/047_TVF_ExecutionPlanStatisticsUsage.sql
Code/04_PlanCache/048_TVF_ExecutionPlanColumnReferences.sql
Code/04_PlanCache/049_InternalCollectExecutionPlanMetadata.sql
Code/04_PlanCache/051_InternalAnalyzeExecutionPlan.sql
Code/04_PlanCache/052_USP_CreateExecutionEvidenceJson.sql
Code/04_PlanCache/053_USP_ExecutionPlanAnalysis.sql
```

### 6.2 Installer

```text
Code/Install/Install_ExecutionPlanAnalysis.sql
Code/Install/Install_All.sql
```

### 6.3 Tests

```text
Code/Tests/PlanCache/120_ExecutionPlanAnalysis_Runtime_Contract.sql
Code/Tests/Integration/192_ExecutionPlanAnalysis_Installer_Contract.ps1
Code/Tests/Integration/193_ExecutionPlanAnalysis_Standalone_Runtime_Contract.sql
Code/Tests/Static/997_Validate_ExecutionPlanAnalysis_Public_Contract.py
```

## 7. Generierung statt manueller Doppelpflege

Der Teilinstaller und der Gesamtinstaller dürfen dieselben Objekttexte nicht manuell in zwei voneinander unabhängigen Fassungen pflegen.

Zulässige Modelle:

1. SQLCMD-Includes aus derselben kanonischen Dateiliste;
2. ein vorhandener Installer-Generator erzeugt beide Installer aus getrennten Manifesten;
3. der eigenständige, auslieferbare Installer wird deterministisch aus dem Teilmanifest gebaut, während `Install_All.sql` das Gesamtmanifest verwendet.

Nicht zulässig:

- Kopieren und getrenntes manuelles Nachpflegen vollständiger Objektdefinitionen;
- abweichende Objektversionen in Teil- und Gesamtinstaller;
- ein Teilinstaller, der intern ungeprüft `Install_All.sql` ausführt;
- ein Gesamtinstaller, der einen veralteten eingebetteten Teilinstaller enthält.

## 8. Dependency-Manifest

Das maschinenlesbare Manifest besitzt folgende eingefrorene Felder:

```text
InstallOrdinal
ObjectType
ObjectName
SourcePath
StandaloneRequired
FrameworkIntegrationRole
```

Das Manifest ist die Quelle für:

- Teilinstaller;
- Einbindung in den Gesamtinstaller;
- Installationsreihenfolgetests;
- Prüfung, dass der Teilinstaller keine unzulässigen Analysefamilien installiert.

## 9. Steuertabellen und Seedverhalten

### 9.1 Frameworkdefaults

Repository-Seeds dürfen ausschließlich generische Defaultprofile und Regelschwellen enthalten:

```text
LATENCY_SENSITIVE
BALANCED
THROUGHPUT
MAINTENANCE
UNKNOWN
```

Alle Werte müssen als Frameworkheuristiken dokumentiert werden.

### 9.2 Lokale Anpassungen

Eine erneute Installation:

- ergänzt fehlende Frameworkdefaults;
- aktualisiert Frameworkdefaults nur über eine explizit dokumentierte Seedversion;
- löscht keine lokalen Zeilen;
- überschreibt keine Zeilen mit `IsFrameworkDefault = 0`;
- speichert keine realen Datenbank-, Objekt-, Benutzer- oder Unternehmensbezeichner im Repositoryseed.

## 10. Datenschutz im Installer

Der Installer enthält keine:

- echten Pläne;
- Histogrammgrenzwerte;
- Parameter- oder Literalwerte;
- `STATISTICS IO`-/`TIME`-Ausgaben aus realen Umgebungen;
- realen Datenbank-, Schema-, Tabellen-, Index-, Statistik-, Benutzer-, Server- oder Programmnamen;
- Logs, Ausführungspläne oder Screenshots mit internen Informationen.

Tests verwenden synthetische `Example*`-Bezeichner und selbst erzeugte rücksetzbare Datenverteilungen.

## 11. Berechtigungen

Der Teilinstaller vergibt keine Analyseberechtigungen an Benutzer oder Gruppen. Er installiert nur die Frameworkobjekte.

Die Laufzeitobjekte:

- prüfen die tatsächlich benötigte Server- beziehungsweise Datenbankberechtigung;
- nennen die erforderliche Berechtigung im Status;
- verwenden die vorhandene interne Ressourcenfreigabe für Deep-Pfade;
- ändern keine Server- oder Datenbankkonfiguration;
- aktivieren keine Profiling- oder Query-Store-Funktion.

## 12. Idempotenz und Upgradefähigkeit

### 12.1 Procedures und Functions

```text
CREATE OR ALTER
```

### 12.2 Tabellen

- `IF NOT EXISTS` für Ersterstellung;
- additive Migrationen nur kontrolliert und versioniert;
- keine destruktive Rekonstruktion bei vorhandenen lokalen Daten;
- Constraints und Indizes einzeln prüfen;
- Seedversion ausweisen.

### 12.3 Resultset- und JSON-Schema

- Resultset-Schemaversionen im Repositoryinventar;
- Evidenz-JSON mit eigener `schemaVersion`;
- unbekannte zusätzliche JSON-Properties tolerieren;
- nicht unterstützte ältere oder neuere Schemaversionen kontrolliert melden;
- kein stillschweigendes Umdeuten.

## 13. Post-Install-Validierung

Der Teilinstaller selbst enthält nur kanonische SQLCMD-Includes und führt keine versteckten Testabfragen aus. Die leichte Post-Install-Validierung läuft unmittelbar danach über einen separaten synthetischen Runtime-Contract, damit Installation und Test eindeutig getrennt bleiben.

Mindestens zu prüfen:

```text
alle erforderlichen Objekte vorhanden
keine verbotenen Integrationsfamilien durch Teilinstaller installiert
öffentliche Signaturen verfügbar
@Hilfe=1 erfolgreich
synthetischer Minimalplan analysierbar
Evidenz-JSON mit leerer beziehungsweise synthetischer Evidenz validierbar
TABLE-Zielpreflight funktionsfähig
kein High-Impact-Zugriff im Smoke-Test
```

Der Teilinstaller führt keine vollständigen Deep-Tests aus. `193_ExecutionPlanAnalysis_Standalone_Runtime_Contract.sql` prüft Erstinstallation, beide Public APIs, Reinstallation, lokale Seed-Erhaltung, Objektclosure sowie die Unabhängigkeit von `USP_ShowplanAnalysis`, Query Store und Extended Events.

## 14. Release-Gate

Die vollständige Implementierung muss bestehen:

```text
SQL Server 2019
SQL Server 2022
SQL Server 2025
```

Die finale synthetische Linux-Matrix ist dokumentiert erfolgreich: SQL Server 2019, 2022 und 2025 haben Gesamtgate und Permission Matrix bestanden; SQL Server 2025 zusätzlich den isolierten Teilinstallervertrag und die Regex Matrix. Der Output-Pilot ist auf allen drei Zielversionen erfolgreich. Die verbindlichen Actions-Verweise, Zielbuilds und Container-Digests stehen im maschinenlesbaren Public Contract.

Zusätzlich:

- Teilinstaller aus leerer Datenbank;
- Teilinstaller nach vollständigem Framework;
- Teilinstaller zweimal hintereinander;
- Gesamtinstaller aus leerer Datenbank;
- Vergleich der Kernobjektdefinitionen aus Teil- und Gesamtinstallation;
- Privacy-Tests für Histogramm-, Parameter- und Predicatewerte;
- Prüfung der installierten Objektmenge gegen das Dependency-Manifest.

## 15. Abnahmekriterien

Der Teilinstaller ist fertig, wenn:

1. `USP_ExecutionPlanAnalysis` einen synthetischen Plan direkt analysiert;
2. `USP_CreateExecutionEvidenceJson` synthetische Evidenz erzeugt und normalisiert;
3. kein Plan-Cache-, Query-Store- oder anderes Analysefamilienobjekt für den direkten Standalone-Aufruf benötigt wird;
4. aktive CURRENT_SERVER-Deep-Pfade kontrolliert gegated sind;
5. Teil- und Gesamtinstaller dieselben Kernobjektversionen installieren;
6. eine Wiederholung keine lokalen Regeln oder Zuordnungen zerstört;
7. SQL Server 2019, 2022 und 2025 nicht verfügbare Features kontrolliert als Capability-Status ausgeben;
8. keine realen oder potenziell sensiblen Werte in Repositoryartefakten enthalten sind.

## 16. Implementierungsentscheidung

Der Teilinstaller ist aus derselben kanonischen Quellmenge wie `Install_All.sql` aufgebaut. Der Installervertrag vergleicht seine Includes mit dem Dependency-Manifest; der Standalone-Runtime-Contract prüft zusätzlich die tatsächlich installierte Objektclosure und die Idempotenz auf einer leeren synthetischen Datenbank.
