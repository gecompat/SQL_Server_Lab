# Bekannte Grenzen

| Merkmal | Wert |
|---|---|
| Status | `BINDING_LIMITATIONS` |
| Stand | 2026-08-27 |

Dieses Dokument beschreibt bekannte Grenzen des aktuell implementierten Runtimepfads. Es ist Teil des öffentlichen Projektvertrags. Ein Feld im JSON-Schema oder ein Planungsdokument gilt nicht automatisch als Implementierungsnachweis.

## Provider

### Docker und Podman

Docker und Podman sind implementiert. Start, Stop und Live-Status verwenden den
pro Instanz in `connection-info.json` gespeicherten Provider.

Der aktuelle vertiefte Nachweis vom 2026-08-27 ist fuer Docker und Podman mit
einem repraesentativen SQL Server 2022 CU18 einschliesslich Chinook, Storage,
Ressourcen, Reconcile, Lifecycle und Cleanup positiv. Der laufende Core-Gate verwendet ausschließlich SQL Server 2025;
Mehrversions-Kompatibilität wird in SQL Analyze und Toolbelt abgenommen. Der
Core-Gate verwendet die native Containercollation
`SQL_Latin1_General_CP1_CI_AS`. Beim expliziten SQL-2025-Systemdatenbankumbau
auf `SQL_Latin1_General_CP1_CS_AS` trat bei Docker und Podman sporadisch der
Loginfehler 18456/State 115 auf. SQL_Server_Lab erkennt nur diesen Diagnosefall
und erstellt den scopegebundenen Container genau einmal neu; wiederholt sich
der Zustand oder tritt ein anderer Readiness-Fehler auf, bleibt der Lauf
fail-closed. Alle Testressourcen wurden scopegebunden bereinigt. Details stehen im
[Validierungsbericht vom 2026-08-27](VALIDATION_RESULT_2026-08-27.md).

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
run-lokale dynamische oder feste Zusatz-VHDX mit SQL-bezogenen Rollen, Status,
Start, Stop, PowerShell Direct und scopegebundener Cleanup. Der Native-
Smoke-Test verwendet bewusst eine synthetische leere Parent-VHDX und beweist
weder Betriebssystem- noch SQL-Bereitschaft.

Builder und reguläre Lab-VMs deaktivieren automatische Hyper-V-Checkpoints.
Die Publikation bleibt fail-closed, wenn dennoch ein Checkpoint vorhanden ist,
und übernimmt eine VHDX erst nach erfolgreicher, hashverifizierter Registry-
Kopie. Erst danach dürfen Builder-VM und buildlokale Quelle entfernt werden.

Operatorseitig bereitgestellte, bereits generalisierte `OS_SEALED`- und
`SQL_PREPARED_SEALED`-VHDX können immutable und SHA-256-verifiziert in einer
lokalen Registry abgelegt, deterministisch ausgewählt und per portablem
Manifest Lock an einen Run gebunden werden. Die Registry erzeugt oder
generalisiert diese Images nicht selbst.

Die Windows-Image-Builder-Grundlage verifiziert ein lokales ISO, erstellt einen
persistenten Build-Plan und kann den isolierten Generation-2-Builder samt
Cleanup erzeugen. Der Operatorpfad ist über die Image-Aktion des
`Invoke-SqlServerLab`-Menüs erreichbar, löst die ISO aus dem kanonischen Media
Root auf und bindet sie an ein einzelnes SHA-256-Sidecar. Die OS-Installation
bleibt manuell und wird als
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

Ein realer Windows-Server-2025-Standard-Evaluation-Core-Gast wurde aus ISO
installiert, per PowerShell Direct verifiziert und erfolgreich generalisiert.
Die dabei entdeckten Fehler in kulturabhängigen Evidenz-Zeitstempeln,
automatischen Checkpoints und Evaluation-Metadaten sind korrigiert und durch
Regressionstests gebunden. Der konkrete ISO-Build endete wegen des damals noch
fehlerhaften Publikations-Cleanups korrekt als `FAILED`; er ist deshalb kein
positiver End-to-End-Publikationsnachweis.

Eine separat bereitgestellte Windows-Server-2025-Datacenter-Evaluation-VHDX
wurde dagegen SHA-256-verifiziert als reale `OS_SEALED`-Baseline importiert und
über eine isolierte Differencing-VM mit Hyper-V-Heartbeat `OK` gebootet. Dieser
hostlokale Nachweis wird nicht mit dem Repository ausgeliefert und ersetzt
weder einen reproduzierbaren Unattended-ISO-Build noch Gast-Specialization und
SQL-Readiness. Der Ablauf ist unter
[Windows-Server-Baseline aus ISO](../HowTo/HYPERV_WINDOWS_IMAGE_BUILD.md)
dokumentiert.

Mit
`Tests/Integration/Invoke-HyperVWindowsBaselineAcceptanceRun.ps1` existiert
nun ein dedizierter realer Cold-Path-Runner für veröffentlichte
`OS_SEALED`-Baselines. Er deckt OOBE, regionale Einstellungen, PowerShell
Direct, Stop/Start über Reconcile, den Reconnect nach einem Cold Start, die
Abwesenheit einer SQL-Instanz und scopegebundenen Cleanup ab. Ein positiver
hostlokaler Lauf dieses neuen Runners ist noch nicht dokumentiert; bis dahin
bleibt er ein ausführbarer Abnahmevertrag und kein zusätzlicher Runtime-
Nachweis.

`New-SqlServerLab -Manifest` kann genau eine veröffentlichte
`SQL_PREPARED_SEALED`-Vorlage als differenzierenden Hyper-V-Lab-Klon starten und
die vorhandene Unattended-Provisionierung verwenden. Der Aufruf braucht dafür
im Standardmodus externe Guest- und gegebenenfalls SQL-SA-Secrets. Dieser Pfad
hat noch keinen positiven realen SQL-End-to-End-Nachweis für alle Medien.

Zusatz-VHDX werden auf dem Host vor der VM-Mutation validiert, unterhalb des
Run-Verzeichnisses erzeugt, per SCSI angebunden und durch VM-Identität sowie
Cleanup-Plan gebunden. Die Runtime ordnet sie über den VHDX-DiskIdentifier im
Gast eindeutig zu und orchestriert über PowerShell Direct eine idempotente
GPT-/NTFS-Initialisierung samt Allocation Unit, Volume Label und Gastpfad.
Credentials werden nicht persistiert. Der Native-Smoke besitzt jedoch kein
installiertes Windows und beweist deshalb nur DiskIdentifier, Host-Attach und
Cleanup; die tatsächliche Gastformatierung ist statisch mit Mocks abgedeckt.

Die Runtime orchestriert außerdem eine idempotente Windows-Specialization. Sie
validiert den Ziel-Computernamen, persistiert den Rename-/Reboot-Zustand vor der
jeweiligen Gastmutation und wartet mit festem Timeout auf PowerShell Direct und
`IMAGE_STATE_COMPLETE`. Danach kann sie SQL Server im Gast über eine lokale,
verschlüsselte Verbindung auf laufenden Dienst, erwartete Major-Version und die
vier Online-Systemdatenbanken prüfen. Gast- und SA-Credentials werden nicht in
VM-Notizen oder Evidence gespeichert. Der credentialfreie allgemeine Status
zeigt nur die letzte Readiness-Evidenz und setzt `SqlReady` bewusst nicht aus
einem möglicherweise veralteten Receipt auf `true`.

Windows-Specialization, Reboot/Reconnect und SQL-Readiness sind weiterhin nur
statisch mit Mocks abgedeckt. Die reale Datacenter-VHDX wurde ohne bekannte
Gast-Credentials ausschließlich bis zum Hyper-V-Heartbeat gebootet; der
synthetische Native-Smoke beweist diese Gastpfade ebenfalls nicht.
Ein resumierbarer SQL-Image-Builder erstellt inzwischen je Prepared-Image eine
frische Windows-Server-2025-VHDX und bindet SHA-256-geprüfte Windows- sowie
SQL-2019-, SQL-2022- oder SQL-2025-Medien ein. Er führt `PrepareImage` und
genau einen finalen Windows-Sysprep über PowerShell Direct aus, speichert keine
Gast-Credentials und veröffentlicht die VHDX transaktional als
`SQL_PREPARED_SEALED`. Dieser Pfad
ist statisch getestet; ein positiver realer Lauf mit jedem bereitgestellten
SQL-Medium steht noch aus. Die OOBE-Automatisierung kann `Unattend.xml` offline
in die Child-VHDX schreiben, benötigt dafür aber einen erhöht gestarteten
Windows-Runner. Ein nur der Gruppe `Hyper-V-Administratoren` angehörender,
nicht erhöhter Prozess kann VMs verwalten, besitzt jedoch nicht zwingend das
für `Mount-VHD` benötigte Volume-Recht. In diesem Fall bleibt genau der
dokumentierte OOBE-/Passwortschritt manuell; SQL Setup und Abnahme laufen
danach weiter unbeaufsichtigt.

Freie run-lokale Manifest-Drives werden inzwischen deklarativ auf zusätzliche
Hyper-V-VHDX und deren Disk-ID-gebundene Gastinitialisierung abgebildet. Noch
nicht implementiert ist die vollständige Bindung an den Datenbank-, Software-,
Post-Provisioning- und Netzwerkvertrag. Der enge Klonpfad führt für ein
`SQL_PREPARED_SEALED`-Image im Prepared-Image-Klonpfad `CompleteImage` aus. Ein echter
CLI-Vertical-Slice aus einem frischen `OS_SEALED`-Slot ist fuer SQL Server 2025
einschliesslich Installation, Storage, TempDB, Ressourcenwechsel, Datenpersistenz
und Cleanup akzeptiert. Offen bleiben der vollautomatische OS-Factory-Build,
der allgemeine deklarative Hyper-V-SQL-Runtimepfad, runtimeübergreifende Network
Intents, zentraler IPAM, erweitertes Reconcile und der automatische Artifact
Refresh. Der verbindliche Zielvertrag steht in
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

Die Instanzdefinition enthält eine Collation, die bei neuen Umgebungen sowohl als SQL-Server-Instanzcollation als auch als Default für neu angelegte Datenbanken verwendet wird. Ohne explizite Angabe gilt der native SQL-Containerstandard `SQL_Latin1_General_CP1_CI_AS`. Eine abweichende Collation wie `SQL_Latin1_General_CP1_CS_AS` löst beim ersten Containerstart einen Systemdatenbankumbau aus und kann deshalb deutlich länger benötigen.

Die Konsolenanwendung besitzt noch keinen versionsgebundenen Collation-Katalog
mit Filter- oder Suchauswahl. Das aktuelle freie Eingabefeld validiert nur den
technischen Namen. Katalog, tokenbasierte Suche und SQL-seitige Verifikation
sind in `COL-001` des
[Konsolidierungsplans](../Project_Planning/CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md)
vorgesehen.

## Datenbankdateien und Volumes

`New-SqlServerLabDatabase` berücksichtigt `path` für Data- und Log-Files. Der angegebene Containerpfad muss vorher über `drives` beziehungsweise einen Volume-Mount bereitgestellt worden sein.

Die aktuelle Multi-Root-Verwaltung kann registrierte `Lab_Data`-Roots noch
nicht Default-Data, Default-Log, Backup, einzelnen TempDB-Datenfiles oder dem
TempDB-Log zuordnen. Auch eine geforderte physische Trennung wird noch nicht
über Backing Devices nachgewiesen. Vier Laufwerksbuchstaben oder Partitionen
auf derselben Festplatte dürfen daher derzeit nicht als vier physisch getrennte
TempDB-Ziele bewertet werden.

Die aktuelle Storage-Konsole verwendet außerdem noch direkte `Read-Host`-
Auswahl, akzeptiert laufwerksrelative Eingaben wie `D:` und kann beim ersten
Registrieren eines weiteren Roots einen bestehenden Legacy-Default übersehen.
Bis `STO-009` bis `STO-013` und `SFP-001` bis `SFP-003` umgesetzt sind, müssen
Default und resultierende Pfade vor jeder Mutation manuell geprüft werden.

Das Feld `sizeLimitGB` bei Drives ist derzeit Metadatum; Docker- oder Podman-Volumes werden dadurch nicht physisch auf diese Größe begrenzt.

Beliebige `drives[].hostPath`-Mounts aus einem Manifest sind standardmäßig
read-only. Ein schreibender Host-Mount ist kein Standard- oder Persistenzpfad:
Er verlangt `accessMode: readWrite`, `expertActions.hostWriteMounts: true` und
zusätzlich den Aufrufschalter `-AllowExpertHostWriteMounts`. Dieser Schutz
ersetzt keine Host-Sandbox; ein ausdrücklich freigegebener Expertenmount kann
weiterhin in das gewählte Hostverzeichnis schreiben.

Für Evaluation-Refresh existiert ein externer, idempotent initialisierbarer
Data Root mit versionsgetrennten Data-/Log-Bereichen und einer gemeinsamen
Backup-Übergabeebene. Automatisches Backup, `RESTORE VERIFYONLY`, Restore,
TDE-Schlüsseltransfer und persistente Hyper-V-Daten-VHDX sind noch kein
Runtimepfad; bis dahin bleibt der dokumentierte Backup-/Restore-Ablauf
operatorgeführt.

## Restore

Unterstützt werden direkte `.bak`-Dateien aus lokalen Pfaden oder HTTP(S)-URLs.
Ein HTTP(S)-Restore ohne `restore.sha256` kann im interaktiven Trust-Pfad
verwendet werden, beendet einen unbeaufsichtigten Manifestlauf jedoch mit
`TRUST_REQUIRED`.

## Automatisierte Manifeste und Vorlagenpool

`automation.mode: unattended` ist der Manifeststandard. Passwörter dürfen nur
über eng benannte Prozess-Umgebungsvariablen (`SQL_SERVER_LAB_SECRET_*`) oder
als `SecureString`-Parameter übergeben werden. Der Containerpfad ist für
automatisierte Tests und schnelle Setups der vollständige primäre Runtimepfad;
das explizite `interactive` bleibt Kompatibilitätsmodus.

Die lokale Hyper-V-Registry fasst höchstens 20 veröffentlichte `OS_SEALED`-
und `SQL_PREPARED_SEALED`-Vorlagen. Die Grenze ist absichtlich keine
automatische Lösch- oder Auswahlstrategie: Der Operator muss eine nicht mehr
benötigte, nicht referenzierte Vorlage bewusst entfernen. Ein aktiver Lab-Run
oder Image-Build blockiert das Entfernen seines Parents. Der noch offene
Ausbauumfang steht im
[Vorlagen- und Manifestvertrag](../Architecture/TEMPLATE_POOL_AND_AUTOMATED_MANIFESTS.md).

Nicht automatisch unterstützt werden:

- nicht katalogisierte Archive
- Attach-Szenarien mit vorhandenen MDF/LDF-Dateien
- Differential- oder Log-Backup-Ketten
- verschlüsselte Backups mit externen Zertifikaten
- komplexe Mehrfach-Backup-Sets

Bei manuellen Restores ist `-RunId` mit optionaler `-InstanceId` die bevorzugte Identitaet. Provider, Container, Host und Port werden dabei aus der gespeicherten `connection-info.json` aufgeloest. Der direkte Modus mit `-Port` bleibt fuer externe Aufrufer erhalten; ohne `-ContainerName` verwendet er die portbasierte Containererkennung.

## Sample-Datenbanken

`sample`-Referenzen werden auf den Katalog `Catalogs/sample-databases.json` aufgelöst.

Automatisch ausführbar sind Varianten mit `runtimeStatus: executable` und den
Handler-Typen `backup`, `archive-backup` (ZIP oder 7z mit einer exakten,
katalogisierten `.bak`-Payload) oder `sql-script` (einzelnes katalogisiertes
T-SQL-Skript) sowie `script-bundle` (ZIP mit root-gebundenem SQL-Entrypoint).
Bundles erlauben ausschließlich explizit freigegebene `GO`-, `:r`- und
`:setvar`-Features; `:connect`, Shell-Escapes, Include-Traversal und rekursive
Includes werden abgelehnt. Die Installation läuft über
`Private/SampleArtifactHandlers.ps1`, bindet die Sample-Identität an Trust
Store, Cache und Run Lock, setzt `fail-if-exists` durch und verifiziert die
erwarteten Datenbanken abschließend als `ONLINE` (`DATASET_READY`). Archiv-Payloads
werden nur temporär unter dem Run- bzw. Temp-Arbeitsbereich extrahiert und nach
dem Restore entfernt.

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

`Northwind` und `Chinook` sind als fest gepinnte, SHA-256-verifizierte
Einzelskripte katalogisiert: Northwind erhält zuerst eine leere Zieldatenbank,
Chinook legt seine Datenbank selbst an. Große Stack-Overflow-`.7z`-Archive
bleiben bewusst `descriptive`, weil sie MDF/LDF-Dateien für einen noch nicht
implementierten Attach-Handler enthalten – sie werden nicht als `.bak`
umgedeutet.

Noch nicht implementiert sind Attach-Handler, Hyper-V-`LAB_GENERATED`-Backups,
das Überschreiben der erwarteten Zieldatenbanknamen sowie die Wizard-Navigation
mit Zurück/Planvorschau. Single- und Multi-Output-Container-Samples erzeugen
nach erfolgreicher Verifikation geprüfte Backups und
bevorzugen es in Folge-Runs über das portable Register. Script Bundles können
Datenbanken als eine Installation erzeugen; bei einem Teilfehler bleibt der
Run mit `RECOVERY_REQUIRED` sichtbar, eine automatische Löschung wird nicht
vorgetäuscht.

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
Die produktiven Adapter für `SQL_PerformanceSchulung`, `SQL_Server_Analyze` und
`SQL_Server_Toolbelt` sind noch nicht umgesetzt; die Reihenfolge steht in der
[Project-Adapter-Priorisierung](../Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md).

## SQL Server Builds und CUs

Der Versionskatalog enthält ausdrücklich versionierte Buildmetadaten. Diese Daten sind nicht automatisch aktuell. Ein vorhandener Katalogeintrag bedeutet nicht, dass er das neueste verfügbare CU darstellt.

Kurzbezeichner wie `2022-CU16` werden nur akzeptiert, wenn der Build im Katalog vorhanden ist. Unbekannte CU-Bezeichner werden nicht mehr durch eine vermutete Image-Tag-Konvention ersetzt.

## External Languages

Die Installation von R, Python oder Java ist von SQL-Version, Betriebssystem,
Distribution, Provider, Paketquellen und der jeweiligen Supportmatrix abhängig.
Python ist ausdrücklich auch unter Linux und in Containern vorgesehen; es ist
nicht auf Hyper-V beschränkt.

Der providerneutrale Softwarekatalog und Capability Resolver normalisieren
Python-, R- und Java-Anforderungen bereits nach SQL-Version, Betriebssystem,
Architektur und Provider. Unvollständig belegte Varianten, freie Commands,
nicht gesperrte Zusatzpakete und der bisherige `post-start`-Installer werden
vor der Mutation sichtbar abgelehnt. Die katalogisierten SQL-2022-Varianten
bleiben deshalb derzeit `PREVIEW` und nicht `SUPPORTED`.

Für SQL Server 2022/Python, R und Java existieren inzwischen ein per MCR-Digest
gebundener Buildkontext, vollständige DEB-, Wheel-, R-Paket-, JDK-, Java-
Extension- und OCI-Locks, ein
providerneutraler Image-Key, getrennte Docker-/Podman-Buildreceipts, sichere
Providerbindung und echte Python-, R- beziehungsweise Java-Postconditions mit
Daten-In/Daten-Out und Worker-Identitätsprüfung. Die Einzel- und
Kombinationsimages wurden lokal gebaut; die Zielimages wurden auf Runtime- und
Paketversionen sowie compilerfreie R-/Java-Buildgrenzen geprüft. Java 11.0.32,
Language Extension 1.1.1, das reproduzierbar gebaute SDK und das synthetische
Probe-JAR sind hashgebunden. Java-Sprache und -Libraries wurden in einer echten
SQL-2022-Zieldatenbank erstellt, gegen ihre Content-Hashes geprüft, idempotent
wiederverwendet und nach einem absichtlich fehlgeschlagenen neuen Probeversuch
vollständig kompensiert. Dies ist noch kein positiver SQL-JAR-Runtime-Nachweis.

Der sichere `launchpadd`-Namespace-Modus benötigt cgroup v1 und die gezielt
gebundene Container-Capability `SYS_ADMIN`. Der aktuelle Docker-Desktop-Host
stellt cgroup v2 bereit und wird deshalb vor State und Mutation abgelehnt. Der
Modus ohne Namespace-Isolation würde gleichzeitig Outbound-Zugriff der Worker
erfordern und ist bewusst kein stiller Fallback. Getrennte positive Docker-
und Podman-Native-Acceptance auf geeigneten Hosts fehlt weiterhin; Python, R
und Java bleiben daher `PREVIEW`. Der Java-JAR-Aufruf erreicht auf dem aktuellen
cgroup-v2-Host erwartungsgemäß keine bereitgestellte Language Runtime und wird
nicht als positiver Nachweis gewertet.

Für Hyper-V/Windows sind der SHA-256-gebundene Offline-Media-Pfad, der
deterministische Gastplan, die Python-/R-/Java-Installation,
SQL-Feature-Bindung, State/Recovery und der native Acceptance-Runner
implementiert. Java bindet Microsoft OpenJDK 17.0.20.1, den letzten
verfügbaren Windows-Extension-Release 1.1.0, dessen SDK und ein reproduzierbar
erzeugtes Probe-JAR. Ein positiver realer External-Script-Nachweis für alle drei
Sprachen steht noch aus und erfordert eine erhöht gestartete
PowerShell-Sitzung auf dem Hyper-V-Host; die Varianten bleiben deshalb
`PREVIEW`.

`customImage` wird weiterhin nicht als ungeprüfte Manifestquelle in die
Provider-Imageauswahl übernommen. Ein Softwareplan, erfolgreicher Image-Build
oder statischer Resolver-Test ist kein `sp_execute_external_script`-Nachweis.

## Tests

Der Integration-Smoke-Test benötigt eine laufende lokale Runtime und `sqlcmd`.

`-Provider auto` wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Das Resource Assessment prüft zusätzlich alle erkannten Provider.

Die statische Konsistenzprüfung ersetzt keinen echten Docker- oder Podman-End-to-End-Test.

Die reale Hyper-V-Abnahme hatte im Windows-Generalize-Pfad einen nicht gültigen
Aufruf `Invoke-Command -Passthru` gefunden. Der Aufruf ist entfernt und
`Invoke-HyperVProviderChecks.ps1` bindet den gültigen Parametervertrag
inzwischen statisch. Der positive reale Windows-Generalize-/Publish-Nachweis
nach dieser Korrektur bleibt offen; der statische Test ersetzt die erneute
PowerShell-Direct-Abnahme nicht.

Beim bloßen Öffnen und Abbrechen bestimmter Lifecycle-Schnellmenüs kann derzeit
eine automatische Connection-Center-/CMS-Synchronisation ausgelöst werden.
Bis zur Einführung des strukturierten Aktionsergebnisses gilt: Menüabbruch ist
nicht als nachgewiesen seiteneffektfrei zu betrachten.

## Lokale State- und Secret-Daten

State, Secrets, Connection Information, konkrete Hostpfade und Cache-Dateien liegen außerhalb des Git-Checkouts. Sie dürfen nicht in Issues, Pull Requests oder versionierte Diagnoseartefakte kopiert werden.

## Priorisierte nächste technische Schritte

1. Nach der erfolgreichen Docker-/Podman-/Hyper-V-Batchmatrix den
   Batch-/Queue-/Resume-Kern mit Manifest-Rerun, echtem Prozessabbruch und dem
   technisch verifizierten Windows-User-Gate abnehmen.
2. Die verbleibenden P0-Fehler und unerwünschten Seiteneffekte aus der manuellen Abnahme nach
   dem [Konsolidierungsplan](../Project_Planning/CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md)
   schließen und real regressieren.
3. Multi-Root-Storage sowie dateigenaue Data-/Log-/TempDB-Platzierung inklusive
   Nachweis physischer Backing Devices umsetzen.
4. `LAB_GENERATED`-Erzeugung und Auswahl an den Hyper-V-Export binden (Sample-Welle 5/6).
5. Die implementierten providerneutralen Network- und Software-Intents an Hyper-V-LAN/NAT/IPAM und Software-Runtime binden.
6. Artifact Registry, Refresh/Rebuild und Evaluierungsablauf implementieren.
7. Den bereits validierten nativen Hyper-V-Lifecycle in getrennten Wellen bis
   zum realen Windows-/SQL-2025-Cold-Path und zur vollständigen Manifestbindung
   ausbauen.
8. Katalogaktualität, verifizierte Prüfsummen (`catalog-verified`) und Baseline-Kompatibilität kontrolliert pflegen.
