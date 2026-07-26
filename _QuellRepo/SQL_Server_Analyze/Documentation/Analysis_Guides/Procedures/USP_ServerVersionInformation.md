# [monitor].[USP_ServerVersionInformation]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Ordnet Instanzbuild, Servicing-Zweig und Microsoft-Lifecycle anhand eines versionierten Offline-Katalogs ein.<br>
**Beobachtungsart:** aktueller Instanzsnapshot plus Frameworkkatalog<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Diese Procedure beantwortet: **Welche technische SQL-Server-Version läuft, wie lässt sich der Build im offline mitgelieferten Microsoft-Katalog einordnen und in welcher Lifecycle-Phase befindet sich die Hauptversion?** Sie ist der leichte Einstieg vor versionsabhängigen Diagnosepfaden und benötigt keinen Plan-Cache-, Query-Store- oder Benutzerdatenzugriff.

Build, Katalogtreffer und Lifecycle werden getrennt ausgegeben. Eine operative Patchentscheidung braucht zusätzlich die aktuelle Microsoft-Buildseite, die organisationsspezifische Freigabe und gegebenenfalls Security Advisories. Die Procedure führt keinen Onlinezugriff aus und verändert keine Instanzeinstellung.

## Nicht beantwortete Fragen

Die Ausgabe beweist weder vollständige Security-Patches noch Verwundbarkeit, ausstehenden Neustart, Lizenzkonformität oder betriebliche Freigabe einer CU. `SERVERPROPERTY('LicenseType')` und `NumLicenses` werden bewusst nicht als Lizenznachweis verwendet. Ein unbekannter Build ist nicht automatisch veraltet; er kann neuer als der Offline-Katalog, ein Preview-/On-Demand-Build oder ein nicht katalogisierter Servicing-Zweig sein.

Die normale CONSOLE-Ausgabe enthält keine Server-, Host-, Instanz-, Konto- oder Pfadidentität. Optional ausgegebene Datenbanknamen stammen nur aus dem ausdrücklich aktivierten Resultset `databaseCompatibility`.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerVersionInformation]
      @ResultSetArt = 'CONSOLE';
```

Verwenden Sie mit folgendem Aufruf einen optionalen, synthetischen Datenbankkontext:

```sql
EXEC [monitor].[USP_ServerVersionInformation]
      @MitDatenbankKompatibilitaet = 1,
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'RAW';
```

## Resultsets und Leserichtung

Die sieben stabilen Resultsetnamen lauten `serverVersion`, `buildAssessment`, `lifecycle`, `instanceFeatures`, `databaseCompatibility`, `references` und `warnings`. CONSOLE verdichtet Build- und Lifecyclebewertung zu genau einem Grid. RAW liefert alle sieben Resultsets in dieser Reihenfolge. TABLE akzeptiert eine beliebige eindeutige Teilmenge der sieben Namen; JSON verwendet gleichnamige Arrays unter einer gemeinsamen `meta`-Hülle.

Berücksichtigen Sie zuerst `warnings`, Modulstatus und `buildAssessment`. Prüfen Sie danach `lifecycle`, die technischen `serverVersion`-Eigenschaften und bei Bedarf `instanceFeatures`. `references` enthält ausschließlich öffentliche Microsoft-URLs und den Katalogstand.

## Eine Zeile bedeutet

`serverVersion`, `buildAssessment` und `lifecycle` enthalten je Aufruf höchstens eine Instanz-/Hauptversionszeile. Eine Zeile in `instanceFeatures` steht für genau ein `SERVERPROPERTY`-Flag. Eine Zeile in `databaseCompatibility` steht für den sichtbaren Katalogzustand einer ausgewählten Datenbank. Eine `warnings`-Zeile beschreibt eine fehlende Teilquelle oder eine nicht eindeutige Offline-Einordnung.

Die Granularitäten dürfen nicht ohne Resultsetname zusammengeführt werden. `CapturedAtUtc`, `SourceType`, `SourceObject`, `EvidenceScope` und `EvidenceLimit` bestimmen Herkunft und Aussagegrenze.

## So lesen

`AssessmentStatus` unterscheidet unter anderem `EXACT_MATCH`, `OLDER_KNOWN_BUILD`, `UNKNOWN_BUILD`, `BUILD_NEWER_THAN_OFFLINE_CATALOG`, `PREVIEW_BUILD` und `ON_DEMAND_BUILD`. `CatalogFreshnessStatus` bewertet ausschließlich das Alter des mitgelieferten Katalogs. Der Lifecycle-Status bezieht sich auf die Hauptversion, nicht auf Edition, ESU-Vertrag oder eine konkrete KB.

`LatestKnownBuildInBranch` ist nur bei eindeutig bekanntem Servicing-Zweig vergleichbar. `LatestKnownBuildForMajor` ist ein Navigationshinweis und keine universelle Upgradeempfehlung. Prüfen Sie bei einer unbekannten oder höheren Buildnummer zuerst die verlinkte Microsoft-Buildübersicht.

## Warum kann das problematisch sein?

Ein alter bekannter Build kann dokumentierte spätere Qualitäts- oder Security-Releases nicht enthalten. Ein abgelaufener Mainstream-Support verändert die Art der verfügbaren Wartung. Ebenso problematisch ist eine scheinbar präzise Bewertung mit einem veralteten Offline-Katalog: Sie kann neuere Builds nicht kennen.

Die Procedure verhindert diese Überinterpretation durch getrennte Build-, Katalog- und Lifecycle-Status sowie durch stabile Primärquellenlinks.

## Wann ist es kein Problem?

Ein `OLDER_KNOWN_BUILD` kann bewusst organisationsweit freigegeben und innerhalb eines unterstützten Wartungsplans liegen. `EXTENDED_SUPPORT` bedeutet nicht automatisch Betriebsstörung. Ein `UNKNOWN_BUILD` kann ein neuerer Build sein, den der lokale Katalog noch nicht enthält. Ohne Abgleich mit der aktuellen Primärquelle ist keine dieser Zeilen allein ein Änderungsauftrag.

## Beispiele und Gegenbeispiele

**Synthetischer Befund:** `ExampleInstance` meldet einen exakten Katalogtreffer, aber nicht den neuesten bekannten Build desselben Zweigs. Das ist ein Prüfauftrag für Release Notes, Testplan und Wartungsfenster, keine automatische Installationsanweisung.

**Gegenbeispiel:** Der laufende Build ist höher als jeder Katalogeintrag. `BUILD_NEWER_THAN_OFFLINE_CATALOG` bedeutet gerade nicht „veraltet“, sondern „lokal nicht abschließend klassifizierbar“.

**Nicht entscheidbar:** Fehlt der OS-/Startzeitkontext wegen Berechtigung, bleiben SERVERPROPERTY, Buildkatalog und Lifecycle weiterhin nutzbar; die Procedure kennzeichnet das Ergebnis als partiell.

## Leere oder partielle Ausgabe

Fehlen `serverVersion`, `buildAssessment` oder `lifecycle`, ist die technische Einordnung nicht vollständig. Ein leeres `databaseCompatibility`-Resultset ist bei `@MitDatenbankKompatibilitaet = 0` erwartungsgemäß. Explizit angeforderte, aber nicht sichtbare oder ausgeschlossene Datenbanken erscheinen in `warnings`.

`NULL` in einer Eigenschaft bedeutet nicht anwendbar, nicht verfügbar oder nicht lesbar und wird über Status/Evidenzgrenze eingeordnet. Ein `@MaxZeilen`-Limit betrifft nur den optionalen Datenbankkontext.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Eine SERVERPROPERTY-Materialisierung, zwei kleine Frameworkkataloge und isolierte Host-/Uptime-DMVs. |
| Teuerster Pfad | Optional alle sichtbaren Datenbanken aus `master.sys.databases` für den Compatibility-/Collation-Kontext. |
| Haupttreiber | Zahl sichtbarer beziehungsweise explizit ausgewählter Datenbanken. |
| Skalierung | Instanz- und Katalogteil konstant; Datenbankresultset linear zur Kandidatenzahl. |
| Ressourcen | Geringe CPU-, Katalog- und TempDB-Arbeitstabellenlast; kein Benutzerdaten-, Plan-Cache- oder Query-Store-Zugriff. |
| Begrenzungswirkung | `@DatabaseNames`/Pattern begrenzen früh; `@MaxZeilen` begrenzt die sichtbare Datenbankausgabe, nicht die Instanzbewertung. |
| Locking und Nebenwirkungen | Lesend, keine Konfigurations-, Netzwerk- oder Patchoperation; Kataloge werden nur bei der Installation aktualisiert. |
| Schutzmechanismus | Identitäts- und Pfadwerte fehlen in CONSOLE; Quellen sind isoliert und Partialstatus bleibt sichtbar. |
| Sicherer Einsatz | Zuerst ohne Datenbankkontext; anschließend bei Bedarf eine synthetisch benannte oder gezielt ausgewählte Datenbank. |
| Aussagegrenze | Offline-Einordnung und Produktlifecycle, kein Vulnerability-, Lizenz-, Neustart- oder Freigabenachweis. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie wird ein aktueller Instanzbuild ohne Internetzugriff reproduzierbar und ohne falsche Patchbehauptung eingeordnet?

### Technischer Hintergrund

Die Procedure materialisiert `SERVERPROPERTY` einmal, ergänzt nach Möglichkeit `sys.dm_os_host_info` und `sys.dm_os_sys_info` und vergleicht die vollständige Buildnummer mit `monitor.SqlServerBuildCatalog`. Der Hauptversions-Lifecycle stammt getrennt aus `monitor.SqlServerLifecycleCatalog`. Beide Kataloge werden versioniert durch den Installer gepflegt.

### Datenkette

`SERVERPROPERTY` → `#ServerVersionInformation_ServerVersion` → `monitor.SqlServerBuildCatalog`/`monitor.SqlServerLifecycleCatalog` → benannte Ausgabe. Optional: `master.sys.databases` → `databaseCompatibility`. Die Ausgabe liest keine Primärquelle online.

### Source Select

Die lokale Buildnummer wird mit dem offline versionierten Build- und Lifecyclekatalog verbunden:

```sql
DECLARE @ProductVersion varchar(32) =
    CONVERT(varchar(32), SERVERPROPERTY(N'ProductVersion'));
DECLARE @ProductMajorVersion int =
    CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));

SELECT
      @ProductVersion AS [ProductVersion]
    , [b].[ReleaseName]
    , [b].[ServicingBranch]
    , [b].[ReleaseDate]
    , [l].[ProductName]
    , [l].[MainstreamEndDate]
    , [l].[ExtendedEndDate]
FROM [monitor].[SqlServerBuildCatalog] AS [b] WITH (NOLOCK)
LEFT JOIN [monitor].[SqlServerLifecycleCatalog] AS [l] WITH (NOLOCK)
  ON [l].[ProductMajorVersion] = @ProductMajorVersion
WHERE [b].[BuildVersion] = @ProductVersion;
```

**Wichtig für die Eigenlast:** Exakter Build- und Major-Key machen die Abfrage klein. Es erfolgt kein Onlinezugriff; unbekannte Builds bleiben unbekannt und müssen über die verlinkte Microsoft-Buildübersicht geprüft werden.

### Zeit- und Scope-Modell

Instanzeigenschaften und Datenbankkatalog sind ein aktueller Aufrufsnapshot; Build- und Lifecyclezeilen besitzen den expliziten Katalogstand 2026-07-21. Ein später veröffentlichter Build erfordert ein Katalogupdate oder den manuellen Abgleich über `references`.

### Bewertung und Gegenprobe

Berücksichtigen Sie die vollständige Buildnummer, den exakten Treffer, den Servicing-Zweig, das Katalogalter und die offizielle Buildübersicht gemeinsam. Verwenden Sie die aktuelle Microsoft-Buildseite der erkannten Hauptversion als Gegenprobe und prüfen Sie den Lifecycle separat auf der Microsoft-Lifecycle-Seite.

### Typische Fehlinterpretation

Die höchste numerische Buildnummer kann aus einem anderen Servicing-Zweig stammen. Deshalb darf eine CU-Differenz nur innerhalb eines eindeutig bekannten Zweigs interpretiert werden. Edition und Engine Edition sind ebenfalls kein Lizenznachweis.

### Folgeanalyse

Prüfen Sie vor einer Patchentscheidung Release Notes, Security Advisory, Backup- und Rollbackplan, Kompatibilitätstests sowie die organisationsspezifische Freigabe. Verwenden Sie anschließend `USP_ServerFeatureCapabilities`, um die Featurefähigkeit zu ermitteln.

## Primärquellen

- [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17)
- [SQL Server 2019 builds](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions)
- [SQL Server 2022 builds](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions)
- [SQL Server 2025 builds](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions)
- [SQL Server 2019 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2019)
- [SQL Server 2022 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2022)
- [SQL Server 2025 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2025)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#9-monitorusp_serverversioninformation)
