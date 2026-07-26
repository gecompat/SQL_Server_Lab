# Runbook: Memory Grants warten

## Erstaufrufe

```sql
EXEC [monitor].[USP_CurrentMemoryGrants] @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_ServerMemory] @ResultSetArt='CONSOLE';
```

## Auswertung

Lesen Sie Requested, Granted, Used, Waitzeit, Warteschlangenlänge und DOP zusammen mit der aktuellen Konkurrenz sowie dem OS- und SQL-Memory-Pressure.

## Interpretation

`Granted=0` plus lange `RESOURCE_SEMAPHORE`-Wartezeit bedeutet, dass die Query noch nicht mit ihrer Hauptarbeit beginnen konnte.

## Gegenprobe

Korrelieren Sie Request und Plan über `USP_CurrentRequests` und `USP_ShowplanAnalysis`. Prüfen Sie außerdem Estimate versus Actual und Memory Grant Feedback.

## Nicht ableiten

Erhöhen Sie `max server memory` nicht automatisch. Prüfen Sie zunächst Konkurrenz, Schätzfehler, DOP und übergroße Grants.
