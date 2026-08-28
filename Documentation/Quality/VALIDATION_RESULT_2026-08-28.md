# External-Runtime-Refresh-/Removal-Validierungsbericht 2026-08-28

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_EXTERNAL_RUNTIME_REFRESH_REMOVAL_PASS` |
| Branch-Stand | `agent/external-language-wave8c`, nativer Abschlussstand `419cdd0` |
| Plattform | isolierter Ubuntu-22.04-Hyper-V-Gast, cgroup v1 |
| Provider | Docker und Podman, getrennte Evidence |
| SQL-Referenz | SQL Server 2022 External Runtimes |
| Image-Rezept | Version 5 |
| Vorheriger Gesamtbefund | [CLI- und Provider-Validierung 2026-08-27](VALIDATION_RESULT_2026-08-27.md) |

## Ergebnis

Der External-Runtime-Lifecycle bestand den echten Produktpfad getrennt für
Docker und Podman. Jeder positive Lauf provisionierte zunächst eine
Python-only-Instanz, änderte anschließend das Zielmanifest auf Python, R und
Java, entfernte Java wieder und führte den verbleibenden Python-/R-Stand durch
einen providergebundenen Restart.

Dieser fokussierte Nachweis erweitert den vollständigen CLI-/Providerbefund vom
2026-08-27. Der dortige Hyper-V-/Windows-External-Language-Befund wurde nicht
erneut ausgeführt und wird in der Repository-Map ausdrücklich als übernommener
Befund bezeichnet.

Beide Provider bestätigten:

- resolvergebundene Klassifizierung `recreate` mit genau einer Aktion;
- Build des neuen inhaltsadressierten Derived Image vor jeder Mutation;
- journalgebundenes Umbenennen des alten und Erstellen des neuen Containers;
- SQL-Readiness und echte Python-, R- und Java-Postconditions;
- atomaren Connection-/Desired-State-Commit und Journalstatus `COMPLETED`;
- eigentumsgebundenen Java-DDL-Cleanup für Sprache, SDK- und Probe-Library;
- Persistenz eines SQL-Datenmarkers über Refresh, Removal und Restart;
- erfolgreichen providergebundenen Restart mit erneuten Python-/R-Probes;
- Cleanup des Containers und aller drei run-eigenen Volumes;
- getrennte Retention und anschließendes explizites Entfernen der Testimages
  sowie des Podman-Testnetzes.

## Charakterisierung und Korrekturen

SQL-Daten bleiben in `/var/opt/mssql` erhalten. Die langlebigen Runtime-
Artefakte unter `externallanguages` und `externallibraries` besitzen zwei
weitere scopegebundene Volumes; LaunchPad-Daten und Sandboxes bleiben
containerlokal. Der Startadapter synchronisiert die katalogisierte ML-EULA,
Runtime-Konfiguration und Artifact-Ownership, wodurch Docker und Podman
denselben Vertrag trotz unterschiedlicher Volume-Initialisierung erfüllen.

Die Linux-Java-Libraries verwenden `PLATFORM = LINUX` in der jeweiligen
`CREATE EXTERNAL LIBRARY`-Dateispezifikation. Ein transienter SQL-Fehler
`39011` oder `39012` erlaubt genau einen Container-Restart mit anschließendem
Probe-Retry. Ein versuchsübergreifender Tracker erhält dabei die Information,
welche Java-Objekte das Lab erstellt hat; Compensation und spätere Removal-
Aktionen bleiben dadurch vollständig und greifen nicht auf fremde Objekte zu.

Die vorherige Python-only-Charakterisierung hatte außerdem die von
`revoscalepy` benötigte OpenMP-Laufzeit `libgomp.so.1` identifiziert. Rezept 5
bindet das offizielle Ubuntu-22.04-Paket `libgomp1` separat per Version und
SHA-256 und extrahiert dieselben compilerfreien Runtimebytes in Python- und
R-Zielstages.

## Evidence und Cleanup

Die sanitisierten, außerhalb des Repositorys gespeicherten Evidence-Dokumente
melden jeweils `PASS`, Refresh und Removal `SUCCEEDED`, Journal `COMPLETED`,
cgroup-Version `1`, bestandene Restart-Probes und vollständigen Cleanup:

| Provider | Evidence-Datei | SHA-256 |
|---|---|---|
| Docker | `external-runtime-docker-wave8c-final.json` | `0CE8EC73CC351F9AABB41F6E4D9ABEE15F5EFE1B0C5DDE6E03A553CF2EFF0BDC` |
| Podman | `external-runtime-podman-wave8c-final.json` | `9306F491A79B17C3B49B9B8DB0C7613C132DE99C37049E67535DAD48CC010F00` |

Nach der Evidence-Sicherung waren in beiden Providern keine verwalteten
Container oder Volumes mehr vorhanden. Die isolierte Diagnose-VM und ihr exakt
zugeordnetes run-eigenes Verzeichnis wurden entfernt; die Evidence blieb im
externen Host-Evidenzverzeichnis erhalten.

## Verbleibende Grenze

Dieser Nachweis gilt für SQL-Server-2022-Docker-/Podman-Runs mit
resolverfreigegebenen Runtime-Varianten. Freie Packagewechsel, der allgemeine
Hyper-V-Softwarepfad sowie Hyper-V-Artifact-Refresh und automatische
Gastumschaltung bleiben außerhalb dieses Slices. Rootless Podman ist für den
SQL-2022-External-Runtime-Namespace-Modus weiterhin nicht freigegeben.
