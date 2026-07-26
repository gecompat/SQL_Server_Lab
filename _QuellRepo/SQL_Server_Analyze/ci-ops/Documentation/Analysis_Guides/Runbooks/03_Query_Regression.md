# Runbook: Eine Query ist plötzlich langsamer

## Erstaufruf

```sql
EXEC [monitor].[USP_QueryStoreRegressions]
      @QueryStoreDatabaseNames=N'[ExampleDatabase]',
      @MinAusfuehrungenJeFenster=10,
      @ResultSetArt='CONSOLE';
```

## Auswertung

Vergleichen Sie Baseline- und Vergleichsfenster, Stichprobengröße, absolute Änderung, Prozentänderung, Plananzahl und letzte Ausführung.

## Interpretation

Eine Regression ist belastbar, wenn vergleichbare Workload mit ausreichender Stichprobe im Vergleichsfenster mehr Ressourcen benötigt.

## Gegenprobe

Verwenden Sie `USP_QueryStorePlanChanges`, `USP_QueryStoreWaitStats`, Runtime Stats je Plan und `USP_ShowplanAnalysis` als Gegenproben.

## Nicht ableiten

Forcieren Sie keinen Plan allein aufgrund einer hohen Prozentänderung bei einer einzelnen Ausführung. Prüfen Sie zuvor Unterschiede bei Parametern und Datenmengen.
