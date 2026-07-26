# Versionsadaptive und spezialisierte Analysepfade

**Procedures:** 9
**Evidenz:** Version, Plattform, sichtbare Kataloge, Spezialfeature-Metadaten und isolierte Runtime-DMVs  
**Kosten:** LOW bis HIGH_OPT_IN

## Grundregeln

- SQL-Server-Hauptversion allein beweist nicht, dass ein Feature auf Edition, Plattform, Build, CU, Compatibility Level oder in einer konkreten Datenbank verfügbar ist.
- Katalogobjekterkennung ist belastbarer als hart codierte Versionsannahmen, bleibt aber berechtigungsabhängig.
- `NOT_DETECTED_VISIBLE_SCOPE` bedeutet nur „im sichtbaren Metadatenscope nicht gefunden“.
- Feature-Inventar ist kein Healthcheck.
- In-Memory-, Temporal-, Service-Broker-, Full-Text- und Data-Capture-/Replikations-Findings verwenden konfigurierbare Framework-Heuristiken und führen keine DDL aus.

---

## 1. [monitor].[USP_ServerFeatureCapabilities]

### Zweck

Die Procedure ermittelt versions- und plattformabhängige Diagnosefähigkeiten auf Server- und Datenbankebene. Zusätzlich können Spezialindizes und Query-Store-Replica-Funktionen inventarisiert werden.

### Auswahlhinweis

`N''` und `NULL` schränken den Datenbankscope nicht ein. Ohne explizite Liste
oder Pattern werden alle sichtbaren Online-Benutzerdatenbanken verarbeitet;
Systemdatenbanken bleiben opt-in. Prüfen Sie bei produktiver Automatisierung den Status und
die Warnungen für explizit nicht verfügbare Datenbanken.

### Aufrufe

```sql
EXEC [monitor].[USP_ServerFeatureCapabilities]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'RAW';
```

```sql
EXEC [monitor].[USP_ServerFeatureCapabilities]
      @DatabaseNames = NULL,
      @MitSpezialindizes = 1,
      @MitQueryStoreReplicas = 1,
      @MitPlattformdetails = 1,
      @ResultSetArt = 'RAW';
```

### Capabilities

| Spalte | Bedeutung |
|---|---|
| `ScopeName` | `SERVER` oder anderer Scope |
| `FeatureName` | stabiler Featurecode |
| `AvailabilityStatus` | `AVAILABLE`, `UNAVAILABLE_VERSION`, `UNAVAILABLE_PLATFORM` oder weitere Statuswerte |
| `LogicPath` | verwendete oder empfohlene Erkennungs-/Fallbacklogik |
| `MinimumKnownMajorVersion` | bekannte Mindesthauptversion |
| `SourceObject` | Katalog-/Metadatenquelle |
| `Detail` | fachliche Einordnung |
| `RequiredPermission` | benötigte Berechtigung |

### DatabaseFeatures

`DatabaseName`, `CompatibilityLevel`, `StateDesc`, `FeatureName`, `AvailabilityStatus`, `FeatureValue`, `LogicPath`, `Detail`.

Beispielhafte Features:

- `OPTIMIZED_LOCKING`
- `QUERY_STORE_READABLE_SECONDARY`
- `JSON_INDEX_METADATA`
- weitere im Build erkannte datenbankbezogene Fähigkeiten.

### SpecialIndexes

`DatabaseName`, `SchemaName`, `ObjectName`, `IndexName`, `IndexFamily`, `IndexDetails`, `AvailabilityStatus`.

Die genaue Indexgruppe ist versionsabhängig. Das Resultset ist ein Inventar, kein Performanceurteil.

Für `IndexFamily = JSON` enthält `IndexDetails` nur Array-Suchoption,
Pfadanzahl und Disabled-Status. Konkrete SQL/JSON-Pfade liefert der enger
gefilterte Pfad `USP_ObjectInventory`. Beide Wege prüfen
`sys.json_indexes` und `sys.json_index_paths` vor der Referenz und lesen keine
JSON-Dokumentwerte.

### Errors

`DatabaseName`, `ModuleName`, `ErrorNumber`, `ErrorMessage`.

### Serverfeatures im aktuellen Code

| Feature | Interpretation |
|---|---|
| `PERFORMANCE_STATE_PERMISSION` | ab SQL Server 2022 wird für viele Performance-DMVs `VIEW SERVER PERFORMANCE STATE` ausgewiesen, davor `VIEW SERVER STATE` |
| `ZSTD_BACKUP_COMPRESSION` | SQL Server 2025 unterstützt ZSTD als Backupkompressionsalgorithmus; CPU-/Durchsatzwirkung trotzdem testen |
| `RESOURCE_GOVERNOR_STANDARD_EDITION` | SQL Server 2025 erweitert Editionsverfügbarkeit; reale Katalog- und Editionsprüfung bleibt nötig |
| Linux Host Stats | Linux-spezifische DMVs werden nur bei Linux und vorhandenem Systemobjekt als verfügbar markiert |
| Optimized Locking | Datenbankeigenschaft; mit ADR, RCSI und Workload interpretieren |
| Query Store Readable Secondary | SQL Server 2025-/Plattformfunktion; Katalogsicht `sys.query_store_replicas` ist maßgeblich |

### Interpretation

- `AVAILABLE` heißt: Diagnosepfad/Katalog ist nach Erkennung verfügbar. Es heißt nicht, dass das Feature aktiviert, genutzt oder gesund ist.
- `UNAVAILABLE_VERSION` kann auch bedeuten, dass das erwartete Systemobjekt auf diesem Build nicht existiert.
- `UNAVAILABLE_FEATURE`, `UNAVAILABLE_SOURCE_SCHEMA` und
  `AVAILABLE_LIMITED` halten die buildabhängige SQL-Server-2025-Previewgrenze
  der JSON-Indexkataloge explizit.
- `FeatureValue` muss featurebezogen interpretiert werden; Textwerte sind nicht global vergleichbar.
- Optimized Locking kann Lockmemory und bestimmte Blockierungen reduzieren, beseitigt aber nicht jeden Lockkonflikt.
- Query Store für lesbare Secondaries schreibt Ausführungsinformationen zum primären Query Store zurück; Replica-Dimensionen müssen in Auswertungen berücksichtigt werden.
- ZSTD kann schnellere und bessere Kompression bieten, erhöht aber wie andere Kompression CPU-Verbrauch und muss gegen Concurrent Workload getestet werden.

### Folgeanalyse

- In-Memory gefunden → `USP_InMemoryOltpAnalysis`
- Temporal gefunden → `USP_TemporalAnalysis`
- Service Broker gefunden → `USP_ServiceBrokerAnalysis`
- Full-Text gefunden → `USP_FullTextAnalysis`
- Change Tracking oder CDC gefunden → `USP_DataCaptureDeepAnalysis`
- Wenn eine Query-Store-Replica verfügbar ist, berücksichtigen Sie in den Query-Store-Guides die Replica Group.
- Spezialindex → passende Objekt-/Plananalyse
- JSON-Indexmetadaten → `USP_ObjectInventory`; Präsenz und Pfadzahl sind kein Health- oder Rebuildbefund

### Kosten

LOW bis MEDIUM. Cross-Database-Katalogzugriffe und optionales Spezialindexinventar; keine Benutzerdatenscans.

---

## 2. [monitor].[USP_SpecialFeatureInventory]

### Zweck

Die Procedure erstellt eine aggregierte Nutzungsinventur sichtbarer Spezialfeatures mit begrenzter Quellarbeit. Sie liest keine externen Locations, Credentials, Broker-Payloads, CLR-Binaries, Moduldefinitionen oder Benutzerdaten.

### Erkannte Featuregruppen

- In-Memory OLTP
- System-versioned Temporal Tables
- Service Broker
- Full-Text
- Change Tracking
- Change Data Capture
- Verschlüsselung/Always Encrypted/TDE-Metadaten
- CLR
- External Tables/Data Sources
- External Languages/Libraries
- FILESTREAM/FileTable
- Graph
- Spatial
- XML
- native JSON-/Vector-Typen, soweit versionsseitig sichtbar
- benutzerdefinierte Typen

### Aufrufe

```sql
EXEC [monitor].[USP_SpecialFeatureInventory]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'RAW';
```

```sql
EXEC [monitor].[USP_SpecialFeatureInventory]
      @DatabaseNames = NULL,
      @NurErkannteFeatures = 1,
      @ResultSetArt = 'RAW';
```

### DatabaseStatus

| Spalte | Bedeutung |
|---|---|
| `DatabaseName` | Scope |
| `StatusCode`, `IsPartial` | Auswertbarkeit |
| `FeatureRows` | erzeugte Featureinventarzeilen |
| `DetectedFeatureRows` | Zeilen mit erkannter Nutzung/Konfiguration |
| `ErrorNumber`, `ErrorMessage` | behandelter Fehler |
| `Detail` | Aussagegrenze |

### FeatureInventory

| Spalte | Bedeutung |
|---|---|
| `DatabaseName` | Datenbank |
| `FeatureCode` | stabiler technischer Code |
| `FeatureFamily` | lesbare Featuregruppe |
| `DetectionStatus` | etwa erkannt, nicht im sichtbaren Scope erkannt oder versionell nicht verfügbar |
| `DetectedItemCount` | aggregierte Anzahl von Metadatenobjekten/-signalen |
| `ConfigurationState` | Featurekonfiguration, sofern sinnvoll |
| `SourceObjects` | verwendete Systemkataloge |
| `RecommendedModule` | passendes Deep-Dive-Modul |
| `RecommendedModuleStatus` | verfügbar, nicht implementiert oder nicht anwendbar |
| `EvidenceLimit` | explizite Grenze |

### Interpretation

- Zähler verschiedener Features sind nicht untereinander vergleichbar. Bei Service Broker können Queue, Service und Enablement in eine Zahl einfließen; bei Temporal primär aktuelle Tabellen.
- `DetectedItemCount=0` kann fehlende Sichtbarkeit bedeuten.
- Konfiguriert, aber ohne Objekt ist ein anderer Zustand als aktiv genutzt.
- External Scripts enabled ohne externe Bibliothek kann Vorbereitungs- oder Altzustand sein.
- Database Encryption Flag, Always-Encrypted-Schlüsselmetadaten und verschlüsselte Spalten sind unterschiedliche Technologien, die in einer Featuregruppe zusammengefasst werden können.
- `@NurErkannteFeatures=1` verbessert die Lesbarkeit, entfernt aber die explizite Information über nicht erkennbare oder nicht verfügbare Featuregruppen.
- Sichtbare native Vector-Spalten verweisen auf `USP_VectorIndexAnalysis`; erst dieses Modul prüft vorhandene Vector-Indizes und ihre aktuelle Wartungsevidenz.
- Sichtbare native JSON-Spalten verweisen auf `USP_ObjectInventory`; dort
  werden capability-adaptiv JSON-Index- und Pfadmetadaten inventarisiert,
  ohne JSON-Dokumentwerte zu lesen oder eine automatische Healthaussage zu
  erzeugen.

### Plakative und grenzwertige Beispiele

| Befund | Bewertung |
|---|---|
| Temporal erkannt, 500 Tabellen | Deep-Dive und Retention-/Kapazitätsstrategie priorisieren |
| Broker enabled, keine benutzerdefinierten Queues | möglicherweise nur Konfiguration, nicht aktive Nutzung |
| CLR Assembly Count 1 | Sicherheits-/Supportreview, nicht automatisch Risiko |
| Native Vector `UNAVAILABLE_VERSION` | erwartbar vor unterstützter Version |
| 0 Full-Text-Objekte bei eingeschränkter Metadatensicht | keine belastbare Abwesenheitsaussage |

### Folgeanalyse

Verwenden Sie das angegebene `RecommendedModule`. Für `VECTOR` ist `USP_VectorIndexAnalysis` implementiert und versionsadaptiv. Für `JSON` ist der bestehende `USP_ObjectInventory`-Pfad implementiert; eine eigene JSON-Index-Procedure ist für den abgegrenzten Inventarumfang nicht erforderlich. Beide Inventare sind keine Indexgesundheitsbefunde. Wenn ein anderes Deep-Dive-Modul fehlt, müssen Quelle und Betriebsanforderung manuell geprüft werden.

### Kosten

LOW. Aggregierte Systemkatalogabfragen, kein Daten- oder Definitionsscan.

---

## 3. [monitor].[USP_InMemoryOltpAnalysis]

### Zweck

Die Procedure führt eine Best-Effort-Tiefenanalyse der sichtbaren In-Memory-OLTP-Konfiguration und der Runtimeevidenz zu Tabellen- und Indexmemory, Hashindizes, Memory Consumers, Checkpoint Files, aktiven Transaktionen und Resource Pools durch.

### Framework-Schwellen

| Parameter | Default | Bedeutung |
|---|---:|---|
| `@MinTableMemoryMb` | 1024 | große Tabelle/Indexmemory zur Sichtung |
| `@HashAvgChainWarn` | 10 | durchschnittliche Hashchain |
| `@HashMaxChainWarn` | 100 | maximale Hashchain |
| `@HashMinEmptyBucketPercent` | 10 | sehr geringe Leerbucketquote |
| `@WaitingCheckpointWarnMb` | 1024 | Checkpointfiles in wartendem Zustand |
| `@ActiveTransactionWarnCount` | 100 | aktive XTP-Transaktionen |
| `@PoolUsedWarnPercent` | 80 | Resource-Pool-Auslastung relativ zum Target |

Diese Schwellen sind heuristische Prüfgrenzen, keine automatische Bucket-, Memory- oder Poolbemessung.

### Statusresultsets

#### DatabaseStatus

`DatabaseName`, `StatusCode`, `IsPartial`, `MemoryOptimizedTableCount`, `MemoryOptimizedTableTypeCount`, `MemoryOptimizedFilegroupCount`, `SourceFailureCount`, `FindingCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

#### SourceStatus

`DatabaseName`, `SourceCode`, `StatusCode`, `IsPartial`, `RowCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

Jede Runtime-DMV wird separat behandelt. Ein partieller Hashindexstatus darf Table-Memory- oder Checkpointevidenz nicht entwerten.

### TableMemory

`DatabaseName`, `SchemaName`, `TableName`, `ObjectId`, `DurabilityDesc`, `TableAllocatedMb`, `TableUsedMb`, `IndexAllocatedMb`, `IndexUsedMb`, `TotalAllocatedMb`, `TotalUsedMb`, `UsedPercent`, `Severity`, `FindingCode`, `EvidenceLimit`.

### HashIndex

`DatabaseName`, `SchemaName`, `TableName`, `IndexName`, `ObjectId`, `IndexId`, `ConfiguredBucketCount`, `TotalBucketCount`, `EmptyBucketCount`, `EmptyBucketPercent`, `AverageChainLength`, `MaxChainLength`, `RuntimeStatsStatus`, `Severity`, `FindingCode`, `EvidenceLimit`.

`@MitHashIndexStats=1` ist HIGH_OPT_IN und benötigt `CATALOG_DEEP`, weil `sys.dm_db_xtp_hash_index_stats` laut Hersteller vollständige Tabellenarbeit verursachen kann.

### MemoryConsumer

`DatabaseName`, `MemoryConsumerType`, `MemoryConsumerDesc`, `ConsumerCount`, `AllocationCount`, `AllocatedMb`, `UsedMb`, `UsedPercent`, `EvidenceLimit`.

### Checkpoint

`DatabaseName`, `FileType`, `FileTypeDesc`, `State`, `StateDesc`, `FileCount`, `FileSizeMb`, `FileUsedMb`, `LogicalRowCount`, `Severity`, `FindingCode`, `EvidenceLimit`.

Checkpointfiles sind append-only Data- und Delta-Strukturen und durchlaufen mehrere legitime Zustände. `WAITING FOR LOG TRUNCATION` ist nicht automatisch ein Fehler; prüfen Sie Logtrunkierung, Merge- und Recoverybedarf sowie die Dauer.

### Transaction

`DatabaseName`, `TransactionState`, `TransactionStateDesc`, `ResultDesc`, `TransactionCount`, `Severity`, `FindingCode`, `EvidenceLimit`.

Es werden bewusst keine realen Transaktions-IDs ausgegeben.

### ResourcePool

`DatabaseName`, `ResourcePoolId`, `ResourcePoolName`, `IsDefaultOrUnbound`, `DatabasesUsingPool`, `MinMemoryPercent`, `MaxMemoryPercent`, `MaxMemoryMb`, `TargetMemoryMb`, `UsedMemoryMb`, `UsedPercentOfTarget`, `OutOfMemoryCount`, `Severity`, `FindingCode`, `EvidenceLimit`.

### Findings

`FindingOrdinal`, Scope, `Severity`, `Confidence`, `FindingCode`, `MetricName`, `MetricValue`, `ThresholdValue`, `Evidence`, `EvidenceLimit`, `RecommendedNextCheck`.

### Interpretation

| Konstellation | Bewertung |
|---|---|
| hohe TableMemory, stabiler Pool, keine OOMs | groß, aber nicht automatisch problematisch |
| durchschnittliche Chain 15, Max 20, workload hauptsächlich point lookup | Bucketreview sinnvoll |
| Max Chain 1000 durch einzelnen Extremwert, Avg 1.2 | Skew-/Schlüsseldistribution prüfen, nicht nur Maxwert |
| EmptyBucketPercent 1 % | Bucketzahl möglicherweise zu klein oder Verteilung ungleich |
| EmptyBucketPercent 99 % | stark überdimensioniert möglich; Memorykosten prüfen |
| viele Checkpointfiles WAITING FOR LOG TRUNCATION | Log-/Backup-/AG-Kontext prüfen |
| PoolUsed 90 %, keine Pressureflags | Watchlist, Verlauf und Growthplan |
| `OutOfMemoryCount>0` | historisch relevante Pressureevidenz; Reset-/Zeitkontext ergänzen |

### Aussagegrenzen

- Runtimewerte sind Momentaufnahmen oder kumulativ seit Restart/Objekterstellung.
- Hashchainqualität hängt von Schlüsselverteilung und Zugriffsmuster ab.
- Resource-Pool-Auslastung allein ist keine Max-Memory-Empfehlung.
- Checkpointfiles werden aggregiert; Dateipfade werden absichtlich nicht gelesen.
- Memory-optimized Table Types können Nutzung erzeugen, ohne dauerhafte Tabelle.

### Folgeanalyse

Query-/XTP-Indexnutzung, aktuelle Grants/Memory, Resource Governor, Log-/Backupstatus und Wiederholungsmessung.

---

## 4. [monitor].[USP_TemporalAnalysis]

### Zweck

Die Procedure analysiert sichtbare system-versioned Temporal Tables, Current-/History-Zuordnung, Periodenspalten, Retentionkonfiguration, approximative Größe/Zeilenzahl und die Indexreihenfolge der History-Tabelle.

Es werden keine aktuellen oder historischen Benutzertabellenzeilen gelesen.

### Framework-Schwellen

| Parameter | Default |
|---|---:|
| `@HistorySizeWarnMb` | 10.240 MB |
| `@HistoryRowsWarn` | 10.000.000 |
| `@HistoryToCurrentRatioWarn` | 10 |
| `@MinHistoryMbForRatioWarn` | 100 MB |

### Statusresultsets

#### DatabaseStatus

`DatabaseName`, `StatusCode`, `IsPartial`, `TemporalTableCount`, `HistoryTableCount`, `SourceFailureCount`, `FindingCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

#### SourceStatus

`DatabaseName`, `SourceCode`, `StatusCode`, `IsPartial`, `RowCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

### TemporalTable

| Gruppe | Spalten |
|---|---|
| Current | `DatabaseName`, `CurrentSchemaName`, `CurrentTableName`, `CurrentObjectId`, `CurrentIsMemoryOptimized`, `CurrentDurabilityDesc` |
| History | `HistorySchemaName`, `HistoryTableName`, `HistoryObjectId` |
| Period | `PeriodStartColumnName`, `PeriodEndColumnName`, `PeriodStartIsHidden`, `PeriodEndIsHidden` |
| Retention | `DatabaseRetentionEnabled`, `HistoryRetentionPeriod`, `HistoryRetentionUnitDesc`, `RetentionMode` |
| Kapazität | `CurrentRowsApprox`, `HistoryRowsApprox`, `CurrentReservedMb`, `CurrentUsedMb`, `HistoryReservedMb`, `HistoryUsedMb`, `HistoryToCurrentRowRatio` |
| Index | `HistoryIndexCount`, `HasPeriodLeadingHistoryIndex` |
| Bewertung | `AssessmentStatus`, `EvidenceLimit` |

### HistoryIndex

`DatabaseName`, Current-/History-Scope, `IndexName`, `IndexId`, `IndexTypeDesc`, `IsUnique`, `IsDisabled`, `FirstKeyColumnName`, `SecondKeyColumnName`, `IsPeriodLeadingIndex`, `EvidenceLimit`.

Ein Period-leading History-Index wird anhand der erwarteten Reihenfolge **Period End, Period Start** bewertet. Andere Zugriffsmuster können zusätzliche Indizes benötigen.

### Findings

`FindingOrdinal`, Current-/History-Scope, `Severity`, `Confidence`, `FindingCode`, `MetricName`, `MetricValue`, `ThresholdValue`, `Evidence`, `EvidenceLimit`, `RecommendedNextCheck`.

### Interpretation

| Konstellation | Bewertung |
|---|---|
| History 20× Current, aber nur 50 MB | Ratio über Schwelle, durch Mindestgröße eventuell absichtlich nicht gewarnt |
| History 2 TB, Ratio 2 | absolute Kapazität relevant trotz moderatem Verhältnis |
| Retention OFF und update-/delete-intensive Tabelle | unbegrenztes Wachstum möglich; fachliche Aufbewahrung klären |
| Retention ON | beweist keinen erfolgreichen Cleanup |
| kein Period-leading Index | Temporal-Abfragen/Cleanup können leiden; bestehende alternative Indizes und Workload prüfen |
| HistoryIndex disabled | klarer Reviewfall |
| Hidden Period Columns | normal und oft erwünscht |
| Current memory-optimized | spezielle Kombination; Feature-/Versiongrenzen beachten |

### Aussagegrenzen

- Größen/Zeilen stammen approximativ aus Partitionsstatistiken.
- Kein Datenscan: Periodenüberlappungen, ungültige Fachzeiten oder Cleanupfortschritt werden nicht bewiesen.
- Nach `SYSTEM_VERSIONING=OFF` kann die frühere Paarbeziehung verloren sein und wird nicht zuverlässig rekonstruiert.
- Retention Policy muss fachliche und rechtliche Anforderungen erfüllen; Größe allein bestimmt sie nicht.
- Eine große History-Tabelle kann sowohl Storagekosten als auch Temporal-Querykosten erhöhen.

### Folgeanalyse

Kapazität, Index Usage/Physical Stats, Query Store für Temporal Queries, Partitionierungs-/Retentionstrategie und Cleanupmonitoring.

---

## 5. [monitor].[USP_ServiceBrokerAnalysis]

### Zweck

Die Procedure analysiert sichtbare Service-Broker-Konfiguration und gruppierte Betriebsevidenz zu Queues, interner Aktivierung, Transmission Queue und Conversation Endpoints. Queue-Nutzdaten, Nachrichtenkörper und Conversation-Handles werden nicht gelesen.

### Framework-Schwellen

| Parameter | Default | Bedeutung |
|---|---:|---|
| `@TransmissionAgeWarnMinutes` | 60 | Alter des ältesten gruppierten Transmission-Eintrags |
| `@TransmissionRowsWarn` | 1.000 | gruppierte Nachrichtenanzahl als Reviewkontext |
| `@QueueRowsWarn` | 10.000 | approximative Queue-Zeilen als Kapazitätskontext |
| `@ActivationSilenceWarnMinutes` | 60 | Zeit seit letzter Aktivierung bei sichtbarem Rückstand |
| `@ConversationRowsWarn` | 100.000 | sichtbare Conversation Endpoints als Wachstumskontext |

Die Schwellen priorisieren eine manuelle Prüfung. Sie beweisen weder Zustellfehler noch fehlerhafte Kapazität oder eine Poison Message.

### Statusresultsets

#### DatabaseStatus

`DatabaseName`, `StatusCode`, `IsPartial`, `IsBrokerEnabled`, `UserQueueCount`, `UserServiceCount`, `TransmissionMessageCount`, `ConversationEndpointCount`, `SourceFailureCount`, `FindingCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

#### SourceStatus

`DatabaseName`, `SourceCode`, `StatusCode`, `IsPartial`, `RowCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

Feature-Gate, Queue-Katalog, Kapazität, Queue-Monitor, aktivierte Tasks, Transmission und Conversations werden isoliert bewertet. Eine fehlende DMV-Berechtigung entwertet zugängliche Kataloge nicht.

### Queues

`DatabaseName`, Queue-Scope, Serviceanzahl, Broker-/Queue-Schalter, Aktivierungsprozedur, Ausführungskontext, approximative Zeilen-/Seitenevidenz, Monitorzustand, Aktivierungszeitpunkte, wartende Receiver, aktive Tasks, `AssessmentStatus`, `EvidenceLimit`.

`QueueRowsApprox` stammt aus Partitionsstatistiken. Der Wert enthält keine Aussage zu Alter, Durchsatz, Priorität oder fachlich zulässigem Rückstand.

### TransmissionGroups

Gruppiert werden nicht-payloadhaltige Service-, Ziel-, Contract-, Message-Type-, Status-, Mengen- und Zeiteigenschaften. Eine Zeile in `sys.transmission_queue` ist nicht automatisch ein Fehler: Zustellung, Bestätigung und Retention können Einträge vorübergehend erhalten.

### ConversationStates

Conversation Endpoints werden nach Zustand, Initiator-/Systemflag und Lifetime aggregiert. Handles, Gruppen-IDs, Schlüsselkennungen und Nachrichteninhalt bleiben ausgeschlossen.

### Findings

Wichtige Reviewcodes sind deaktivierte Queue-Schalter, Aktivierungsstillstand bei sichtbarem Rückstand, Transmission-Status oder -Alter, Conversation-Errorzustand, abgelaufene Lifetime und isolierte Evidenzlücken.

### Interpretation

| Konstellation | Bewertung |
|---|---|
| `is_receive_enabled=0` | kann nach wiederholten Rollbacks automatisch oder manuell entstehen; Ursache separat belegen |
| Queue-Zeilen hoch, Monitor `RECEIVES_OCCURRING` | Rückstand vorhanden, aber Verarbeitung sichtbar; Trend und Durchsatz prüfen |
| Queue-Zeilen hoch, keine aktiven Tasks | nur bei vollständiger Monitor-/Taskevidenz ein belastbarer Aktivierungs-Reviewfall |
| Transmission-Status gefüllt | konkrete Transport-/Routingevidenz; Ziel, Route, Endpunkt, Zertifikate und Fehlerlog korrelieren |
| Transmission ohne Status | nicht automatisch gesund oder fehlerhaft; Alter und Verlauf ergänzen |
| viele Endpoints | kann legitime langlebige Dialoge oder unvollständigen Dialogabschluss bedeuten |
| Retention aktiviert | erklärt erhaltene Queue-Zeilen und ist kein Fehlerbefund |

### Aussagegrenzen

- Queue-Monitor und aktivierte Tasks sind Momentaufnahmen.
- Eingeschränkte Metadatensichtbarkeit kann einen scheinbaren Leerzustand erzeugen.
- Ein deaktiviertes RECEIVE beweist keine Poison Message.
- Das Modul liest keine Queue-Nutzdaten und führt kein `RECEIVE`, `ALTER QUEUE` oder `END CONVERSATION` aus.
- Kapazitäts-, Routing- und Bereinigungsmaßnahmen benötigen Zeitverlauf, Anwendungs- und Betriebskontext.

### Folgeanalyse

Korrelieren Sie das SQL-Fehlerlog beziehungsweise freigegebene Extended Events mit Routing- und Endpunktkonfiguration, Zertifikaten, Readerdurchsatz, Anwendungstransaktionen und wiederholten Messungen. Exportieren und übermitteln Sie Laufzeitevidenz mit realen Namen oder Inhalten nur kontrolliert.

---

## 6. [monitor].[USP_FullTextAnalysis]

### Zweck

Die Procedure analysiert sichtbare Full-Text-Kataloge und -Indizes sowie aktuelle Populationen, ausstehende Batches, querybare Fragmente, semantische Ähnlichkeitspopulationen und serverweiten Gatherer-/FDHost-Kontext. Tabelleninhalte, Keywords, Stopwords, Parser-Eingaben, Schlüsselwerte, Crawl-Logs und Pfade bleiben ausgeschlossen.

### Framework-Schwellen

| Parameter | Default | Bedeutung |
|---|---:|---|
| `@PopulationAgeWarnMinutes` | 60 | Alter einer aktuell sichtbaren normalen oder semantischen Population |
| `@QueryableFragmentWarn` | 30 | Zahl querybarer Fragmente mit Status 4 oder 6 |
| `@OutstandingBatchWarn` | 100 | aktuell ausstehende Batches pro Tabelle |
| `@FailedDocumentWarn` | 1 | aggregierte aktuell gemeldete Dokumentfehler |
| `@CatalogSizeWarnMb` | 10.240 MB | aggregierte logische Größe querybarer Fragmente |

Alle fünf Werte sind Priorisierungs- oder Kapazitätsheuristiken. Microsoft dokumentiert keinen universellen Fragment-, Batch-, Laufzeit- oder Speichergrenzwert.

### Statusresultsets

#### DatabaseStatus

`DatabaseName`, `StatusCode`, `IsPartial`, `IsFullTextInstalled`, `CatalogCount`, `FullTextIndexCount`, `ActivePopulationCount`, `OutstandingBatchCount`, `FindingCount`, `SourceFailureCount`, `RequiredPermission`, `ErrorNumber`, `ErrorMessage`, `Detail`.

#### SourceStatus

Feature-Gate, Katalog-/Indexmapping, Fragmente, normale Population, Batches und semantische Population werden je Datenbank isoliert. Memory Pools und FDHosts werden einmal serverweit gelesen. SQL Server 2019 benötigt für die Laufzeit-DMVs `VIEW SERVER STATE`, SQL Server 2022 oder neuer `VIEW SERVER PERFORMANCE STATE`.

### Kataloge und FullTextIndexes

Kataloge liefern Namen, Default-/Accent-Sensitivity-Kontext, sichtbare Indexanzahl sowie aggregierte Fragmentgröße. Indizes liefern Tabelle, Katalog, Enablement, Status des eindeutigen Schlüsselindex, Change-Tracking- und Crawl-Kontext, Spalten-/Semantikanzahl sowie zugeordnete Fragment-, Population- und Batchzahlen.

Der Katalogname und Tabellen-Scope sind normale Runtime-Diagnosewerte. Sie werden nicht in gespeicherte Testevidenz übernommen. Katalogpfade und Schlüsselwerte werden weder gelesen noch ausgegeben.

### Populationen, Batches und Semantik

- `sys.dm_fts_index_population` enthält nur aktuell laufende Full-Text- und semantische Extraktionen. Nullzeilen sind keine Historie und kein Abschlussnachweis.
- Status 7 kann während eines automatischen Merge auftreten; Status 11 meldet eine abgebrochene Population.
- `sys.dm_fts_outstanding_batches` wird ohne Batch-ID, Speicheradressen oder Inhalte nach Tabelle, Fehlercode und Retryzustand aggregiert.
- Dokumentfehler werden nur als Anzahl gelesen. Einzelne Fehler können Inhalte von der Suche ausschließen, ohne die gesamte Population zu stoppen.
- Die semantische Ähnlichkeitspopulation ist die zweite Phase nach der Extraktion und wird nur bei sichtbaren `STATISTICAL_SEMANTICS`-Spalten abgefragt.

### Fragmente, Memory Pools und FDHosts

Nur querybare Fragmente mit Status 4 oder 6 fließen in Fragmentanzahl, logische Größe und Zeilenzahl ein. Viele Fragmente können Full-Text-Abfragen verlangsamen; ein `REORGANIZE` wird jedoch nie automatisch ausgeführt.

Memory Pools sind serverweit gemeinsam genutzter Gatherer-Kontext. FDHosts werden ausschließlich nach Typ aggregiert; Prozess-IDs und Hostnamen bleiben ausgeschlossen. Eine nicht atomare Abweichung zwischen Population- und FDHost-Momentaufnahme besitzt nur geringe Konfidenz.

### Interpretation

| Konstellation | Bewertung |
|---|---|
| Change Tracking `MANUAL` oder `OFF` | zulässige Konfiguration; erwartete Populationsteuerung prüfen |
| `has_crawl_completed=0`, keine aktive Population | kann durch `NO POPULATION` beabsichtigt sein; kein Fehlerbeweis |
| lange Population, Fortschritt steigt | Kapazitäts-/Durchsatzkontext, nicht Stillstand |
| Status 11 | belastbare aktuelle Abbruchmeldung; Ursache in geschützter Laufzeitumgebung prüfen |
| Retry oder `hr_batch<>0` | aktueller Batchreview; Fehlercode und Zeitverlauf korrelieren |
| viele querybare Fragmente | Suchlatenz und Trend prüfen, erst danach Wartung planen |
| Memory Pool groß | gemeinsamer Ressourcenverbrauch, kein datenbankspezifischer Druckbefund |

### Aussagegrenzen

- Katalogmetadaten beweisen keine Vollständigkeit indizierter Inhalte.
- Crawl-Logs liegen außerhalb des Frameworkscopes und dürfen nur in einer kontrollierten Laufzeitumgebung mit geeignetem Zugriff ausgewertet werden.
- Eine leere Laufzeit-DMV ist keine Historie.
- Alter, Batchzahl und Fragmentzahl sind ohne Zeitreihe und Workload kein Ursachenbeweis.
- Das Modul führt kein `ALTER FULLTEXT`, keine Population und keine Reorganisation aus.

### Folgeanalyse

Korrelieren Sie bei einer Folgemessung Fortschritt und Batches, Suchlatenz, I/O- und Logkontext sowie geschützte Full-Text- und Crawl-Logs in der Laufzeitumgebung. Dokumentieren Sie ausschließlich abstrahierte, synthetische Testergebnisse.

---

## 7. [monitor].[USP_DataCaptureDeepAnalysis]

### Zweck

Die Procedure vertieft Change Tracking, CDC und lokal erreichbare Replikation. Sie liest ausschließlich Katalog-, DMV-, Job- und aggregierte Distributionsevidenz. Change-Zeilen, Replikationsbefehle, Kommentare, Fehlertexte, LSNs, Credentials oder Agentjob-Commands werden nicht gelesen; die Konfiguration bleibt unverändert.

### Framework-Schwellen

| Parameter | Default | Bedeutung |
|---|---:|---|
| `@ChangeTrackingClientVersion` | `NULL` | echter zuletzt bestätigter Consumer-Wasserstand für genau eine ausgewählte Datenbank; ohne ihn kein Verlusturteil |
| `@CdcLatencyWarnSeconds` | 300 | aggregierte CDC-Scan-Latenz |
| `@CdcCleanupGraceMinutes` | 60 | Toleranz zusätzlich zur Cleanup-Retention |
| `@ErrorLookbackHours` | 24 | CDC- und lokale Replikationsfehler |
| `@ReplicationLatencyWarnSeconds` | 300 | Delivery-Latenz aus lokaler Agenthistorie |
| `@ReplicationPendingCommandWarn` | 10.000 | undistributed commands am lokalen Distributor |
| `@ReplicationAgentStaleWarnMinutes` | 15 | alte Distribution-History nur zusammen mit sichtbarem Rückstand |

Alle Zeit-, Latenz- und Mengenwerte außer dem CT-Minimumvergleich sind Priorisierungsheuristiken. Ein Wasserstand unter `CHANGE_TRACKING_MIN_VALID_VERSION` bedeutet für diesen Consumer und diese Tabelle, dass eine gültige inkrementelle Enumeration nicht mehr möglich ist.

### Resultsets

`DatabaseStatus` und `SourceStatus` zeigen zuerst Anwendbarkeit und Evidenzlücken. Danach folgen `Findings`, Change-Tracking-Tabellen, CDC-Capture-Instanzen, CDC-Scan-Sitzungen, aggregierte CDC-Fehler, CDC-Jobs, lokal sichtbare Replikationsagenten und aggregierte Replikationsfehler.

Schema- und Objektfilter gelten nur für CT-/CDC-Quelltabellen. Das Feature-Gate bleibt unfiltriert. Replikationsrollen und Agenten besitzen keinen zuverlässigen gemeinsamen Schema-/Tabellenschlüssel und werden deshalb nur über den Datenbankscope begrenzt.

### Change Tracking

- `MinValidVersion` ist tabellenspezifisch.
- `@ChangeTrackingClientVersion < MinValidVersion` erzeugt den hochkonfidenten Reinitialisierungsbefund.
- Ein Wasserstand über `CHANGE_TRACKING_CURRENT_VERSION()` ist inkonsistent.
- Ohne Consumer-Wasserstand wird ausdrücklich nur `CT_CLIENT_WATERMARK_NOT_SUPPLIED` ausgegeben.
- Deaktiviertes Auto-Cleanup ist Konfigurationskontext und nicht automatisch ein Fehler.

### CDC

Capture-Instanzen liefern Konfiguration, Drop-Pending und die Zeitgrenze der ältesten verfügbaren LSN. Die Scan-DMV liefert Aggregat und neueste Sitzung; sie wird bei Neustart oder Failover zurückgesetzt und ist auf einer AG-Sekundärreplik leer. CDC-Fehler werden ohne Meldungstext oder LSN nach Nummer, Schweregrad und Phase gruppiert.

Bei kontinuierlichem Capture ist hohe Latenz ein Warnhinweis. Bei zeitgesteuertem Capture wird derselbe Wert als Kontext mit niedrigerer Konfidenz ausgegeben. Das Überschreiten von Retention plus Toleranz ist wegen ruhiger Workloads und Cleanup-Timing nur eine Heuristik.

### Replikation

Lokale Distribution Agents werden mit `MSdistribution_status`, neuester History und Subscription-Status aggregiert. Log Reader und Merge Agent werden getrennt behandelt. `Idle` ohne Rückstand ist kein Fehler. Inaktive Subscriptions oder Fail/Retry sind Reinitialisierungskandidaten, aber kein alleiniger Reinitialisierungsbeweis.

Wenn eine Datenbank eine Replikationsrolle besitzt, aber keine lokale Distribution erreichbar ist, wird `REPLICATION_TOPOLOGY_NOT_LOCALLY_OBSERVABLE` ausgegeben. Remote-Distributor-, Netzwerk- und Subscriber-Zustände werden nicht erraten.

### Aussagegrenzen und Folgeanalyse

- CDC- und Replikationshistorien sind begrenzt und bereinigbar.
- Die Quellen werden nicht atomar gelesen; Zustände können sich zwischen Abfragen ändern.
- Peer-to-Peer-, Pull- und Remote-Topologien können außerhalb der lokalen Sicht liegen.
- Konkrete Fehlertexte, Commands, Zeilenkonflikte und Laufzeitnamen bleiben ausschließlich in der kontrollierten Laufzeitdiagnose.

Korrelieren Sie wiederholte Messungen, den Consumer-spezifischen CT-Wasserstand, den Agentjobausgang, die Netzwerk- und Subscriber-Erreichbarkeit sowie geschützte Laufzeitlogs. Persistieren Sie ausschließlich synthetische Testzustände.

## Anfänger-Entscheidungsbaum

```mermaid
flowchart TD
    A[Unbekannte Spezialfeatures] --> B[SpecialFeatureInventory]
    B --> C{Feature erkannt?}
    C -->|Nein| D[Sichtbarkeit und Version prüfen]
    C -->|Ja| E{Deep-Dive vorhanden?}
    E -->|In-Memory| F[InMemoryOltpAnalysis]
    E -->|Temporal| G[TemporalAnalysis]
    E -->|Service Broker| H[ServiceBrokerAnalysis]
    E -->|Full-Text| N[FullTextAnalysis]
    E -->|CT oder CDC| P[DataCaptureDeepAnalysis]
    E -->|nur Capability| L[ServerFeatureCapabilities]
    F --> I[SourceStatus und Findings gemeinsam lesen]
    G --> J[Retention, Größe und History-Index gemeinsam lesen]
    H --> K[Queue, Aktivierung, Transmission und Conversations]
    N --> O[Population, Batches und Fragmente]
    P --> Q[Versionen, Capture und Distribution]
    L --> M[Version + Katalog + Plattform + DB-Kontext]
```

## Quellen

- [What's new in SQL Server 2025](https://learn.microsoft.com/sql/sql-server/what-s-new-in-sql-server-2025)
- [Editions and supported features of SQL Server 2025](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2025)
- [Optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)
- [Query Store for readable secondary replicas](https://learn.microsoft.com/sql/relational-databases/performance/query-store-for-secondary-replicas)
- [sys.query_store_replicas](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-replicas?view=sql-server-ver17)
- [Backup compression and ZSTD](https://learn.microsoft.com/sql/relational-databases/backup-restore/backup-compression-sql-server)
- [In-Memory OLTP overview](https://learn.microsoft.com/sql/relational-databases/in-memory-oltp/overview-and-usage-scenarios)
- [sys.dm_db_xtp_hash_index_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-xtp-hash-index-stats-transact-sql)
- [sys.dm_db_xtp_checkpoint_files](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-xtp-checkpoint-files-transact-sql)
- [Temporal tables](https://learn.microsoft.com/sql/relational-databases/tables/temporal-tables)
- [Manage temporal history retention](https://learn.microsoft.com/sql/relational-databases/tables/manage-retention-of-historical-data-in-system-versioned-temporal-tables)
- [Temporal table considerations and limitations](https://learn.microsoft.com/sql/relational-databases/tables/temporal-table-considerations-and-limitations)
- [sys.service_queues](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-service-queues-transact-sql)
- [sys.transmission_queue](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-transmission-queue-transact-sql)
- [sys.dm_broker_queue_monitors](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-queue-monitors-transact-sql)
- [sys.dm_broker_activated_tasks](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-activated-tasks-transact-sql)
- [sys.conversation_endpoints](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-conversation-endpoints-transact-sql)
- [Work with Change Tracking](https://learn.microsoft.com/sql/relational-databases/track-changes/work-with-change-tracking-sql-server)
- [sys.change_tracking_tables](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/change-tracking-catalog-views-sys-change-tracking-tables)
- [sys.dm_cdc_log_scan_sessions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/change-data-capture-sys-dm-cdc-log-scan-sessions)
- [sys.dm_cdc_errors](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/change-data-capture-sys-dm-cdc-errors)
- [MSdistribution_status](https://learn.microsoft.com/sql/relational-databases/system-views/msdistribution-status-transact-sql)
- [MSdistribution_history](https://learn.microsoft.com/sql/relational-databases/system-tables/msdistribution-history-transact-sql)
- [MSmerge_sessions](https://learn.microsoft.com/sql/relational-databases/system-tables/msmerge-sessions-transact-sql)
- [sys.fulltext_indexes](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-fulltext-indexes-transact-sql)
- [sys.fulltext_index_fragments](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-fulltext-index-fragments-transact-sql)
- [sys.dm_fts_index_population](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-index-population-transact-sql)
- [sys.dm_fts_outstanding_batches](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-outstanding-batches-transact-sql)
- [sys.dm_fts_semantic_similarity_population](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-semantic-similarity-population-transact-sql)
- [sys.dm_fts_memory_pools](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-memory-pools-transact-sql)
- [sys.dm_fts_fdhosts](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-fdhosts-transact-sql)

---

## 8. [monitor].[USP_EncryptionAnalysis]

### Zweck

Die Procedure verbindet TDE-Zustand und Scanfortschritt, sichtbaren Zertifikatlebenszyklus, den Verschlüsselungsstatus des letzten sichtbaren nicht-copy-only Full-Backups und aggregierte Always-Encrypted-/Ledger-Metadaten. Jede Quelle besitzt eine eigene Fehlergrenze.

### Wichtige Trennungen

- TDE schützt Datenbankdateien; explizite Backupverschlüsselung ist ein eigener Mechanismus. Sie wird nur bei `@ExpliziteBackupverschluesselungErwartet=1` als Soll geprüft.
- Ein suspendierter oder abgebrochener TDE-Scan ist direkte Engine-Evidenz. Eine lange Transition ist dagegen ein konfigurierbarer Zeitgrenzwert.
- Zertifikatablauf ist ein Lebenszykluswarnsignal. Er beweist nicht, dass bestehende TDE-Verschlüsselung stoppt.
- Ein leerer lokaler Private-Key-Backupzeitpunkt beweist nicht, dass keine externe autorisierte Kopie existiert.
- Always Encrypted und Ledger werden ausschließlich als aggregierte Anzahlen erfasst; daraus entsteht kein Gesundheitsurteil.

### Ausgeschlossene Daten

Das Modul liest keine Schlüsselpfade, Signaturen, verschlüsselten Werte, Backupmedien, Konten oder privaten Schlüssel und gibt keine Thumbprints aus. Der Besitz nutzbaren Schlüsselmaterials und die Wiederherstellbarkeit können nur durch einen autorisierten externen Restore-Prozess nachgewiesen werden.

### Primärquellen

- [Transparent Data Encryption](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption)
- [sys.dm_database_encryption_keys](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-database-encryption-keys-transact-sql)
- [sys.certificates](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-certificates-transact-sql)
- [backupset](https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/backupset-transact-sql)
- [sys.column_master_keys](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-column-master-keys-transact-sql)
- [sys.column_encryption_keys](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-column-encryption-keys-transact-sql)

---

## 9. [monitor].[USP_ServerVersionInformation]

### Zweck

Die Procedure liefert eine leichte, offline reproduzierbare Einordnung von Instanzbuild,
Servicing-Zweig und Microsoft-Produktlifecycle. Die Procedure trennt aktuelle
`SERVERPROPERTY`-/Hostevidenz vom Stand der mitgelieferten Frameworkkataloge.

### Sicherer Aufruf

```sql
EXEC [monitor].[USP_ServerVersionInformation]
      @ResultSetArt = 'CONSOLE';
```

`databaseCompatibility` ist opt-in. Die normale Console enthält keine Server-,
Host-, Instanz-, Konto- oder Pfadidentität.

### Interpretation

- `EXACT_MATCH` ist ein exakter Offline-Katalogtreffer, keine Patchfreigabe.
- `OLDER_KNOWN_BUILD` zeigt einen älteren bekannten Katalogeintrag.
- `BUILD_NEWER_THAN_OFFLINE_CATALOG` ist keine Veraltet-Aussage.
- `CATALOG_STALE` bewertet den Katalogstand, nicht den Serverzustand.
- Lifecycle gilt für die Produkt-Hauptversion und ersetzt keine editions- oder
  vertragsspezifische Supportprüfung.

### Primärquellen

- [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17)
- [SQL Server build versions](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates)
- [Microsoft Lifecycle](https://learn.microsoft.com/en-us/lifecycle/)

---

## 10. [monitor].[USP_ExternalRuntimeAnalysis]

### Zweck

Die Procedure trennt External-Runtime-Konfiguration, datenbankbezogene Language-/Libraryregistrierungen, aktive Requests, External Resource Pools, registrierte Execution Stats und Performance Counter. Sie führt keinen externen Code aus und erzeugt deshalb keinen End-to-End-Funktionsnachweis.

### Resultsets

| Resultset | Zeilengranularität und Aussage |
|---|---|
| `configuration` | Eine Servermomentaufnahme zu Installationsproperty, `external scripts enabled` und aggregiertem Launchpad-Status. |
| `databaseStatus` | Eine Zeile je angeforderter beziehungsweise auswertbarer Datenbank. |
| `sourceStatus` | Eine Zeile je isolierter Quelle und Messpunkt mit Berechtigungs-, Fehler- und Aussagegrenze. |
| `languages`, `libraries` | Sichtbare datenbankbezogene Registrierungen; Datei- und Ownerdetails sind Opt-ins. |
| `activeRequests` | Aktuell aktive External-Script-Requests, dokumentiert über `external_script_request_id` korreliert. |
| `externalPools` | Aktueller Poolzustand und optional resetgeprüfte Deltas. |
| `executionStats`, `performanceCounters` | Kumulative Werte beziehungsweise typisierte Samplemetriken; keine allgemeine Script-Historie. |
| `findings` | Priorisierte Widersprüche und Livehinweise für Triage. |

### Datenschutz und Grenzen

Script- und Batchtexte, Parameter, Environment Variables, Datei- und Libraryinhalt sowie Pfade werden nicht gelesen. Login-, Host-, Client- und External-Worker-Identität sind standardmäßig `NULL`. Selbst mit `@MitDateimetadaten = 1` werden nur `file_name` und `platform_desc` der Language Extension beziehungsweise `platform_desc` der Library gelesen.

`sys.dm_external_script_requests` ist eine flüchtige Momentaufnahme. `sys.dm_external_script_execution_stats` erfasst registrierte Featurefunktionen, nicht beliebige Scripts. External-Pool-Werte gelten seit `statistics_start_time`; Deltas werden bei Reset oder `pool_version`-Wechsel verworfen. Unter Linux sind die dokumentierten cgroup-basierten Einheitengrenzen zu beachten.

### Sicherer Aufruf

```sql
EXEC [monitor].[USP_ExternalRuntimeAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @SampleSeconds = 0,
      @MitDateimetadaten = 0,
      @MitBerechtigungsanalyse = 0,
      @MitSitzungskontext = 0,
      @ResultSetArt = 'CONSOLE';
```

### Folgeanalyse

Ordnen Sie aktive oder blockierte Requests mit `USP_CurrentRequests` und `USP_CurrentBlocking` ein. Prüfen Sie Poolkontext mit `USP_ResourceGovernorAnalysis`, Counter mit `USP_PerformanceCounters` und Betriebsfehler mit `USP_ErrorLogAnalysis` beziehungsweise bereits vorhandener Extended-Events-Evidenz. Die vollständige Leserichtung steht in der [Procedure-Seite](Procedures/USP_ExternalRuntimeAnalysis.md).

---

## 11. [monitor].[USP_ClrAnalysis]

### Zweck

Die Procedure analysiert SQL-CLR-Konfiguration und sichtbare benutzerdefinierte Assemblies, Module, direkte Assemblyreferenzen, CLR-Typen, Host Properties, AppDomains, geladene Assemblies, CLR Tasks, aktive Managed-Code-Requests, Memory Clerks und Counter. Sie ist vom out-of-process Language-Extension-Pfad getrennt.

### Resultsets

| Resultset | Zeilengranularität und Aussage |
|---|---|
| `configuration` | Eine Servermomentaufnahme zu `clr enabled`, `clr strict security`, `lightweight pooling` und optionaler Trust-List-Anzahl. |
| `databaseStatus` | Eine Zeile je Datenbank mit sichtbarer Assembly-, High-Permission- und Modulanzahl. |
| `assemblies` | Eine sichtbare benutzerdefinierte Assembly innerhalb genau einer Datenbank. |
| `assemblyModules`, `assemblyDependencies` | Sichtbare CLR-Objekte, direkte Referenzen und CLR-Typen ohne Definition oder Binärinhalt. |
| `clrProperties`, `appDomains`, `loadedAssemblies`, `clrTasks` | Aktueller Host- und Cachekontext; keine Aufrufhistorie. |
| `activeRequests`, `memory`, `performanceCounters` | Flüchtige Requests, aktuelle Clerkaggregate und kumulative beziehungsweise gesampelte Counter. |
| `findings` | Priorisierte Sicherheits-, Plattform-, Konfigurations- und Livehinweise. |

### Sicherheits- und Korrelationsvertrag

`assembly_id` ist nur innerhalb einer Datenbank eindeutig. Geladene Assemblies werden deshalb zuerst einem AppDomain und dessen Datenbank zugeordnet und erst danach gegen `sys.assemblies` korreliert. Ein serverweiter Join allein über `assembly_id` ist unzulässig.

Assembly-Binärinhalt, SHA2-512-Hash, Trusted-Assembly-Beschreibung, Moduldefinition, SQL-Text und Plan bleiben ausgeschlossen. Der Standardpfad kann daher keinen Assembly-zu-Trust-List-Nachweis erzeugen. Owner-, `EXECUTE AS`- und Trust-List-Kontext erfordern einen expliziten Berechtigungs-Opt-in.

### Sicherer Aufruf

```sql
EXEC [monitor].[USP_ClrAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @SampleSeconds = 0,
      @MitModulzuordnung = 1,
      @MitBerechtigungsanalyse = 0,
      @MitSitzungskontext = 0,
      @ResultSetArt = 'CONSOLE';
```

### Folgeanalyse

Prüfen Sie blockierte Managed-Code-Requests mit `USP_CurrentRequests` und `USP_CurrentBlocking`, Instanzhärtung mit `USP_ServerSecurityConfiguration`, Speicher- und Counterevidenz mit `USP_ServerMemory` und `USP_PerformanceCounters` sowie Lade- oder Hostfehler mit `USP_ErrorLogAnalysis`. Die vollständige Leserichtung steht in der [Procedure-Seite](Procedures/USP_ClrAnalysis.md).
