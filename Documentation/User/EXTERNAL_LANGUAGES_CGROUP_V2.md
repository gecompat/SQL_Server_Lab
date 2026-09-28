# External Languages auf cgroup v2

Für eigene SQL-Server-2025-Labs bietet Docker oder Podman eine ausdrücklich
gewählte Variante ohne Launchpad-Sandbox-Isolation. Der Standard bleibt der
isolierte cgroup-v1-Modus. Es gibt keine automatische Umstellung und keinen
Fallback bei einem fehlgeschlagenen Sprachtest.

## Auswahl

Das [vollständige Beispielmanifest](../../Schemas/example-external-languages-cgroup-v2.json)
verwendet Docker; für Podman wird ausschließlich das Providerfeld geändert.

Im Manifest wird für jede gewünschte Sprache die passende Variante angegeben:

```json
"software": [
  { "id": "sql-python", "variant": "sql-python-2025-shared-user-v2", "scope": "sqlExternalRuntime", "optional": false },
  { "id": "sql-r", "variant": "sql-r-2025-shared-user-v2", "scope": "sqlExternalRuntime", "optional": false },
  { "id": "sql-java", "variant": "sql-java-2025-shared-user-v2", "scope": "sqlExternalRuntime", "optional": false }
]
```

Die Instanz benötigt `version: "2025"` und `provider: "docker"` oder `"podman"`.
Eine Teilmenge ist zulässig; unterschiedliche Isolationsmodi innerhalb einer
Instanz werden abgelehnt. Der Manifest-Wizard zeigt dieselben Varianten mit
einem Hinweis auf die fehlende Isolation. Erstellung erfolgt über
`New-SqlServerLab -Manifest <Manifestpfad> -SaPassword <SecureString>`.

Das eigene Image bindet SQL Server 2025 CU9 (17.0.5005.3), das gleichversionierte
Extensibility-Paket sowie die gesperrten Python-, R- und Java-Artefakte.
Imageidentität und Run-State erhalten die Variantenwahl. Ein öffentlicher
`Restart-SqlServerLab` startet deshalb denselben Modus erneut.

## Grenzen

Launchpad startet mit `-usens=false -usesameuser=true`. Alle Sprachworker laufen
als `mssql_launchpadd`; die sonstige Trennung der Worker und die ausgehende
Netzwerkisolation durch Launchpad entfallen. SQL-External-Resource-Pool-Werte
sind kein Nachweis wirksamer Ressourcenisolation für diesen Modus. Die äußeren
Containerlimits bleiben bestehen. Diese Variante ist für eigene Labskripte
gedacht, nicht für die Ausführung nicht vertrauenswürdiger Skripte verschiedener
Benutzer. Eine Hersteller-Supportzusage wird daraus nicht abgeleitet.

Voraussetzung ist eine eindeutig rootful Linux-Runtime mit cgroup v2.
Rootless, SQL 2019/2022 und unbekannte Hostfähigkeiten werden abgelehnt.
Der Provider verwendet explizite Capabilities einschließlich `SYS_ADMIN`
und die gebundenen Security-Optionen, keinen privilegierten Container und
keinen Bind-Mount der Host-cgroups. Der cgroup-Namespace bleibt privat.
Beim Start prüft der Launcher `cgroup2fs`, `cgroup.controllers` und die
Abwesenheit aller cgroup-v1-Mounts. Er stellt weder Hostkernel noch Mounts um.

## Validierung

`Tests/Integration/Invoke-ExternalRuntimeCgroupV2Acceptance.ps1` erstellt einen
eigenen Run über den öffentlichen Manifestpfad. Er prüft echte Python-/R-/Java-
Datenroundtrips, Workeridentität, SQL-Build und reine cgroup-v2-Mounts vor und
nach einem öffentlichen Restart. Abschließend entfernt er seine Runressourcen;
wiederverwendbare Images und lokale Diagnose bleiben getrennt erhalten.
Docker und Podman benötigen jeweils einen eigenen Lauf. Der frühere Spike
belegt die technische Möglichkeit unter WSL2-basierten Providerhosts; er ersetzt
weder diesen Produktnachweis noch einen Bare-Metal-Nachweis.

```powershell
./Tests/Integration/Invoke-ExternalRuntimeCgroupV2Acceptance.ps1 `
  -Provider docker -EvidenceRoot <neuer-lokaler-Diagnoseordner>
```

Mit `-InstallViaReconcile` erstellt derselbe Runner zunächst ein Lab ohne
Sprachruntime und eine synthetische Datenbank. Anschließend installiert der
öffentliche Reconcile-Pfad alle drei Sprachen durch Containerersatz. Die
Sprachtests und der Datenbankinhalt werden vor und nach Restart geprüft.
Die persistierte Storage-ID bleibt dabei erhalten; neue Runtime-Sidecars
gehören zu demselben Store. Direkte Erstellung und Nachinstallation benötigen
getrennte Läufe je Provider.
`-Language Java` prüft das reine Java-Image mit seinem separaten finalen
Containerfile-Stage; ohne den Parameter werden alle drei Sprachen gewählt.

Ein vorhandener persistierter Software-Intent bleibt die Autorität. Das
nachträgliche Ändern eines schon installierten Isolationsmodus durch Austausch
des Manifests ist kein unterstützter Wechselpfad. Für die hier beschriebene
Nachinstallation beginnt der Run ohne External Languages.

## Ausgeführte Produktabnahme

Am 2026-09-27 bestanden getrennte native Läufe auf rootful, WSL2-basierten
Linux-Hosts mit Docker Engine 29.8.0 und Podman Server 6.0.2:

| Workflow | Docker | Podman |
|---|---|---|
| Direkte Manifest-Erstellung, drei Sprachen, Restart, Cleanup | PASS | PASS |
| Reines Java-Image, SQL-Roundtrip, Restart, Cleanup | PASS | PASS |
| Nachinstallation über Reconcile, Datenbankerhalt, drei Sprachen, Restart, Cleanup | PASS | PASS |
| `cgroup2fs`, Controllerdatei, keine v1-Mounts | PASS | PASS |
| Kein privilegierter Container, kein Host-cgroup-Bind | PASS | PASS |

Alle Sprachtests liefen gegen SQL Server 17.0.5005.3 und prüften
`mssql_launchpadd` als Worker. Die Testressourcen wurden jeweils vollständig
entfernt. Lokale Rohdaten und wiederverwendbare Image-Caches werden nicht
versioniert. Diese Evidence gilt weder für SQL Server 2022 noch für Rootless,
Bare Metal, Launchpad-Sandbox-Isolation oder wirksame SQL-Ressourcenisolation.

### Historische Commitzuordnung

Der damalige lokale Abschlussvermerk ordnet die Produktabnahmen dem Featurestand
`bc251775f134f2361174dafcac02613cd383ddb3` zu. Der
[PR-Gate-Lauf 36320431347](https://github.com/gecompat/SQL_Server_Lab/actions/runs/36320431347)
bestand auf diesem Head; er ersetzt keine native Sprachabnahme. Der integrierte
Stand `b08eca4ca57d02dbf418342901f057298c83d1ee` besitzt denselben Git-Baum.
Die einzelnen lokalen nativen Ergebnisdateien enthalten jedoch keine eigene
Commitbindung. Diese historische Zuordnung ist daher kein eigenständiger
commitgebundener Native-Receipt; der Merge-SHA wird nicht als getesteter
Native-Head ausgegeben. Die getrennten Provider- und Isolationsgrenzen oben
bleiben unverändert.
