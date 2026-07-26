# Ausgabe-Vertrag CONSOLE, RAW, TABLE und JSON

Stand: 2026-07-20

## Parameter

```sql
@ResultSetArt varchar(16) = 'CONSOLE',
@ResultTablesJson nvarchar(max) = NULL,
@JsonErzeugen bit = 0,
@Json nvarchar(max) = NULL OUTPUT
```

`@ResultSetArt` akzeptiert case-insensitiv `CONSOLE`, `RAW`, `TABLE` und
`NONE`. JSON kann unabhängig davon zusätzlich erzeugt werden.
`@ResultTablesJson` ist ausschließlich mit `TABLE` zulässig.

## Default

`CONSOLE` ist der frameworkweite Default, weil die Procedures primär für interaktive Ad-hoc-Analysen in SSMS oder Azure Data Studio vorgesehen sind. Technische Verbraucher müssen `RAW` oder `TABLE` ausdrücklich setzen. Ausschließlich JSON wird mit `@ResultSetArt = 'NONE', @JsonErzeugen = 1` angefordert.

## CONSOLE

Menschenorientierte Projektion. Eine einzelne Procedure liefert im Normalfall
genau ein fachliches Resultset. Ein separates technisches Meta-Grid sowie leere
Warning- oder Detail-Grids werden unterdrückt. Bei leerer Fachmenge erscheint
genau eine verständliche Zeile; Hinweise dürfen zusätzlich als `RAISERROR`
Severity 10 mit `NOWAIT` ausgegeben werden.

CONSOLE ist kein stabiler Importvertrag. Darstellungsspalten, Reihenfolge und Formatierung dürfen zur besseren Ad-hoc-Diagnose weiterentwickelt werden.

## RAW

Stabiler maschinenlesbarer Vertrag: typisierte Werte, keine Darstellungseinheiten, keine redundanten Schlüsselspalten und keine Titelzeilen. Mehrere fachliche Resultsets bleiben erlaubt und werden über gemeinsame Schlüssel verbunden.

RAW muss explizit angefordert werden:

```sql
EXEC [monitor].[USP_CurrentRequests]
    @ResultSetArt = 'RAW';
```

## TABLE

`TABLE` schreibt eine oder mehrere benannte, nativ typisierte Datenmengen in
lokale `#Temp`-Tabellen des Aufrufers. Semantische JSON-Properties ersetzen jede
positionsabhängige Zuordnung.

Der kanonische Aufruf ist:

```sql
CREATE TABLE #CurrentRequests_Result ([Dummy] int NULL);

EXEC [monitor].[USP_CurrentRequests]
      @MaxZeilen = 100
    , @ResultSetArt = 'TABLE'
    , @ResultTablesJson = N'{"requests":"#CurrentRequests_Result"}';

SELECT * FROM #CurrentRequests_Result;
```

Der Writer kennt zwei zulässige Zielzustände:

1. Eine leere Tabelle mit exakt einer beliebigen Dummy-Spalte. Der Writer ersetzt diese Spalte unabhängig von Name, Datentyp und Nullability durch die nativen Quellspalten.
2. Eine bereits exakt passende Spaltenstruktur. Der Writer hängt weitere Zeilen an.

Unbekannte Resultsetnamen, doppelte Namen oder Ziele sowie ungültige,
nicht vorhandene oder gefüllte Ziele werden atomar vor dem fachlichen
Systemzugriff abgelehnt. Spaltenname und -reihenfolge, Systemdatentyp, Länge
beziehungsweise `MAX`, Precision, Scale, Collation und Nullability müssen beim
Append übereinstimmen.

Bewusste Grenzen:

- Nur lokale `#Temp`-Tabellen sind erlaubt. Globale `##Temp`-Tabellen und permanente Tabellen werden abgelehnt.
- Das Präfix `#Monitor` ist für interne Tabellen reserviert.
- Frameworkinterne Temp-Tabellen tragen einen Bezug zur erzeugenden Procedure oder zum Skript; wiederverwendete Helper erhalten den konkreten lokalen Tabellennamen als Parameter.
- Tabellen besitzen keine garantierte Zeilenreihenfolge; Consumer müssen beim Lesen selbst `ORDER BY` setzen.
- Identity-, Computed-, CLR-/benutzerdefinierte, schema-gebundene XML- und `rowversion`-Spalten werden nicht automatisch reproduziert.
- Alle exportierbaren Namen und ihre geordneten nativen Schemas stehen in `Metadata/Inventory/ResultSets.csv`.
- Alle Ziele werden aus den bereits während desselben Aufrufs materialisierten Ergebnissen geschrieben. Der Export löst keine erneuten DMV-, Plan-Cache-, Query-Store-, Extended-Events- oder Katalogzugriffe aus.

Die Beschränkung auf lokale Temp-Tabellen ist auch eine Datenschutzgrenze: Persistenz, Aufbewahrung, Berechtigungen und Schema-Drift permanenter Ergebnistabellen müssen außerhalb des Frameworks bewusst entworfen werden.

## JSON

JSON verwendet ein Envelope mit `meta`, benannten fachlichen Arrays und `warnings`. Anonyme Namen wie `resultSet1` sind nicht zulässig. CONSOLE, RAW, TABLE und JSON beruhen auf derselben einmal ermittelten Datenbasis.

Textuelle Steuerwerte werden getrimmt und case-insensitiv normalisiert. SQL-Identifier und fachliche Namensfilter bleiben unter `SQL_Latin1_General_CP1_CS_AS` exakt case-sensitiv.
