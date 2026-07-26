# [monitor].[USP_PrepareNameFilters]

**Bereich:** Common, interner Filtervertrag<br>
**Zweck:** Validiert und zerlegt case-sensitive, bracket-aware Namensfilter.<br>
**Beobachtungsart:** Aufrufbezogene Validierung<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wurde eine Namenliste syntaktisch eindeutig und unter der case-sensitiven Frameworksemantik aufbereitet?** Sie unterstützt die Entscheidung, ob der gewünschte Analysepfad sicher und eindeutig vorbereitet ist oder der Fachaufruf wegen Policy, Capability oder ungültigem Scope unterbleiben muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Performance- oder Verfügbarkeitsursache und keine Aussage über Daten außerhalb des aktuellen Execution-Kontexts. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

Die Procedure erwartet eine über `@FilterTable` eindeutig benannte lokale Temp-Tabelle mit festem Schema. Benutzer rufen die jeweilige Analyse-Procedure mit deren Filterparametern auf.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Diese Hilfsprocedure besitzt bewusst keinen öffentlichen TABLE-Export. Sie befüllt die vom Parent bereitgestellten Temp-Strukturen beziehungsweise OUTPUT-Statuswerte. Zuerst sind Status und Warnungen des Parents zu lesen; erst danach darf dessen Fachresultset interpretiert werden. Ein direkter Aufruf ohne den dokumentierten Tabellenvertrag ist kein Ersatz für den Parentpfad.

## Eine Zeile bedeutet

Eine Zeile in der über `@FilterTable` benannten Tabelle entspricht einem normalisierten Filterelement, beispielsweise Schema, Objekt, Index, Statistik oder vollständig qualifiziertes Objekt.

## So lesen

Prüfen Sie Filtertyp, Status und tatsächliche Zeilenzahl. Bei Fehlern wird die Temp-Tabelle absichtlich geleert.

## Warum kann das problematisch sein?

Eine leere Filtertabelle nach `INVALID_PARAMETER` darf nicht als „kein Filter“ behandelt werden. Sonst könnte eine nachfolgende Analyse versehentlich zu breit laufen.

## Wann ist es kein Problem?

Unter der case-sensitiven Projektcollation sind `ExampleTable` und `exampletable` unterschiedliche Namen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Doppelte identische Namen führen absichtlich zu einem Fehler; Namen, die sich nur in der Groß- und Kleinschreibung unterscheiden, führen nicht dazu. Korrigieren Sie die Eingabe und wiederholen Sie den öffentlichen Aufruf.

**Ähnlich aussehender Gegenfall:** Unter der case-sensitiven Projektcollation sind `ExampleTable` und `exampletable` unterschiedliche Namen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Hilfsprocedures kann eine leere interne Zieltabelle aus bewusst leerem Filter, ungültiger Eingabe oder fehlender Policy entstehen; diese Fälle dürfen nicht zu einem ungefilterten Parentlauf zusammenfallen.

Für `USP_PrepareNameFilters` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Parst bis zu sechs übergebene Pipe-Listen über die Framework-TVFs, validiert Exklusivität/Duplikate und schreibt gültige Zeilen in eine bereits vom Parent angelegte lokale Temp-Tabelle. Ohne Listen bleibt die Ausgabe leer. |
| Teuerster Pfad | Sehr lange Listen mit vielen bracket-aware Elementen in allen sechs Parametern; `@FullObjectNames` benötigt zusätzlich die Zerlegung in Datenbank, Schema und Objekt. Ungültige oder doppelte Werte werden erst nach der Parserarbeit erkannt. |
| Haupttreiber | Zeichenlänge und Elementzahl von Schema-, Objekt-, Full-Object-, Index-, Statistik- und Spaltenlisten. Es gibt keine Datenbankkandidaten-, Capability-, Login-Token- oder Fachquellenabfrage. |
| Skalierung | Parser- und UNION-ALL-Arbeit wächst linear mit den Elementen; die case-sensitive Duplikatprüfung gruppiert die materialisierte Worktable und kann bei sehr großen Listen zusätzliche TempDB-CPU benötigen. |
| Ressourcen | CPU für String-/Identifierparser, eine lokale Worktable und dynamisches SQL für Schema-Prüfung/Insert der vom Parent benannten lokalen Temp-Tabelle. Kein Katalog- oder Nutzdatenscan. |
| Begrenzungswirkung | Es existiert kein Zeilenlimit: Vollständige Validierung ist Teil des Sicherheitsvertrags. Begrenzen lässt sich die Arbeit nur durch kleine Eingabelisten; `@FilterTable` ist auf einen lokalen `#`-Namen mit maximal 116 Zeichen beschränkt. |
| Locking und Nebenwirkungen | Schreibt ausschließlich in lokale Temp-Tabellen der aufrufenden Session. Keine fachliche Datenänderung und kein Security-Token-Lesen; dynamisches SQL prüft nur die erwarteten Spalten der Zieltabelle und fügt validierte Werte ein. |
| Schutzmechanismus | Kein Analyse-Gate, weil dies ein interner Parser ist. Er akzeptiert nur lokale `#`-Temp-Tabellennamen bis 116 Zeichen, prüft die erwartete Zieltabelle, erzwingt die Exklusivität vollständiger versus getrennter Objektnamen und lehnt syntaktisch ungültige oder case-sensitiv doppelte Werte ab; ein Mengenbudget müssen die aufrufenden Module setzen. |
| Sicherer Einsatz | Nur nach Anlegen der dokumentierten lokalen Zieltabelle und zunächst mit einer kleinen `ExampleSchema`-/`ExampleObject`-Liste aufrufen. `INVALID_PARAMETER` muss den Parent stoppen und darf nie in ungefilterte Analyse umgedeutet werden. |
| Aussagegrenze | Die Procedure bestätigt ausschließlich Syntax, Exklusivität und case-sensitive Eindeutigkeit. Sie prüft nicht, ob Datenbank, Schema, Objekt, Index, Statistik oder Spalte tatsächlich existieren oder für den Aufrufer sichtbar sind. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wurde eine Namenliste syntaktisch eindeutig und unter der case-sensitiven Frameworksemantik aufbereitet?

### Technischer Hintergrund

Die Procedure ist ein Schutzbaustein für Filter. Quote-/Bracket-aware Parser verhindern, dass Trenner innerhalb korrekt geklammerter Namen falsch zerlegt werden. Validierte Werte werden in Temp-Strukturen geschrieben; ungültige Eingaben führen kontrolliert zu leerem/ungültigem Filterstatus.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung und Filterlogik; die Procedure besitzt keine eigenständige Systemquelle.

### Source Select

Keine Systemquelle: Die Procedure normalisiert vom Aufrufer gelieferte Namenslisten über die Framework-TVFs. Der direkte Parserzugriff lautet:

```sql
SELECT
      [f].[ItemOrdinal]
    , [f].[DatabaseName]
    , [f].[SchemaName]
    , [f].[ObjectName]
    , [f].[IsValid]
FROM [monitor].[TVF_ParseFullObjectNameList]
     (@FullObjectNames) AS [f];
```

**Wichtig für die Eigenlast:** Die Listenmenge ist klein; der entscheidende Nutzen ist, exakte Namen vor teuren Katalog- oder DMF-Pfaden bereitzustellen. Pattern- und Regexfilter sind ein anderer Vertrag und ersetzen diese frühe Zielauflösung nicht.

### Zeit- und Scope-Modell

Die Filter gelten nur für den aktuellen Aufruf und werden nicht persistiert.

### Bewertung und Gegenprobe

Behandeln Sie Case-Sensitivität, Duplikate, leere Elemente und ungültige Quote-/Bracketstruktur explizit. Ein absichtlich leerer Filter und ein aufgrund von Fehler geleerter Filter müssen unterscheidbar bleiben.

### Typische Fehlinterpretation

Eine leere Filtertabelle nach `INVALID_PARAMETER` darf nie als Freigabe für eine ungefilterte breite Analyse dienen.

### Folgeanalyse

Korrigieren Sie die Eingabe und starten Sie das aufrufende Fachmodul erneut.

## Primärquellen

- [QUOTENAME](https://learn.microsoft.com/en-us/sql/t-sql/functions/quotename-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../01_Common.md#5-monitorusp_preparenamefilters)
