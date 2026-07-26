# Fehlersuche im internen Ressourcenschutz

**Stand:** 18. Juli 2026

## 1. Diagnose in fester Reihenfolge

Vergeben Sie bei einem verweigerten, leeren oder partiellen Ergebnis nicht unmittelbar zusätzliche SQL-Rechte. Prüfen Sie zuerst die folgenden Ebenen:

1. Wurde überhaupt ein ressourcenintensiver Modus angefordert?
2. Welche `AnalysisClass` gilt für diesen Modus?
3. Erlaubt die Gruppen-Whitelist den Pfad?
4. Unterstützt die SQL-Server-Version die Quelle?
5. Ist das Feature oder Objekt vorhanden?
6. Besitzt der Login die technische SQL-Berechtigung?
7. Wurde ein Zeit-, Lock-, Zeilen- oder Datenbanklimit erreicht?

## 2. Basissammlung

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'RAW';
```

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames      = N''
    , @MitGruppenpruefung = 1
    , @NurNichtVerfuegbar = 1
    , @ResultSetArt       = 'RAW';
```

Werten Sie reale Login-, Gruppen-, Server-, Datenbank- oder Objektwerte nur kontrolliert aus. Exportieren oder übermitteln Sie diese Werte nicht ungeprüft.

## 3. `DENIED_GROUP`

### Bedeutung

Die interne Ressourcen-Whitelist schließt den Benutzer vom Deep-Pfad aus. Dies ist kein SQL-Server-`DENY`.

### Prüfen

```sql
SELECT
      [AnalysisClass]
    , [RequiresGroupGate]
    , [IsAllowed]
    , [AccessReason]
    , [ActivePolicyCount]
    , [RelevantPolicyCount]
    , [MatchedGroupCount]
FROM [monitor].[VW_AnalyseAccessCurrent]
WHERE [IsAllowed] = 0
ORDER BY [AnalysisClass];
```

### Häufige Ursachen

- aktive Policy vorhanden, aber keine Regel für die Klasse;
- kein `*`-Fallback;
- Gruppenname passt nicht zum Login-Token;
- `IsEnabled` ist nicht `1`;
- UTC-Gültigkeitsfenster ist nicht aktiv;
- Windows-Gruppenmitgliedschaft wurde nach dem Login geändert;
- Analyseklasse ist case-sensitiv falsch geschrieben.

### Maßnahme

Prüfen Sie die Policy und das Login-Token. Erweitern Sie DMV-Rechte nicht ohne eine fachliche und sicherheitsbezogene Prüfung.

## 4. `DENIED_PERMISSION`

### Bedeutung

Der Benutzer ist intern für den Ressourcenpfad freigegeben, aber SQL Server verweigert die technische Quelle.

Relevante Felder:

- `RequiredPermissionScope`
- `PermissionCheckType`
- `RequiredPermission`
- `HasRequiredPermission`
- `IsQueryable`
- `ErrorNumber`
- `ErrorMessage`

Typische Rechte:

- SQL Server 2019: `VIEW SERVER STATE`, `VIEW DATABASE STATE`;
- SQL Server 2022/2025: `VIEW SERVER PERFORMANCE STATE`, `VIEW DATABASE PERFORMANCE STATE`.

Das Framework vergibt diese Rechte nicht.

## 5. `OPEN_POLICY`, obwohl ein Ausschluss erwartet wurde

Mögliche Ursachen:

- Policyview liefert keine aktive Zeile;
- alle Zeilen sind deaktiviert;
- alle Regeln liegen außerhalb des UTC-Fensters;
- `AnalysisClass` oder `ADGroupName` ist leer;
- falsche Installationsdatenbank wird abgefragt.

```sql
SELECT *
FROM [monitor].[VW_AnalyseAccessPolicy]
ORDER BY [Priority], [AnalysisClass], [ADGroupName];
```

## 6. `NO_MATCH` trotz erwarteter Mitgliedschaft

Token lokal prüfen:

```sql
SELECT [name], [type], [usage]
FROM [sys].[login_token]
WHERE [type] = N'WINDOWS GROUP'
ORDER BY [name];
```

Fallback mit synthetischem Beispiel:

```sql
SELECT IS_MEMBER(N'ExampleDomain\SqlMonitorDeep') AS [IsSyntheticExampleMember];
```

Maßnahmen:

- Verbindung vollständig neu aufbauen;
- Domain- und Gruppenname lokal prüfen;
- verschachtelte Gruppen und Tokenaufbau prüfen;
- integrierte Windows-Authentifizierung sicherstellen.

Bei SQL-Logins liefert `IS_MEMBER` typischerweise `NULL`; daraus entsteht kein positiver Match.

## 7. Eine Policyzeile sperrt unerwartet andere Deep-Klassen

Dies ist die vorgesehene Whitelistsemantik. Sobald irgendeine aktive Policyzeile existiert, benötigen alle geschützten Klassen einen passenden Klassen- oder `*`-Match.

Lösungen:

- Regeln für alle gewünschten Klassen ergänzen;
- bewusstes `*`-Fallback ergänzen;
- zur leeren offenen Policy zurückkehren.

`Priority` löst das Problem nicht, da sie keine Allow-/Deny-Reihenfolge steuert.

## 8. Begrenzter Standardpfad funktioniert, Deep-Pfad nicht

Dies kann korrekt sein.

Viele Procedures schützen nur teure Parameterkombinationen. Beispiel:

- `TOP` mit engem Limit: ungeschützter Standardpfad;
- `VOLL`, unbegrenzt oder hohes Limit: geschützte Deep-Klasse.

Procedure-Hilfe prüfen:

```sql
EXEC [monitor].[USP_QueryStats] @Hilfe = 1;
```

## 9. `AVAILABLE_LIMITED`

Die Quelle ist nutzbar, aber nicht vollständig.

Mögliche Ursachen:

- eingeschränkte DMV-Sicht;
- optionale Unterquelle nicht verfügbar;
- einzelner Child-Pfad gesperrt;
- Capability nur per Probe bewertbar;
- Teilpfad wegen Limit oder Featurezustand ausgelassen.

Ein leerer Resultset mit `AVAILABLE_LIMITED` ist kein Abwesenheitsbeweis.

## 10. `CHECK_ERROR`

Die Auswertung der Ressourcenschutz-View ist selbst fehlgeschlagen.

Prüfen:

- Existenz und Kompilierbarkeit der Policyviews;
- Lesbarkeit von `[sys].[login_token]`;
- Spaltenvertrag der lokal angepassten Policyview;
- Collation- und Typkompatibilität.

Ein `CHECK_ERROR` darf keinen Deep-Pfad freigeben.

## 11. sysadmin-Bypass unerwartet

```sql
SELECT
      ORIGINAL_LOGIN() AS [OriginalLogin]
    , SUSER_SNAME() AS [EffectiveLogin]
    , IS_SRVROLEMEMBER(N'sysadmin') AS [IsSysadmin];
```

Mögliche Ursachen:

- `EXECUTE AS` verändert den effektiven Kontext;
- anderer Connection-Pool oder Credential-Kontext;
- Login ist tatsächlich sysadmin.

## 12. Freigabe führt trotzdem zu hoher Systemlast

Die Gruppenfreigabe hebt Schutzlimits nicht auf.

Prüfen:

- `@MaxZeilen`;
- `@HighImpactConfirmed` und tatsächlich aktivierte Analyseklasse;
- Analysemodus;
- Samplingdauer;
- Lock-Timeout;
- Defaultwerte aus `[monitor].[VW_AnalyseClassCatalog]`;
- tatsächliche Filterselektivität.

Ein erlaubter Deep-Pfad muss weiterhin begrenzt und gezielt aufgerufen werden.

## 13. Sichere Supportinformationen

Ausreichend sind:

- synthetischer Zielcode;
- SQL-Server-Hauptversion;
- `AnalysisClass`;
- angeforderter Analysemodus;
- `StatusCode`;
- `AccessReason`;
- `RequiredPermission`;
- `HasRequiredPermission`;
- technische Fehlernummer;
- Angabe, ob eine neue Anmeldung verwendet wurde.

Übernehmen Sie die folgenden Informationen nicht in ungeschützte Berichte, Tickets oder Downloads:

- reale Login- und Gruppennamen;
- Server-, Instanz-, Domain- oder Datenbanknamen;
- interne Objektbezeichnungen;
- SQL- oder Plantexte;
- ungeprüfte Screenshots und Logs.

## 14. Verwandte Dokumente

- [Architektur](../Architecture/Authorization_Architecture.md)
- [Administration](Authorization_Administration.md)
- [Statusreferenz](../Reference/Authorization_Status_and_Access_Reasons.md)
