# Bekannte Grenzen

| Merkmal | Wert |
|---|---|
| Status | `BINDING_LIMITATIONS` |
| Stand | 2026-08-03 |

Dieses Dokument beschreibt bekannte Grenzen des aktuell implementierten Runtimepfads. Es ist Teil des öffentlichen Projektvertrags. Ein Feld im JSON-Schema oder ein Planungsdokument gilt nicht automatisch als Implementierungsnachweis.

## Provider

### Docker und Podman

Docker und Podman sind implementiert. Start, Stop und Live-Status verwenden den
pro Instanz in `connection-info.json` gespeicherten Provider.

### Gemischte Containerprovider in einem Run

Ein Run kann Docker- und Podman-Instanzen enthalten. State, Status, Start, Stop
und Cleanup verwenden dafür getrennte `ProviderSubRuns`. Der implementierte
Umfang und die Recovery-Regeln stehen im
[Gemischten Container-Provider-Lifecycle](../Architecture/MIXED_PROVIDER_LIFECYCLE.md).

Nicht enthalten sind ein gemeinsames providerübergreifendes Containernetzwerk,
Cluster- oder Failoversemantik sowie Hyper-V-SubRuns.

### Hyper-V

Hyper-V besitzt eine ausführbare Lifecycle-Grundlage für eine Generation-2-VM
aus einer verifizierten read-only Parent-VHDX: Differencing Child, Secure Boot,
Status, Start, Stop, PowerShell Direct und scopegebundener Cleanup. Der Native-
Smoke-Test verwendet bewusst eine synthetische leere Parent-VHDX und beweist
weder Betriebssystem- noch SQL-Bereitschaft.

Operatorseitig bereitgestellte, bereits generalisierte `OS_SEALED`- und
`SQL_PREPARED_SEALED`-VHDX können immutable und SHA-256-verifiziert in einer
lokalen Registry abgelegt, deterministisch ausgewählt und per portablem
Manifest Lock an einen Run gebunden werden. Die Registry erzeugt oder
generalisiert diese Images nicht selbst.

Die Windows-Image-Builder-Grundlage verifiziert ein lokales ISO, erstellt einen
persistenten Build-Plan und kann den isolierten Generation-2-Builder samt
Cleanup erzeugen. Die OS-Installation bleibt manuell und wird als
`MANUAL_ACTION_REQUIRED` ausgewiesen. Danach kann die Runtime Sysprep ueber
PowerShell Direct ausfuehren, den erfolgreichen Microsoft-ImageState pruefen,
einen resumierbaren `REBOOT_REQUIRED`-State persistieren, den Gast-Shutdown
beobachten und die buildgebundene Evidenz automatisch erzeugen. Gast-
Credentials werden dabei nicht gespeichert. VM-Auszustand, SQL_Server_Lab-
Identität, fehlende Checkpoints und VHDX-Pfadgrenze werden vor einer immutable
Registry-Publikation geprüft. Der Native-Smoke verwendet keine echte Windows-
Installation und beweist daher kein Gast-Sysprep. Synthetische CI-Builds koennen
ausschließlich `LIFECYCLE_TEST_ONLY`, niemals `OS_SEALED`, veröffentlichen und
duerfen den automatischen Sysprep-Pfad nicht ausfuehren.

Manifeste mit Windows-Betriebssystem oder GUI-Software können bei der Provider-
Auflösung zu `hyperv` führen; `New-SqlServerLab` bricht weiterhin mit einer
klaren Meldung ab, weil die Hyper-V-SQL-Provisionierung noch fehlt.

Nicht implementiert sind insbesondere der unattended OS-/SQL-Image-Build,
`PrepareImage`/`CompleteImage`, zusätzliche VM-Drives,
Network Intents, IPAM, Reconcile und Artifact Refresh. Der
verbindliche Zielvertrag steht in
[Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).

## Manifest und Schema

### Schema ist kein Runtime-Nachweis

`Schemas/lab-manifest.schema.json` enthält neben ausführbaren Feldern auch teilweise vorbereitete Erweiterungsfelder. Direkte `serverConfig`-Eigenschaften sind mit `x-runtimeStatus` als `executable`, `reserved` oder `partially-executable` klassifiziert. Für die tatsächliche Ausführung sind zusätzlich `Private/ManifestParser.ps1` und die zuständige Runtimefunktion maßgeblich.

### Ausgeführte `serverConfig`-Bereiche

Aktuell werden ausgeführt:

- `memory`
- `tempdb`
- `maxDop`
- `costThreshold`
- `traceFlags`
- `spConfigure`
- `externalScripts` einschließlich Resource-Governor-Teilkonfiguration

### Noch nicht zuverlässig angewendete `serverConfig`-Felder

Folgende Schemafelder sind noch kein stabiler Runtimevertrag:

- `collation` innerhalb von `serverConfig`
- `defaultPaths`
- `sqlAgent` als steuerbarer Schalter
- `clrEnabled`
- `filestream`
- `containedDatabases`
- `authMode`
- `errorLogRetention`
- `instantFileInit`
- `externalScripts.customImage`
- `externalScripts.installMethod = pre-built`

Ausführbare Beispiele verwenden diese Felder daher nicht.

## Collation

Die Instanzdefinition enthält eine Collation, die als Default für neu angelegte Datenbanken verwendet wird. Eine abweichende SQL-Server-Instanzcollation wird bei der Containererstellung derzeit nicht gesetzt.

## Datenbankdateien und Volumes

`New-SqlServerLabDatabase` berücksichtigt `path` für Data- und Log-Files. Der angegebene Containerpfad muss vorher über `drives` beziehungsweise einen Volume-Mount bereitgestellt worden sein.

Das Feld `sizeLimitGB` bei Drives ist derzeit Metadatum; Docker- oder Podman-Volumes werden dadurch nicht physisch auf diese Größe begrenzt.

## Restore

Unterstützt werden direkte `.bak`-Dateien aus lokalen Pfaden oder HTTP(S)-URLs.

Nicht automatisch unterstützt werden:

- `.7z`-, `.zip`- oder andere Archive
- Attach-Szenarien mit vorhandenen MDF/LDF-Dateien
- Differential- oder Log-Backup-Ketten
- verschlüsselte Backups mit externen Zertifikaten
- komplexe Mehrfach-Backup-Sets

Bei manuellen Restores ist `-RunId` mit optionaler `-InstanceId` die bevorzugte Identitaet. Provider, Container, Host und Port werden dabei aus der gespeicherten `connection-info.json` aufgeloest. Der direkte Modus mit `-Port` bleibt fuer externe Aufrufer erhalten; ohne `-ContainerName` verwendet er die portbasierte Containererkennung.

## Sample-Datenbanken

`sample`-Referenzen werden auf den Katalog `Catalogs/sample-databases.json` aufgelöst.

Automatisch ausführbar sind Varianten mit direkter `.bak`-URL,
`artifactType: backup` und `runtimeStatus: executable`. Die Installation läuft
über den Sample-Backup-Handler (`Private/SampleArtifactHandlers.ps1`), der die
Sample-Identität an Trust Store, Cache und Run Lock bindet, die Idempotenzregel
`fail-if-exists` durchsetzt und die erwartete Datenbank nach dem Restore als
`ONLINE` verifiziert (`DATASET_READY`).

Die Integrität sichert der Artifact Resolver: Eine Katalog-SHA-256 wird
erzwungen; fehlt sie, gilt der Trust-Pfad `interactive-once` mit einmaliger
interaktiver Freigabe, persistentem Trust Store, inhaltsadressiertem Cache und
Quarantäne bei Hash-Mismatch. Ein nicht interaktiver Aufruf ohne bekannte
Prüfsumme endet mit `TRUST_REQUIRED`. Die im Katalog hinterlegten Prüfsummen
können bei Trust-Pfad-Varianten `null` sein.

Mehrere Samples pro Instanz sind ad-hoc über `New-SqlServerLab -Sample` und den
Menüschritt `Testdatenbanken` wählbar; kollidierende erwartete Ausgaben werden
als `SAMPLE_OUTPUT_CONFLICT` abgewiesen. Der Manifest-Wizard bietet für
`sample`-Felder eine Katalogauswahl mit erwarteter Datenbank, Größe und Lizenz.

Einträge für SQL-Skripte, Archive oder Attach-Verfahren bleiben `descriptive`
und werden mit einer erklärenden Fehlermeldung abgewiesen; sie werden nicht in
einen Restore umgedeutet.

Noch nicht implementiert sind SQL-Skript- und Script-Bundle-Handler,
`LAB_GENERATED`-Baselines, das Überschreiben der erwarteten Zieldatenbanknamen
sowie die Wizard-Navigation mit Zurück/Planvorschau. Ein Sample, das mehrere
Datenbanken erzeugt, wird vom aktuellen Backup-Handler nicht unterstützt.

Der verbleibende Zielvertrag steht in
[Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](../Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md).

## Project Adapter

Der Adaptervertrag `Schemas/project-adapter.schema.json` ist in Version
`0.1-draft` implementiert (`Test-SqlServerLabAdapter`,
`Install-SqlServerLabAdapter`).

Ausgeführt werden ausschließlich relative T-SQL-Entrypoints (`.sql`) innerhalb
des Adapter-Roots gegen eine per RunId aufgelöste Instanz. Nicht enthalten
sind:

- PowerShell-, Binär- oder Setup-Entrypoints (benötigen einen getrennten
  Deployment-Unit-Vertrag);
- die Package-Architektur des Projektintegrationsvertrags: `sqlPackageCatalogs`
  und `defaultPackageRefs` sind reservierte Schemafelder ohne Runtimepfad;
- Observe-/Evidence-Entrypoints, Szenarien und Fault Injection;
- eine automatische Erfolgskontrolle über die Rückgabe der Entrypoints hinaus;
  `validate` meldet Fehler als `PROJECT_ASSERTION_FAILED`.

Die Entrypoints `update`, `validate` und `cleanup` setzen eine existierende
`targetDatabase` voraus; nur `install` darf sie im master-Kontext selbst
erzeugen. Das sqlcmd-Timeout wirkt pro Statement, nicht pro Skript.

Entrypoints werden als reines T-SQL ausgeführt. Die sqlcmd-Skriptebene ist im
Single-Connection-Modus vollständig deaktiviert (`-X1 -x`): `:r`, `:!!`, `:ed`,
der Zugriff auf Host-Umgebungsvariablen und die `$(var)`-Substitution sind nicht
verfügbar. Ein Entrypoint, der eine solche Direktive enthält, bricht mit
`PROJECT_CONTENT_FAILED` ab. Ein künftiger Adapter darf daher keine über `:r`
eingebundenen Zusatzskripte voraussetzen; alle ausgeführten Anweisungen müssen im
Entrypoint selbst stehen (Pfadgrenze des Adapter-Roots). Die Skripte werden vor
der Ausführung als UTF-8 mit BOM übergeben, damit Nicht-ASCII-Zeichen
plattformunabhängig korrekt dekodiert werden; BOM-lose Dateien werden dadurch
nicht mehr in der ANSI-Codepage fehlinterpretiert.

Die Pfadgrenze wird zweifach abgesichert: Das JSON-Schema lehnt bereits offline
Entrypoints mit `..` oder absoluten Pfaden ab, der Resolver erzwingt zusätzlich
Containment im Adapter-Root und lehnt Reparse Points ab.

Als Capabilities werden derzeit nur `sqlcmd` und `container-linux` geprüft.
Die produktiven Adapter für `SQL_Server_Analyze` und `SQL_PerformanceSchulung`
sind noch nicht umgesetzt; die Reihenfolge steht in der
[Project-Adapter-Priorisierung](../Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md).

## SQL Server Builds und CUs

Der Versionskatalog enthält ausdrücklich versionierte Buildmetadaten. Diese Daten sind nicht automatisch aktuell. Ein vorhandener Katalogeintrag bedeutet nicht, dass er das neueste verfügbare CU darstellt.

Kurzbezeichner wie `2022-CU16` werden nur akzeptiert, wenn der Build im Katalog vorhanden ist. Unbekannte CU-Bezeichner werden nicht mehr durch eine vermutete Image-Tag-Konvention ersetzt.

## External Languages

Die Installation von R, Python oder Java ist von SQL-Version, Betriebssystem,
Distribution, Provider, Paketquellen und der jeweiligen Supportmatrix abhängig.
Python ist ausdrücklich auch unter Linux und in Containern vorgesehen; es ist
nicht auf Hyper-V beschränkt.

Das aktuelle `software`-Schema und der External-Scripts-Pfad bilden diesen
providerneutralen Zielvertrag noch nicht vollständig ab. `customImage` wird
derzeit nicht in die Provider-Imageauswahl übernommen. Derived Container Images,
Custom Runtimes und Java-JAR-Registrierung sind nicht automatisiert.

## Tests

Der Integration-Smoke-Test benötigt eine laufende lokale Runtime und `sqlcmd`.

`-Provider auto` wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Das Resource Assessment prüft zusätzlich alle erkannten Provider.

Die statische Konsistenzprüfung ersetzt keinen echten Docker- oder Podman-End-to-End-Test.

## Lokale State- und Secret-Daten

State, Secrets, Connection Information, konkrete Hostpfade und Cache-Dateien liegen außerhalb des Git-Checkouts. Sie dürfen nicht in Issues, Pull Requests oder versionierte Diagnoseartefakte kopiert werden.

## Priorisierte nächste technische Schritte

1. SQL-Skript- und Script-Bundle-Handler mit Verification und Cleanup ergänzen (Sample-Welle 4).
2. `LAB_GENERATED`-Baselines mit Registry, Key und deterministischer Auswahl umsetzen (Sample-Welle 5).
3. Providerneutrale Drive-, Network-, Software- und Reconcile-Verträge gemäß Hyper-V-Zielvertrag umsetzen.
4. Artifact Registry, Refresh/Rebuild und Evaluierungsablauf implementieren.
5. Hyper-V anschließend in den dokumentierten, getrennt testbaren Wellen implementieren.
6. Katalogaktualität, verifizierte Prüfsummen (`catalog-verified`) und Baseline-Kompatibilität kontrolliert pflegen.
