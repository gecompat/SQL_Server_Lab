# Betrieb des WaitTypeCatalog

Der Katalog trennt exakte Wait-Beschreibungen, analytische Einordnung und
Messhinweise. Für unbekannte Wait Types stellt er einen regelbasierten Fallback
anhand der Wait Group sowie passende Quellen bereit. Runtime-Abfragen verwenden
ausschließlich lesende Lookups. Eigene Zeilen erhalten
`IsFrameworkDefault=0`; dadurch bleiben sie bei Framework-Upgrades unverändert.

## Welche Fragen eine Katalogzeile beantwortet

| Frage | Feld |
|---|---|
| Auf welche Ressource oder Synchronisationsstelle wird gewartet? | `Meaning` |
| Wann entsteht der Wait typischerweise? | `TypicalOccurrence` |
| Ist er standardmäßig erwartbar, kontextabhängig oder bei aktiver Evidenz handlungsrelevant? | `DefaultAssessment`, `IsGenerallyBenign`, `Severity` |
| Worauf beruht diese Einordnung? | `AssessmentBasis` |
| Welche Ursachen sind häufig, aber noch nicht automatisch bewiesen? | `CommonCauses` |
| Welche Benutzer- oder Systemwirkung kann entstehen? | `PerformanceImpact`, `HighWaitImpact` |
| Wie lässt sich die bestätigte Ursache vermeiden oder mindern? | `Mitigation` |
| Welche Beobachtung spricht gegen den Wait als Root Cause? | `CounterEvidence` |
| Welche Queranalysen grenzen die Ursache ein? | `RecommendedChecks`, `RelatedWaitTypes` |
| Wie müssen aktive, Delta-, kumulative, Signal- und Resource-Werte gelesen werden? | `MeasurementGuidance` |
| Wie belastbar ist die Detailaussage? | `AnalysisConfidence` |

`DefaultAssessment` ist keine Alarmstufe. Ein Wait Type benennt zunächst den
Ort des Wartens, nicht automatisch den Verursacher. Besonders bei Locking liegt
die Ursache häufig beim Lockbesitzer und nicht beim wartenden Request.

## Quellenmodell

`SourceReference` bleibt aus Kompatibilitätsgründen die Microsoft-Primärquelle
für Wait-Namen und dokumentierte Kurzdefinitionen. Dieser gemeinsame Link
belegt jedoch nicht automatisch Interpretation, Ursachen oder Gegenmaßnahmen.

Die normalisierte Tabelle `[monitor].[WaitTypeCatalogSource]` weist deshalb je
Framework-Wait mindestens vier getrennte Quellenrollen aus:

| `SourceType` | Aussagezweck |
|---|---|
| `DEFINITION` | offizieller Name, Definition und Versionshinweis |
| `MEASUREMENT` | Runner-/Waiter-Abgrenzung, aktive Tasks, Delta und Plan-Waits |
| `INTERPRETATION` | wait-spezifische Fachreferenz |
| `DIAGNOSTIC_MITIGATION` | Diagnose und Gegenmaßnahmen für Komponenten oder Wait Groups |
| `EXACT_DIAGNOSTIC` | zusätzliche exakte Quelle für besonders häufige Entscheidungen |

`EvidenceLevel` unterscheidet Microsoft-Primärdokumentation,
Microsoft-Engineeringbeiträge, Microsoft-Werkzeuge und externe
Spezialistenreferenzen. `SupportsFields` nennt ausdrücklich, welche
Katalogaussagen die Quelle stützt.

SQLskills wird wait-spezifisch verlinkt. Inhalte der Bibliothek werden nicht in
eine freigegebene Laufzeitdokumentation kopiert. Seltene interne Waits bleiben mit
`AnalysisConfidence = INTERNAL_LIMITED` gekennzeichnet; für sie werden keine
undokumentierten Detailursachen oder Trace-Flag-Empfehlungen erfunden.

Quellen eines Wait Types abfragen:

```sql
SELECT *
FROM [monitor].[TVF_WaitTypeSources] (N'WRITELOG')
ORDER BY [SourceOrdinal];
```

## Mess- und Interpretationsvertrag

- Aktive `sys.dm_os_waiting_tasks` zeigen den aktuellen Zustand; sie können sich
  zwischen zwei Abfragen ändern.
- `sys.dm_os_wait_stats` ist seit Instanzstart oder letztem Reset kumulativ.
- Mindestens zwei Messpunkte unter vergleichbarer Last sind für eine
  Engpassaussage erforderlich.
- Lesen Sie `WaitTimeMs`, Taskanzahl und Durchschnitt immer gemeinsam. Viele kurze
  Waits und wenige lange Waits haben unterschiedliche Ursachen.
- `SignalWaitTimeMs` betrifft Runnable-/Schedulerzeit;
  `ResourceWaitTimeMs` die eigentliche Ressourcenwartezeit.
- Neustart, `DBCC SQLPERF`-Reset, Failover und Rollenwechsel begrenzen die
  Vergleichbarkeit.
- Ein hoher Prozentanteil kann entstehen, weil andere Waits fehlen; absolute
  Dauer, Durchsatz und Benutzerlatenz bleiben erforderlich.

## Upgrade- und Erweiterungsverhalten

Frameworkzeilen werden beim Upgrade erneut klassifiziert und ihre
Frameworkquellen werden neu aufgebaut. Benutzerdefinierte Katalog- und
Quellenzeilen mit `IsFrameworkDefault=0` bleiben erhalten. Für eigene Quellen
sind die Ordinalwerte 11 bis 20 vorgesehen; die Frameworkzuordnungen verwenden
1 bis 5.

Neue oder unbekannte Wait Types erhalten über `TVF_WaitTypeInfo` eine
generische Einordnung anhand der ermittelten Wait Group und über
`TVF_WaitTypeSources` transparente generische Definitions-, Mess- und
Interpretationsquellen. Diese Einordnung ist ausdrücklich keine vollständig
kuratierte Detailanalyse.
