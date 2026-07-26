# Runbook: I/O-Latenz ist hoch

## Erstaufrufe

```sql
EXEC [monitor].[USP_CurrentIO] @SampleSeconds=10, @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_CurrentWaits] @SampleSeconds=5, @ResultSetArt='CONSOLE';
```

## Auswertung

Bewerten Sie die Sample-Latenz und nicht nur den kumulativen Durchschnitt. Lesen Sie Operationen, Bytes, Dateiart, PAGEIOLATCH- beziehungsweise WRITELOG-Waits und betroffene Requests gemeinsam.

## Interpretation

Hohe Latenz bei vielen aktuellen Operationen plus passende Waits zeigt unmittelbare Workloadauswirkung.

## Gegenprobe

Verwenden Sie `USP_DatabaseCapacityAnalysis`, Query Reads, Backup- und Logaktivität sowie externes Storage-Monitoring als Gegenproben.

## Nicht ableiten

Bewerten Sie weder eine einzelne langsame Operation noch einen alten kumulativen Durchschnitt als Nachweis eines Storageausfalls.
