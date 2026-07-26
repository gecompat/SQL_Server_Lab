# Status- und AccessReason-Referenz des Ressourcenschutzes

**Stand:** 18. Juli 2026  
**Kanonische Quellen:** `[monitor].[VW_ModuleStatusCatalog]`, `[monitor].[VW_AnalyseAccessCurrent]`

## 1. Zwei getrennte Codebereiche

- `AccessReason` erklärt, warum der interne Ressourcenschutz einen Analysepfad erlaubt oder ausschließt.
- `StatusCode` erklärt, welches technische oder fachliche Ergebnis ein Modul liefert.

Ein positiver Gruppenmatch bedeutet nicht automatisch, dass die benötigten SQL-Server-Rechte vorhanden sind.

## 2. AccessReason

| AccessReason | `IsAllowed` | Bedeutung |
|---|---:|---|
| `NOT_REQUIRED` | 1 | Der Pfad ist nicht als ressourcenintensiv geschützt. |
| `SYSADMIN` | 1 | sysadmin-Bypass. |
| `OPEN_POLICY` | 1 | Keine aktive Whitelist; geschützte Pfade sind offen. |
| `LOGIN_TOKEN` | 1 | Passende Windows-Gruppe im aktuellen Login-Token. |
| `IS_MEMBER` | 1 | Positiver Fallback über `IS_MEMBER`. |
| `NO_MATCH` | 0 | Aktive Whitelist, aber keine passende Gruppenregel. |

Innerhalb der Capability-Prüfung können zusätzlich folgende Sonderwerte auftreten:

| Wert | Bedeutung |
|---|---|
| `OPEN` | Gruppenprüfung wurde nicht angewendet oder noch nicht ausgeführt. |
| `CHECK_ERROR` | Die Ressourcenschutzprüfung selbst ist kontrolliert fehlgeschlagen. |

## 3. Ressourcenschutzstatus

### `DENIED_GROUP`

Der Benutzer ist für den ressourcenintensiven Analysepfad nicht freigegeben.

- Es handelt sich nicht um einen SQL-Server-`DENY`.
- Technische DMV-Rechte können trotzdem vorhanden sein.
- Der teure Pfad soll vor der Materialisierung beendet werden.

### `DENIED_PERMISSION`

Die Ressourcenschutz-Policy erlaubt den Pfad, aber SQL Server verweigert die technische Quelle.

| Status | Ebene |
|---|---|
| `DENIED_GROUP` | interne Ressourcen-Whitelist |
| `DENIED_PERMISSION` | SQL Server Security Engine |

## 4. Weitere relevante Statuscodes

| StatusCode | Bedeutung |
|---|---|
| `AVAILABLE` | Pfad freigegeben und vollständig nutzbar. |
| `AVAILABLE_LIMITED` | Abfrage möglich, Vollständigkeit eingeschränkt. |
| `AVAILABLE_UNVERIFIED` | Probe erfolgreich, Vollständigkeit nicht deklarativ beweisbar. |
| `AVAILABLE_DISABLED` | Quelle erreichbar, Feature deaktiviert. |
| `UNAVAILABLE_VERSION` | Mindestversion nicht erreicht. |
| `UNAVAILABLE_PLATFORM` | Quelle auf dieser Plattform nicht verfügbar. |
| `UNAVAILABLE_FEATURE` | Feature nicht installiert, aktiviert oder nutzbar. |
| `UNAVAILABLE_OBJECT` | System- oder Frameworkobjekt fehlt. |
| `DATABASE_UNAVAILABLE` | Zieldatenbank nicht verfügbar oder nicht sichtbar. |
| `TIMEOUT` | Lock- oder Laufzeitlimit erreicht. |
| `ERROR_HANDLED` | Nicht genauer klassifizierter Fehler wurde isoliert. |
| `INVALID_PARAMETER` | Ungültige oder widersprüchliche Eingabe. |

## 5. Leserichtung

Lesen Sie ein verweigertes oder partielles Ergebnis in der folgenden Reihenfolge:

1. `StatusCode`
2. `IsPartial`
3. `AnalysisClass`
4. `RequiresGroupGate`
5. `IsAllowed`
6. `AccessReason`
7. `RequiredPermission`
8. `HasRequiredPermission`
9. `IsQueryable`
10. `ErrorNumber` und `ErrorMessage`

## 6. Aussagegrenzen

Ein positiver Gruppenmatch beweist nicht:

- vollständige DMV-Sicht;
- vorhandene SQL-Berechtigungen;
- aktiviertes Feature;
- verfügbare Plattformquelle;
- Einhaltung des Zeitbudgets.

Ein leerer Resultset beweist nicht:

- dass keine Daten existieren;
- dass vollständige Sicht besteht;
- dass der Benutzer den Deep-Pfad tatsächlich ausführen durfte.

## 7. Diagnoseaufrufe

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse = 'PLAN_CACHE_DEEP'
    , @ResultSetArt  = 'RAW';
```

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames      = N''
    , @AnalyseKlasse      = 'PLAN_CACHE_DEEP'
    , @MitGruppenpruefung = 1
    , @NurNichtVerfuegbar = 1
    , @ResultSetArt       = 'RAW';
```

## 8. Verwandte Dokumente

- [Architektur](../Architecture/Authorization_Architecture.md)
- [Administration](../Operations/Authorization_Administration.md)
- [Fehlersuche](../Operations/Authorization_Troubleshooting.md)
