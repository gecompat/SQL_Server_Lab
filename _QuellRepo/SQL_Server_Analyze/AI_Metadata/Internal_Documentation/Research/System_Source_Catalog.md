# Systemquellenkatalog

Stand: 2026-07-18

## Zweck

Dieses Dokument beschreibt, welche SQL-Server-Systemquellen das Framework nutzt und wie deren Aussagekraft einzuordnen ist. Der vollständige maschinenlesbare Katalog steht unter [`Metadata/Inventory/SystemSources.csv`](../../Metadata/Inventory/SystemSources.csv).

Der Katalog wurde aus den kanonischen Dateien unter `Code/00_Setup` bis `Code/09_VersionAdaptive` erzeugt und mit abstrahierten Ergebnissen der früheren Quellenanalyse ergänzt. Historische Dateipfade, umgebungsspezifische Objektnamen und externe Hilfsobjekte wurden nicht übernommen.

Aktuell inventarisiert: **siehe `Metadata/Inventory/SystemSources.csv`; der Wert wird im statischen Release-Audit geführt**.

## Quellklassen

### Live- und Laufzeit-DMVs

Beispiele sind Requests, Sessions, Tasks, Waits, Locks, Memory Grants, Scheduler, Betriebssystem- und I/O-Zähler. Diese Quellen zeigen aktuellen oder seit einem Reset kumulierten Zustand. Sie sind keine vollständige Historie.

### Datenbankbezogene DMVs und DMFs

Hierzu zählen Indexnutzung, Operational und Physical Stats, Statistikmetadaten, Log-, TempDB-, Columnstore- und Persistent-Version-Store-Informationen. Scope und Parameter müssen vor dem Aufruf eng begrenzt werden. Einige DMFs können bei NULL-Parametern eine breite Wildcard-Semantik besitzen.

### Plan Cache und Showplan

Plan-Cache- und XML-Quellen können CPU, Speicher und XML-Shredding verursachen. Das Framework begrenzt deshalb Analyseobjekte getrennt von Ergebniszeilen und prüft die zugehörigen Deep-Analyseklassen vor breiten Scans.

### Query Store

Query Store ist datenbankbezogen. Das Framework wechselt kontrolliert in jede ausgewählte Quelldatenbank, erzeugt lokale Kandidatenmengen und führt erst danach ein globales Ranking aus. Query Store darf nicht als verfügbar angenommen werden, nur weil die SQL-Server-Version ihn grundsätzlich unterstützt.

### Extended Events

Katalogviews beschreiben vorhandene Sessions; Runtime-DMVs beschreiben aktive Sessions und Targets. Eventfile- und Ringbuffer-Inhalte werden nur opt-in gelesen. Das Framework erstellt, startet, stoppt oder verändert keine Session.

### Systemdatenbanken und Infrastruktur

SQL Agent, Backup-/Restore-Historie, Log Shipping und Teile der Replikation liegen in systemverwalteten Datenbanken. Zugriff und Vollständigkeit hängen von Featureinstallation, Rolle und Berechtigungen ab. Das Framework vergibt keine Rechte.

### Spezialfeature-Nutzungsinventur

`monitor.USP_SpecialFeatureInventory` aggregiert ausschließlich sichtbare Systemkatalogmetadaten für 18 Featureklassen. Es liest keine Nutzdaten, externen Speicherorte oder Verbindungsoptionen, Credentials, Service-Broker-Nachrichten, CLR-Binärinhalte, Moduldefinitionen oder Objektnamen. Eine Nullzählung ist bei eingeschränkter Metadatensichtbarkeit kein Abwesenheitsbeweis; die Inventur ist kein Gesundheitsurteil.

### In-Memory OLTP

`monitor.USP_InMemoryOltpAnalysis` trennt Feature-Gate, Tabellen-/Indexspeicher, Memory-Consumer, Hashkatalog, opt-in Hashketten, Checkpointzustände, aktive Transaktionsaggregate und Resource-Governor-Poolkontext. Jede DMV besitzt einen eigenen Quellenstatus. Die Hashindex-Laufzeitstatistik kann vollständige Tabellen scannen und ist deshalb `HIGH_OPT_IN`. Checkpoint-Pfade und GUIDs sowie Session-, Benutzer- und Transaktionskennungen werden nicht gelesen. Defaultpoolwerte werden nur als gemeinsamer Kontext, nicht als Datenbankattribution gewertet.

### Temporal Tables

`monitor.USP_TemporalAnalysis` trennt Feature-Gate, Current-/History-Katalogzuordnung, Retention-Konfiguration, approximative Partitionskapazität und History-Indexmetadaten. `sys.dm_db_partition_stats` liefert ungefähre Zeilen- und Seitenwerte, keine Nutzdaten. Eine endliche Retention bei deaktiviertem Datenbankschalter und eine fehlende sichtbare Perioden-Indexbaseline werden als Prüfhinweise ausgewiesen. Ohne Current-/History-Zeilenscan, `DBCC CHECKCONSTRAINTS` oder persistierte Historie werden weder Periodenüberlappungen noch Cleanup-Erfolg oder nach `SYSTEM_VERSIONING=OFF` getrennte frühere Paare behauptet.

### Service Broker

`monitor.USP_ServiceBrokerAnalysis` trennt Feature-Gate, Queue-Katalog, approximative Partitionskapazität, Queue-Monitor, aktivierte Tasks, Transmission und Conversation Endpoints. Die Transmission Queue wird ausschließlich nach nicht-payloadhaltigen Metadaten gruppiert; Queue-Nutzdaten, Nachrichtenkörper, Handles, Gruppen-IDs und Schlüsselkennungen werden nicht gelesen. Ein deaktiviertes RECEIVE kann automatisch nach wiederholten Rollbacks oder manuell entstanden sein und bleibt ohne Ereignis- und Anwendungsevidenz ein Prüfhinweis. Broker-DMVs sind Momentaufnahmen und werden einzeln fehlertolerant behandelt.

### Full-Text

`monitor.USP_FullTextAnalysis` trennt Feature-Gate, Katalog-/Indexmapping, Fragmente, laufende Populationen, ausstehende Batches, semantische Ähnlichkeitspopulationen sowie serverweite Memory Pools und FDHosts. Population- und Batch-DMVs sind Momentaufnahmen, keine Historie. Batch-IDs, Speicheradressen, FDHost-Namen und Prozess-IDs werden nicht ausgegeben; Tabelleninhalt, Keywords, Stopwords, Parser-Eingaben, Schlüsselwerte, Crawl-Logs und Pfade werden nicht gelesen. Fragment-, Laufzeit-, Batch- und Größenwerte bleiben konfigurierbare Prüfheuristiken ohne automatische DDL.

### Change Tracking, CDC und Replikation

`monitor.USP_DataCaptureDeepAnalysis` trennt das sichtbare Feature-Gate von CT-Katalog, CDC-Capture-Instanzen, Scan-DMV, Fehler-DMV, msdb-Jobs sowie lokalen Distribution-, Log-Reader-, Merge- und Fehlerquellen. Ein CT-Synchronisationsverlust wird nur gegen einen explizit gelieferten Consumer-Wasserstand bewertet. CDC-DMVs werden durch Neustart, Failover und Retention begrenzt; zeitgesteuertes Capture wird nicht wie kontinuierliches Capture bewertet. Lokale Replikationstabellen beweisen keinen Remote-Distributor- oder Subscriber-Zustand. Change-Zeilen, Commands, Kommentare, Fehlertexte, LSNs, Credentials, Agentjob-Commands und Konfliktzeilen werden nicht gelesen.

## Berechtigungsgrundsatz

Für serverbezogene DMVs gilt auf SQL Server 2019 typischerweise `VIEW SERVER STATE`; ab SQL Server 2022 verwenden viele Performance-DMVs `VIEW SERVER PERFORMANCE STATE`. Datenbankbezogene Quellen verwenden entsprechend `VIEW DATABASE STATE` beziehungsweise ab SQL Server 2022 häufig `VIEW DATABASE PERFORMANCE STATE`. Sicherheitsbezogene Quellen können abweichende Security-State-Berechtigungen erfordern.

Eine Vorabprüfung ist nur eine Indikation. Jeder optionale Zugriff bleibt fehlertolerant und muss Berechtigungs-, Versions-, Plattform- und Objektfehler separat behandeln.

## Kosten- und Blockingmodell

- `LOW_OR_SCOPE_DEPENDENT`: Katalog- oder kleine Statusquelle; Umfang trotzdem begrenzen.
- `MEDIUM_OR_SCOPE_DEPENDENT`: Runtime-DMV, Cross-Database- oder größere Historienquelle.
- `HIGH_OR_SCOPE_DEPENDENT`: Physical Stats, breite Plan-/Query-Store-Analyse, XML-Shredding oder Eventfile-Lesen.
- `HIGH_OPT_IN`: explizit aktivierter, vorab hart begrenzter Deep-Pfad wie die Histogrammverteilungsanalyse.

Breite Metadatenauflösung verwendet Systemkataloge mit kurzer Lock-Wartezeit beziehungsweise best-effort Fehlerisolation. Eine fehlende Namensauflösung ist einem blockierten Gesamtergebnis vorzuziehen; technische IDs bleiben erhalten.

## Offizielle Ausgangspunkte

- Dynamic Management Objects: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/system-dynamic-management-objects?view=sql-server-ver17
- Extended-Events-Systemviews: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/selects-and-joins-from-system-views-for-extended-events-in-sql-server?view=sql-server-ver17
- Weitere objektbezogene Primärquellen: [`Sources.md`](./Sources.md)
