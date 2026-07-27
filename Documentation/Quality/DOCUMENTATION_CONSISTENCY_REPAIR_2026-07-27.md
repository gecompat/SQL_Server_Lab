# Dokumentations- und Vertragsbereinigung vom 2026-07-27

## Anlass

Die Root-README und mehrere Bereichsdokumente beschrieben das Repository noch als Planungsgrundlage, obwohl der Container-Core bereits implementiert war. Gleichzeitig bestanden technische Brüche zwischen Code, Manifest, Katalogen, Provider-Metadaten, Beispielen und Tests.

## Behobene technische Brüche

- beschädigte PowerShell-Struktur in `Private/VersionCatalog.ps1`;
- nicht implementierte Exporte im Modulmanifest;
- falsche Docker-Provider-Dateiendung in `provider.json`;
- Providerverlust bei Start, Stop und Live-Status;
- `CREATE DATABASE` vor einem anschließend geplanten Restore;
- nicht erhaltene Data- und Log-Dateipfade aus Manifesten;
- fehlende Auflösung direkter `.bak`-Sample-Referenzen;
- fehlende Katalogschemas und nicht existente Schema-Referenzziele;
- providerfremde und Hyper-V-fehlerhafte Annahmen im Integration-Smoke-Test.

## Behobene Dokumentationsbrüche

- Rootstatus `PLANNING_FOUNDATION` durch den tatsächlichen Container-Core-Status ersetzt;
- Getting Started auf generische Pfade und tatsächliche Cmdlet-Parameter korrigiert;
- nicht implementierte Environment Variable aus dem Bedienvertrag entfernt;
- Auto-Verhalten des Smoke-Tests korrekt beschrieben;
- Katalog-, Schema-, Public-, Private-, Provider- und Testdokumentation angeglichen;
- Known Limitations als verbindliche Negativdokumentation ergänzt;
- `.ai/repo_map.yaml` als maschinenlesbare Repository-Landkarte ergänzt;
- Governance-Artefakte für Beiträge, Security, Ownership, Issues und Pull Requests ergänzt.

## Neue lokale Prüfpfade

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

## Validierungsstatus dieser Änderung

### Durchgeführt

- aktueller `main` und offene Pull Requests geprüft;
- Branch ohne Rückstand von `main` erstellt;
- vollständige Changed-File-Matrix über GitHub verglichen;
- zentrale Dateien nach jeder Änderung erneut über den GitHub-Connector gelesen;
- JSON- und YAML-Inhalte strukturell erstellt und Referenzziele explizit angelegt;
- Privacy-Prüfung durchgeführt; vorhandene öffentliche Attribution wurde nach ausdrücklicher Freigabe beibehalten.

### Nicht ausgeführt

- lokale PowerShell-Ausführung;
- `Tests/Static/Invoke-DocumentationChecks.ps1`;
- Docker-Smoke-Test;
- Podman-Smoke-Test.

Grund: Die ausführende Umgebung verfügt nicht über PowerShell, Docker oder Podman und kann das öffentliche Repository nicht lokal klonen. Diese Prüfungen dürfen deshalb erst nach tatsächlichem lokalen Lauf als bestanden bezeichnet werden.

## Verbleibende Grenzen

Siehe `Documentation/Quality/KNOWN_LIMITATIONS.md`. Besonders relevant:

- Hyper-V ist geplant;
- gemischte Provider innerhalb eines Runs besitzen noch keinen gemeinsamen Lifecycle;
- mehrere vorbereitete `serverConfig`-Felder sind noch kein stabiler Runtimevertrag;
- Sample-Automation unterstützt nur direkte `.bak`-Varianten;
- der Versionskatalog ist nicht automatisch aktuell.
