# Lokale Validierungsstrategie

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_WITH_GAPS` |
| Stand | 2026-08-27 |
| CI/CD | keine Voraussetzung für die lokale Produktfunktion |
| Ziel | reproduzierbare lokale Prüfung von Verträgen und Provider-Runtime |

## 1. Grundsatz

`SQL_Server_Lab` stellt seine Qualitätsprüfungen als lokal ausführbare Skripte bereit.

Die lokale Validierung besteht aktuell aus drei produktiven Ebenen:

1. statische Vertrags- und Dokumentationsprüfung ohne Labmutation;
2. mutierender End-to-End-Smoke-Test für einen ausgewählten Laufzeitprovider (oder Auto-Auswahl);
3. Übergreifender Referenztest (`Invoke-SmokeMatrix`) über erreichbare Provider mit SQL Server 2025 und optionaler Parallelitätsprüfung.

Die vertiefte, providergetrennte CLI-Abnahme ist in der
[CLI-Akzeptanzmatrix](CLI_ACCEPTANCE_MATRIX.md) festgelegt. Sie ergaenzt die
kleinen Smokes um reale Samples, getrennte Storagepfade, TempDB auf mehreren
Datentraegern, Ressourcenwechsel und den Cleanup echter Windows-SQL-Slots.

### 1.1 Validierungsscope der AI Repository Foundation

Die Foundation ergänzt die vorhandenen Prüfungen, ersetzt sie aber nicht. Die
Nachweise werden getrennt ausgewiesen:

| Scope | Zuständiger Nachweis |
|---|---|
| `FOUNDATION_INTEGRITY` | Foundation-Validator gegen die installierten Dateien unter `.ai/foundation/`, den Root-Bridge-Block, die Provenienz und ausgewählte Adapter |
| `PROJECT_SEMANTIC` | vorhandene statische Projektverträge, insbesondere `Invoke-DocumentationChecks.ps1`, `Invoke-PrivacyScannerChecks.ps1` und die betroffene Auswahl über `Invoke-ImpactedChecks.ps1` |
| `RUNTIME_EMPIRICAL` | Builds, Provider-Smokes, Integrationsprüfungen und manuelle Abnahmen, wenn der Änderungsscope Runtimeverhalten berührt |

Die Foundation-1.7-Identity-, Registration-, Upgrade- und Continuity-Policies
werden unter `FOUNDATION_INTEGRITY` auf Datei-, Schema-, Katalog- und
Indexebene geprüft. Die projektspezifische Scope- und Authority-Zuordnung steht
in `.ai/IDENTITY_AND_ARTIFACT_REGISTRATION.md` und wird unter
`PROJECT_SEMANTIC` geprüft. Lokale Runtime-Registries bleiben unveränderte,
nicht versionierte Betriebsdaten; ohne Runtime-Änderung ist kein Provider-Smoke
durch diese Governance-Integration betroffen.

Der Foundation-Validator behandelt bei verwaltetem UTF-8-Text ausschließlich
LF-/CRLF-Unterschiede als äquivalent. Andere Inhalts-, Final-Newline-, Lone-CR-
oder Binärunterschiede bleiben echte Drift. Die Projektkonfiguration für
`.gitattributes` wird dadurch nicht verändert.

Blockierte Pflichtprüfungen werden als `VALIDATION_FAILURE`,
`INFRASTRUCTURE_UNAVAILABLE` oder `UNKNOWN` klassifiziert. Ein inhaltlich
fehlgeschlagener oder nicht eindeutig klassifizierter Check darf nicht über
einen Continuity-Pfad umgangen werden. Bei Infrastrukturunverfügbarkeit bleibt
die Prüfung bis zum erfolgreichen Nachlauf ausstehend. Der verbindliche
Notfallablauf und die tatsächlich aktiven, geschichteten GitHub-Rulesets stehen
im [Repository-Continuity-Runbook](REPOSITORY_CONTINUITY_RUNBOOK.md). Der
Break-Glass-Akteur darf ausschließlich über einen Pull Request umgehen;
PR-Pflicht, Löschschutz und Force-Push-Schutz besitzen keinen Bypass.

Der Foundation-Validator wird aus einem Checkout der Foundation ausgeführt:

```text
python tools/foundation_validator.py --target <SQL_Server_Lab-Checkout>
```

Ein grüner `FOUNDATION_INTEGRITY`-Nachweis ist kein Nachweis für
`PROJECT_SEMANTIC` oder `RUNTIME_EMPIRICAL`. `NOT_EXECUTED` entspricht
`not executed`; `PASS` darf nur für den tatsächlich ausgeführten und
bestandenen Scope als `validated` abgebildet werden. `SKIP_OPTIONAL`,
`UNSUPPORTED`, `WARN`, `FAIL` und `RECOVERY_REQUIRED` bleiben eigenständige
Projektstatus und dürfen nicht als `validated` dargestellt werden.

## 2. Aktuelle Einstiegspunkte

### Statische Prüfung

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
```

### Docker-Smoke-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

### Podman-Smoke-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

### SQL Server 2022 External Languages

Der Gast-Runner erzeugt einen isolierten, SHA-256-gebundenen
Ubuntu-22.04-/cgroup-v1-Hyper-V-Gast und führt Docker und Podman getrennt aus:

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeContainerHyperVHost.ps1
```

In einem bereits geeigneten rootful Linux-/cgroup-v1-Gast können die Provider
auch einzeln geprüft werden. `EvidencePath` liegt außerhalb des Repositorys:

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeContainerAcceptance.ps1 -Provider docker -EvidencePath <path>
.\Tests\Integration\Invoke-ExternalRuntimeContainerAcceptance.ps1 -Provider podman -EvidencePath <path>
```

Beide Läufe prüfen Python, R und Java über echte SQL-Datenroundtrips, einen
additiven Refresh, eigentumsgebundenes Java-Removal, SQL-/Artefaktpersistenz,
Python-/R-Probes nach providergebundenem Neustart sowie den registrierten und
expliziten Cleanup. Docker-Evidence gilt nicht für Podman und umgekehrt.

### Auto-Modus

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
```

Der Auto-Modus wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Er ist kein Ersatz für zwei getrennte Providerläufe.

### Vertiefte CLI-Akzeptanz

```powershell
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman -Version 2022-CU18
.\Tests\Integration\Invoke-HyperVCliAcceptance.ps1 -MediaRoot D:\Lab_Base -SqlVersion 2025
```

Es werden bewusst nicht alle CUs getestet. Docker und Podman verwenden je
einen repraesentativen katalogisierten CU; Windows prueft die frische
Basisinstallation und verwendet ein CU nur bei vorhandenem verifiziertem Paket.
Der empfohlene operative Push-Pfad ist in der lokalen Readiness-Checkliste beschrieben:

```text
.\Documentation\Quality\LOCAL_READINESS_CHECKLIST.md
```

## 3. Voraussetzungen

### Statische Prüfung

- PowerShell 7.2 oder neuer;
- lokaler Repository-Checkout;
- keine laufende Container-Runtime erforderlich.

### Integration-Smoke-Test

- PowerShell 7.2 oder neuer;
- Docker oder Podman installiert und erreichbar;
- `sqlcmd` installiert;
- Zugriff auf das ausgewählte SQL-Server-Container-Image;
- ausreichend RAM und Storage;
- ein freier Port im Lab-Bereich.

Ein fehlender Provider oder ein fehlendes `sqlcmd` ist kein bestandener Test. Der Test bricht mit einem nachvollziehbaren Fehler ab.

Für lokale Full-Readiness sind zusätzlich relevant:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

## 4. Statische Vertragsprüfung

`Tests/Static/Invoke-DocumentationChecks.ps1` prüft derzeit:

### PowerShell

- Syntax aller aktiven `.ps1`, `.psm1` und `.psd1` außerhalb von `_QuellRepo/` und `private_Note/`;
- Lesbarkeit des Modulmanifests;
- eindeutige `FunctionsToExport`;
- Entfernen nicht implementierter Exportplatzhalter;
- Modulimport, sofern nicht ausdrücklich mit `-SkipModuleImport` übersprungen;
- Übereinstimmung von Exportliste und tatsächlich exportierten Funktionen.

### JSON und Schemas

- JSON-Syntax unter `Catalogs/` und `Schemas/`;
- Existenz relativer `$schema`- und `$ref`-Ziele;
- Existenz der zentralen Katalogschemas;
- grundlegende Provider-Metadaten;
- Existenz der in `provider.json` angegebenen Implementierungsdatei.

Die Prüfung validiert noch nicht jedes JSON-Dokument semantisch vollständig gegen Draft-07. Das bleibt eine benannte Lücke.

### Dokumentation

- Existenz der Front-Door- und Governance-Dateien;
- relative Links in den zentralen Dokumenten;
- Ausschluss des veralteten Rootstatus `PLANNING_FOUNDATION`;
- Ausschluss individueller Entwicklerpfade aus Getting Started;
- Ausschluss der nicht implementierten Environment Variable `SQL_SERVER_LAB_PATH` als Bedienvertrag;
- Ausschluss veralteter Restore-Beispiele mit `-RunId` oder `-BackupUrl`;
- korrekte Beschreibung des Smoke-Test-Auto-Modus;
- Existenz referenzierter `postProvision`-Dateien in Beispielmanifesten.

### Grenzen

Die statische Prüfung ersetzt nicht:

- tatsächlichen Containerstart;
- SQL-Bereitschaft;
- Restore einer realen zulässigen `.bak`-Datei;
- Providerparität;
- Performance- oder Fault-Szenarien;
- vollständige Privacy- oder Secret-Erkennung aller denkbaren Inhalte.

## 5. Integration-Smoke-Test

`Tests/Integration/Invoke-SmokeTest.ps1` prüft für den ausgewählten Provider:

1. Modulimport;
2. Erkennung implementierter Provider über `provider.json` und vorhandene Implementierungsdatei;
3. Runtime-Erreichbarkeit;
4. Resource Assessment;
5. Provisionierung einer SQL-Server-Instanz;
6. Rückgabe von RunId, Provider und Port;
7. Sichtbarkeit des Containers in der ausgewählten Runtime;
8. Erstellung einer Datenbank mit mehreren Data-Files;
9. Verifikation über `sys.databases`;
10. Ausführung eines T-SQL-Skripts mit mehreren `GO`-Batches;
11. Datenverifikation;
12. `Get-SqlServerLab`;
13. `Stop-SqlServerLab`;
14. providergetreue Containerstatusprüfung;
15. `Start-SqlServerLab`;
16. `Remove-SqlServerLab`;
17. Verifikation, dass der Container entfernt wurde;
18. Cleanup bei Testfehlern, sofern `-KeepOnFailure` nicht gesetzt ist.

Der Test erzeugt ausschließlich synthetische Testobjekte.

Der dedizierte Batch-/Queue-Smoke prüft zusätzlich die reale Provisionierung
zweier Container-Labs über persistente Operationen, zwei Scheduler-Worker,
idempotentes Resume und scopegebundenen Cleanup:

```powershell
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker -AbortSchedulerOnce
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker -ManifestRerun
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 `
    -Provider hyperv `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
.\Tests\Integration\Invoke-BatchUserGateAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Container-Batchpositionen müssen dazu in `defaults`, `intent`, `manifest` oder
`overrides` das Feld `SaPasswordEnvironmentVariable` mit dem Namen einer
`SQL_SERVER_LAB_SECRET_*`-Prozessvariable referenzieren. Der Wert wird erst im
Worker gelesen und nicht im Workflow-State persistiert.

`-AbortSchedulerOnce` startet den Scheduler in einem separaten Prozess, wartet
auf eine reale operationseigene Providerressource, beendet den Prozess hart und
prüft anschließend `WorkerRecovered`, eindeutiges Operation-zu-Run-Eigentum,
idempotentes Resume und vollständigen scopegebundenen Cleanup.

`-ManifestRerun` prüft, dass eine zweite offene Einreichung desselben Manifests
denselben Batch und dieselben Operationen zurückgibt. Nach Abschluss und Cleanup
erzeugt dasselbe Manifest einen neuen Batch mit neuen RunIds, bleibt beim
Scheduler-Rerun idempotent und wird erneut vollständig bereinigt.

`Invoke-BatchUserGateAcceptance.ps1` benötigt für den testlokalen Offline-Mount
des operationseigenen Child-VHDX eine erhöhte Sitzung. Das immutable Parent
bleibt read-only. Der Test bindet auf einer realen Windows-VM den reinen
`CandidateSatisfied`-Probe ohne Step-/Receipt-Fortschritt, die fail-closed
Bestätigung, echte PowerShell-Direct-Credential-Verifikation, genau ein
`UserGateConfirmed`-Receipt sowie vollständigen VM-, Child-VHDX- und
State-Cleanup. Ein unverändert grüner Realnachweis wird nicht ohne neue Evidence
wiederholt.

Der diagnostische Konsolen-Fallback wird im selben PowerShell-7-Terminal
gestartet:

```powershell
.\Invoke-SqlServerLab.ps1 -ConsoleMode Fallback
```

Die reale Konsolenabnahme prüft getrennt: `0` beendet den Fallback mit Exitcode
0; `Ctrl+C` beendet Cursor- und Fallback-Verarbeitung mit einem Prozessabbruch,
ohne Ergebnis-/Fortsetzungsmarker und ohne Wechsel vom Cursor in den Fallback.
Die statische Ergänzung ist `Invoke-ConsoleUiChecks.ps1`; simulierte Keys allein
ersetzen den PTY-Nachweis nicht.

## 6. Provider-Abnahme

| Fähigkeit | Docker | Podman | Hyper-V |
|---|---:|---:|---:|
| Resource Assessment | implementiert | implementiert | Lifecycle-Verfügbarkeit implementiert |
| sealed Image-Registry | nicht zutreffend | nicht zutreffend | Import, Integrity, Auswahl und Run Lock implementiert |
| einzelne SQL-Instanz | implementiert | implementiert | eingeschränkter Manifest-Klonpfad aus `OS_SEALED` oder `SQL_PREPARED_SEALED` implementiert; allgemeiner Providerpfad geplant |
| Health und SQL Readiness | implementiert | implementiert | OS-Slot-Installation und Host-SQL-Readiness implementiert |
| Datenbankerstellung | implementiert | implementiert | mit absoluten Windows-Pfaden implementiert |
| T-SQL-Skriptausführung | implementiert | implementiert | ueber Host-SQL-Zugriff implementiert |
| Live-Status | implementiert | implementiert | Lifecycle-Grundlage implementiert |
| Stop und Start | implementiert | implementiert | Lifecycle-Grundlage implementiert |
| Remove | implementiert | implementiert | scopegebundene Grundlage implementiert |
| eigener Smoke-Test-Aufruf | Lifecycle und CLI-Akzeptanz | Lifecycle und CLI-Akzeptanz | Lifecycle, Windows-Baseline und vollstaendige CLI-Akzeptanz |
| gemischter Provider-Run | implementiert mit Podman-ProviderSubRun | implementiert mit Docker-ProviderSubRun | nicht unterstützt |
| SQL-2022-Python/R/Java | nativ validiert auf rootful Linux/cgroup v1 | nativ validiert auf rootful Linux/cgroup v1 | nativ validiert im isolierten Windows-Gast einschließlich VM-Kaltstart |

`implementiert` bedeutet, dass Code und Testpfad vorhanden sind. `validiert` darf nur für einen tatsächlich erfolgreich ausgeführten lokalen Lauf verwendet werden.

## 7. SQL-Server-Versionen

Der Versionskatalog enthält derzeit SQL Server 2019, 2022 und 2025 sowie ausgewählte CU-Buildmetadaten.

Der Smoke-Test kann eine Version oder einen katalogisierten CU-Kurzbezeichner erhalten:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2019'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2022'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2025'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2022-CU16'
```

`Invoke-SmokeMatrix.ps1` ist der übergeordnete Provider-Testeinstieg und prüft
pro erreichbarem Provider SQL Server 2025. `-IncludeParallel` verwendet
ebenfalls ausschließlich diese Referenzversion. Die reale Mehrversions-
Kompatibilität für 2019/2022/2025 wird in SQL Analyze und Toolbelt geprüft,
weil dort die versionsabhängigen Partnerworkflows liegen. Einzelne Nachweise
bleiben getrennt zu dokumentieren, wenn ein Provider nicht verfügbar ist.

Ein Katalogeintrag oder vorhandener Testparameter beweist nicht, dass ein Image weiterhin verfügbar oder der Katalog aktuell ist.

## 8. Restore-Validierung

Der allgemeine Smoke-Test prüft derzeit keinen Download und keinen Restore einer öffentlichen Sample-Datenbank, um Laufzeit, Netzwerkabhängigkeit und Datenmenge klein zu halten.

Für einen manuellen Restore-Nachweis sind mindestens zu dokumentieren:

- verwendete synthetische oder öffentliche Quelle;
- Lizenz und Klassifikation;
- SQL-Server-Version;
- Provider;
- Dateigröße und gegebenenfalls Prüfsumme;
- Restore-Ergebnis;
- Datenbankverifikation;
- Cleanup-Ergebnis.

Nicht in versionierte Evidence übernehmen:

- lokale Backup-Pfade;
- Passwörter;
- Connection Strings;
- reale Hostwerte;
- vollständige Backup-Metadaten aus nicht öffentlichen Quellen.

## 9. Sample-Katalog-Validierung

Die statische Prüfung verifiziert JSON und Schema-Referenzen. Der Manifestparser prüft zur Laufzeit:

- Sample-ID vorhanden;
- Variante vorhanden;
- SQL-Mindestversion erfüllt;
- URL vorhanden;
- Variante hat einen freigegebenen Handler und eine dazu passende direkte
  `.bak`-, `.zip`- oder `.sql`-Quelle.

Nicht freigegebene Archive, Attach-Szenarien und Script-Bundles müssen mit einer
erklärenden Fehlermeldung abgewiesen werden.

Ein vollständiger automatischer Download-/Restore-Test pro Sample ist derzeit nicht vorhanden.

## 10. Cleanup- und Recovery-Prüfung

Der Smoke-Test prüft erfolgreichen Remove und versucht Cleanup bei einem Testfehler.
Der separate Mixed-Provider-Smoke-Test prüft zusätzlich Provisionierung,
Status, Stop, Start und Remove für genau einen Docker- und einen
Podman-ProviderSubRun.

Noch nicht vollständig automatisiert sind unter anderem:

- Prozessabbruch nach einzelnen Mutationsschritten;
- wiederholtes Cleanup nach Teilfehler;
- Fremdobjektschutz bei manipulierten Labels;
- symbolische Links und Junctions außerhalb des Scope;
- Providerfehler während Restore oder Serverkonfiguration;
- idempotenter Recoverylauf nach Hostneustart;
- gezielt induzierte Teilfehler in einem gemischten Provider-Lifecycle.

Diese Punkte bleiben Roadmap und dürfen nicht als validiert bezeichnet werden.

## 11. Privacy-Validierung

Vor Datei-, Git-, Package- oder Exportoperationen sind zu prüfen:

- Personen-, Firmen-, Kunden- und Organisationsbezüge;
- Hostnamen, IP-Adressen, Endpunkte und Pfade;
- Secrets und Connection Strings;
- reale Datenbank- und Objektstrukturen;
- Produktions- und unbekannte Backups;
- Logs, Plans, Responses und Screenshots;
- lokale State-, Artifact-, Cache- und Secretpfade;
- unerwartete Binärdateien und Archive.

Die statische Vertragsprüfung ist kein vollständiger Data-Loss-Prevention-Scanner. Verantwortliche Inhaltsprüfung bleibt erforderlich.

## 12. Ergebnisbegriffe

```text
PASS
WARN
SKIP_OPTIONAL
NOT_EXECUTED
UNSUPPORTED
FAIL
RECOVERY_REQUIRED
```

Verwendung:

- `PASS`: relevante Prüfung erfolgreich und erforderliches Cleanup abgeschlossen;
- `WARN`: Prüfung lief, aber eine nicht blockierende Grenze bleibt;
- `NOT_EXECUTED`: Prüfung wurde nicht ausgeführt;
- `UNSUPPORTED`: aktueller Vertrag unterstützt den Pfad nicht;
- `FAIL`: erwarteter Vertrag wurde verletzt;
- `RECOVERY_REQUIRED`: erzeugte Ressourcen konnten nicht vollständig bereinigt werden.

Ein nicht verfügbarer Provider darf nicht als `PASS` behandelt werden.

## 13. Empfohlene lokale Abnahme vor Push/Release

### Nur Dokumentation, Schema oder Metadaten

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

### Docker-Runtime betroffen

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

### Podman-Runtime betroffen

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

### Gemeinsame Containerlogik betroffen

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

### Hyper-V-Lifecycle betroffen

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

Der Hyper-V-Smoke-Test ist ein Image-Registry- und VM-/VHDX-Lifecycle-Nachweis. Ein erfolgreicher
Lauf ist kein Betriebssystem-, PowerShell-Direct-Postcondition- oder SQL-Nachweis.

### Voller Minimalablauf (Push/Release)

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Bei fehlender Docker-/Podman-Ebene dokumentiert `Invoke-SmokeMatrix` `SKIP` statt `FAIL`; ein erreichbarer Providerfehler bleibt jedoch `FAIL`.

Reproduzierbare Release-Vorbereitung:

```powershell
.\Tools\Prepare-LocalRelease.ps1 -CreateArchive -IncludeHashManifest
```

Nicht verfügbare Native-Tests müssen im Pull Request mit Grund als `NOT_EXECUTED` angegeben werden.

## 14. Roadmap

Verbleibende priorisierte Ergänzungen:

1. Pester-Kontrakt-Paket und Release-Artefakt-Erstellung (mit `Tools\Prepare-LocalRelease.ps1`) sind implementiert;
2. zusätzliche nicht mutierende Versionsauflösungstests;
3. weitere Fault-Injection-Pfade für Portbindung, Runtimeabbruch und
   teilweise Orphan-Bereinigung;
4. zusätzliche Fremdobjekt- und Pfadsicherheitstests;
5. Hyper-V-Windows-Specialization, PowerShell-Direct-Postcondition und
   SQL-Provisionierung nach der validierten Lifecycle-Grundlage.

Bereits umgesetzt sind vollständige Schema-Prüfungen, die lokal steuerbare
Version-/Provider-Matrix, ein synthetischer echter Backup-/Restore-Test, ein
deterministischer Cleanup-/Recovery-Fehlertest und das übergeordnete statische
Testskript `Tests/Static/Invoke-AllChecks.ps1`.

## 15. CI/CD-Abgrenzung

Lokale Produktfunktion und Native-Tests dürfen nicht von GitHub-hosted Runnern abhängen.

Der Workflow `PR Gate` klassifiziert geänderte Pfade, führt auf Windows und
Ubuntu nur betroffene statische Suites aus und schaltet ausschließlich passende
Runtime-Smokes zu. Änderungen am Foundation-Core, Root-Agentenvertrag,
Copilot-Adapter oder PR-Gate starten zusätzlich den Job `Foundation integrity`.
Dieser checkt den in `.ai/repo_map.yaml` gebundenen Foundation-Quellcommit aus
und führt den Foundation-Validator mit den projektspezifisch ausgewählten
Adaptern und Capabilities aus. Sein Ergebnis fließt in den geschützten
Abschlusscheck `PR Gate` ein. Auf einen Merge nach `main` folgt keine zweite
Vollmatrix.
Die vollständige statische und native Regression läuft täglich gebündelt als
`Nightly Regression`; eine frische Hyper-V-/SQL-Installation läuft wöchentlich
oder manuell. Nightly-Fehler werden über ein dauerhaftes Tracking-Issue sichtbar.
