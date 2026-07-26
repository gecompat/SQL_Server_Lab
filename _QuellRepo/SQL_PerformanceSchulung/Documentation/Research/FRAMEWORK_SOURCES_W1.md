# Primärquellen für die Welle-1-Framework-Basis

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Arbeitspakete | `FWK-003` bis `FWK-007`, `FWK-010`, `FWK-011` |
| Geltungsbereich | SQL Server 2019, 2022 und 2025 sowie plattformneutrale Prozess- und Ergebnissteuerung |

## Quellen

| ID | Primärquelle | Aussagebezug | Gültigkeitsgrenze |
|---|---|---|---|
| `FWKSRC-001` | [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17) | Histogramm, Density, Sampling und Statistikinterpretation in `FWK-005` | SQL Server 2019–2025; CE- und Compatibility-Level-Kontext beachten |
| `FWKSRC-002` | [sys.dm_db_stats_properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-properties-transact-sql?view=sql-server-ver17) | Statistikproperties in `FWK-005` | leeres Ergebnis nicht als Nullstatistik interpretieren; Metadatensichtbarkeit beachten |
| `FWKSRC-003` | [sys.dm_db_stats_histogram](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-histogram-transact-sql?view=sql-server-ver17) | Histogrammschritte in `FWK-005` | Histogramm bezieht sich auf die führende Statistikspalte |
| `FWKSRC-004` | [SET STATISTICS XML](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-statistics-xml-transact-sql?view=sql-server-ver17) | interaktive Actual-Showplan-XML-Ausgabe | `SHOWPLAN` auf allen referenzierten Datenbanken erforderlich; keine automatische Persistierung |
| `FWKSRC-005` | [sys.dm_exec_sessions](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-sessions-transact-sql?view=sql-server-ver17) | sessionbezogene CPU-, Read-, Logical-Read- und Write-Zähler in `FWK-004` | kumulative Sessionzähler; Messoverhead ist enthalten |
| `FWKSRC-006` | [sys.dm_exec_session_wait_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-session-wait-stats-transact-sql?view=sql-server-ver17) | optionale sessionbezogene Wait-Deltas in `FWK-004` | Berechtigungsbezeichnung versionsabhängig; fehlende optionale Sichtbarkeit ergibt `WARN` |
| `FWKSRC-007` | [Query processing architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/query-processing-architecture-guide?view=sql-server-ver17) | Abgrenzung von Plan, Optimierung, Ausführung und Runtime-Evidenz | Plan- und Laufzeitbeobachtung sind keine alleinige Ursachenbestätigung |
| `FWKSRC-008` | [ALTER DATABASE SET options – Query Store](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-set-options?view=sql-server-ver17#query-store) | Query-Store-Enable, Operation Mode, Clear und Konfigurationsoptionen in `FWK-007` | Optionen und Defaults versionsabhängig; vorhandene Konfiguration vor Änderung erfassen |
| `FWKSRC-009` | [CREATE EVENT SESSION](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-event-session-transact-sql?view=sql-server-ver17) | serverweite XE-Session, Target, Optionen und Berechtigungen | `CREATE ANY EVENT SESSION` ab SQL Server 2022; `ALTER ANY EVENT SESSION` kompatibel |
| `FWKSRC-010` | [DROP EVENT SESSION](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-event-session-transact-sql?view=sql-server-ver17) | bestätigtes Entfernen der Framework-XE-Session | `DROP ANY EVENT SESSION` ab SQL Server 2022 oder kompatible weitergehende Berechtigung |
| `FWKSRC-011` | [Targets for Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server?view=sql-server-ver17) | flüchtiges `ring_buffer`-Target und Speicherbegrenzung | Targetinhalt endet mit Session; Microsoft empfiehlt Ring-Buffer-Begrenzung zur XML-Darstellung |
| `FWKSRC-012` | [Quickstart: Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/quick-start-extended-events-in-sql-server?view=sql-server-ver17) | Create, Start, Read, Stop und Drop als Lifecycle | Beispielsyntax ist an den engeren Projektvertrag anzupassen |

## Evidenzgrenze

Die Quellen dokumentieren Produkteigenschaften, Syntax, Berechtigungen und Messschnittstellen. Generatorverteilungen, konkrete Performancewirkungen und zulässige Bandbreiten bleiben empirische Eigenschaften der jeweiligen synthetischen Demo. Python-Prozesssteuerung und Ergebnisnormalisierung sind User-defined Tools; deren Verhalten wird durch SQL-Server-unabhängige Selbsttests belegt.

Query Store und Extended Events können zur Laufzeit SQL-Texte, Literalwerte und Fehlermeldungen enthalten. Der Frameworkvertrag leitet daraus keine Freigabe zur Persistierung ab. Jeder Export benötigt eine eigene Privacy- und Metadatenprüfung.

## Abnahme

Alle Framework-Komponenten sind den verwendeten Herstellerquellen oder klar gekennzeichneten projektinternen Methoden zugeordnet. Eine Runtime-Validierung der SQL-Referenzskripte auf SQL Server 2019, 2022 und 2025 ist nicht Bestandteil dieses Quellenreviews und bleibt ein separates Arbeitspaket.
