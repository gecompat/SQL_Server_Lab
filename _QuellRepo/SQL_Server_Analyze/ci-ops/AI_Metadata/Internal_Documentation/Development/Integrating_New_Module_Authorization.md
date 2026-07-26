# Neue Module in den Ressourcenschutz integrieren

**Stand:** 18. Juli 2026  
**Zielgruppe:** Entwickler neuer Views und Stored Procedures

## 1. Leitfrage

Die interne Berechtigungsschiene wird nur dann benötigt, wenn ein Analysepfad eine relevante zusätzliche Systemlast oder ein erhöhtes Betriebsrisiko besitzt.

Vor der Implementierung ist daher zuerst zu entscheiden:

> Welche Parameterkombination macht den Pfad ressourcenintensiv, und welche Benutzergruppen dürfen diesen Modus ausführen?

SQL-Server-Berechtigungen sind eine getrennte technische Voraussetzung und nicht der primäre Zweck der internen Policy.

## 2. Standard- und Deep-Pfad trennen

Ein Modul soll nach Möglichkeit zwei klar getrennte Pfade besitzen:

- **Standardpfad:** eng begrenzt, niedrige Eigenlast, kein Gruppengate;
- **Deep-Pfad:** explizit angefordert, höheres I/O-/CPU-/Memory-/Locking-Risiko, Gruppengate erforderlich.

Typische Deep-Auslöser:

- `@AnalyseModus = 'VOLL'`;
- `@MaxZeilen = 0` oder `NULL`;
- ungewöhnlich hohe Zeilenlimits;
- mehrere oder alle Datenbanken;
- physische Indexstatistiken;
- XML-Shredding von Showplans oder Extended Events;
- breite Plan-Cache- oder Query-Store-Historie;
- forensische Eventdateien;
- zusätzliche Sampling- oder Wartezeitfenster.

## 3. Bestehende Analyseklasse bevorzugen

```sql
SELECT
      [AnalysisClass]
    , [AnalysisLevel]
    , [RequiresGroupGate]
    , [DefaultMaxRows]
    , [DefaultTimeoutSeconds]
    , [Description]
FROM [monitor].[VW_AnalyseClassCatalog]
ORDER BY [AnalysisLevel], [AnalysisClass];
```

Beispiele:

| Pfad | Klasse |
|---|---|
| begrenzte Plan-Cache-Auswertung | `PLAN_CACHE_CURRENT` |
| vollständiger oder unbegrenzter Plan Cache | `PLAN_CACHE_DEEP` |
| gezielte Showplananalyse | `SHOWPLAN_TARGETED` |
| breites XML-Shredding | `SHOWPLAN_XML_DEEP` |
| physische Indexstatistiken | `PHYSICAL_STATS_DEEP` |
| breite Query-Store-Historie | `QUERY_STORE_DEEP` |
| mehrere Datenbanken | `CROSS_DATABASE_DEEP` |
| Extended-Events-Forensik | `EXTENDED_EVENTS_FORENSICS_DEEP` |

Eine neue Klasse ist nur sinnvoll, wenn Kostenprofil und Freigabegruppe nicht zu einer bestehenden Klasse passen.

## 4. Neue Kostenklasse definieren

Falls erforderlich, `[monitor].[VW_AnalyseClassCatalog]` erweitern.

Pflichtentscheidungen:

- stabiler, case-sensitiver Klassencode;
- `AnalysisLevel`;
- `RequiresGroupGate`;
- konservatives Standardzeilenlimit;
- realistisches Zeitbudget;
- Beschreibung der Eigenlast und Aussagegrenze.

`RequiresGroupGate=1` ist insbesondere für breite Katalog-, Plan-, XML-, Cross-Database-, physische und forensische Pfade vorgesehen.

## 5. Gate vor der teuren Materialisierung

Das Gate muss vor dem ressourcenintensiven Zugriff geprüft werden.

```sql
DECLARE @DeepRequested bit = CASE
    WHEN @AnalyseModus = 'VOLL'
      OR @MaxZeilen IS NULL
      OR @MaxZeilen = 0
      OR @MaxZeilen > 1000
    THEN 1 ELSE 0 END;

DECLARE @Allowed bit = 1;

IF @StatusCode = 'AVAILABLE' AND @DeepRequested = 1
BEGIN
    SELECT @Allowed = COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0)
    FROM [monitor].[VW_AnalyseAccessCurrent]
    WHERE [AnalysisClass] = 'PLAN_CACHE_DEEP';

    IF @Allowed = 0
    BEGIN
        SET @StatusCode = 'DENIED_GROUP';
        SET @ErrorMessage = N'PLAN_CACHE_DEEP ist nicht freigegeben.';
    END;
END;
```

Nicht erst nach dem Scan prüfen. Ein nachträgliches Verwerfen der Daten schützt das System nicht.

## 6. Cross-Database-Pfade

Für Datenbanklisten `[monitor].[USP_PrepareDatabaseCandidates]` verwenden und die korrekte Ressourcenklasse übergeben.

```sql
EXEC [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames                  = @DatabaseNames
    , @SystemdatenbankenEinbeziehen   = @SystemdatenbankenEinbeziehen
    , @DatabaseNamePattern            = @DatabaseNamePattern
    , @AnalysisClass                  = 'CROSS_DATABASE_DEEP'
    , @HighImpactConfirmed            = @HighImpactConfirmed
    , @StatusCode                     = @StatusCode OUTPUT
    , @ErrorMessage                   = @ErrorMessage OUTPUT
    , @CrossDatabaseRequested         = @CrossDatabaseRequested OUTPUT;
```

Die Kandidatenmenge wird nicht vorab gekürzt. Der tatsächlich aktivierte
High-Impact-Pfad benötigt unabhängig von der Gruppenfreigabe eine ausdrückliche
Bestätigung.

## 7. Capability und SQL-Berechtigung ergänzen

Jede neue Systemquelle wird zusätzlich in `[monitor].[VW_FrameworkFeatureCatalog]` beschrieben.

Erforderlich sind:

- `FeatureCode`;
- `ScopeType`;
- `AnalysisClass`;
- Mindestversion;
- Berechtigung vor SQL Server 2022;
- Berechtigung ab SQL Server 2022;
- sichere Prüfart (`HAS_PERMS_BY_NAME` oder `PROBE_ONLY`);
- erwartetes Verhalten ohne Recht;
- eng begrenzte read-only Probe;
- optionaler Featurezustand;
- Aussagegrenze.

Diese Capabilityangaben prüfen technische Nutzbarkeit. Sie ersetzen nicht das Ressourcengate.

## 8. Statuscodes sauber trennen

| Ursache | Status |
|---|---|
| Deep-Pfad nicht für Gruppe freigegeben | `DENIED_GROUP` |
| SQL-Server-Recht fehlt | `DENIED_PERMISSION` |
| Version zu alt | `UNAVAILABLE_VERSION` |
| Feature nicht nutzbar | `UNAVAILABLE_FEATURE` |
| Objekt fehlt | `UNAVAILABLE_OBJECT` |
| Datenbank nicht zugänglich | `DATABASE_UNAVAILABLE` |
| Lock-/Laufzeitlimit | `TIMEOUT` |
| nutzbare Teilansicht | `AVAILABLE_LIMITED` |

Ein allgemeines `ERROR_HANDLED` ist nur für nicht genauer klassifizierbare Fehler zulässig.

## 9. Hilfe und Dokumentation

`@Hilfe=1` muss erklären:

- welcher Parameter den Deep-Pfad aktiviert;
- welche Analyseklasse geprüft wird;
- welche Limits weiterhin gelten;
- dass Gruppenfreigabe keine SQL-Rechte vergibt;
- wie der Zugriff mit `[monitor].[USP_CheckAnalyseAccess]` geprüft wird.

Zu aktualisieren sind:

- Procedure-Header;
- Procedure-Seite;
- Aufrufkatalog;
- Systemquellen- und Capabilityinventar;
- Analyseklasse, falls neu;
- Status- und Berechtigungsaussage;
- Spezialfallmatrix;
- Release-Gate-Vertrag.

## 10. Tests

Mindestens prüfen:

1. begrenzter Standardpfad ohne Gruppenmatch;
2. Deep-Pfad bei offener Policy;
3. Deep-Pfad bei aktiver Policy ohne Match → `DENIED_GROUP`;
4. Deep-Pfad mit Gruppenmatch;
5. sysadmin-Bypass;
6. fehlende SQL-Berechtigung trotz Gruppenmatch → `DENIED_PERMISSION`;
7. hohe und unbegrenzte Limits;
8. Cross-Database-Grenze;
9. Timeout-/Lock-Timeout-Verhalten;
10. RAW, CONSOLE, NONE und JSON;
11. SQL Server 2019, 2022 und 2025;
12. Windows-Token- und AD-Gruppenfall auf einem geeigneten Windows-Ziel.

Linux-SQL-Login-Matrizen ersetzen keinen echten Windows-Gruppentest.

## 11. Review-Checkliste

- [ ] Der Ressourcenverbrauch des neuen Pfads ist beschrieben.
- [ ] Standard- und Deep-Pfad sind getrennt.
- [ ] Das Gate wird vor der teuren Materialisierung geprüft.
- [ ] Eine bestehende Analyseklasse wurde bevorzugt.
- [ ] Gruppenfreigabe entfernt keine Zeilen-, Datenbank- oder Zeitlimits.
- [ ] `DENIED_GROUP` und `DENIED_PERMISSION` sind getrennt.
- [ ] Capabilityprobe ist read-only und leichtgewichtig.
- [ ] Keine realen Umwelt- oder Gruppendaten stehen in Repositoryartefakten.
- [ ] Drei SQL-Versionen und ein Windows-Gruppenszenario sind vorgesehen.

## 12. Verwandte Dokumente

- [Architektur](../Architecture/Authorization_Architecture.md)
- [Administration](../Operations/Authorization_Administration.md)
- [Policy-Beispiele](../Reference/Authorization_Policy_Examples.md)
- [Statusreferenz](../Reference/Authorization_Status_and_Access_Reasons.md)
