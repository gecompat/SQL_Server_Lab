# [monitor].[USP_FrameworkUsageFromQueryStore]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Zeigt, welche Framework-Procedures tatsächlich aufgerufen wurden.<br>
**Beobachtungsart:** Query-Store-Katalogsnapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Diese Procedure ist passend, wenn die konkrete Betriebsfrage lautet: **Welche
meiner installierten Framework-Procedures verwende ich tatsächlich, wie oft
und mit welcher Laufzeit?** Sie liefert ein Nutzungsinventar aus dem Query
Store der Installationsdatenbank ohne eigene Datenerfassung. Sie ist hilfreich
bei:

- Einarbeitung: Welche Procedures nutzt das Team bereits?
- Kapazität: Welche Procedures erzeugen die meiste Last?
- Aufräumen: Welche Procedures wurden nie aufgerufen?
- Vergleich: Wie hat sich die Nutzung über die Zeit verändert?

## Nicht beantwortete Fragen

- Kein Nutzungsdaten-Schreiben: Die Procedure liest ausschließlich aus
  bestehenden Query-Store-Daten. Ist der Query Store deaktiviert oder frisch
  bereinigt, erscheint kein Ergebnis.
- Keine Benutzer-Attribution: Es ist nicht erkennbar, wer eine Procedure
  aufgerufen hat.
- Kein Erfolgs-/Fehlerstatus: Nur Ausführungen werden gezählt, nicht ob
  diese erfolgreich waren.
- Keine externen Aufrufe: Nur Ausführungen innerhalb der
  Installationsdatenbank sind sichtbar.

## Voraussetzungen

- Query Store muss in der Installationsdatenbank aktiviert sein
  (`ALTER DATABASE ... SET QUERY_STORE = ON`).
- Mindestens READ-Berechtigung auf die Query-Store-Systemsichten.
- Je nach Retention-Einstellung sind ältere Aufrufe möglicherweise
  nicht mehr enthalten.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_FrameworkUsageFromQueryStore];
```

Dieser Aufruf zeigt die Top 100 meistgenutzten Procedures.

## Parameter

| Parameter | Typ | Default | Bedeutung |
|---|---|---|---|
| `@MaxZeilen` | int | 100 | Maximale Ergebniszeilen. 0/NULL = alle. Negativ = ungültig. |
| `@MinAusfuehrungen` | bigint | 1 | Mindestanzahl Ausführungen für die Aufnahme ins Ergebnis. |
| `@ZeitraumTage` | int | NULL | Einschränkung auf die letzten N Tage. NULL = gesamter QS-Inhalt. |
| `@ResultSetArt` | varchar(16) | CONSOLE | CONSOLE, RAW, NONE. |
| `@Json` | nvarchar(max) OUTPUT | NULL | Optionale JSON-Ausgabe. |

## Resultset und Leserichtung

| Spalte | Bedeutung |
|---|---|
| `ProcedureName` | Name der Framework-Procedure (ohne Schema). |
| `ExecutionCount` | Gesamtzahl der Ausführungen im gewählten Zeitraum. |
| `LastExecutionTime` | Letzter Ausführungszeitpunkt (UTC). |
| `AvgDurationMs` | Durchschnittliche Laufzeit in Millisekunden. |
| `AvgCpuMs` | Durchschnittliche CPU-Zeit in Millisekunden. |
| `AvgLogicalReads` | Durchschnittliche logische Reads. |
| `AvgMemoryGrantKB` | Durchschnittlicher Memory Grant in KB. |
| `PlanCount` | Anzahl verschiedener Ausführungspläne. |
| `QueryCount` | Anzahl verschiedener Queries (Statements). |
| `FirstSeen` | Erste erfasste Ausführung. |
| `LastSeen` | Letzte erfasste Ausführung. |

## So lesen

1. **ExecutionCount:** Hohe Werte zeigen die Kern-Procedures des Teams.
2. **PlanCount > 1:** Deutet auf Parameter-Sensitivität oder Recompiles hin.
3. **AvgDurationMs vs. AvgCpuMs:** Große Differenz deutet auf Wartezeiten.
4. **LastSeen weit zurück:** Procedure wird möglicherweise nicht mehr benötigt.
5. **Fehlende Procedure:** Wurde im gewählten Zeitraum nicht aufgerufen.

## Warum kann das problematisch sein?

Eine nie genutzte Procedure kann auf ungenügende Einarbeitung, fehlenden
Bedarf oder ein unbekanntes Feature hinweisen. Eine extrem häufig genutzte
Procedure mit hoher Laufzeit kann ein Kandidat für Optimierung sein.

## Wann ist es kein Problem?

Viele Procedures werden nur situativ benötigt (z.B. Deadlock-Analyse).
Eine geringe Nutzung ist bei Spezialmodulen normal und kein Defekt.

## Beispielaufrufe

```sql
-- Top 10 meistgenutzte Procedures der letzten 30 Tage
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @ZeitraumTage = 30
    , @MaxZeilen = 10;

-- Alle Procedures mit mindestens 50 Ausführungen
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @MinAusfuehrungen = 50
    , @MaxZeilen = 0;

-- Nutzung der letzten 7 Tage als JSON
DECLARE @UsageJson nvarchar(max);
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @ZeitraumTage = 7
    , @ResultSetArt = 'NONE'
    , @Json = @UsageJson OUTPUT;
SELECT @UsageJson;
```

## Leere oder partielle Ausgabe

Ein leeres Ergebnis kann bedeuten:

- Query Store ist deaktiviert (`UNAVAILABLE_FEATURE`).
- Keine Framework-Procedure wurde im gewählten Zeitraum ausgeführt.
- `@MinAusfuehrungen` ist höher als die tatsächliche Nutzung.
- Query Store Retention hat ältere Daten bereits bereinigt.

Prüfen Sie zuerst `StatusCode` und den Query-Store-Zustand mit
`USP_QueryStoreStatus` oder
`SELECT * FROM sys.database_query_store_options`.

## Zeit- und Scope-Modell

Die Daten stammen aus dem Query Store der Installationsdatenbank. Der
sichtbare Zeitraum hängt von der Retention-Konfiguration und dem
Capture-Modus ab. Nach einem `ALTER DATABASE ... CLEAR PROCEDURE_CACHE`
oder `sp_query_store_flush_db` kann sich der sichtbare Stand ändern.

## Nächster Schritt

Verwenden Sie `USP_CheckFrameworkCapabilities` um festzustellen, welche
Module auf der aktuellen Instanz überhaupt nutzbar sind. Kombinieren Sie
die Nutzungsdaten mit dem Capability-Status, um blinde Flecken zu
identifizieren.

## Weiterführend

- [Versionsadaptive Analysen](../09_Version_Adaptive.md)
- [Scope und Grenzen](../../Reference/Scope_and_Limitations.md)
- [Query Store Leitfaden](../05_Query_Store.md)
