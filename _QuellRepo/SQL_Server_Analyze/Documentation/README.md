# SQL Server Analyze – Dokumentationsübersicht

SQL Server Analyze ist ein T-SQL-Diagnoseframework für SQL Server 2019 oder neuer. Die Dokumentation ist nach Nutzungssituation aufgebaut: zuerst passende Analyse finden, danach Resultate korrekt lesen und erst anschließend technische Architektur oder Einzelkomponenten vertiefen.

## Empfohlene Leserichtung

1. [Hier beginnen](Analysis_Guides/Start_Here.md) – von Symptom oder Ziel zur geeigneten ersten Procedure.
2. [`USP_AnalysisNavigator`](Reference/Analysis_Navigator.md) – Suche direkt in SSMS, Rollen, Ranking, Kosten, Pakete und Folgebeziehungen.
3. [Einsteiger-Leseleitfaden](Analysis_Guides/Beginner_Reading_Guide.md) – Status, Scope, Zeitbezug, Nenner, Partialität und Gegenprobe.
4. [Runbooks](Analysis_Guides/Runbooks/README.md) – konkrete Abläufe für zehn häufige Störungssituationen.
5. [Procedure-Seiten](Analysis_Guides/Procedures/README.md) – eigenständige Tiefendokumentation für alle 97 öffentlichen Procedures.
6. [Objektreferenz](Reference/Object_Reference.md) – jede unterstützende View, TVF, interne Procedure und Tabelle.

Der Inventarvertrag umfasst 165 Objekte: 97 öffentliche Procedures, acht Views, 27 Table-Valued Functions, 16 interne Procedures und 17 Tabellen. Scalar-Valued Functions sind derzeit nicht vorhanden.

## Installation und erster Betrieb

- [Vollständige Installation](Reference/Installation.md): Voraussetzungen, SQLCMD- und eigenständiger Installer, Smoke-Test, Berechtigungen und Fehlerbehebung.
- [Schnellwahl und Aufrufkatalog](Reference/Call_Catalog.md): kopierbare Hilfe- und sichere Beispielaufrufe.
- [Procedure-Referenz](Reference/Procedure_Reference.md): Parameter, Datentypen, Defaults und OUTPUT-Verträge.
- [Resultset-Konventionen](Reference/Resultset_Conventions.md): benannte Ergebnisverträge und native TABLE-Schemas.
- [Szenarien](Reference/Scenarios.md): typische Kombinationen mehrerer Analysen.

Beispielaufrufe verwenden ausschließlich `[monitor].[Objektname]` und sind nicht mit einer konkreten Frameworkdatenbank qualifiziert.

## Analysehandbuch

| Zweck | Dokument |
|---|---|
| Gesamtübersicht | [Analysehandbuch](Analysis_Guides/README.md) |
| Auswahl nach Beobachtung | [Hier beginnen](Analysis_Guides/Start_Here.md) |
| Symptomorientierte Abläufe | [Runbooks](Analysis_Guides/Runbooks/README.md) |
| Alle öffentlichen Procedures | [Objektindex](Analysis_Guides/Object_Index.md) |
| Fachbegriffe | [Glossar](Analysis_Guides/Glossary.md) |
| Filter, Limits und sichere Aufrufe | [Parameter-Lesehilfe](Analysis_Guides/Parameter_Reading_Guide.md) |
| Gemeinsame Status- und Evidenzverträge | [Gemeinsame Verträge](Analysis_Guides/Common_Contracts.md) |
| Execution-, Zeit-, Scope- und Kostenmodell | [Technische Grundlagen](Analysis_Guides/Technical_Foundations.md) |
| Versions- und Primärquellenzuordnung | [Primärquellenmatrix](Analysis_Guides/Version_Primary_Source_Matrix.md) |

### Bereichsleitfäden

- [Common, Zugriff und Frameworkschnittstellen](Analysis_Guides/01_Common.md)
- [Current State und Live-Triage](Analysis_Guides/02_Current_State.md)
- [Objekte, Indizes und Statistiken](Analysis_Guides/03_Object_Index.md)
- [Plan Cache, Showplan und Execution Plan](Analysis_Guides/04_Plan_Cache.md)
- [Query Store](Analysis_Guides/05_Query_Store.md)
- [Extended Events](Analysis_Guides/06_Extended_Events.md)
- [Infrastruktur und Betrieb](Analysis_Guides/07_Infrastructure.md)
- [Server Health und Konfiguration](Analysis_Guides/08_Server_Health.md)
- [Versionen und Spezialfeatures](Analysis_Guides/09_Version_Adaptive.md)

## Ressourcenschutz und Berechtigungen

Die interne Policy schaltet ressourcenintensive Analyseklassen für Benutzergruppen frei oder sperrt sie. Sie erteilt keine SQL-Server-Berechtigungen.

1. [Architektur und Entscheidungsfluss](Architecture/Authorization_Architecture.md)
2. [Administration](Operations/Authorization_Administration.md)
3. [Troubleshooting](Operations/Authorization_Troubleshooting.md)
4. [Policy-Beispiele](Reference/Authorization_Policy_Examples.md)
5. [Status- und Access-Reasons](Reference/Authorization_Status_and_Access_Reasons.md)
6. [Ausführbare Beispiele](../Code/Examples/050_Authorization_Examples.sql)

Kostenklasse, High-Impact-Bestätigung und SQL-Server-Berechtigung sind getrennte Verträge. Der Analysis Navigator zeigt den repräsentativen Kostenkontext; die Ziel-Procedure entscheidet den tatsächlich aktivierten Pfad.

## Architektur

- [Implementierungsstatus und Abschlusskriterien](Architecture/Implementation_Status_Model.md)
- [RAW-, CONSOLE-, TABLE- und JSON-Ausgabe](Architecture/Output_RAW_CONSOLE_JSON.md)
- [Datenbank-, CONSOLE- und TABLE-Vertrag](Architecture/Database_Console_Table_Contract.md)
- [Parameter-API](Architecture/Parameter_API.md)
- [Listen- und Patternfilter](Architecture/Filter_Lists_and_Patterns.md)
- [Zeilen- und Scope-Limits](Architecture/Row_Limits.md)
- [SQL-Text-, Statement-, Batch- und Modulkontext](Architecture/SQL_Text_Statement_Batch_Module.md)
- [Tool-Hintergrundabfragen](Architecture/Tool_Background_Query_Filtering.md)
- [Memory Grants und Resource Governor](Architecture/Memory_Grants_and_Resource_Governor.md)
- [Spezialfallmodule](Architecture/Special_Case_Modules.md)
- [SQL-Server-2025-JSON-Index-Inventar](Architecture/SQL_Server_2025_JSON_Index_Inventory.md)
- [SQL-Server-2025-TempDB-Resource-Governance](Architecture/SQL_Server_2025_TempDB_Resource_Governance.md)
- [SQL-Server-2025-Statistiken auf lesbaren Secondaries](Architecture/SQL_Server_2025_Readable_Secondary_Statistics.md)
- [RUNTIME-001: External Runtime und SQL CLR](Architecture/External_Runtime_CLR_Analysis_Plan.md)
- [LAB-001: Reproducible Diagnostic Lab](Architecture/Reproducible_Diagnostic_Lab_Plan.md)
- [LAB-001: Docker-/Podman-Quick-Testsystem](Architecture/Docker_Podman_Quick_Test_System_Requirements.md)
- [Geplantes SubProject SSIS-001: SSIS Package- und Execution-Analyse](Architecture/SSIS_Package_and_Execution_Analysis_Plan.md)
- [Datenschutz und Laufzeitausgaben](Architecture/Runtime_Data_Privacy.md)
- [Execution-Plan-Analyse](Architecture/Execution_Plan_Analysis_Design.md)
- [Eigenständiges PLAN-001-Paket](Architecture/Execution_Plan_Analysis_Installation_Contract.md)
- [Snapshot-/Baseline-Paket](Architecture/Snapshot_Baseline_Package_Contract.md)

## Betrieb

- [Versionsadaptive Features](Operations/Version_Adaptive_Features.md)
- [Wait-Stats-Methodik](Operations/Wait_Stats_Methodology.md)
- [Wait-Type-Katalog](Operations/Wait_Type_Catalog.md)
- [Snapshot-/Baseline-Betrieb](Operations/Snapshot_Baseline_Operations.md)

Das Framework erstellt keine Datenbank, vergibt keine Benutzer- oder Serverrechte und richtet keinen Scheduler ein. Das optionale Snapshotpaket besitzt einen separaten Installations-, Retention-, Budget- und Löschvertrag.

## Vollständige Referenz

- [Analysis Navigator](Reference/Analysis_Navigator.md)
- [Call Catalog](Reference/Call_Catalog.md)
- [Procedure-Signaturen](Reference/Procedure_Reference.md)
- [Unterstützende Objekte](Reference/Object_Reference.md)
- [Resultsetinventar](Reference/Resultset_Conventions.md)
- [Autorisierungsstatus](Reference/Authorization_Status_and_Access_Reasons.md)
- [Autorisierungsbeispiele](Reference/Authorization_Policy_Examples.md)

Die maschinenlesbaren Verträge liegen unter `Metadata/Inventory` und `Metadata/Quality`. `Objects.csv` ist die technische Bestandsquelle; der Analysis Catalog bildet die fachliche Navigation darüber ab.

## Qualität und unterstützte Nachweise

- [Verbindlicher Schreibstil für Dokumentation](Quality/Documentation_Writing_Style.md)
- [Bestandsprüfung des Dokumentationsstils](Quality/Documentation_Style_Review.md)
- [Testmatrix](Quality/Test_Matrix.md)
- [CI-Impact-Auswahl](Quality/CI_Impact_Selection.md)
- [Performance- und Risikobewertung](Quality/Performance_and_Risk_Assessment.md)
- [Bekannte Einschränkungen](Quality/Known_Issues.md)
- [Release Notes](Quality/Release_Notes.md)

Ein Eintrag `NOT_EXECUTED` in der Testmatrix ist kein Laufzeitnachweis. Leere oder partielle fachliche Resultsets sind ebenfalls kein automatischer Negativnachweis; Status, Berechtigung, Capture, Retention, Filter und Zeitbezug bleiben mitzulesen.
