# Changelog

Dieses Changelog dokumentiert Änderungen am öffentlichen Verhalten, an maschinenlesbaren Verträgen und an der Bedienung von `SQL_Server_Lab`.

Das Repository verwendet derzeit keine formalen Releases. Einträge werden daher nach Datum geführt. Neue Einträge werden oben ergänzt.

## 2026-07-30

### Hinzugefügt

- maschinenlesbare `x-runtimeStatus`-Klassifikation fuer `serverConfig`-Felder;
- vollstaendige Schema-Validierung der Kataloge und Beispielmanifeste im statischen Check;
- RunId-basierte Restore-Zielaufloesung mit optionaler Instanz-ID;
- SHA-256-Pruefung fuer freigegebene Sample-Downloads und lokale Backups.

### Geaendert

- unverifizierte Sample-Varianten sind explizit `descriptive` und werden nicht
  automatisch ausgefuehrt;
- statische Test- und Architektur-Dokumentation bildet den aktuellen Stand ab.

## 2026-07-28

### Hinzugefügt

- `New-SqlServerLabManifest` als schema-gesteuerter PowerShell-Konsolen-Wizard für alle Manifestfelder;
- `Test-SqlServerLabManifest` für struktur- und fachbezogene Prüfung ohne Provisionierung;
- Manifestaktion im interaktiven Hauptmenü;
- statischer Regressionstest für Builder, Schema, Kataloge und Runtime-Grenzen.

### Geändert

- der Manifestparser validiert vollständig gegen das JSON-Schema;
- nicht ausführbare Provider-, Versions-, Sample- und Datenbankkombinationen werden vor einer Ressourcenmutation abgelehnt;
- vorbereitete Runtimefelder und riskante SQL-Optionen werden als Warnungen ausgewiesen.
- alle öffentlichen Nomen sind auf den Präfix `SqlServerLab` vereinheitlicht;
	`New-LabManifest`, `Test-LabManifest`, `New-LabDatabase`,
	`Restore-LabDatabase`, `Invoke-LabScript` und `Test-LabResources` wurden ohne
	Kompatibilitätsaliasse oder Deprecation-Zeitraum durch die entsprechenden
	kanonischen `SqlServerLab*`-Commands ersetzt.

## 2026-07-27

### Behoben

- beschädigte PowerShell-Struktur in `Private/VersionCatalog.ps1` repariert;
- CU-Kurzbezeichner werden über den Versionskatalog aufgelöst und unbekannte Builds nicht mehr erraten;
- Restore- und Sample-Datenbanken werden nicht mehr vor dem Restore per `CREATE DATABASE` angelegt;
- Datenbankoptionen werden nach erfolgreichem Restore angewendet;
- Data- und Log-Dateipfade aus Manifesten werden bis zu `New-SqlServerLabDatabase` erhalten und verwendet;
- Start, Stop und Live-Status verwenden den für den Run gespeicherten Provider statt einer global bevorzugten Runtime;
- Docker-Provider-Metadatum von `DockerProvider.psm1` auf die tatsächlich geladene Datei `DockerProvider.ps1` korrigiert;
- nicht implementierte Exporte aus `SqlServerLab.psd1` entfernt;
- fehlerhafte Restore-Beispiele und individuelle lokale Pfade aus Getting Started entfernt;
- falsche Aussage korrigiert, der Auto-Smoke-Test provisioniere alle installierten Provider.

### Hinzugefügt

- JSON-Schema für den SQL-Version-Katalog;
- JSON-Schema für den Sample-Datenbank-Katalog;
- Auflösung direkter `.bak`-Sample-Varianten im Manifestparser;
- verbindliches Dokument der bekannten Runtimegrenzen;
- maschinenlesbare Repository-Landkarte `.ai/repo_map.yaml`;
- lokale statische Vertrags- und Dokumentationsprüfung;
- Beitrags-, Security- und GitHub-Governance-Artefakte.

### Geändert

- Root-README vom Planungsstatus auf den implementierten Container-Core und den tatsächlichen Benutzerfluss umgestellt;
- Dokumentationsindex, Getting Started, Katalog-, Schema-, Public- und Testdokumentation an den Codevertrag angeglichen;
- ausführbare Manifestbeispiele auf vorhandene Dateien und tatsächlich angewendete Felder reduziert;
- Sample- und Restore-Vertrag ausdrücklich voneinander und von `CREATE DATABASE` getrennt.

## Frühere Änderungen

Ältere Änderungen sind derzeit über die Git-Historie und die vorhandenen Projektplanungsdokumente nachvollziehbar. Sie werden nicht rückwirkend ohne belastbare Zuordnung in dieses Changelog übertragen.
