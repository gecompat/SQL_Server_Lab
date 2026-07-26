# FWK-001 – Preflight-Vertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | alle ausführbaren Demos |
| Referenzimplementierung | `../Templates/00_Preflight.sql` |

## 1. Zweck

Der Preflight entscheidet vor jeder zustandsverändernden oder ressourcenrelevanten Operation, ob die Demo unter den angegebenen Voraussetzungen sicher und fachlich interpretierbar ausgeführt werden kann. Er verändert keine Instanz- oder Datenbankkonfiguration und persistiert keine Umgebungsinformationen.

Die Prüfung ist nicht auf die Produktversion beschränkt. Engine-Version, Compatibility Level, Edition beziehungsweise Engine Edition, Datenbankzustand, erforderliche Berechtigungen, Sicherheitsfreigaben und optionaler Ressourcenbedarf werden getrennt bewertet.

## 2. Verbindliche Eingaben

Jede Demo setzt im Preflight mindestens folgende Werte:

| Eingabe | Bedeutung |
|---|---|
| `@DemoId` | kanonische Demo-ID |
| `@SafetyLevel` | `GREEN`, `YELLOW` oder `RED` |
| `@MinimumMajorVersion` / `@MaximumMajorVersion` | unterstützte Engine-Hauptversion |
| `@MinimumCompatibilityLevel` / `@MaximumCompatibilityLevel` | unterstützte Datenbank-Compatibility-Level |
| `@TargetDatabase` | erwartete synthetische Testdatenbank, sofern vorhanden |
| Berechtigungsflags | nur tatsächlich benötigte Server- und Datenbankberechtigungen |
| Sicherheitsbestätigungen | abhängig von `FWK-008` |
| Ressourcenlimits | nur wenn die Kernaussage eine definierte Mindest- oder Maximalressource benötigt |

Nicht benötigte Prüfungen bleiben deaktiviert. Ein Preflight darf keine pauschalen Administratorrechte verlangen, wenn eine engere Berechtigung ausreicht.

## 3. Prüfreihenfolge

1. Vertrags- und Parameterkonsistenz.
2. unterstützte SQL-Server-Engine und Engine Edition.
3. Ziel-Datenbankzustand und Compatibility Level.
4. erforderliche Berechtigungen.
5. Sicherheitsfreigaben gemäß `FWK-008`.
6. optionaler Ressourcen- und Freispeichercheck.
7. konsolidiertes Ergebnis gemäß `FWK-012`.

Die Reihenfolge verhindert, dass ein späterer Check bereits voraussetzt, was ein früherer Check erst bestätigen soll.

## 4. Pflichtprüfungen

### 4.1 Engine und Plattform

Die unterstützten Hauptversionen sind 15, 16 und 17 für SQL Server 2019, 2022 und 2025. Die Referenzimplementierung verwendet `SERVERPROPERTY` und parst keine zusammengesetzte `@@VERSION`-Zeichenfolge.

Die Schulungsdemos richten sich an eine SQL-Server-Instanz beziehungsweise einen entsprechenden Container. Andere Engine Editions erhalten einen kontrollierten `SKIP_PLATFORM`, solange eine Demo sie nicht ausdrücklich unterstützt.

### 4.2 Datenbank

Wenn eine Ziel-Datenbank erforderlich ist, werden mindestens Existenz, `ONLINE`-Status, Schreibbarkeit und Compatibility Level aus `sys.databases` geprüft. Eine fehlende Setup-Datenbank ist `FAIL_STATE`; ein fachlich nicht unterstütztes Compatibility Level ist `SKIP_COMPATIBILITY_LEVEL`.

### 4.3 Berechtigungen

Berechtigungen werden mit `HAS_PERMS_BY_NAME` oder einer gleichwertigen dokumentierten Prüfung bewertet. Fehlende optionale Diagnoseberechtigungen führen zu `SKIP_PERMISSION`, nicht zu einer behaupteten fachlichen Fehlfunktion der Engine.

SQL Server 2022 und neuer können für bestimmte DMVs `VIEW SERVER PERFORMANCE STATE` anstelle älterer, weiter gefasster Berechtigungen verlangen. Die Demo benennt exakt die von ihr verwendeten Objekte und prüft nur die dafür dokumentierte Berechtigung.

### 4.4 Ressourcen

Ein Freispeicherwert ist nur belastbar, wenn der tatsächlich verwendete Daten- oder Logdateipfad gemessen wird. Ein Wert eines anderen Volumes darf höchstens als `WARN` ausgegeben werden. Ressourcenprüfungen sind optional und müssen ihre Messbasis nennen.

## 5. Ergebnisvertrag

Jeder Check liefert dieselben Spalten:

```text
Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
```

`Outcome` verwendet ausschließlich `PASS`, `WARN`, `SKIP` oder `FAIL`. Codes stammen aus `FWK-012`.

Ein oder mehrere `FAIL`-Ergebnisse beenden den Batch nach Ausgabe aller Prüfergebnisse mit `THROW`. Ein kontrollierter `SKIP` beendet den Preflight ohne technische Fehlermeldung; der spätere Test-Harness wertet den Summary-Datensatz aus.

## 6. Datenschutz

Der Standardwert für `@EmitEnvironmentDetails` ist `0`. Dadurch werden keine Server-, Host-, Instanz-, Pfad- oder Benutzerkennungen ausgegeben. Diagnostisch notwendige Werte dürfen interaktiv angezeigt, aber nicht als Repository-Artefakt persistiert werden.

## 7. Abnahmekriterien

`FWK-001` ist implementiert, wenn die Referenzvorlage:

- Version, Plattform, Ziel-Datenbank, Compatibility Level, Berechtigung und Sicherheitsfreigabe getrennt prüft,
- ausschließlich die Status- und Fehlercodes aus `FWK-012` verwendet,
- keine Konfiguration verändert,
- Umgebungsdetails standardmäßig unterdrückt,
- bei `FAIL` erst nach Ausgabe der vollständigen Prüftabelle abbricht.

## 8. Primärquellen

Abgerufen am 24. Juli 2026:

- [SERVERPROPERTY (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17)
- [sys.databases (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17)
- [HAS_PERMS_BY_NAME (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/functions/has-perms-by-name-transact-sql?view=sql-server-ver17)
