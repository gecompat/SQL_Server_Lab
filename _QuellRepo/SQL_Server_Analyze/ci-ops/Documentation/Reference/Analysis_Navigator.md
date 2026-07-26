# Analysis Navigator – Katalog-, Such- und Relationsvertrag

`[monitor].[USP_AnalysisNavigator]` ist die Discovery-Schnittstelle des Frameworks. Sie priorisiert geeignete Procedures nach einer beobachteten Situation, einem Ziel, einem bekannten technischen Begriff oder einem expliziten Filter. Der Navigator ist kein Orchestrator: Er führt keine vorgeschlagene Procedure aus und liest keine fachlichen DMVs, Querytexte, Pläne, Ereignisdateien oder Benutzerdaten.

## Komponenten

| Objekt | Granularität | Aufgabe |
|---|---|---|
| `[monitor].[VW_AnalysisCatalog]` | genau eine Zeile je öffentlicher Procedure | kanonische Rolle, Primärbereich, Scope, Evidenzart, Kostenband, Paket, Voraussetzung, sicherer Aufruf und Dokumentationspfad |
| `[monitor].[VW_AnalysisSearchTerm]` | mehrere Zeilen je Procedure | deutsche und englische Symptome, Synonyme, Ziele und technische Begriffe mit fachlichem Gewicht und Trefferbegründung |
| `[monitor].[VW_AnalysisRelation]` | mehrere gerichtete Beziehungen | fachlich begründete Vertiefung, Gegenprobe, Alternative oder Vorbereitung zwischen öffentlichen Procedures |
| `[monitor].[USP_AnalysisNavigator]` | priorisierte Treffermenge je Aufruf | Suche, Filter, lokale Installationsprüfung, Kostenanreicherung und Ausgabe im Frameworkvertrag |

Die drei Views enthalten ausschließlich konstante Frameworkmetadaten. Ihre direkte Abfrage ist für Katalogauswertungen stabil dokumentiert; die Procedure bleibt die bevorzugte anwenderorientierte Schnittstelle.

## Vollständigkeitsmodell

Der Katalog enthält jede öffentliche Procedure aus `Metadata/Inventory/Objects.csv` genau einmal. Auch optionale Paketobjekte bleiben enthalten, wenn sie lokal nicht installiert sind. Eine primäre Rolle und ein primärer Bereich verhindern doppelte Katalogzeilen. Mehrfachzuordnungen entstehen stattdessen über Suchbegriffe und Relationen.

Unterstützende Views, TVFs, interne Procedures und Tabellen stehen vollständig in der [Objektreferenz](Object_Reference.md), sind aber keine eigenständigen Navigatorziele. Öffentlich aufrufbare technische Support-Procedures erhalten die Rolle `SUPPORT` und werden nur bei einer passenden expliziten Suche oder Filterung angeboten.

## Parameter

| Parameter | Default | Vertrag |
|---|---|---|
| `@Suchbegriff nvarchar(4000)` | `NULL` | maximal 400 tatsächlich belegte Zeichen; Symptom, Ziel, Fachbegriff, Anzeigename oder Procedure; DE und EN |
| `@Bereich varchar(40)` | `NULL` | exakter `PrimaryAreaCode`; case- und accent-insensitiv |
| `@Scope varchar(40)` | `NULL` | exakter `ScopeCode`; case- und accent-insensitiv |
| `@Navigationsrolle varchar(24)` | `NULL` | `ENTRY`, `FOLLOW_UP`, `TARGETED`, `SETUP` oder `SUPPORT` |
| `@NurInstallierte bit` | `0` | `0` zeigt den vollständigen Katalog; `1` nur lokal vorhandene Procedures |
| `@MaxZeilen int` | `12` | `NULL` oder `0` ohne Ergebnisbegrenzung; positive Werte von 1 bis 100 begrenzen die priorisierten Treffer |
| `@ResultSetArt varchar(16)` | `CONSOLE` | `CONSOLE`, `RAW`, `TABLE` oder `NONE` |
| `@ResultTablesJson nvarchar(max)` | `NULL` | bei `TABLE` genau `{"navigation":"#LokalesZiel"}` |
| `@JsonErzeugen bit` | `0` | erzeugt `meta` und `navigation` aus derselben Materialisierung |
| `@Json nvarchar(max) OUTPUT` | `NULL` | JSON-Ausgabeparameter |
| `@PrintMeldungen bit` | `1` | kontrolliert behandelte Informationsmeldungen |
| `@Hilfe bit` | `0` | gibt den kompakten Aufrufvertrag aus und beendet die Procedure |

Leere Werte für Suchtext oder Filter werden wie `NULL` behandelt. Unbekannte Bereichs-, Scope- oder Rollenwerte führen zu `INVALID_PARAMETER`, nicht zu einer stillen leeren Treffermenge.

## Such- und Rankingmodell

Die Suche verwendet ausdrücklich `Latin1_General_100_CI_AI`. Groß-/Kleinschreibung und Akzente der Installationsdatenbank verändern das Matching daher nicht. Das ist besonders für case-sensitive Installationen wichtig.

Die Priorisierung folgt diesen Ebenen:

1. exakter technischer Procedurename, auch in der Form `[monitor].[USP_Name]`;
2. exakter fachlicher Anzeigename;
3. exakter kuratierter Suchbegriff;
4. Phrase enthält Suchbegriff oder Suchbegriff enthält eine hinreichend lange Phrase;
5. Übereinstimmung wesentlicher Einzelwörter in Name, Bereich, Zweck oder Suchbegriffen;
6. kleiner Rollenbonus für `ENTRY`, danach `FOLLOW_UP`, `TARGETED`, `SETUP` und `SUPPORT`.

Suchphrasen besitzen ein Gewicht von 1 bis 100. Ein exakter hochgewichteter Begriff wie `Benutzer warten` soll deshalb vor einem nur teilweise passenden Memory- oder Workerpfad stehen. Der numerische `RelevanceScore` ist nur innerhalb eines Aufrufs vergleichbar. Er ist keine fachliche Schwere, kein Performancewert und kein dauerhafter API-Schlüssel.

Ohne Suchbegriff und Filter zeigt der Navigator die kuratierte Startliste nach `DefaultRank`. Mit einem Bereichs-, Scope- oder Rollenfilter werden passende Katalogobjekte rollenorientiert sortiert. Die Navigator-Procedure selbst wird nicht als eigener Treffer zurückgegeben.

## Rollen

| Code | Zweck | Typischer erforderlicher Kontext |
|---|---|---|
| `ENTRY` | erster sinnvoller Aufruf für ein Symptom oder Ziel | grobe Beobachtung genügt |
| `FOLLOW_UP` | vertieft oder bestätigt einen Ausgangsbefund | Signal und nächste Frage sind bekannt |
| `TARGETED` | analysiert ein bestimmtes Ziel | Datenbank, Objekt, Session, Query, Handle, XE-Session oder Plan-XML ist bekannt |
| `SETUP` | prüft oder betreibt Framework-/Paketkonfiguration | beabsichtigte Betriebswirkung ist verstanden |
| `SUPPORT` | technische Hilfsschnittstelle | nur nach dokumentiertem internen Aufrufvertrag |

`NavigationRole` beschreibt die Auffindbarkeit, nicht die Berechtigung. Eine `ENTRY`-Procedure kann optionale teurere Unterpfade besitzen; eine `TARGETED`-Procedure kann mit engem Scope vergleichsweise leicht sein.

## Primärbereiche

| Code | Fachlicher Bereich |
|---|---|
| `NAVIGATION` | Einstieg und Orientierung |
| `FRAMEWORK` | Capabilities, Ressourcenschutz und technische Aufrufverträge |
| `LIVE` | akute Störung, aktive Requests und aktueller Ressourcenstatus |
| `OBJECT` | Objekte, Indizes, Statistiken, Partitionen und Schemadesign |
| `PLAN` | Query Stats, Plan Cache, Showplan und Plan-XML |
| `QUERY_STORE` | persistierte Query-, Plan-, Laufzeit- und Wait-Historie |
| `EXTENDED_EVENTS` | Sessions, Targets und Ereignishistorie |
| `OPERATIONS` | Agent, Backup, HA/DR, Replikation und Betrieb |
| `SERVER` | CPU, NUMA, Memory, Worker, Konfiguration und Server Health |
| `SPECIAL_FEATURE` | Version, Capability, Inventur und Spezialfeatures |
| `SNAPSHOT` | optionales persistentes Snapshot-/Baseline-Paket |

Ein Primärbereich ist keine Exklusivzuordnung. Blocking gehört beispielsweise zugleich zu Live-Triage, Transaktionen, Performance und möglicher XE-Historie; diese zusätzlichen Pfade erscheinen über Suchbegriffe und Relationen.

## Scope und Evidenzart

`ScopeCode` beschreibt den für einen sinnvollen Aufruf erforderlichen Untersuchungsumfang:

| Scope | Bedeutung |
|---|---|
| `FRAMEWORK` | lokale Frameworkmetadaten oder ein technischer Frameworkvertrag |
| `SERVER` | gesamte SQL-Server-Instanz |
| `DATABASE` | genau eine fachlich gewählte Datenbank |
| `MULTI_DATABASE` | eine explizit begrenzte Menge zugänglicher Datenbanken |
| `SESSION_REQUEST` | bekannte oder aktuell relevante Session beziehungsweise Request |
| `OBJECT` | bekanntes Schema-, Tabellen-, Index- oder Statistikobjekt |
| `QUERY` | bekannte Queryidentität, Hash, Handle oder Query-Store-ID |
| `PLAN_XML` | bereits vorhandenes oder gezielt auflösbares Ausführungsplan-XML |
| `EVENT_SESSION` | bekannte Extended-Events-Session oder ihr Target |
| `EVENT_HISTORY` | vorhandene, zeitlich begrenzte Ereignishistorie |
| `INFRASTRUCTURE` | betrieblicher Server-, Agent-, Backup-, HA/DR- oder Replikationskontext |
| `SNAPSHOT_TARGET` | separat konfiguriertes Ziel des optionalen Snapshotpakets |

`EvidenceType` grenzt die Aussage zeitlich und technisch ein:

| Evidenzart | Aussagegrenze |
|---|---|
| `FRAMEWORK_METADATA` | statischer oder lokal installierter Frameworkzustand |
| `LIVE_SNAPSHOT` | flüchtiger Zustand im Erfassungsmoment |
| `SAMPLE_DELTA` | Veränderung während eines begrenzten Messintervalls |
| `CUMULATIVE_DMV` | kumuliert seit quellenabhängigem Reset, Start oder Cacheeintrag |
| `PERSISTED_HISTORY` | Historie innerhalb Capture- und Retentiongrenzen |
| `EVENT_HISTORY` | nur konfigurierte und noch vorhandene Ereignisse |
| `CATALOG_CONFIGURATION` | sichtbarer Katalog- oder Konfigurationszustand |
| `STATIC_INPUT` | vom Benutzer bereitgestellte, unveränderte Eingabe wie ein Plan-XML oder typisierte Laufzeitevidenz |
| `MIXED` | mehrere ausdrücklich zu unterscheidende Evidenzarten |
| `PERSISTED_SNAPSHOT` | lokal persistierte Snapshotdaten des optionalen Pakets |

Die Codes sind Such- und Orientierungshilfen. Die genaue Zeit-, Reset- und Granularitätssemantik bleibt Bestandteil der jeweiligen Procedure-Seite.

## Kosten- und Freigabekontext

`CostRangeCode` beschreibt die dokumentierte Spannweite vom sicheren Einstieg bis zum teuersten optionalen Pfad:

| Kostenband | Bedeutung |
|---|---|
| `LOW` | Metadaten- oder eng begrenzter Snapshotpfad ohne dokumentierten mittleren oder hohen Teilpfad |
| `LOW_MEDIUM` | leichter Einstieg mit abhängig von Sample, Scope oder Details mittlerem Pfad |
| `MEDIUM` | bereits der fachlich sinnvolle Standardpfad besitzt mittlere Eigenlast |
| `LOW_HIGH_OPT_IN` | leichter Einstieg; hoher Pfad existiert nur nach bewusster Aktivierung und Schutzprüfung |
| `MEDIUM_HIGH_OPT_IN` | mittlerer Einstieg; hoher Vertiefungspfad bleibt ausdrücklich opt-in |
| `HIGH_OPT_IN` | der sinnvolle Einstieg ist ein bewusst gewählter High-Impact-Pfad und benötigt die dokumentierte Bestätigung |

`RepresentativeAnalysisClass` verweist auf `[monitor].[VW_AnalyseClassCatalog]`. Daraus reichert der Navigator `AnalysisLevel` und `RequiresGroupGate` an. Diese Klasse ist repräsentativ, nicht zwingend der einzige Laufzeitpfad der Ziel-Procedure. Der tatsächliche Aufruf kann abhängig von Filtern, Detailschaltern und `@HighImpactConfirmed` eine andere Analyseklasse prüfen.

Deshalb sind drei Felder getrennt:

- `RequiresHighImpactForSafeStart`: Bereits der erste fachliche Datenzugriff des empfohlenen Einstiegspfads benötigt eine ausdrückliche Bestätigung; `@Hilfe = 1` bleibt davon unberührt.
- `HighImpactPathAvailable`: Die Procedure besitzt mindestens einen als hoch eingestuften Pfad. Ob dieser Pfad optional ist und ob er ein ausdrückliches Gate besitzt, ergibt sich aus Kostenband, Procedure-Seite und Laufzeitparametern; das Feld allein behauptet kein Gate.
- `RequiresGroupGate`: Die repräsentative Analyseklasse unterliegt der internen Gruppenpolicy.

Der Navigator selbst benötigt kein High-Impact-Gate. Er führt keine fachliche Quellabfrage aus.

## Beziehungen und nächste Schritte

| Relation | Bedeutung |
|---|---|
| `REFINE_WITH` | ein vorhandenes Signal mit einer spezialisierten Sicht vertiefen |
| `CONFIRM_WITH` | eine unabhängige oder anders gemessene Evidenz gegenprüfen |
| `ALTERNATIVE_TO` | einen anderen Zugang bei abweichender verfügbarer Eingabe verwenden |
| `PREPARE_WITH` | Voraussetzung oder Betriebszustand für den nächsten Pfad herstellen |

`NextProcedureName` ist die höchstpriorisierte Relation für den Treffer. `NextStep` beschreibt die Bedingung. Weitere gültige Übergänge können direkt aus `VW_AnalysisRelation` gelesen werden:

```sql
SELECT
      [RelationType],
      [ToProcedureName],
      [RelationPriority],
      [ConditionSummary]
FROM [monitor].[VW_AnalysisRelation]
WHERE [FromProcedureName] = N'USP_CurrentBlocking'
ORDER BY [RelationType], [RelationPriority];
```

Eine Relation ist eine Untersuchungsreihenfolge, keine automatische Kausalitätsbehauptung.

## Paket- und Installationsstatus

`PackageCode` unterscheidet:

- `CORE`: Bestandteil des vollständigen Installers;
- `CORE_PLAN_STANDALONE`: Bestandteil des vollständigen Installers und des eigenständigen PLAN-001-Pakets;
- `SNAPSHOT_OPTIONAL`: nur im separat installierten Snapshot-/Baseline-Paket.

`IsInstalled` wird pro Aufruf durch eine lesende Verknüpfung mit `sys.schemas` und `sys.procedures` bestimmt. Der Wert sagt nur, ob die Procedure lokal unter `[monitor]` vorhanden ist. Er beweist weder die nötigen Serverrechte noch die Verfügbarkeit ihrer fachlichen Quellen. Für diese Fragen dienen `USP_CheckFrameworkCapabilities` und die Statusresultsets der Ziel-Procedure.

## Ergebnisvertrag

Das benannte Primärergebnis `navigation` enthält:

- Rang und Relevanz;
- Procedure, Anzeigename, Rolle, Bereich und Scope;
- Evidenz-, Kosten- und repräsentative Analyseklasse;
- Trefferbegründung, Zweck und Voraussetzungen;
- Target-, High-Impact-, Paket- und Installationsstatus;
- sicheren Aufruf, priorisierte Relation und Dokumentationspfade.

`RAW` gibt zuerst einen Modulstatus und danach `navigation` aus. `CONSOLE` liefert genau eine beschriftete Fachansicht oder bei Leere eine verständliche Statuszeile. `TABLE` schreibt ausschließlich `navigation` in eine lokale `#Temp`-Tabelle. `NONE` unterdrückt Resultsets. JSON enthält `meta` und `navigation` aus derselben Materialisierung.

```sql
CREATE TABLE #ExampleNavigation ([Seed] int NULL);

EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'query regression',
      @ResultSetArt = 'TABLE',
      @ResultTablesJson = N'{"navigation":"#ExampleNavigation"}';

SELECT *
FROM #ExampleNavigation
ORDER BY [Rank];
```

## Statuscodes

| Status | Bedeutung |
|---|---|
| `AVAILABLE` | gültige Anfrage mit mindestens einem Treffer |
| `NO_MATCH` | gültige Anfrage, aber kein Treffer nach allen Filtern |
| `INVALID_PARAMETER` | ungültige Ausgabeart, Grenze, Rolle, Bereich, Scope oder Suchtextlänge |
| `LOCK_TIMEOUT` | lokale Systemmetadaten konnten unter dem No-Wait-Vertrag nicht gelesen werden |
| `ERROR_HANDLED` | sonstiger behandelter Fehler bei der Katalogauswertung |

`NO_MATCH` ist nicht partiell. Es ist auch kein Beweis, dass das Framework keine geeignete Funktion besitzt: Begriff verkürzen, Filter entfernen oder den vollständigen Katalog nach Bereich lesen.

## Direkte Katalogabfragen

Alle Einstiege eines Bereichs:

```sql
SELECT
      [ProcedureName], [DisplayName], [NavigationRole], [ScopeCode],
      [EvidenceType], [CostRangeCode], [SafeCall]
FROM [monitor].[VW_AnalysisCatalog]
WHERE [PrimaryAreaCode] = 'LIVE'
ORDER BY
      CASE [NavigationRole] WHEN 'ENTRY' THEN 1 ELSE 2 END,
      [DisplayName];
```

Alle Suchbegriffe eines Objekts:

```sql
SELECT [LanguageCode], [SearchTerm], [SearchWeight], [MatchReason]
FROM [monitor].[VW_AnalysisSearchTerm]
WHERE [ProcedureName] = N'USP_CurrentTempDB'
ORDER BY [SearchWeight] DESC, [SearchTerm];
```

Diese Abfragen führen ebenfalls keine Diagnose aus.

## Aussagegrenzen

- Der Katalog kennt Frameworkobjekte, nicht die konkrete Root Cause einer Instanz.
- Ranking ist eine Auswahlhilfe und keine Schweregradbewertung.
- Ein sicherer Beispielaufruf bleibt an die eigene Umgebung, Berechtigung und Zielwahl anzupassen.
- `RepresentativeAnalysisClass` ersetzt keine pfadabhängige Laufzeitprüfung.
- `IsInstalled` ersetzt keine Capability-, Rechte- oder Featureprüfung.
- Dokumentationspfade sind relative Pfade innerhalb der mitgelieferten Dokumentation und keine SQL-Server-URLs.
- Der Navigator ändert keine Konfiguration, erstellt keine XE-Session, startet keinen Job und speichert keine Diagnosedaten.

Für die praktische Auswahl dient [Hier beginnen](../Analysis_Guides/Start_Here.md). Für Parameterdefaults und Datentypen siehe die [Procedure-Referenz](Procedure_Reference.md); für jede unterstützende Komponente die [Objektreferenz](Object_Reference.md).
