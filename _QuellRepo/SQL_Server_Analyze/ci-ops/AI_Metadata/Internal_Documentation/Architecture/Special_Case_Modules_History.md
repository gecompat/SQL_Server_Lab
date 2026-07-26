# Spezialfallmodule: Evidenz, Kosten und Grenzen

Stand: 2026-07-18

## Ziel und Datenschutzgrenze

Die Spezialfallmodule sind rein lesende Diagnosebausteine. Sie verändern weder Resultsets noch OUTPUT-Werte zur Anonymisierung. Die Datenschutzregel gilt für persistierte Repository-, GitHub- und Downloadartefakte: Laufzeitwerte dürfen diagnostisch erscheinen, werden aber nicht als reale Beispieldaten, Testbelege oder Screenshots in das Repository übernommen.

Alle Beispiele verwenden ausschließlich generische Platzhalter. Die Procedures führen kein `DBCC CHECKDB`, keinen Restore, kein Failover, keine Reparatur und keine Konfigurationsänderung aus.

## Implementierte Reihenfolge

| Reihenfolge | Procedure | Evidenz | Standardkosten / Opt-in | Entscheidende Grenze |
|---:|---|---|---|---|
| P0.1 | `monitor.USP_DatabaseIntegrityAnalysis` | CHECKDB-Zeitstempel, suspect pages, zeitlich begrenzte Backupmetadaten, AG-Seitenreparatur | Metadaten LOW; Page-Auflösung opt-in | Leere Indikatoren beweisen keine Integrität |
| P0.2 | `monitor.USP_DatabaseCapacityAnalysis` | Datei- und Volumefreiraum, nächstes Growth, Maximum | Volume-/Dateimetadaten MEDIUM | Ohne Historie keine Zeit-bis-voll-Prognose |
| P0.3 | `monitor.USP_PerformanceCounters` | Countertyp, Basis, Snapshot oder Sample-Delta | Snapshot LOW; Sample 0–60 s | Unbekannte Countertypen bleiben roh und unbewertet |
| P0.4 | `monitor.USP_CriticalEngineEvents` | bestehendes `system_health`-Eventfile, optional One-Shot-Diagnostik | Eventfile MEDIUM; XML opt-in | Fehlende Historie wird nicht synthetisiert |
| P1.1 | `monitor.USP_IntelligentQueryProcessingAnalysis` | PSP/OPPO-Eignung, Query-Varianten, Plan Feedback, Automatic Tuning | Katalogabfrage LOW/MEDIUM | Anzahl von Feedbackzeilen bewertet keine Wirksamkeit |
| P1.2 | `monitor.USP_InternalContentionAnalysis` | Latch-/Spinlock-Deltas, aktuelle Seitenwaits | Sample opt-in; Page-Details opt-in | Korrelation ist keine Ursachenfeststellung |
| P1.3 | `monitor.USP_BufferPoolAnalysis` | Prozess-/OS-Speicher, Resource Semaphores, Clerks, optional Buffer-Pool-Verteilung | Basis LOW; Buffer-Scan opt-in HIGH | Momentaufnahme ist kein Trend und keine Konfigurationsempfehlung |
| P1.4 | `monitor.USP_BackupChainAnalysis` | Full-/Differentialbasis, Log-LSN, Recovery Forks, Checksums, Restorehistorie | `msdb`-Historie MEDIUM | Nur ein Test-Restore beweist Wiederherstellbarkeit |
| P1.5 | `monitor.USP_SchemaDesignAnalysis` | Constraints, FK-Stützindizes, Indexduplikate, Identity/Sequence | Cross-DB MEDIUM/HIGH | Jeder Befund ist ein Prüfauftrag, keine DDL-Anweisung |
| P1.6 | `monitor.USP_StatisticsDistributionAnalysis` | begrenzte Histogrammverteilung, Tail-Konzentration, Änderungen seit Statistikstand und inkrementelle Partitionsvariation | CATALOG_DEEP; maximal 1–250 Statistiken je Datenbank | Skew ist keine Planursache; Out-of-Range-Werte sind ohne Query-/Datenkontext nicht messbar |
| P1.7 | `monitor.USP_AvailabilityDeepAnalysis` | Replikas, Datenbewegung, Queues, Quorum, Seeding, Page Repair | Always-On-DMVs MEDIUM | Netzpfad, Clusterlog und Zeitverlauf fehlen |
| P1.8 | `monitor.USP_AgentMonitoringAnalysis` | Dienst, Alertabdeckung, Routing, Jobs, Mailstatus | `msdb`-Metadaten LOW/MEDIUM | Externes Monitoring kann fehlende Agentobjekte kompensieren |
| P1.9 | `monitor.USP_DiagnosticFindings` | normalisierte Triage aus den JSON-Verträgen der vorherigen Module | Kernmodule an; Schema/Statistikverteilung/IQP/Contention opt-in | Priorität und Konfidenz sind Triage, keine automatische Ursache |
| P2.1 | `monitor.USP_SpecialFeatureInventory` | aggregierte Nutzung oder reine Konfiguration von 18 Spezialfeatureklassen | LOW; reine sichtbare Systemkataloge | Inventar ist kein Gesundheitsurteil; Nullzählungen beweisen bei eingeschränkter Metadatensichtbarkeit keine Abwesenheit |
| P2.2 | `monitor.USP_InMemoryOltpAnalysis` | Tabellen-/Indexspeicher, Consumer, Hashketten, Checkpointzustände, aktive Transaktionen und Poolkontext | Basis MEDIUM; Hashketten HIGH_OPT_IN mit `CATALOG_DEEP` | Momentaufnahmen und Heuristiken beweisen weder Speicherdruck noch falsche DDL; Defaultpool ist nicht datenbankgenau zurechenbar |
| P2.3 | `monitor.USP_TemporalAnalysis` | Current-/History-Zuordnung, Periodenmetadaten, Retention-Schalter, approximative Kapazität und History-Indexbaseline | MEDIUM; Kataloge plus `sys.dm_db_partition_stats` | Keine Nutzdatenprüfung: weder Periodenüberlappungen noch Cleanup-Erfolg oder frühere Zuordnungen werden bewiesen |
| P2.4 | `monitor.USP_ServiceBrokerAnalysis` | Queue-Schalter und approximative Kapazität, interne Aktivierung, gruppierte Transmission- und Conversation-Zustände | MEDIUM; Kataloge, Broker-DMVs und `sys.dm_db_partition_stats` | Keine Queue-Nutzdaten oder Nachrichtenkörper; deaktivierte Queue und alte Metadaten beweisen weder Poison Message noch Ursache |
| P2.5 | `monitor.USP_FullTextAnalysis` | Kataloge, Indizes, aktuelle Populationen, aggregierte Batches, Fragmente, Semantik, Memory Pools und FDHosts | MEDIUM; Kataloge und Full-Text-DMVs | Keine Inhalte, Keywords, Stopwords, Schlüsselwerte, Crawl-Logs, Pfade oder DDL; DMVs sind keine Historie und Grenzwerte bleiben Heuristiken |
| P2.6 | `monitor.USP_DataCaptureDeepAnalysis` | CT-MinValidVersion gegen optionalen Consumer-Wasserstand, CDC-Capture/Cleanup und aggregierte lokale Replikationsagenten/-fehler | MEDIUM; Kataloge, CDC-DMVs, msdb und lokale Distribution | Keine Change-Zeilen, Replikationsbefehle, Fehlertexte, Credentials oder DDL; Remote Distributor bleibt explizite Evidenzlücke |
| P2.7 | `monitor.USP_EncryptionAnalysis` | TDE-Zustand, Scanfortschritt, sichtbarer Zertifikatlebenszyklus, explizite Backupverschlüsselung und aggregierte Always-Encrypted-/Ledger-Anzahlen | LOW/MEDIUM; Kataloge, DMV und begrenzte msdb-Sicht | Kein Schlüsselmaterial, keine Pfade, Signaturen, verschlüsselten Werte, Medien oder Konten; Restore bleibt externer Beweis |
| P2.8 | `monitor.USP_MaintenanceOperations` | resumierbare Indexoperationen, technische Wartungsrequests, ADR/PVS und explizit gefilterte Jobaktivität | MEDIUM; PVS-Detail ab SQL Server 2022 | Keine SQL-/Jobinhalte oder Identitätsdaten; keine Resume-, Abort-, Kill-, Cleanup- oder Jobaktion |

## Messverträge

- `@MaxZeilen > 0` begrenzt die Ausgabe; `NULL` oder `0` bedeutet unbegrenzt; negative Werte sind ungültig.
- `@ResultSetArt` akzeptiert `CONSOLE`, `RAW` und `NONE` case-insensitiv.
- Performance-Counter berechnen Raten, Prozentquotienten und Durchschnittsquotienten ausschließlich aus Intervall- und passenden Basisdeltas; ein Einzelwert wird dafür nicht als Rate ausgegeben.
- Das Contention-Modul unterscheidet `SAMPLE_DELTA` ausdrücklich von kumulativen Werten seit Serverstart und verwendet für Raten die tatsächliche Messdauer.
- Counter-Resets werden nicht in negative Raten umgerechnet, sondern als Reset ausgewiesen.
- Die Statistikverteilungsanalyse begrenzt Kandidaten vor dem Histogrammzugriff. Dominanz-, Equal-/Range-Skew-, Tail-, Modification- und Partitionsindikatoren bleiben konfigurierbare Prüfhinweise.
- Featureabhängige Katalogsichten werden erst in dynamische Batches aufgenommen, wenn die Produktversion sie unterstützt.
- Die Spezialfeature-Inventur liest keine externen Locations, Connection Options, Credentials, Service-Broker-Payloads, CLR-Binaries, Moduldefinitionen oder Benutzertabellen. `CONFIGURED_ONLY` beweist keine tatsächliche Nutzung.
- Die In-Memory-OLTP-Analyse ruft jede DMV isoliert auf. `sys.dm_db_xtp_hash_index_stats` ist wegen möglicher vollständiger Tabellenscans standardmäßig aus; Checkpoint-Pfade, Container-GUIDs, SQL-Texte sowie Session-, Benutzer- und Transaktionskennungen werden nicht gelesen.
- Die Temporal-Tables-Analyse liest keine Current- oder History-Zeilen. Die dokumentierte Indexbaseline Periodenende/Periodenstart ist ein Prüfhinweis, kein automatischer DDL-Vorschlag. `SYSTEM_VERSIONING=OFF` trennt die Tabellen; ohne erhaltene Metadatenzuordnung darf das Modul daraus kein ehemaliges Paar erraten.
- Die Service-Broker-Analyse liest keine Queue-Nutzdaten und referenziert die Nachrichtenkörperspalte nicht. `sys.transmission_queue` wird nur nach nicht-payloadhaltigen Metadaten gruppiert; Conversation-Handles, Gruppen-IDs und Schlüsselkennungen werden nicht ausgegeben. Ein deaktiviertes RECEIVE kann Folge der automatischen Poison-Message-Erkennung oder einer manuellen Konfiguration sein und wird deshalb nie als Ursachenbeweis bezeichnet.
- Die Data-Capture-Tiefenanalyse behauptet CT-Synchronisationsverlust nur mit einem expliziten Consumer-Wasserstand. CDC-Scan-DMVs und Agenthistorien sind begrenzte Momentaufnahmen. Eine Remote- oder unzugängliche Distribution wird nie als gesund bewertet. Change-Zeilen, Replikationscommands, Fehlertexte, Credentials und Agentjob-Commands bleiben ausgeschlossen.
- Die Verschlüsselungsanalyse trennt TDE von expliziter Backupverschlüsselung. Zertifikatablauf und lokaler Exportzeitpunkt sind Lebenszyklusevidenz, kein Beweis über extern vorhandene Schlüsselkopien. Always-Encrypted- und Ledger-Kataloge werden nur aggregiert.
- Die Wartungsanalyse liest die Agentquelle nur bei explizitem Namensfilter. Pausen, Laufdauer und PVS-Größe bleiben Kontext; das Modul verändert keine Operation und liest keine SQL-, Job-, Identitäts- oder Clientinhalte.
- `USP_DiagnosticFindings` benötigt Compatibility Level 130 oder höher, weil `OPENJSON` den Vertragsinhalt aggregiert.

## Befundvertrag

`USP_DiagnosticFindings` ruft Kindmodule mit `@ResultSetArt='NONE'` und `@JsonErzeugen=1` auf. Innerhalb eines `USP_ServerHealthAnalysis`-Laufs verwendet es bereits erhobene Integritäts-, Kapazitäts- und Buffer-Pool-Ergebnisse bei gleichem Scope erneut; ohne Parent-Ergebnis liest es frisch. `InvocationStatus=REUSED_PARENT_RESULT` trennt Wiederverwendung von einer Child-Ausführung. Übernommen werden nur definierte Felder wie Befundcode, Messwert, Scope, Evidenzgrenze und Status. Nicht übernommen werden SQL-/Plantexte, Event-XML, Dateipfade, Mailinhalte oder freie Meldungstexte.

Jeder normalisierte Befund enthält Quelle, Kategorie, Priorität, Konfidenz, technischen Scope, stabilen Befundcode, begrenzten Messwert, Aussagegrenze und nächste kontrollierte Prüfung.

## Test- und Freigabestatus

Der Codebestand besitzt Help-, Installer-, Objekt-, Parameter-, Smoke- und Spezialfall-API-Verträge. Commit `40d54fdc195b5cfa0015e2cbe281da595e427ab0` weist alle 181 P0-/P1-/P2-Fälle in 31 Suiten auf SQL Server 2019, 2022 und 2025 nach. Zusätzliche Plattform-, Last- und externe Evidence bleibt getrennt.

## Primärquellen

- [DBCC CHECKDB](https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql)
- [suspect_pages](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/manage-the-suspect-pages-table-sql-server)
- [sys.dm_db_page_info](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-page-info-transact-sql)
- [sys.dm_os_volume_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-volume-stats-transact-sql)
- [sys.dm_os_performance_counters](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql)
- [sp_server_diagnostics](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-server-diagnostics-transact-sql)
- [sys.query_store_query_variant](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-query-variant)
- [sys.query_store_plan_feedback](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-plan-feedback)
- [sys.dm_db_tuning_recommendations](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-tuning-recommendations-transact-sql)
- [sys.dm_os_latch_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-latch-stats-transact-sql)
- [sys.dm_os_spinlock_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-spinlock-stats-transact-sql)
- [sys.dm_os_buffer_descriptors](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-descriptors-transact-sql)
- [sys.dm_db_stats_histogram](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-histogram-transact-sql)
- [sys.dm_db_incremental_stats_properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-incremental-stats-properties-transact-sql)
- [backupset](https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/backupset-transact-sql)
- [Always-On-DMVs](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/monitor-availability-groups-transact-sql)
- [SQL Server Agent Alerts](https://learn.microsoft.com/en-us/sql/ssms/agent/alerts)
- [sys.tables](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-tables-transact-sql)
- [sys.columns](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-columns-transact-sql)
- [sys.external_tables](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-tables-transact-sql)
- [Work with Change Tracking](https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/work-with-change-tracking-sql-server)
- [sys.dm_cdc_log_scan_sessions](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/change-data-capture-sys-dm-cdc-log-scan-sessions)
- [MSdistribution_status](https://learn.microsoft.com/en-us/sql/relational-databases/system-views/msdistribution-status-transact-sql)
- [sys.external_languages](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-languages-transact-sql)
- [sys.assemblies](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-assemblies-transact-sql)
- [sys.dm_db_xtp_table_memory_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-table-memory-stats-transact-sql)
- [sys.dm_db_xtp_hash_index_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-xtp-hash-index-stats-transact-sql)
- [Hashindizes für speicheroptimierte Tabellen](https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/hash-indexes-for-memory-optimized-tables)
- [sys.dm_db_xtp_checkpoint_files](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-checkpoint-files-transact-sql)
- [Resource-Pool-Bindung für In-Memory OLTP](https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/bind-a-database-with-memory-optimized-tables-to-a-resource-pool)
- [Temporal Tables](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables)
- [Temporal-Retention](https://learn.microsoft.com/en-us/sql/relational-databases/tables/manage-retention-of-historical-data-in-system-versioned-temporal-tables)
- [Temporal-Einschränkungen und Indexbaseline](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-table-considerations-and-limitations)
- [sys.transmission_queue](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-transmission-queue-transact-sql)
- [sys.service_queues](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-service-queues-transact-sql)
- [sys.dm_broker_queue_monitors](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-queue-monitors-transact-sql)
- [sys.dm_broker_activated_tasks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-activated-tasks-transact-sql)
- [sys.conversation_endpoints](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-conversation-endpoints-transact-sql)
- [Poison Messages entfernen](https://learn.microsoft.com/en-us/sql/database-engine/service-broker/removing-poison-messages)
- [sys.dm_database_encryption_keys](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-database-encryption-keys-transact-sql)
- [Transparent Data Encryption](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption)
- [sys.index_resumable_operations](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-index-resumable-operations)
- [sys.dm_exec_requests](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [sys.dm_tran_persistent_version_store_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-persistent-version-store-stats?view=sql-server-ver17)
