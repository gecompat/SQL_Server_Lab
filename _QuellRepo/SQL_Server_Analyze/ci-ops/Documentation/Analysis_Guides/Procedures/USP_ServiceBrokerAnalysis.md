# [monitor].[USP_ServiceBrokerAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Bewertet sichtbare Service-Broker-Queues, Aktivierung, Transmission und Conversation-Zustände ohne Nachrichteninhalt oder Zustandsänderung.<br>
**Beobachtungsart:** flüchtiger Runtime-Snapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Warum werden Service-Broker-Nachrichten nicht verarbeitet oder übertragen, und welche Queue-/Conversationzustände existieren?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServiceBrokerAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @NurProblematisch = 1,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Die Procedure verwendet für jeden fachlichen Lauf `CATALOG_DEEP`. Die Bestätigung ist deshalb auch beim Problemscope einer einzelnen Datenbank nötig; Queue-Inhalte werden dadurch weder freigegeben noch gelesen.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einem Datenbankstatus, isolierten Quellenstatus, Finding, einer Queue, einer gruppierten Transmission-Konstellation oder einem aggregierten Conversation-Zustand.

## So lesen

Prüfen Sie zuerst `StatusCode`, `IsPartial` und `SourceStatus`. Korrelieren Sie danach Queue-Schalter und approximativen Rückstand mit Queue-Monitor, aktivierten Tasks, Transmission-Alter/-Status und Conversation-Zuständen.

## Warum kann das problematisch sein?

Deaktiviertes RECEIVE oder Enqueue, fehlender Aktivierungsfortschritt, alte Transmission-Einträge und Conversation-Errorzustände können Verarbeitung oder Zustellung verhindern. Ein einzelner Wert beweist die Ursache jedoch nicht.

## Wann ist es kein Problem?

Queue-Monitor und Tasks sind Momentaufnahmen. Retention kann Queue-Zeilen nach erfolgreicher Verarbeitung erhalten, kurz laufende Reader können zwischen Messungen fehlen und langlebige Dialoge können fachlich beabsichtigt sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine nichtleere Queue mit aktivierter interner Prozedur, ohne sichtbaren Task und ohne laufende Receives ist ein Reviewfall, wenn alle drei Quellen vollständig sind. Prüfen Sie Zeitverlauf, Fehlerlog beziehungsweise freigegebene Events und Anwendungstransaktionen. RECEIVE OFF allein beweist keine Poison Message.

**Ähnlich aussehender Gegenfall:** Queue-Monitor und Tasks sind Momentaufnahmen. Retention kann Queue-Zeilen nach erfolgreicher Verarbeitung erhalten, kurz laufende Reader können zwischen Messungen fehlen und langlebige Dialoge können fachlich beabsichtigt sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_ServiceBrokerAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Ein Leerzustand beweist bei eingeschränkter Metadatensichtbarkeit keine Abwesenheit. Fehlende Rechte auf Aktivierungs-DMVs lassen andere Katalog-, Transmission- und Conversation-Evidenz gültig; die Procedure kennzeichnet diese Lücke über `IsPartial` und `SourceStatus`.

## Eigenlast und Grenzen

MEDIUM: sichtbare Kataloge, aggregierte Broker-Laufzeitmetadaten und approximative Partitionsstatistik. Es werden keine Queue-Nutzdaten gelesen und kein `RECEIVE`, `ALTER QUEUE` oder `END CONVERSATION` ausgeführt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, Problemscope und möglichst Queue-/Objektfilter; Konfiguration, approximative Queuegröße, Aktivierung, Transmission und aggregierte Conversation-Zustände werden gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken ohne Objektfilter und unbegrenzte Ausgabe bei vielen Queues, Transmissionzeilen und Conversation Endpoints. Nachrichtenkörper und Queue-Nutzdaten bleiben ausgeschlossen. |
| Haupttreiber | Zahl gewählter Datenbanken, Broker-Queues/-Services, Queue-Monitore, aktivierter Tasks, Transmissionzeilen und Conversation Endpoints. Nachrichteninhalte werden nicht gelesen; große offene Conversationbestände dominieren den Deep-Pfad. |
| Skalierung | Katalog-/Queuepfad wächst mit Brokerobjekten und Partitionen; Aggregationen über `sys.transmission_queue` und `sys.conversation_endpoints` wachsen mit Rückstand und Endpointbestand und können den Lauf dominieren. |
| Ressourcen | CPU und Datenbank-I/O für Brokerkataloge, Queue-Partitionsmetadaten und aggregierte Transmission-/Conversation-Systemtabellen; dynamisches SQL und TempDB/Arbeitsspeicher für Gruppen/Findings. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen Queuekatalogarbeit. `@MaxZeilen` und `@NurProblematisch` werden erst auf fertige Resultsets angewandt und begrenzen insbesondere die vorgelagerte Aggregation von Transmission und Conversations nicht. |
| Locking und Nebenwirkungen | Read-only ohne `RECEIVE`, `END CONVERSATION` oder Queueänderung. Runtime-/Systemtabellen verändern sich während des Laufs; kurze Katalogzugriffe und Aggregations-I/O können mit Brokeraktivität konkurrieren. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleDatabase`, Problemscope und konkrete Queuefilter. Bei großem Transmission-/Endpointbestand außerhalb der Lastspitze ausführen und zuerst Quellenstatus/Vollständigkeit prüfen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „flüchtiger Runtime-Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Warum werden Service-Broker-Nachrichten nicht verarbeitet oder übertragen, und welche Queue-/Conversationzustände existieren?

### Technischer Hintergrund

Service Broker ordnet typisierte Dialognachrichten anhand von Services und Contracts einer Queue zu. Internal Activation startet Procedures nach Queuezustand. Remoteübertragung nutzt Routes und Endpoints; `sys.transmission_queue` hält nicht zustellbare Nachrichten mit Fehlertext. Conversation Endpoints besitzen Zustandsmaschine und Lifetime.

### Datenkette

`sys.conversation_endpoints`, `sys.databases`, `sys.dm_broker_activated_tasks`, `sys.dm_broker_queue_monitors`, `sys.dm_db_partition_stats`, `sys.schemas`, `sys.service_queues`, `sys.services`, `sys.sp_executesql`, `sys.transmission_queue`.

### Source Select

Der Katalogkern verbindet Queue, Schema und darauf gebundene Services:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [q].[name] AS [QueueName]
    , [q].[is_receive_enabled]
    , [q].[is_activation_enabled]
    , COUNT_BIG([svc].[service_id]) AS [ServiceCount]
FROM [sys].[service_queues] AS [q] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [q].[schema_id]
LEFT JOIN [sys].[services] AS [svc] WITH (NOLOCK)
  ON [svc].[service_queue_id] = [q].[object_id]
WHERE [q].[is_ms_shipped] = 0
  AND [s].[name] = N'ExampleSchema'
  AND [q].[name] = N'ExampleObject'
GROUP BY
      [s].[name], [q].[name]
    , [q].[is_receive_enabled], [q].[is_activation_enabled];
```

**Wichtig für die Eigenlast:** Legen Sie Datenbank und Queue vor Queue-Monitor-, Activated-Task-, Transmission- und Conversation-Pfaden fest. Transmission und Endpoints werden aggregiert; Nachrichtenkörper werden nicht gelesen.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Queue-/Conversation-/Transmissionzustand; Rows können bei Verarbeitung rasch verschwinden, alte Dialoge persistieren.

### Bewertung und Gegenprobe

Korrelieren Sie Broker Enabled, Queue IsReceiveEnabled und Activation, Queue Rows, Transmission Errors und Age, Endpoint States, Routes, Remote Binding und Poison-Message-Deaktivierung. Messen Sie das Wachstum über die Zeit.

### Typische Fehlinterpretation

Queue Rows > 0 können normaler Backlog sein; `NOTIFIED`/Activationstatus allein beweist keinen erfolgreichen Consumer. `NEW_BROKER` wäre destruktiv für Dialogidentitäten und ist keine Diagnosemaßnahme.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Queueprocedure/Errorlog/XE, Network/Endpoint und wiederholtes Backlogsample.

## Primärquellen

- [Service Broker catalog views](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/service-broker-catalog-views-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#5-monitorusp_servicebrokeranalysis)
