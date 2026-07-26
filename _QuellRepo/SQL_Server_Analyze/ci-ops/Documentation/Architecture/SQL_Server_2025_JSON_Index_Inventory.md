# SQL Server 2025 JSON-Index-Inventar

**Status:** `IMPLEMENTED_ACTIONS_GATE`  
**Arbeitsumfang:** `SQL25-002`  
**Öffentliche Procedures:** `[monitor].[USP_ObjectInventory]` und
`[monitor].[USP_ServerFeatureCapabilities]`  
**Orchestrator:** `[monitor].[USP_ObjectAnalysis]` über den bestehenden
Objektinventarpfad

## Ziel

Der Slice erweitert die vorhandenen Objekt-, Index- und
Feature-Capability-Inventare um zwei ausschließlich strukturelle
SQL-Server-2025-Quellen:

- `sys.json_indexes` liefert die sichtbare JSON-Indexdefinition einschließlich
  `optimize_for_array_search`;
- `sys.json_index_paths` liefert die zu einem sichtbaren JSON-Index gehörenden
  SQL/JSON-Pfade.

Es wurde bewusst keine eigene JSON-Index-Procedure angelegt. Das Inventar
beantwortet, welche Definition im sichtbaren Scope existiert und welchen
Capabilitystatus die Quellen besitzen. Es liest keine Zeilen aus
Benutzertabellen, keine JSON-Dokumentwerte, keine Querytexte und keine Pläne.
Es führt keine DDL-, Rebuild- oder Wartungsaktion aus.

## Versions- und Featuregrenze

Die öffentlichen Dateien bleiben auf SQL Server 2019 und 2022 parsbar. Die
beiden SQL-Server-2025-Quellen stehen ausschließlich in Dynamic SQL. Vor einer
Referenz prüft jeder Produktpfad:

1. `ProductMajorVersion >= 17`;
2. die Existenz des jeweiligen Systemobjekts;
3. die dokumentierten Pflichtspalten;
4. den sichtbaren Datenbank- und Objektscope.

JSON-Indizes sind in SQL Server 2025 ein Previewfeature. Ein aktiver
Runtimenachweis benötigt Compatibility Level 170, `PREVIEW_FEATURES = ON`,
den nativen Datentyp `json` und einen Build, der beide Katalogsichten mit den
benötigten Spalten bereitstellt. Fehlt eine Voraussetzung, entstehen
explizite Zustände wie `UNAVAILABLE_VERSION`, `UNAVAILABLE_FEATURE` oder
`UNAVAILABLE_SOURCE_SCHEMA`. Eine Schemagrenze der Pfadquelle wird als
`AVAILABLE_LIMITED` propagiert, wenn die Indexquelle trotzdem auswertbar ist.

## Einmalread- und Scopevertrag

Je Zieldatenbank und Procedureaufruf wird jede fachliche Quelle höchstens
einmal gelesen. `USP_ObjectInventory` materialisiert zuerst die im bereits
gewählten Objekt-/Indexscope sichtbaren JSON-Indizes und liest danach die
zugehörigen Pfade. `USP_ServerFeatureCapabilities` materialisiert die
Pfadanzahl und die sichtbaren JSON-Indizes ebenfalls je höchstens einmal.
Mehrere Ausgabearten lösen keinen zusätzlichen Quellenread aus.

Die Pfadquelle wird nicht gelesen, wenn im gewählten Scope kein sichtbarer
JSON-Index vorhanden ist. Fehler der optionalen SQL-Server-2025-Quellen bleiben
auf die betroffene Datenbank und Teilquelle begrenzt; die allgemeine
Objektinventur wird weiter ausgeführt.

## Öffentlicher Ausgabezusatz

Das bestehende Resultset `objects` von `USP_ObjectInventory` erhält:

| Feld | Aussage |
|---|---|
| `IsJsonIndex` | sichtbare Indexzeile stammt aus `sys.json_indexes` |
| `OptimizeForArraySearch` | sichtbarer Katalogwert der Array-Suchoption |
| `JsonPathCount` | Zahl sichtbarer Pfadmetadaten dieser Indexzeile |
| `JsonPaths` | aggregierte sichtbare SQL/JSON-Pfadmetadaten |
| `JsonIndexStatusCode` | Version-, Feature-, Schema-, Sichtbarkeits- oder Fehlerstatus |
| `JsonIndexEvidenceLimit` | konkrete Aussagegrenze dieses Aufrufs |

`databaseStatus` ergänzt denselben Status sowie Index-/Pfadzeilenzähler,
Fehlernummer und gekürzte Fehlermeldung. Dadurch sind eine fehlende Quelle,
ein leerer oder eingeschränkt sichtbarer Scope und eine partielle Pfadquelle
voneinander unterscheidbar.

`USP_ServerFeatureCapabilities` ergänzt
`JSON_INDEX_METADATA` in `databaseFeatures` und `JSON` in
`specialIndexes`. `IndexDetails` enthält nur strukturelle Angaben zu
Array-Suchoption, Pfadanzahl und Disabled-Status; konkrete Pfadwerte werden in
diesem breiten Capability-Inventar nicht ausgegeben.

RAW, JSON und benanntes TABLE stammen aus derselben lokalen Materialisierung.
`USP_ObjectAnalysis` gibt den erweiterten `objectInventory`-Vertrag über seinen
bereits vorhandenen Childpfad weiter.

## Bewertungsgrenzen

Ein sichtbarer JSON-Index ist kein Health-, Nutzungs-, Nutzen-, Redundanz- oder
Rebuildbefund. `JsonPathCount` und `OptimizeForArraySearch` beschreiben nur die
aktuell sichtbare Definition; sie beweisen nicht, dass Pfade und Optionen zur
Workload passen.

`AVAILABLE_EMPTY_OR_RESTRICTED` trennt einen leeren sichtbaren Scope nicht
künstlich von eingeschränkter Metadata Visibility. Für eine belastbare
Abwesenheitsaussage muss der aufrufende Sicherheitskontext die betroffenen
Objekte sehen können. Ein fehlender Pfadkatalog entwertet außerdem keine
bereits sichtbare Indexdefinition; er begrenzt nur deren Pfadevidenz.

## Berechtigung und Datenschutz

Beide Katalogsichten folgen der normalen Metadata Visibility. Das Framework
vergibt keine Berechtigung. Fehler 229, 262, 297, 300, 371 und 916 werden als
`DENIED_PERMISSION` klassifiziert; Lock-Timeout 1222 bleibt davon getrennt.

Runtimefixtures verwenden ausschließlich kurzlebige `Example*`-Objekte und
synthetische Pfadliterale. In die Tabellen werden keine JSON-Dokumentzeilen
geschrieben. Die Produktpfade lesen weder JSON-Dokumentwerte noch
Benutzertabellenzeilen.

## Nachweis

Der maschinenlesbare Vertrag liegt in
[`SQL25_JSON_Index_Public_Contract.json`](../../Metadata/Quality/SQL25_JSON_Index_Public_Contract.json).
Der Runtimevertrag
`Code/Tests/ObjectIndex/121_SQL25_JSON_Index_Inventory_Runtime_Contract.sql`
prüft SQL Server 2019, 2022 und 2025, den erweiterten TABLE-/JSON-Vertrag,
ObjectAnalysis-Routing und das Capability-Inventar.

Auf SQL Server 2025 aktiviert der Test die Previewvoraussetzungen zuerst.
Stellt der konkrete Build den aktiven Pfad bereit, prüft er zwei synthetische
JSON-Indizes, mehrere Pfade, die Array-Suchoption, Begrenzung, leeren Scope und
eingeschränkte Metadata Visibility. Andernfalls muss die konkrete
Feature-, Schema- oder Buildgrenze explizit ausgewiesen werden; der Test
behauptet dann keinen aktiven Featurepfad.

## Primärquellen

- [sys.json_indexes (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-indexes-transact-sql?view=sql-server-ver17)
- [sys.json_index_paths (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-index-paths-transact-sql?view=sql-server-ver17)
- [CREATE JSON INDEX (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-json-index-transact-sql?view=sql-server-ver17)
