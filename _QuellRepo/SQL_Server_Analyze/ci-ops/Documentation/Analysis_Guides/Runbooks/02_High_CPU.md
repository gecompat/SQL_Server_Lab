# Runbook: CPU ist dauerhaft hoch

## Erstaufrufe

```sql
EXEC [monitor].[USP_CurrentRequests] @Sortierung='CPU', @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_QueryStats] @Sortierung='CPU_TOTAL', @MaxZeilen=50, @ResultSetArt='CONSOLE';
```

## Auswertung

Vergleichen Sie aktuelle CPU, Elapsed Time, Reads, DOP, Ausführungszahl, Total- und Average-CPU sowie Query- und Plan-Hash.

## Interpretation

- Hohe CPU, hohe Reads und wenige Ergebniszeilen sprechen für einen möglicherweise ineffizienten Zugriff.
- Eine niedrige Average-CPU bei sehr vielen Ausführungen kann auf kumulative Last durch häufige kleine Queries hinweisen.
- Hohe CPU ausschließlich während eines kurzen, geplanten Reports kann dem erwarteten Betriebsprofil entsprechen.

## Gegenprobe

Prüfen Sie `USP_QueryHashAnalysis`, `USP_ShowplanAnalysis`, Query Store Runtime Stats sowie den Server-CPU- und NUMA-Kontext als unabhängige Gegenproben.

## Nicht ableiten

Ändern Sie MAXDOP, Cost Threshold oder Indizes nicht allein aufgrund eines einzelnen Parallelitätswaits.
