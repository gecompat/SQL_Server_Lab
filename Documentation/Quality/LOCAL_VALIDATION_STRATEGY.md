# Lokale Validierungsstrategie

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_WITH_GAPS` |
| Stand | 2026-08-27 |
| CI/CD | keine Voraussetzung für die lokale Produktfunktion |
| Ziel | reproduzierbare lokale Prüfung von Verträgen und Provider-Runtime |

## 1. Grundsatz

`Invoke-WindowsLocaleChecks.ps1` prueft portable Normalisierung, Schema,
Wizard-/Batch-Bindung, Image-Sprachgrenze, Lock-Idempotenz und widerspruechliche
Receipts. Die Hyper-V-Umgebungssuite prueft den nach OOBE geschriebenen Receipt.
Der gesonderte `Invoke-HyperVWindowsLocaleAcceptance.ps1` prueft einen eigenen
Batch mit US-Profil nach Kaltstart; ein erfolgreicher Lauf ist noch offen.

`Invoke-BlockingActionProgressChecks.ps1` prueft einen mit `Thread.Sleep`
blockierten Hauptthread: Heartbeat ab fuenf Sekunden, Drosselung,
Phasenwechsel, Secretfreiheit, verschachtelte Aufrufe und Cleanup ohne
Beenden eines geliehenen Reporters. Ein echter PowerShell-Terminaltest vom
2026-09-10 zeigte die formatierten Zeilen bei 00:05 und 00:06 und entfernte
die Anzeige anschliessend. Ein weiterer Terminaltest bestaetigte den
Finally-Cleanup; er wird nicht als gezielt nachgewiesener Ctrl-C-Abbruch
gewertet. Die statische Suite stoppt zusaetzlich eine echte Pipeline waehrend
eines synchronen .NET-Aufrufs und bestaetigt den Reporter-Cleanup nach dessen
Rueckkehr. Der WMI-Transport bleibt unveraendert; ein vollstaendiger neuer
Legacy-Gastlauf ist damit nicht behauptet.

`Invoke-HyperVPersistentDataDriveChecks.ps1` prueft Operations-Lease,
Recovery-Markierung und Reattach-/Release-Abschluss mit schreibfreier Preview,
Revisionskonflikten und bestehenden Clone-/Resume-Fehlerpfaden.
`Invoke-HyperVPersistentDataDriveAcceptance.ps1` serialisiert den kleinen
nativen VHDX-Nachweis am Runtime-Mutex; Cleanup bindet die erzeugte VM-ID
und den eigenen Temp-Pfad und erhaelt Dateien bei VM-Cleanupfehlern.
Der lokale native Lauf auf 84ffc91 vom 2026-09-10 bestand: 64-MB-Test-VHDX,
ausgeschaltete eigene VM, unveraenderte Quelle, unabhaengiger Clone mit neuer
DiskIdentifier, Reattach, Release und Cleanup. SQL- und Gast-Evidence dieses
kleinen Hosttests ist modelliert und bleibt ausdruecklich separat.

`Invoke-ContainerInstanceStoreChecks.ps1` prueft auch Preview und veraltete
Revisionen fuer Clone-Lease und Zielregistrierung. Die synthetischen Spiegel
bleiben bei Preview unveraendert; Apply registriert das Ziel und loest die
Quell-Lease in derselben Revision. Copy-/Katalogfehler und Resume bleiben
Bestandteil der Suite; diese Pruefung startet keine Container-Runtime.

Der regulaere Container-Lease-Erwerb und -Release verwenden ebenfalls den
gemeinsamen Katalogkern. Die Katalogsuite prueft deren Previews, erwartete
Revisionen und den fehlerhaften Release: `RECOVERY_REQUIRED` wird im Apply
vor dem Fehler committed, waehrend derselbe Preview keinerlei State schreibt.

`Tools/Get-SqlServerLabCapabilityInventory.ps1` liefert den aktuellen
maschinellen Produktquellen-, Export-, Provider-, Test- und Planungsindex.
`Tests/Static/Invoke-CapabilityInventoryChecks.ps1` prueft Exportparitaet,
portable Dateiverweise, Evidenzgrenzen, fehlerhaftes JSON und das Nichtverfolgen
von Symlinks/Junctions einschliesslich indirektem Modulimport. Das Inventar
fuehrt keine Tests oder Runtime-Probes aus und ersetzt keinen semantischen
Backlog-Abgleich.

Die Persistent-Storage-Katalogsuite prueft auch den umgestellten
Container-Datenbankreferenz-Writer: Preview ohne Katalogschreiben, genau eine
Revision beim Apply, stabile Referenz-IDs bei No-op sowie Abweisung einer
veralteten Revision und eines fremden Runs. Die übrigen direkten Writer bleiben
separate PSR-003-Folgearbeit.

`Tests/Static/Invoke-SkillChecks.ps1` validiert die drei Repository-Skills unter
`.agents/skills`: eindeutige Namen, einfache YAML-String-Metadaten, vorhandene
repositorygebundene Verweise und tatsaechlich exportierte Fachbefehle.
Negative Header-Faelle pruefen den Validator selbst. Zusaetzlich bestand der
Skill-Creator-YAML-Validator fuer jede Datei. Diese Nachweise pruefen die
versionierten Dateien und nicht die Skill-Erkennung eines beliebigen Clients.

`Tools/Test-SqlServerLabClientReadiness.ps1 -Provider docker -Operation Inspect`
prueft den Client ohne Skill, Setup oder Runtime-Start. Der strukturierte
Vertrag `SqlServerLab.ClientReadiness/1.0` nennt fehlende Voraussetzungen,
Warnungen und naechste Schritte ohne Hostpfade oder native Rohfehler. READY
belegt den Bootstrap; `MutationAllowed` und `SkillLoaderVerified` bleiben false.
`Tests/Static/Invoke-ClientReadinessChecks.ps1` prueft fehlende Installation,
ungültige Aufloesung, Ausfuehrungs-/Runtimeberechtigung, Nichterreichbarkeit,
Timeout, ungueltige Antworten und unvollstaendigen Checkout getrennt.

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

Die Foundation-1.8-Identity-, Registration-, Upgrade-, Continuity- und
Rule-Context-Cache-Policies
werden unter `FOUNDATION_INTEGRITY` auf Datei-, Schema-, Katalog- und
Indexebene geprüft. Die projektspezifische Scope- und Authority-Zuordnung steht
in `.ai/IDENTITY_AND_ARTIFACT_REGISTRATION.md` und wird unter
`PROJECT_SEMANTIC` geprüft. Lokale Runtime-Registries bleiben unveränderte,
nicht versionierte Betriebsdaten; ohne Runtime-Änderung ist kein Provider-Smoke
durch diese Governance-Integration betroffen.

Historische Foundation-Upgrades werden unter
`.ai/foundation-upgrade-assessments/` als getrennte, schema-validierte
Assessment-Datensätze nachgewiesen. Der Projektcheck bindet jeden Datensatz an
installierte Version, Zielversion und exakten Foundation-Quellref und vergleicht
die vollständige Kandidatenmenge samt Delta-Gründen, Klassifikation,
Repository-Evidence, Begründung und ausgewählten Capabilities. Eine bloße
Statusliste in der Repo-Map genügt nicht als Upgrade-Nachweis.

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

Der direkte Fortschrittskern wird mit
`Tests/Static/Invoke-ActionProgressChecks.ps1` geprueft. Synthetische Uhrzeiten
belegen die Fuenf-Sekunden-Schwelle, Drosselung, Phasenwechsel und sanitisierten
Messwerte. Ein verzoegerter Loopback-HTTP-Transfer und ein stiller nativer
Kindprozess belegen Zwischenmeldungen vor dem Ende; Redirect-Verweigerung,
Retry, Fehler, Timeout und Reporter-Cleanup werden funktional geprueft.
Die echte Readiness-Poll-Schleife verwendet dabei einen synthetischen sqlcmd-
Ersatz. Diese Tests sind kein SQL- oder Provider-Runtime-Nachweis.

`Tests/Integration/Invoke-ActionProgressAcceptance.ps1 -Provider docker|podman`
baut ohne Download ein synthetisches Scratch-Image ueber denselben nativen
Wrapper. Label- und Image-ID-Bindung schuetzen den abschliessenden Cleanup;
vorhandene Images werden weder ersetzt noch entfernt. Docker und Podman
bestanden diesen Test am 2026-09-10 getrennt. Die separaten SQL-2025-Smokes
bestanden jeweils 34/34 Pruefungen samt Run-Cleanup. Native Runtime-Build-Caches
bleiben unter der bestehenden Providerverwaltung; der Test fuehrt kein Prune aus.

### Statische Prüfung

`Tests/Static/Invoke-JobProgressChecks.ps1` prueft echte lokale PowerShell-Jobs:
stille sechssekuendige Ausfuehrung, Ergebnisreihenfolge, ErrorRecord-Kategorie,
Deadline, Schutz fremder Jobs, gemeinsame Anzeige und unterdrueckte rohe
Gast-ProgressRecords. `Invoke-HyperVGuestProgressChecks.ps1` prueft den
Transportvertrag funktional ohne VM: begrenzte OpenError-Retries, kein
Fallback bei fachlichen oder Ownershipfehlern, temporaeres WinRM-Trust sowie
den gemeinsamen Reporter und die Restdeadline mehrerer Readiness-Probes.
Diese Offline-Pruefungen ersetzen keinen nativen Gast- oder Transfernachweis.
Der vorhandene `Invoke-HyperVCliAcceptance.ps1` prueft den Gastpfad mit einem
eigenen Windows-/SQL-Run aus einer registrierten OS-Baseline. Er verwendet die
gemeinsame Runtime-Sperre, verlangt fuer seine 6144-MB-VM mindestens 7373 MB
freien RAM, vier logische CPUs und 40 GB am registrierten Ressourcenroot.
SQL-Medien muessen bereits hashregistriert sein. Fehlgeschlagenes Cleanup
bewahrt den Test-State; temporaere Testdateien werden nur innerhalb des
validierten eigenen Temp-Roots entfernt.

`Tests/Static/Invoke-ContainerTransferProgressChecks.ps1` prueft den BACPAC-
Reporter und die Fehlerpfade fuer Teilkopie, Import und Cleanup einschliesslich
nativer Ausnahmen. Eine zufaellige eigene Containerdatei bleibt das einzige
Cleanupziel; Versions- und Ownershipfehler verhindern die Mutation.
Die vorhandenen `Invoke-ContainerToolAcceptance.ps1`,
`Invoke-ContainerDatabasePackageExportAcceptance.ps1` und
`Invoke-RestoreSmokeTest.ps1` liefern die getrennten nativen Provider-Nachweise.
Am 2026-09-10 bestanden 17 betroffene statische Suites. Der Gegenbeweis mit der
alten BACPAC-Cleanup-Reihenfolge scheiterte gezielt bei der Teilkopie.
Der Paketexport bestand getrennt auf Docker und Podman mit vollstaendiger
Hashpruefung, Offline-Postcondition und Run-Cleanup. Beide Provider bestanden
zusaetzlich SqlPackage-Version, Restart, BACPAC-Inhalt, Attach-Inhalt und
Attach-Recovery samt Entfernung des Test-Runs und seines Images. Der Schutz
vor vorhandenen Images bindet das exakte geplante Ziel; andere Tool-Images
bleiben mit derselben Tag-/Image-ID-Bindung erhalten. Docker belegt diesen
Gegenfall nativ. Auch die Restore-Smokes bestanden getrennt auf Docker und
Podman mit vollstaendigem Run-Cleanup.
Beide Acceptance-Skripte koordinieren sich mit der Runtime-Sperre, pruefen
Ressourcen und bewahren bei fehlgeschlagenem Cleanup den Recovery-State.

`Tests/Static/Invoke-SessionTransferProgressChecks.ps1` prueft echte asynchrone
PowerShell-Pipelines mit langsamer synthetischer Arbeit, Ausgabeobjekten,
Fehlerkategorien, Deadline und Reporter-Cleanup. Rohe ProgressRecords werden
unterdrueckt. Dieser Offline-Lauf belegt noch keinen echten PSSession-Transfer.

`Tests/Static/Invoke-SqlActionProgressChecks.ps1` prueft Query- und Skript-
Argumente, gemeinsame GO-Verbindung, Statement-/Prozessdeadline, SQL-Exitcode,
Fehlerschwere sowie Cleanup temporaerer Ein- und Ergebnisdateien. Die Ausgabe
verwendet den Unicode-Dateivertrag von
[sqlcmd](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility).
`Tests/Integration/Invoke-SqlActionProgressAcceptance.ps1 -Provider docker|podman`
prueft getrennt an einem eigenen SQL-2025-Run einen langsamen Query-Heartbeat,
geheimnisfreie Anzeige, Unicode, SQL-Fehler, GO-Sessionbindung, Statement-Timeout
und vollstaendigen Run-Cleanup. Ein Lauf ist kein Nachweis fuer den anderen
Provider oder fuer Hyper-V.
Am 2026-09-10 bestanden Docker und Podman jeweils alle acht SQL-Progress-
Assertions samt Run-Cleanup. Der Timeout-Gegenbeweis verwendet eine zwanzig-
sekündige synthetische Wartephase mit einem einsekündigen Statement-Timeout.
Der lokale ODBC-Client lieferte dabei `Timeout expired` bei Exitcode null;
die gemeinsame Fehlererkennung behandelt diesen Fall jetzt als Fehler.
Die anschliessenden SQL-2025-Lifecycle-Smokes bestanden auf beiden Providern
34/34 Pruefungen. Auch `Invoke-RestoreSmokeTest.ps1` bestand getrennt fuer Docker
und Podman mit identischen synthetischen Daten und vollstaendigem Cleanup.
Der Restore-Test validiert seinen temporaeren Cleanup-Root und bewahrt bei
fehlgeschlagenem Provider-Cleanup den State fuer Recovery.

`Tests/Static/Invoke-ArchiveProgressChecks.ps1` prueft ZIP-Byteintegritaet,
Zeitstempel, Zwischenmeldungen, bestehende Ziele, Teilfehler-Cleanup sowie
einen gemeinsamen Reporter fuer Datei- und native Archivschritte.
`Invoke-SampleHandlerChecks.ps1` deckt weiterhin Katalog- und Pfadgrenzen ab.
`Tests/Integration/Invoke-ArchiveProgressAcceptance.ps1` verwendet eine bereits
installierte 7-Zip-Kommandozeile und ein eigenes synthetisches Archiv. Der
Lauf am 2026-09-10 bestaetigte Backup- und Attach-Bytes sowie Fehler-Cleanup;
er benoetigt weder SQL noch Container oder VM und installiert kein Werkzeug.

`Tests/Static/Invoke-TransferProgressChecks.ps1` prueft Kopieren und SHA-256
mit synthetischen Dateien: mehrere Bloecke und Restbytes, Zeitstempel,
gemessene Zwischenwerte, leere Datei, Teilfehler mit erhaltenem Altziel,
Wiederholung und Hardlink-Schutz. Die drei betroffenen Hyper-V-Dateisuites
pruefen die Registry- und Migrationsvertraege ohne VM-Mutation. Diese
Pruefungen ersetzen keinen VHDX- oder Hyper-V-Lifecycle-Nachweis.

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

### Hyper-V External-Runtime-Reconcile

Der additive öffentliche SQL-2022-Windows-/Hyper-V-Reconcile-Vertrag wird
fokussiert ohne Hostmutation geprüft:

```powershell
.\Tests\Static\Invoke-HyperVExternalRuntimeReconcileChecks.ps1
```

Die Suite deckt providergebundenes Routing, Plan/`WhatIf`, Journal vor der
Mutation, No-op, Failure/Resume, PlanKey-Postconditions und die fail-closed
Removal-Grenze ab. Der bestehende native Hyper-V-Acceptance-Aufbau kann den
öffentlichen Reconcile-Pfad in einer erhöhten Sitzung isoliert ausführen:

```powershell
.\Tests\Integration\Invoke-HyperVExternalRuntimeReconcileAcceptance.ps1 -CleanupOnSuccess
```

Der Runner persistiert zuerst einen softwarefreien Desired State und prüft dann
Plan, `WhatIf`, Apply, No-op, Removal-Blockade, ausbleibenden VM-Neustart,
echte SQL-Datenroundtrips und Cold Start. Der Runnervertrag ist statisch geprüft;
die öffentliche Reconcile-Sequenz bleibt bis zu einem tatsächlich erfolgreichen
Lauf `NOT_EXECUTED`.

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
.\Tests\Integration\Invoke-HyperVStorageAcceptance.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVPersistentDataDriveAcceptance.ps1
```

Der letzte Runner benötigt keinen Windows-Gast und belegt mit kleinen,
test-eigenen Ressourcen den nativen Host-Lifecycle einer persistenten VHDX:
unveränderte Quelle, eigenständiger Clone mit neuem DiskIdentifier, Reattach an
eine ausgeschaltete Generation-2-VM, Release, operationsgebundene Leases sowie
atomare Katalogcommits und vollständiger Cleanup. Er
behauptet ausdrücklich keinen SQL-/Gast- oder Datenbank-Onlinenachweis.

Fehlt auf dem Host ein dauerhaft veröffentlichtes SQL-2025-Prepared-Artifact,
kann der vollständige Nachweis stattdessen dessen isolierten N4-Bootstrap
verwenden:

```powershell
.\Tests\Integration\Invoke-HyperVStorageAcceptanceBootstrap.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
```

Der Bootstrap behält den testlokalen N4-State nur nach vollständigem Erfolg
bis zur Übergabe an N5, übergibt Artifact-ID und State-Root maschinenlesbar und
entfernt anschließend zuerst den exakten terminalen Build-State und danach das
isolierte Prepared-Image über die produktive Image-Registry. Beide
Abwesenheits-Postconditions werden geprüft. Bei einem Fehler bleiben State und
Artifact mit `RECOVERY_REQUIRED` für eine sichere Diagnose erhalten. Der
Standardlauf der N4-Abnahme behält weiterhin nichts zurück.

Für den nativen Testdatenbank-Reconcile prüft ein eigener erhöhter Runner den
öffentlichen Plan-/Action-Vertrag mit einer fremden Schutzdatenbank. Er verlangt
ein verifiziertes SQL-2025-Prepared-Artifact und beweist `WhatIf`, Addition,
No-op, eigentumsgebundene Entfernung, erneuten No-op, VM-Restart und
scopegebundenen Cleanup. Derselbe isolierte Lauf erzeugt in einem ausschließlich
prozesslokal gebundenen Testdaten-Root eine hashverifizierte
`LAB_GENERATED`-Baseline, entfernt das Sample, installiert es nachweislich über
den Baseline-Eintrag im Manifest-Lock erneut und entfernt es abschließend wieder
eigentumsgebunden. Ohne dauerhaftes Artifact erzeugt der Wrapper einen
isolierten N4-Stand und entfernt ihn nur nach vollständig grünem Ergebnis:

```powershell
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptanceBootstrap.ps1 `
    -MediaRoot D:\Lab_Base
```

Der erweiterte Runner ist implementiert und statisch gebunden; ein positiver
nativer Baseline-Lauf bleibt bis zur tatsächlichen erhöhten Ausführung
`NOT_EXECUTED`.

Es werden bewusst nicht alle CUs getestet. Docker und Podman verwenden je
einen repraesentativen katalogisierten CU; Windows prueft die frische
Basisinstallation und verwendet ein CU nur bei vorhandenem verifiziertem Paket.
Der empfohlene operative Push-Pfad ist in der lokalen Readiness-Checkliste beschrieben:

```text
.\Documentation\Quality\LOCAL_READINESS_CHECKLIST.md
```

`Invoke-HyperVStorageAcceptance.ps1` ist der getrennte N5-Vertrag für vier
TempDB-Datendateien auf mindestens zwei beziehungsweise der im Intent
geforderten höheren Zahl physischer Geräte, separates TempDB-Log, SQL-Dienstrestart,
dateigenaues CREATE und Restore sowie VM-Restart und Cleanup. Der Runner bleibt
`NOT_EXECUTED`, solange der Host nicht mindestens die im Intent geforderten
physischen Geräte mit eindeutig selektierbaren Storage-Locations und ein passendes `SQL_PREPARED_SEALED`-
Artifact bereitstellt.

Der Referenzlauf wurde am 2026-08-31 nach Einführung der gebundenen Hyper-V-
Ressourcenroots mit drei von drei geforderten physischen Geräten erneut
ausgeführt. Builder-VHDX, Published Image und N5-Lanes wurden über ihre
persistierten Bindungen aufgelöst; SQL-Restart, Create, Backup/Restore,
VM-Restart und Cleanup waren erfolgreich. Die unabhängigen Nachprüfungen fanden
kein Test-Artifact, keinen isolierten State und keine seit Laufbeginn erzeugte
VHDX an den registrierten Locations.

### Reale Windows-Generalize-/Publish-Abnahme

Auf einem Hyper-V-Host mit freigegebenem Windows-Server-2025-Eval-ISO prüft
dieser Runner eine frische unbeaufsichtigte Installation auf einer neuen VHDX,
den produktiven PowerShell-Direct-Generalize-Receipt, die testlokale immutable
Publikation und den garantierten Cleanup. Eine vorhandene `OS_SEALED`-Artifact-
ID liefert ausschließlich die freigegebenen OS-/Lizenzmetadaten; ihre VHDX wird
nicht als Generalize-Quelle wiederverwendet.

```powershell
.\Tests\Integration\Invoke-HyperVWindowsGeneralizeAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

### Reale SQL-Prepared-Image-Abnahme

Dieser erhöhte Windows-Runner verifiziert Windows-Server-2025- und SQL-Server-
2025-Medien samt SHA-256-Sidecars, installiert Windows unbeaufsichtigt auf
einer neuen VHDX und führt den produktiven SQL-`PrepareImage`-/finalen-
Sysprep-/Publish-Pfad aus. Das resultierende testlokale
`SQL_PREPARED_SEALED`-Artifact wird danach über den normalen Manifestpfad als
differenzierende VM geklont. Der Runner prüft Windows-Specialization,
`CompleteImage`, WMI, TCP/IP-Hostzugriff und `SQL_READY_RUN` mit Major-Version
und vier Online-Systemdatenbanken. Abschließend belegt er den unveränderten
Parent-Hash sowie den scopegebundenen Cleanup von Builder- und Manifestlauf.
Die Builder-VHDX wird dabei nicht aus dem State-Verzeichnis zusammengesetzt,
sondern aus `resourceRelativePath` und dem persistierten `Build`-Binding erneut
aufgelöst.

```powershell
.\Tests\Integration\Invoke-HyperVSqlPreparedImageAcceptance.ps1
```

Dieser Nachweis schließt den Windows-2025-/SQL-2025-Prepared-Image-Referenzpfad
vom frischen Build bis zum bereinigten Manifestklon. Weitere Windows-/SQL-
Kombinationen und die breite Datenbank-, Software-, Post-Provisioning- und
Network-Manifestbindung benötigen weiterhin eigene Nachweise.

### Reale Legacy-Run-/Parent-Child-Migration

Der erhöhte HVR-008-Runner verlangt eine exakte Run-ID, den erwarteten VM-Namen,
einen getrennten Legacy-StateRoot und einen registrierten Ziel-DataRoot. Er
veröffentlicht das Parent-Image hashgebunden, migriert und reparentet die
run-eigene VHDX, verschiebt VM-Konfiguration, Paging und Snapshots, belegt zwei
Gaststarts und entfernt die verifizierte Quelle erst nach den abschließenden
Binding-, VHDX-, Parent- und Attachment-Postconditions. Ein nichtterminales
Journal wird aus demselben Plan fortgesetzt. Für einen ursprünglich laufenden
Legacy-SQL-Run validiert `-RequireSqlReadiness` die erwartete SQL-Hauptversion
und beide Restart-Receipts. `-AdoptLegacySqlIdentity` übernimmt fehlende
aktuelle VM-Identität nur aus persistierter abgeschlossener Windows-
Provisionierung und einem erfolgreichen Live-SQL-Probe. Vor dem VHDX-Hashplan
wird der Gast geordnet heruntergefahren; ein Fehler vor Journalbeginn stellt
den laufenden Zustand samt Readiness wieder her. Nach erfolgreicher Migration
wird der ursprüngliche laufende Zustand ebenfalls mit Gast- und SQL-Readiness
wiederhergestellt.

```powershell
.\Tests\Integration\Invoke-HyperVResourceMigrationAcceptance.ps1 `
    -RunId '<run-guid>' -ExpectedVMName '<vm-name>' `
    -LegacyStateRoot '<legacy-state-root>' -DataRoot '<registered-lab-data-root>' `
    -EvidencePath '<path-outside-repository>' -Confirm:$false
```

Ein SQL-gebundener, ursprünglich laufender Kandidat ergänzt:

```powershell
-ExpectedInitialVMState Running -RequireSqlReadiness `
    -ExpectedSqlMajorVersion <major> -AdoptLegacySqlIdentity
```

Diese Parameter und ihre statischen Verträge sind implementiert; ein positiver
realer SQL-Legacy-Migrationslauf bleibt bis zur tatsächlichen Ausführung
`NOT_EXECUTED`.

Die allgemeine `Lab_Data`-Parent-Migration besitzt zusätzlich einen
fail-closed Sicherheitsvertrag: Erkennt der Plan VM-Konfiguration, Snapshots
oder Smart Paging unter dem später zu entfernenden Quellroot, bindet er exakte
VM-, Quell- und Zielidentität. Apply revalidiert den ausgeschalteten Zustand,
journalisiert `Move-VMStorage` als `PENDING`, verlangt exakte Ziel-
Postconditions und überspringt die Mutation bei einem Resume nach bereits
erfolgter Umbindung. Der fokussierte synthetische Nachweis liegt in
`Invoke-StorageMigrationChecks.ps1`. Der reale Runner verlangt die exakte ID
einer kleinen, nicht als Default verwendeten Location ohne Run-, Attachment-,
Binding- oder vorhandene VM-Konfigurationsreferenz:

```powershell
.\Tests\Integration\Invoke-HyperVStorageParentMigrationAcceptance.ps1 `
    -SourceLocationId '<non-default-location-guid>'
```

Er erstellt eine ausgeschaltete Generation-2-Test-VM mit eigener VHDX,
migriert den vollständigen Location-Root auf demselben Volume zu einem
temporären Parent und anschließend zurück. Geprüft werden Configuration,
Snapshot, Smart Paging, VHDX, `LocationId`, unveränderte Quelldateien und der
vollständige scopegebundene Cleanup. Dieser real erhöhte Lauf ist bestanden.
Bei einem Fehler bleiben Test-VM, aktueller Root und Journale als
`RECOVERY_REQUIRED` für eine sichere Fortsetzung erhalten.

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
| einzelne SQL-Instanz | implementiert | implementiert | Windows-2025-/SQL-2025-Manifestklon aus `SQL_PREPARED_SEALED` real validiert; breite Manifestbindung partiell |
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

`Invoke-ArtifactResolverChecks.ps1` ist der deterministische Nachweis für den
lokalen Artifact-Trust-Vertrag: Er simuliert einen einzelnen Download ohne
Katalog-SHA-256, prüft die Erzeugung des lokalen SHA-256-Trust-Records und
fordert anschließend nichtinteraktiv dieselbe Quelle erneut an. Der Folgelauf
muss den hashgeprüften Content-Cache verwenden und darf keinen zweiten Download
auslösen. Der Test benötigt weder Netzwerk noch Container oder SQL Server.
Er registriert außerdem für eine echte ausführbare Katalogvariante ausschließlich
synthetischen lokalen Trust-State und prüft die gemeinsame
Workflow-Projektion auf `user-trusted-generated` mit `CacheStatus: MISS`.
Der öffentliche `Get-SqlServerLabWorkflow` verwendet exakt diesen read-only
Projektionscore. Auch dieser Teil erzeugt keinen Download, keine Freigabe und
keine Provider-Mutation.

`Invoke-BackupLibraryCrossProviderAcceptance.ps1` ist der isolierte PSR-008-
Nachweis: Er erzeugt ein synthetisches Backup in Docker, veröffentlicht es nur
nach `CHECKSUM`, `RESTORE VERIFYONLY`, Host-Hash und Metadatenreceipt, entfernt
die Quelle und restauriert nach Podman ausschließlich per `BackupSetId` und
konfiguriertem `DataRoot`. Die Auswahl prüft Receipt-Status, Verification-
Evidence, Objektpräsenz und SHA-256 erneut. Quelle und Ziel müssen denselben
sanitisierten Inhaltsdigest liefern. Da SQL Server in den verwendeten Linux-
Containern keine FILESTREAM-Evidence liefert, zählt dieser Lauf ausdrücklich
nicht als FILESTREAM-Abnahme. Für `PSR-008` ist das kein offener Testersatz:
FILESTREAM ist laut Microsoft unter SQL Server auf Linux nicht unterstützt,
und die aktuelle Provider-Matrix besitzt daher kein zweites FILESTREAM-fähiges
Cross-Provider-Ziel. Das Kriterium ist `NOT_APPLICABLE` und wird erst bei einer
künftigen Capability-Erweiterung wieder zum verpflichtenden nativen Gate.

`Invoke-DatabasePackageChecks.ps1` prüft den PSR-009-Core deterministisch mit
einer synthetischen MDF-/NDF-/LDF-Dateimenge und einem verschachtelten
FILESTREAM-Container. Der Test beweist rekursive Hashes, Manipulationsschutz,
unabhängige Clone-Dateien, `COPY_THEN_ATTACH`, Journal/Postcondition sowie die
fail-closed Grenzen für ältere SQL-Ziele, FILESTREAM, TDE, Detach-State und
parallele Writer. Er ist bewusst kein Ersatz für einen nativen Windows-SQL-
FILESTREAM-Attach; dessen Acceptance muss separat in Hyper-V laufen.
Die Suite prüft zusätzlich die pfadfreie CLI-/Browser-Inventur per stabiler
`DatabasePackageId`, aufgeschobenes Voll-Hashing beim Refresh, explizite
Integritätsverifikation, die sanitisierte Projektion persistierter
Migrationskategorien und Warnungen sowie den öffentlichen Hyper-V-WhatIf-/
Attach-Vertrag mit stabiler Run-/Instanzbindung, vorab persistiertem Recovery-
Journal und pfad-/hash-/geheimnisfreiem Ergebnis. Die Projektion führt keine
neue SQL-Abfrage aus. `Invoke-WorkflowUiChecks.ps1` prüft zusätzlich die lokale Browseraktion für
den Container-Paketexport: Der Request enthält ausschließlich Run-ID,
Instanz-ID und validierten Datenbanknamen; Host, Port, Pfad und SA-Passwort
werden nicht übertragen. Die reale Docker-/Podman-Acceptance des öffentlichen
Export-Cores bleibt der getrennte Runtime-Nachweis.
Gemeinsam mit `Invoke-BackupLibraryChecks.ps1` prüft die Suite außerdem den öffentlichen,
einzelobjektgebundenen Bestands-Sync: `-WhatIf` schreibt keine Katalogrevision,
der Apply-Pfad registriert nach vollständiger Artefaktverifikation genau eine
stabile ID und die Wiederholung bleibt ein `NO_CHANGE`.

`Invoke-DatabaseMigrationDependencyChecks.ps1` prüft den PSR-010-Core ohne
Runtime-Mutation: Parser und Schema für read-only SQL-Counts, Server-Login-,
Agent-Job-, Proxy-, Linked-Server- und TDE-Kategorien, die
`NOT_OBSERVABLE`-Grenze für Serverkonfiguration/SSISDB/SSAS, das TDE-Recovery-
Gate, den öffentlichen direkten und Run-/Instanz-gebundenen Aufruf sowie
sanitisierte `DATABASE_FILES_ONLY`-Receipts. Der Receipt enthält zusätzlich den
separat schema-validierten `SqlServerLab.DatabaseMigrationExecutionPlan/1.0`.
Die Suite prüft dessen TDE-Blockierung, kategoriebasierten manuellen/externalen
Review-Schritte sowie `MutationAllowed=false` und `TransferAuthority=NONE`; der
Plan führt keine Export-, Import- oder sonstige Runtime-Mutation aus. Der bestehende
`Invoke-DatabasePackageChecks.ps1` prüft ergänzend, dass neue
`DATABASE_PACKAGE`-Receipts diesen Plan nur geheimnisfrei persistieren, seine
kanonischen Felder in den Paketmanifest-SHA-256 aufnehmen und im pfadfreien
Katalog lediglich Status, Schrittzahl und Blocker anzeigen.
`Invoke-BackupLibraryChecks.ps1` prüft die dazu passende Backup-Binding-
Evidence: Neue Backupsets referenzieren die exakt bei der Veröffentlichung
berechnete Objekt-SHA-256, bewahren alle acht nicht ausführbaren Plan-Schritte
und projizieren nur Status, Schrittzahl und Blocker in die Auswahlansicht.
Der bestehende
`Invoke-WorkflowUiChecks.ps1` prüft zusätzlich die lokale Browserbindung der
Containerinventur: Nur Run-ID, Instanz-ID, validierter Datenbankname und
flüchtiges SA-Passwort erreichen die Workflowaktion; die Ergebnisprojektion
enthält ausschließlich Kategorien, Counts, Grenzen und Review-Schritte. Der
Browser parst nur die versionierte `[INVENTAR]`-Projektion aus dem bestehenden
Live-Log und rendert sie strukturiert, ohne einen weiteren Endpunkt oder
Rohdatenpfad einzuführen. Der
UI-Slice führt keine Runtime-Mutation aus; der bestehende öffentliche PSR-010-
Core und dessen separate Runtime-Evidence bleiben maßgeblich.
`Invoke-BackupLibraryCrossProviderAcceptance.ps1` führt die echte SQL-Abfrage
bei der Docker-Backup-Erstellung aus; dies ist kein Windows-TDE-,
Serverobjekt-Export- oder Hyper-V-FILESTREAM-Nachweis.

`Invoke-AiScenarioChecks.ps1` prüft den AI-00-/AI-10-Vertrag ohne laufenden
SQL Server: Manifest- und Package-Schema, portable Modell-/Szenario-PlanKeys,
Dataset- und Skript-SHA-256, pfadfreie öffentliche Projektion, persistierte
Intentbindung, Docker-/Podman-Capability, mutationsfreies `WhatIf`, verweigerten
Cloud-Egress und Traversal-Schutz. Dieser statische Lauf ist kein Nachweis,
dass `VECTOR`, `VECTOR_DISTANCE` oder `AI_GENERATE_CHUNKS` im Container
erfolgreich ausgeführt wurden. Der native Nachweis verwendet einen zuvor per
KI-Manifest erstellten SQL-2025-Run und anschließend
`Invoke-SqlServerLabAiScenario`; Docker und Podman sind getrennt auszuführen.
Der ausführbare, run-eigene Nachweis dafür ist
`Tests/Integration/Invoke-AiVectorCoreAcceptance.ps1 -Provider docker|podman`.
Er prüft Vector-Distanz, Chunking, sanitisierte Evidence und Szenario-Cleanup
und entfernt danach den zugehörigen Provider-Run.

Der modell- und SQL-freie HTTPS-Nachweis des Endpointvertrags läuft separat:

```powershell
.\Tests\Integration\Invoke-AiHttpsEndpointStubAcceptance.ps1
```

Er bindet einen flüchtigen IPv4-Loopback-TLS-Server mit exakt gepinntem
öffentlichem Zertifikat über Custom-Root-Trust an den normalen `HttpClient`.
Geprüft werden Embed- und Generate-Payload, ein echter HTTP-429-Retry sowie die
Ablehnung eines abweichenden Pins. Der Test verändert keinen globalen
Zertifikatspeicher, benötigt keine Modellruntime und räumt Prozess,
Zertifikatobjekte und temporäre Dateien vollständig auf.

Der vollständige lokale RAG-Nachweis wird ebenfalls providergetrennt ausgeführt:

```powershell
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider podman
```

Jeder Lauf verbindet katalogisierte Ollama-Embeddings und -Generierung mit
echter exakter SQL-2025-Cosine-Suche, prüft die erwartete Top-Quelle, startet
SQL und Ollama neu und entfernt Run, Container und Volumes vollständig.

Der read-only Agent besitzt einen eigenen nativen Provider-Nachweis:

```powershell
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider podman
```

Geprüft werden feste SELECT-Werkzeuge, echte Least-Privilege-Sichtrechte,
lokale Generierung, inhaltsfreies Journal, vollständiger Login-Cleanup und ein
erneuter Lauf nach Ollama-Restart.

Der vorbereitete Hyper-V-Paritätsnachweis bindet einen bereits verwalteten
SQL-2025-Run an einen scopegebundenen lokalen Ollama-Container:

```powershell
.\Tests\Integration\Invoke-AiHyperVAcceptance.ps1 `
    -RunId '<laufender-verwalteter-hyperv-sql-2025-run>' `
    -SaPassword $password `
    -OllamaProvider docker
```

Er prüft RAG, den read-only Agenten, Login-Cleanup und einen erneuten Lauf nach
VM- und Ollama-Neustart, entfernt aber niemals den übergebenen Hyper-V-Run.
Am 2026-09-07 wurden RAG, Agent, Login-Cleanup und Ollama-Restart gegen einen
echten verwalteten Hyper-V-SQL-2025-Run erfolgreich ausgeführt. Der Run gehört
zur geschützten automatischen Testgruppe; deren Einzelneustart wurde daher
korrekt abgelehnt und nicht umgangen. Das Ergebnis bleibt `PARTIAL`, bis ein
isolierter Hyper-V-Run auch den VM-Neustart belegt; vorher wird keine
vollständige Provider-Capability deklariert.

Der ausführbare native Windows-SQL-Nachweis ist:

```powershell
# benötigt ein echtes erhöhtes Windows-Token
.\Tests\Integration\Invoke-DatabasePackageSqlAcceptance.ps1
```

Er setzt SQL Server 2025 mit effektivem FILESTREAM voraus und räumt ausschließlich
seine zufällig benannten Datenbanken und `sql-lab-psr009-*`-Wurzeln auf. Ein
nicht erhöhter Prozess endet vor neuer Mutation fail-closed.

Der native Hyper-V-Providernachweis ist:

```powershell
# benötigt Hyper-V-Hostrechte und einen laufenden SQL-2025-Run (alternativ ein Prepared-Artifact)
.\Tests\Integration\Invoke-HyperVDatabasePackageAttachAcceptance.ps1 `
    -RunId '<laufender-verwalteter-sql-2025-run>'
```

Er verwendet mit `-RunId` ressourcenschonend einen laufenden verwalteten
SQL-2025-Run oder erzeugt andernfalls einen isolierten Prepared-Run. Ein
temporärer `Lab_Data`-Root hält alle Paketdaten. Geprüft werden pfadfreie
öffentliche Auswahl, Live-Zielbindung, PowerShell-Direct-Kopie, Gast-Hashes,
Online-/Inhalts-Postcondition, Journal und vollständiger Test-Cleanup.
FILESTREAM bleibt im getrennten lokalen Windows-SQL-Lauf belegt.

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

Nicht freigegebene Archive und Attach-Szenarien müssen mit einer erklärenden
Fehlermeldung abgewiesen werden. Freigegebene Script-Bundles bleiben an ihren
root-gebundenen Entrypoint, ihre erlaubten sqlcmd-Features und die vollständige
erwartete Outputliste gebunden.

`Invoke-SampleBaselineRuntimeChecks.ps1` belegt für Container und Hyper-V
dieselbe portable Registry-, Key-, Lock-, Auswahl- und Fallback-Semantik.
Der Hyper-V-Slice verlangt einen exakten Run, ein flüchtiges Gastcredential,
ein verifiziertes Storage-Receipt und genau eine Backup-Lane. Der synthetische
Test prüft Export, Gast-Cleanup und den bevorzugten run-gebundenen Restore.
Die Storage-Placement-Suite belegt zusätzlich, dass ad-hoc CREATE und RESTORE
ohne explizite Datenbankregel ausschließlich die verifizierten Default-Data-
und Default-Log-Lanes verwenden und partielle Bindungen nicht akzeptieren.
Für den automatischen Hyper-V-Manifestpfad belegt sie den Preflight auf
vollständige Default-Data-/Default-Log-/Backup-Lanes und die Ablehnung
widersprüchlicher Einzelplatzierung; die Hyper-V-Lab-Suite bindet den
run-basierten Sample-Handler statisch an Run, Instanz und Gastcredential.
Eine reale Hyper-V-Ausführung bleibt `NOT_EXECUTED`.

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

### Host-Tool-Auflösung betroffen

```powershell
.\Tests\Static\Invoke-HostToolResolutionChecks.ps1
.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Der statische Resolver-Vertrag prüft sichere exakte Overrides, idempotente
nur-prozesslokale `PATH`-Erweiterung, unveränderte persistierte Benutzer-/
Maschinenwerte sowie die gemeinsame Einbindung in Modulimport und Podman-
Bootstrap. Eine AST-gestützte Vollprüfung über `Private`, `Public` und
`Providers` stellt sicher, dass produktive Docker-/Podman-Aufrufpfade den
zentral aufgelösten absoluten Aufruf verwenden und nicht von einem geerbten
Shell-`PATH` abhängen. Eigenständig gestartete Runtime-Acceptances werden
zusätzlich vor ihrem ersten Provider-Probe zentral initialisiert und verwenden
danach ausschließlich den absoluten `Invocation`-Pfad. Die Runtime-Smokes
bleiben erforderlich, weil
Dateiauflösung weder Engine-Erreichbarkeit noch Ausführungsberechtigung beweist.

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
.\Tests\Static\Invoke-HyperVNetworkReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVResourceReconcileChecks.ps1
.\Tests\Static\Invoke-ContainerReconcileChecks.ps1
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

### Kataloggebundenes SqlPackage, BACPAC oder Container-Attach betroffen

```powershell
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-SoftwareCatalogChecks.ps1
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider podman
```

Die Acceptance erzeugt ein synthetisches BACPAC im gebundenen Container,
importiert es wieder über den normalen Tool-Handler, prüft die importierten SQL-
Daten und die Entfernung des temporären Containerartefakts. Zusätzlich erzeugt
sie eine synthetische Datenbank, detacht deren MDF/LDF, kopiert nur diese
Testpayloads in den Host-Workspace und führt den normalen Container-Attach-
Handler mit ONLINE-, Inhalts- und Journalpostcondition aus. Der garantierte
Run-Cleanup entfernt sämtliche testbezogenen Container und Volumes. Ein zweiter
Attach auf die bereits vorhandene Testdatenbank erzwingt einen SQL-Teilfehler;
der Test verlangt dafür das persistierte `RECOVERY_REQUIRED`-Journal mit der
passenden Detach-Aktion. Sie lädt
kein fremdes Sample-Artefakt herunter.

Der Datenbankpaket-Static-Check ergänzt dazu den öffentlichen Hyper-V-
Recoverypfad: Nur ein für dieselbe Paket-ID, Run-/Instanzbindung und
Zielunterstruktur validiertes `RECOVERY_REQUIRED`-Journal darf mit
`Invoke-SqlServerLabDatabasePackageAttach -Recover` ausgeführt werden.

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
Upgrade-Assessment, Copilot-Adapter oder PR-Gate starten zusätzlich den Job
`Foundation integrity`.
Der PR-Gate und die nativen Docker-, Podman-, Mixed- und Hyper-V-Workflows
brechen einen bereits gestarteten Lauf bei einer neueren Revision nicht hart
ab. Der neue Lauf wartet in derselben Concurrency-Gruppe, damit der laufende
PowerShell-Prozess seinen scopegebundenen `finally`-Cleanup auf dem persistenten
self-hosted Runner ausführen kann. Ein manueller Workflow-Abbruch oder ein
Runner-Ausfall bleibt davon getrennt und ist über Lifecycle-Metadaten,
Maintenance-Plan und objektgebundenes Cleanup zu behandeln.
Die Docker- und Podman-Lifecycle-Gates führen nach ihren jeweiligen Smokes
zusätzlich die öffentliche `DELETE_WITH_RUN`-Acceptance aus. Sie teilen den
bereits gehaltenen Runtime-Mutex, erzeugen einen isolierten rungebundenen Store
und verlangen Registrierung, Missing-Volume-Nachweis sowie `DETACHED`-Katalog-
abschluss; Backup- und Paket-SHA-256-Verträge bleiben davon getrennt.
Danach belegen dieselben getrennten Provider-Gates auch den öffentlichen
`Export-SqlServerLabDatabasePackage`-Pfad unter demselben Parent-Mutex:
`WhatIf`, live gebundene Quelle, exklusives Offline, stabile Paket-/Storage-ID,
vollständige Integritätsprüfung und Cleanup. Die Acceptance akzeptiert keine
freien Container- oder Hostpfade.
Dieser checkt den in `.ai/repo_map.yaml` gebundenen Foundation-Quellcommit aus
und führt den Foundation-Validator mit den projektspezifisch ausgewählten
Adaptern und Capabilities aus. Sein Ergebnis fließt in den geschützten
Abschlusscheck `PR Gate` ein. Auf einen Merge nach `main` folgt keine zweite
Vollmatrix.
Die vollständige statische und native Regression läuft täglich gebündelt als
`Nightly Regression`; eine frische Hyper-V-/SQL-Installation läuft wöchentlich
oder manuell. Nightly-Fehler werden über ein dauerhaftes Tracking-Issue sichtbar.
