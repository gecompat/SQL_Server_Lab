# SQL-Text-, Statement-, Batch- und Modulvertrag

Stand: 2026-07-16

## Ziel

Bei laufenden Requests muss eindeutig erkennbar sein:

1. welcher Request und welche Session laufen,
2. ob ein persistentes Modul oder ein Ad-hoc-/Prepared-Batch ausgeführt wird,
3. welches einzelne Statement innerhalb dieses Batches oder Moduls aktuell ausgeführt wird,
4. an welcher Byte-, Zeichen- und Zeilenposition dieses Statement liegt,
5. wie der vollständige Batch- beziehungsweise Modultext lautet,
6. welcher Befehl ursprünglich an SQL Server übergeben wurde.

## Statement-Offsets

`sys.dm_exec_requests.statement_start_offset` und `statement_end_offset` sind Byte-Offsets innerhalb des von `sys.dm_exec_sql_text` gelieferten `nvarchar`-Texts. Die Extraktion erfolgt zentral über:

```sql
[monitor].[TVF_StatementText]
```

Der Vertrag liefert mindestens:

- `HasStatementOffsets`
- `IsStatementOffsetValid`
- `StatementStartOffsetBytes`
- `StatementEndOffsetBytes`
- `StatementStartCharacter`
- `StatementEndCharacter`
- `StatementStartLine`
- `StatementEndLine`
- `StatementCharacterCount`
- `BatchCharacterCount`
- `StatementText`

`statement_end_offset = -1` bedeutet das Ende des Batches oder persistenten Moduls. Fehlen die Offsets, wird der gesamte verfügbare SQL-Text als nicht weiter abgrenzbarer Batch behandelt; `HasStatementOffsets = 0` macht diesen Fallback transparent.

## Modulkontext

`sys.dm_exec_sql_text` liefert für persistente Module `dbid`, `objectid`, `number` und `encrypted`. Namen werden nicht über `OBJECT_NAME`, `OBJECT_SCHEMA_NAME` oder `SCHEMA_NAME` aufgelöst. Die Auflösung erfolgt datenbankbezogen über `sys.objects` und `sys.schemas` mit `NOLOCK`, fehlerisoliert je Datenbank.

Relevante Spalten:

- `SqlTextDatabaseId`
- `SqlTextObjectId`
- `SqlTextObjectNumber`
- `SqlTextIsEncrypted`
- `ExecutionContextType`
- `ModuleDatabaseName`
- `ModuleSchemaName`
- `ModuleObjectName`
- `ModuleType`
- `ModuleTypeDescription`
- `ModuleFullName`

Ein typischer Wert ist:

```text
[BeispielDatenbankB].[etl].[USP_LoadFactSales]
```

## Aktuelles Statement und vollständiger SQL-Text

Für Live-Request-Analysen gelten:

```sql
@MitSqlText                 bit = 1,
@GesamtenSqlTextEinbeziehen bit = 0,
@MaxSqlTextZeichen          int = 4000
```

- `@MitSqlText = 1`: exakt abgegrenztes aktuelles Statement ausgeben.
- `@GesamtenSqlTextEinbeziehen = 1`: vollständigen Batch- beziehungsweise Modultext zusätzlich ausgeben.
- Bei `@MaxSqlTextZeichen > 0` wird die Darstellung auf diese Zeichenzahl begrenzt.
- `@MaxSqlTextZeichen = 0` oder `NULL`: vollständigen jeweiligen Text ausgeben.

Eine Kürzung wird über eigene `...IsTruncated`-Spalten ausgewiesen. Die fachliche Textlänge wird vor der Kürzung festgehalten.

## Input Buffer

```sql
@InputBufferEinbeziehen bit = 0
```

Der Input Buffer ergänzt den ursprünglich an SQL Server übergebenen Befehl. Dies ist insbesondere hilfreich, wenn innerhalb einer Stored Procedure ein einzelnes Statement läuft, aber zusätzlich der aufrufende `EXEC`- oder RPC-Kontext benötigt wird.

Ausgegeben werden:

- `InputBufferEventType`
- `InputBufferParameterCount`
- `InputBufferCharacterCount`
- `InputBufferIsTruncated`
- `InputBufferText`

## CONSOLE

Die Hauptansicht zeigt Modul, Statement-Zeilen, Byte-Offsets und das aktuelle Statement. Vollständiger SQL-Text und Input Buffer werden als eigene, schmalere Resultsets ausgegeben, damit das Request-Resultset nicht unnötig verbreitert wird.

## RAW

RAW enthält typisierte Diagnose- und Textspalten ohne Darstellungsformatierung. Technische Verbraucher müssen `@ResultSetArt = 'RAW'` explizit setzen.

## JSON

`USP_CurrentRequests` verwendet benannte Arrays:

- `requests`
- `statements`
- `batches`
- `inputBuffers`
- `warnings`

Damit werden große Texte nicht redundant in jeder fachlichen Teilstruktur wiederholt.

## Zusätzlicher Ausführungskontext

`USP_CurrentRequests` ergänzt im RAW-/JSON-Vertrag und im separaten CONSOLE-Resultset `SQL-Kontext` insbesondere:

- `NestLevel` zur Einordnung verschachtelter Modulaufrufe,
- `ConnectionId`, `TransactionId`, `SchedulerId` und `TaskAddress` zur Korrelation mit Verbindungs-, Transaktions- und Schedulerdiagnosen,
- `WorkloadGroupId`/`WorkloadGroupName` und `ResourcePoolId`/`ResourcePoolName` für Resource-Governor-Bezug,
- `StatementSqlHandle` und `StatementContextId` für den individuellen Query-/Query-Store-Kontext,
- `IsResumable`, `ExecutingManagedCode` und `ContextInfo`,
- Query Hash, Query Plan Hash, SQL Handle und Plan Handle.

Der Request-Input-Buffer ist der geeignete Zusatzkontext für den ursprünglich eingereichten EXEC-/RPC-/Batch-Aufruf. `SESSION_CONTEXT` einer fremden Session wird nicht als allgemeiner Live-Diagnosevertrag versprochen.

## Weitere sinnvolle Opt-in-Diagnosen

- tatsächlicher Ausführungsplan für genau das Statement über `sys.dm_exec_text_query_plan`,
- taskbezogene Waits bei parallelen Requests,
- Lock-/Transaktionskorrelation über `TransactionId`,
- Page-Resource-Dekodierung bei Page-Waits,
- Query-Store-Korrelation über `StatementSqlHandle`/`StatementContextId`, soweit Query Store aktiv ist.

Plan-XML und weitere tiefe Analysen bleiben wegen CPU-, Speicher- und Plan-Cache-Kosten opt-in und gehören nicht in den Standardaufruf.
