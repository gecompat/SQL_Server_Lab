# [monitor].[USP_CurrentOverview]

**Bereich:** Current State, Orchestrator<br>
**Zweck:** Führt mehrere leichte Live-Analysen in definierter Reihenfolge aus.<br>
**Beobachtungsart:** nicht atomare Folge aus Snapshots und optionalen Stichproben<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Current-State-Symptome verdienen als Erstes eine spezialisierte Analyse?** Sie unterstützt die Entscheidung, ob das aktuelle Symptom im Erfassungsmoment sichtbar ist und welcher engere Live-, Verlaufs- oder Planpfad als Nächstes sinnvoll ist.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine lückenlose Historie und allein aus einem Snapshot weder Dauerhäufigkeit noch Root Cause oder zukünftige Entwicklung. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CurrentOverview]
      @MitSqlText = 0,
      @SampleSeconds = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Der Default `@Detailgrad = 'SUMMARY'` liefert genau ein konsolidiertes
Modul-Summary. `RELEVANT` ergänzt nicht leere diagnostisch relevante Details;
`ALL` ergänzt alle nicht leeren aktivierten Childdetails. Sampling und
Aktivieren Sie vollständige SQL-Texte nur gezielt.

`@ToolHintergrundabfragenEinbeziehen = 0` wird an Sessions, Requests, Blocking
und aktuelle Waiting Tasks weitergegeben. Mit Wert `1` werden erkannte
Tool-Hintergrundaktivitäten samt Klassifikation in allen vier Childresultaten
sichtbar. Die Blockingkette normaler Abfragen bleibt auch dann vollständig,
wenn ihr Zwischen- oder Root-Blocker ein erkanntes Tool ist.

Die Blocking-Ressourcenauflösung ist durchgereicht: `NONE` deaktiviert sie,
`STANDARD` ist der auf 100 Kandidaten begrenzte Default. `DEEP` liest zusätzlich
die Locks beteiligter Blocking-Sessions und verlangt `LOCKS_DEEP` sowie
`@HighImpactConfirmed = 1`.

```sql
DECLARE @OverviewJson nvarchar(max);
EXEC [monitor].[USP_CurrentOverview]
      @BlockingObjektTiefe = 'DEEP',
      @MaxObjektAufloesungen = 500,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'NONE',
      @JsonErzeugen = 1,
      @Json = @OverviewJson OUTPUT;
SELECT JSON_QUERY(@OverviewJson, '$.blocking.locks') AS BlockingLocks;
```

Die vollständigen Deep-Lockzeilen liegen im Overview-JSON unter
`$.blocking.locks`. CONSOLE- und TABLE-Details des Orchestrators materialisieren
nur die Blockingketten. Für ein direktes Lockgrid ist
`USP_CurrentBlocking @ResultSetArt = 'RAW'` der passendere Aufruf.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`, `snapshotStatus`,
`sessions`, `requests`, `requestContext`, `statements`, `batches`,
`inputBuffers`, `blocking`, `waits`, `transactions`, `memoryGrants`,
`tempdbSessions`, `tempdbGovernance`, `io`, `logs` und `warnings`. Status, Scope und Warnings sind
vor den Fachergebnissen zu lesen. Resultsets mit unterschiedlicher
Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden. Im
Overview-JSON liegt die Governance innerhalb des einmal erzeugten TempDB-Childs
unter `$.tempdbSessions.tempdbGovernance`.


## Laufinterner Primär-Snapshot

Vor den acht Snapshot-fähigen Children materialisiert der Overview-Owner nur die
dafür benötigten Primärquellen. `snapshotStatus` weist pro Quelle
`SnapshotId`, `CapturedAtUtc`, Abschlusszeit, Status, Partialität und Zeilenzahl aus.
SQL-Text wird nur bei einem tatsächlichen Consumer materialisiert;
SQL-Handles werden vor dem DMF-Zugriff dedupliziert und begrenzt. Input Buffer
bleibt eine gezielte Post-Candidate-Quelle von `USP_CurrentRequests` und gehört
noch nicht zum gemeinsamen Primär-Snapshot.

Sessions, Requests, Blocking, Waits, Transactions, Memory Grants, TempDB und
I/O erhalten dieselbe laufinterne Snapshot-ID und lesen die gemeinsam
materialisierten Quellen nicht erneut. Mit `@MitTempDB=1` umfasst dieser
Snapshot auf SQL Server 2025 auch Workload-Group-Limits, Nutzung, Peak,
Verletzungszähler und Resetzeitpunkt. Eigene, nicht überlappende Quellen wie
Locks, Instanz-Wait-Stats, Datei-I/O oder TempDB-Dateikatalog bleiben im
jeweiligen Child. Schlägt der Owner selbst fehl, wird der Fehler als
`SNAPSHOT_OWNER` ausgewiesen und die Children fallen auf frische Einzelreads
zurück.

Die Snapshot-ID und alle Temp-Tabellen enden mit dem Procedure-Aufruf. Ein
späterer Einzelaufruf kann sie nicht wiederverwenden. Die Quellzeitpunkte
bleiben getrennt; dieselbe ID bedeutet einen gemeinsamen Aufrufvertrag, keine
transaktionale Atomizität.

## Eine Zeile bedeutet

Im Summary entspricht eine Zeile einem Childmodul. Status, Partialität,
Zeilenanzahl und Dauer stammen aus dem expliziten Childvertrag. In den bewusst
aktivierten Detailgraden entspricht eine Detailzeile weiterhin Session, Request,
Blockingkante, Wait, Transaktion, Grant, TempDB-Verbrauch, Datei-I/O oder
Logzustand.

## So lesen

Lesen Sie zuerst den Modulstatus und wechseln Sie danach vom konkreten Symptom zum passenden Child. Addieren Sie Resultsets nicht ungeprüft miteinander.

## Warum kann das problematisch sein?

Ein Überblick verdichtet unterschiedliche Evidenzarten. Ein auffälliger Einzelwert ohne Childkontext kann zu einer falschen Ursache führen.

## Wann ist es kein Problem?

Nicht aktivierte Children fehlen absichtlich. Ein leeres Child ist nur bei erfolgreichem Status als „aktuell nichts sichtbar“ interpretierbar.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Blocking und hohe Logauslastung können dieselbe alte Transaktion als Ursache haben. Mit Blocking- und Transaktionsprocedure fokussiert nachprüfen.

**Ähnlich aussehender Gegenfall:** Nicht aktivierte Children fehlen absichtlich. Ein leeres Child ist nur bei erfolgreichem Status als „aktuell nichts sichtbar“ interpretierbar. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Live-DMVs kann der Zustand bereits beendet sein, bevor die Quelle gelesen wird. Eine leere Menge ist deshalb höchstens 'jetzt nicht sichtbar', nicht 'trat nicht auf'.

Für `USP_CurrentOverview` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Der Default ruft alle neun Current-State-Children einmal auf, materialisiert deren TABLE-Ergebnisse und erzeugt Childstatus/JSON. `@Detailgrad = 'SUMMARY'` verkürzt nur die sichtbare Ausgabe; er spart die Erhebung nicht ein. Mit `@SampleSeconds = 0` gibt es kein WAITFOR. |
| Teuerster Pfad | Breiter Datenbank- und Sessionscope, SQL-Text an und `@SampleSeconds = 60`: `USP_CurrentWaits` und `USP_CurrentIO` sampeln nacheinander, sodass allein die beiden WAITFOR-Intervalle den Parent um ungefähr 120 Sekunden verlängern können. |
| Haupttreiber | Zahl sichtbarer Sessions, Requests, Blockingkanten, Transaktionen, Grants und TempDB-Verbraucher sowie Datenbanken/Dateien für I/O und Log. SQL-Text verbreitert mehrere Childresultate. |
| Skalierung | Jedes Child liest seinen eigenen Zeitpunkt und schreibt in eine Parent-Temp-Tabelle. Kosten addieren sich sequenziell; derselbe Request kann in mehreren Children erneut gelesen werden. Mehr Detailausgabe erhöht Transfer, ändert aber nicht die bereits angefallene Childarbeit. |
| Ressourcen | Live-DMV- und Datenbankmetadatenzugriffe, Temp-Tabellen/JSON und optional zwei wartende Samplephasen. Es gibt in diesem Parent keinen XEL-, Plan-XML-, `msdb`- oder Benutzerdatenscan. |
| Begrenzungswirkung | `@MaxZeilen` wird je Child weitergereicht und ist kein globales Budget. Einige Children nutzen ein frühes Kandidatenlimit, andere begrenzen erst sortierte/aggregierte Resultate; die Quellen für Instanzwaits und Datei-I/O werden dadurch nicht vollständig vermieden. `SUMMARY` ist ausdrücklich kein Kostenlimit. |
| Locking und Nebenwirkungen | Read-only ohne absichtlich gehaltene Nutzdatenlocks. Sampling hält die aufrufende Session während jedes WAITFOR; die Children laufen nacheinander und bilden daher keinen atomaren Zustand. |
| Schutzmechanismus | `@HighImpactConfirmed` wird an datenbankbezogene Children weitergereicht und wirkt nur, wenn deren konkrete Analyseklasse ein Gate verlangt. Der Parent aktiviert keine VLF-, Datei-, XML- oder sonstige Deep-Option; der Schalter begrenzt weder Laufzeit noch Ergebnisgröße. |
| Sicherer Einsatz | SQL-Text und Sampling zunächst aus, `@MaxZeilen = 100`, nicht benötigte Children abschalten und Datenbanken/Sessions eingrenzen. Nach dem Summary genau das Child separat wiederholen, das zum Symptom passt. |
| Aussagegrenze | Ein Child kann zwischen den sequenziellen Abfragen verschwinden oder neu entstehen. Ein Parentlimit kann Ranglisten abschneiden, und ein erfolgreicher Summarystatus macht die unterschiedlichen Messzeitpunkte nicht konsistent; „leer“ bedeutet nur im jeweiligen Childmoment nicht sichtbar. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Current-State-Symptome verdienen als Erstes eine spezialisierte Analyse?

### Technischer Hintergrund

Der Orchestrator ruft jedes aktivierte Child genau einmal und niemals mit
CONSOLE auf. Der eine Childaufruf materialisiert das Primärergebnis und erzeugt
den JSON-/Statusvertrag. Summary, optionale Details, JSON und TABLE-Export nutzen
diese Materialisierung weiter. Das Ausbleiben eines SQL-Fehlers wird nicht als
`AVAILABLE` interpretiert; ein fehlender oder unvollständiger Statusvertrag wird
als `STATUS_UNAVAILABLE` partiell ausgewiesen.

TABLE verwendet ausschließlich `@ResultTablesJson`. Exportierbar sind
`moduleStatus`, `sessions`, `requests`, `blocking`, `waits`, `transactions`,
`memoryGrants`, `tempdbSessions`, `tempdbGovernance`, `io`, `logs` und
`warnings`.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung und Filterlogik; die Procedure besitzt keine eigenständige Systemquelle.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert `USP_CurrentSessions`, `USP_CurrentRequests`, `USP_CurrentBlocking`, `USP_CurrentWaits`, `USP_CurrentTransactions`, `USP_CurrentMemoryGrants`, `USP_CurrentTempDB`, `USP_CurrentIO` und `USP_CurrentLog`. Die direkten Quellbeziehungen stehen in den jeweiligen Child-Seiten.

**Wichtig für die Eigenlast:** Die Childmodule laufen nacheinander und bilden keinen atomaren Snapshot. `@MitSqlText = 0`, ein endliches `@MaxZeilen` und `@SampleSeconds = 0` halten den Einstieg klein. Vertiefen Sie anschließend nur den auffälligen Childpfad.

### Zeit- und Scope-Modell

Die Auswertung kombiniert nahe beieinanderliegende, aber nicht atomare Momentaufnahmen; Sampling-Childs können den Aufruf verlängern.

`@BlockingObjektTiefe = 'DEEP'` kann bei lockintensiven Systemen die Eigenlast
des Overview merklich erhöhen. Der Standardpfad bleibt dedupliziert und durch
`@MaxObjektAufloesungen` begrenzt.

### Bewertung und Gegenprobe

Prüfen Sie zuerst Modulstatus und Partialflags und vertiefen Sie danach nur auffällige Children. Eine Korrelation ist möglich, wenn dieselbe Session, Datenbank oder Datei in mehreren Children erscheint.

### Typische Fehlinterpretation

Ein unauffälliger Overview beweist nicht, dass zwischen Childaufrufen kein kurzer Vorfall auftrat. Resultsets dürfen nicht so behandelt werden, als stammten sie aus einer gemeinsamen Transaktion.

### Folgeanalyse

Führen Sie das betroffene Childmodul mit engeren Filtern erneut aus.

## Primärquellen

- [Dynamic Management Views](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [sp_WhoIsActive – ergänzende Live-Diagnostik und andere Aufbereitung aktueller Aktivität](https://github.com/amachanic/sp_whoisactive)

[Technische Detailbeschreibung](../02_Current_State.md#10-monitorusp_currentoverview)
