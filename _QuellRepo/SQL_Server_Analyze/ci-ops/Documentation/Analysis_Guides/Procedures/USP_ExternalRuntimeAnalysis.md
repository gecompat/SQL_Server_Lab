# [monitor].[USP_ExternalRuntimeAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Analysiert Konfiguration, Katalogregistrierungen und aktuelle beziehungsweise gesampelte Betriebsevidenz externer SQL-Server-Runtimes.<br>
**Beobachtungsart:** Konfigurations-, Katalog-, Live- und Sample-Snapshot<br>
**Kostenklasse:** MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Sind External Languages, Libraries und der SQL-Server-Extensibility-Pfad konsistent sichtbar, und gibt es aktuelle Hinweise auf blockierte Requests, Poolgrenzen oder Ausführungsfehler?** Sie ist der Deep-Dive nach `USP_SpecialFeatureInventory`, wenn `EXTERNAL_RUNTIME` erkannt oder `EXTERNAL_SCRIPTS` konfiguriert ist. Der Standardpfad bleibt rein lesend und führt weder R-, Python-, Java-, C#- noch anderen externen Code aus.

Die Analyse trennt vier Evidenzklassen: Serverkonfiguration und Installationsproperty, datenbankbezogene Registrierungen, flüchtige Live-Requests sowie kumulative oder gesampelte Pool- und Counterwerte. Diese Klassen dürfen nicht zu einem pauschalen Gesundheitsurteil verschmolzen werden. Eine registrierte Sprache beweist keine installierte Runtime; ein laufender Launchpad-Service beweist keine erfolgreiche Libraryinitialisierung; ein leerer Request-Snapshot beweist keine historische Inaktivität.

## Nicht beantwortete Fragen

Die Procedure beantwortet nicht, ob ein konkretes Script fachlich korrekt ist, ob ein Package außerhalb des SQL-Katalogs vollständig installiert ist oder ob Betriebssystem-, Container- und Netzwerkabhängigkeiten funktionieren. Sie liest keine Script- oder Batchtexte, Parameter, Environment Variables, Binärinhalte, Libraryinhalte oder Dateipfade. Sie startet keinen Testrequest und erzeugt deshalb keinen synthetischen Verfügbarkeitsnachweis.

Die standardmäßige Ausgabe enthält keine Login-, Host-, Programm- oder External-Worker-Identität. `@MitSitzungskontext = 1` ist ein ausdrücklicher Privacy-Opt-in. `@MitDateimetadaten = 1` liest nur Dateiname und Plattform der Language Extension beziehungsweise die Libraryplattform; Inhalte und Pfade bleiben ausgeschlossen. Ownernamen werden nur mit `@MitBerechtigungsanalyse = 1`, bestätigtem High-Impact-Pfad und der zugehörigen Policy gelesen.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ExternalRuntimeAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @SampleSeconds = 0,
      @MitDateimetadaten = 0,
      @MitBerechtigungsanalyse = 0,
      @MitSitzungskontext = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch. Beginnen Sie ohne Sampling und ohne Privacy- oder Katalog-Opt-ins. Erst wenn die Momentaufnahme einen konkreten Runtime- oder Poolhinweis enthält, ist ein kurzes Sample sinnvoll.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. CONSOLE rendert dieselbe priorisierte Findingstruktur. RAW und JSON liefern zusätzlich `configuration`, `databaseStatus`, `sourceStatus`, `languages`, `libraries`, `activeRequests`, `externalPools`, `executionStats`, `performanceCounters` und `warnings`.

Lesen Sie zuerst `sourceStatus`. Ein fachlich leeres Resultset ist nur belastbar, wenn seine Quelle `AVAILABLE` meldet. Lesen Sie danach `configuration` und `databaseStatus`, dann Registrierungen und erst anschließend Live- beziehungsweise Sampleevidenz. `findings` enthält Triageentscheidungen, ersetzt aber nicht die zugrunde liegenden Resultsets.

## Eine Zeile bedeutet

Eine Zeile in `languages` ist eine sichtbare Language-Registrierung oder bei aktiviertem Datei-Opt-in eine sichtbare plattformspezifische Dateizeile. Eine Zeile in `libraries` ist eine sichtbare Libraryregistrierung oder Plattformzeile. Eine Zeile in `activeRequests` beschreibt genau einen zum Lesezeitpunkt aktiven `external_script_request_id`; abgeschlossene Requests fehlen. Eine Poolzeile beschreibt einen External Resource Pool und optional ein resetgeprüftes Delta. Execution-Stats- und Counterzeilen besitzen eigene Zählersemantik und sind nicht mit Requestanzahlen gleichzusetzen.

## So lesen

Prüfen Sie Konfiguration, Installationsproperty und Launchpad-Status getrennt. Ordnen Sie registrierte Sprachen und Libraries der jeweiligen Datenbank zu. Korrelieren Sie aktive Requests ausschließlich über `external_script_request_id` mit `sys.dm_exec_requests`. Bewerten Sie Pooldeltas nur bei identischer `statistics_start_time` und `pool_version`. Berücksichtigen Sie bei Performance Counters stets `cntr_type`, Sampledauer und Resetstatus.

## Warum kann das problematisch sein?

Eine aktivierte Serveroption ohne sichtbare Installations- oder Serviceevidenz kann eine unvollständige Bereitstellung anzeigen. Registrierungen bei deaktiviertem External-Scripts-Pfad können auf stillgelegte Abhängigkeiten oder Migrationsrisiken hinweisen. Blockierte External Requests verlängern nicht nur die SQL-Requestdauer, sondern halten möglicherweise externe Worker und Poolkapazität. Erreicht `active_processes_count` ein konfiguriertes, von null verschiedenes `max_processes`, kann weitere Arbeit warten. Ein steigender `Execution Errors`-Counter ist ein konkreter Zeitfensterhinweis, enthält aber keine Fehlerursache.

## Wann ist es kein Problem?

Eine registrierte, aber momentan inaktive Runtime kann als bewusst bereitgestellte Plattform korrekt sein. `external scripts enabled = 0` kann in einer stillgelegten oder gehärteten Umgebung beabsichtigt sein. Ein External Pool mit `max_processes = 0` ist nach dem Quellenvertrag nicht an dieser Zahl begrenzt. Ein einzelner aktiver Prozess am Limit ist ohne Warteschlange, Dauer und wiederholte Messung noch kein Sättigungsnachweis. Fehlende Execution-Stats-Counter beweisen weder fehlende Nutzung noch Fehlerfreiheit, weil die DMV nur registrierte Featurefunktionen abbildet.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `ExampleDatabase` enthält eine registrierte Python-Library. External Scripts ist aktiv, der sichtbare Launchpad-Status ist `STOPPED`, und ein wiederholtes Sample zeigt keine startbare Arbeit. Das Finding ist ein belastbarer Bereitstellungs- oder Betriebsverdacht; prüfen Sie Service- und Extensibility-Logs, ohne den Diagnosepfad als Funktionsprobe auszugeben.

**Ähnlich aussehender Gegenfall:** `ExampleDatabase` enthält eine Java-Language-Registrierung, der aktuelle Request-Snapshot ist leer und die Counterdeltas sind null. Das ist bei einer nur periodisch verwendeten Runtime erwartbar. Die Momentaufnahme belegt keine Störung und keine historische Inaktivität.

**Samplegrenze:** Steigt ein kumulativer Wert zwischen T1 und T2 nicht, ist das nur eine Aussage über das gemeinsame Intervall. Sinkt er oder wechselt die Poolversion beziehungsweise Resetzeit, verwirft die Procedure die Deltaaussage und kennzeichnet die Resetgrenze.

## Leere oder partielle Ausgabe

`NOT_APPLICABLE` bedeutet, dass External Scripts deaktiviert ist und im sichtbaren Scope weder Registrierungen noch Runtimeevidenz gefunden wurden. `FEATURE_DISABLED` bedeutet, dass die Option deaktiviert ist, aber Katalog- oder Zählerevidenz sichtbar bleibt. `AVAILABLE_LIMITED` bedeutet, dass mindestens eine isolierte Quelle nicht gelesen werden konnte. `DENIED_PERMISSION`, `SOURCE_UNAVAILABLE` und `LOCK_TIMEOUT` bleiben je Quelle sichtbar; zugängliche Teilresultate werden nicht verworfen.

Eine leere `activeRequests`-Liste ist ein gültiger Momentaufnahmebefund, keine Historie. Null Registrierungen gelten nur im sichtbaren Metadatenscope. `NULL` bei Konfiguration, Service oder Metrik bedeutet unbekannt oder nicht ableitbar, nicht automatisch null. Ein positives `@MaxZeilen` begrenzt die Ausgabe erst nach der Materialisierung und reduziert daher nicht die Quellarbeit.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM |
| Standardpfad | Eine bekannte Datenbank, `@SampleSeconds = 0`, keine Datei-, Owner- oder Sitzungsdaten und höchstens 100 Ausgabezeilen. |
| Teuerster Pfad | Viele Datenbanken, breite Languagefilter, Datei- und Owner-Metadaten, Sitzungskontext, unbegrenzte Ausgabe und ein 60-Sekunden-Sample. |
| Haupttreiber | Zahl der Zieldatenbanken, sichtbaren Language-/Libraryregistrierungen, aktiven Requests, External Pools und Counterinstanzen. |
| Skalierung | Katalogarbeit wächst mit Datenbanken und Registrierungen; Server-DMVs werden je Messpunkt einmal materialisiert. Das Sample verdoppelt Pool-, Execution-Stats- und Counterzugriffe, nicht die Katalogschleife. |
| Ressourcen | Temporäre Tabellen, dynamisches SQL je Datenbank und eine optionale `WAITFOR`-Dauer. Es werden keine Benutzertabellen oder externen Prozesse gestartet. |
| Begrenzungswirkung | Datenbank- und Languagefilter reduzieren Katalog- und Runtimezeilen. `@MaxZeilen` begrenzt Resultsets, aber nicht die vorgelagerte Quellmaterialisierung. |
| Locking und Nebenwirkungen | Rein lesend mit konfigurierbarem `LOCK_TIMEOUT`; kein DDL, kein Resource-Governor-Change und keine Runtimeausführung. Live-DMVs sind nicht atomar. |
| Schutzmechanismus | `EXTERNAL_RUNTIME_CURRENT` steuert den Basispfad. Datei-/Ownerkontext verwendet zusätzlich `CATALOG_DEEP` und verlangt je Policy `@HighImpactConfirmed = 1`. |
| Sicherer Einsatz | Starten Sie mit einer synthetisch dokumentierten `ExampleDatabase`, Sample 0 und allen Privacy-Opt-ins aus. Vertiefen Sie nur eine konkrete Quelle. |
| Aussagegrenze | Registrierung, Dienststatus, Requestsnapshot und Counterdeltas sind getrennte Evidenz. Keine Kombination beweist ohne kontrollierte externe Funktionsprobe die End-to-End-Verfügbarkeit. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche External-Runtime-Komponenten sind im gewählten Scope sichtbar, und welche aktuellen Konfigurations-, Request-, Pool- oder Counterhinweise rechtfertigen eine gezielte Folgeanalyse?

### Technischer Hintergrund

SQL Server führt externe Scripts außerhalb des Engineprozesses über den Extensibility-/Launchpad-Pfad aus. Registrierungen sind datenbankbezogen; aktive Requests und Resource Pools sind serverweit. Deshalb muss die Analyse Katalog-, Host- und Laufzeitevidenz getrennt materialisieren. SQL CLR gehört nicht in diesen Pfad und wird durch `USP_ClrAnalysis` analysiert.

### Datenkette

`SERVERPROPERTY`, `sys.configurations`, `sys.dm_server_services`, `sys.external_languages`, `sys.external_language_files`, `sys.external_libraries`, `sys.external_library_files`, `sys.dm_external_script_requests`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_external_script_execution_stats`, `sys.dm_resource_governor_external_resource_pools` und `sys.dm_os_performance_counters`.

### Source Select

Die aktive Korrelation verwendet den dokumentierten Requestschlüssel:

```sql
SELECT
      [er].[external_script_request_id]
    , [er].[language]
    , [r].[session_id]
    , [r].[request_id]
    , [r].[status]
    , [r].[wait_type]
FROM [sys].[dm_external_script_requests] AS [er] WITH (NOLOCK)
LEFT JOIN [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
  ON [r].[external_script_request_id] = [er].[external_script_request_id];
```

**Wichtig für die Eigenlast:** Aktive External Requests, External Resource Pools und Performance Counter besitzen serverweiten Scope und werden je Messpunkt einmal materialisiert. Datenbank- und Languagefilter begrenzen Katalog- und korrelierte Ausgabezeilen, nicht sämtliche serverweiten Quellzugriffe; `@MaxZeilen` wirkt erst nach der Materialisierung.

Die Katalogprojektionen referenzieren niemals `content`, `parameters` oder `environment_variables`. Die Liveprojektion referenziert keinen SQL- oder Scripttext.

### Zeit- und Scope-Modell

Konfiguration und Kataloge sind Current State. Active Requests sind eine flüchtige Momentaufnahme. Execution Stats und Performance Counter sind kumulativ; bei `@SampleSeconds > 0` wird nur ein resetgeprüftes Delta des gemeinsamen Intervalls ausgewiesen. Das Finding zu `Execution Errors` verwendet dieses eigene Sampledelta und nicht den aktuellen Gesamtwert. Poolwerte gelten seit `statistics_start_time`; ein Versions- oder Resetwechsel invalidiert das Delta. Linux-Poolwerte besitzen herstellerdokumentierte plattformspezifische Einheiten.

### Bewertung und Gegenprobe

Bestätigen Sie einen Konfigurationswiderspruch mit Installationsumfang und Servicezustand. Bestätigen Sie Blocking mit `USP_CurrentBlocking`, Poolgrenzen mit `USP_ResourceGovernorAnalysis`, Counter mit `USP_PerformanceCounters` und Fehlerhinweise mit `USP_ErrorLogAnalysis` oder bereits vorhandenen Extended-Events-Sessions. Führen Sie keine Produktionsprobe allein zur Diagnose aus.

### Typische Fehlinterpretation

`IsAdvancedAnalyticsInstalled = 1` ist kein Beweis für eine bestimmte Runtimeversion. Ein laufender Launchpad-Service ist kein Package-Healthcheck. Request-CPU aus `sys.dm_exec_requests` enthält keine belegte externe Prozess-CPU. `sys.dm_external_script_execution_stats` ist keine vollständige Script-Historie.

### Folgeanalyse

Prüfen Sie bei Blocking `USP_CurrentBlocking`, bei allgemeinen Requests `USP_CurrentRequests`, bei Pool- oder Workload-Governance `USP_ResourceGovernorAnalysis`, bei Countern `USP_PerformanceCounters` und bei Betriebsfehlern `USP_ErrorLogAnalysis` sowie vorhandene Extended-Events-Evidenz im selben Zeitfenster.

## Primärquellen

- [External-Script-Requests](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-external-script-requests?view=sql-server-ver17)
- [External-Script-Execution-Stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-external-script-execution-stats?view=sql-server-ver17)
- [External Resource Pools](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-resource-governor-external-resource-pools?view=sql-server-ver17)
- [External Languages](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-languages-transact-sql?view=sql-server-ver17)
- [External Libraries](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-libraries-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#10-monitorusp_externalruntimeanalysis)
