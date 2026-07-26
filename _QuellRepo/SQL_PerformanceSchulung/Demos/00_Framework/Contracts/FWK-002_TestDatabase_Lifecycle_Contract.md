# FWK-002 – Namens-, Schutz- und Lifecycle-Vertrag für Testdatenbanken

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | synthetische Schulungsdatenbanken |
| Referenzimplementierung | `../Sql/FWK_TestDatabaseLifecycle.sql` |

## 1. Zweck

Der Lifecycle-Vertrag verhindert, dass Setup oder Cleanup eine fremde Datenbank verändert oder entfernt. Eine Datenbank gilt nur dann als Eigentum einer Demo, wenn ihr Name dem kanonischen Schema entspricht und die vollständigen Datenbankmarker mit Demo-ID und Run-Token übereinstimmen.

Ein passender Name allein ist niemals ein ausreichender Löschgrund.

## 2. Kanonisches Namensschema

```text
SQLPERF_LAB_<DEMO-ID OHNE BINDESTRICH>_<RUN-TOKEN>
```

Beispiel mit ausschließlich synthetischen Werten:

```text
SQLPERF_LAB_QRY001_LOCAL
```

Regeln:

- Demo-ID: genau ein kanonisches Präfix aus `STL`, `OPT`, `QRY`, `IDX`, `CON`, `RES` oder `DGN` und drei Ziffern.
- Run-Token: 1 bis 16 Zeichen, ausschließlich `A-Z` und `0-9`.
- Der Datenbankname wird aus Demo-ID und Run-Token abgeleitet und nicht frei eingegeben.
- Systemdatenbanken und Datenbanken mit `database_id <= 4` sind ausgeschlossen.

`FWK-*` bezeichnet Framework-Arbeitspakete und erzeugt keine fachliche Testdatenbank. `INF-*` beschreibt Bereitstellung und ist ebenfalls kein Datenbankpräfix.

## 3. Eigentumsmarker

Die Referenzimplementierung schreibt folgende Extended Properties auf Datenbankebene:

| Property | Wert |
|---|---|
| `SQLPERF.Project` | `SQL_PerformanceSchulung` |
| `SQLPERF.ContractVersion` | `1.0` |
| `SQLPERF.DemoId` | kanonische Demo-ID |
| `SQLPERF.RunToken` | normalisierter Run-Token |
| `SQLPERF.CreatedUtc` | UTC-Zeitpunkt im ISO-8601-Format |

Vor `VALIDATE` und `DROP` müssen Projekt, Vertragsversion, Demo-ID und Run-Token vollständig übereinstimmen. Ein fehlender, nicht lesbarer oder abweichender Marker führt zu `FAIL_STATE`.

## 4. Aktionen

### 4.1 `CREATE`

- nur außerhalb expliziter oder impliziter Transaktionen,
- nur nach `@ConfirmLabUse = 1`,
- nur mit dokumentierter Berechtigung zur Datenbankerstellung,
- idempotent, wenn bereits eine vollständig passende Datenbank existiert,
- niemals überschreibend bei einer unmarkierten oder abweichend markierten Datenbank.

Nach dem Erstellen werden `RECOVERY SIMPLE`, `AUTO_CLOSE OFF`, `AUTO_SHRINK OFF`, `PAGE_VERIFY CHECKSUM` und das angeforderte Compatibility Level gesetzt. Dateipfade werden nicht hart codiert; die Instanz verwendet ihre konfigurierte Standardablage.

### 4.2 `VALIDATE`

`VALIDATE` prüft Name, Zustand, Schreibbarkeit, Compatibility Level und Eigentumsmarker. Die Aktion verändert keinen Zustand.

### 4.3 `DROP`

`DROP` ist nur zulässig, wenn:

- `@ConfirmLabUse = 1` und `@ConfirmDrop = 1`,
- die Datenbank `ONLINE` ist,
- alle Eigentumsmarker exakt übereinstimmen,
- die Datenbank keine Systemdatenbank ist,
- der Batch außerhalb einer Transaktion läuft.

Erst nach diesen Prüfungen darf `SINGLE_USER WITH ROLLBACK IMMEDIATE` verwendet und die Datenbank entfernt werden. Ist ein Marker nicht prüfbar, wird nicht versucht, den Zustand zu erzwingen.

## 5. Fehler- und Wiederherstellungsverhalten

Scheitert die Markeranlage unmittelbar nach einer in diesem Batch neu erstellten Datenbank, versucht die Referenzimplementierung ausschließlich diese gerade erstellte, kanonisch abgeleitete Datenbank wieder zu entfernen. Das ursprüngliche Fehlerereignis wird anschließend erneut ausgelöst.

Eine bereits vor dem Batch vorhandene Datenbank wird bei einem Fehler niemals automatisch entfernt.

## 6. Datenschutz und Neutralität

Der Datenbankname enthält ausschließlich Projektpräfix, Demo-ID und synthetischen Run-Token. Host-, Benutzer-, Kunden-, Firmen- oder Umgebungskennungen sind unzulässig. Dateipfade und reale Freispeicherwerte werden nicht in Repository-Dateien geschrieben.

## 7. Abnahmekriterien

`FWK-002` ist implementiert, wenn:

- der Name deterministisch abgeleitet wird,
- alle Marker bei `VALIDATE` und `DROP` geprüft werden,
- `DROP` zwei ausdrückliche Bestätigungen verlangt,
- eine fremde oder unmarkierte Datenbank technisch nicht gelöscht werden kann,
- `CREATE` und `VALIDATE` idempotent sind,
- die Referenzimplementierung keine dauerhaften Objekte in `master` anlegt.

## 8. Primärquellen

Abgerufen am 24. Juli 2026:

- [CREATE DATABASE (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-database-transact-sql?view=sql-server-ver17)
- [ALTER DATABASE SET Options (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-set-options?view=sql-server-ver17)
- [DROP DATABASE (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-database-transact-sql?view=sql-server-ver17)
- [sys.sp_addextendedproperty (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-addextendedproperty-transact-sql?view=sql-server-ver17)
