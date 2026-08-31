# Bekannte Grenzen

| Merkmal | Wert |
|---|---|
| Status | `BINDING_LIMITATIONS` |
| Stand | 2026-08-31 |

Dieses Dokument beschreibt bekannte Grenzen des aktuell implementierten Runtimepfads. Es ist Teil des öffentlichen Projektvertrags. Ein Feld im JSON-Schema oder ein Planungsdokument gilt nicht automatisch als Implementierungsnachweis.

## Provider

### Docker und Podman

Docker und Podman sind implementiert. Start, Stop und Live-Status verwenden den
pro Instanz in `connection-info.json` gespeicherten Provider.

Container erhalten neben dem harten Runtime-Limit ein SQL-internes
`MSSQL_MEMORY_LIMIT_MB` mit 20 Prozent Headroom. Das ist insbesondere fuer SQL
Server 2019 auf cgroup-v2-Hosts erforderlich. Automatisierte Linux-Testziele
verwenden fuer Projektvolltests 4 GB Container-RAM und 3 GB
`max server memory`. Der Testumgebungs-Export liest den gebundenen
Containerstatus live und gibt bei einem fehlgeschlagenen Healthcheck keine
Umgebung als `READY` frei.

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

Für die geschützte automatisierte Testgruppe existiert ein eigener öffentlicher,
providerübergreifender Gruppen-Lifecycle. Er kann registrierte Docker-, Podman-
und Hyper-V-Mitglieder idempotent starten, authentifizierte SQL-Readiness samt
Major-Version prüfen und alle Mitglieder danach ohne Löschung wieder stoppen.
Dieser enge Vertrag ist keine allgemeine Provider-Gruppenverwaltung: Er verändert
keine Registrierungen, erstellt keine Slots und repariert keine unvollständige
SQL-Installation. Ein Teilfehler hält den erneuerten Export fail-closed.

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

Automatisierte Windows-Testslots besitzen nun einen eigenen Lizenz-Gate im
Child-VM-Build. Nach OOBE aktiviert die Runtime die Windows-Server-Evaluation
online und verifiziert live `LicenseStatus = 1` sowie eine positive
Evaluation-Restlaufzeit. Die Aktivierung bleibt in der wiederverwendeten
Child-VHDX des Slots erhalten. Nur für einen noch nicht aktivierten Slot wird
ein vorhandener, optional vorgegebener oder automatisch aufgelöster External-
Switch an einer verbundenen physischen NIC als temporäre zweite VM-NIC verwendet
und anschließend scopegebunden entfernt. Edition-Konvertierung
und Product Key sind dafür nicht erforderlich. Dieser Pfad ist statisch und
synthetisch abgesichert; die reale Aktivierung der vorhandenen lokalen Slots ist
ein hostlokaler Betriebsnachweis und kein portables Repository-Artefakt. Eine
abgelaufene Evaluation wird nicht verlängert oder technisch zurückgesetzt.

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

Der Prepared-Image-Klonpfad aus `SQL_PREPARED_SEALED` ist für Windows Server
2025 Standard Evaluation (Desktop Experience) und SQL Server 2025 Enterprise
Developer real belegt: ein normaler Manifestlauf verwendete eine
differenzierende Child-VHDX, führte Windows-Specialization und `CompleteImage`
aus und erreichte `SQL_READY_RUN` mit SQL Major 17 und vier Online-
Systemdatenbanken. Hash und Schreibschutz des Prepared-Parents blieben
unverändert; VM, Child-VHDX und rungebundene Secrets wurden anschließend
scopegebunden entfernt. Diese Referenz-Evidence ersetzt keine positive Matrix
für weitere Windows-/SQL-Versionen oder Editionen.
Ein resumierbarer SQL-Image-Builder erstellt inzwischen je Prepared-Image eine
frische Windows-Server-2025-VHDX und bindet SHA-256-geprüfte Windows- sowie
SQL-2019-, SQL-2022- oder SQL-2025-Medien ein. Er führt `PrepareImage` und
genau einen finalen Windows-Sysprep über PowerShell Direct aus, speichert keine
Gast-Credentials und veröffentlicht die VHDX transaktional als
`SQL_PREPARED_SEALED`. Der positive reale Lauf ist für Windows Server 2025
Standard Evaluation (Desktop Experience) mit SQL Server 2025 Enterprise
Developer belegt: Medien-Sidecars, frische Installation, OOBE, `PrepareImage`,
finaler Sysprep, immutable testlokale Publikation und Cleanup waren grün. Reale
positive Läufe für die übrigen bereitgestellten SQL-Versionen und Editionen
stehen noch aus. Die OOBE-Automatisierung kann `Unattend.xml` offline
in die Child-VHDX schreiben, benötigt dafür aber einen erhöht gestarteten
Windows-Runner. Ein nur der Gruppe `Hyper-V-Administratoren` angehörender,
nicht erhöhter Prozess kann VMs verwalten, besitzt jedoch nicht zwingend das
für `Mount-VHD` benötigte Volume-Recht. In diesem Fall bleibt genau der
dokumentierte OOBE-/Passwortschritt manuell; SQL Setup und Abnahme laufen
danach weiter unbeaufsichtigt.

Freie run-lokale Manifest-Drives werden inzwischen deklarativ auf zusätzliche
Hyper-V-VHDX und deren Disk-ID-gebundene Gastinitialisierung abgebildet. Der
portable Netzwerkvertrag bindet Docker/Podman über Loopback an `nat`/`host`, Hyper-V an
`hostOnly`/`host`, `isolated`/`none` und `nat`/`host`; andere Kombinationen
scheitern vor Mutation. Hyper-V-NAT verwendet einen gemeinsamen WinNAT-Vertrag,
mutationsfreie CIDR-/WinNAT-Prüfung, scopegebundene statische IPAM-Leases sowie
einen Gateway-/DNS-Snapshot. Auf dem Referenzhost blockiert das bereits aktive,
fremde WinNAT `172.30.0.0/24` die positive NAT-Erstellung erwartungsgemäß; dieser
Host liefert deshalb native Kollisions-, aber keine positive Erstellungs-Evidence.
Noch nicht implementiert ist die vollständige Bindung an den Datenbank-, Software-
und Post-Provisioning-Vertrag sowie Hyper-V-LAN und Netzwerk-Reconcile. Der Prepared-Image-Klonpfad führt für
ein `SQL_PREPARED_SEALED`-Image `CompleteImage` aus und ist für den Windows-
2025-/SQL-2025-Referenzfall bis `SQL_READY_RUN` real akzeptiert. Ein weiterer
echter CLI-Vertical-Slice aus einem frischen `OS_SEALED`-Slot ist für SQL
Server 2025 einschließlich Installation, Storage, TempDB, Ressourcenwechsel,
Datenpersistenz und Cleanup akzeptiert. Offen bleiben der vollautomatische
OS-Factory-Build,
der allgemeine deklarative Hyper-V-SQL-Runtimepfad, LAN-/External-Bindings,
erweitertes Reconcile und der automatische Artifact
Refresh. Der verbindliche Zielvertrag steht in
[Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).

## Manifest und Schema

### Schema ist kein Runtime-Nachweis

`Schemas/lab-manifest.schema.json` enthält neben ausführbaren Feldern auch teilweise vorbereitete Erweiterungsfelder. Direkte `serverConfig`-Eigenschaften sind mit `x-runtimeStatus` als `executable`, `reserved` oder `partially-executable` klassifiziert. Gesetzte reservierte Felder werden vor Auflösung und Mutation mit `MANIFEST_RESERVED_RUNTIME_FIELD` abgelehnt, statt nur gewarnt oder still verworfen zu werden. Wertabhängige Grenzen sind über `x-runtimeValueStatus` maschinenlesbar und enden mit `MANIFEST_RESERVED_RUNTIME_VALUE`. Für die tatsächliche Ausführung sind zusätzlich `Private/ManifestParser.ps1` und die zuständige Runtimefunktion maßgeblich.

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
- `externalScripts.installMethod = custom-image`
- `externalScripts.installMethod = pre-built`

Ausführbare Beispiele verwenden diese Felder daher nicht. Ein Manifest mit
einem dieser Felder oder Werte ist fachlich ungültig und kann weder vom Wizard
gespeichert noch über den Manifestpfad provisioniert werden.

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

Die Multi-Root-Verwaltung erfasst seit 2026-08-29 stabile `LocationId`,
Volume- und Backing-Device-Topologie, übernimmt Legacy-Defaults mit Receipt und
schützt Default- sowie referenzierte Locations. Laufwerksrelative Eingaben wie
`D:` werden blockiert; das normalisierte Ziel wird vor der Bestätigung gezeigt.

Registrierte `Lab_Data`-Roots können über portable Selektoren jetzt read-only an
Default-Data, Default-Log, Backup, einzelne TempDB-Datenfiles, TempDB-Log,
Datenbankdateien und Restore-Regeln gebunden werden. Der Bound Plan prüft
Volume- und Backing-Device-Anforderungen fail-closed. Der Hyper-V-Manifestpfad
erzeugt pro Selector eine controller-eigene dynamische VHDX, initialisiert die
Gastdisks stabil und wendet Instanz-Defaultpfade sowie den vollständigen TempDB-
Plan an. Ein getrenntes Runtime-Receipt verbindet Hostpfad, VHDX-ID, Gastdisk
und SQL-Pfad; `VERIFIED` erfordert Dienstrestart und vollständige SQL-
Postconditions. Diese Implementierung ist statisch, synthetisch und seit
2026-08-30 durch den realen Mehrgeräte-Referenzlauf abgenommen.
Mit `Tests/Integration/Invoke-HyperVStorageAcceptance.ps1` existiert dafür ein
fail-closed ausführbarer Runner: Er verlangt vor der Mutation vier TempDB-
Datendateien auf mindestens zwei beziehungsweise der im Intent festgelegten
höheren Zahl belegter Backing Devices und eine eigene TempDB-Log-Lane. Das
Referenz-Intent fordert drei physische Geräte und verteilt die vier Dateien
round-robin als 2/1/1. Der positive reale Lauf vom 2026-08-30 bestätigte
SQL-Dienstrestart, dateigenaues CREATE, synthetischen Backup/Restore-Roundtrip,
Persistenz nach vollständigem VM-Restart und rungebundenen VHDX-Cleanup.
`SQLS-002` und `SQLS-003` sind für den Hyper-V-Manifestpfad real belegt:
CREATE verwendet ausschließlich dateigenaue
Plan-/Receipt-Bindings, Restore erzeugt aus `FILELISTONLY` für jede Data-, Log-
und unterstützte Spezialdatei genau ein typgerechtes `MOVE`-Ziel, und beide
Operationen quittieren erst nach exaktem `sys.master_files`-Abgleich. Fehler
hinterlassen ein sanitisiertes `RECOVERY_REQUIRED`-Receipt. Katalogisierte
Sample-Restores im neuen Hyper-V-Storagepfad sind weiterhin unsupported;
physische Containertrennung bleibt ebenfalls unsupported. Der physische
N5-Storage-Nachweis ist damit abgeschlossen. Ein erneuter realer Lauf am
2026-08-31 bestätigte den Vertrag nach der Ressourcenroot-Umstellung mit drei
von drei geforderten Geräten, gebundenem Builder-/Image-Pfad und vollständigem
Cleanup des isolierten Prepared-Images, Test-State und aller rungebundenen
VHDX. Die reale Legacy-SQL-Migration ist seit 2026-08-31 ebenfalls mit
isoliertem SQL-2022-Klon, committed Binding, zwei Gast-/SQL-Restarts,
Wiederherstellung des laufenden Zustands und vollständigem Cleanup belegt. Die
allgemeine Parent-Storage-Migration ist mit
isolierter Test-VM, VHDX-Rebind, Rückmigration und Cleanup real belegt.
Die virtuelle Lane-Kapazität wird im Bound Plan deterministisch abgeleitet:
mindestens 32 GB für offen wachsende Data-/Log-/Backup-Rollen, mindestens 4 GB
für reine TempDB-Lanes und jeweils mindestens die expliziten Dateigrößen plus
1 GB Reserve. Die VHDX bleibt dynamisch und belegt diese Größe nicht sofort.

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

Noch nicht implementiert sind Attach-Handler und das Überschreiben der
erwarteten Zieldatenbanknamen. Run-gebundene Hyper-V-`LAB_GENERATED`-Backups verwenden
eine verifizierte Storage-Receipt-Backup-Lane, PowerShell Direct für den Export
und denselben run-gebundenen Restorepfad; dieser Vertrag ist synthetisch, aber
noch nicht real auf einem Host belegt. Die automatische Hyper-V-
Manifestausführung für Samples ist an vollständige Default-Data-, Default-Log-
und Backup-Lanes gebunden und blockiert widersprüchliche datenbankspezifische
Platzierung vor der Provider-Mutation; auch dieser Pfad besitzt noch keine reale
Host-Evidence. Der Manifest-Wizard
unterstützt Hilfe, schrittweise Zurücknavigation, Zwischenzusammenfassung und
Abbruch ohne partielle Datei. Seine mutationsfreie Planvorschau umfasst
External Runtimes sowie Sample-/Artifact-Quelle, Lizenz, Outputs, Größen,
Integrität, Trust, Handler und Idempotenz. Single- und
Multi-Output-Container-Samples erzeugen
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
Alle drei produktiven Pilotadapter sind in den autoritativen
Partnerrepositories umgesetzt. `CON-004`, der Analyze-Slice
`EXECUTION-PLAN-001` und das Toolbelt-Modul
`toolbelt.core.console-message` 1.0.0 sind jeweils auf SQL Server 2025 Linux
mit Docker und Podman end-to-end validiert. Jeder Lauf umfasste seinen
fachlichen Cleanup und den scopegebundenen Infrastruktur-Cleanup. Gate N3 ist
damit geschlossen; die breiteren partnerseitigen Mehrversionsmatrizen und eine
gesonderte Stabilisierung des weiterhin als `0.1-draft` geführten
Adaptervertrags bleiben außerhalb dieses Pilotnachweises. Die Evidence steht in
der
[Project-Adapter-Priorisierung](../Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md).

## SQL Server Builds und CUs

Der Versionskatalog enthält für SQL Server 2019, 2022 und 2025 die vollständige
bei Microsoft weiterhin verfügbare CU-Historie mit expliziten MCR-Tags sowie
hashgebundenen Windows-Paketen. Diese Daten sind nicht automatisch aktuell und
müssen bei neuen Microsoft-Veröffentlichungen weiter gepflegt werden. SQL
Server 2019 CU7 bleibt wegen des von Microsoft dokumentierten Rückzugs bewusst
nicht auswählbar.

`Save-SqlServerLabCuResource` und der Konsolenpunkt unter Storage und Medien
stellen jeden dieser CUs ohne KI-Unterstützung bereit. Windows akzeptiert nur
die katalogisierte Microsoft-HTTPS-Quelle und veröffentlicht ein Paket erst
nach SHA-256- sowie Microsoft-Authenticode-Prüfung im Media Root. Linux zieht
den exakten MCR-Tag in den gewählten Docker-/Podman-Cache. Der Cache ist kein
portables Offlineartefakt und wird nicht in `Lab_Base` gespiegelt.

Kurzbezeichner wie `2022-CU16` werden nur akzeptiert, wenn der Build im Katalog vorhanden ist. Unbekannte CU-Bezeichner werden nicht mehr durch eine vermutete Image-Tag-Konvention ersetzt.

## External Languages

Die Installation von R, Python, Java oder C# ist von SQL-Version, Betriebssystem,
Distribution, Provider, Paketquellen und der jeweiligen Supportmatrix abhängig.
Python ist ausdrücklich auch unter Linux und in Containern vorgesehen; es ist
nicht auf Hyper-V beschränkt.

Der providerneutrale Softwarekatalog und Capability Resolver normalisieren
Python-, R-, Java- und C#-Anforderungen nach SQL-Version, Betriebssystem,
Architektur und Provider. Unvollständig belegte Varianten, freie Commands,
nicht gesperrte Zusatzpakete und der bisherige `post-start`-Installer werden
vor der Mutation sichtbar abgelehnt. SQL Server 2019 besitzt im Linux-
Containerpfad derzeit nur die Java-Variante; dessen älterer Python-/R-
Machine-Learning-Paketstack wird nicht mit dem Custom-Runtime-Vertrag von SQL
Server 2022/2025 vermischt. SQL Server 2022 und 2025 katalogisieren Python, R
und Java für Docker und Podman. Native SQL-Roundtrip-Nachweise liegen für Java
auf SQL Server 2019 und für Python, R und Java auf SQL Server 2022 und 2025 vor,
jeweils getrennt für Docker und Podman.

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
vollständig kompensiert.

Die Wave-8B-Native-Charakterisierung fand außerdem, dass ein zuvor nicht separat
abgenommener Python-only-Stage die von `revoscalepy` benötigte OpenMP-Laufzeit
`libgomp.so.1` nur indirekt über kombinierte R-Images erhielt. Rezeptversion 5
bindet deshalb `libgomp1` als eigenes Ubuntu-22.04-Paket per Version und SHA-256
und extrahiert dieselben Runtimebytes compilerfrei in Python- und R-Zielstages.

Der sichere `launchpadd`-Namespace-Modus benötigt rootful Linux, cgroup v1,
einen schreibbaren cgroup-Bind sowie die im Rezept exakt gebundenen Linux-
Capabilities und Security-Optionen. Ungeeignete Hosts werden vor State und
Mutation abgelehnt; es gibt keinen stillen Fallback ohne Namespace-Isolation.
Docker und Podman bestanden auf isolierten cgroup-v1-Gästen vollständige Native
Acceptances für SQL Server 2019/Java sowie SQL Server 2022 und 2025 mit Python,
R und Java. Die Sprachen lieferten echte SQL-Datenroundtrips und Worker-
Identität vor und nach providergebundenem Neustart; Run-Ressourcen, Derived
Images und die test-eigenen Podman-Netze wurden vollständig bereinigt. Podman
3.4.4 benötigt dabei die eng begrenzte
CNI-0.4.0-Kompatibilitätskorrektur und einen Retry für seine sofortige
Portfreigabe-Race. Rootless Podman bleibt für allgemeine Labs unterstützt,
nicht jedoch für den External-Runtime-Namespace-Modus.

C# Language Extensions sind von Microsoft ab SQL Server 2019 CU3 ausschließlich
unter Windows beschrieben; die in SQL registrierte Sprache heißt `dotnet`.
Der einzige veröffentlichte Microsoft-Binärrelease zielt auf die nicht mehr
unterstützte .NET-5-Runtime. Der aktuelle Microsoft-Quellstand zielt auf .NET 8,
liefert aber keinen entsprechenden reproduzierbaren Binärrelease. `sql-csharp`
ist deshalb für SQL 2019/2022/2025 auf Hyper-V/Windows katalogisiert, bleibt
aber bis zu hashgebundenem Build und nativer SQL-Evidence `PREVIEW` und
fail-closed.

Für Hyper-V/Windows sind der SHA-256-gebundene Offline-Media-Pfad, der
deterministische Gastplan, die Python-/R-/Java-Installation,
SQL-Feature-Bindung, State/Recovery und der native Acceptance-Runner
implementiert. Java bindet Microsoft OpenJDK 17.0.20.1, den letzten
verfügbaren Windows-Extension-Release 1.1.0, dessen SDK und ein reproduzierbar
erzeugtes Probe-JAR. Ein positiver realer External-Script-Nachweis für alle drei
Sprachen wurde auf SQL Server 2022 unter Windows Server 2025 erbracht: Python,
R und Java bestanden Datenroundtrip, Versions- und Worker-Identitätsprüfung vor
und nach einem vollständigen VM-Kaltstart. Der isolierte Acceptance-Klon und
beide VHDX-Kopien wurden danach über den registrierten Cleanup-Plan entfernt.
Diese drei Hyper-V-Varianten sind deshalb `SUPPORTED`. Andere Windows-/SQL-
Versionen erben diesen Status nicht.

`customImage` wird weiterhin nicht als ungeprüfte Manifestquelle in die
Provider-Imageauswahl übernommen. Ein Softwareplan, erfolgreicher Image-Build
oder statischer Resolver-Test ist kein `sp_execute_external_script`-Nachweis.

Der Manifest-Wizard bietet External Runtimes nur aus der resolverfreigegebenen
Kombination von SQL-Version, Provider und Betriebssystem an. Die read-only
Manifestprüfung liefert denselben portabel identifizierten Softwareplan mit
Downloads, Derived-Image-Build oder Gastmutation, Restart-/Downtime-Bedarf,
Package Locks und Verification. Aenderungen werden als Artifact-`rebuild`,
Service-`restart`, Container-`recreate` oder Gast-`reprovision` klassifiziert;
die `PlanKey` wird in Installation Receipt, Derived-Image-Plan, Buildreceipt,
Run-State und Cleanup-/Recovery-Bindung übernommen. Run-lokale Ressourcen
werden damit scopegebunden entfernt, während wiederverwendbare Softwareartefakte
ausdrücklich erhalten bleiben.

Ein ausführbarer Installations- und Refresh-Slice ist für laufende SQL-2022-
Docker-/Podman-Runs implementiert. Er kann die erste External Runtime
nachinstallieren sowie vorhandene, erneut vom Resolver freigegebene Runtime-
Anforderungen ergänzen oder bis auf die letzte Runtime entfernen. Provider,
SQL-Version, Profil, Storage, Netzwerk, Datenbanken und andere Instanzen müssen
unverändert bleiben. Das neue Derived Image wird vor der Container-Mutation
gebaut; Journal, Scope-Prüfung, SQL-Readiness und echte Sprachpostconditions
binden Umschaltung und Rollback. Der alte Container wird erst nach atomarem
Connection-/Desired-State-Commit entfernt, das alte Image bleibt erhalten.
Der vollständige Umschaltpfad bestand am 2026-08-28 getrennte native Docker-
und Podman-Abnahmen auf einem isolierten Ubuntu-22.04-/cgroup-v1-Gast: ausgehend
von Python-only wurden R und Java additiv ergänzt, Java anschließend wieder
entfernt und Python/R nach einem Provider-Restart erneut ausgeführt. Die
Journale erreichten `COMPLETED`; der eigentumsgebundene Java-DDL-Cleanup
entfernte nur die vom Lab erzeugte Sprache, SDK-Library und Probe-Library.
Ein SQL-Datenmarker blieb über beide Containerwechsel und den Restart erhalten.

Container speichern `/var/opt/mssql` sowie die beiden langlebigen
External-Runtime-Artefaktpfade `externallanguages` und `externallibraries` in
drei getrennten, scopegebundenen Volumes. LaunchPad-Arbeitsdaten und Sandboxes
bleiben containerlokal. Bei einer Nachinstallation werden die beiden neuen
Volumes vor dem Container-Cleanup eingeordnet und in Rollback/Recovery
einbezogen. Der Startadapter synchronisiert die katalogisierte
ML-EULA und die Runtime-Artefakte providerneutral, sodass Docker und Podman
denselben Persistenzvertrag erfüllen. Für die transienten SQL-Fehler `39011`
und `39012` ist genau ein Container-Restart mit anschließendem Probe-Retry
zulässig; Java-Registrierungseigentum wird dabei versuchsübergreifend erhalten,
damit Compensation und spätere Removal-Aktionen vollständig bleiben.

Noch nicht unterstützt sind die Entfernung der letzten External Runtime, freie
Packagewechsel, der allgemeine Hyper-V-Softwarepfad sowie Hyper-V-Artifact-
Refresh und automatische Gastumschaltung. Das Hyper-V-Verwaltungsmenü weist
darauf mit einem begründet deaktivierten Eintrag hin.

## Tests

### Container-Reconcile

Der öffentliche Containerplan und seine Action unterstützen derzeit CPU, RAM
und SQL `max server memory (MB)` live sowie Hostport- und SQL-Runtime-
Vertragsreparatur per kontrolliertem Recreate. Das lokale Journal bindet echte
Runtime-IDs und kann einen unvollständigen Folgelauf abschließen, zurückrollen
oder sichtbar als `RECOVERY_REQUIRED` markieren. Docker und Podman sind am
2026-08-29 real mit No-op, Live, Recreate, Rollback, Datenpersistenz und Cleanup
geprüft worden.

Freie Änderungen beliebiger Mounts, Environment-Variablen oder Images sind
nicht Teil dieses öffentlichen Reconcile-Vertrags. Der Recreate-Pfad übernimmt
die bereits freigegebenen Mounts, Labels, das Netzwerk und die Restart-Policy;
er ist kein allgemeiner Containereditor. Ein Journal ersetzt außerdem keine
physische Hyper-V-Storage-Evidence.

Der Integration-Smoke-Test benötigt eine laufende lokale Runtime und `sqlcmd`.

`-Provider auto` wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Das Resource Assessment prüft zusätzlich alle erkannten Provider.

Die statische Konsistenzprüfung ersetzt keinen echten Docker- oder Podman-End-to-End-Test.

Die reale Hyper-V-Abnahme hatte im Windows-Generalize-Pfad einen nicht gültigen
Aufruf `Invoke-Command -Passthru` und anschließend ein zu kurzes UEFI-DVD-
Bootfenster gefunden. Beide Fehler sind korrigiert. Der positive Pfad wurde mit
einer frischen unbeaufsichtigten Windows-Server-2025-Evaluation auf einer neuen
Builder-VHDX real wiederholt: Installations-Receipt, Sysprep-Exitcode 0,
`IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, hashgebundene PowerShell-Direct-
Evidence, testlokale immutable `OS_SEALED`-Publikation und Cleanup waren grün.
Eine bereits generalisierte Baseline ist wegen des begrenzten Windows-Lizenz-
Rearm-Vertrags keine zulässige positive Generalize-Testquelle.

Der reale SQL-Prepared-Image-Runner installiert Windows Server 2025 und SQL
Server 2025 Enterprise Developer aus hashverifizierten Medien auf einer neuen
VHDX. `PrepareImage`, der finale Sysprep-Receipt und die immutable testlokale
`SQL_PREPARED_SEALED`-Publikation sind positiv ausgeführt. Anschließend klont
derselbe Runner dieses Parent-Artifact über ein normales Manifest,
spezialisiert Windows, führt `CompleteImage` aus und bestätigt
`SQL_READY_RUN`, SQL Major 17, vier Online-Systemdatenbanken, unveränderten
Parent-Hash sowie vollständigen Builder- und Manifest-Cleanup.

Lifecycle-Schnellmenüs verwenden inzwischen `ActionResult/1.0`: `Cancelled`,
`NoChange`, `Skipped`, Ablehnung und Fehler lösen weder Connection-Center- noch
CMS-Synchronisation aus; eine erfolgreiche endpunktrelevante Mutation genau
eine. Der Aufrufzähler ist lokal synthetisch gebunden. Der gemeinsame
Dialogabbruch der grafischen Workflow-UI ist im lokalen Browser real mit
`Escape`, Löschbestätigung und Passwortverwerfung geprüft. Die PowerShell-
Konsole ist im realen PowerShell-7-PTY für Cursor- und erzwungenen Fallback-
Modus geprüft: `Ctrl+C` beendet die aktuelle Verarbeitung, der Fallback ist über
`-ConsoleMode Fallback` reproduzierbar und `0` beendet ihn kontrolliert.
Die konkrete Restmigration ist ebenfalls abgeschlossen: Storage,
Connection Center/CMS, Erstellungs- und Hyper-V-Auswahllisten verwenden die
gemeinsame Cursor-/Fallback-Schicht; ein statisches AST-Inventar lässt keine
direkten `Read-Host`-Auswahlprompts mehr zu. Freie Text-, Pfad- und
Passworteingaben bleiben über den gemeinsamen Escape-fähigen Adapter angebunden.
Der harte Scheduler-Prozessabbruch ist dagegen mit zwei realen Docker-
Ressourcen, persistenter `WorkerRecovered`-Evidence, eindeutigem Operation-zu-
Run-Eigentum, idempotentem Resume und scopegebundenem Cleanup belegt.
Das Hyper-V-Windows-User-Gate ist ebenfalls real belegt: Ein read-only Probe
setzt nur `CandidateSatisfied`, Bestätigung ohne verifiziertes Credential bleibt
fail-closed, PowerShell Direct bestätigt das echte Gast-Credential und genau ein
Receipt setzt den Scheduler fort. Der Acceptance-Test entfernt VM, Child-VHDX
und temporären State scopegebunden.

## Hyper-V-Ressourcenpfade

Vor `HVR-003` konnten reguläre Slot-VHDX, Image-Builder-Ressourcen,
VM-Konfiguration und Smart Paging unter dem Legacy-State-Root
`%LOCALAPPDATA%\SqlServerLab` entstehen, obwohl ein verwalteter
`Lab_Data`-Root konfiguriert war. Neue Ressourcen werden nun durch persistierte
`HyperVResourceBinding`-Verträge unter registriertem `Lab_Data` erzeugt und vor
sowie nach der Mutation geprüft. Für vorhandene Run-Ressourcen besteht ein
journalisierter Migrationskern mit Preview, Hash-/VHDX-Verifikation, Resume,
VM-Umbindung und spätem Quell-Cleanup. Legacy-Images können zusätzlich
hashidentisch im gebundenen Image-Store veröffentlicht werden; referenzierte
Quellen bleiben dabei sichtbar als `WAITING_FOR_CONSUMERS`. Run-lokale
Legacy-Children werden nur gegen den unveränderten Image-Plan, das committed
Binding und ein hashverifiziertes read-only Ziel-Parent umgehängt. Der
vorjournalisierte `Set-VHD`-Schritt ist fortsetzbar; getrennte Quell-/Ziel-
Child-Hashes schützen den späten Cleanup. Nach dem Child-Cleanup wird die
Image-Migration automatisch fortgesetzt. Die physische Zielbindung ist über
`Get-SqlServerLabHyperVResourcePreview` und das Console-User-Gate öffentlich
sichtbar; sie wird über UAC explizit übergeben und im erhöhten Prozess erneut
geprüft. Der Legacy-Migrations-Apply besitzt weiterhin keinen öffentlichen
Startpfad. Ein real erhöhter Windows-Parent-/Child-Fall belegt Copy, Reparent,
VM-Storage-Rebind, zwei Gaststarts, Recovery-Resume und Quell-Cleanup. Der
interne Acceptance-Runner kann einen ursprünglich laufenden Legacy-SQL-Run vor
dem Hashplan geordnet stoppen, fehlende aktuelle SQL-Identität nur aus
persistierter Windows-Evidence plus Live-SQL-Probe übernehmen, für beide
Restart-Zyklen SQL-Readiness verlangen und den laufenden Zustand abschließend
erneut validieren. Dieser SQL-gebundene Realfall ist seit 2026-08-31 real grün;
der Bootstrap stellte die geschützte Testgruppe abschließend 6/6 `READY` her
und hinterließ weder Kandidaten-VM noch Legacy-State. Legacy-Dateien dürfen
weiterhin nicht manuell verschoben werden, weil nur der journalisierte Pfad
die Identitäts-, Integritäts-, Restart- und Cleanup-Postconditions garantiert.

Persistierte Builder-States referenzieren ihre System-VHDX portabel über
`resourceRelativePath`; Resume, Generalize, Publish sowie die realen Windows-
und SQL-Acceptance-Pfade lösen den physischen Pfad erneut über das gebundene
`Build`-Receipt auf. Der reale N4-/N5-Referenzlauf hat diese Trennung zwischen
kleinem State und physischer Builder-/Image-Ressource bestätigt.

Der priorisierte
[P0-Bugfix](../Project_Planning/HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md)
trennt Create-, Discovery-, State- und Ressourcenroots, blockiert neue
Fehlplatzierungen vor der Provider-Mutation und fordert eine journalisierte
Migration vorhandener Legacy-Slots. Der physische N5-Hyper-V-Mehrgeräte-
Nachweis wurde am 2026-08-30 abgeschlossen und am 2026-08-31 nach der
Ressourcenroot-Umstellung einschließlich Artifact-Cleanup erneut bestätigt.
Der P0-Ressourcenroot-Bugfix ist nach der realen Legacy-SQL-Abnahme vom
2026-08-31 abgeschlossen.

`HVR-001` bis `HVR-008` sind implementiert und statisch, synthetisch sowie in
den geforderten realen Hyper-V-Szenarien validiert: Der
versionierte lokale Vertrag löst kurze Create-Roots ausschließlich aus
registrierten `Lab_Data`-Locations auf, revalidiert Controller-, Location-,
Volume-, Path-Length- und Reparse-Evidence und schützt Provider, Builder sowie
Image- und Staging-Store an ihren Mutationsgrenzen. Der Migrationskern
inventarisiert und verifiziert Legacy-Runs, bindet run-lokale Hyper-V-
Ressourcen journalisiert um und erhält externe SQL-Lanes. Die Parent-/Child-
Kette wird dabei graphbasiert auf den gebundenen Image-Store umgehängt und
referenzfrei bereinigt. Die öffentliche CLI-Preview und das Console-User-Gate
zeigen Location, `Lab_Data`, Kapazität und Klassenroots vor der Bestätigung;
der UAC-Handoff revalidiert denselben Vertrag. Die reale erhöhte Windows-
Legacy-Run-/Parent-/Child-Migration, der erneute N5-Mehrgeräte-Nachweis, die
allgemeine Parent-Storage-Migration sowie die laufende Legacy-SQL-Migration
mit zwei SQL-Restarts sind belegt. Der Apply bleibt als bewusste
Sicherheitsgrenze intern und wird über den expliziten Acceptance-Runner
ausgeführt.
Der erste `HVR-006`-Slice schützt den Hyper-V-Cleanup bereits atomar gegen
nichtterminale Run-Migrationen und unsafe VHDX-Pfade. Der Cleanup-Audit weist
Run-Bindings, Migrationsstatus, ungetrackte Preserve-Dateien und Shared-Roots
read-only aus; eine automatische Reparatur oder Löschung solcher Befunde ist
bewusst noch nicht implementiert.
Der zweite `HVR-006`-Slice koppelt Lifecycle-Reconcile, Start, Stop,
Autostartänderung und SQL-WMI-Repair an einen gemeinsamen read-only
Migrationsguard. Laufende, fehlgeschlagene oder inkonsistent abgeschlossene
Migrationen planen und führen keine konkurrierende Mutation aus. Ein
abgeschlossenes Journal wird nur zusammen mit seinem committed, erneut gegen
die persistierte Location geprüften Run-Binding freigegeben.
Der dritte `HVR-006`-Slice koppelt die allgemeine, journalisierte Parent-
Migration einer `Lab_Data`-Location an dasselbe Binding-Modell. Plan und Apply
inventarisieren und revalidieren mitkopierte sowie externe lokale Hyper-V-
Receipts, erhalten `LocationId` und `ResourceKey` und stellen die Bindings nach
dem Katalogwechsel atomar am Zielroot neu aus. Manipulierte Inventare sowie
nichtterminale Run-, Image- oder Location-Journale blockieren Storage-Mutation,
Hyper-V-Lifecycle und Cleanup fail-closed. Ein Abbruch nach neu ausgestelltem
Binding bleibt aus demselben Journal fortsetzbar. Registrierte VM-
Konfiguration, Snapshot- oder Smart-Paging-Pfade unter dem Quellroot werden
mit exakter VM-Identität sowie Quell- und Zielpfaden geplant und unmittelbar
vor der Mutation erneut gegen eine ausgeschaltete VM geprüft. Die
`Move-VMStorage`-Umbindung wird als `PENDING` journalisiert, durch exakte
Ziel-Postconditions abgeschlossen und bei einem Resume nicht doppelt
ausgeführt. Damit ist `HVR-006` intern geschlossen, synthetisch validiert und
mit einer isolierten Nicht-Default-Location, realer VM-Konfiguration, VHDX,
Vorwärts-/Rückmigration und Cleanup real belegt.
Image-Quellen werden bis zum nachgewiesenen Wegfall aller Consumer absichtlich
nicht entfernt; manuelles Verschieben außerhalb des journalisierten Vertrags
bleibt unzulässig.

## Lokale State- und Secret-Daten

State, Secrets, Connection Information, konkrete Hostpfade und Cache-Dateien liegen außerhalb des Git-Checkouts. Sie dürfen nicht in Issues, Pull Requests oder versionierte Diagnoseartefakte kopiert werden.

## Priorisierte nächste technische Schritte

1. Den P0-Bugfix für Hyper-V-Ressourcenroots nach der belegten real erhöhten
   Windows-Legacy-Run-/Parent-/Child-Migration, dem erneuten N5-Nachweis und
   der allgemeinen Parent-Storage-Migration mit SQL-Readiness der Legacy-
   Migration abschließen.
2. Den synthetisch implementierten Hyper-V-`LAB_GENERATED`-Export und die
   automatische Sample-Manifestausführung real abnehmen (Sample-Welle 6).
3. Die verbleibenden providerneutralen Network- und Software-Intents an
   Hyper-V-LAN/NAT/IPAM/DNS und Software-Runtime binden; Container-`nat` sowie
   Hyper-V-`hostOnly`/`isolated` sind bereits gebunden.
4. Artifact Registry, Refresh/Rebuild und Evaluierungsablauf implementieren.
5. Den belegten Windows-2025-/SQL-2025-Referenzpfad zur vollständigen
   allgemeinen Hyper-V-Manifestbindung und zu weiteren realen
   Versions-/Editionsnachweisen ausbauen.
6. Katalogaktualität, verifizierte Prüfsummen (`catalog-verified`) und
   Baseline-Kompatibilität kontrolliert pflegen.
