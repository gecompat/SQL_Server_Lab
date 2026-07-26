# Eingebettete Quell-Repository-Snapshots

Dieser Bereich bewahrt vollständige Dateisnapshots zweier Quell-Repositories als normale Dateien innerhalb von `SQL_Server_Lab` auf.

Die Verzeichnisse sind keine Git-Submodule, keine Subtrees mit eigener Historie und keine eigenständigen Repositories. `.git`-Metadaten wurden nicht übernommen.

## Zweck

Die Snapshots sichern insbesondere alle vorhandenen Informationen zur bisherigen Lab-Erzeugung, bevor entsprechende Inhalte in den Quell-Repositories bereinigt oder entfernt werden.

Die Dateien unter `_QuellRepo/` sind zunächst Referenz- und Migrationsquellen. Änderungen am aktiven `SQL_Server_Lab` werden außerhalb dieser Snapshot-Verzeichnisse umgesetzt.

## Herkunft

| Snapshot | Quell-Repository | Branch | Commit | Dateien | Bytes |
|---|---|---|---|---:|---:|
| `SQL_Server_Analyze/` | https://github.com/gecompat/SQL_Server_Analyze | `main` | `612bcc60d4a8a34c05ab28ffc6ce964e359df6c2` | 782 | 9487738 |
| `SQL_PerformanceSchulung/` | https://github.com/gecompat/SQL_PerformanceSchulung | `main` | `bc3a180c9ff4b87314a8e526a16d41ec36f57ea6` | 161 | 17880163 |

**Kopierzeitpunkt (UTC):** `2026-07-26T12:32:39Z`

## Integritätsnachweis

`SOURCE_SNAPSHOT_MANIFEST.csv` enthält für jede eingebettete Datei den relativen Pfad, die Größe, den SHA-256-Hash sowie Executable- und Symlink-Kennzeichen.

## Aktualisierung

Eine spätere Aktualisierung muss bewusst erfolgen, den neuen Quell-Commit dokumentieren und das vollständige Manifest neu erzeugen. Eine automatische Synchronisierung mit den Quell-Repositories besteht nicht.
