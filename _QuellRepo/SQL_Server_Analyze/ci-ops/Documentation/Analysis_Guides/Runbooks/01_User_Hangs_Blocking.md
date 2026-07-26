# Runbook: Benutzer melden Hänger oder Blocking

## 1. Sicherer Erstaufruf

```sql
EXEC [monitor].[USP_CurrentOverview]
      @MitIO = 0,
      @SampleSeconds = 0,
      @ResultSetArt = 'CONSOLE';
```

## 2. Auswertung

Lesen Sie zuerst die folgenden Informationen gemeinsam:

- den Status der aufgerufenen Teilmodule;
- aktive Requests mit hoher Elapsed Time;
- `BlockingSessionId`, Waittyp und Waitzeit;
- offene Transaktionen;
- den Wiederverwendungsgrund des Transaktionslogs.

## 3. Entscheidungspfad

- Bei einem Lockwait folgt `USP_CurrentBlocking`.
- Bei einem Root Blocker im Zustand `sleeping` oder mit offener Transaktion folgt `USP_CurrentTransactions`.
- Ohne Lockwait bestimmt die Wait-Kategorie, ob die I/O-, Memory-Grant-, CPU- oder Netzwerkanalyse fortgesetzt wird.

## 4. Interpretation

Hohe Laufzeit allein erklärt keinen Hänger. Hohe Laufzeit plus niedrige CPU plus dominierende Lockwartezeit zeigt, dass der Request nicht arbeiten kann.

## 5. Nicht ableiten

Beenden Sie nicht zuerst die Opfer-Sessions. Prüfen Sie den Root Blocker, den betroffenen Geschäftsvorgang, die Rollbackkosten und den sichtbaren Fortschritt.

## 6. Historische Gegenprobe

Verwenden Sie `USP_ExtendedEventsBlockedProcesses` und bei Bedarf die Deadlock- oder Query-Store-Analyse als historische Gegenprobe.
