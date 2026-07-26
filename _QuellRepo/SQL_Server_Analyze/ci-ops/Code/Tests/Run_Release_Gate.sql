:ON ERROR EXIT

/*
===============================================================================
Datei        : Run_Release_Gate.sql
Zweck        : Führt die verbindlichen Integrationsverträge eines installierten
               Frameworkstands in fester Reihenfolge aus.
Ausführung   : Im SQLCMD-Modus aus dem Verzeichnis Code/Tests starten.
Voraussetzung: Den generischen Platzhalter [DeineDatenbank] vor der Ausführung
               repositoryweit durch die vorgesehene Installationsdatenbank
               ersetzen. Install_All.sql muss erfolgreich ausgeführt sein.
Nebenwirkung : Die eingebundenen Tests verwenden ausschließlich synthetische,
               rücksetzbare Fixtures und temporäre Objekte. Bei erstem
               SQL-Fehler endet der Runner.
Datenschutz  : Laufzeitausgaben werden nicht in Dateien geschrieben. Eine
               Übernahme in Repositoryartefakte ist separat zu prüfen.
Evidenz      : Versionsworkflows veröffentlichen commitbezogene Statuskontexte
               und bilden die kanonische Release-Candidate-Laufzeitevidenz.
Nachlauf     : Ein expliziter Verifikationscommit prüft nachgelagerte reine
               Status- und Evidence-Änderungen erneut auf allen Zielversionen.
P1           : Suiten 170 bis 178 prüfen alle 40 P1-Fälle.
P2           : Suiten 179 bis 186 prüfen Feature Inventory, In-Memory OLTP,
               Temporal, Service Broker, Full-Text, Data Capture, Encryption
               und Maintenance capability-adaptiv und ohne reale Nutzdaten.
OUTPUT       : Suiten 187 bis 190 prüfen Strukturadaption, Pilotvertrag, den
               frameworkweiten CONSOLE-/TABLE-Vertrag sowie die Welle-1-
               Verträge. Suite 191 ergänzt die Welle-2-Betriebsdiagnosen;
               Suite 196 prüft den Analysis Navigator.
               Suiten 120, 121, 122, 123, 190, 191, 196, 198 und 199 sind
               Begleittests; die kanonische Anzahl der Release-Suiten bleibt
               deshalb 34.
===============================================================================
*/

RAISERROR(N'RELEASE_GATE 1/34: Smoke Test',10,1) WITH NOWAIT;
:r Integration/110_Smoke_Test.sql

RAISERROR(N'RELEASE_GATE 2/34: Parameter-API-Vertrag',10,1) WITH NOWAIT;
:r Integration/163_Parameter_API_Vertrag.sql

RAISERROR(N'RELEASE_GATE 3/34: Filter- und Ausgabe-Vertrag',10,1) WITH NOWAIT;
:r Integration/165_Filter_Output_Contract.sql

RAISERROR(N'RELEASE_GATE 4/34: Spezialfall-API-Vertrag',10,1) WITH NOWAIT;
:r Integration/167_Special_Case_API_Contract.sql

RAISERROR(N'RELEASE_GATE 5/34: Spezialfall-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/168_Special_Case_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 6/34: P0-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/169_P0_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 7/34: P1-IQP-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/170_P1_IQP_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 8/34: P1-Contention-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/171_P1_Contention_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 9/34: P1-Speicher-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/172_P1_Memory_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 10/34: P1-Backupketten-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/173_P1_Backup_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 11/34: P1-Schema-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/174_P1_Schema_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 12/34: P1-Statistikverteilungs-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/175_P1_Statistics_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 13/34: P1-Availability-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/176_P1_Availability_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 14/34: P1-Agent-/Alert-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/177_P1_Agent_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 15/34: P1-Findings-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/178_P1_Diagnostic_Findings_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 16/34: P2-Spezialfeature-Inventur',10,1) WITH NOWAIT;
:r Integration/179_P2_Special_Feature_Inventory_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 17/34: P2-In-Memory-OLTP-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/180_P2_InMemory_Oltp_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 18/34: P2-Temporal-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/181_P2_Temporal_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 19/34: P2-Service-Broker-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/182_P2_Service_Broker_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 20/34: P2-Full-Text-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/183_P2_FullText_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 21/34: P2-Data-Capture-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/184_P2_Data_Capture_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 22/34: P2-Encryption-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/185_P2_Encryption_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 23/34: P2-Maintenance-Laufzeitvertrag',10,1) WITH NOWAIT;
:r Integration/186_P2_Maintenance_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 24/34: TABLE-Ausgabevertrag',10,1) WITH NOWAIT;
:r Integration/187_Table_Output_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 25/34: Ausgabe-Pilotvertrag',10,1) WITH NOWAIT;
:r Integration/188_Framework_Output_Pilot_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 26/34: Frameworkweiter Ausgabevertrag',10,1) WITH NOWAIT;
:r Integration/189_Framework_Output_Runtime_Contract.sql
:r Integration/190_Wave1_Output_Xml_Version_Runtime_Contract.sql
:r Integration/191_Wave2_Operational_Diagnostics_Runtime_Contract.sql
:r Integration/196_Analysis_Navigator_Runtime_Contract.sql
:r Integration/198_Runtime001_External_Runtime_CLR_Runtime_Contract.sql
:r Integration/122_DIAG004_Request_Context_Runtime_Contract.sql
:r Integration/199_CurrentState_Snapshot_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 27/34: Common',10,1) WITH NOWAIT;
:r Common/090_Test_und_Abnahme_Phase1A.sql

RAISERROR(N'RELEASE_GATE 28/34: Current State',10,1) WITH NOWAIT;
:r CurrentState/110_Test_und_Abnahme_Phase1B.sql

RAISERROR(N'RELEASE_GATE 29/34: Object und Index',10,1) WITH NOWAIT;
:r ObjectIndex/110_Test_und_Abnahme_Phase2.sql
:r ObjectIndex/120_SQL25_Vector_Index_Runtime_Contract.sql
:r ObjectIndex/121_SQL25_JSON_Index_Inventory_Runtime_Contract.sql
:r ObjectIndex/123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 30/34: Plan Cache',10,1) WITH NOWAIT;
:r PlanCache/110_Test_und_Abnahme_Phase3.sql
:r PlanCache/120_ExecutionPlanAnalysis_Runtime_Contract.sql
:r PlanCache/121_DIAG003_Parameter_Evidence_Runtime_Contract.sql
:r PlanCache/123_DIAG005_Plan_Optimizer_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 31/34: Query Store',10,1) WITH NOWAIT;
:r QueryStore/110_Test_und_Abnahme_Phase4.sql

RAISERROR(N'RELEASE_GATE 32/34: Extended Events',10,1) WITH NOWAIT;
:r ExtendedEvents/110_Test_und_Abnahme_Phase5.sql

RAISERROR(N'RELEASE_GATE 33/34: Infrastructure',10,1) WITH NOWAIT;
:r Infrastructure/110_Test_und_Abnahme_Phase6.sql
:r Infrastructure/122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql

RAISERROR(N'RELEASE_GATE 34/34: Server Health',10,1) WITH NOWAIT;
:r ServerHealth/110_Test_und_Abnahme_Phase7.sql

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],
       CAST(0 AS bit) AS [IsPartial],
       CAST(34 AS int) AS [ExecutedSuites],
       N'Alle Integrationsverträge und Bereichs-Smoke-Tests wurden ohne SQL-Fehler beendet.' AS [Detail];
GO
