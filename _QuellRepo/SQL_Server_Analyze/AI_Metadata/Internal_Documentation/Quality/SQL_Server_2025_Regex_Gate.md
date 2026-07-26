# SQL-Server-2025-Regex-Gate

**Stand:** 18. Juli 2026  
**Workflow:** `.github/workflows/sqlserver-2025-linux-release-gate.yml`  
**Test:** `Code/Tests/VersionAdaptive/120_SQL_Server_2025_Regex_Matrix.sql`
**Statischer Validator:** `Code/Tests/Static/920_Validate_SQL_Server_2025_Regex.py`

## Zweck

Das Regex-Gate ergänzt das allgemeine SQL-Server-2025-Linux-Release-Gate um einen expliziten Laufzeitvertrag für die SQL-Server-2025-Regex-Funktionen und die frameworkweiten Patternpräfixe `regex:` und `regexi:`.

Der Test läuft ausschließlich gegen eine synthetische SQL-Server-2025-Developer-Instanz unter Linux. Die Installationsdatenbank verwendet Compatibility Level 170 und die Collation `SQL_Latin1_General_CP1_CS_AS`.

## Statische Schutzprüfung

Vor dem Containerlauf durchsucht der Workflow alle T-SQL-Dateien unter `Code/` nach ungültigen Skalarvergleichen mit `REGEXP_LIKE`. Der Validator arbeitet über Dateigrenzen hinweg jeweils auf dem vollständigen Dateiinhalt und erkennt deshalb auch mehrzeilige Aufrufe und verschachtelte Argumentausdrücke. SQL-Zeilen- und Blockkommentare werden ausgeblendet.

Nicht zulässig sind insbesondere:

```sql
REGEXP_LIKE(...) = 0
REGEXP_LIKE(...) = 1
REGEXP_LIKE(...) <> 0
REGEXP_LIKE(...) <> 1
REGEXP_LIKE(...) != 0
REGEXP_LIKE(...) != 1
```

`REGEXP_LIKE` wird in SQL Server 2025 als Prädikat verwendet. Die korrekten Formen sind:

```sql
WHERE REGEXP_LIKE([Spalte], @Pattern, @Flags)
```

und für die Negation:

```sql
WHERE NOT REGEXP_LIKE([Spalte], @Pattern, @Flags)
```

Die Prüfung verhindert, dass erneut syntaktisch ungültige Regex-Pfade in das Repository aufgenommen werden. Ihre acht generischen Selbsttests decken gültige positive und negierte Prädikate, auskommentierte Beispiele sowie direkte, mehrzeilige, verschachtelte und dynamische Fehlformen ab. Ein Trefferbericht enthält nur Regelcode, Repositorypfad, Zeilennummer und Anzahl, niemals die betroffene Quellzeile.

## Laufzeitverträge

Die Matrix prüft getrennt:

1. einen direkten positiven Treffer mit `REGEXP_LIKE`;
2. einen case-sensitiven Nichttreffer;
3. einen case-insensitiven Treffer mit dem `varchar`-Flag `'i'`;
4. das Parsing von `regex:` durch `[monitor].[TVF_ParsePattern]`;
5. das Parsing von `regexi:` einschließlich des `i`-Flags;
6. einen Regex-Filter in `[monitor].[USP_CurrentSessions]`;
7. einen Regex-Filter in `[monitor].[USP_ExtendedEventsSessions]`;
8. das kontrollierte Feature-Gate bei Compatibility Level 160;
9. die Wiederherstellung von Compatibility Level 170;
10. die erneute Regex-Verfügbarkeit nach der Wiederherstellung.

Die abschließende generische Statuszeile meldet deshalb `ExecutedContracts=10`.

## Feature-Gate

Die Matrix senkt den Compatibility Level der ausschließlich synthetischen Testdatenbank kurzzeitig von 170 auf 160.

In diesem Zustand müssen Regex-Aufrufe der geprüften Framework-Procedures kontrolliert den Status `UNAVAILABLE_FEATURE` liefern. Es darf kein dynamisches SQL mit `REGEXP_LIKE` ausgeführt werden.

Sowohl im normalen Ablauf als auch im Fehlerpfad wird Compatibility Level 170 wiederhergestellt. Anschließend wird `REGEXP_LIKE` erneut direkt geprüft.

## Berechtigungsabgrenzung

Die Regex-Matrix läuft nach der versionsparametrisierten SQL-Server-2022+-Berechtigungsmatrix. Damit bleiben folgende Verträge getrennt:

- Berechtigungsmatrix: Server-/Datenbank-State-Rechte, Gruppenpolicy und sysadmin-Bypass;
- Regex-Matrix: Featureverfügbarkeit, Patternparser und Regex-Consumer.

SQL Server 2025 kann fehlende Performance-State-Rechte über External-Policy-Berechtigungsfehler melden. Diese werden durch die Framework-Procedures kontrolliert als `DENIED_PERMISSION` klassifiziert und dürfen den Regex-Vertrag nicht als allgemeinen Laufzeitfehler verfälschen.

## Datenschutz und Sicherheit

- Alle Testwerte und Principalnamen sind eindeutig synthetisch.
- Kennwörter entstehen ausschließlich zur Laufzeit und werden maskiert.
- Der Repositorybestand wird nur in einer temporären Runnerkopie angepasst.
- Der Container erhält die Codekopie schreibgeschützt.
- Vollständige SQLCMD-Ausgaben werden nicht dauerhaft gespeichert.
- Fehlerzusammenfassungen werden höchstens einen Tag aufbewahrt.
- Der Container wird auch bei Fehlern entfernt.

## Erfolgsbedingung

Der SQL-Server-2025-Workflow ist nur erfolgreich, wenn alle folgenden Schritte bestehen:

- statische Regex-Prädikatprüfung;
- Versions- und Collation-Readiness;
- vollständiger Installer;
- allgemeines 34-Suite-Release-Gate einschließlich aller P0-/P1-/P2- sowie Datenbank-, CONSOLE- und TABLE-Ausgabeverträge;
- SQL-Server-2025-Berechtigungsmatrix;
- SQL-Server-2025-Regex-Matrix;
- generische Erfolgszusammenfassung;
- Container-Cleanup.

Das Linux-Gate ersetzt keine Windows-, AD-Gruppen-, produktionsnahe Last- oder optionalen Feature-Positivtests.
