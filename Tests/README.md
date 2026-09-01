# Tests/ – lokale und Remote-Validierung

## Verzeichnisse

| Verzeichnis | Inhalt |
|---|---|
| `Static/` | Import-, Export-, JSON-, Schema-, Metadaten-, Link-, Menü- und Dokumentationskonsistenz |
| `Integration/` | read-only sowie mutierende Lifecycle-, Provider-, Versions- und Parallelitäts-Smoke-Tests |

## Kurz-Readiness vor einem Pull Request

Die CI ermittelt die betroffenen Suites aus den geänderten Pfaden. Lokal kann
dieselbe Auswahl verwendet werden:

```powershell
$paths = git diff --name-only origin/main...HEAD
.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths
```

Die vollständige statische Regression bleibt für Nightly, Release oder eine
bewusste manuelle Abnahme verfügbar:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
```

Bei Hyper-V-relevanten Änderungen zusätzlich:

```powershell
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

Die vertiefte Matrix fuer reale Samples, Ressourcen- und Storageaenderungen ist
in [CLI_ACCEPTANCE_MATRIX.md](../Documentation/Quality/CLI_ACCEPTANCE_MATRIX.md)
dokumentiert. Ihre ausfuehrbaren Einstiege sind:

```powershell
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-ContainerRuntimeScopeAcceptance.ps1
.\Tests\Integration\Invoke-HyperVCliAcceptance.ps1 -MediaRoot D:\Lab_Base -SqlVersion 2025
.\Tests\Integration\Invoke-HyperVSqlPreparedImageAcceptance.ps1
.\Tests\Integration\Invoke-HyperVSqlConfigurationReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSqlConfigurationReconcileAcceptanceBootstrap.ps1
.\Tests\Integration\Invoke-HyperVSqlPortReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSqlPortReconcileAcceptanceBootstrap.ps1
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptanceBootstrap.ps1 `
    -MediaRoot D:\Lab_Base
.\Tests\Integration\Invoke-HyperVStorageAcceptance.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
```

Der SQL-Konfigurationsrunner erzeugt einen eigenen Prepared-Image-Klon und
prüft Plan, `WhatIf`, Live-Reconcile, Trace-Flag-Ownership, den Fortbestand
eines fremden Runtime-Flags, einen ausschließlichen SQL-Dienstrestart für einen
nicht dynamischen Wert, Desired-State-Rückkehr, No-op und Cleanup. Der Bootstrap
erzeugt zuvor ein isoliertes SQL-2025-Prepared-Artifact und entfernt es nur nach
erfolgreichem Runner-Cleanup. Beide Einstiege behalten bei Fehlern die exakten
Recovery-IDs; eine positive native Ausführung ist noch `NOT_EXECUTED`.

Der SQL-Port-Runner erzeugt ausschließlich im neuen Gast eine kontrollierte
TCP-/Firewall-Drift und prüft anschließend Plan, `WhatIf`, den alleinigen SQL-
Dienstrestart, Connection-State, No-op und vollständigen Cleanup. Der getrennte
Bootstrap besitzt denselben isolierten Artifact-/Recovery-Vertrag; eine
positive native Ausführung ist noch `NOT_EXECUTED`.

Der letzte Runner ist der ausführbare Vertrag für Gate N5. Er startet nur,
wenn vier TempDB-Datendateien auf mindestens zwei beziehungsweise der im Intent
geforderten höheren Zahl nachweislich getrennter Backing Devices liegen und das
TempDB-Log einen eigenen Selector und damit eine eigene VHDX-Lane besitzt. Das
mitgelieferte Referenz-Intent verwendet drei Geräte mit der Verteilung 2/1/1.
Er erzeugt State
und Cleanup-Plan vor der ersten VM-Mutation, prüft SQL-Dienstrestart, CREATE,
einen synthetischen Backup/Restore-Roundtrip, VM-Restart und entfernt danach
VM, Child-VHDX sowie alle zusätzlichen run-eigenen VHDX. Ein vorhandener
Runner oder ein grüner statischer Check ist noch kein Runtime-Nachweis.

Interpretation:

- `SKIP`: Provider nicht erreichbar/fehlend oder fehlende Elevation
- `FAIL`: Erreichbarer Provider hat einen harten Fehler, Exitcode ist `1`
- `PASS`: Testpfad ist vollständig erfolgreich

## Statische Prüfungen

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-BatchWorkflowChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ReadinessContractChecks.ps1
.\Tests\Static\Invoke-ReconcileContractChecks.ps1
.\Tests\Static\Invoke-ReconcileActionContractChecks.ps1
.\Tests\Static\Invoke-HyperVResourceReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVStorageReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVSqlStorageReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVSqlConfigurationReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVSqlPortReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVTestDatabaseReconcileChecks.ps1
.\Tests\Static\Invoke-ExternalRuntimeReconcileChecks.ps1
.\Tests\Static\Invoke-StorageFilePlacementChecks.ps1
.\Tests\Static\Invoke-HyperVResourceMigrationChecks.ps1
.\Tests\Static\Invoke-HyperVImageMigrationChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
.\Tests\Static\Invoke-ArtifactResolverChecks.ps1
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-ProjectAdapterChecks.ps1
.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1
.\Tests\Static\Invoke-CleanupAuditChecks.ps1
.\Tests\Static\Invoke-PersistentStorageCatalogChecks.ps1
.\Tests\Static\Invoke-PersistentStorageRemovalPlanChecks.ps1
.\Tests\Static\Invoke-ContainerInstanceStoreChecks.ps1
.\Tests\Static\Invoke-ContainerRuntimeScopeChecks.ps1
.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1
.\Tests\Static\Invoke-PesterChecks.ps1
.\Tests\Static\Invoke-ReleaseReadinessChecks.ps1
```

Die statischen Prüfungen benötigen keine laufende SQL-Server-Instanz. Sie kontrollieren unter anderem:

- JSON-Syntax der Kataloge, Schemas und Beispiele;
- Existenz referenzierter Schema-Dateien;
- Import des Modulmanifests;
- Übereinstimmung von `FunctionsToExport` und tatsächlich verfügbaren Funktionen;
- persistente Batch-/Operation-Verträge, deterministische Mengenexpansion,
  Zwei-Worker-/HyperVHeavy-Limits, Fehlerisolation, User-Gates und Resume;
- schema- und fachgerechte Manifest-Erstellung ohne Provisionierung;
- Ablehnung unbekannter Felder, doppelter IDs, Providerkonflikte und inkompatibler Datenbankoptionen;
- Existenz der in Provider-Metadaten angegebenen Module;
- zentrale Dokumentationslinks;
- SQL- und Datenbank-Readiness-Verträge;
- Read-only Reconcile-Vertrag: versionierter Desired/Actual/Diff/Action-Plan,
  No-op, providergebundene Vorschläge, fail-closed Runtime-Zustände und
  Geheimnisfreiheit;
- Reconcile-Executor-Vertrag: `Invoke-SqlServerLabReconcileAction` mit
  unterstütztem `START`/`STOP`, `-WhatIf`, mixed-operation-Schutz und
  geheimnissicherem Ergebnis;
- External-Runtime-Reconcile-Vertrag: versionsbewusster SQL-2019-/2022-/2025-
  Container-Refresh, Nicht-Software-Drift-/Removal-Gates, sanitisiertes
  `-WhatIf`, Journal, Rollback und Umschaltreihenfolge;
- portabler Storage-Intent, lokale Selector-/Topologiebindung, vollständige
  SQL-Dateipläne und der getrennte Runtime-Receipt-Vertrag;
- Hyper-V-Legacy-Migration: schema-valides read-only Inventar, Checkpoint-
  Blocker, `-WhatIf`, Hash-/VHDX-Verifikation, journalisiertes Resume nach
  unterbrochenem Parent-Reparent, getrennte Quell-/Ziel-Child-Hashes, zwei
  Neustartprüfungen, Erhalt externer SQL-Lanes, Quell-Cleanup erst nach
  erfolgreicher Zielbindung und automatisches Resume des Image-Cleanup;
- Hyper-V-Image-Migration: exaktes Artifact-/Hash-Inventar, Fremdbelegungs-
  und Planmanipulationsschutz, hashidentische Veröffentlichung im gebundenen
  Image-Store sowie `WAITING_FOR_CONSUMERS` bis zum referenzfreien Resume-
  Cleanup;
- Pester-Vertrag: projektspezifische Baseline, Manifest-/Exportkonsistenz und
  deterministisch ausführbare Unit-/Contract-Tests unter `Tests/Pester`;
- Ausschluss bekannter veralteter Beispiele und Statusangaben.
- ProviderSubRuns, Mixed-Provider-Beispiel und Cleanup-Zuordnung.
- Trust Store, inhaltsadressierten Artifact Cache, Quarantäne und sanitisiertes Run Lock mit ausschliesslich synthetischen Testbytes.
- Sample-Backup-Handler-Vertrag: Katalogfilterung, Auflösung, Idempotenz- und Trust-Metadaten sowie den nicht interaktiven `TRUST_REQUIRED`-Pfad ohne Netzwerk oder Container.
- Project-Adapter-Vertrag: Schema, Versions- und Capability-Gates sowie die Pfadgrenzen des Adapter-Roots anhand manipulierter Kopien.
- Cleanup-/Recovery-Vertrag: sichtbarer Providerfehler, persistierter
  `RECOVERY_REQUIRED`-State, Fehlerhistorie und erfolgreicher Wiederholungsversuch.
- Storage-Residency-Inventar: stabile Objektidentitäten, host-sichtbares
  `Lab_Data`, native Runtime-Volumes, externe Referenzen, Retention,
  Orphan-Kandidaten und ausdrücklich unverifizierbares physisches Backing.
- Podman-Bootstrap: bereits erreichbare Runtime, eindeutige Machine-Auswahl,
  Startfehler, Timeout und hostweit serialisierter Parallelstart.

Der interaktive Menüpfad darf das bereits laufende Modul nicht innerhalb von `Invoke-SqlServerLab` erneut mit `Import-Module -Force` laden. Eine Selbst-Neuladung entfernt die gerade verwendeten Hilfsfunktionen aus dem Funktionskontext.

## Einzelprovider-Smoke-Test

Der bestehende Test prüft einen explizit gewählten Provider vollständig:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider hyperv
```

`-Provider auto` wählt weiterhin genau einen erreichbaren Container-Provider, bevorzugt Docker vor Podman. Ein erfolgreicher Docker-Lauf ist kein Nachweis für Podman und umgekehrt.

`-Provider hyperv` startet den Hyper-V-native Smoke-Test (`Invoke-HyperVSmokeTest.ps1`) und überprüft damit ausschließlich den VM-/VHDX-/Image-Builder-Lifecycle (ohne SQL-Containerlaufzeit).

## Gemischter Container-Provider-Smoke-Test

Der folgende Test prüft Docker und Podman innerhalb eines gemeinsamen Runs:

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

Er benötigt einen Runner, auf dem beide Runtimes erreichbar sind. Die beiden
Instanzen gehören zu einem einzelnen Lab und werden im Lifecycle nicht parallel
als unabhängige Jobs provisioniert.

Eine vorhandene, gestoppte Podman-Machine wird vor Podman- und Mixed-Smokes
durch `Tests/Integration/Initialize-PodmanRuntime.ps1` automatisch gestartet.
Podman muss installiert und mindestens eine Machine bereits angelegt sein.

## Batch-/Queue-Runtime-Smoke-Test

Der Batch-Smoke erzeugt zwei Umgebungen über die persistente Queue, führt sie
mit zwei Workern aus, prüft eindeutige RunIds und idempotentes Scheduler-Resume
und baut anschließend beide Operation-Scopes wieder ab. Das synthetische
SA-Passwort wird nur über eine temporäre `SQL_SERVER_LAB_SECRET_*`-
Prozessvariable an die Worker vererbt.

```powershell
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 `
    -Provider hyperv `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Der Hyper-V-Workflow kann denselben Nachweis gezielt und erhöht auf dem
Self-hosted Runner ausführen, ohne den Nightly-Lauf zu wiederholen. Der Modus
`slot-batch` wählt ohne explizite Artifact-ID das neueste reale `OS_SEALED`-
Artifact und entfernt beide erzeugten Slot-Scopes nach dem Test.

Der Modus `shared-environments` ist der eng begrenzte Bereitschaftsnachweis für
die dauerhaft registrierte Testgruppe. Er startet nur gebundene Windows-VMs und
vorhandene SQL-Engine-Dienste, falls sie nicht laufen, und führt anschließend
die bestehende SQL-/CMS-Abnahme für alle sechs Ziele aus. Er provisioniert oder
löscht keine Testumgebung und ersetzt keinen Nightly-Lauf.

## Backup-/Restore-Smoke-Test

Der echte Restore-Test verwendet ausschliesslich eine zur Laufzeit erzeugte
synthetische Datenbank. Er erzeugt ein temporaeres `.bak`, prueft dessen
SHA-256 und stellt es ueber die gespeicherte Run-/Providerbindung wieder her:

```powershell
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

Die Remote-Workflows fuehren den Test nach dem jeweiligen SQL-2025-Lifecycle
für Docker beziehungsweise Podman unter demselben hostweiten Mutex aus.

Der lokale PSR-008-Cross-Provider-Nachweis verwendet zusätzlich dieselbe
test-eigene Quelle für Docker → Podman und registriert nur den sanitierten
Inhaltsdigest:

```powershell
.\Tests\Integration\Invoke-BackupLibraryCrossProviderAcceptance.ps1
```

## Provider-Referenztest

Der bevorzugte übergreifende Test ist:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Ohne weitere Parameter werden alle implementierten und lokal erreichbaren Provider erkannt. Pro Provider wird ein vollständiger Lifecycle mit der Referenzversion ausgeführt:

```text
Provisionierung
→ Datenbank
→ SQL-Skript
→ Restart
→ Persistenzprüfung
→ Stop
→ Start
→ Cleanup
```

Nicht erreichbare Provider werden als `SKIP` ausgewiesen. Ein erreichbarer, aber fehlerhafter Provider führt zu `FAIL` und Exitcode `1`.

SQL_Server_Lab prüft im eigenen Runtime-Gate genau die Referenzversion SQL
Server 2025. Der Katalog bleibt versionsoffen, aber reale Kompatibilitätsläufe
für 2019 und 2022 gehören in die Partnerprojekte SQL Analyze und Toolbelt, in
denen die versionsabhängigen Workflows tatsächlich verwendet werden.

### Parallelitätsprüfung

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -IncludeParallel
```

Der Paralleltest prüft gleichzeitig laufende Labs je verfügbarem Provider.
Aktuell werden bis zu vier SQL-Server-2025-Szenarien verwendet:

- zweimal Docker / SQL Server 2025;
- zweimal Podman / SQL Server 2025.

Geprüft werden:

- eindeutige RunIds und ScopeIds;
- eindeutige Hostports;
- voneinander getrennte Run-States;
- isolierter Cleanup eines Runs;
- Fortbestand der übrigen Runs;
- vollständiger abschließender Cleanup.

### Erweiterte lokale Parallelitätsabnahme

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -IncludeParallel
```

## Remote Runner

Der Workflow `PR Gate` führt bei Pull Requests auf Windows und Ubuntu nur die
von `Tools/Get-CiTestSelection.ps1` ermittelten statischen Suites aus. Je nach
Änderungsbereich wird höchstens der passende Docker-, Podman-, Mixed-, Hyper-V-
oder Adapter-Smoke zugeschaltet. Reine Dokumentationsänderungen starten keine
Runtime. Unbekannte produktive Änderungen verwenden Docker als sicheren
repräsentativen Fallback.

Ein Push auf `main` startet keine erneute Vollmatrix. Der tägliche Workflow
`Nightly Regression` führt stattdessen alle statischen Suites, alle Runtime-
Smokes sowie die SQL-/CMS-Abnahme der gemeinsam exportierten Testumgebungen aus.
Der native Gruppen-Lifecycle kann ergänzend mit
`Invoke-TestEnvironmentGroupLifecycle.ps1` ausgeführt werden; er beweist den
öffentlichen Ablauf Start, Live-Export `READY`, nicht-destruktiver Windows-Stopp
und fail-closed Export bei unveränderten Registrierungen und Linux-Mitgliedern.
Im garantierten Abschluss stellt er alle Windows-Mitglieder wieder bis
`READY` bereit, damit der Nachweis die persistente Testgruppe nicht außer
Betrieb hinterlässt.
Fehler werden in einem wiederverwendeten GitHub-Issue sichtbar gehalten. Die
frische Hyper-V-/SQL-Installation läuft zusätzlich wöchentlich oder manuell.

Self-hosted Runtime-Jobs aus Pull Requests werden nur für Branches desselben
Repositories ausgeführt. Fork-Code erhält keinen Zugriff auf die privilegierten
SQL-/Hyper-V-Runner und wird auf GitHub-hosted Runnern statisch geprüft; die
vollständige Runtime-Abdeckung folgt über den vertrauenswürdigen Nightly-Lauf
von `main`.

Die Runtime-Tests verwenden ausschließlich dafür gekennzeichnete Self-hosted Runner:

| Workflow | Erforderliche Labels |
|---|---|
| Docker Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker` |
| Podman Runtime Smoke | `self-hosted`, `SQL_Lab`, `Podman` |
| Mixed Provider Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker`, `Podman` |
| Hyper-V Lifecycle Smoke | `self-hosted`, `SQL_Lab`, `Hyper-V` |

Die Workflows werden bewusst nicht auf einem generischen `self-hosted`-Runner ausgeführt. Der mutierende Teil jedes Docker-, Podman- und Mixed-Provider-Smoke-Tests hält einen gemeinsamen hostweiten Mutex. Dadurch können auf demselben Runner keine zwei Runtime-Lifecycle-Tests gleichzeitig Ressourcen erzeugen oder entfernen, ohne dass GitHub wartende Workflow-Läufe verwerfen muss. Die Parallelität wird innerhalb des jeweiligen Smoke-Tests kontrolliert erzeugt.

Remote-Läufe befinden sich unter:

```text
.github/workflows/static-contracts.yml
.github/workflows/nightly-regression.yml
.github/workflows/adapter-smoke-github-hosted.yml
.github/workflows/runtime-smoke-docker-github-hosted.yml
.github/workflows/runtime-smoke-docker.yml
.github/workflows/runtime-smoke-podman.yml
.github/workflows/runtime-smoke-mixed-providers.yml
.github/workflows/runtime-smoke-hyperv.yml
```

Die Runtime-Workflows sind wiederverwendbar und enthalten keine Kopie der
statischen Vollregression. Der stabile Pflichtcheck für Branch Protection heißt
`PR Gate`; veraltete PR-Läufe werden automatisch abgebrochen.

## Voraussetzungen

- PowerShell 7.2 oder neuer;
- laufendes Docker; Podman muss installiert sein, eine vorhandene gestoppte
  Podman-Machine wird automatisch gestartet;
- `sqlcmd`;
- genügend RAM, Storage und freie Ports im Bereich 14330 bis 14399;
- Zugriff auf die konfigurierten SQL-Server-Container-Images;
- für den Hyper-V-Lifecycle-Smoke einen freigegebenen Windows-Host mit Hyper-V;
  der Test registriert nur eine synthetische Parent-VHDX, erzeugt ein Child und
  keine OS-/SQL-VM;
- für Podman unter Windows eine funktionierende Localhost-Weiterleitung, siehe `Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md`.

## Fehlerdiagnose

Fehlgeschlagene Labs für eine lokale Diagnose behalten:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider docker `
    -KeepOnFailure
```

Danach:

```powershell
Get-SqlServerLab -Detailed

docker ps -a --filter 'label=sql-server-lab.run-id'
# oder
podman ps -a --filter 'label=sql-server-lab.run-id'
# oder fuer den isolierten Hyper-V-Lifecycle
Get-VM | Where-Object Notes -Like 'SQL_SERVER_LAB:*'
```

Die Remote-Workflows verwenden `KeepOnFailure` nicht. Sie versuchen den normalen testseitigen Cleanup und beenden den Job bei einem Fehler mit Exitcode `1`.
