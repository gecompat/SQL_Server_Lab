# [monitor].[USP_PrepareDatabaseCandidates]

**Bereich:** Common, interner Auswahlvertrag<br>
**Zweck:** Befüllt die vom Aufrufer bereitgestellte Datenbank-Kandidatenliste.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Datenbanken gehören tatsächlich zum Cross-Database-Auftrag und dürfen sicher verarbeitet werden?** Sie unterstützt die Entscheidung, ob der gewünschte Analysepfad sicher und eindeutig vorbereitet ist oder der Fachaufruf wegen Policy, Capability oder ungültigem Scope unterbleiben muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Performance- oder Verfügbarkeitsursache und keine Aussage über Daten außerhalb des aktuellen Execution-Kontexts. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

Diese interne Procedure setzt exakt definierte lokale Temp-Tabellen voraus. Deren procedurebezogene Namen werden mit `@CandidateTable` und optional `@WarningTable` übergeben. Sie liefert keine normalen Analyse-Resultsets; die aufrufende Procedure ist der öffentliche Einstieg.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Diese Hilfsprocedure besitzt bewusst keinen öffentlichen TABLE-Export. Sie befüllt die vom Parent bereitgestellten Temp-Strukturen beziehungsweise OUTPUT-Statuswerte. Zuerst sind Status und Warnungen des Parents zu lesen; erst danach darf dessen Fachresultset interpretiert werden. Ein direkter Aufruf ohne den dokumentierten Tabellenvertrag ist kein Ersatz für den Parentpfad.

## Eine Zeile bedeutet

Eine Zeile in der über `@CandidateTable` benannten Tabelle entspricht einer für den aktuellen Lauf akzeptierten Datenbank. Warnzeilen in `@WarningTable` dokumentieren angeforderte, aber nicht nutzbare Scopes.

## So lesen

Berücksichtigen Sie Kandidaten, Warnungen und OUTPUT-Status gemeinsam. Prüfen, ob jede ausdrücklich angeforderte Datenbank tatsächlich in der Kandidatenliste enthalten ist.

## Warum kann das problematisch sein?

Eine offline, unsichtbare oder unzulässige Datenbank fehlt in der Fachanalyse. Wird die Warnung ignoriert, kann ein unvollständiger Scope fälschlich als Entwarnung erscheinen.

## Wann ist es kein Problem?

Eine große sichtbare Datenbankmenge ist allein kein Deep-Pfad. Die Auswahl wird
nicht vorab gekürzt; erst die tatsächlich aktivierte Analyseklasse entscheidet,
ob `@HighImpactConfirmed = 1` erforderlich ist.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Zwei Datenbanken werden angefordert, eine ist offline. Das Fachergebnis enthält nur die online Datenbank; die fehlende Datenbank muss als nicht untersuchter Scope dokumentiert werden.

**Ähnlich aussehender Gegenfall:** Eine große sichtbare Datenbankmenge ist allein kein Deep-Pfad. Die Auswahl wird
nicht vorab gekürzt; erst die tatsächlich aktivierte Analyseklasse entscheidet,
ob `@HighImpactConfirmed = 1` erforderlich ist. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Hilfsprocedures kann eine leere interne Zieltabelle aus bewusst leerem Filter, ungültiger Eingabe oder fehlender Policy entstehen; diese Fälle dürfen nicht zu einem ungefilterten Parentlauf zusammenfallen.

Für `USP_PrepareDatabaseCandidates` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Validiert Listen/Pattern und lokale Zieltabellenschemas, prüft optional genau eine Analyseklasse und materialisiert alle passenden sichtbaren Online-Datenbanken aus `TVF_DatabaseCandidates`. Ohne Scope sind das alle Benutzerdatenbanken. |
| Teuerster Pfad | Sehr lange explizite Liste oder Regex über eine Instanz mit vielen Datenbanken, Systemdatenbanken eingeschlossen und Warningtabelle aktiv. Die Procedure öffnet die Kandidatendatenbanken nicht und liest keine Fachkataloge. |
| Haupttreiber | Zahl der `master.sys.databases`-Zeilen und Eingabeelemente. Dynamisches SQL prüft nur die vom Parent angelegten lokalen Temp-Tabellenschemas und kopiert Kandidaten/Warnings. |
| Skalierung | Linear mit Datenbank- und Listenzahl; case-sensitive Duplikat-/Syntaxprüfung ist klein. Regex kann auf allen Datenbanknamen arbeiten, bleibt aber reine Namensfilterung. |
| Ressourcen | Master-Metadaten, Parser-TVFs und lokale Temp-Tabellen. Kein Login-Token-, Capability-, `msdb`- oder Nutzdatenscan. |
| Begrenzungswirkung | Es gibt absichtlich keine Datenbank-Mengenbegrenzung. Exakte Liste/Pattern reduzieren Kandidaten; der Parent muss spätere Facharbeit selbst limitieren. Fehlende explizite Namen werden separat als Warning erzeugt. |
| Locking und Nebenwirkungen | Read-only gegenüber Systemkatalogen und Schreibzugriff nur auf lokale Parent-Temp-Tabellen. Datenbankstatus kann sich nach Kandidatenermittlung ändern. |
| Schutzmechanismus | Nur bei nichtleerem `@AnalysisClass` ruft die Procedure `InternalCheckAnalysisPath` auf; verlangt diese Klasse ein Gruppengate, ist `@HighImpactConfirmed = 1` nötig. `NULL` bedeutet bewusst keine Gateprüfung, nicht automatische Freigabe eines späteren Childpfads. |
| Sicherer Einsatz | Nur als Parent-Helfer mit korrekt angelegter Kandidaten-/Warningtabelle; für Produktionsanalysen eine `ExampleDatabase` statt des NULL-Scopes dokumentieren. |
| Aussagegrenze | Kandidat bedeutet sichtbar, online und filterkonform zum Ermittlungszeitpunkt. Es beweist weder spätere CONNECT-/Objektberechtigung noch erfolgreichen Cross-Database-Zugriff; Statuswechsel bleiben Sache des Fachmoduls. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Datenbanken gehören tatsächlich zum Cross-Database-Auftrag und dürfen sicher verarbeitet werden?

### Technischer Hintergrund

Die Procedure bildet aus exakten Namen oder Pattern einen stabilen Kandidatenscope. Ohne explizite Einschränkung liefert sie alle sichtbaren, zugreifbaren und online befindlichen Benutzerdatenbanken. Es gibt keinen CURRENT-Scope und keine Vorabbegrenzung. Systemdatenbanken sind opt-in. Die Procedure prüft zusätzlich die vom Aufrufer tatsächlich aktivierte Analyseklasse und beendet einen bestätigungspflichtigen Pfad vor dem teuren Fachzugriff mit `HIGH_IMPACT_CONFIRMATION_REQUIRED`.

### Datenkette

`master.sys.databases`, `sys.sp_executesql`.

### Source Select

Der zentrale Kandidatenpfad beginnt direkt im serverweiten Datenbankkatalog:

```sql
SELECT
      [d].[database_id]
    , [d].[name]
    , [d].[state_desc]
    , [d].[user_access_desc]
    , [d].[is_read_only]
    , [d].[compatibility_level]
FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
WHERE [d].[state] = 0
  AND [d].[database_id] > 4
  AND (@DatabaseNamePattern IS NULL
       OR [d].[name] LIKE @DatabaseNamePattern);
```

**Wichtig für die Eigenlast:** Exakte Namensliste oder LIKE-Pattern wirken bereits an der Kandidatenquelle. Regex benötigt spätere Auswertung und darf nicht als gleichwertige frühe Quellbegrenzung beschrieben werden.

### Zeit- und Scope-Modell

Die Auswertung liefert eine Momentaufnahme der Datenbankliste. Zwischen Kandidatenermittlung und späterer dynamischer Abfrage kann eine Datenbank offline gehen, failovern oder gelöscht werden.

### Bewertung und Gegenprobe

Explizit angeforderte, aber ausgeschlossene Datenbanken müssen als fehlende Evidenz dokumentiert werden. Eine Analyse über neun von zehn angeforderten Datenbanken ist nicht automatisch eine vollständige Entwarnung.

### Typische Fehlinterpretation

Pattern und explizite Liste sind alternative Einschränkungen und dürfen nicht
gleichzeitig gesetzt werden. Eine explizit nicht verfügbare Datenbank bleibt als
Warning sichtbar; sie darf nicht als erfolgreich untersuchter Scope gelten.

### Folgeanalyse

Berücksichtigen Sie Warnings und OUTPUT-Status zusammen mit jedem Cross-Database-Resultset.

## Primärquellen

- [sys.databases](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../01_Common.md#4-monitorusp_preparedatabasecandidates)
