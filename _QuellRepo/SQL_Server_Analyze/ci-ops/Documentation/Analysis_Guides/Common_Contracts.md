# Gemeinsame Verträge und Interpretationsregeln

**Stand:** 20. Juli 2026

Dieses Dokument gilt für alle Analyse-Procedures. Die bereichsbezogenen Leitfäden wiederholen nur Abweichungen und verfahrensspezifische Besonderheiten.

## 1. Ausgabearten

| Wert | Bedeutung | Geeignet für |
|---|---|---|
| `CONSOLE` | genau eine verdichtete Fachansicht; bei Leere eine verständliche Zeile | interaktive Analyse in SSMS oder Azure Data Studio |
| `RAW` | stabiler technischer Resultset-Vertrag | genaue Spaltenanalyse, Tests und Consumer |
| `TABLE` | semantisch benannte typisierte Ergebnisse in lokalen `#Temp`-Tabellen | Weiterverarbeitung in derselben SQL-Sitzung |
| `NONE` | keine fachlichen Resultsets | JSON-only, Aggregatoren und statusorientierte Aufrufe |

Bei technischer Verarbeitung ist `RAW` oder `TABLE` ausdrücklich zu setzen.
CONSOLE gibt keine separaten technischen Meta-Grids und keine leeren Details aus.
`TABLE` verwendet ausschließlich `@ResultTablesJson`, beispielsweise
`N'{"requests":"#CurrentRequests_Result"}'`. Permanente Tabellen und globale
Temp-Tabellen sind nicht Bestandteil dieses Vertrags.

Jede öffentliche Procedure bleibt eigenständig aufrufbar und ermittelt zeitabhängige Daten für ihren eigenen Aufruf frisch. Ruft ein Orchestrator mehrere Children im selben Lauf auf, darf er ein bereits erhobenes Ergebnis weiterreichen, wenn Quelle, Scope, Filter, Optionen und Berechtigungskontext fachlich gleich sind oder das Parent-Ergebnis ein nachweisbares Superset bildet. Der Childstatus kennzeichnet dies als `REUSED_PARENT_RESULT`; ein unvollständiges Ergebnis bleibt unvollständig und darf nicht als frische Vollerhebung erscheinen. Nur fehlende beziehungsweise wegen einer Sperre nicht erhobene Teilbereiche dürfen gezielt nachgelesen werden. Zwischen nacheinander ausgeführten öffentlichen Procedures existiert bewusst kein impliziter Cache, weil dessen Alter und Scope sonst die Ergebnissemantik verändern würden.

### Sperrverhalten bei Quellreads

`READPAST` ist kein allgemeiner Framework-Hint und wird insbesondere nicht für `sys.*`, DMVs oder den Plan Cache eingesetzt. Der Hint überspringt nur gesperrte Zeilen, nicht gesperrte Seiten, und kann dadurch fachlich relevante Evidenz lautlos auslassen. Zulässig wäre er nur für eine frameworkeigene Queue-/Work-Tabelle, wenn genau dieses Überspringen Teil des Verarbeitungsvertrags ist und Anzahl beziehungsweise Scope der ausgelassenen Zeilen als partiell ausgewiesen werden. `NOLOCK` verhindert zudem keine Schema-Stability-Sperre gegen eine gleichzeitige Schema-Modification-Sperre; deshalb bleiben `LOCK_TIMEOUT 0`, isoliertes `TRY/CATCH` und ein expliziter Teilstatus erforderlich. Siehe [Microsoft: Tabellenhinweise – READPAST, READUNCOMMITTED/NOLOCK und NOWAIT](https://learn.microsoft.com/en-us/sql/t-sql/queries/hints-transact-sql-table).

## 2. JSON und OUTPUT-Status

Viele neuere Procedures besitzen:

- `@JsonErzeugen bit`,
- `@Json nvarchar(max) OUTPUT`,
- `@StatusCodeOut varchar(40) OUTPUT`,
- `@IsPartialOut bit OUTPUT`,
- `@ErrorNumberOut int OUTPUT`,
- `@ErrorMessageOut nvarchar(2048) OUTPUT`.

### StatusCode

| Typischer Status | Bedeutung | Reaktion |
|---|---|---|
| `AVAILABLE` | vorgesehener Pfad wurde ausgeführt | fachliche Resultsets auswerten |
| `PARTIAL` oder `IsPartial = 1` | mindestens eine Quelle war unvollständig | Aussagegrenzen und Fehlerdetails prüfen |
| `INVALID_PARAMETER` | Parametervertrag verletzt | Aufruf korrigieren; Resultset nicht fachlich deuten |
| `UNAVAILABLE_FEATURE` | Feature, Version oder Compatibility Level fehlt | Capability und Zielplattform prüfen |
| `PERMISSION_DENIED` oder verwandter Status | benötigte Sicht ist nicht lesbar | keine Entwarnung aus leeren Resultsets ableiten |
| `NOT_CONFIGURED` | Feature ist nicht eingerichtet | nur dann unkritisch, wenn es fachlich nicht benötigt wird |
| `NO_DATA` | Quelle ist verfügbar, liefert aber keine Zeilen | Retention, Reset und Filter prüfen |

Die tatsächliche Statusliste ist procedureabhängig. `IsPartial = 1` hat Vorrang vor einer vereinfachten Interpretation des Hauptstatus.

## 3. Zeilen-, Datenbank- und Objektlimits

- `@MaxZeilen > 0`: begrenzt die ausgegebenen Zeilen.
- `@MaxZeilen = 0` oder `NULL`: unbegrenzt.
- Negative Werte: ungültig.
- Datenbankkandidaten werden vor globaler Bewertung und Sortierung nicht willkürlich begrenzt.
- Breite ressourcenintensive Pfade benötigen `@HighImpactConfirmed=1`; leichte Pfade nicht.
- `@MaxAnalyseobjekte`: begrenzt teure Plan-/XML-Analyseobjekte.
- Spezielle Limits wie `@MaxVerteilungsStatistiken` verhindern breite Tiefenscans.

**Grenzfall:** Ein TOP-Limit ohne eindeutige fachliche Sortierung kann relevante Zeilen abschneiden. Deshalb muss zusammen mit `@MaxZeilen` immer die Sortierung und der Filter geprüft werden.

## 4. Filtervertrag

### Exakte Listen

Listen sind pipe-getrennt und bracket-aware:

```sql
@DatabaseNames = N'[ExampleDbA]|[ExampleDbB]'
```

### Pattern

Je nach Procedure:

- implizites oder explizites `LIKE`,
- `like:...`,
- SQL Server 2025 und Compatibility Level 170: `regex:...` und `regexi:...`.

Exakte Liste und Pattern derselben Eigenschaft sind regelmäßig gegenseitig exklusiv.

### Datenbankauswahl

Frameworktypisch bedeutet:

| Wert | Bedeutung |
|---|---|
| `N''` oder `NULL` | alle sichtbaren Online-Benutzerdatenbanken |
| explizite Liste | nur genannte Datenbanken |

Systemdatenbanken benötigen stets `@SystemdatenbankenEinbeziehen=1`.

## 5. Gemeinsame technische Spalten

### Identität

| Spalte | Bedeutung | Aussagegrenze |
|---|---|---|
| `DatabaseId` | interne Datenbank-ID | nicht instanzübergreifend stabil |
| `DatabaseName` | aufgelöster Datenbankname | kann bei fehlender Sichtbarkeit `NULL` sein |
| `SchemaName` | Schema | nur sichtbarer Metadatenscope |
| `ObjectId` | Objekt-ID | nur innerhalb der Datenbank eindeutig; nach Drop/Recreate wiederverwendbar |
| `ObjectName` | Objektname | ohne Datenbank/Schema nicht eindeutig |
| `FullObjectName` | qualifizierter Name | bevorzugte Anzeige- und Filterspalte |
| `IndexId` | Index-ID | 0 kann Heap bedeuten |
| `IndexName` | Indexname | bei Heap häufig `NULL` |
| `PartitionNumber` | 1-basierte Partition | nicht mit Partition-ID verwechseln |
| `SessionId` | Session-ID | wiederverwendbar; immer Zeitbezug beachten |
| `RequestId` | Request innerhalb der Session | zusammen mit SessionId verwenden |
| `QueryId` | Query-Store-ID | nur in der betreffenden Query-Store-Datenbank gültig |
| `PlanId` | Query-Store-Plan-ID | nicht mit Plan Handle oder QueryPlanHash verwechseln |

### Zeit

| Spalte | Bedeutung | Interpretation |
|---|---|---|
| `SampleUtc` / `CapturedUtc` | Erfassungszeitpunkt | Grundlage jeder Momentaufnahme |
| `StartTime` | Beginn des beobachteten Vorgangs | Zeitzone und Quelle beachten |
| `LastExecutionTime` | letzte beobachtete Ausführung | Cache-/Historiengrenzen beachten |
| `IntervalStartUtc` / `IntervalEndUtc` | Query-Store-Intervall | Werte sind im Intervall aggregiert |
| `AgeSeconds`, `AgeHours`, `AgeDays` | berechnetes Alter | Framework-Heuristik, keine universelle Produktgrenze |

### Status und Vollständigkeit

| Spalte | Bedeutung |
|---|---|
| `StatusCode` | technischer Verfügbarkeits-/Ausführungsstatus |
| `IsPartial` | mindestens eine Quelle ist unvollständig |
| `ErrorNumber` | technische Fehlernummer, falls vorhanden |
| `ErrorMessage` | begrenzte technische Meldung |
| `EvidenceLimit` | explizite fachliche Aussagegrenze |
| `FindingCode` | stabiler normalisierter Befundcode |
| `Severity` | Triage-Priorität, keine Ursachenbestätigung |
| `Confidence` | Evidenzstärke |
| `RecommendedNextCheck` | empfohlene Folgeanalyse, kein automatischer Eingriff |

## 6. Reset- und Retention-Grenzen

### Neustart oder Cache-Eviction

Betroffen sind unter anderem:

- Plan Cache und Query Stats,
- Index Usage,
- Teile der Operational Stats,
- Waiting- und OS-DMVs,
- Memory- und Schedulerzustände.

Ein kleiner Zähler kurz nach Neustart ist nicht mit einem kleinen Zähler nach 180 Tagen Uptime vergleichbar.

### Query Store

Begrenzungen:

- Capture Mode,
- Read-Only-Status,
- max_storage_size,
- Cleanup,
- Runtime-Intervallgröße,
- Planlimit je Query,
- asynchrones Flushen,
- Query Store auf Secondary Replicas abhängig von Version und Konfiguration.

### Extended Events

Begrenzungen:

- Session war nicht aktiv,
- Event oder Action war nicht konfiguriert,
- Ring Buffer wurde überschrieben,
- Event Files wurden rotiert oder gelöscht,
- Target wurde nicht geflusht,
- Dateipfad oder Berechtigung fehlt.

### msdb-Historie

Backup-, Restore- und Agenthistorie kann durch Cleanup, Wartungsjobs oder Migration unvollständig sein.

## 7. Schwellenwertklassen

| Klasse | Kennzeichnung im Guide | Beispiel |
|---|---|---|
| Code-Default | **Framework-Schwelle** | `@CheckdbWarnHours = 168` |
| offizielle Produktaussage | **Microsoft-dokumentiert** | Query Store aggregiert Werte nach Intervallen |
| praktische Betriebsregel | **Heuristik** | wachsender Lock-Wait über mehrere Messungen ist relevanter als 50 ms einmalig |
| keine seriöse Universalgrenze | **Unspecified** | akzeptable PAGEIOLATCH-Latenz ohne Storage-/SLA-Kontext |

## 8. Null, Nullzeile und Nullwert

Diese drei Fälle sind zu unterscheiden:

1. **Keine Resultsetzeile:** Prüfen Sie Filter, Retention, Reset, Feature und Berechtigung.
2. **Zeile mit `NULL`:** Quelle kennt den Wert nicht, Wert ist nicht anwendbar oder Auflösung schlug fehl.
3. **Zeile mit 0:** tatsächlicher Zählerstand 0 im sichtbaren Zeitfenster, sofern die Quelle vollständig ist.

## 9. Vergleichs- und Deltaanalysen

Ein Delta ist sinnvoll bei:

- I/O-Zählern,
- Performance Countern vom Typ Rate oder Base,
- Waits,
- Spinlocks,
- kumulativen Aktivitätszählern.

Ein Delta ist ungeeignet, wenn:

- der Zähler zwischen Samples resettet wurde,
- die Quelle nicht monoton ist,
- ein Plan oder Metadatencacheobjekt verschwand,
- beide Samples nicht denselben Scope besitzen.

## 10. Häufige Fehlinterpretationen

| Fehlinterpretation | Korrektur |
|---|---|
| hoher Wert = Fehler | Last, Dauer, Häufigkeit und SLA einbeziehen |
| leer = gesund | Verfügbarkeit und Historiengrenze prüfen |
| ein Missing Index = DDL-Auftrag | vorhandene Indizes, Schreibkosten und Plan prüfen |
| Fragmentierung > 30 % = sofort rebuild | Page Count, Seitendichte, Workload und Wartungsfolgen prüfen |
| `suspended` = blockiert | WaitType und BlockingSessionId prüfen |
| hoher DOP = falsch | Querytyp, Worker, CPU und Plan prüfen |
| Forced Plan = dauerhaft korrekt | Force-Fehler und neue Daten-/Schemaentwicklung beobachten |
| keine suspect pages = CHECKDB erfolgreich | separate Integritätsevidenz erforderlich |

## 11. Datenschutz in Beispielen

Zulässig:

- `ExampleDatabase`, `ExampleSchema`, `ExampleTable`, `ExampleIndex`,
- `ExampleLogin`, `ExampleHost`, `ExampleApplication`,
- synthetische Session-, Query-, Page- und Planwerte.

Unzulässig:

- kopierte reale Runtime-Ausgaben,
- nur geschwärzte oder gehashte reale Werte,
- reale Server-, Datenbank-, Kunden-, Benutzer-, Firmen-, Pfad- oder Jobnamen,
- reale SQL-Texte, Planparameter, Eventpayloads oder Fehlermeldungen.

## 12. Gemeinsame Primärquellen

- [Dynamic Management Views and Functions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views)
- [Monitor performance with Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)
- [Extended Events overview](https://learn.microsoft.com/sql/relational-databases/extended-events/extended-events)
- [Index-related DMVs](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/index-related-dynamic-management-views-and-functions-transact-sql)
- [SQL Server permissions](https://learn.microsoft.com/sql/relational-databases/security/permissions-database-engine)
