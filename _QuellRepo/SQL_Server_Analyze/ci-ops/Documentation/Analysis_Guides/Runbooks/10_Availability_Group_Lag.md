# Runbook: Availability Group hat Lag

## Erstaufrufe

```sql
EXEC [monitor].[USP_AvailabilityGroups] @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_AvailabilityDeepAnalysis] @ResultSetArt='CONSOLE';
```

## Auswertung

Lesen Sie Rolle, Availability Mode, Synchronization State, Send Queue, Redo Queue, Lagtrend und Connected State gemeinsam.

## Interpretation

Wachsende Send Queue weist eher auf Primär-/Transportpfad hin; wachsende Redo Queue eher auf Secondary-I/O/CPU/Redo.

## Gegenprobe

Prüfen Sie Performance Counter, Storage, Netzwerk, Cluster und Logerzeugungsrate als Gegenproben.

## Nicht ableiten

Führen Sie kein Failover allein aufgrund eines einzelnen Queue-Snapshots aus. Prüfen Sie RPO, Trend sowie Datenverlust- und Rollbackrisiko.
