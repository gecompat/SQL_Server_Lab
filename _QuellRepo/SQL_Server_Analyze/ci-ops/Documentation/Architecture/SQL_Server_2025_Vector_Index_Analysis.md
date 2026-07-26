# SQL Server 2025 Vector-Index-Analyse

**Status:** `IMPLEMENTED_ACTIONS_GATE`  
**Arbeitsumfang:** `SQL25-001`  
**Öffentliche Procedure:** `[monitor].[USP_VectorIndexAnalysis]`  
**Orchestrator:** `[monitor].[USP_ObjectAnalysis]` mit `@MitVectorIndexes = 1`

## Ziel

Der Slice verbindet zwei unterschiedliche Evidenzarten, ohne sie zu vermischen:

- `sys.vector_indexes` liefert die sichtbare, aktuelle Katalogdefinition eines
  Vector-Index;
- `sys.dm_db_vector_indexes` liefert den flüchtigen Zustand der letzten
  Hintergrundwartung und den ungefähren Stalenesswert.

Die Procedure bewertet keine Vector-Nutzdaten und führt keine Ähnlichkeitssuche
aus. Sie liest weder `build_parameters` noch Querytexte oder Pläne und führt
keine DDL-, Rebuild- oder Wartungsaktion aus.

## Versions- und Featuregrenze

Die öffentlichen Procedure- und Installerdateien bleiben auf SQL Server 2019
und 2022 parsbar. Die beiden SQL-Server-2025-Quellen stehen ausschließlich in
Dynamic SQL. Vor ihrer Referenz prüft die Procedure:

1. `ProductMajorVersion >= 17`;
2. die Existenz des jeweiligen Systemobjekts;
3. die dokumentierten Pflichtspalten;
4. bei Regexfiltern zusätzlich Compatibility Level 170.

Fehlt eine Grenze, entsteht ein expliziter Quellenstatus wie
`UNAVAILABLE_VERSION`, `UNAVAILABLE_FEATURE`,
`UNAVAILABLE_SOURCE_SCHEMA` oder `UNAVAILABLE_PATTERN_CAPABILITY`. Ein leeres
Array wird daher nie als Ersatz für einen Verfügbarkeitsstatus verwendet.

Der approximative Vector-Index-Pfad ist in SQL Server 2025 ein Previewfeature.
Ein aktiver Lauf benötigt Compatibility Level 170, die
Datenbankkonfiguration `PREVIEW_FEATURES = ON` und einen Build, der beide
Systemobjekte tatsächlich bereitstellt. Fehlt trotz aktivierter
Voraussetzungen eine Quelle, bleibt der Produktvertrag vollständig
auswertbar: `sourceStatus` liefert `UNAVAILABLE_FEATURE` oder bei abweichendem
Pflichtschema `UNAVAILABLE_SOURCE_SCHEMA`; der Modulstatus propagiert eine
solche partielle Schemagrenze als `AVAILABLE_LIMITED`, statt einen leeren
Erfolg oder eine vorgetäuschte aktive Fixture zu melden.

## Einmalread- und Scopevertrag

Je Zieldatenbank und Procedureaufruf wird jede der beiden fachlichen Quellen
höchstens einmal gelesen. Die Katalogquelle wird bereits mit Schema-, Objekt-
und Indexfiltern begrenzt. Die Runtime-DMV wird einmal datenbankweit
materialisiert und danach ausschließlich lokal mit den sichtbaren
Katalogkandidaten korreliert. Mehrere Resultsets oder Ausgabearten lösen keinen
zweiten Quellenread aus.

Cross-Database-Aufrufe verwenden den gemeinsamen Kandidatenvertrag des
Frameworks. Ein Fehler bleibt auf die betroffene Datenbank und Quelle begrenzt;
er verwirft keine bereits gültige Evidenz anderer Datenbanken.

## Resultsets

| Resultset | Aussage |
|---|---|
| `moduleStatus` | Gesamtstatus, Version, Scope, Zeilenzahlen und Begrenzungsmarker |
| `vectorIndexes` | sichtbare Definition, Typ, Distanzmetrik und Disabled-Status |
| `maintenance` | aktuelle DMV-Korrelation je sichtbarem Index |
| `findings` | eng begrenzte Reviewhinweise |
| `sourceStatus` | Quelle, Zeit, Berechtigung, Status und Fehlergrenze |
| `warnings` | partielle oder fehlgeschlagene Quellen |

RAW, JSON und benanntes TABLE verwenden dieselben lokalen Evidenztabellen.
CONSOLE zeigt nur `findings`. JSON enthält in `meta` eigene Zeilenzahlen und
`hasMore…`-Marker, sodass eine Begrenzung durch `@MaxZeilen` erkennbar bleibt.

## Bewertungsgrenzen

`VECTOR_STALENESS_REVIEW` verwendet den konfigurierbaren Wert
`@StalenessReviewPercent`, standardmäßig 15 Prozent. Der Wert ist ein
Reviewauslöser und kein automatischer Fehler- oder Rebuildgrenzwert. Laut
Microsoft kann erhöhte Staleness während Batchloads erwartbar sein; relevant
werden vor allem anhaltende Werte zusammen mit messbarer Recall- oder
Performanceverschlechterung.

`VECTOR_BACKGROUND_TASK_FAILED` beschreibt nur den letzten sichtbaren
Hintergrundtask. Ohne Wiederholung und Zeitverlauf beweist er kein dauerhaftes
Problem. `VECTOR_INDEX_DISABLED` beschreibt den aktuellen Katalogzustand, nicht
die Absicht oder Ursache.

Ein fehlender DMV-Datensatz wird als `NOT_RETURNED` beziehungsweise mit dem
Quellenstatus ausgewiesen. Er macht eine vorhandene Katalogzeile nicht
ungültig.

## Berechtigung und Datenschutz

Die Katalogsicht folgt der normalen Metadata Visibility. Die Runtime-DMV
erfordert `VIEW DATABASE STATE`. Fehler 229, 262, 297, 300, 371 und 916 werden
als `DENIED_PERMISSION` klassifiziert; Lock-Timeout 1222 bleibt davon getrennt.

Im Repository und in den Runtimefixtures kommen ausschließlich generische
`Example*`-Bezeichner und deterministische synthetische Vektoren vor. Die
Procedure erhebt keine Vektorwerte. Die von SQL Server bereitgestellte letzte
Hintergrundtask-Fehlermeldung bleibt auf den ausdrücklich sichtbaren Index und
den aktuellen Aufruf begrenzt.

## Nachweis

Der maschinenlesbare Vertrag liegt in
[`SQL25_Vector_Index_Public_Contract.json`](../../Metadata/Quality/SQL25_Vector_Index_Public_Contract.json).
Der Runtimevertrag `Code/Tests/ObjectIndex/120_SQL25_Vector_Index_Runtime_Contract.sql`
prüft SQL Server 2019, 2022 und 2025 sowie TABLE/JSON und das
ObjectAnalysis-Routing. Auf SQL Server 2025 aktiviert er zuerst Compatibility
Level 170 und `PREVIEW_FEATURES`. Stellt der Build die Quellen bereit, folgen
aktiver Katalog- und Wartungszustand, leere und begrenzte Ausgaben,
Cross-Database sowie verweigerte DMV-Berechtigung. Andernfalls muss derselbe
Build die fehlende Previewfähigkeit beziehungsweise Schemagrenze explizit als
`UNAVAILABLE_FEATURE` oder `UNAVAILABLE_SOURCE_SCHEMA` ausweisen; der Test
behauptet in diesem Fall keinen aktiven Featurepfad.

## Primärquellen

- [sys.vector_indexes (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-vector-indexes-transact-sql?view=sql-server-ver17)
- [sys.dm_db_vector_indexes (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-vector-indexes-transact-sql?view=sql-server-ver17)
- [CREATE VECTOR INDEX (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql?view=sql-server-ver17)
- [Vector search and vector indexes in the SQL Database Engine](https://learn.microsoft.com/en-us/sql/sql-server/ai/vectors?view=sql-server-ver17)
