# Runbook: TempDB wächst oder ist fast voll

## Erstaufrufe

```sql
EXEC [monitor].[USP_CurrentTempDB] @MitDateien=1, @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_TempDBConfiguration] @ResultSetArt='CONSOLE';
```

## Auswertung

Prüfen Sie zuerst die Gesamtauslastung und die Dateien. Unterscheiden Sie anschließend User Objects, Internal Objects und Version Store.

## Interpretation

- Internal Objects einer Session können durch Sort-, Hash-, Spill- oder Worktable-Aktivität entstehen.
- Ein großer Version Store kann mit einer langen Snapshot- oder RCSI-Transaktion zusammenhängen.
- Häufiges Wachstum kann auf unzureichende Vorallokation oder ungeeignete Growth-Einstellungen hinweisen.

## Gegenprobe

Korrelieren Sie die verursachende Session mit `USP_CurrentRequests`, den Version Store mit `USP_CurrentTransactions` und Contention mit `USP_InternalContentionAnalysis`.

## Nicht ableiten

Vergrößern Sie nicht ausschließlich die Dateien, ohne zuvor die Verbrauchsart und den verursachenden Vorgang zu bestimmen.
