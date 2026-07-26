# Analyse-Resultsets richtig lesen – Einsteigerleitfaden für alle Procedures

**Stand:** 17. Juli 2026  
**Abdeckung:** alle 97 dokumentierten öffentlichen Procedures einschließlich der eigenständigen und optionalen Pakete
**Zweck:** Der Leitfaden erklärt, **wie** die Resultsets gelesen werden, **worauf** zu achten ist und **warum** bestimmte Kombinationen problematisch oder unkritisch sein können.

> Dieser Leitfaden ergänzt die technischen Detailbeschreibungen. Die Bereichsleitfäden nennen Resultsets und Spalten; hier wird daraus ein nachvollziehbarer Analyseweg.

## 1. Die wichtigste Grundregel

Ein einzelner hoher oder niedriger Wert ist selten schon eine Diagnose. Ein belastbarer Befund entsteht normalerweise aus einer Kombination:

1. **Scope:** Welcher Server, welche Datenbank, welches Objekt, welche Session oder welche Query ist betroffen?
2. **Zeitbezug:** Momentaufnahme, Stichprobe, kumulativer Zähler oder Historie?
3. **Belastung:** Wie viel Arbeit fand statt – Ausführungen, Zeilen, Reads, Dauer oder Datenmenge?
4. **Symptom:** Welche Ressource wartet, wächst, läuft voll oder wird ungewöhnlich oft verwendet?
5. **Auswirkung:** Werden andere Sessions blockiert, steigt die Laufzeit, fehlt Speicher oder droht Datenverlust?
6. **Gegenprobe:** Kann derselbe Wert in dieser Workload normal sein?
7. **Folgeschritt:** Welche zweite Procedure bestätigt oder widerlegt die Vermutung?

### 1.1 Warum Kombinationen wichtiger sind als Einzelwerte

| Einzelwert | Noch keine ausreichende Aussage | Problematischer Zusammenhang |
|---|---|---|
| hohe Laufzeit | kann absichtlich langer Report sein | hohe Laufzeit + wachsende Lock-Wartezeit + viele blockierte Sessions |
| hohe CPU | kann kurze, produktive Parallelverarbeitung sein | hohe CPU + hohe Reads + wenige Ergebniszeilen + wiederholte Ausführung |
| hoher Memory Grant | kann für großen Hash Join erforderlich sein | großer Grant + geringe Nutzung + viele wartende Grants |
| hohe Fragmentierung | bei acht Seiten bedeutungslos | Millionen Seiten + niedrige Seitendichte + scanlastige Workload |
| keine Nutzung | Beobachtungsfenster kann zu kurz sein | 180 Tage Beobachtung + Millionen Updates + keine Reads + keine Abhängigkeit |
| leeres Resultset | kann gesund sein | Quelle nicht verfügbar, Berechtigung fehlt oder Retention hat Daten gelöscht |

## 2. Gemeinsame Leserichtung für jedes Resultset

### Schritt A – Status zuerst

Lesen Sie vor den Fachdaten immer `StatusCode`, `IsPartial`, Warnungen und Fehler.

- `AVAILABLE` bedeutet: Der vorgesehene Pfad war grundsätzlich verfügbar.
- `AVAILABLE_LIMITED` oder `IsPartial=1` bedeutet: Ein Teil der Evidenz fehlt.
- `PERMISSION_DENIED`, `UNAVAILABLE_FEATURE` oder ähnliche Statuscodes erklären, warum ein Resultset leer oder unvollständig sein kann.

**Warum wichtig:** Ein leeres Resultset bei vollständiger erfolgreicher Erfassung ist etwas anderes als ein leeres Resultset wegen fehlender Rechte.

### Schritt B – Zeitfenster bestimmen

- Live-DMV: aktueller Zustand, kann Sekunden später verschwunden sein.
- Stichprobe: Delta innerhalb von `@SampleSeconds`.
- kumulativer Zähler: seit Restart, Cacheeintrag, Datenbankstatuswechsel oder anderem Reset.
- Historie: nur innerhalb von Retention und Capture-Zeitraum.

**Warum wichtig:** `0 Reads` seit einem Restart vor einer Stunde ist schwache Evidenz; `0 Reads` über 180 Tage ist wesentlich aussagekräftiger.

### Schritt C – Nenner suchen

Prozent- und Durchschnittswerte benötigen einen Nenner:

- 100 % Fragmentierung bei 8 Seiten ist meist unwichtig.
- 50 % Regression bei einer Ausführung ist statistisch schwach.
- 20 % Deleted Rows bei einer kleinen selten gelesenen Rowgroup kann tolerierbar sein.
- 5 ms durchschnittlicher Wait bei zehn Millionen Waits kann insgesamt sehr relevant sein.

### Schritt D – Ursache und Auswirkung trennen

Ein Resultset zeigt oft zuerst ein **Symptom**:

- `LCK_M_X` zeigt Lock-Warten, aber noch nicht, warum der Blocker die Transaktion offen hält.
- `RESOURCE_SEMAPHORE` zeigt Grant-Knappheit, aber nicht, ob Schätzfehler, Parallelität oder Konkurrenz die Ursache ist.
- hohe I/O-Latenz zeigt langsame Dateiantwort, aber nicht automatisch defektes Storage.

### Schritt E – nie unmittelbar verändern

Kein einzelner Befund rechtfertigt automatisch:

- `KILL`,
- Index löschen oder erstellen,
- Rebuild/Reorganize,
- Konfiguration ändern,
- Plan forcieren,
- Failover,
- Repair.

Erst zweite Evidenzquelle, Auswirkung, Risiko und Rollbackweg bestimmen.

# 3. Common

## [monitor].[USP_CheckAnalyseAccess]

**Auswertung:** Prüfen Sie zuerst `IsAllowed` und danach `AccessReason`, `RelevantPolicyCount` sowie `MatchedGroupCount`. Vergleichen Sie anschließend Original- und Effektivlogin.

**Warum problematisch:** `RelevantPolicyCount > 0` und `MatchedGroupCount = 0` bedeutet, dass für diese Analyseklasse Regeln existieren, aber keine passende Gruppenmitgliedschaft erkannt wurde. Der Zugriff ist deshalb erwartbar gesperrt und nicht technisch defekt.

**Wann nicht problematisch:** `RelevantPolicyCount = 0` und `IsAllowed = 1` entspricht dem Frameworkvertrag: Ohne definierte Policy bleibt die Klasse offen.

**Beispiel:** `IsAllowed=0`, `AccessReason=NO_GROUP_MATCH` ist kein DMV-Fehler. Prüfen Sie zuerst die Gruppenpolicy und ändern Sie nicht die SQL-Berechtigungen.

**Nächster Schritt:** `USP_CheckFrameworkCapabilities` prüft, ob der technisch erlaubte Pfad auch tatsächlich lesbar ist. [Detailbeschreibung](01_Common.md#2-monitorusp_checkanalyseaccess)

## [monitor].[USP_CheckFrameworkCapabilities]

**Auswertung:** Prüfen Sie die Angaben in der Reihenfolge `VersionSupported` → `GroupAccessAllowed` → `HasRequiredPermission` → `IsQueryable` → `IsFeatureEnabled` → `IsUsable`.

**Warum problematisch:** `HasRequiredPermission=1`, aber `IsQueryable=0` zeigt, dass die formale Permission allein nicht genügt. Datenbankstatus, Plattform, Replica-Rolle oder ein Laufzeitfehler begrenzen den Pfad.

**Wann nicht problematisch:** `IsFeatureEnabled=0` bei einem bewusst nicht verwendeten Feature ist kein Fehler. Es erklärt nur, warum die zugehörige Analyse keine Daten liefern kann.

**Beispiel:** Query Store ist versionsseitig unterstützt und lesbar, aber deaktiviert. Ein leeres Query-Store-Resultset ist dann erwartbar und keine Aussage über die Queryqualität.

**Nächster Schritt:** Rufen Sie nur Procedures auf, deren relevanter Scope `IsUsable=1` meldet. [Detailbeschreibung](01_Common.md#3-monitorusp_checkframeworkcapabilities)

## [monitor].[USP_PrepareDatabaseCandidates]

**Auswertung:** Diese interne Procedure liefert keine normalen Resultsets. Entscheidend sind die befüllte `#DatabaseCandidates`, Warnungen und OUTPUT-Statuswerte.

**Warum problematisch:** Eine explizit angeforderte Datenbank, die in der Warnung als nicht verfügbar erscheint, fehlt anschließend vollständig in der Fachanalyse. Das kann zu falscher Entwarnung führen, wenn die Warnung ignoriert wird.

**Wann nicht problematisch:** Die vollständige Kandidatenmenge ist beabsichtigt.
Explizit genannte, aber nicht verfügbare Datenbanken werden als Warning
ausgewiesen; ressourcenintensive Pfade besitzen ein separates Bestätigungsgate.

**Beispiel:** Zwei Datenbanken wurden angefordert, eine ist offline. Die Analyse enthält nur die online Datenbank; die Warnung muss als fehlender Scope dokumentiert werden.

**Nächster Schritt:** Lesen Sie Warnungen immer zusammen mit dem Resultset der aufrufenden Procedure. [Detailbeschreibung](01_Common.md#4-monitorusp_preparedatabasecandidates)

## [monitor].[USP_PrepareNameFilters]

**Auswertung:** Prüfen Sie, welche Filterart befüllt wurde und ob der Status gültig ist. Bei Fehlern wird die temporäre Tabelle geleert.

**Warum problematisch:** Eine leere Filtertabelle nach `INVALID_PARAMETER` darf nicht wie „kein Filter“ behandelt werden. Sonst könnte eine nachfolgende Analyse versehentlich zu breit laufen.

**Wann nicht problematisch:** Unter der case-sensitiven Collation sind `ExampleTable` und `exampletable` verschiedene Namen.

**Beispiel:** Doppelte identische Namen verursachen absichtlich einen Fehler; zwei nur in Groß-/Kleinschreibung verschiedene Namen nicht.

**Nächster Schritt:** Korrigieren Sie die Eingabeliste und führen Sie die aufrufende Analyse erneut aus. [Detailbeschreibung](01_Common.md#5-monitorusp_preparenamefilters)

# 4. Current State

## [monitor].[USP_CurrentSessions]

**Auswertung:** Prüfen Sie zuerst `SessionStatus`, `RequestStatus` und `OpenTransactionCount`. Berücksichtigen Sie danach die letzte Aktivität, die kumulativen CPU-/I/O-Werte und die Verbindungsinformationen.

**Warum problematisch:** `sleeping` + `OpenTransactionCount > 0` bedeutet, dass der Client aktuell nichts ausführt, aber eine Transaktion offen bleibt. Dadurch können Locks, Log-Wiederverwendung und Blocking bestehen bleiben.

**Wann nicht problematisch:** Eine lange eingeloggte sleeping Session ohne offene Transaktion ist bei Connection Pools normal.

**Beispiel:** Eine Session ist seit acht Stunden verbunden, aber zuletzt vor zehn Sekunden aktiv und ohne Transaktion. Das Alter allein ist kein Problem. Dieselbe Session mit offener Transaktion seit zwei Stunden ist kritisch.

**Nächster Schritt:** Prüfen Sie `USP_CurrentTransactions` und bei aktiver Arbeit `USP_CurrentRequests`. [Detailbeschreibung](02_Current_State.md#1-monitorusp_currentsessions)

## [monitor].[USP_CurrentRequests]

**Auswertung:** Vergleichen Sie zuerst `ElapsedMs`, `CpuMs`, Reads und Writes. Berücksichtigen Sie danach Blocking, Waits, Memory Grant, DOP und den aktuellen Statementtext.

**Warum problematisch:** Hohe Laufzeit bei sehr niedriger CPU bedeutet, dass die Zeit überwiegend nicht mit Rechenarbeit verbracht wurde. Ein wachsender Lock-Wait oder fehlender Memory Grant erklärt dann die Verzögerung.

**Wann nicht problematisch:** Hohe CPU bei kurzer Laufzeit und hohem DOP kann eine produktive analytische Abfrage sein, wenn sie erwartbar ist und keine Konkurrenz verdrängt.

**Beispiel:** `ElapsedMs=180000`, `CpuMs=900`, `WaitType=LCK_M_X`, `BlockingSessionId=74` bedeutet: Drei Minuten vergangen, aber nur 0,9 Sekunden CPU. Fast die gesamte Zeit wartet der Request auf einen exklusiven Lock – deshalb ist Blocking die relevante Spur.

**Nächster Schritt:** Prüfen Sie Blocking → `USP_CurrentBlocking`; Grant → `USP_CurrentMemoryGrants`; CPU/Reads → Plan Cache oder Query Store. [Detailbeschreibung](02_Current_State.md#2-monitorusp_currentrequests)

## [monitor].[USP_CurrentBlocking]

**Auswertung:** Verfolgen Sie die Kanten von `LeafSessionId` bis `RootBlockingSessionId`. Vergleichen Sie dabei Waitzeit, Ressource und Zustand des Root Blockers.

**Warum problematisch:** Viele blockierte Sessions können dieselbe einzelne Root-Session haben. Das Beenden eines Opfers löst die Ursache nicht; der Root Blocker hält weiterhin die Ressource.

**Wann nicht problematisch:** Kurze Blockierung ist bei transaktionaler Konsistenz normal. Relevant wird sie, wenn dieselbe Kette in Folgemessungen wächst oder SLA-Auswirkungen erzeugt.

**Beispiel:** Zehn Sessions warten jeweils zwei Minuten auf Session 51, die sleeping ist und eine offene Transaktion besitzt. Das ist problematischer als eine aktiv arbeitende Session, die seit 50 ms kurz einen Lock hält.

**Nächster Schritt:** Untersuchen Sie die Root-Session mit `USP_CurrentTransactions` und `USP_CurrentRequests`. Verwenden Sie Blocked-Process-XE für die historische Analyse. [Detailbeschreibung](02_Current_State.md#3-monitorusp_currentblocking)

## [monitor].[USP_CurrentWaits]

**Auswertung:** Berücksichtigen Sie Waittyp und Waitgruppe zusammen mit Dauer, Anzahl, Session, Request und Samplemodus. Bewerten Sie bei einem Sampling das Delta und nicht den kumulativen Gesamtwert.

**Warum problematisch:** Ein dominanter Wait zeigt, wo Zeit verloren geht. Er wird erst mit hoher Gesamtdauer, Wiederholung und messbarer Auswirkung relevant.

**Wann nicht problematisch:** Viele SQL-Server-Waits sind normal oder Hintergrundaktivität. Auch Parallelitätswaits beweisen keine falsche MAXDOP-Konfiguration.

**Beispiel:** `PAGEIOLATCH_SH` über 20 ms einmalig ist kein Beweis für langsames Storage. Millionen solcher Waits mit steigender Datei-Latenz und langsamen Queries sind dagegen eine starke I/O-Spur.

**Nächster Schritt:** Prüfen Sie Lockwaits → Blocking; I/O-Waits → `USP_CurrentIO`; Grantwaits → Memory Grants; CPU/Scheduler → Server Health. [Detailbeschreibung](02_Current_State.md#4-monitorusp_currentwaits)

## [monitor].[USP_CurrentTransactions]

**Auswertung:** Berücksichtigen Sie Transaktionsalter, Sessionstatus, `OpenTransactionCount`, Logbytes und SQL-Kontext gemeinsam.

**Warum problematisch:** Eine alte Transaktion kann Locks halten, die Log-Wiederverwendung verhindern und bei Rollback sehr lange benötigen. Sleeping verstärkt den Verdacht auf vergessene Commit-/Rollback-Logik.

**Wann nicht problematisch:** Eine lange aktive Transaktion kann bei geplanten Batchloads oder Wartung erwartet sein, sofern Fortschritt, Logkapazität und Blocking kontrolliert sind.

**Beispiel:** Sleeping seit 30 Minuten, offene Transaktion, wachsender Logverbrauch und mehrere Blockierte: starke Evidenz für einen Anwendungspfad, der die Transaktion nicht beendet hat.

**Nächster Schritt:** Prüfen Sie `USP_CurrentBlocking`, `USP_CurrentLog` und Anwendungsablauf. [Detailbeschreibung](02_Current_State.md#5-monitorusp_currenttransactions)

## [monitor].[USP_CurrentMemoryGrants]

**Auswertung:** Vergleichen Sie `RequestedMemoryMb`, `GrantedMemoryMb`, `UsedMemoryMb`, Wartezeit und Konkurrenz.

**Warum problematisch:** Ein Request mit großem angefordertem Grant und `GrantedMemoryMb=0` wartet, bis genügend Query Execution Memory verfügbar wird. Viele solche Requests können sich gegenseitig stauen.

**Wann nicht problematisch:** Ein großer gewährter und tatsächlich genutzter Grant kann für einen großen Sort oder Hash Join angemessen sein.

**Beispiel:** 32 GB angefordert, 0 gewährt, 60 Sekunden `RESOURCE_SEMAPHORE`: der Request arbeitet nicht langsam – er durfte noch gar nicht beginnen. Dagegen sind 32 GB gewährt und 28 GB genutzt bei einem geplanten großen Report plausibel.

**Nächster Schritt:** Prüfen Sie Plan, Kardinalität, DOP, Konkurrenz und Servermemory. [Detailbeschreibung](02_Current_State.md#6-monitorusp_currentmemorygrants)

## [monitor].[USP_CurrentTempDB]

**Auswertung:** Prüfen Sie zuerst die Datei- und Gesamtauslastung. Unterscheiden Sie danach den Sessionverbrauch nach User Objects, Internal Objects, Version Store und freier Fläche.

**Warum problematisch:** Eine einzelne Session mit stark wachsendem Internal-Object-Verbrauch kann große Sorts, Hashes oder Spills erzeugen. Version Store wächst dagegen typischerweise durch lange Snapshot-/RCSI-Transaktionen.

**Wann nicht problematisch:** Kurzzeitige TempDB-Spitzen während kontrollierter ETL- oder Indexoperationen können erwartet sein, wenn Dateien ausreichend dimensioniert sind und kein Autogrowth-Sturm entsteht.

**Beispiel:** TempDB 90 % voll allein erklärt die Ursache nicht. 80 % Version Store + sehr alte Snapshot-Transaktion weist auf etwas anderes hin als 80 % Internal Objects einer einzelnen Query.

**Nächster Schritt:** Prüfen Sie Session → `USP_CurrentRequests`; Version Store → Transaktionen; Dateien → `USP_TempDBConfiguration`. [Detailbeschreibung](02_Current_State.md#7-monitorusp_currenttempdb)

## [monitor].[USP_CurrentIO]

**Auswertung:** Trennen Sie kumulative Durchschnittswerte vom Sample-Delta. Vergleichen Sie Reads, Writes, Bytes, Operationen und Latenz je Datei.

**Warum problematisch:** Hohe Latenz bei vielen aktuellen I/O-Operationen kann Requests unmittelbar bremsen. Ein hoher kumulativer Durchschnitt kann jedoch von einem alten Ereignis stammen.

**Wann nicht problematisch:** Eine selten verwendete Datei mit einer einzigen langsamen Operation kann einen extremen Durchschnitt zeigen, ohne aktuelle Relevanz.

**Beispiel:** 500 ms Durchschnitt bei nur einer Operation seit Start ist schwach. 25 ms im 10-Sekunden-Sample bei zehntausenden Reads und gleichzeitigem `PAGEIOLATCH` ist deutlich belastbarer.

**Nächster Schritt:** Prüfen Sie betroffene Queries, Datei-/Volumekapazität und externes Storage-Monitoring. [Detailbeschreibung](02_Current_State.md#8-monitorusp_currentio)

## [monitor].[USP_CurrentLog]

**Auswertung:** Berücksichtigen Sie Used Percent, Loggröße, `log_reuse_wait_desc`, Wachstum, VLF und gegebenenfalls den Persistent Version Store gemeinsam.

**Warum problematisch:** Hohe Auslastung ist besonders kritisch, wenn die Wiederverwendung durch eine alte Transaktion, fehlende Logbackups oder Replikations-/AG-Lag verhindert wird. Dann hilft bloßes Vergrößern nur vorübergehend.

**Wann nicht problematisch:** Hohe prozentuale Nutzung unmittelbar während eines geplanten großen Batchs kann akzeptabel sein, wenn Kapazität, Backupfolge und Wiederverwendung kontrolliert sind.

**Beispiel:** 95 % genutzt + `ACTIVE_TRANSACTION` + 2-Stunden-Transaktion: Ursache ist nicht primär die Dateigröße, sondern die offene Transaktion.

**Nächster Schritt:** Prüfen Sie `USP_CurrentTransactions`, Backup-/AG-Status und Kapazitätsanalyse. [Detailbeschreibung](02_Current_State.md#9-monitorusp_currentlog)

## [monitor].[USP_CurrentOverview]

**Auswertung:** Prüfen Sie zuerst den Modulstatus und wechseln Sie dann vom Symptom zum passenden Detailmodul. Gewichten Sie nicht alle Child-Resultsets gleichermaßen.

**Warum problematisch:** Ein auffälliger Wert in einem Child kann ohne Kontext irreführen. Der Überblick dient Triage, nicht endgültiger Ursachenfeststellung.

**Wann nicht problematisch:** Ein Child ohne Zeilen kann bedeuten, dass aktuell kein entsprechendes Symptom sichtbar ist – sofern der Childstatus vollständig war.

**Beispiel:** Overview zeigt Blocking und hohe Logauslastung. Erst die Blocking-/Transaktionskette kann zeigen, dass dieselbe alte Transaktion beide Symptome verursacht.

**Nächster Schritt:** Rufen Sie das spezifische Childmodul mit engeren Filtern erneut auf. [Detailbeschreibung](02_Current_State.md#10-monitorusp_currentoverview)

# 5. Object und Index

## [monitor].[USP_ObjectInventory]

**Auswertung:** Prüfen Sie zuerst Objektgröße und Zeilenanzahl. Berücksichtigen Sie danach Indexart, Schlüssel, Includes, Partitionierung, Kompression und Sonderzustände.

**Warum problematisch:** Ein großer deaktivierter, hypothetischer oder stark redundanter Index kann Speicher und Wartungskosten verursachen. Die Definition allein beweist aber keine Entbehrlichkeit.

**Wann nicht problematisch:** Gemischte Kompression oder mehrere ähnliche Indizes können Teil einer bewussten Hot-/Cold- oder Coverage-Strategie sein.

**Beispiel:** Zwei Indizes haben gleiche Schlüssel, aber einer sichert eine Unique Constraint. Trotz Ähnlichkeit darf er nicht wie ein gewöhnlicher Duplikatindex behandelt werden.

**Nächster Schritt:** Prüfen Sie Usage, Operational Stats und konkrete Pläne. [Detailbeschreibung](03_Object_Index.md#1-monitorusp_objectinventory)

## [monitor].[USP_IndexUsage]

**Auswertung:** Berücksichtigen Sie Resetzeit, Reads, Updates, letzte Nutzung und Schutzmerkmale wie Primary Key oder Unique Constraint gemeinsam.

**Warum problematisch:** Viele Updates ohne Reads bedeuten potenzielle Schreib-, Log-, Lock- und Speicherlast ohne sichtbaren Lesebedarf.

**Wann nicht problematisch:** Kurzes Beobachtungsfenster, saisonale Reports oder Constraints machen `0 Reads` unzureichend für eine Löschung.

**Beispiel:** 0 Reads, 8 Mio. Updates, 180 Tage Beobachtung ist ein starker Reviewkandidat. 0 Reads, 40 Updates, zwei Stunden seit Restart ist praktisch bedeutungslos.

**Nächster Schritt:** Prüfen Sie Query Store, Abhängigkeiten, Constraints und `USP_IndexOperationalStats`. [Detailbeschreibung](03_Object_Index.md#2-monitorusp_indexusage)

## [monitor].[USP_IndexOperationalStats]

**Auswertung:** Bewerten Sie Zähler nicht isoliert, sondern normalisieren Sie diese pro Aktivität oder Wait. Vergleichen Sie DML, Allocations, Locks, Latches und Scans.

**Warum problematisch:** Viele Page Allocations pro Insert können Page-Split-/Wachstumsdruck anzeigen; hohe Lock-/Latchzeiten können Parallelität und Durchsatz begrenzen.

**Wann nicht problematisch:** Hohe absolute Zähler sind bei einem sehr stark genutzten Index normal. Relevant sind Verhältnis, Delta und Auswirkung.

**Beispiel:** Eine Million Page-Latch-Waits über ein Jahr kann weniger kritisch sein als 50.000 Waits in fünf Minuten auf derselben Hot Page.

**Nächster Schritt:** Prüfen Sie Live-Waits, Showplan, Keyverteilung und gegebenenfalls `OPTIMIZE_FOR_SEQUENTIAL_KEY`-Kontext. [Detailbeschreibung](03_Object_Index.md#3-monitorusp_indexoperationalstats)

## [monitor].[USP_MissingIndexes]

**Auswertung:** Prüfen Sie zuerst Reads und Compiles und danach Impact und Improvement Measure. Vergleichen Sie anschließend vorgeschlagene Schlüssel und Includes mit vorhandenen Indizes.

**Warum problematisch:** Der Optimizer schätzt, dass relevante Queries ohne geeigneten Zugriff mehr Kosten verursachen. Die DMV kennt aber Schreibkosten, Speicher, Duplikate und betriebliche Abhängigkeiten nur unzureichend.

**Wann nicht problematisch:** 98 % Impact bei zwei Reads ist plakativ, aber schwache Evidenz. Ein bereits vorhandener ähnlicher Index kann den Vorschlag überflüssig machen.

**Beispiel:** 25 % Impact bei fünf Millionen Reads kann mehr Gesamtnutzen haben als 99 % bei einer einzigen Ausführung.

**Nächster Schritt:** Prüfen Sie vorhandene Indizes, Querytext, Plan, Usage und Write-Last. Entwerfen Sie DDL erst nach dieser Prüfung. [Detailbeschreibung](03_Object_Index.md#4-monitorusp_missingindexes)

## [monitor].[USP_Statistics]

**Auswertung:** Berücksichtigen Sie Rows, Rows Sampled, Modification Counter, führende Spalte, Filter und letzten Updatezeitpunkt gemeinsam.

**Warum problematisch:** Stark geänderte oder unpassend gesampelte Statistiken können falsche Kardinalitätsschätzungen und damit schlechte Join-, Grant- oder Zugriffspfade verursachen.

**Wann nicht problematisch:** Eine alte Statistik kann weiterhin korrekt sein, wenn sich relevante Daten kaum geändert haben. Ein niedriger Sample-Prozentsatz kann bei sehr großen Tabellen ausreichend sein.

**Beispiel:** Zehn Jahre alt + Modification Counter 0 ist nicht automatisch schlecht. Eine gestern aktualisierte Statistik kann trotzdem einen neu entstandenen stark verzerrten Tail schlecht abbilden.

**Nächster Schritt:** Prüfen Sie Histogramm-/Verteilungsanalyse und betroffene Pläne. [Detailbeschreibung](03_Object_Index.md#5-monitorusp_statistics)

## [monitor].[USP_StatisticsDistributionAnalysis]

**Auswertung:** Prüfen Sie zuerst Sample und Modification und danach Dominant Step, Skew, Tail und Partitionsspread. Bewerten Sie die Findings erst im Anschluss.

**Warum problematisch:** Starke Verteilungsspitzen oder neue Tailwerte können dazu führen, dass ein für einen Parameter guter Plan für einen anderen Parameter ungeeignet ist.

**Wann nicht problematisch:** Skew kann die reale Verteilung korrekt beschreiben und bei passenden Plänen völlig unkritisch sein.

**Beispiel:** Ein Wert umfasst 70 % der Zeilen. Das ist erst dann problematisch, wenn seltene und häufige Parameter denselben gecachten Plan verwenden und stark unterschiedliche Zeilenmengen erzeugen.

**Nächster Schritt:** Vergleichen Sie Query Store Plan Changes, Parameterwerte und Showplan. [Detailbeschreibung](03_Object_Index.md#6-monitorusp_statisticsdistributionanalysis)

## [monitor].[USP_Partitions]

**Auswertung:** Vergleichen Sie RowCount und Größe je Partition, Grenzintervalle, Filegroup, Kompression und Indexausrichtung.

**Warum problematisch:** Stark unausgewogene Partitionen können Wartung, Statistiken und Lastverteilung erschweren. Falsche Grenzen oder nicht ausgerichtete Indizes können Partition Switching und Elimination verhindern.

**Wann nicht problematisch:** Leere Randpartitionen und ungleiche Größen sind bei Sliding-Window- oder Hot-/Cold-Design oft beabsichtigt.

**Beispiel:** Eine leere zukünftige Monatspartition ist normal. Eine einzelne aktuelle Partition mit 95 % aller Zeilen und ohne passende Prädikate kann dagegen den erwarteten Partitionierungsvorteil verhindern.

**Nächster Schritt:** Prüfen Sie Showplan auf Partition Elimination, Statistikdetails und Kapazität. [Detailbeschreibung](03_Object_Index.md#7-monitorusp_partitions)

## [monitor].[USP_Columnstore]

**Auswertung:** Vergleichen Sie Rowgroupzustand, Total, Deleted und Active Rows, Fullness, Trim Reason sowie Alter. Vertiefen Sie Segmente und Dictionaries nur bei konkretem Bedarf.

**Warum problematisch:** Viele kleine komprimierte Rowgroups oder hohe Deleted-Rows-Anteile verschlechtern Kompression, Segment Elimination und Scan-Effizienz.

**Wann nicht problematisch:** Offene Delta Stores während laufender Last und Deleted Rows in wenig gelesenen alten Partitionen können tolerierbar sein.

**Beispiel:** 40 % Deleted Rows in einer häufig gescannten großen Rowgroup ist relevanter als 40 % in einer winzigen Archivpartition. Die gleiche Prozentzahl hat unterschiedliche Auswirkung.

**Nächster Schritt:** Prüfen Sie Ladebatchgröße, Tuple Mover, Partitionierung und Querypläne. [Detailbeschreibung](03_Object_Index.md#8-monitorusp_columnstore)

## [monitor].[USP_IndexPhysicalStats]

**Auswertung:** Bewerten Sie `PageCount` immer vor `AvgFragmentationPercent`. Berücksichtigen Sie danach Seitendichte, Scanmodus sowie Record-, Ghost- und Forwarded-Werte.

**Warum problematisch:** Große fragmentierte Strukturen können Range Scans und Read-Ahead beeinträchtigen; niedrige Seitendichte erhöht Speicher- und I/O-Bedarf.

**Wann nicht problematisch:** 99 % Fragmentierung bei acht Seiten ist praktisch irrelevant. Hohe Fragmentierung kann bei überwiegend punktuellen Seeks weniger bedeutsam sein.

**Beispiel:** Fünf Millionen Seiten, 45 % Fragmentierung und 55 % Dichte sind relevant, weil sehr viele zusätzliche Seiten gelesen und gecacht werden können. Acht Seiten mit denselben Prozentwerten sind es nicht.

**Nächster Schritt:** Prüfen Sie Usage, Workload, Wartungsfenster und Dichtewirkung. [Detailbeschreibung](03_Object_Index.md#9-monitorusp_indexphysicalstats)

## [monitor].[USP_SchemaDesignAnalysis]

**Auswertung:** Berücksichtigen Sie FindingCode, Severity, betroffenes Objekt, verwandtes Objekt, Metrik und EvidenceLimit gemeinsam.

**Warum problematisch:** Nicht vertrauenswürdige Constraints, fehlende FK-Unterstützung oder fast erschöpfte Identitybereiche können Optimierung, DML und Verfügbarkeit beeinträchtigen.

**Wann nicht problematisch:** Disabled oder doppelt wirkende Objekte können Teil eines Lade-, Deployment- oder Constraintdesigns sein.

**Beispiel:** FK ohne passenden Index ist besonders relevant, wenn Parent-Deletes/Updates blockieren oder große Childscans auslösen. Bei statischen Tabellen ohne solche Operationen kann die Priorität niedriger sein.

**Nächster Schritt:** Prüfen Sie Objektinventar, Usage, Pläne und Änderungsrisiko. [Detailbeschreibung](03_Object_Index.md#11-monitorusp_schemadesignanalysis)

## [monitor].[USP_ObjectAnalysis]

**Auswertung:** Prüfen Sie zuerst den Childstatus und gehen Sie dann vom Inventar über die Nutzung zur spezifischen Tiefenanalyse über. Ein Child-Resultset ersetzt die übrigen Resultsets nicht.

**Warum problematisch:** Ein Missing-Index-Vorschlag ohne Inventar und Usage kann zu redundanten Indizes führen; Fragmentierung ohne Page Count kann unnötige Wartung auslösen.

**Wann nicht problematisch:** Nicht aktivierte Deep-Module fehlen absichtlich und sind keine partielle Ausführung.

**Beispiel:** Inventar zeigt ähnlichen Index, Missing Index schlägt neuen vor, Usage zeigt bestehende geringe Nutzung. Die Kombination spricht eher für Konsolidierung als für blindes Erstellen.

**Nächster Schritt:** Führen Sie das relevante Child gezielt mit einem engeren Scope erneut aus. [Detailbeschreibung](03_Object_Index.md#12-monitorusp_objectanalysis)

# 6. Plan Cache und Showplan

## [monitor].[USP_QueryStats]

**Auswertung:** Prüfen Sie zuerst Cachefenster (`CreationTime`, `LastExecutionTime`) und Execution Count. Betrachten Sie danach Total-, Average-, Maximal- und Letztwerte getrennt.

**Warum problematisch:** Hohe Totalwerte zeigen Gesamtauswirkung, hohe Maxwerte Ausreißer, hohe Durchschnittswerte systematische Kosten. Reads bei wenigen Ergebniszeilen weisen auf ineffizienten Zugriff hin.

**Wann nicht problematisch:** Eine einmalige schwere administrative Query kann hohe Maxwerte haben, aber geringe Gesamtauswirkung.

**Beispiel:** Eine Million Ausführungen zu je 2 ms verursachen mehr Gesamtkosten als eine einmalige 10-Minuten-Query. Berücksichtigen Sie deshalb Total und Average gemeinsam.

**Nächster Schritt:** Prüfen Sie Query Hash, Plan Details, Showplan oder Query Store. [Detailbeschreibung](04_Plan_Cache.md#1-monitorusp_querystats)

## [monitor].[USP_QueryHashAnalysis]

**Auswertung:** Vergleichen Sie `PlanVariantCount`, `PlanHandleCount`, Ausführungen und Ressourcen je Variante.

**Warum problematisch:** Viele Planvarianten können instabile Performance, Parameter Sensitivity oder unterschiedliche Compilekontexte erzeugen. Viele Handles bei gleichem Plan Hash können Cachebloat anzeigen.

**Wann nicht problematisch:** Mehrere Varianten können durch legitime SET Options, Datenbankkontexte oder bewusstes Recompile entstehen.

**Beispiel:** Acht Planvarianten, aber eine verbraucht 99 % der CPU. Nicht die Anzahl allein, sondern die dominante schlechte Variante ist relevant.

**Nächster Schritt:** Vergleichen Sie einzelne Handles über `USP_PlanDetails` und Historie über Query Store. [Detailbeschreibung](04_Plan_Cache.md#2-monitorusp_queryhashanalysis)

## [monitor].[USP_PlanCacheHealth]

**Auswertung:** Berücksichtigen Sie Gesamtgröße, Plananzahl, Single-Use-Anteil, Use Counts und Memory Pressure gemeinsam.

**Warum problematisch:** Viele große Single-Use-Pläne verbrauchen Cache für Texte, die kaum wiederverwendet werden, und verdrängen möglicherweise nützlichere Pläne oder Datenseiten.

**Wann nicht problematisch:** Hoher Single-Use-Anteil ohne Speicherdruck kann technische Schuld, aber kein akuter Engpass sein.

**Beispiel:** 70 % Single-Use bei reichlich freiem Speicher ist weniger dringend als 20 % Single-Use auf einem Server mit starkem Memory Pressure.

**Nächster Schritt:** Prüfen Sie Textvarianz, Parametrisierung, `optimize for ad hoc workloads` und Memoryanalyse. [Detailbeschreibung](04_Plan_Cache.md#3-monitorusp_plancachehealth)

## [monitor].[USP_PlanDetails]

**Auswertung:** Prüfen Sie zuerst die Kandidatenidentität und danach die Planattribute. Unterscheiden Sie anschließend zwischen den verfügbaren Planquellen Compile, Last Actual und Live.

**Warum problematisch:** Abweichende Cache-Key-Attribute können mehrere Planhandles erzeugen; Actual-Pläne können Schätzfehler, Spills und reale Zeilenmengen zeigen.

**Wann nicht problematisch:** Compile-Pläne enthalten nur Schätzungen. Das Fehlen von Actualwerten ist daher kein Fehler der Query.

**Beispiel:** Zwei identische Texte mit unterschiedlichem `set_options` können getrennte Cacheeinträge haben. Das ist eine Erklärung für mehrere Handles, nicht automatisch Planinstabilität.

**Nächster Schritt:** Verwenden Sie `USP_ShowplanAnalysis` oder führen Sie einen manuellen Planvergleich durch. [Detailbeschreibung](04_Plan_Cache.md#4-monitorusp_plandetails)

## [monitor].[USP_ShowplanAnalysis]

**Auswertung:** Prüfen Sie die Angaben in der Reihenfolge Statementebene → Warnungen → Operatoren → Estimate/Actual → Memory → Parameter. Bewerten Sie absolute Zeilenmengen vor den Ratios.

**Warum problematisch:** Große Estimate-/Actual-Abweichungen können falsche Joinarten, Grants und Zugriffspfade erzeugen. Spills zeigen, dass Arbeit nach TempDB ausgelagert wurde.

**Wann nicht problematisch:** Ratio 10 bei Estimate 1 und Actual 10 ist meist weniger wichtig als Ratio 10 bei 100 Mio. tatsächlichen Zeilen.

**Beispiel:** Estimate 1, Actual 10 Mio. erklärt, warum ein Nested Loops Plan oder kleiner Grant kollabieren kann. Estimate 1, Actual 10 hat dieselbe Ratio, aber viel geringere Auswirkung.

**Nächster Schritt:** Prüfen Sie Statistik, Parameter, Query Store, Index- und Memorykontext. [Detailbeschreibung](04_Plan_Cache.md#5-monitorusp_showplananalysis)

## [monitor].[USP_PlanCacheAnalysis]

**Auswertung:** Beachten Sie Modulstatus und Reihenfolge. Query Stats priorisiert Kandidaten, Query Hash erklärt Varianten, Health beschreibt den Cache und Showplan den Planinhalt.

**Warum problematisch:** Ein breiter Showplanlauf kann selbst hohe CPU verursachen und liefert viele Befunde ohne Priorisierung.

**Wann nicht problematisch:** Nicht aktivierte Children sind normal; der Default ist absichtlich leichtgewichtig.

**Beispiel:** Identifizieren Sie zuerst die Queries mit der höchsten CPU-Nutzung und parsen Sie danach nur die fünf relevanten Pläne. Dieses Vorgehen liefert fokussiertere Evidenz und verursacht geringere Analysekosten als eine Analyse des gesamten Cache.

**Nächster Schritt:** Führen Sie eine fokussierte Childanalyse aus oder verwenden Sie Query Store für die historische Analyse. [Detailbeschreibung](04_Plan_Cache.md#6-monitorusp_plancacheanalysis)

# 7. Query Store

## [monitor].[USP_QueryStoreStatus]

**Auswertung:** Prüfen Sie `ActualStateDesc`, Readonly Reason, Storage Used, Capture Mode, Cleanup, Interval Length und Wait Capture.

**Warum problematisch:** Read-only, voller Speicher oder Capture Mode können Historienlücken erzeugen. Dann ist ein fehlender Queryeintrag keine Entwarnung.

**Wann nicht problematisch:** Capture Mode AUTO lässt billige oder seltene Queries absichtlich weg.

**Beispiel:** Wait-Resultset leer + Wait Capture OFF ist erwartbar. Leer + Capture ON + passendes Zeitfenster verlangt weitere Prüfung.

**Nächster Schritt:** Starten Sie erst bei geeignetem Status Runtime-, Wait- oder Plananalysen. [Detailbeschreibung](05_Query_Store.md#1-monitorusp_querystorestatus)

## [monitor].[USP_QueryStoreRuntimeStats]

**Auswertung:** Vergleichen Sie Zeitfenster und Intervalllänge, Execution Count, Total und Average je Ressource sowie PlanId.

**Warum problematisch:** Mehrere Pläne derselben Query mit stark unterschiedlichen Werten können Regression oder Parameter Sensitivity anzeigen.

**Wann nicht problematisch:** Hohe Total-CPU bei sehr vielen Ausführungen kann eine kleine, aber häufige Query sein; hohe Average-Dauer bei einer Ausführung ist schwache Evidenz.

**Beispiel:** Plan A 10 ms × 100.000, Plan B 500 ms × 20. Plan B ist pro Aufruf schlechter, Plan A verursacht möglicherweise mehr Gesamtlast.

**Nächster Schritt:** Prüfen Sie Wait Stats, Plan Changes, Regressions und Showplan. [Detailbeschreibung](05_Query_Store.md#2-monitorusp_querystoreruntimestats)

## [monitor].[USP_QueryStoreWaitStats]

**Auswertung:** Berücksichtigen Sie Waitkategorie, Totalzeit, Maximalwert, Recorded Rows und Zeitintervalle gemeinsam.

**Warum problematisch:** Hohe Totalzeit zeigt kumulative Auswirkung; hoher Maxwert kann einzelne Ausreißer anzeigen. Kategorien sind gröber als Live-Waittypen.

**Wann nicht problematisch:** Viele Recorded Rows sind nur viele Messintervalle, nicht automatisch viele Ausführungen.

**Beispiel:** Lock-Wait dominiert ein einzelnes Intervall, danach nicht mehr: möglicher Burst. Lock-Wait dominiert täglich über Stunden: systematisches Problem.

**Nächster Schritt:** Prüfen Sie Runtimewerte, Planwechsel und bei Reproduktion Live-Blocking. [Detailbeschreibung](05_Query_Store.md#3-monitorusp_querystorewaitstats)

## [monitor].[USP_QueryStorePlanChanges]

**Auswertung:** Vergleichen Sie PlanCount, Distinct Plan Hashes, Compile- und Executionzeiten sowie Forced-Status.

**Warum problematisch:** Ein neuer Plan kann andere Kosten, Parallelität oder Zugriffspfade haben und zeitlich mit einer Regression zusammenfallen.

**Wann nicht problematisch:** Mehrere Planzeilen mit demselben Plan Hash oder alte nie mehr verwendete Pläne sind nicht automatisch relevant.

**Beispiel:** Vier PlanIds, aber nur zwei Plan Hashes; einer wurde seit Monaten nicht ausgeführt. Für die aktuelle Ursache sind die aktiven Varianten entscheidend.

**Nächster Schritt:** Prüfen Sie Runtime Stats je Plan, Regressionen und Planvergleich. [Detailbeschreibung](05_Query_Store.md#4-monitorusp_querystoreplanchanges)

## [monitor].[USP_QueryStoreRegressions]

**Auswertung:** Berücksichtigen Sie Baseline- und Vergleichsfenster, Ausführungsanzahl, absolute Werte und Prozentänderung gemeinsam.

**Warum problematisch:** Eine belastbare Regression bedeutet, dass vergleichbare Workload im neuen Fenster deutlich mehr Ressourcen oder Zeit benötigt.

**Wann nicht problematisch:** 900 % bei je einer Ausführung ist statistisch schwach; veränderte Parameter oder Datenmenge können die Ursache sein.

**Beispiel:** 100 ms → 150 ms bei je 100.000 Ausführungen ist eine belastbare 50-%-Regression. 1 ms → 10 ms bei je einer Ausführung noch nicht.

**Nächster Schritt:** Prüfen Sie Plan Changes, Wait Stats und konkrete Parameter-/Plananalyse. [Detailbeschreibung](05_Query_Store.md#5-monitorusp_querystoreregressions)

## [monitor].[USP_QueryStoreForcedPlans]

**Auswertung:** Berücksichtigen Sie IsForced, Forcing Type, Failure Count, Failure Reason, letzte Ausführung sowie Engine- und Compatibility-Kontext.

**Warum problematisch:** Force-Fehler bedeuten, dass die gewünschte Planbindung nicht zuverlässig angewendet wird. Ein alter Forced Plan kann neue Optimizerverbesserungen verhindern.

**Wann nicht problematisch:** Ein fehlerfrei erzwungener Plan mit stabiler guter Performance kann eine bewusste Schutzmaßnahme sein.

**Beispiel:** 50 Force-Fehler und aktuelle Regression sind dringender als ein seit Monaten stabiler Forced Plan ohne Fehler.

**Nächster Schritt:** Prüfen Sie Plan Changes, Runtimevergleich und Rücknahmepfad. [Detailbeschreibung](05_Query_Store.md#6-monitorusp_querystoreforcedplans)

## [monitor].[USP_QueryStoreHints]

**Auswertung:** Berücksichtigen Sie Hinttext, Quelle, Failure Count, Failure Reason und betroffene Query gemeinsam.

**Warum problematisch:** Ein Hint kann die Optimizerfreiheit begrenzen und nach Daten-, Schema- oder Versionsänderungen schädlich werden.

**Wann nicht problematisch:** Ein dokumentierter, getesteter Hint kann eine gezielte temporäre oder dauerhafte Maßnahme sein.

**Beispiel:** Fehlerfreier Hint heißt nur, dass er angewendet wird – nicht, dass er weiterhin nützlich ist.

**Nächster Schritt:** Prüfen Sie Runtime, Regression, Plan Changes und Change-Governance. [Detailbeschreibung](05_Query_Store.md#7-monitorusp_querystorehints)

## [monitor].[USP_IntelligentQueryProcessingAnalysis]

**Auswertung:** Trennen Sie Eligibility, Database-scoped Configurations, Query-Store-Zustand und Evidenzcounts voneinander.

**Warum problematisch:** Ein Feature kann versionsseitig geeignet, aber deaktiviert sein; Query Store OFF kann persistentes Feedback begrenzen.

**Wann nicht problematisch:** `EvidenceCount=0` beweist weder Erfolg noch Misserfolg. Möglicherweise gab es keine geeignete Query oder die Quelle speichert nichts.

**Beispiel:** PSP eligible, aber keine Query Variants. Das ist kein Fehler; erst eine bekannte parameter-sensitive Query liefert eine sinnvolle Gegenprobe.

**Nächster Schritt:** Prüfen Sie Query Store, konkrete Query und Showplan. [Detailbeschreibung](05_Query_Store.md#8-monitorusp_intelligentqueryprocessinganalysis)

## [monitor].[USP_QueryStoreAnalysis]

**Auswertung:** Prüfen Sie zuerst das Status-Child und danach nur die für die Fragestellung aktivierten Children. Beachten Sie Zeitfenster und Wrappersemantik.

**Warum problematisch:** Regressionen können falsch interpretiert werden, wenn das übergebene Fenster als Baseline statt Vergleich verstanden wird.

**Wann nicht problematisch:** Fehlende Childresultsets sind normal, wenn die Schalter deaktiviert sind.

**Beispiel:** Wrapper bekommt letzte Stunde; diese ist das Vergleichsfenster, die Baseline liegt unmittelbar davor.

**Nächster Schritt:** Wiederholen Sie das relevante Child mit QueryId beziehungsweise Query Hash und einem engen Zeitraum. [Detailbeschreibung](05_Query_Store.md#9-monitorusp_querystoreanalysis)

# 8. Extended Events

## [monitor].[USP_ExtendedEventsSessions]

**Auswertung:** Prüfen Sie Sessiondefinition, Laufzeitstatus, Events, Actions, Targets und Felder getrennt.

**Warum problematisch:** Eine definierte, aber nicht laufende Session sammelt keine Daten. Ein Event ohne erforderliche Actions kann später wichtige Korrelationsinformationen vermissen lassen.

**Wann nicht problematisch:** Eine bewusst nur bei Bedarf gestartete Session darf gestoppt sein.

**Beispiel:** Deadlockevent ist konfiguriert, aber kein Event-File-Target vorhanden und Ringbuffer klein. Historische Tiefe kann dadurch fehlen.

**Nächster Schritt:** Lesen Sie Target Runtime und tatsächliche Events. [Detailbeschreibung](06_Extended_Events.md#1-monitorusp_extendedeventssessions)

## [monitor].[USP_ExtendedEventsReadEvents]

**Auswertung:** Prüfen Sie Quelle, Zeitfenster, Eventname, Dateireihenfolge und XML- beziehungsweise Payloadverfügbarkeit.

**Warum problematisch:** Fehlende Events können durch Rollover, Retention, falschen Pfad oder nicht aktive Session entstehen – nicht nur dadurch, dass das Ereignis nie auftrat.

**Wann nicht problematisch:** Ein leeres enges Zeitfenster bei laufender Session kann tatsächlich bedeuten, dass kein passendes Ereignis auftrat.

**Beispiel:** Keine Events im Ringbuffer nach Restart sagt nichts über die Zeit davor. Eventdateien können dagegen ältere Historie enthalten.

**Nächster Schritt:** Prüfen Sie Session-/Targetstatus und externe Datei-Retention. [Detailbeschreibung](06_Extended_Events.md#2-monitorusp_extendedeventsreadevents)

## [monitor].[USP_ExtendedEventsDeadlocks]

**Auswertung:** Berücksichtigen Sie Opfer, Prozesse, Ressourcen und Kanten des Deadlockgraphs gemeinsam. Betrachten Sie nicht nur die Opferquery.

**Warum problematisch:** Ein Deadlock ist zyklisches Warten; mindestens eine Transaktion muss abgebrochen werden. Wiederholung verursacht Fehler, Rollbacks und Durchsatzverlust.

**Wann nicht problematisch:** Ein einmaliges Ereignis nach seltenem Deployment kann geringere Priorität haben als ein minütlich wiederkehrendes Muster.

**Beispiel:** Zwei Sessions sperren dieselben Tabellen in umgekehrter Reihenfolge. Die Lösung liegt häufig in konsistenter Zugriffsreihenfolge, nicht im Opferprozess.

**Nächster Schritt:** Prüfen Sie beteiligte Statements, Indizes, Isolation und Transaktionsreihenfolge. [Detailbeschreibung](06_Extended_Events.md#3-monitorusp_extendedeventsdeadlocks)

## [monitor].[USP_ExtendedEventsBlockedProcesses]

**Auswertung:** Vergleichen Sie Blockeddauer, Blocker- und Blocked-Statements, Ressource und zeitliche Wiederholungen.

**Warum problematisch:** Wiederholte Reports derselben Kette zeigen persistierendes Blocking und nicht nur einen kurzen Snapshot.

**Wann nicht problematisch:** Ein einzelner Report knapp über dem konfigurierten Threshold kann ein einmaliger langsamer Vorgang sein.

**Beispiel:** Alle fünf Sekunden derselbe Root Blocker über zwei Minuten ist starke Evidenz; ein einzelner Report ohne Wiederholung deutlich schwächer.

**Nächster Schritt:** Korrelieren Sie Live mit Current Blocking/Transactions. [Detailbeschreibung](06_Extended_Events.md#4-monitorusp_extendedeventsblockedprocesses)

## [monitor].[USP_ExtendedEventsTargetRuntime]

**Auswertung:** Prüfen Sie Targettyp, Laufzeitstatus, Dateipfad, Speicher- und Eventanzahl, Dropped Events sowie optional die Targetdaten.

**Warum problematisch:** Dropped Events oder volles/kleines Target bedeuten Evidenzverlust. Ein Flush kann I/O und Zielzustand beeinflussen und ist deshalb opt-in.

**Wann nicht problematisch:** Ein kleiner Ringbuffer ist für kurzfristige Ad-hoc-Diagnose geeignet, aber nicht für lange Historie.

**Beispiel:** Session läuft, aber Target zeigt viele verlorene Events. Ein leeres Detailresultset kann dann nicht als „kein Problem“ interpretiert werden.

**Nächster Schritt:** Prüfen Sie Targetgröße, Eventrate und Event-File-Strategie. [Detailbeschreibung](06_Extended_Events.md#5-monitorusp_extendedeventstargetruntime)

## [monitor].[USP_ExtendedEventsAnalysis]

**Auswertung:** Prüfen Sie zuerst Inventar und Targetstatus und danach den Ereignis- oder Spezialparser. Beachten Sie dabei den Childstatus.

**Warum problematisch:** Deadlock-/Blockinganalyse ohne verlässliche Quelle kann falsche Entwarnung liefern.

**Wann nicht problematisch:** Standardmäßig deaktivierte Event-/Deadlock-Children fehlen absichtlich.

**Beispiel:** Inventar zeigt Session gestoppt; Deadlockresultset leer. Die korrekte Schlussfolgerung ist „keine Evidenz erfasst“, nicht „keine Deadlocks“.

**Nächster Schritt:** Korrigieren Sie Session oder Target oder lesen Sie vorhandene Eventdateien gezielt. [Detailbeschreibung](06_Extended_Events.md#6-monitorusp_extendedeventsanalysis)

# 9. Infrastruktur

## [monitor].[USP_AgentStatus]

**Auswertung:** Unterscheiden Sie Plattformunterstützung, Dienststatus, Startmodus und Agentkonfiguration.

**Warum problematisch:** Gestoppter Agent verhindert geplante Jobs, Backups, Wartung und Alerts.

**Wann nicht problematisch:** Auf Plattformen ohne klassischen SQL Agent ist Nichtverfügbarkeit erwartbar.

**Beispiel:** Agent gestoppt auf einer Instanz mit geplanten Logbackups ist kritisch; auf einer bewusst agentlosen Plattform nicht.

**Nächster Schritt:** Prüfen Sie Jobs und alternative Scheduler. [Detailbeschreibung](07_Infrastructure.md#1-monitorusp_agentstatus)

## [monitor].[USP_AgentJobs]

**Auswertung:** Berücksichtigen Sie Enabled, aktuellen Laufstatus, letzten Outcome, Dauer, nächste Ausführung und Schrittfehler gemeinsam.

**Warum problematisch:** Wiederholte Fehler oder deutlich längere Laufzeiten können Backups, ETL und Wartungsfenster gefährden.

**Wann nicht problematisch:** Ein langer Job kann für Full Backup oder große Wartung normal sein, wenn er innerhalb seines Fensters bleibt.

**Beispiel:** Job läuft 90 Minuten, historischer Normalwert 20 Minuten und blockiert Folgeschritte: echte Abweichung. Ein monatlicher Full Backup mit 90 Minuten Normalwert nicht.

**Nächster Schritt:** Prüfen Sie Schrittoutput, Blocking, I/O und Historie. [Detailbeschreibung](07_Infrastructure.md#2-monitorusp_agentjobs)

## [monitor].[USP_ResourceGovernorAnalysis]

**Auswertung:** Vergleichen Sie Poollimits, Workload-Group-Limits, aktuelle Nutzung und zugeordnete Sessions.

**Warum problematisch:** CPU-, Memory- oder Parallelitätslimits können Requests absichtlich drosseln oder Grants begrenzen.

**Wann nicht problematisch:** Drosselung kann genau das gewünschte Schutzverhalten sein.

**Beispiel:** Query ist langsam, aber ihrer Gruppe ist nur 20 % CPU zugewiesen. Das ist nicht zwingend ein schlechter Plan, sondern möglicherweise Policywirkung.

**Nächster Schritt:** Prüfen Sie Sessionzuordnung, Classifier und SLA. [Detailbeschreibung](07_Infrastructure.md#3-monitorusp_resourcegovernoranalysis)

## [monitor].[USP_AvailabilityGroups]

**Auswertung:** Berücksichtigen Sie Replica-Rolle, Connected State, Synchronization State, Health, Failover Mode, Availability Mode und Routing gemeinsam.

**Warum problematisch:** Disconnected oder not synchronizing kann Datenverlust- oder Failoverrisiko erhöhen; fehlerhaftes Routing kann Read-Only-Workload falsch lenken.

**Wann nicht problematisch:** Asynchrone Replicas dürfen Lag haben; entscheidend sind RPO und Trend.

**Beispiel:** `ASYNCHRONOUS_COMMIT` mit 30 Sekunden Lag kann policykonform sein. Derselbe Lag bei synchroner HA-Replica vor geplantem Failover ist kritisch.

**Nächster Schritt:** Prüfen Sie `USP_AvailabilityDeepAnalysis`. [Detailbeschreibung](07_Infrastructure.md#4-monitorusp_availabilitygroups)

## [monitor].[USP_BackupRecovery]

**Auswertung:** Berücksichtigen Sie Recovery Model, Alter der Full-, Differential- und Log-Sicherungen, letzte erfolgreiche Sicherung, Copy-only und Restorehistorie gemeinsam.

**Warum problematisch:** Fehlende oder alte Logbackups vergrößern möglichen Datenverlust und können Log-Wiederverwendung verhindern.

**Wann nicht problematisch:** In SIMPLE Recovery sind Logbackups nicht vorgesehen; eine fehlende Differential-Sicherung kann durch Strategie gedeckt sein.

**Beispiel:** FULL Recovery + letztes Logbackup vor sechs Stunden bei 30-Minuten-RPO ist kritisch. SIMPLE Recovery + kein Logbackup ist erwartbar.

**Nächster Schritt:** Prüfen Sie Backup Chain und realen Restore-Test. [Detailbeschreibung](07_Infrastructure.md#5-monitorusp_backuprecovery)

## [monitor].[USP_LogShippingStatus]

**Auswertung:** Vergleichen Sie Backup-, Copy- und Restorezeit, Schwellenstatus, Sekundärmodus und Metadatenverfügbarkeit.

**Warum problematisch:** Wachsende Differenz zwischen Backup, Copy und Restore zeigt, an welcher Stufe die Pipeline zurückfällt.

**Wann nicht problematisch:** Geplanter Restore Delay erzeugt absichtlich Verzögerung.

**Beispiel:** Backups aktuell, Copy 90 Minuten zurück, Restore ebenfalls zurück: Transportpfad ist wahrscheinlicher als Backupjob.

**Nächster Schritt:** Prüfen Sie Jobhistorie, Netzwerk, Share und Sekundärstatus. [Detailbeschreibung](07_Infrastructure.md#6-monitorusp_logshippingstatus)

## [monitor].[USP_ReplicationStatus]

**Auswertung:** Berücksichtigen Sie Publikation, Subscription, Agentstatus, letzte Aktion, Latenz, Pending Commands und Fehler gemeinsam.

**Warum problematisch:** Wachsender Backlog bedeutet, dass Änderungen schneller entstehen als verteilt werden oder ein Agent blockiert ist.

**Wann nicht problematisch:** Kurzzeitiger Backlog während Lastspitzen kann sich selbst abbauen.

**Beispiel:** Pending Commands steigen in drei Messungen kontinuierlich und Latenz wächst: systematischer Rückstand. Ein einmaliger Peak mit anschließendem Abbau nicht.

**Nächster Schritt:** Prüfen Sie Agentjob, Distributor, Blocking und Netzwerk. [Detailbeschreibung](07_Infrastructure.md#7-monitorusp_replicationstatus)

## [monitor].[USP_DataCaptureStatus]

**Auswertung:** Unterscheiden Sie Featureaktivierung, Status der Capture- und Cleanup-Jobs, Retention und Datenbankzustand.

**Warum problematisch:** Aktiviertes CDC ohne laufenden Capturejob erzeugt wachsenden Log- und Datenrückstand; Cleanupfehler vergrößern Tabellen.

**Wann nicht problematisch:** Deaktiviertes CDC/Change Tracking auf einer Datenbank, die es nicht benötigt, ist normal.

**Beispiel:** CDC enabled + Capturejob disabled ist ein konkreter Fehlerzustand. CDC disabled allein nicht.

**Nächster Schritt:** Prüfen Sie Agentjobs, Logstatus und Featurekonfiguration. [Detailbeschreibung](07_Infrastructure.md#8-monitorusp_datacapturestatus)

## [monitor].[USP_InfrastructureAnalysis]

**Auswertung:** Prüfen Sie zuerst den Childstatus und danach nur die relevanten Infrastrukturmodule. Unterscheiden Sie Verfügbarkeit und Featureeinsatz.

**Warum problematisch:** Ein leeres Child kann durch nicht verwendetes Feature oder durch fehlende Rechte entstehen; beide Fälle sind fachlich verschieden.

**Wann nicht problematisch:** Keine AG-Zeilen auf einer Standalone-Instanz sind erwartbar.

**Beispiel:** Backupchild meldet partiell, AG-Child unavailable feature. Nur der Backupbereich braucht Nacharbeit.

**Nächster Schritt:** Rufen Sie auffälliges Child gezielt auf. [Detailbeschreibung](07_Infrastructure.md#12-monitorusp_infrastructureanalysis)

## [monitor].[USP_BackupChainAnalysis]

**Auswertung:** Berücksichtigen Sie Full-Basis, Differential Base, Log-LSN-Folge, Gap-Status und Restoreevidenz in zeitlicher Reihenfolge.

**Warum problematisch:** Eine unterbrochene LSN-Kette kann Point-in-Time-Restore verhindern. Vorhandene Dateien allein garantieren keine wiederherstellbare Kette.

**Wann nicht problematisch:** Copy-only Full verändert die Differential Base nicht und darf nicht falsch als Kettenbruch interpretiert werden.

**Beispiel:** Full vorhanden, viele Logbackups, aber ein fehlendes LSN-Segment: Restore bis zum Ende ist nicht möglich.

**Nächster Schritt:** Prüfen Sie die Backupmedien und führen Sie einen tatsächlichen Restore-Test durch. [Detailbeschreibung](07_Infrastructure.md#9-monitorusp_backupchainanalysis)

## [monitor].[USP_AvailabilityDeepAnalysis]

**Auswertung:** Berücksichtigen Sie Send Queue, Redo Queue, geschätzte Lagzeit, Synchronisierungszustand und Replica-Rolle gemeinsam. Der Trend ist aussagekräftiger als ein Einzelwert.

**Warum problematisch:** Wachsende Send Queue bedeutet Transport-/Primärproblem; wachsende Redo Queue bedeutet Sekundär-Redo kann nicht folgen.

**Wann nicht problematisch:** Kurzer Queue-Peak nach großer Transaktion kann sich erwartbar abbauen.

**Beispiel:** Send Queue stabil klein, Redo Queue wächst über mehrere Messungen: Fokus auf Sekundär-I/O/CPU/Redo, nicht Netzwerk.

**Nächster Schritt:** Prüfen Sie Performance Counter, Storage, Netzwerk und Cluster. [Detailbeschreibung](07_Infrastructure.md#10-monitorusp_availabilitydeepanalysis)

## [monitor].[USP_AgentMonitoringAnalysis]

**Auswertung:** Betrachten Sie Jobprobleme, Alert- und Operator-Konfiguration sowie Database-Mail-Verfügbarkeit getrennt.

**Warum problematisch:** Ein Fehler kann auftreten, aber unbemerkt bleiben, wenn Alert, Operator oder Mailpfad fehlt.

**Wann nicht problematisch:** Nicht jede Umgebung verwendet Database Mail; dann muss ein alternativer Alarmweg existieren.

**Beispiel:** Kritischer Job schlägt wiederholt fehl, aber kein aktiver Operator ist erreichbar. Das Betriebsrisiko ist höher als der Jobfehler allein.

**Nächster Schritt:** Prüfen Sie Agent Jobs, Mailstatus und Monitoringprozess. [Detailbeschreibung](07_Infrastructure.md#11-monitorusp_agentmonitoringanalysis)

# 10. Server Health

## [monitor].[USP_ServerCpuTopology]

**Auswertung:** Vergleichen Sie logische CPUs, Sockets, Cores, Scheduler, Soft-NUMA und sichtbare CPUs.

**Warum problematisch:** Unerwartet offline/hidden Scheduler oder ungewöhnliche Topologie kann Parallelität, Lizenzierung und Lastverteilung beeinflussen.

**Wann nicht problematisch:** Soft-NUMA und bestimmte Schedulerzustände können vom SQL Server absichtlich erzeugt sein.

**Beispiel:** Wenn von 64 OS-CPUs nur 32 online sichtbar sind, müssen Lizenz-, Affinity- und Editionskontext geprüft werden. Ein Hardwarefehler darf daraus nicht unmittelbar abgeleitet werden.

**Nächster Schritt:** Prüfen Sie NUMA, Konfiguration und Betriebssystem. [Detailbeschreibung](08_Server_Health.md#1-monitorusp_servercputopology)

## [monitor].[USP_ServerNuma]

**Auswertung:** Vergleichen Sie Scheduler pro Node, Online- und Idle-Zustand, Memory Node sowie Foreign Memory.

**Warum problematisch:** Stark unausgewogene Scheduler- oder Memoryverteilung kann lokale Engpässe und Remote-Memory-Zugriffe begünstigen.

**Wann nicht problematisch:** Unterschiedliche Momentanlast je Node ist normal; persistente Asymmetrie ist relevanter.

**Beispiel:** Wenn ein Node dauerhaft voll ausgelastet ist, ein anderer nahezu idle bleibt und Sessions konzentriert sind, müssen Affinity, Verbindungslast und Soft-NUMA geprüft werden.

**Nächster Schritt:** Korrelieren Sie CPU, Schedulerwaits und Konfiguration. [Detailbeschreibung](08_Server_Health.md#2-monitorusp_servernuma)

## [monitor].[USP_ServerMemory]

**Auswertung:** Berücksichtigen Sie OS Available Memory, SQL Process Memory, Target und Total Server Memory, Memory Pressure und die größten Clerks gemeinsam.

**Warum problematisch:** OS- und SQL-Druck gleichzeitig kann Paging, Cacheverdrängung und Grantknappheit verursachen.

**Wann nicht problematisch:** Total Server Memory nahe Target ist normal – SQL Server soll zugewiesenen Speicher nutzen.

**Beispiel:** Total≈Target allein ist gesund. Total≈Target + OS kaum frei + Process Physical Memory Low + Grantwaits ist problematisch.

**Nächster Schritt:** Prüfen Sie Memory Grants, Buffer Pool und max server memory. [Detailbeschreibung](08_Server_Health.md#3-monitorusp_servermemory)

## [monitor].[USP_TempDBConfiguration]

**Auswertung:** Prüfen Sie Dateianzahl, Gleichheit von Größe und Growth, Autogrowth-Einheit, verfügbaren Platz, VLF und Version Store.

**Warum problematisch:** Ungleich große Datenfiles können proportional unterschiedlich genutzt werden; kleine Growthschritte verursachen viele Wachstumsereignisse.

**Wann nicht problematisch:** Nicht jede Instanz benötigt acht Dateien; CPU, Contention und Workload entscheiden.

**Beispiel:** Acht Dateien sind kein Selbstzweck. Vier gleich große Dateien ohne Contention können besser sein als acht stark ungleiche.

**Nächster Schritt:** Prüfen Sie Current TempDB, Contention und Filegrowth-Historie. [Detailbeschreibung](08_Server_Health.md#4-monitorusp_tempdbconfiguration)

## [monitor].[USP_ServerConfiguration]

**Auswertung:** Vergleichen Sie Configured Value, Run Value, Dynamic- und Advanced-Status sowie Beschreibung.

**Warum problematisch:** Abweichende Run Values können pending restart/reconfigure anzeigen; extreme Werte können Ressourcen falsch begrenzen.

**Wann nicht problematisch:** Nicht jeder vom Default abweichende Wert ist falsch – viele produktive Systeme benötigen bewusste Anpassungen.

**Beispiel:** Ein niedriger Wert für `max server memory` kann bei einer großen Instanz absichtlich Speicher für andere Dienste reservieren. Prüfen Sie zuerst den Betriebssystem- und Workloadkontext.

**Nächster Schritt:** Prüfen Sie Memory, CPU, TempDB oder konkrete Featureanalyse. [Detailbeschreibung](08_Server_Health.md#5-monitorusp_serverconfiguration)

## [monitor].[USP_TraceFlags]

**Auswertung:** Prüfen Sie Flagnummer, globalen beziehungsweise sessionbezogenen Scope, Status und versionsabhängige Bedeutung.

**Warum problematisch:** Undokumentierte oder veraltete Flags können Optimizer-/Engineverhalten unerwartet verändern.

**Wann nicht problematisch:** Manche Flags sind dokumentierte bewusste Workarounds oder Diagnosehilfen.

**Beispiel:** Aktives altes Kompatibilitäts-Flag nach Upgrade kann neue Standardverbesserungen überdecken.

**Nächster Schritt:** Prüfen Sie Startup Parameters, Microsoft-Dokumentation und Changehistorie. [Detailbeschreibung](08_Server_Health.md#6-monitorusp_traceflags)

## [monitor].[USP_StartupParameters]

**Auswertung:** Prüfen Sie Parameterart, Pfade, Trace Flags und Startoptionen.

**Warum problematisch:** Falsche Master-/Errorlog-/Startpfade oder unerwartete Flags können Start und Verhalten beeinflussen.

**Wann nicht problematisch:** Abweichende Pfade sind häufig bewusstes Storage-Design.

**Beispiel:** Trace Flag nur als Startup-Parameter erklärt, warum es nach jedem Neustart wieder aktiv ist.

**Nächster Schritt:** Prüfen Sie Trace Flags, Dateisystem und Dienstkonfiguration. [Detailbeschreibung](08_Server_Health.md#7-monitorusp_startupparameters)

## [monitor].[USP_OSInformation]

**Auswertung:** Berücksichtigen Sie OS-Version, Virtualisierung, Speicher, Zeit, Uptime und Plattformgrenzen gemeinsam.

**Warum problematisch:** Sehr geringe Uptime erklärt resetete DMVs; Zeitabweichungen erschweren Korrelation; Memory-/Virtualisierungsgrenzen beeinflussen SQL.

**Wann nicht problematisch:** Virtuelle Umgebung ist nicht automatisch langsam.

**Beispiel:** Index Usage zeigt 0 Reads, OS Uptime zwei Stunden. Die Beobachtung ist zu kurz für eine Löschungsentscheidung.

**Nächster Schritt:** Prüfen Sie CPU, Memory, I/O und Hypervisor-/OS-Monitoring. [Detailbeschreibung](08_Server_Health.md#8-monitorusp_osinformation)

## [monitor].[USP_ServerSecurityConfiguration]

**Auswertung:** Berücksichtigen Sie jede Konfiguration zusammen mit Scope, aktuellem Wert, Exposition und EvidenceLimit.

**Warum problematisch:** Unsichere Optionen können Angriffsfläche oder unerwünschte Rechtepfade eröffnen.

**Wann nicht problematisch:** Ein aktiviertes Feature kann betrieblich erforderlich und durch andere Kontrollen abgesichert sein.

**Beispiel:** `xp_cmdshell` aktiviert ist ein Reviewbefund, aber die reale Gefährdung hängt von Berechtigungen, Nutzung und Kompensationskontrollen ab.

**Nächster Schritt:** Prüfen Sie Berechtigungen, Audit und Sicherheitskonzept. [Detailbeschreibung](08_Server_Health.md#9-monitorusp_serversecurityconfiguration)

## [monitor].[USP_ServerHealthAnalysis]

**Auswertung:** Prüfen Sie zuerst den Status jeder Teilanalyse und danach deren Symptome. Interpretieren Sie keine Summenzeile als vollständigen Nachweis eines fehlerfreien Zustands.

**Warum problematisch:** Ein Teilergebnis kann unvollständig sein; ein anderes kann nur die Konfiguration, aber keine aktuelle Auswirkung zeigen.

**Wann nicht problematisch:** Nicht aktivierte Spezialmodule fehlen absichtlich.

**Beispiel:** Memorykonfiguration auffällig, aber aktuelle Memorywerte normal. Das ist ein Review, kein akuter Incident.

**Nächster Schritt:** Rufen Sie das entsprechende Child mit einem fokussierten Scope auf. [Detailbeschreibung](08_Server_Health.md#10-monitorusp_serverhealthanalysis)

## [monitor].[USP_DatabaseIntegrityAnalysis]

**Auswertung:** Berücksichtigen Sie Datenbankstatus, PAGE_VERIFY, CHECKDB-Alter, Suspect Pages, beschädigte Backups und HADR-Reparaturen gemeinsam.

**Warum problematisch:** Suspect Pages oder beschädigte Backup-Evidenz weisen auf mögliche physische/inhaltliche Schäden hin. Pending HADR-Reparatur zeigt ungelösten Zustand.

**Wann nicht problematisch:** Keine Indikatoren beweisen keine Integrität; die Procedure führt keinen CHECKDB aus.

**Beispiel:** `SuspectPageCount=0` bedeutet nur, dass diese Quelle nichts meldet. `SuspectPageCount=3` ist dagegen konkrete negative Evidenz und muss eskaliert werden.

**Nächster Schritt:** Prüfen Sie Page Details, CHECKDB-Strategie, Backup Chain und Restore-Test. [Detailbeschreibung](08_Server_Health.md#11-monitorusp_databaseintegrityanalysis)

## [monitor].[USP_DatabaseCapacityAnalysis]

**Auswertung:** Berücksichtigen Sie Dateigröße, belegten und freien Speicher, Volume Free, Growthsetting, MaxSize und Wachstumsspielraum gemeinsam.

**Warum problematisch:** Kleine freie Fläche + kleine häufige Autogrowths kann zu Pausen und Fragmentierung führen; MaxSize oder volles Volume kann Wachstum vollständig verhindern.

**Wann nicht problematisch:** Niedriger Prozentwert bei sehr großem absoluten freien Speicher kann ausreichend sein; hoher Prozentwert bei winziger Disk dagegen nicht.

**Beispiel:** 5 % freier Speicher von 20 TB entsprechen 1 TB und können ausreichend sein. 20 % freier Speicher von 10 GB entsprechen dagegen nur 2 GB. Berücksichtigen Sie den Prozentwert und die absolute Menge gemeinsam.

**Nächster Schritt:** Prüfen Sie Wachstumstrend, Backup-/Logstatus und Storagekapazität. [Detailbeschreibung](08_Server_Health.md#12-monitorusp_databasecapacityanalysis)

## [monitor].[USP_PerformanceCounters]

**Auswertung:** Beachten Sie Countertyp und Normalisierung. Verwenden Sie bei Rate- und Fraction-Countern Samplewerte anstelle des Rohwerts.

**Warum problematisch:** Rohcounter ohne Typ können völlig falsch interpretiert werden. Delta und Base sind für manche Counter zwingend.

**Wann nicht problematisch:** Ein hoher kumulativer Rohwert kann nur lange Uptime widerspiegeln.

**Beispiel:** Page Life Expectancy hat keine universelle feste Grenze. Ein abrupter Einbruch zusammen mit Memory Pressure und I/O ist relevanter als ein einzelner Wert unter einer alten Faustregel.

**Nächster Schritt:** Prüfen Sie Server Memory, I/O, Workload und Baseline. [Detailbeschreibung](08_Server_Health.md#13-monitorusp_performancecounters)

## [monitor].[USP_CriticalEngineEvents]

**Auswertung:** Vergleichen Sie Eventtyp, Severity, Zeit, Quelle und Wiederholung. Aktivieren Sie XML und Details nur gezielt.

**Warum problematisch:** Schwere Fehler, Schedulerprobleme oder Dumps können Engine-, Hardware- oder I/O-Risiken anzeigen.

**Wann nicht problematisch:** Einzelnes historisches Ereignis kann bereits behoben sein; aktuelle Wiederholung und Begleitsymptome entscheiden.

**Beispiel:** Severity-20+-Fehler mehrfach in kurzer Zeit plus suspect pages ist deutlich kritischer als ein einzelnes altes Ereignis ohne Wiederholung.

**Nächster Schritt:** Prüfen Sie Error Log, system_health, Integrität und Infrastruktur. [Detailbeschreibung](08_Server_Health.md#14-monitorusp_criticalengineevents)

## [monitor].[USP_InternalContentionAnalysis]

**Auswertung:** Betrachten Sie Delta über Sample, Spin- und Latchklasse, Waitdauer, Hot Page und Wiederholung.

**Warum problematisch:** Hohe interne Synchronisationswartezeiten können CPU-Durchsatz begrenzen, obwohl einzelne Queries unauffällig wirken.

**Wann nicht problematisch:** Hohe absolute Zähler seit Start ohne aktuelles Delta sind schwach.

**Beispiel:** Hot Page erscheint in mehreren Samples mit wachsender Waitzeit: belastbare Contention. Ein einmaliger kleiner Peak nicht.

**Nächster Schritt:** Prüfen Sie Page Details, TempDB/Indexdesign, Insertmuster und aktuelle Requests. [Detailbeschreibung](08_Server_Health.md#15-monitorusp_internalcontentionanalysis)

## [monitor].[USP_BufferPoolAnalysis]

**Auswertung:** Berücksichtigen Sie Gesamtbuffer, Clerks, Datenbankverteilung, Dirty und Clean Pages sowie Memory Pressure gemeinsam.

**Warum problematisch:** Ungewöhnliche Verteilung oder dominanter Clerk kann Speicher verdrängen; Dirty Pages können Checkpoint-/I/O-Druck anzeigen.

**Wann nicht problematisch:** Eine große Datenbank darf den Buffer Pool dominieren, wenn sie die aktive Workload trägt.

**Beispiel:** 80 % Buffer für ExampleDatabase ist nicht automatisch schlecht. Problematisch wird es, wenn andere aktive Datenbanken ständig physisch lesen und Memory Pressure besteht.

**Nächster Schritt:** Prüfen Sie Server Memory, I/O, Query Reads und Workloadanteil. [Detailbeschreibung](08_Server_Health.md#16-monitorusp_bufferpoolanalysis)

## [monitor].[USP_DiagnosticFindings]

**Auswertung:** Berücksichtigen Sie Severity und Confidence zusammen mit SourceModule, Evidence, EvidenceLimit und Modulstatus.

**Warum problematisch:** HIGH/HIGH bedeutet starke priorisierte Evidenz. HIGH/LOW bedeutet dringende Verifikation, aber noch keine bestätigte Ursache.

**Wann nicht problematisch:** Keine Findings sind nur dann beruhigend, wenn relevante Kindmodule vollständig liefen.

**Beispiel:** Leeres Findingsresultset + Integritätsmodul `PERMISSION_DENIED` ist keine Entwarnung. `SUSPECT_PAGE_EVIDENCE_PRESENT`, HIGH/HIGH dagegen sofortige Eskalation.

**Nächster Schritt:** Wechseln Sie immer zum angegebenen `SourceModule` und lesen Sie dessen Detailresultsets. [Detailbeschreibung](08_Server_Health.md#17-monitorusp_diagnosticfindings)

# 11. Versionsadaptive Spezialanalysen

## [monitor].[USP_ServerFeatureCapabilities]

**Auswertung:** Unterscheiden Sie Serverversion, Edition, Plattform, Datenbank-Compatibility und die jeweilige Featurefähigkeit.

**Warum problematisch:** Codepfade können auf einer Version vorhanden, aber auf Plattform/Edition oder in einer Datenbank nicht nutzbar sein.

**Wann nicht problematisch:** Ein nicht unterstütztes Feature ist kein Serverfehler, wenn es nicht benötigt wird.

**Beispiel:** SQL Server 2025 installiert, aber Compatibility 160: bestimmte 170-Features sind für diese Datenbank noch nicht aktivierbar.

**Nächster Schritt:** Führen Sie das konkrete Spezialmodul nur für geeignete Scopes aus. [Detailbeschreibung](09_Version_Adaptive.md#1-monitorusp_serverfeaturecapabilities)

## [monitor].[USP_SpecialFeatureInventory]

**Auswertung:** Berücksichtigen Sie FeatureCode, Erkennungsstatus, Nutzungsumfang, empfohlene Tiefenanalyse und EvidenceLimit.

**Warum problematisch:** Ein erkanntes Spezialfeature benötigt eigene Betriebs-, Backup-, Kapazitäts- und Performancebetrachtung, die Standardanalysen nicht vollständig abdecken.

**Wann nicht problematisch:** Featureerkennung ist Inventar, kein Fehlerbefund.

**Beispiel:** Temporal Tables erkannt bedeutet nicht, dass Retention falsch ist; es bedeutet, dass `USP_TemporalAnalysis` sinnvoll wird.

**Nächster Schritt:** Prüfen Sie das empfohlene Deep-Dive-Modul. [Detailbeschreibung](09_Version_Adaptive.md#2-monitorusp_specialfeatureinventory)

## [monitor].[USP_InMemoryOltpAnalysis]

**Auswertung:** Berücksichtigen Sie Tabellenmemory, Hash-Buckets, Chainlängen, Checkpointfiles, aktive Transaktionen und Resource Pool gemeinsam.

**Warum problematisch:** Lange Hashketten verursachen mehr Vergleiche; wartende Checkpointdaten oder hohe Poolauslastung können Speicher-/Persistenzdruck anzeigen.

**Wann nicht problematisch:** Große Memorynutzung ist bei bewusst großen XTP-Tabellen normal; absolute Größe allein genügt nicht.

**Beispiel:** Avg Chain 20, Max 500 und kaum leere Buckets bei vielen Equality Lookups spricht für zu kleine Bucketzahl. Dieselben Werte bei nicht verwendetem Hashindex haben geringere Auswirkung.

**Nächster Schritt:** Prüfen Sie Workload, Indexart, Bucketdimensionierung, Pool und Checkpoints. [Detailbeschreibung](09_Version_Adaptive.md#3-monitorusp_inmemoryoltpanalysis)

## [monitor].[USP_TemporalAnalysis]

**Auswertung:** Vergleichen Sie Current- und History-Zuordnung, Historygröße, Retention, Konsistenzstatus, Indexierung und Wachstum.

**Warum problematisch:** Unbegrenzte oder nicht funktionierende Retention kann Historytabellen stark wachsen lassen; ungeeignete Indizes verteuern Zeitabfragen und Cleanup.

**Wann nicht problematisch:** Große History kann fachlich erforderlich sein und durch Partitionierung/Archivierung kontrolliert werden.

**Beispiel:** History wächst monatlich stark, Retention ist konfiguriert, aber Cleanupstatus zeigt keine Wirkung. Das ist ein konkreter Betriebsbefund, nicht nur „große Tabelle“.

**Nächster Schritt:** Prüfen Sie Kapazität, Partitionierung, Retentionjob und Abfragepläne. [Detailbeschreibung](09_Version_Adaptive.md#4-monitorusp_temporalanalysis)

## [monitor].[USP_ServiceBrokerAnalysis]

**Auswertung:** Prüfen Sie zuerst den Datenbank- und Quellenstatus. Berücksichtigen Sie danach Queue-Schalter und Rückstand, Aktivierungszustand, Transmission-Gruppen und Conversation-Zustände gemeinsam.

**Warum problematisch:** Deaktiviertes RECEIVE, ausbleibende Aktivierung, alte Transmission-Einträge oder Conversation-Errorzustände können Verarbeitung und Zustellung blockieren.

**Wann nicht problematisch:** Queue- und DMV-Werte sind Momentaufnahmen. Retention, kurz laufende Reader oder bewusst langlebige Dialoge können auffällige Einzelwerte erklären.

**Beispiel:** Eine nichtleere Queue ohne sichtbaren Task ist erst dann ein Aktivierungsbefund, wenn Queue-Monitor und Taskquelle vollständig auswertbar sind. RECEIVE OFF allein beweist keine Poison Message.

**Nächster Schritt:** Prüfen Sie Zeitverlauf, Fehlerlog beziehungsweise freigegebene Events, Routing, Endpunkt und Anwendungstransaktionen. [Detailbeschreibung](09_Version_Adaptive.md#5-monitorusp_servicebrokeranalysis)

## [monitor].[USP_FullTextAnalysis]

**Auswertung:** Prüfen Sie zuerst den Datenbank- und Quellenstatus. Berücksichtigen Sie danach Indexschalter, Crawl-Kontext, aktuelle Populationen, Batches, Fragmente und semantische Population gemeinsam.

**Warum problematisch:** Deaktivierte Indizes, abgebrochene Populationen, Batchfehler oder fehlgeschlagene Dokumente können Suchaktualität und Auffindbarkeit beeinträchtigen; viele Fragmente können Suchabfragen verteuern.

**Wann nicht problematisch:** `MANUAL/OFF`, ein absichtlich verzögerter initialer Crawl und ein langer, aber fortschreitender Lauf können korrekt sein. Die DMVs sind Momentaufnahmen und keine Historie.

**Beispiel:** Eine Population läuft seit zwei Stunden, ihre abgeschlossenen Ranges steigen jedoch zwischen Messungen. Dies belegt keinen Stillstand. Bewerten Sie zuerst Verlauf, Batches, I/O und geschützte Logs gemeinsam.

**Nächster Schritt:** Prüfen Sie in einer Folgeaufnahme den I/O- und Logkontext sowie die Suchlatenz. Full-Text- und Crawl-Logs dürfen ausschließlich in der Laufzeitumgebung ausgewertet werden. [Detailbeschreibung](09_Version_Adaptive.md#6-monitorusp_fulltextanalysis)

## [monitor].[USP_DataCaptureDeepAnalysis]

**Auswertung:** Behandeln Sie Change Tracking, CDC und Replikation getrennt. Prüfen Sie zuerst den Quellenstatus und berücksichtigen Sie danach CT-Versionen, CDC-Scan und Jobs sowie lokale Replikationsagenten mit Rückstand gemeinsam.

**Warum problematisch:** Ein echter CT-Consumer-Wasserstand unter `MinValidVersion` erfordert Reinitialisierung. CDC-Fehler oder fehlende Jobs können Capture/Cleanup verhindern. Hoher lokaler Replikationsrückstand zusammen mit Fail/Retry weist auf eine Zustellstörung hin.

**Wann nicht problematisch:** Ohne CT-Wasserstand ist kein Verlust beweisbar. Zeitgesteuertes CDC kann zwischen Läufen Latenz zeigen. Idle-Replikationsagenten ohne Rückstand sind normal.

**Beispiel:** 20.000 undistributed commands und ein Distribution Agent im Retry-Zustand sind gemeinsam wesentlich stärker als eine alte Idle-History ohne Rückstand.

**Nächster Schritt:** Wiederholen Sie die Verlaufsmessung und prüfen Sie Consumer-Wasserstand, Jobausgang sowie Distributor- und Subscriber-Erreichbarkeit. Geschützte Logs dürfen nur in der Laufzeitumgebung ausgewertet werden. [Detailbeschreibung](09_Version_Adaptive.md#7-monitorusp_datacapturedeepanalysis)

# 12. Praktisches Vorgehen für Anfänger

1. Beginnen Sie im [Objektindex](Object_Index.md) oder bei der Symptomnavigation im [Analysehandbuch](README.md).
2. Lesen Sie zuerst Status und Aussagegrenze.
3. Bestimmen Sie Zeitbezug und Nenner.
4. Markieren Sie nicht den größten Wert, sondern die auffälligste **Kombination**.
5. Formulieren Sie eine Hypothese, zum Beispiel: „Die Query ist langsam, weil sie überwiegend auf einen Lock wartet.“
6. Rufen Sie die empfohlene zweite Procedure auf.
7. Ändern Sie erst etwas, wenn beide Evidenzquellen, Auswirkung und Rollbackweg verstanden sind.

## Beispiel einer vollständigen Leserichtung

Ausgangswerte:

- `ElapsedMs = 180000`
- `CpuMs = 900`
- `WaitType = LCK_M_X`
- `WaitTimeMs = 176000`
- `BlockingSessionId = 74`

Interpretation in Schritten:

1. Drei Minuten Laufzeit wirken hoch, sind allein aber noch keine Ursache.
2. Nur 0,9 Sekunden CPU zeigen, dass die Query kaum gerechnet hat.
3. 176 Sekunden Lock-Wartezeit erklären fast die gesamte Laufzeit.
4. `BlockingSessionId=74` liefert den direkten Blocker.
5. Das Problem ist daher nicht zuerst „Query benötigt mehr CPU“, sondern „Query kann wegen eines exklusiven Locks nicht weiterarbeiten“.
6. `USP_CurrentBlocking` muss zeigen, ob Session 74 Root Blocker ist.
7. `USP_CurrentTransactions` muss zeigen, ob dort eine alte oder sleeping Transaktion offen ist.
8. Erst danach ist eine betriebliche Entscheidung möglich.

Diese Form der Argumentation soll für alle Frameworkbefunde verwendet werden: **Wert → Zusammenhang → Ursachehypothese → Auswirkung → Gegenprobe → Folgeschritt**.
