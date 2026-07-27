# Validierungsergebnis vom 2026-07-27

## Geprüfter Stand

- Branch: `agent/documentation-consistency-repair`
- Zielbranch: `main`
- Pull Request: `#3`
- Ausführungsumgebung: lokales Linux-Sandboxsystem
- PowerShell: 7.4.6 portable

Die Prüfung erfolgte auf einem nach den letzten Codeänderungen neu geladenen Branch-Archiv.

## Erfolgreich ausgeführt

### Statische Projektprüfung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Ergebnis: `PASS`

Geprüft wurden unter anderem:

- PowerShell-Parser für aktive `.ps1`, `.psm1` und `.psd1`;
- Modulimport;
- Übereinstimmung von `FunctionsToExport` und tatsächlich exportierten Funktionen;
- JSON-Syntax;
- relative `$schema`- und `$ref`-Ziele;
- Provider-Metadaten und referenzierte Implementierungsdateien;
- zentrale Dokumentationsdateien und relative Links;
- Ausschluss veralteter Restore-Beispiele und des alten Planungsstatus;
- Existenz referenzierter `postProvision`-Dateien.

### JSON-Schema-Validierung

Ergebnis: `PASS`

Tatsächlich gegen Draft-07 validiert wurden:

- `Catalogs/sql-server-versions.json` gegen `Schemas/version-catalog.schema.json`;
- `Catalogs/sample-databases.json` gegen `Schemas/sample-databases.schema.json`;
- sämtliche `Schemas/example-*.json` gegen `Schemas/lab-manifest.schema.json`.

### Nicht mutierende PowerShell-Vertragstests

Ergebnis: `PASS`

Geprüft wurden:

- Auflösung der Basisversionen 2019, 2022 und 2025;
- Auflösung katalogisierter CU-Kurzbezeichner;
- Auflösung eines exakten Image-Tags;
- Ablehnung eines unbekannten CU-Bezeichners;
- Einlesen und Normalisieren sämtlicher Beispielmanifeste;
- Auflösung einer direkten `.bak`-Sample-Variante;
- Ablehnung eines nicht automatisch unterstützten SQL-Skript-Samples;
- State-Transitions bis `RECOVERY_REQUIRED`;
- Persistenz des Providers im Cleanup-Plan.

Alle dabei erzeugten State-Dateien waren synthetisch und wurden im temporären Verzeichnis vollständig entfernt.

### PSScriptAnalyzer

Ergebnis: `PASS`

Ausgeführt wurde PSScriptAnalyzer für Fehler-Schweregrad über:

- `Public/`;
- `Private/`;
- `Providers/`;
- `Tests/`;
- `SqlServerLab.psm1`.

Die Regel zum absichtlichen synthetischen Testpasswort wurde für diesen Lauf ausgeschlossen. Es wurden keine sonstigen Fehlerbefunde zurückgegeben.

## Nicht ausgeführt

### Docker-End-to-End-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

Status: `NOT_EXECUTED`

Grund: In der ausführenden Sandbox steht keine Docker-Runtime zur Verfügung.

### Podman-End-to-End-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Status: `NOT_EXECUTED`

Grund: In der ausführenden Sandbox steht keine Podman-Runtime zur Verfügung.

## Mergeentscheidung

Der Branch ist statisch und auf Vertragsebene validiert. Er verändert jedoch Provisionierung, Providerbindung, Restore, Cleanup, State-Recovery, Serverkonfiguration und beide Containerprovider.

Daher gilt:

- Der Pull Request kann fachlich geprüft und als reviewbereit markiert werden.
- Ein Merge in `main` erfolgt erst nach mindestens einem erfolgreichen Docker-Smoke-Test und einem erfolgreichen Podman-Smoke-Test oder nach einer ausdrücklichen Entscheidung, einen der beiden Provider mit dokumentiertem `NOT_EXECUTED` zu übernehmen.
- Nicht ausgeführte Runtimeprüfungen werden nicht als bestanden dargestellt.
