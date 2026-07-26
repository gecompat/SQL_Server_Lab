# [monitor].[USP_StartupParameters]

**Bereich:** Server Health<br>
**Zweck:** Zeigt SQL-Server-Startparameter, Pfade und dauerhaft aktivierte Flags.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Mit welchen Service-/Engineparametern wurde die Instanz gestartet?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_StartupParameters]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `startupParameters`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Startparameter oder einer daraus abgeleiteten Konfigurationsinformation.

## So lesen

Prüfen Sie Parameterart, Pfade, Trace Flags, Startoptionen und Dienstkontext.

## Warum kann das problematisch sein?

Falsche Master-/Errorlog-/Startpfade oder unerwartete Flags können Start und Engineverhalten beeinflussen.

## Wann ist es kein Problem?

Abweichende Pfade sind häufig bewusstes Storage-Design.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein Trace Flag als Startup-Parameter erklärt, warum es nach jedem Restart wieder aktiv ist. Prüfen Sie Trace-Flag-Dokumentation, Dateisystem und Dienstkonfiguration.

**Ähnlich aussehender Gegenfall:** Abweichende Pfade sind häufig bewusstes Storage-Design. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_StartupParameters` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Erkennt zunächst Plattform/Verfügbarkeit und liest dann aus `sys.dm_server_registry` nur `SQLArg%`, `ImagePath` und `ObjectName`; Werte werden als Trace Flag, Master-Daten-/Logpfad, Errorlogpfad oder Other klassifiziert. |
| Teuerster Pfad | Kein Deep-Pfad. Auch eine Instanz mit vielen Startargumenten liefert nur wenige Registry-DMV-Zeilen; RAW/JSON verbreitern lediglich die Ausgabe. |
| Haupttreiber | Anzahl der SQL-Startargument-/Dienstparameterzeilen. Auf Linux oder ohne DMV wird kontrolliert `UNAVAILABLE_PLATFORM`/`UNAVAILABLE_OBJECT` geliefert, kein alternativer Datei-/Shellzugriff gestartet. |
| Skalierung | Praktisch konstant; LIKE-Klassifikation und Sortierung wachsen linear mit wenigen Registrywerten. |
| Ressourcen | Ein Hostplattform-Lookup, ein kleiner Metadaten-Existenzcheck und optional ein gefilterter `sys.dm_server_registry`-Scan. Kein direkter Registryzugriff außerhalb SQL Server. |
| Begrenzungswirkung | Kein Zeilenlimit; vollständige Startargumente sind fachlich erforderlich. `NONE` unterdrückt Ausgabe, führt Plattform-/DMV-Prüfung und Quellabfrage dennoch aus. |
| Locking und Nebenwirkungen | Read-only. Startparameter werden weder geschrieben noch aktiviert; Änderungen außerhalb SQL Server können nach dem Snapshot erfolgen und wirken teils erst nach Dienstneustart. |
| Schutzmechanismus | Kein Gate und kein Zeilenparameter. Die Implementierung beschränkt `sys.dm_server_registry` fest auf `SQLArg%`, `ImagePath` und `ObjectName`, prüft zuvor die Plattform/Quellverfügbarkeit und führt keinen allgemeinen Registryscan aus. |
| Sicherer Einsatz | CONSOLE direkt nutzen, aber Pfade, Dienstkonto und ImagePath als sensible Betriebsmetadaten schützen. Trace-Flag-Wirkung separat versionsspezifisch prüfen. |
| Aussagegrenze | Die Procedure zeigt DMV-sichtbare Startwerte, nicht deren Änderungsverlauf oder tatsächliche Dateiexistenz. Ein `-T`-Argument beweist Konfiguration beim Start, aber nicht automatisch aktuelle Notwendigkeit oder Supportstatus. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Mit welchen Service-/Engineparametern wurde die Instanz gestartet?

### Technischer Hintergrund

Startupparameter definieren unter anderem Master Data/Log, Errorlog, Trace Flags und weitere Engineoptionen. Registry-/Service-DMVs liefern konfigurierte Parameter; einige Änderungen benötigen Dienstneustart und können Startfähigkeit beeinflussen.

### Datenkette

`sys.dm_os_host_info`, `sys.dm_server_registry`.

### Source Select

Auf Windows liest der direkte Quellpfad nur Startup- und Dienstparameter aus der Registry-DMV:

```sql
SELECT
      [r].[registry_key]
    , [r].[value_name]
    , CONVERT(nvarchar(2048), [r].[value_data]) AS [value_data]
FROM [sys].[dm_server_registry] AS [r] WITH (NOLOCK)
WHERE [r].[value_name] LIKE N'SQLArg%'
   OR [r].[value_name] IN (N'ImagePath', N'ObjectName');
```

**Wichtig für die Eigenlast:** Der `value_name`-Filter wirkt direkt an der kleinen DMV. Pfade und Dienstidentitäten können in realen Resultsets schutzbedürftig sein; sie gehören nicht ungeprüft in Repositoryartefakte. Auf nicht unterstützten Plattformen wird kein Ersatz erfunden.

### Zeit- und Scope-Modell

Die Auswertung beschreibt die Konfiguration der laufenden Instanz und ihre Wirkung seit dem letzten Start.

### Bewertung und Gegenprobe

Prüfen Sie Parameter, Quelle, Reihenfolge, Pfad-/Flagbedeutung und Abgleich mit Runtime Trace Flags/Errorlog. Abweichung von Standard kann bewusst sein.

### Typische Fehlinterpretation

Ein angezeigter Parameter beweist nicht, dass sein Zielpfad gesund oder noch erforderlich ist. Änderungen ohne Recoveryzugang können Instanzstart verhindern.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Trace Flags, OS/Filesystem und dokumentiertes Restart-/Rollbackrunbook.

## Primärquellen

- [sys.dm_server_registry](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-server-registry-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#7-monitorusp_startupparameters)
