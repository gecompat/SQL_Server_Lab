# Runbook: Ein Index scheint ungenutzt

## Erstaufrufe

```sql
EXEC [monitor].[USP_IndexUsage]
      @DatabaseNames=N'[ExampleDatabase]',
      @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_ObjectInventory]
      @DatabaseNames=N'[ExampleDatabase]',
      @ResultSetArt='CONSOLE';
```

## Auswertung

Lesen Sie Resetzeit, Reads, Updates, letzte Nutzung, PK-, Unique- und Constraint-Funktion, Indexdefinition und Größe zusammen mit dem saisonalen Workloadkontext.

## Interpretation

Viele Updates ohne Reads können unnötige Write-/Log-/Lockkosten anzeigen. Das gilt nur über ein belastbares Beobachtungsfenster.

## Gegenprobe

Prüfen Sie Query Store, Plan Cache, Abhängigkeiten, Foreign Keys, seltene Notfall- oder Monatsreports und `USP_IndexOperationalStats` als Gegenproben.

## Nicht ableiten

Löschen Sie keinen Index allein aufgrund von `0 Reads` im sichtbaren Beobachtungsfenster.
