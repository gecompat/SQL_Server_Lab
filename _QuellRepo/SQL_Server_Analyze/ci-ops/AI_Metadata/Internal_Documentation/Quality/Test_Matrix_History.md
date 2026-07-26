# Testmatrix und Freigabeprotokoll

**Stand:** 21. Juli 2026
**Status:** commitbezogene 34-Suite-Evidenz einschließlich der Welle-1- und Welle-2-Verträge vorhanden
**Maschinenlesbare Fassung:** `Metadata/Quality/Test_Matrix.csv`
**Integrationsrunner:** `Code/Tests/Run_Release_Gate.sql`
**Suite-Evidenz:** `Metadata/Quality/Release_Gate_Evidence.csv`
**Nachweisregel:** Nur tatsächlich ausgeführte und protokollierte Kombinationen gelten als Laufzeitnachweis; `NOT_EXECUTED` bedeutet ausdrücklich nicht getestet.

Die zielunabhängigen Modulfälle stehen zusätzlich in `Metadata/Quality/Special_Case_Test_Cases.csv`. Zielmatrix und Modulfälle werden über `TargetId`, getesteten Commit und einen nicht sensitiven Evidence-Verweis gemeinsam dokumentiert.

## Zweck

Diese Matrix dokumentiert nachprüfbar, auf welchen SQL-Server-Ausprägungen ein Repositorystand installiert, kompiliert und getestet wurde. Ein allgemeiner Hinweis wie „vollständig getestet“ ersetzt keine konkrete Zielmatrix.

Technische Grundlage sind die offiziellen Verträge zum [Pullen beziehungsweise Pinnen eines Docker-Images per Digest](https://docs.docker.com/reference/cli/docker/image/pull/), zu den [SQL-Server-Linux-Containerimages](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/quickstart-install-docker?view=sql-server-ver17) und zu [`SERVERPROPERTY('ProductVersion')`](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17). `ProductVersion` wird als `major.minor.build.revision` validiert; der Digest wird als unveränderlicher Startbezug verwendet.

## Automatisierte Evidence

Commit `8572c02ccec7b349d104ccf72a01489733fc03a7` hat Installer, den 34-Suite-Release-Gate-Vertrag einschließlich aller 181 Spezialfälle, der TABLE-/Pilot-/Framework-Ausgabesuiten sowie der Welle-1- und Welle-2-Begleitverträge und die Berechtigungsmatrix auf den drei Linux-Targets erfolgreich abgeschlossen. Das SQL-Server-2025-Gate hat zusätzlich die eigenständige Regex-Matrix ausgeführt:

| Target | ProductVersion | Compatibility Level | Actions-Nachweis | Ergebnis |
|---|---|---:|---|---|
| SQL Server 2019 | `15.0.4480.2` | 150 | [Run 29817699638](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699638) | `PASS_WITH_LIMITATIONS`; 34 Suiten einschließlich Welle-1- und Welle-2-Vertrag |
| SQL Server 2022 | `16.0.4265.3` | 160 | [Run 29817699733](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699733) | `PASS_WITH_LIMITATIONS`; 34 Suiten einschließlich Welle-1- und Welle-2-Vertrag |
| SQL Server 2025 | `17.0.4065.4` | 170 | [Run 29817699655](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699655) | `PASS_WITH_LIMITATIONS`; 34 Suiten einschließlich Welle-1- und Welle-2-Vertrag; `REGEX_MATRIX=PASS` |

Die Läufe haben nach dem Pull den aufgelösten Digest validiert und exakt diesen unveränderlichen Bezug gestartet:

| Target | Container-Image-Digest |
|---|---|
| SQL Server 2019 | `mcr.microsoft.com/mssql/server@sha256:46f719fd3457d4e7e8e5845fe00c35c20e7bae7ff1e8b9fe595f2a81029f5ba8` |
| SQL Server 2022 | `mcr.microsoft.com/mssql/server@sha256:ba4c8329f48fb8f02e1416be6a930ebfd71268caee78aa985f3af4315e457c89` |
| SQL Server 2025 | `mcr.microsoft.com/mssql/server@sha256:86cc6144ef39bb0fbed2329e1ad79b13ee82e7b2e4739213a0db0800e668a74a` |

Der Runtime-Nachweis ist commitbezogen; Dokumentations-, Commit-Message- und Datenschutzgates werden als getrennte Evidence-Klassen geführt. Die Linux-Evidence bleibt synthetisch und read-only. Feature-positive Windows-/Azure-MI-Zustände, Lasttests, externe Restorebeweise und operative Mutationen bleiben separate Nachweise.

## Datenschutz

Das Protokoll enthält ausschließlich technische Produktmerkmale und synthetische Target-IDs. Nicht dokumentiert werden reale Server-, Instanz-, Benutzer-, Firmen-, Kunden-, Datenbank-, Domain-, Host- oder Infrastrukturbezeichner. Resultsets und OUTPUT-Parameter der getesteten Procedures bleiben davon unberührt.

## Pflichtfelder

| Feld | Bedeutung |
|---|---|
| TargetId | synthetische stabile Kennung, beispielsweise SQL2019-WINDOWS |
| ProductMajorVersion | 15, 16 oder 17 |
| ProductVersion | vollständige technische Buildnummer, sofern bestätigt |
| ContainerImageReference | beim Pull verwendeter öffentlicher MCR-Tag; für Nicht-Container-Ziele leer |
| ContainerImageDigest | beim Lauf aufgelöster unveränderlicher `repo@sha256`-Digest; für Nicht-Container-Ziele leer |
| EditionClass | EXPRESS, STANDARD, ENTERPRISE, DEVELOPER oder AZURE_MI |
| Platform | WINDOWS, LINUX oder AZURE_MI |
| CompatibilityLevel | getesteter Compatibility Level |
| Collation | erwartete case-sensitive Zielcollation |
| PermissionProfile | technische Berechtigungsklasse ohne Principalnamen |
| OptionalFeatures | Pipe-Liste generischer Featurecodes |
| FrameworkRelease | kanonische Frameworkversion des aktuellen Evidence-Satzes |
| ReleaseGateSuiteCount | Anzahl der im vollständigen Release-Gate ausgeführten Suiten |
| P0CaseCount / P1CaseCount / P2CaseCount | kanonische Fallzahlen je Prioritätsklasse |
| CommitSha | exakt getesteter Commit |
| TestStatus | NOT_EXECUTED, PASS, PASS_WITH_LIMITATIONS oder FAIL |
| EvidenceStatus | REPORTED oder INDEPENDENTLY_VERIFIED |
| EvidenceReference | öffentlicher technischer Actions-Verweis ohne Laufzeitdaten |

## Verbindliche Prüffolge je Target

1. Pullen Sie bei Containerzielen den öffentlichen Image-Tag, validieren Sie den aufgelösten `repo@sha256`-Digest und starten Sie exakt diesen Digest. Erfassen Sie nach der Bereitschaft `SERVERPROPERTY('ProductVersion')`.
2. Führen Sie den Installer im vorgesehenen Datenbankkontext aus.
3. Prüfen Sie den Compile- und Objektbestand.
4. Führen Sie im SQLCMD-Modus aus `Code/Tests` den Runner `Run_Release_Gate.sql` aus. Er startet die sechsundzwanzig folgenden Vertragsgruppen und danach acht Bereichs-Smoke-Tests in fester Reihenfolge; beim ersten SQL-Fehler wird beendet:
   - `Integration/110_Smoke_Test.sql`
   - `Integration/163_Parameter_API_Vertrag.sql`
   - `Integration/165_Filter_Output_Contract.sql`
   - `Integration/167_Special_Case_API_Contract.sql`
   - `Integration/168_Special_Case_Runtime_Contract.sql`
   - `Integration/169_P0_Runtime_Contract.sql`
   - `Integration/170_P1_IQP_Runtime_Contract.sql`
   - `Integration/171_P1_Contention_Runtime_Contract.sql`
   - `Integration/172_P1_Memory_Runtime_Contract.sql`
   - `Integration/173_P1_Backup_Runtime_Contract.sql`
   - `Integration/174_P1_Schema_Runtime_Contract.sql`
   - `Integration/175_P1_Statistics_Runtime_Contract.sql`
   - `Integration/176_P1_Availability_Runtime_Contract.sql`
   - `Integration/177_P1_Agent_Runtime_Contract.sql`
   - `Integration/178_P1_Diagnostic_Findings_Runtime_Contract.sql`
   - `Integration/179_P2_Special_Feature_Inventory_Runtime_Contract.sql`
   - `Integration/180_P2_InMemory_Oltp_Runtime_Contract.sql`
   - `Integration/181_P2_Temporal_Runtime_Contract.sql`
   - `Integration/182_P2_Service_Broker_Runtime_Contract.sql`
   - `Integration/183_P2_FullText_Runtime_Contract.sql`
   - `Integration/184_P2_Data_Capture_Runtime_Contract.sql`
   - `Integration/185_P2_Encryption_Runtime_Contract.sql`
   - `Integration/186_P2_Maintenance_Runtime_Contract.sql`
   - `Integration/187_Table_Output_Runtime_Contract.sql`
   - `Integration/188_Framework_Output_Pilot_Runtime_Contract.sql`
   - `Integration/189_Framework_Output_Runtime_Contract.sql`
     - `Integration/190_Wave1_Output_Xml_Version_Runtime_Contract.sql` als Begleitvertrag derselben 26. Ausgabesuite
   - Common, Current State, Object/Index, Plan Cache, Query Store, Extended Events, Infrastructure und Server Health
5. Führen Sie die Bereichstests für Common, Current State, Object/Index, Plan Cache, Query Store, Extended Events, Infrastructure und Server Health aus.
6. Prüfen Sie neue Spezialfallmodule gegen Capability-, Leerzustands-, Positiv-, Berechtigungs-, Reset- und Lastfälle; prüfen Sie bei der Statistikverteilung zusätzlich Uniform-, Dominanz-, Tail-, Modification-, Filter-, Incremental- und Kandidatengrenzfälle. Für `USP_SpecialFeatureInventory` sind Feature-absent, eingeschränkte Metadatensichtbarkeit, Begrenzung sowie je ein positiver Fall für alle 18 Featurecodes vorgesehen. Für `USP_InMemoryOltpAnalysis` sind No-XTP, Schema-only, Speicher-, Hashketten-, Checkpoint-, Transaktions-, Pool-, Berechtigungs-, Filter-, Begrenzungs- und Kostenfälle definiert. Für `USP_TemporalAnalysis` sind No-Temporal, Zuordnung/Period, Retention, Kapazität/Ratio, Indexbaseline, Memory-Optimized, Berechtigung, Filter, Begrenzung und die ausdrückliche Nichterkennbarkeit getrennter Paare vorgesehen. Für `USP_ServiceBrokerAnalysis` sind No-Broker, Konfiguration ohne Objekte, deaktivierter Broker mit Objekten, Queue-Schalter, approximative Kapazität, interne Aktivierung, Transmission-Alter/-Status, Conversation-Zustände, Retention, Berechtigungen, Filter, Begrenzung und ein statischer Payload-Ausschluss vorgesehen. Für `USP_FullTextAnalysis` sind Feature-/Katalogzustand, Indexschalter, Populationen, Batches, Fragmente, Semantik, Memory/FDHost, Berechtigungen, Filter, Begrenzung und Inhalts-/DDL-Ausschluss vorgesehen. Für `USP_DataCaptureDeepAnalysis` sind CT-Consumer-Versionen, CDC-Scan/Fehler/Jobs/Cleanup, lokale Replikationsagenten/Rückstand/Fehler, Remote-Topologielücke, Berechtigungen, Filter, Begrenzung und Nutzdaten-/Credential-/Command-/DDL-Ausschluss vorgesehen. `USP_EncryptionAnalysis` trennt TDE, Zertifikatslebenszyklus, explizite Backupverschlüsselung und aggregierte Always-Encrypted-/Ledger-Fälle. `USP_MaintenanceOperations` trennt pausierte/aktive Requests, PVS-Versionen, ungefilterte und explizit gefilterte Jobfälle sowie den statischen Änderungs- und Inhaltsausschluss. Alle Fälle stehen in `Special_Case_Test_Cases.csv`.
7. Verifizieren Sie die RAW-, CONSOLE-, TABLE-, NONE- und JSON-Verträge.
8. Führen Sie das Repository- und Liefergate aus.
9. Halten Sie den Targetstatus in `Test_Matrix.csv` und jeden Suite-Status in `Release_Gate_Evidence.csv` fest. Reale Umgebungswerte, Resultsets und lokale Pfade dürfen nicht übernommen werden.

`Release_Gate_Evidence.csv` enthält ausschließlich vorab definierte synthetische Target- und Suitekennungen. `CommitSha`, `TestedAtUtc` und ein generischer Evidence-Verweis werden erst nach realer Ausführung ergänzt. Sobald ein vorgesehener Nachweis sensible oder nicht eindeutig generische Inhalte enthalten könnte, bleibt der Schreibvorgang angehalten und der zulässige Inhalt muss vorab geklärt werden.

## Freigaberegel

Ein Target gilt nur dann als freigegeben, wenn `TestStatus` mindestens `PASS_WITH_LIMITATIONS` ist, der getestete Commit exakt angegeben wurde und jede Einschränkung als generische Capability- oder Berechtigungsaussage dokumentiert ist. Nicht ausgeführte Zeilen bleiben ausdrücklich `NOT_EXECUTED`.

Die drei Windows-Zeilen der CSV bleiben Planungseinträge und keine behaupteten Testergebnisse.

## Execution-Plan-Analyse

`PlanCache/120_ExecutionPlanAnalysis_Runtime_Contract.sql` prüft synthetische Mehrstatementpläne, gleiche NodeIds in unterschiedlichen Statements, paarweise ActualRows-/ActualRowsRead-Auswertung, JSON- und TABLE-Ausgabe, erneute Evidenznormalisierung, die Datenschutzmodi `DERIVED_ONLY`, `TOKENIZED` und `OMIT` sowie IO-/TIME-Parsing. Der Teilinstallervertrag wird zusätzlich durch `Integration/192_ExecutionPlanAnalysis_Installer_Contract.ps1` und den isolierten SQL-Server-2025-Lauf `Integration/193_ExecutionPlanAnalysis_Standalone_Runtime_Contract.sql` geprüft. Die finale Actions-Matrix auf SQL Server 2019, 2022 und 2025 ist bestanden; die kanonischen PLAN-001-Verweise stehen in `Metadata/Quality/ExecutionPlanAnalysis_Public_Contract.json`.
