# [monitor].[USP_ConfigureSnapshotTarget]

**Bereich:** Optionales Snapshot-/Baseline-Paket SC-023
**Zweck:** Verknüpft die Frameworkdatenbank mit einer separat installierten Snapshot-Datenbank und schreibt Collector-, Retention- und Budgetpolicy typisiert.

Die Procedure erstellt weder Datenbanken noch Rechte oder Schedulerobjekte. Der Aufruf ist erst nach beiden SC-023-Installern sinnvoll. Alle Beispielnamen sind synthetisch.

```sql
EXEC [monitor].[USP_ConfigureSnapshotTarget]
     @TargetDatabaseName = N'ExampleSnapshotDatabase',
     @IsEnabled = 1,
     @SchedulerType = 'EXTERNAL',
     @PayloadEnabled = 0;
```

## Eine Zeile bedeutet

Die Procedure besitzt kein fachliches Resultset. OUTPUT-Status beschreibt genau den atomaren Konfigurationsversuch; die persistierte Singletonzeile bezeichnet das aktive lokale Ziel.

## So lesen

`AVAILABLE` bedeutet, dass die Ziel-Datenbank online, schreibbar und mit dem erwarteten internen Konfigurationsobjekt erreichbar war. `TARGET_UNAVAILABLE` trennt fehlenden Zielkontext von `DENIED_PERMISSION`. `IsEnabled=0` bewahrt vorhandene Historie und verhindert neue Collection Cycles.

## Warum kann das problematisch sein?

Ein falsches Ziel kann reale Laufzeitwerte in einer unerwarteten Datenbank persistieren. Zu lange Retention, aktivierte Payloads oder ein zu großes Zeilenlimit erhöhen Speicher-, Log- und Purgekosten. Der Installer vergibt deshalb absichtlich keine Rechte und aktiviert keinen Job.

## Wann ist es kein Problem?

Eine deaktivierte Konfiguration ist ein gültiger sicherer Zustand. Dokumentierte Beispiele verwenden ausschließlich eindeutige Platzhalter wie `ExampleSnapshotDatabase`; der reale Zielname verbleibt in der geschützten Betriebsdatenbank.

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welches explizite Ziel und welche begrenzte Policy dürfen der schedulerneutrale Collector und der Purge verwenden?

### Technischer Hintergrund

`monitor.SnapshotTargetConfiguration` ist ein typisierter Singleton. Zielseitig bilden `snapshot.CollectorPolicy` und `snapshot.RetentionPolicy` die validierten Optionen ab; ein allgemeiner Key-Value-Speicher ersetzt diese bekannten Felder nicht.

### Datenkette

Framework-Singleton → validierter Drei-Part-Name → `snapshot.InternalConfigureSnapshotPolicy` → typisierte Zielpolicy.

### Source Select

Die bestehende Singleton-Konfiguration wird mit dem sichtbaren Zustand der Zieldatenbank korreliert:

```sql
SELECT
      [c].[TargetDatabaseName]
    , [c].[IsEnabled]
    , [c].[DefaultSchedulerType]
    , [d].[state_desc]
    , [d].[is_read_only]
FROM [monitor].[SnapshotTargetConfiguration] AS [c] WITH (NOLOCK)
LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[name] = [c].[TargetDatabaseName]
WHERE [c].[ConfigurationId] = 1;
```

**Wichtig für die Eigenlast:** Das Lesen ist trivial. Die Procedure ist jedoch ein Konfigurations-Schreibpfad: Sie validiert genau eine Zieldatenbank, aktualisiert zuerst deren Snapshotpolicy und danach die Framework-Singletonzeile in einer Transaktion.

### Zeit- und Scope-Modell

`LastUpdatedUtc` ist UTC. Die Konfiguration gilt für genau die lokale Framework-/Snapshot-Datenbankbeziehung; Fleet-Transport gehört nicht zu SC-023.

### Bewertung und Gegenprobe

Prüfen Sie nach dem Aufruf Zielname, Aktivierungsstatus und Policy in beiden Datenbanken. Starten Sie danach einen manuellen Cycle mit einem begrenzten Zeilenlimit.

### Typische Fehlinterpretation

`AVAILABLE` beweist nicht, dass der Ausführer später alle DMV- und Zielschreibrechte besitzt. Konfiguration und Collection haben getrennte Rechte- und Statuspfade.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_RunSnapshotCollectionCycle`, `USP_PurgeSnapshotData` und der Betriebsleitfaden.

[Technische Detailbeschreibung](../../Operations/Snapshot_Baseline_Operations.md)
