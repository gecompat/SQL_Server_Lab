# [monitor].[USP_LogShippingStatus]

**Bereich:** Infrastruktur<br>
**Zweck:** Zeigt Backup-, Copy- und Restorefortschritt von Log Shipping.<br>
**Beobachtungsart:** Konfigurationssnapshot + retentionbegrenzte Historie<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Erzeugen, kopieren und restaurieren die Log-Shipping-Jobs Backups innerhalb der konfigurierten Schwellen?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_LogShippingStatus]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `primary`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Primary-/Secondary-Konfiguration, Datenbankbeziehung oder Überwachungszeile.

## So lesen

Vergleichen Sie die Zeitpunkte des letzten Backups, Kopierens und Restores sowie den Schwellenstatus, den Restore Delay und die Metadatenverfügbarkeit.

## Warum kann das problematisch sein?

Eine wachsende Differenz zeigt, ob Backup-, Transport- oder Restorephase zurückfällt.

## Wann ist es kein Problem?

Ein geplanter Restore Delay erzeugt absichtlich Verzögerung.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Backups aktuell, Copy 90 Minuten zurück, Restore ebenfalls zurück: Transportpfad wahrscheinlicher als Backupjob. Prüfen Sie Jobhistorie, Netzwerk, Share und Secondary.

**Ähnlich aussehender Gegenfall:** Ein geplanter Restore Delay erzeugt absichtlich Verzögerung. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_LogShippingStatus` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist gering.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Aktueller lokaler msdb-Snapshot der konfigurierten Primary- und Secondary-Monitorzeilen, jeweils bis zum Defaultlimit 5000. |
| Teuerster Pfad | `@MaxZeilen = 0` bei sehr vielen Log-Shipping-Konfigurationen. Die Procedure liest keine frei wählbare Job- oder Backuphistorie und besitzt keinen Datenbankfilter. |
| Haupttreiber | Zahl lokaler Primary-/Secondary-Konfigurationen und Monitorzeilen in msdb. Backup- oder Jobhistory wird nicht geöffnet; deshalb wächst der Pfad mit konfigurierten Log-Shipping-Beziehungen, nicht mit dem frei wählbaren Historienalter. |
| Skalierung | Nahezu linear mit den lokalen Primary-/Secondary-Monitorzeilen; Ergebnisbreite enthält auch konfigurierte Datei-/Sharefelder, bleibt aber gewöhnlich klein. |
| Ressourcen | Geringe CPU- und msdb-I/O-Last für Konfigurations-/Monitorjoins und Sortierung; keine Remoteabfrage und kein Logdateizugriff. |
| Begrenzungswirkung | `@MaxZeilen` wird als TOP in Primary- und Secondarypfad getrennt angewandt. Es ist keine gemeinsame Gesamtgrenze und kann relevante später sortierte Konfigurationen ausblenden. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | Kein Gate und kein Datenbankfilter. Das endliche Defaultlimit wird getrennt auf Primary- und Secondary-Monitorzeilen angewandt; der Quellpfad bleibt auf aktuelle lokale Log-Shipping-Konfiguration beschränkt und öffnet keine Job- oder Backuphistorie. |
| Sicherer Einsatz | Defaultlimit und CONSOLE; bei mehr als 5000 Konfigurationen RAW/JSON-Vollständigkeitsmarker und Sortierung prüfen, bevor das Limit erhöht wird. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Konfigurationssnapshot + retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Erzeugen, kopieren und restaurieren die Log-Shipping-Jobs Backups innerhalb der konfigurierten Schwellen?

### Technischer Hintergrund

Log Shipping besteht aus Backupjob auf Primary, Copy-/Restorejobs auf Secondary und optional Monitorserver. Monitor-/Primary-/Secondarytabellen halten letzte Datei-/Zeit-/Schwellenwerte. Jede Stufe kann unabhängig zurückliegen.

### Datenkette

`msdb.dbo.log_shipping_monitor_primary`, `msdb.dbo.log_shipping_monitor_secondary`, `msdb.dbo.log_shipping_primary_databases`, `msdb.dbo.log_shipping_secondary_databases`.

### Source Select

Der Primary-Pfad verbindet Konfiguration und Monitorstatus über `primary_id`:

```sql
SELECT
      [p].[primary_database]
    , [p].[backup_directory]
    , [m].[last_backup_date]
    , [m].[last_backup_file]
    , [m].[backup_threshold]
    , [m].[threshold_alert_enabled]
FROM [msdb].[dbo].[log_shipping_primary_databases] AS [p] WITH (NOLOCK)
LEFT JOIN [msdb].[dbo].[log_shipping_monitor_primary] AS [m] WITH (NOLOCK)
  ON [m].[primary_id] = [p].[primary_id]
WHERE [p].[primary_database] = N'ExampleDatabase';
```

**Wichtig für die Eigenlast:** Filtern Sie die Primary- beziehungsweise Secondary-Datenbank vor der jeweiligen Monitoransicht. Primary und Secondary sind getrennte Zeilengranularitäten und werden nicht über Namen zu einer vermeintlich atomaren Kette verschmolzen.

### Zeit- und Scope-Modell

Die Auswertung verwendet Monitor-Metadaten mit eigener Aktualisierungszeit und die Jobhistorie. Zeitabweichungen und veraltete Monitordaten beeinflussen die Interpretation.

### Bewertung und Gegenprobe

Bewerten Sie Backup-, Copy- und Restorelatenz getrennt. Korrelieren Sie die letzten Dateinamen und Zeiten mit Threshold, Alertstatus, Jobzustand und Monitoraktualität. Restore Mode und Delay können eine beabsichtigte Verzögerung verursachen.

### Typische Fehlinterpretation

Ein grüner Monitor kann stale sein. Eine alte Restorezeit ist bei konfiguriertem Delay nicht automatisch Fehler. Dateinamen allein beweisen keine lückenlose LSN-Kette.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Agent Jobs, Backup Chain und Secondary-/Shareprüfung.

## Primärquellen

- [Überwachen von Log Shipping](https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/monitor-log-shipping-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#6-monitorusp_logshippingstatus)
