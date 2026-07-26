# Tool-Hintergrundabfragen und Blocking-Ketten

## Zweck

Interaktive Diagnoseausgaben sollen gewöhnliche Metadaten- und
Vorschlagsabfragen von SSMS Object Explorer, GitHub Copilot und Redgate SQL
Prompt nicht standardmäßig in den Vordergrund stellen. Sie müssen dennoch
gezielt sichtbar und als solche nachvollziehbar bleiben.

Der Filter ist eine **diagnostische Heuristik**. `program_name` wird vom Client
gesetzt und ist weder manipulationssicher noch über alle Produktversionen
stabil. Die Klassifikation darf deshalb niemals für Berechtigungen, Auditing
oder Sicherheitsentscheidungen verwendet werden.

## Öffentlicher Vertrag

`USP_CurrentSessions`, `USP_CurrentRequests`, `USP_CurrentBlocking`,
`USP_CurrentWaits` und `USP_CurrentOverview` besitzen:

```sql
@ToolHintergrundabfragenEinbeziehen bit = 0
```

- `0` blendet erkannte Tool-Hintergrundaktivität standardmäßig aus.
- `1` zeigt sie einschließlich Regelcode, Kategorie, Erkennungsart und
  Konfidenz.
- Die Filterung erfolgt vor SQL-Text-, Modul-, Katalog- und Lockanreicherung.
- Instanzweite aggregierte Wait Stats werden nicht nach Client gefiltert; der
  Parameter betrifft in `USP_CurrentWaits` ausschließlich `currentTasks`.

## Kettenbewahrende Blocking-Semantik

Blocking wird zuerst als vollständige sichtbare Kantenmenge rekonstruiert.
Danach gilt:

- Ist das blockierte Blatt eine erkannte Tool-Hintergrundabfrage, wird diese
  Kette bei Parameterwert `0` nicht ausgegeben.
- Blockiert eine Tool-Session eine normale Abfrage oder liegt sie innerhalb
  deren Kette, bleibt die normale Kette vollständig sichtbar.
- `BlockingChain` enthält die Leserichtung
  `blockierte Session <- direkter Blocker <- ... <- Root Blocker`.
- `RootBlockingSessionId` und die `RootBlocker*`-Spalten beschreiben den ersten
  äußersten Auslöser, soweit er im nicht atomaren Snapshot sichtbar ist.
- `RootBlockerStatementSource` unterscheidet `ACTIVE_REQUEST`,
  `MOST_RECENT_CONNECTION`, `UNAVAILABLE` und `NOT_REQUESTED`. Dadurch bleibt
  bei einem schlafenden Root Blocker nach Möglichkeit auch das zuletzt über die
  Verbindung bekannte Batch sichtbar, ohne es als aktuell laufenden Request
  auszugeben.
- Zyklen und SQL-Server-Sonderblocker `-2` bis `-5` bleiben ausdrücklich
  gekennzeichnet; ein fehlender Root-Request ist bei einer sleeping Session
  normal.

Ein Sessionfilter wird erst auf die rekonstruierte Kette angewandt. Dadurch
bleibt der Root-Kontext erhalten, wenn eine ausgewählte Session irgendwo in der
Kette vorkommt.

## Metadatengetriebene LIKE-Regeln

Die Steuertabelle `[monitor].[ToolBackgroundQueryPattern]` enthält aktivierbare
echte T-SQL-`LIKE`-Muster. Höhere `Priority` gewinnt; bei gleicher Priorität entscheidet
`RuleCode` deterministisch. Ein Muster ohne Wildcards verhält sich wie ein
exakter Vergleich. `%`, `_` und bracket-escaped Zeichen verwenden die normale
T-SQL-`LIKE`-Semantik.

Der Framework-Seed enthält:

| Kategorie | Seed-Muster | Konfidenz |
|---|---|---|
| GitHub Copilot | `Microsoft SQL Server Management Studio - GitHub Copilot` | HIGH; von Microsoft dokumentierter Client-App-Name |
| Copilot Completions | `Microsoft SQL Server Management Studio - Copilot Completions` | HIGH; von Microsoft dokumentierter Client-App-Name |
| SSMS Object Explorer | `Microsoft SQL Server Management Studio - Object Explorer%` | MEDIUM; versionsabhängige `program_name`-Heuristik |
| Redgate SQL Prompt | konservative Herstellerpräfixe mit `%` | MEDIUM; versionsabhängige `program_name`-Heuristik |

Lokale Regeln verwenden `IsFrameworkDefault=0` und bleiben bei einem erneuten
Installerlauf erhalten. Frameworkregeln können über `IsEnabled=0` lokal
deaktiviert werden; der Seed überschreibt diesen Schalter nicht.

Beispiel für eine lokale LIKE-Regel:

```sql
INSERT [monitor].[ToolBackgroundQueryPattern]
(
      [RuleCode], [Priority], [IsEnabled], [ProgramNameLikePattern]
    , [ToolBackgroundCategory], [ToolBackgroundDetection]
    , [ToolBackgroundConfidence], [SourceNotes], [IsFrameworkDefault]
)
VALUES
(
      'LOCAL_METADATA_BROWSER', 900, 1, N'Example Metadata Browser%'
    , 'LOCAL_METADATA_BROWSER', 'LOCAL_PROGRAM_NAME_PATTERN'
    , 'MEDIUM', N'Lokal verifiziertes Clientmuster.', 0
);
```

Prüfen Sie vor der Aufnahme einer lokalen Regel zuerst die realen Werte in der kontrollierten Laufzeitumgebung:

```sql
SELECT [program_name], COUNT_BIG(*) AS [SessionCount]
FROM [sys].[dm_exec_sessions]
WHERE [is_user_process] = 1
GROUP BY [program_name]
ORDER BY [SessionCount] DESC, [program_name];
```

Breite Muster wie `%SQL%` sind ungeeignet, weil sie fachliche Anwendungen
falsch klassifizieren können.

## Grenzen der Produkterkennung

Microsoft dokumentiert die beiden Copilot-Client-App-Namen ausdrücklich. Für
Object Explorer dokumentiert Microsoft die Funktion, aber keinen stabilen
`program_name`-Vertrag. Redgate dokumentiert, dass SQL Prompt Verbindungen und
Metadaten für Vorschläge verwaltet, jedoch keinen versionsübergreifend stabilen
Application Name. Führt ein Add-in seine Abfrage über dieselbe gewöhnliche
SSMS-Query-Verbindung aus, kann es anhand von `program_name` nicht zuverlässig
von einer Benutzerabfrage unterschieden werden; das Framework blendet es dann
bewusst nicht aus.

## Primärquellen

- [Microsoft: Troubleshoot GitHub Copilot in SSMS](https://learn.microsoft.com/en-us/ssms/github-copilot/troubleshoot)
- [Microsoft: Open and Configure Object Explorer](https://learn.microsoft.com/en-us/ssms/object/open-and-configure-object-explorer)
- [Microsoft: Application Name wird als program_name sichtbar](https://learn.microsoft.com/en-us/fabric/data-warehouse/configure-custom-sql-pools-api)
- [Redgate: Managing connections and memory](https://documentation.red-gate.com/sp11/managing-sql-prompt-behavior/managing-connections-and-memory)
