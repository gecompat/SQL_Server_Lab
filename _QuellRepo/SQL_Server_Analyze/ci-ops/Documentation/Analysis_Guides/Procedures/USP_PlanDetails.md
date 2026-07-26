# [monitor].[USP_PlanDetails]

**Bereich:** Plan Cache<br>
**Zweck:** Löst gezielte Plan-Kandidaten auf und liefert Attribute sowie Compile-, Last-Actual- oder Live-Plan.<br>
**Beobachtungsart:** flüchtiger Cache-Snapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Attribute, Texte, Statements und Planinformationen gehören zu einem konkreten Handle?** Sie unterstützt die Entscheidung, welche aktuell gecachten Query-/Plan-Kandidaten vertieft werden sollen und welche Historienquelle die flüchtige Cachebeobachtung bestätigen muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige Workloadhistorie; evictete Pläne, nicht gecachte Statements und Ursachen außerhalb des Plans bleiben unsichtbar. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_PlanDetails]
      @SessionIds = N'57',
      @MitCompilePlan = 1,
      @MitLastActualPlan = 0,
      @MitLivePlan = 0,
      @MaxAnalyseobjekte = 5,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Die Session-ID ist vollständig synthetisch. Arbeiten Sie alternativ gezielt mit einem vorhandenen Plan Handle oder Query Hash und vermeiden Sie breite Läufe.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `candidates`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Kandidaten-, Attribut- und Planresultsets besitzen unterschiedliche Granularität: Kandidat, Attribut je Kandidat beziehungsweise Planquelle je Kandidat.

## So lesen

Bestimmen Sie zuerst die Kandidatenidentität. Unterscheiden Sie danach die Cache-Key-Attribute und schließlich die Planquelle: Compile, Last Actual oder Live.

## Warum kann das problematisch sein?

Abweichende Cache-Key-Attribute können mehrere Handles erzeugen. Actual-Pläne können große Schätzfehler, Spills und reale Zeilenmengen sichtbar machen.

## Wann ist es kein Problem?

Compile-Pläne enthalten nur Schätzungen. Fehlende Actualwerte sind daher kein Queryfehler.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Identischer Text mit unterschiedlichen `set_options` erklärt getrennte Cacheeinträge. Verwenden Sie danach `USP_ShowplanAnalysis` oder manuellen Planvergleich.

**Ähnlich aussehender Gegenfall:** Compile-Pläne enthalten nur Schätzungen. Fehlende Actualwerte sind daher kein Queryfehler. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Im Plan Cache kann leer bedeuten: evicted, nie gecacht, recompile, falscher Datenbank-/Hashfilter oder fehlender Text-/Planzugriff.

Für `USP_PlanDetails` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Zielgerichtet und auf @MaxAnalyseobjekte begrenzt. Mehr als 20 Pläne prüft PLAN_CACHE_DEEP. Das Framework aktiviert keine Profilingoption.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Ohne Session/Handle/Hash entsteht keine Candidate-Zeile. Mit einem Selektor werden höchstens 20 Kandidaten ermittelt und standardmäßig Attribute, Compile-XML und auf 8000 Zeichen gekürzter SQL-Text je Kandidat geladen. |
| Teuerster Pfad | `@MaxAnalyseobjekte = 0` mit vollständigen Compile-, Text-, Last-Actual- oder Live-Plänen und ungekürztem SQL-Text. |
| Haupttreiber | Kandidatenzahl und Größe der angeforderten Planrepräsentationen. Sessionfilter liest aktive Requests, PlanHandle ist direkt, SQL-/QueryHash filtern `sys.dm_exec_query_stats`; danach entstehen planweise Attribute, Text und XML. |
| Skalierung | Detailaufrufe wachsen ungefähr mit Kandidaten × aktivierten Planquellen. Planattribute und SQL-Text werden je Candidate separat aufgelöst; große XML-Pläne erhöhen Speicher und Netzwerk, werden hier aber nicht in Operatorzeilen geschreddert. |
| Ressourcen | CPU und Speicher für Kandidaten-/Handleauflösung, Planattribute und optionale Compile-, Text-, Last-Actual- oder Live-Plan-XML; großer Transfer bei breiten Plänen. Die Procedure führt kein fachliches XML-Shredding in Operatorresultsets aus. |
| Begrenzungswirkung | `@MaxAnalyseobjekte` begrenzt Kandidaten vor der planweisen Detailauflösung; 0 bedeutet unbegrenzt. Das SQL-Textzeichenlimit begrenzt nur Textbreite. Einen separaten Ergebniszeilen- oder Deadlineparameter besitzt diese Procedure nicht. |
| Locking und Nebenwirkungen | Keine Nutzdatenänderung; Live-Plan-Zugriff beobachtet aktive Requests und Cachehandles können verschwinden. XML-Auswertung kann Schedulerzeit verbrauchen. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `PLAN_CACHE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Genau einen `ExampleQueryHash`/PlanHandle oder eine synthetische Session, maximal fünf Candidates und zunächst nur Compile-Plan. Last-Actual/Live separat und bewusst anfordern; einen `VOLL`-Modus gibt es nicht. |
| Aussagegrenze | Ein Planhandle kann zwischen Candidate- und Detailauflösung verschwinden. Last Actual existiert nur bei bereits aktivierter Engineerfassung; Live zeigt den laufenden Zeitpunkt. Fehlendes XML bedeutet deshalb nicht „kein Plan“ und Candidate-TOP keine repräsentative Planmenge. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Attribute, Texte, Statements und Planinformationen gehören zu einem konkreten Handle?

### Technischer Hintergrund

SQL-/Planhandles referenzieren flüchtige Cacheobjekte. Plan Attributes enthalten DBID, Set Options, User-/Languagekontext und weitere Cachekeyeinflüsse. Unterschiedliche SET Options können separate Pläne derselben Textform erzeugen.

### Datenkette

`sys.dm_exec_plan_attributes`, `sys.dm_exec_query_plan`, `sys.dm_exec_query_plan_stats`, `sys.dm_exec_query_statistics_xml`, `sys.dm_exec_query_stats`, `sys.dm_exec_requests`, `sys.dm_exec_sql_text`, `sys.dm_exec_text_query_plan`.

### Source Select

Ein exaktes Plan-Handle vermeidet eine breite Cache-Suche und verbindet Planinhalt mit ausgewählten Planattributen:

```sql
SELECT
      [qp].[query_plan]
    , [pa].[attribute]
    , [pa].[value]
FROM [sys].[dm_exec_query_plan](@PlanHandle) AS [qp]
CROSS APPLY [sys].[dm_exec_plan_attributes](@PlanHandle) AS [pa]
WHERE [pa].[attribute] IN (N'dbid', N'objectid', N'set_options');
```

**Wichtig für die Eigenlast:** Geben Sie Handle oder Session vor Planbeschaffung eindeutig an. Last-Actual- und Live-Planquellen nur gezielt aktivieren; XML und vollständiger SQL-Text können Transfer und Speicher deutlich erhöhen.

### Zeit- und Scope-Modell

Die Auswertung liefert eine Momentaufnahme eines Cacheeintrags. Das Handle kann zwischen Auswahl und Detailabruf aus dem Cache entfernt werden.

### Bewertung und Gegenprobe

Berücksichtigen Sie Plan Attributes, Statementoffset, Creation/Last Execution, Use Count und XML gemeinsam. Set-Option-Unterschiede können scheinbare Planverdoppelung erklären.

### Typische Fehlinterpretation

Ein Handle ist keine persistente Referenz und darf nicht langfristig gespeichert werden, ohne Gültigkeitsprüfung.

### Folgeanalyse

Verwenden Sie für die weitere Analyse `USP_ShowplanAnalysis` und Query-Store-IDs für eine dauerhaftere Korrelation.

## Primärquellen

- [sys.dm_exec_query_plan](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-plan-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../04_Plan_Cache.md#4-monitorusp_plandetails)
`USP_PlanDetails` bleibt die native Plan-/Attributansicht. Für normalisierte
Warnungs-, Optimizer-, Runtime-, Query-Store- und Variantenresultsets reichen
Sie das ausgewählte Planhandle anschließend an `USP_ExecutionPlanAnalysis`
weiter; die Detailprocedure führt keine konkurrierende XML-Zerlegung aus.

