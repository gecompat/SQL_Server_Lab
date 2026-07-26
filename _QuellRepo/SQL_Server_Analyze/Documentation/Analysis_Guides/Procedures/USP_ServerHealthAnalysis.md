# [monitor].[USP_ServerHealthAnalysis]

**Bereich:** Server Health, Orchestrator<br>
**Zweck:** Orchestriert Topologie, Memory, TempDB, Konfiguration, OS und optionale Spezialmodule.<br>
**Beobachtungsart:** nicht atomare Folge von Server-Snapshots<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Server-Health-Bereiche sind auffällig und welches Spezialmodul soll als Nächstes laufen?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerHealthAnalysis]
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Aktivieren Sie Spezialmodule nur bei konkreter Frage.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: CPU, Scheduler, Node, Memory, Datei, Konfiguration, Ereignis oder Finding.

## So lesen

Berücksichtigen Sie zuerst den Status jeder Teilanalyse und danach deren Symptome. Eine Summenzeile ist keine vollständige Gesundheitsgarantie.

## Warum kann das problematisch sein?

Ein Child kann partiell sein; ein anderes zeigt nur Konfiguration statt aktueller Auswirkung.

## Wann ist es kein Problem?

Nicht aktivierte Spezialmodule fehlen absichtlich.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Memorykonfiguration auffällig, aktuelle Memorywerte normal: Review, kein akuter Incident. Führen Sie das betreffende Child fokussiert erneut aus.

**Ähnlich aussehender Gegenfall:** Nicht aktivierte Spezialmodule fehlen absichtlich. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerHealthAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Neun kleine Server-Snapshots: CPU, NUMA, Memory, TempDB-Konfiguration, Serverkonfiguration, Trace Flags, Startparameter, OS und Security. Datenbankweite Integrität/Kapazität und alle Spezialmodule sind aus. |
| Teuerster Pfad | Alle sieben Opt-ins: Datenbankintegrität/-kapazität, Performance-Counter-Snapshot, `system_health`-Ereignisse, fünf Sekunden Contention, Buffer-Pool-Kontext und Findings. Findings kann weitere Standardchildren frisch erheben, verwendet aber vorhandene Integritäts-, Kapazitäts- und Buffer-Pool-JSONs wieder. |
| Haupttreiber | Im Default überwiegend kleine SQLOS-/Serverkataloge. Im erweiterten Pfad wachsen Kosten mit Datenbanken/Dateien, `msdb`-Historie, System-Health-Ereignissen, Latch-/Spinlockklassen und den von Findings zusätzlich benötigten Quellen. |
| Skalierung | Children laufen sequenziell. Aktivierte Integritäts-/Kapazitäts-/Buffer-Pool-Ergebnisse werden an Findings weitergereicht und dort nicht doppelt gelesen; andere Findings-Quellen bleiben zusätzliche Arbeit. |
| Ressourcen | Server-/OS-DMVs und Kataloge; optional Datenbankmetadaten, `msdb`, XE-Datei-/XML-Verarbeitung, TempDB/JSON sowie ein festes fünfsekündiges WAITFOR im Contention-Child. Es gibt keinen Plan-Cache- oder Query-Store-Pfad. |
| Begrenzungswirkung | `@MaxZeilen` wird nur an Children mit passendem Parameter übergeben und gilt dort je Resultset. Kleine Topologiechildren sind ohnehin unlimitiert; bei XE-/Historien-/Katalogchildren kann Quellarbeit vor der Ausgabegrenze stattfinden. |
| Locking und Nebenwirkungen | Read-only. Contention hält die Session fünf Sekunden; die übrigen Children verändern weder Konfiguration noch Daten. Weil alle nacheinander laufen, können Memory-, TempDB-, XE- und Findings-Sicht verschiedene Zeitpunkte repräsentieren. |
| Schutzmechanismus | Alle breiteren Spezialmodule sind standardmäßig aus. `@HighImpactConfirmed` wird an datenbankweite Children/Findings weitergereicht und wirkt nur an deren Policygates; es ist kein Kostenbudget. Critical Events läuft hier bewusst ohne Server-Diagnostics- und Event-XML-Ausgabe. |
| Sicherer Einsatz | Defaultmodule mit `@MaxZeilen = 100`; für eine Datenbankfrage Scope explizit setzen. Danach genau ein Spezialmodul aktivieren und dessen Childstatus/Kostenvertrag lesen, statt alle sieben zugleich einzuschalten. |
| Aussagegrenze | Der Default bewertet Plattformzustand, nicht automatisch Workloadgesundheit. Optionale Findings sind abgeleitete Triage und wegen sequenzieller Erhebung nicht atomar; leere Spezialresultate können deaktivierte Quelle, fehlende Rechte oder fehlende Ereignisse bedeuten. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Server-Health-Bereiche sind auffällig und welches Spezialmodul soll als Nächstes laufen?

### Technischer Hintergrund

Wrapper über CPU, NUMA, Memory, TempDB, Config, Trace Flags, Startup, OS und Security. Er verbindet keine atomare Systemaufnahme; Children können verschiedene Rechte/Quellen haben.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert CPU-, NUMA-, Memory-, TempDB-, Konfigurations-, Trace-Flag-, Startup-, OS-, Security-, Integrity-, Capacity-, Counter-, Engine-Event-, Contention-, Buffer-Pool-, Finding- und Worker-Pressure-Module.

**Wichtig für die Eigenlast:** Verwenden Sie zuerst die leichten Server-Snapshots und aktivieren Sie optionale Historien-, XEL-, Buffer-Descriptor- oder datenbankübergreifende Module gezielt. Childstatus und Scope bleiben getrennt; ein finales Zeilenlimit spart deren Quellarbeit nicht.

### Zeit- und Scope-Modell

Die Auswertung verwendet eine nicht atomare Folge aktueller Konfigurations- und Runtimeabfragen.

### Bewertung und Gegenprobe

Korrelieren Sie zuerst Childstatus und Partials, danach die Befunde nach Ressource. Das Ergebnis bestimmt eine Triagepriorität und keinen Gesamtgesundheitsscore.

### Typische Fehlinterpretation

Ein grüner Wrapper beweist keine Lastfreiheit oder Integrität; optionale/gesperrte Children können fehlen.

### Folgeanalyse

Prüfen Sie das betroffene Spezialmodul sowie die Current-State- und Historical-Evidenz.

## Primärquellen

- [System Dynamic Management Views](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../08_Server_Health.md#10-monitorusp_serverhealthanalysis)
