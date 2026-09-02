# Validierungsbericht 2026-09-02

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_MULTI_VOLUME_AND_HOST_TOOL_ENTRYPOINT_PASS` |
| Provider | Docker Desktop und Podman-WSL, getrennte Läufe |
| Verträge | `SqlServerLab.ContainerInstanceStoreIntent/1.0`; zentraler Host-Tool-Vertrag |
| Scope | Persistente External-Runtime-Sidecars; Docker-/Podman-/Python-Auflösung in neuen Prozessen |

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
