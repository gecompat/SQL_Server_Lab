# [monitor].[USP_ClrAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Analysiert SQL-CLR-Konfiguration, sichtbare Assemblies und Module sowie aktuelle Host-, AppDomain-, Task-, Request-, Speicher- und Counterevidenz.<br>
**Beobachtungsart:** Konfigurations-, Katalog-, Live- und Sample-Snapshot<br>
**Kostenklasse:** MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche SQL-CLR-Abhängigkeiten sind im gewählten Datenbankscope sichtbar, wie ist der CLR-Host aktuell konfiguriert und welche Liveevidenz rechtfertigt eine Sicherheits- oder Performancevertiefung?** Sie ist der Deep-Dive nach `USP_SpecialFeatureInventory`, wenn benutzerdefinierte Assemblies erkannt werden, und der gezielte Prüfpfad für `clr enabled`, `clr strict security`, AppDomains, geladene Assemblies oder aktive Managed-Code-Requests.

SQL CLR ist vom out-of-process External-Language-Pfad getrennt. Die Procedure analysiert .NET-Assemblies, die vom SQL-Server-CLR-Host verwaltet werden. C# Language Extensions, Launchpad, externe Libraries und External Resource Pools gehören zu `USP_ExternalRuntimeAnalysis`.

## Nicht beantwortete Fragen

Die Analyse führt keine Assembly aus, aktiviert CLR nicht und lädt keine Assembly. Sie bewertet keinen IL-Code, keine binären Abhängigkeiten und keine fachliche Korrektheit einer CLR-Methode. Assembly-Binärinhalt, Trusted-Assembly-Hashes, Moduldefinitionen, SQL-Texte und Pläne bleiben ausgeschlossen. Deshalb kann sie keine exakte Zuordnung einer Datenbankassembly zur serverweiten Trust List behaupten.

Eine sichtbare Katalogzeile beweist weder, dass eine Assembly aktuell geladen ist, noch dass alle Aufrufe erfolgreich sind. Eine geladene Assembly beweist keine konkrete Methodenausführung im betrachteten Zeitfenster. `creation_time` eines AppDomains ist wegen Caching nicht der Startzeitpunkt eines Requests. Active-Request- und Task-DMVs sind flüchtig und bilden keine Historie.

Owner-, `EXECUTE AS`-Principal- und Trusted-Assembly-Anzahl werden nur mit `@MitBerechtigungsanalyse = 1` gelesen. Der Pfad verlangt `CATALOG_DEEP`, die wirksame Gruppenpolicy und bei Bedarf `@HighImpactConfirmed = 1`. Login-, Host- und Programmkontext aktiver Requests bleiben standardmäßig leer und werden nur durch `@MitSitzungskontext = 1` ausgegeben.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ClrAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @SampleSeconds = 0,
      @MitModulzuordnung = 1,
      @MitBerechtigungsanalyse = 0,
      @MitSitzungskontext = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch. Beginnen Sie mit einer bekannten Datenbank, ohne Counterwartezeit und ohne Identity- oder Trust-Opt-in. Nutzen Sie `@AssemblyNames` oder `@AssemblyNamePattern`, wenn der Katalog viele benutzerdefinierte Assemblies enthält.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. CONSOLE rendert diese priorisierte Struktur. RAW und JSON liefern zusätzlich `configuration`, `databaseStatus`, `sourceStatus`, `assemblies`, `assemblyModules`, `assemblyDependencies`, `clrProperties`, `appDomains`, `loadedAssemblies`, `clrTasks`, `activeRequests`, `memory`, `performanceCounters` und `warnings`.

Lesen Sie zuerst `sourceStatus`, weil fehlende Server-DMV-Rechte und eingeschränkte Metadata Visibility unterschiedliche Lücken erzeugen. Lesen Sie danach die Konfiguration und den Datenbankstatus. Ordnen Sie Assemblies nur innerhalb ihrer Datenbank zu. Verwenden Sie Host-, AppDomain-, Task- und Requestresultsets anschließend als flüchtigen Laufzeitkontext, nicht als Ersatz für den Katalog.

## Eine Zeile bedeutet

Eine `assemblies`-Zeile beschreibt genau eine sichtbare benutzerdefinierte Assembly in einer Datenbank. Eine `assemblyModules`-Zeile beschreibt ein sichtbares CLR-Datenbankobjekt und seine Assemblyklasse beziehungsweise Methode, ohne Definition. Eine Dependency-Zeile beschreibt entweder eine direkte Assemblyreferenz oder einen sichtbaren CLR-Typ. Eine AppDomainzeile ist ein aktuell gecachter Hostkontext. Eine Loaded-Assembly-Zeile besitzt nur dann einen belastbaren Namen, wenn `assembly_id` zusammen mit der über den AppDomain ermittelten Datenbank korreliert werden konnte. Eine Task- oder Requestzeile ist ausschließlich eine Momentaufnahme.

## So lesen

Prüfen Sie `clr enabled`, `clr strict security` und `lightweight pooling` gemeinsam. Ordnen Sie Permission Set, Datenbank-`TRUSTWORTHY`, Owner-/Signaturkontext und Plattformgrenzen getrennt ein. Verwenden Sie `assembly_id` nie serverweit als eindeutigen Schlüssel. Korrelieren Sie Tasks best effort über `sos_task_address` zu `sys.dm_os_tasks.task_address`. Bewerten Sie CLR-Memory-Clerks und Counter nur mit Servermemory, Workloadbaseline, Sampledauer und Resetstatus.

## Warum kann das problematisch sein?

Deaktiviertes `clr strict security` schwächt den modernen Sicherheitsvertrag, weil Code Access Security kein belastbarer Sicherheitsrand ist. Gleichzeitiges `clr enabled` und `lightweight pooling` ist laut Produktdokumentation nicht unterstützt. Benutzerassemblies bei deaktiviertem CLR können stillgelegte oder migrationskritische Abhängigkeiten anzeigen. Unter Linux werden für SQL CLR nur SAFE Assemblies unterstützt; sichtbare `EXTERNAL_ACCESS`- oder `UNSAFE_ACCESS`-Metadaten verlangen daher eine Plattformprüfung. `TRUSTWORTHY ON` zusammen mit hoch privilegierten Assemblies ist ein Security-Review-Signal, aber noch kein Exploitnachweis.

Aktive Managed-Code-Requests können blockiert sein wie andere Requests. Nicht zuordenbare Tasks oder geladene Assemblies können durch Lebenszeitwechsel, Systemassemblies, Filter oder fehlende Metadatensichtbarkeit entstehen. Wiederholte Unmappability im selben AppDomain- und Requestkontext rechtfertigt eine Vertiefung; ein einzelner Snapshot nicht.

## Wann ist es kein Problem?

Eine SAFE-Assembly in einer bewusst CLR-basierten Anwendung kann erwarteter Bestandteil des Designs sein. `clr enabled = 1` allein beweist weder aktuelle Nutzung noch ein Sicherheitsproblem. Ein leerer AppDomain-, Task- oder Request-Snapshot ist erwartbar, wenn zur Messzeit keine CLR-Arbeit aktiv oder gecacht ist. Hohe kumulative CLR Execution Time kann bei einer langlebigen Instanz normal sein; ohne Resetzeit, Sampledelta und Workloadvergleich ist sie keine Alarmgrenze. Fehlende Trust-Zuordnung ist im Standardpfad beabsichtigt, weil der notwendige Binärhash aus Datenschutz- und Kostenvertrag ausgeschlossen ist.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `ExampleDatabase` ist `TRUSTWORTHY ON` und enthält `ExampleUnsafeAssembly` mit `UNSAFE_ACCESS`; zugleich ist `clr strict security` deaktiviert. Die Procedure meldet getrennte Security-Findings. Prüfen Sie Owner, Signierung, Trust List, erforderlichen Permission Set und Zielplattform. Leiten Sie daraus nicht automatisch eine Kompromittierung ab.

**Ähnlich aussehender Gegenfall:** `ExampleDatabase` enthält `ExampleSafeAssembly`, `clr strict security` ist aktiv, und aktuell sind weder Task noch Request sichtbar. Die Katalogabhängigkeit bleibt relevant für Deployment und Restore, ist aber ohne Fehler-, Blocking- oder Securityevidenz kein Betriebsdefekt.

**Korrelationsgrenze:** Eine Loaded-Assembly-Zeile mit `assembly_id = 42` darf nur gegen Katalogzeilen der AppDomain-Datenbank geprüft werden. Dieselbe ID kann in einer anderen Datenbank eine andere Assembly bezeichnen.

## Leere oder partielle Ausgabe

`NOT_APPLICABLE` bedeutet, dass CLR deaktiviert ist und im sichtbaren Datenbankscope keine benutzerdefinierte Assembly gefunden wurde. `FEATURE_DISABLED` bedeutet, dass CLR deaktiviert ist, aber eine sichtbare Abhängigkeit verbleibt. `AVAILABLE_LIMITED` bedeutet, dass mindestens eine isolierte Katalog- oder DMV-Quelle fehlt. Zugängliche Resultsets bleiben erhalten und dürfen nur zusammen mit `sourceStatus` interpretiert werden.

Keine Assemblyzeile beweist bei eingeschränkter Metadata Visibility keine Abwesenheit. Keine AppDomain- oder Requestzeile beweist keine historische Nichtnutzung. `NULL` bei Trust, Owner, Mapping oder Metrik bedeutet nicht geprüft, nicht sichtbar oder nicht ableitbar. Ein positives `@MaxZeilen` begrenzt die fertigen Resultsets und nicht die vorgelagerte Katalog- oder DMV-Materialisierung.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM |
| Standardpfad | Eine bekannte Datenbank, `@SampleSeconds = 0`, Modulzuordnung an, Owner-/Trust- und Sitzungskontext aus, höchstens 100 Ausgabezeilen. |
| Teuerster Pfad | Viele Datenbanken, breite Assemblyfilter, Modul-/Dependency-Zuordnung, Owner-/Trustanalyse, Sitzungskontext, unbegrenzte Ausgabe und 60-Sekunden-Countersample. |
| Haupttreiber | Zahl der Zieldatenbanken, benutzerdefinierten Assemblies, Assemblymodule und -referenzen, CLR-Typen, AppDomains, geladenen Assemblies, Tasks und Counterinstanzen. |
| Skalierung | Datenbankkatalogarbeit wächst mit sichtbaren CLR-Objekten. Server-DMVs werden einmal je Messpunkt materialisiert; das Sample wiederholt nur Performance Counter. |
| Ressourcen | Temporäre Tabellen, dynamisches SQL je Datenbank und optionale `WAITFOR`-Dauer. Es werden keine Assembly-Binaries, Benutzertabellen oder Moduldefinitionen gelesen. |
| Begrenzungswirkung | Datenbank- und Assemblyfilter reduzieren Katalogzeilen. `@MaxZeilen` begrenzt die Ausgabe erst nach Materialisierung und reduziert die Quellenkosten nicht vollständig. |
| Locking und Nebenwirkungen | Rein lesend mit konfigurierbarem `LOCK_TIMEOUT`; keine CLR-, Trust-, Datenbank- oder Assemblyänderung und keine Codeausführung. Live-DMVs sind nicht atomar. |
| Schutzmechanismus | `CLR_CURRENT` steuert den Basispfad. Owner-, Principal- und Trustkontext verwendet zusätzlich `CATALOG_DEEP` und je Policy `@HighImpactConfirmed = 1`. |
| Sicherer Einsatz | Beginnen Sie mit einer synthetisch dokumentierten `ExampleDatabase`, Sample 0 und Privacy-Opt-ins aus. Aktivieren Sie Trust-/Ownerkontext nur für ein konkretes Security-Review. |
| Aussagegrenze | Katalog, Hostzustand, AppDomains, Tasks, Requests, Memory und Counter besitzen unterschiedliche Zeit- und Schlüsselmodelle. Die Procedure erzeugt keinen End-to-End- oder Trustnachweis. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche SQL-CLR-Abhängigkeiten und aktuellen Hostsignale sind sichtbar, und welche Sicherheits-, Plattform- oder Laufzeithinweise benötigen eine gezielte Gegenprobe?

### Technischer Hintergrund

SQL Server hostet CLR-AppDomains pro Datenbank- und Sicherheitskontext. `sys.assemblies` und die zugehörigen Modulkataloge sind datenbankbezogen. Die CLR-DMVs sind serverweit. `assembly_id` ist deshalb nur innerhalb der AppDomain-Datenbank sinnvoll korrelierbar. Moderne SQL-Server-Versionen behandeln SAFE und EXTERNAL_ACCESS bei aktiviertem `clr strict security` sicherheitstechnisch wie UNSAFE, sofern keine Signatur- oder Trustbasis vorliegt.

### Datenkette

`sys.configurations`, `sys.databases`, `sys.assemblies`, `sys.assembly_modules`, `sys.assembly_references`, `sys.assembly_types`, `sys.dm_clr_properties`, `sys.dm_clr_appdomains`, `sys.dm_clr_loaded_assemblies`, `sys.dm_clr_tasks`, `sys.dm_os_tasks`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_os_memory_clerks`, `sys.dm_os_performance_counters` und optional `sys.trusted_assemblies`.

### Source Select

Die Loaded-Assembly-Korrelation bindet die ID an den AppDomain-Datenbankkontext:

```sql
SELECT
      [loaded].[assembly_id]
    , [domain].[db_id]
    , [catalog].[name] AS [AssemblyName]
FROM [sys].[dm_clr_loaded_assemblies] AS [loaded] WITH (NOLOCK)
JOIN [sys].[dm_clr_appdomains] AS [domain] WITH (NOLOCK)
  ON [domain].[appdomain_address] = [loaded].[appdomain_address]
LEFT JOIN [ExampleDatabase].[sys].[assemblies] AS [catalog] WITH (NOLOCK)
  ON [catalog].[assembly_id] = [loaded].[assembly_id]
 AND [domain].[db_id] = DB_ID(N'ExampleDatabase');
```

**Wichtig für die Eigenlast:** Die CLR-DMVs besitzen serverweiten Scope und werden je Messpunkt einmal vollständig materialisiert. Datenbank- und Assemblyfilter begrenzen die anschließende Katalogauflösung, nicht jedoch die Arbeit dieser serverweiten DMV-Snapshots; `@MaxZeilen` wirkt erst auf die fertigen Resultsets.

Die reale Procedure verwendet dynamisch quotierte Datenbanknamen aus dem zentralen Kandidatenvertrag. Binärinhalt und Hashquellen werden nicht referenziert.

### Zeit- und Scope-Modell

Konfiguration und Datenbankkataloge sind Current State. AppDomains und geladene Assemblies können über einzelne Requests hinaus gecacht bleiben. CLR Tasks und `executing_managed_code` sind flüchtige Momentaufnahmen. Memory Clerks sind aktuelle Aggregate. CLR Performance Counter sind kumulativ; ein optionales gemeinsames Sample erzeugt nur dann eine Deltaaussage, wenn Countertyp, Messpunkte und Resetvertrag dies zulassen.

### Bewertung und Gegenprobe

Bestätigen Sie Security-Findings mit Datenbankowner, Assemblysignierung, Trust List und dokumentierter Berechtigungsanforderung. Bestätigen Sie Blocking mit `USP_CurrentBlocking`, Requestkontext mit `USP_CurrentRequests`, Memory mit `USP_ServerMemory`, Counter mit `USP_PerformanceCounters` und Hostinitialisierungsfehler mit `USP_ErrorLogAnalysis`. Ein Code- oder Penetrationstest ist ein eigener autorisierter Nachweis und kein Bestandteil dieser Procedure.

### Typische Fehlinterpretation

`permission_set_desc = SAFE_ACCESS` ist bei aktiviertem `clr strict security` kein alleiniger Trustnachweis. `TRUSTWORTHY ON` beweist keine konkrete Ausnutzbarkeit. Eine geladene Assembly ist nicht gleichbedeutend mit einem aktiven Request. AppDomain-CPU ist kumulativ und nicht automatisch einer einzelnen Methode zuordenbar. CLR Execution Time ist keine per-Request-Latenz.

### Folgeanalyse

Verwenden Sie `USP_CurrentRequests` und `USP_CurrentBlocking` für aktive Workload, `USP_ServerSecurityConfiguration` für Instanzhärtung, `USP_ServerMemory` und `USP_PerformanceCounters` für Ressourcenkontext sowie `USP_ErrorLogAnalysis` und vorhandene Extended-Events-Evidenz für Host- oder Ladefehler.

## Primärquellen

- [SQL-CLR-Programmierkonzepte und Plattformunterstützung](https://learn.microsoft.com/en-us/sql/relational-databases/clr-integration/common-language-runtime-clr-integration-programming-concepts?view=sql-server-ver17)
- [CLR Strict Security](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/clr-strict-security?view=sql-server-ver17)
- [CLR Properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-clr-properties-transact-sql?view=sql-server-ver17)
- [CLR AppDomains](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-clr-appdomains-transact-sql?view=sql-server-ver17)
- [Geladene CLR-Assemblies](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-clr-loaded-assemblies-transact-sql?view=sql-server-ver17)
- [CLR Tasks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-clr-tasks-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#11-monitorusp_clranalysis)
