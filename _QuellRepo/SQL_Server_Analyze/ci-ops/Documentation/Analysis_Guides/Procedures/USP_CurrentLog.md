# [monitor].[USP_CurrentLog]

**Bereich:** Current State<br>
**Zweck:** Zeigt Logauslastung, Wiederverwendungswartegrund, VLF- und optional PVS-Kontext.<br>
**Beobachtungsart:** Snapshot + Katalog + kumulative Teilwerte<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie voll ist das Transaktionslog, warum kann es nicht wiederverwendet werden und welches Risiko entsteht?** Sie unterstützt die Entscheidung, ob das aktuelle Symptom im Erfassungsmoment sichtbar ist und welcher engere Live-, Verlaufs- oder Planpfad als Nächstes sinnvoll ist.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine lückenlose Historie und allein aus einem Snapshot weder Dauerhäufigkeit noch Root Cause oder zukünftige Entwicklung. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CurrentLog]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `logs`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Datenbank, eine Logdatei, einen VLF- oder PVS-Aspekt. Prüfen Sie den jeweiligen Scope vor der Summenbildung.

## So lesen

Berücksichtigen Sie Used Percent, absolute Loggröße, `log_reuse_wait_desc`, Growth, VLF und offene Transaktionen gemeinsam.

## Warum kann das problematisch sein?

Hohe Nutzung ist besonders kritisch, wenn Wiederverwendung durch eine alte Transaktion, fehlende Logbackups oder HA-/Replikations-Lag blockiert wird. Reines Vergrößern behebt die Ursache nicht.

## Wann ist es kein Problem?

Hohe Nutzung während eines geplanten Batches kann akzeptabel sein, wenn Kapazität, Backupfolge und anschließende Wiederverwendung gesichert sind.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 95 % genutzt plus `ACTIVE_TRANSACTION` plus zwei Stunden alte Transaktion: Primärursache ist die offene Transaktion. Prüfen Sie `USP_CurrentTransactions`, Backupstatus und Kapazität.

**Ähnlich aussehender Gegenfall:** Hohe Nutzung während eines geplanten Batches kann akzeptabel sein, wenn Kapazität, Backupfolge und anschließende Wiederverwendung gesichert sind. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Live-DMVs kann der Zustand bereits beendet sein, bevor die Quelle gelesen wird. Eine leere Menge ist deshalb höchstens 'jetzt nicht sichtbar', nicht 'trat nicht auf'.

Für `USP_CurrentLog` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Der Standardpfad besitzt eine moderate Eigenlast; die automatische Datenbankauswahl besitzt keine Vorabbegrenzung.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Datenbankweise Logspace-/Reuse-Metadaten ohne breite VLF- oder PVS-Vertiefung. |
| Teuerster Pfad | Cross-Database-VOLL-Lauf mit VLF- und PVS-Vertiefung über große beziehungsweise VLF-reiche Logs. |
| Haupttreiber | Zahl gewählter Datenbanken und – bei aktiviertem Detail – ihrer VLF-Zeilen aus `dm_db_log_info`; Log-Space-/Log-Stats-Summary ist je Datenbank klein. PVS-Kontext fügt Metadaten hinzu, liest aber keine Version-Store-Zeilen. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_CurrentLog ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | Katalog-/DMV-CPU und bei VLF-/PVS-Vertiefung zusätzliche datenbankweise Arbeit, TempDB und Ergebnistransfer. |
| Begrenzungswirkung | Datenbankfilter begrenzen den Quellzugriff; ein Zeilenlimit verhindert nicht, dass VLFs oder PVS-Metadaten des gewählten Scopes zunächst gelesen werden. |
| Locking und Nebenwirkungen | Read-only, aber dynamische datenbankweise Katalogzugriffe können kurz mit DDL/Statuswechseln kollidieren. Der Zustand kann sich schon während des Laufs ändern. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `LOG_VLF_DEEP`, `STANDARD_CURRENT`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Zuerst eine ExampleDb ohne VLF-/PVS-Details; LOG_VLF_DEEP nur gezielt und in ruhigerem Betriebsfenster freigeben. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot + Katalog + kumulative Teilwerte“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie voll ist das Transaktionslog, warum kann es nicht wiederverwendet werden und welches Risiko entsteht?

### Technischer Hintergrund

Das Log ist eine sequenzielle Recoverystruktur aus VLFs. Log Records müssen für Commit gehärtet und für Recovery/Backup/HADR/Replication je nach Konfiguration erhalten werden. Space-Usage, Filemetadaten, VLF-Kontext und `log_reuse_wait_desc` erklären verschiedene Ebenen.

### Datenkette

`master.sys.databases`, `sys.dm_db_log_info`, `sys.dm_db_log_space_usage`, `sys.dm_db_log_stats`, `sys.dm_tran_persistent_version_store_stats`, `sys.sp_executesql`.

### Source Select

Der datenbanklokale Kern verbindet Logbelegung und Logzustand; die Zieldatenbank muss vor dem DMF-Aufruf feststehen:

```sql
SELECT
      [space].[total_log_size_in_bytes]
    , [space].[used_log_space_in_bytes]
    , [stats].[recovery_model]
    , [stats].[log_truncation_holdup_reason]
    , [stats].[total_vlf_count]
FROM [sys].[dm_db_log_space_usage] AS [space] WITH (NOLOCK)
CROSS APPLY [sys].[dm_db_log_stats](DB_ID()) AS [stats];
```

**Wichtig für die Eigenlast:** Zuerst die Datenbankkandidaten einschränken. `sys.dm_db_log_info` liefert eine Zeile je VLF und ist der wesentliche Vertiefungstreiber; VLF-Details nicht breit über alle Datenbanken lesen.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Space- und Reusezustand. Dateigröße und VLFs sind Metadaten; einzelne Zähler sind kumulativ. Der Reuse-Wait kann sich nach einem Backup oder Commit rasch ändern.

### Bewertung und Gegenprobe

Berücksichtigen Sie Used Percent, absolute freie MB, Wachstumsoption, Volumeplatz und Reuse-Wait gemeinsam. `ACTIVE_TRANSACTION`, `LOG_BACKUP`, `AVAILABILITY_REPLICA` oder `REPLICATION` führen zu unterschiedlichen Maßnahmen.

### Typische Fehlinterpretation

Logvergrößerung beseitigt die Reuse-Ursache nicht. Shrink ist keine dauerhafte Lösung und kann VLF-/Autogrowthprobleme verschärfen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_CurrentTransactions`, Backup-/AG-/Replicationmodule, `USP_CurrentIO` für Logfilelatenz.

## Primärquellen

- [sys.dm_db_log_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-log-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [sp_WhoIsActive – ergänzende Live-Diagnostik und andere Aufbereitung aktueller Aktivität](https://github.com/amachanic/sp_whoisactive)

[Technische Detailbeschreibung](../02_Current_State.md#9-monitorusp_currentlog)
