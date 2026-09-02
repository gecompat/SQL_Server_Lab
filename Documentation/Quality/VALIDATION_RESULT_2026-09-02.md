# PSR-005-Sidecar-Validierungsbericht 2026-09-02

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_MULTI_VOLUME_CONTINUE_CLONE_PASS` |
| Provider | Docker Desktop und Podman-WSL, getrennte Läufe |
| Vertrag | `SqlServerLab.ContainerInstanceStoreIntent/1.0` |
| Scope | SQL-Systemvolume plus External-Language- und External-Library-Sidecar |

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
