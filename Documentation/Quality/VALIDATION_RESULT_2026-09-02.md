# Validierungsbericht 2026-09-02

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_MULTI_VOLUME_HOST_TOOL_HYPERV_CATALOG_CAS_AND_LAST_RUNTIME_REMOVAL_PASS` |
| Provider | Docker Desktop, Podman-WSL, nativer Hyper-V-Host und isolierter Hyper-V-Linux-Gast, jeweils getrennte Läufe |
| Verträge | `SqlServerLab.ContainerInstanceStoreIntent/1.0`; `SqlServerLab.PersistentStorageCatalog/1.0`; zentraler Host-Tool-Vertrag; `SqlServerLab.ExternalRuntimeContainerAcceptance/1.4` |
| Scope | Persistente External-Runtime-Sidecars; Docker-/Podman-/Python-Auflösung in neuen Prozessen; revisionsgeschützte Hyper-V-Instanzstore-Writer; letzter Container-Runtime-Removal |

Die unveränderten breiteren External-Runtime-Befunde vom 2026-08-28/29 und der
Hyper-V-Befund vom 2026-08-27 werden nicht neu ausgeführt und bleiben als
übernommene Evidence gültig. Dieser Bericht ergänzt sie um den neuen
PSR-005-Mehr-Volume-Nachweis.

## Ergebnis

Der PSR-005-Mehr-Volume-Pfad bestand die vorhandene native
Container-Instance-Store-Abnahme getrennt für Docker und Podman. Beide Läufe
lösten den Provider über den zentralen Host-Tool-Resolver auf und bestätigten:

- Auswahl des detached Stores über seine stabile `PersistentStorageId`;
- rollenfeste Revalidierung beider Sidecars samt SQL-Major-Version;
- Continue-Bindings für Systemvolume und beide Sidecars;
- read-only Clone jeder Quelle in ein eigenes Zielvolume;
- getrennte Datei-, Byte- und SHA-256-Postconditions im Recovery-Journal;
- unveränderten SQL-Serverzustand und eine erreichbare Benutzerdatenbank;
- je einen provider- und laufgebundenen Marker in beiden Clone-Sidecars;
- atomaren Katalogcommit des Clone-Ziels und vollständigen Test-Cleanup.

Die fokussierte statische Suite bestand mit 20 Prüfungen. Sie bestätigt
zusätzlich, dass eine fehlende oder nicht rollenfest gelabelte Sidecargruppe vor
jeder Mutation blockiert und nicht als bestehender Store adoptiert wird.

## Ausgeführte Nachweise

```powershell
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-ContainerInstanceStoreChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider docker
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider podman
```

## Grenze

Die Evidence gilt für neu rollenfest gelabelte Sidecargruppen. Ältere Gruppen
ohne gemeinsame stabile Storage-ID und Rollenlabels bleiben absichtlich
fail-closed; diese Welle führt keine implizite Bestandsmigration oder
nachträgliche Adoption durch.

## Host-Tool-Auflösung in eigenständigen Prozessen

Die Host-Tool-Welle schließt die Lücke zwischen produktivem Modulimport und
eigenständig gestarteten Runtime-Acceptances. Docker, Podman und Python werden
weiterhin nur im aktuellen Prozess aufgelöst; Benutzer- und Maschinen-`PATH`
bleiben unverändert. Vor der Aussage, ein Werkzeug sei nicht vorhanden, müssen
Agenten und Tests jetzt den zentralen Initializer ausführen und zwischen
`HOST_TOOL_NOT_FOUND`, Runtime-Erreichbarkeit und Berechtigung unterscheiden.

Die fokussierte Resolver-Suite bestand 19/19 Prüfungen. Ein zusätzlicher Probe
mit vollständig ersetztem geerbtem Prozess-`PATH` löste alle drei Werkzeuge über
exakte sichere Overrides auf. Die AST-Prüfung bestätigt, dass weder produktive
Pfade noch eigenständige Runtime-Acceptances nackte Docker-/Podman-Befehle oder
providerindirekte `PATH`-Aufrufe enthalten.

Docker und Podman bestanden anschließend getrennt den nativen SQL-2025-Smoke
mit jeweils 34/34 Prüfungen. Die gemeinsame read-only Runtime-Scope-Acceptance
bestand 8/8 Prüfungen und bestätigte unveränderte Container, Volumes, Contexts,
Connections und Machines. Die beiden Smoke-Runs hinterließen jeweils null
Container und null Volumes. Die betroffenen statischen Suites sowie das genau
einmal ausgeführte Abschluss-Gate endeten mit
`ALLE STATISCHEN VERTRAGSPRUEFUNGEN: PASS`; Release Readiness bestand 18/18.

```powershell
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-HostToolResolutionChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-PodmanBootstrapChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-SmokeTest.ps1 -Provider docker
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-SmokeTest.ps1 -Provider podman
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-ContainerRuntimeScopeAcceptance.ps1
```

Der Resolver kann installierte Werkzeuge auffinden und absolute Aufrufe
bereitstellen; er startet nicht automatisch Docker Desktop und errät keine
Podman-Machine oder Connection. Runtime-Start und Zugriff bleiben getrennte,
explizit diagnostizierte Operationen.

## Revisionsgeschützte Hyper-V-Instanzstore-Writer

Reservierung, Abschluss und Recovery-Markierung regulärer persistenter
Hyper-V-Instanzstores verwenden denselben Katalog-Mutationskern wie die bereits
umgestellten Artefaktwriter. Preview blieb ohne Katalogdatei, veraltete
Revisionen änderten keinen Spiegel, und der Abschluss nach VHDX-Erzeugung sowie
Attachment akzeptierte exakt die Revision der vorherigen Reservierung.

Die fokussierte Katalogsuite bestand 40/40 Prüfungen. Der native Hyper-V-
Lifecycle-Smoke bestätigte Hostzugriff, VM-/VHDX-Lifecycle und vollständigen
scopegebundenen Cleanup. Die präzisere Daten-VHDX-Acceptance reservierte die
Quelle, committed deren echte DiskIdentifier-Postcondition revisionsgeschützt,
klonte sie quellenunverändert, reattachte und releaste den Clone und entfernte
alle test-eigenen Ressourcen. Beide nativen Läufe installieren weder Windows
noch SQL Server und sind daher kein Gast- oder SQL-Onlinenachweis.

```powershell
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-PersistentStorageCatalogChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-HyperVSmokeTest.ps1
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-HyperVPersistentDataDriveAcceptance.ps1
```

## Entfernung der letzten Container-Runtime

Der journalgebundene External-Runtime-Reconcile-Pfad bestand getrennte native
SQL-2022-Abnahmen für Docker und Podman im isolierten Ubuntu-22.04-/cgroup-v1-
Gast. Ausgehend von Python/R nach zuvor belegtem Python/R/Java-Refresh und
eigentumsgebundenem Java-Removal wurde jeweils die letzte Runtime entfernt.
Beide Provider bestätigten:

- Planoperation `RemoveExternalRuntime` mit leerem Ziel-Image-Key;
- Ersatzcontainer auf `mcr.microsoft.com/mssql/server:2022-latest` ohne Build
  eines leeren Derived Images;
- Übernahme des bestehenden SQL-Systemvolumes und eines SQL-Datenmarkers;
- konfigurierte und wirksame Deaktivierung `external scripts enabled = 0/0`;
- Connection-State ohne `externalRuntime` und leeren Installation-Receipt-Satz;
- ausgehängte, aber bis zum normalen Run-Cleanup erhaltene External-Language-
  und External-Library-Sidecars;
- erneute SQL-Readiness und Datenmarker nach providergebundenem Restart;
- Journalstatus `COMPLETED`, vollständigen Run-Cleanup und explizite Entfernung
  aller drei test-eigenen Derived Images.

Die sanitisierten Evidence-Dateien liegen außerhalb des Repositorys unter
`D:\Lab_Base\Linux\ExternalRuntimeAcceptance\evidence\external-runtime-2022-docker-6c75245779954d64b3b348a467237582.json`
und
`D:\Lab_Base\Linux\ExternalRuntimeAcceptance\evidence\external-runtime-2022-podman-6c75245779954d64b3b348a467237582.json`.
Der zugehörige temporäre Gast und sein Run-Verzeichnis wurden nach dem
erfolgreichen Lauf entfernt.

```powershell
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-ExternalRuntimeReconcileChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Static/Invoke-ExternalRuntimeContainerImageChecks.ps1
pwsh -NoLogo -NoProfile -File Tests/Integration/Invoke-ExternalRuntimeContainerHyperVHost.ps1 -SqlVersion 2022 -BootstrapTimeoutSeconds 900
```
