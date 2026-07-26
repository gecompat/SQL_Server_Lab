# SQL Server 2025 – Statistiken auf lesbaren Secondaries

Stand: 23. Juli 2026  
Work Item: `SQL25-004`  
Status: `IMPLEMENTED_ACTIONS_GATE`  
Öffentlicher Vertrag:
`Metadata/Quality/SQL25_Readable_Secondary_Statistics_Public_Contract.json`

## Ziel

`monitor.USP_Statistics` erhält die mit SQL Server 2025 ergänzten
Herkunftsfelder aus `sys.stats`, ohne den bestehenden Statistikvertrag auf SQL
Server 2019 und 2022 unbrauchbar zu machen. Der Output trennt zwei
unterschiedliche Sachverhalte:

- `CurrentReplicaRole` beschreibt die Rolle der analysierten Datenbank zum
  Erfassungszeitpunkt.
- `ReplicaRoleId`, `ReplicaRoleDesc` und `ReplicaName` beschreiben Herkunft
  beziehungsweise letzte Aktualisierungsrolle der einzelnen Statistik.

Diese Trennung ist fachlich notwendig. Die Herkunft einer Statistik ist weder
die aktuelle Verbindungsrolle noch ein Verwendungsnachweis für einen Queryplan;
sie ist ausdrücklich kein Verwendungsnachweis.

## SQL-Server-2025-Quellvertrag

SQL Server 2025 ergänzt `sys.stats` um folgende Spalten:

| Quellspalte | Datentyp | Bedeutung |
|---|---|---|
| `replica_role_id` | `tinyint` | `1` Primary, `2` Secondary, `3` Geo Secondary, `4` Geo HA Secondary |
| `replica_role_desc` | `nvarchar(60)` | Textuelle Rollenbeschreibung |
| `replica_name` | `sysname` | Name des Ursprungsreplikats; auf dem Primary absichtlich `NULL` |

`is_temporary` bleibt davon getrennt. Eine temporäre Statistik kann auf einer
lesbaren Secondary in `tempdb` entstehen. Nach ihrer Persistierung auf dem
Primary kann die temporäre Fassung bis zu Recompilation oder Neustart neben
der permanenten Fassung bestehen.

Wenn eine später persistierte Statistik auf dem Primary aktualisiert wird,
wechselt ihre ausgewiesene Herkunft zum Primary. Die Herkunftsfelder sind
daher eine aktuelle Katalogeigenschaft und keine unveränderliche Historie.

## Öffentlicher Output

Das vorhandene benannte Resultset `statistics` bleibt bestehen und verwendet
Schema-Version 2. Es wird um sieben Felder ergänzt:

| Feld | Bedeutung |
|---|---|
| `IsTemporary` | Temporäre Statistik gemäß `sys.stats.is_temporary` |
| `CurrentReplicaRole` | Aktuelle Datenbankrolle: `HADR_DISABLED`, `PRIMARY`, `SECONDARY` oder `NOT_IN_AG_OR_UNKNOWN`; bei nicht lesbarer Rollenquelle `NULL` |
| `CurrentReplicaRoleStatus` | `AVAILABLE`, `NOT_APPLICABLE`, `DENIED_PERMISSION`, `TIMEOUT` oder `ERROR_HANDLED` |
| `ReplicaRoleId` | Herkunftscode aus `sys.stats`; auf älteren Versionen `NULL` |
| `ReplicaRoleDesc` | Herkunftsbeschreibung; auf älteren Versionen `NULL` |
| `ReplicaName` | Herkunftsreplikat; beim Primary regulär `NULL` |
| `ReplicaMetadataStatus` | Verfügbarkeit und Vollständigkeit der Herkunftsevidenz |

Bei deaktiviertem HADR wird `CurrentReplicaRole=HADR_DISABLED` ohne
Funktionsaufruf gesetzt. Andernfalls wird die Rolle höchstens einmal je
Datenbank über `sys.fn_hadr_is_primary_replica` ermittelt. Diese Funktion
benötigt `VIEW SERVER STATE`; ein Berechtigungs- oder Timeoutfehler wird in
`CurrentReplicaRoleStatus` isoliert und entfernt keine sichtbaren
Statistikdefinitionen. Der Rollenwert wird nicht aus den
Statistik-Herkunftsfeldern abgeleitet.

## Statussemantik

`ReplicaMetadataStatus` verwendet folgende Werte:

| Status | Bedeutung |
|---|---|
| `AVAILABLE` | Rollen-ID, Rollenbeschreibung und – soweit erforderlich – Replikatname sind konsistent vorhanden |
| `NOT_RECORDED` | Alle drei Herkunftsfelder sind `NULL`; es wird keine Rolle unterstellt |
| `PARTIAL_METADATA` | Herkunftsfelder sind nur teilweise vorhanden oder widersprechen der dokumentierten Rollenzuordnung |
| `UNAVAILABLE_VERSION` | SQL Server 2019 oder 2022; die neuen Spalten werden nicht referenziert |
| `UNAVAILABLE_COLUMNS` | SQL Server 2025 oder neuer, aber das erwartete Pflichtschema fehlt |
| `DENIED_METADATA` | Die capability-Prüfung scheitert an Berechtigungen |
| `TIMEOUT` | Die capability-Prüfung erreicht den gewählten Metadaten-Lock-Timeout |
| `CAPABILITY_ERROR` | Sonstiger isolierter Fehler der capability-Prüfung |

Die Konsistenzprüfung der dokumentierten Rollenbeschreibungen ist
case-insensitiv und damit unabhängig von der Datenbankcollation. Der
tatsächliche Text aus `sys.stats` wird im Output unverändert ausgegeben.

Ein leerer fachlicher Scope wird im Datenbankstatus als
`AVAILABLE_LIMITED` mit `RowScope=EMPTY_OR_RESTRICTED` ausgewiesen. Damit wird
nicht behauptet, dass keine Statistik existiert: Ein leerer Filter und
eingeschränkte Metadata Visibility können ohne zusätzliche Rechte
unterscheidbar bleiben.

## Versions- und Capabilitygrenze

Auf SQL Server 2019 und 2022 enthält der kompilierte Abfragepfad keine
Referenz auf die drei SQL-Server-2025-Spalten. Die Ausgabespalten bleiben
typstabil und erhalten `NULL` sowie `UNAVAILABLE_VERSION`. Diese erwartete
Versionsgrenze macht vollständig sichtbare Basisstatistiken nicht partiell;
der Datenbankstatus bleibt in diesem Fall `AVAILABLE`.

Ab Produktmajorversion 17 prüft die Procedure einmal je Zieldatenbank über
`sys.all_views`, `sys.all_columns` und `sys.schemas`, ob alle drei
Pflichtspalten vorhanden sind. Erst danach wird die konkrete Projektion als
Dynamic SQL aufgebaut. Erwartet fehlende Spalten werden zeilengenau als
`UNAVAILABLE_COLUMNS` ausgewiesen und machen die bestehende
Statistikdefinition nicht partiell. Berechtigungs-, Timeout-,
Capability- oder inkonsistente Herkunftsfehler führen dagegen zum
Datenbankstatus `AVAILABLE_LIMITED`.

## Last- und Sperrverhalten

Der Basis-Katalog `sys.stats` wird je Datenbank und Aufruf höchstens einmal
gelesen. Optionale inkrementelle Details verwenden die bereits
materialisierten Statistik-IDs und lesen `sys.stats` nicht erneut.
`sys.dm_db_incremental_stats_properties` wird nur bei
`@MitIncrementellenDetails=1` ausgeführt.

Die Abfrage verwendet vorhandene Objekt-, Schema- und Statistikfilter,
`@MaxZeilen`, `MAXDOP 1`, `RECOMPILE` und den gewählten `@LockTimeoutMs`.
`@LockTimeoutMs` wird ausschließlich in den isolierten dynamischen
Datenbankbatches gesetzt; der im aufrufenden Scope geltende `LOCK_TIMEOUT`
bleibt unverändert. Die Erweiterung liest weder Histogramme noch
Benutzertabellenzeilen.

## Output-Modi

Die sieben Felder sind in `CONSOLE`, `RAW`, JSON und dem benannten
TABLE-Resultset `statistics` enthalten. `NONE` unterdrückt Resultsets, kann
aber weiterhin JSON erzeugen. Das optionale Resultset für inkrementelle
Statistikpartitionen behält seine bisherige Granularität.

## Aussagegrenzen

- Eine Secondary-Herkunft ist kein Nachweis, dass eine aktuelle Abfrage diese
  Statistik verwendet.
- Eine Primary-Herkunft beweist nicht, dass die Statistik nie auf einer
  Secondary entstanden ist; ein späteres Update auf dem Primary überträgt die
  ausgewiesene Herkunft.
- Temporäre und permanente Statistiken mit ähnlicher Spaltenabdeckung können
  vorübergehend gleichzeitig existieren. Das allein ist kein Defekt.
- `ReplicaName IS NULL` ist für Primary-Herkunft erwartet und kein
  Berechtigungsfehler.
- `NOT_RECORDED` ist keine angenommene Primary-Rolle.
- `PARTIAL_METADATA` ist eine Evidenzgrenze, keine Health- oder
  Wartungsempfehlung.
- Die Herkunftsfelder sagen nichts über Aktualität, Selektivität,
  Stichprobenqualität oder Nutzen für einen konkreten Plan aus.

## Runtimevertrag

Der Vertrag
`Code/Tests/ObjectIndex/123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql`
läuft auf SQL Server 2019, 2022 und 2025. Er prüft:

1. stabiles TABLE-/JSON-Schema und Unverändertheit von `LOCK_TIMEOUT`;
2. `UNAVAILABLE_VERSION` ohne Referenz der neuen Spalten auf 2019/2022;
3. den echten capability-geprüften `sys.stats`-Pfad auf 2025;
4. tatsächliche Primary-Herkunft oder den expliziten Zustand
   `NOT_RECORDED`;
5. die dokumentierte Rollenabbildung für Secondary, Geo Secondary und Geo HA
   Secondary mit ausschließlich synthetischen `Example*`-Werten;
6. `PARTIAL_METADATA`, Ergebnisbegrenzung, leeren Scope und eingeschränkte
   Metadata Visibility.

Die portable Container-Matrix erstellt keine Availability Group und behauptet
daher keinen aktiven Secondary-Laufzeitnachweis. Sie führt den echten
SQL-Server-2025-Katalogpfad aus und prüft die nicht herstellbaren Rollenfälle
gegen den eingefrorenen synthetischen Rollencodevertrag. Diese Grenze ist
Bestandteil des öffentlichen Vertrags.

## Datenschutz

Produktiv werden ausschließlich sichtbare Statistikdefinitionen und
Systemmetadaten ausgegeben. Histogrammschlüssel, Tabellendaten, Querytexte und
Pläne werden nicht gelesen. Repositorytests verwenden nur generische
`Example*`-Bezeichner und numerische synthetische Werte.

## Quellen

- Microsoft (2026): [Persisted Statistics for Readable Secondary Replicas](https://learn.microsoft.com/en-us/sql/relational-databases/performance/persisted-stats-secondary-replicas?view=sql-server-ver17).
- Microsoft (2026): [`sys.stats` (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-stats-transact-sql?view=sql-server-ver17).
- Microsoft (2026): [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17).
- Microsoft (2026): [`sys.fn_hadr_is_primary_replica`](https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-hadr-is-primary-replica-transact-sql?view=sql-server-ver17).
