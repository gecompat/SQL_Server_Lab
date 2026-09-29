# SSIS ETL-, Data-Warehouse- und Recovery-Lab – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-08-30 |
| Primärzweck | reproduzierbare SQL-Server-Integration-Services-Szenarien |

## Ziel

Das Lab soll eine vollständig automatisierte SSIS-Testumgebung bereitstellen,
in der Packages entwickelt beziehungsweise als freigegebene Artefakte
eingespielt, nach SSISDB deployed, parametrisiert, ausgeführt, beobachtet,
gestört, wiederaufgenommen und entfernt werden können.

Der erste Referenzpfad verwendet SQL Server und Integration Services unter
Windows in einer Hyper-V-VM. SQL-Quellen, Staging- und Zielinstanzen dürfen je
nach Szenario zusätzlich unter Docker oder Podman laufen. SSIS bleibt die
primäre SQL-Komponente; Datei-, Object-Storage-, Client- und Monitoring-Dienste
sind ausschließlich Supporting Components.

## Anwendungsszenarien

### ETL-Grundlagen

- CSV-, JSON-, XML-, ODBC- und SQL-Quellen mit katalogisierten Beispieldaten;
- typisierte Konvertierung, Lookup, Merge, Aggregate und Conditional Split;
- getrennte Fehlerausgänge und nachvollziehbare Reject-Daten;
- Bulk- und Fast-Load-Verhalten;
- Data-Profiling und maschinenprüfbare Zeilen-, Hash- und Summen-Assertions.

### Data-Warehouse-Aufbau

- Staging-, Dimensions- und Faktentabellen;
- Surrogate Keys und referenzielle Integrität;
- Star Schema und kontrollierte Columnstore-Varianten;
- Slowly Changing Dimensions für feste, überschreibende und historische
  Attribute;
- initialer Full Load und wiederholbarer Delta Load.

### Inkrementelle Verarbeitung

- High-Water-Mark- und Change-Tracking-Lanes;
- SQL-CDC und SSIS-CDC-Komponenten als editionsgebundene Windows-Lane;
- Insert-, Update- und Delete-Verarbeitung;
- verspätete beziehungsweise doppelte Eingangsdaten;
- idempotenter Wiederanlauf ohne doppelte Fakt- oder Dimensionszeilen.

### Deployment und Betrieb

- Project- und Package-Deployment-Modell als getrennte Capabilities;
- SSISDB mit Foldern, Projekten, Packages, Parametern und Environments;
- lokale Secret-Referenzen statt persistierter Klartextwerte;
- Ausführung über SSISDB und katalogisierte SQL-Agent-Jobs;
- Logging, Execution Reports, Retention und sanitisierte Betriebs-Evidence;
- Package- und Project-Versionierung sowie kontrollierter Rollback.

### Migration und Kompatibilität

- Package-Ausführung gegen SQL Server 2019, 2022 und 2025;
- Side-by-side-Installation beziehungsweise getrennte Runtime-Images;
- Upgrade von Project- und Package-Format mit vorheriger Kopie;
- Treiber-, Provider-, Connection-Manager- und Compatibility-Prüfung;
- identische fachliche Assertions vor und nach Upgrade;
- Abweichungen zwischen Standard- und Enterprise-Capabilities.

### Fehler, Resume und Recovery

- Abbruch von Quelle, Ziel, SQL Agent oder SSIS Runtime;
- Netzwerkunterbrechung, Timeout und Credential-Rotation;
- fehlerhafte, unvollständige und schemaabweichende Eingabedaten;
- begrenztes Disk-Full-Ziel für Staging, Log oder SSISDB;
- Checkpoints, Transaktionsgrenzen und Compensation;
- Wiederholung nach Prozess-, VM- und SQL-Restart;
- Nachweis, dass weder Datenverlust noch unerkannte Duplikate entstehen.

### Performance und Scale Out

- Buffer-, Batch-, Commit- und Parallelism-Konfiguration;
- konkurrierende Packages und Resource-Contention;
- Fast Load gegenüber zeilenweiser Verarbeitung;
- SSIS Scale Out mit Master und katalogisierten Workern;
- Worker-Ausfall, Queue-Verhalten und erneute Zuweisung;
- Durchsatz- und Laufzeitvergleich ohne absolute Aussage aus einem Einzelhost.

## Provider- und Plattformvertrag

- Hyper-V/Windows ist der verpflichtende vollständige Referenzpfad für SSIS,
  SSISDB, SQL Agent, Windows Authentication, CDC und Scale Out.
- Docker und Podman dürfen SQL-Quellen, Staging-, Warehouse-, Ziel-, Client-
  oder Fault-Komponenten bereitstellen und benötigen getrennte Runtime-Evidence.
- SSIS unter Linux ist nur eine optionale, versionsgebundene reduzierte Lane.
  SSISDB, SQL-Agent-Scheduling, Windows Authentication, CDC, Scale Out,
  Drittanbieterkomponenten und weitere Features sind dort nicht verfügbar.
- SSIS ist laut aktuellem Herstellerstand nicht für SQL Server 2025 unter
  Linux verfügbar. Daraus folgt kein Container- oder Linux-2025-Versprechen.
- Ein frei gebautes SSIS-Containerimage gilt nicht ohne Herstellerfreigabe,
  katalogisierte Recipe und reale Evidence als unterstützt.

## Artifact-, Lizenz- und Security-Vertrag

- SQL-/SSIS-Installationsmedien, SSDT-Erweiterungen, Treiber und Packages
  erhalten Version, Quelle, Digest, Lizenz und Capability Record.
- Developer Editions werden ausschließlich für Entwicklung und Test verwendet;
  Standard- und Enterprise-Zielprofile bleiben getrennt.
- Packages, Konfigurationsdateien und Connection Manager enthalten keine
  Secrets oder realen Infrastrukturwerte.
- Drittanbieter-Tasks und -Connectoren benötigen ein eigenes Lizenz-,
  Security-, Maintenance- und Exit-Review.
- Testdaten sind synthetisch oder ausdrücklich redistributierbar.

## Erster Vertical Slice

### Begrenzter Diagnoseeinstieg zu Schritt 1

`Tools/Test-SqlServerLabSsisPrerequisite.ps1 -RunId $runId -InstanceId primary`
beobachtet eine bereits laufende eigene Hyper-V-/Windows-/SQL-2025-Instanz.
Der interne Einstieg ist kein neuer öffentlicher Cmdletvertrag. Er verwendet
den bestehenden StateRoot, bindet Run, Instanz und tatsächliche VM-ID und
verweigert WinRM-Fallback. Der Gasttransport ist auf 10 bis 120 Sekunden,
die SQL-Abfrage auf höchstens 30 Sekunden begrenzt. Secrets bleiben flüchtig;
Ergebnisse und Diagnosen dürfen ausschließlich lokal verwendet werden.

Getrennte Beobachtungen sind tatsächlicher SQL-Major und Edition, zwei
SSIS-Komponentendateien mit Dateimajor 17 am dokumentierten Standardpfad sowie
SSISDB-Zustand und Vorhandensein der Katalogsicht `catalog.catalog_properties`.
`DefaultPathComponents=NOT_OBSERVED` bedeutet nur fehlende Dateien dort.
Konfigurierbare andere Installationsorte werden nicht durchsucht; fehlende
Standarddateien beweisen keine fehlende SSIS-Installation. Zugriffsfehler,
Reparse-Dateien und unpassende Dateiversionen liefern `UNKNOWN`.
Der SQL-Check wertet SSISDB-Abwesenheit ausschließlich mit beobachteten
Sysadmin-Sichtrechten aus, damit unsichtbare oder offline Datenbanken nicht
als fehlend ausgegeben werden. Eine gewöhnliche Datenbank namens SSISDB ohne
Katalogsicht bleibt `ONLINE_UNVERIFIED`.

`OBSERVED` beschreibt Beobachtungen, keine erfüllten Voraussetzungen oder
Ausführungsfreigabe. `InstallationVerified=false` und
`ExecutionStatus=NOT_EXECUTED` bleiben immer erhalten. Editionserkennung beweist
keine SSIS-Featureberechtigung. Es gibt keine Installation, SSISDB-Erstellung,
Packageausführung, VM-Start, Zustandsänderung oder automatische Reparatur.
Bindungsänderungen während der Probe verwerfen das Ergebnis. SQL- und
Transportfehler bleiben sanitisiert und von fehlenden Komponenten getrennt.

Die Offline-Suite `Invoke-SsisPrerequisiteChecks.ps1` prüft tatsächliche
Entscheidungs-, Kontext- und Gastlesefunktionen mit synthetischen Ergebnissen,
Identitätsabweichungen, Sichtrechten, Fehlern, Timeout und Secretentsorgung.
Die native Voraussetzungenprüfung und alle folgenden ETL-Abnahmen sind
weiterhin **NOT_EXECUTED**. Der Gesamtbacklog bleibt offen.

Herstellergrundlagen: [Dateipfade und gemeinsame SSIS-Komponenten](https://learn.microsoft.com/sql/sql-server/install/file-locations-for-default-and-named-instances-of-sql-server?view=sql-server-ver17),
[SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17)
und [Sichtrechte für sys.databases](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17).

### Vollständige noch offene Folge

Der interne IS-only-Einstieg
`Tests/Integration/Invoke-SsisOwnedInstallAcceptance.ps1` implementiert den
Installationsanteil von Schritt 1 auf einem frischen eigenen Hyper-V-Slot.
Er verlangt ein explizites Windows-Server-2025-`OS_SEALED`-Artifact, einen
expliziten Medienroot, den relativen ISO-Pfad und einen unabhängig
freigegebenen SHA-256. Der vorhandene Sidecar und der tatsächlich gelesene
ISO-Inhalt müssen beide dazu passen; der offene Lesehandle verhindert während
der Installation auf Windows Änderungen oder Austausch der Datei.

Nur SQL 2025 mit Enterprise-Developer-Ziel und `SQLENGINE,IS` ist vorgesehen.
Der bestehende direkte Slotinstaller bindet diesen Opt-in an Operation und
VM-ID, verweigert vorhandene SQL-Pläne und erhält alle bisherigen Defaults.
Setup verwendet den integrierten SSIS-Dienstaccount und deaktiviert automatische
SQL-/Microsoft-Updates. Windows-Aktivierung ist `VerifyOnly` mit verweigertem
Egress; fehlende Aktivierung ergibt keinen Online-Fallback. Setup ist auf
5400 Sekunden und der Setuptransport auf weitere 360 Sekunden begrenzt;
SQL-Neustartbereitschaft einschließlich des äußeren PowerShell-Direct-Transports
auf 600 Sekunden, die getrennten Gastproben auf 90.

Die Abnahme verlangt tatsächlichen SQL-Major 17 und Developer-Edition,
laufenden SSIS-170-Dienst, passende Dienstdateiversion, weiterhin fehlendes
SSISDB und dieselben Postconditions nach VM-Neustart. Eigener Run-State und
Cleanupplan entstehen vor Provideränderungen. Auch bei verlorener
Erstellungsantwort wird ausschließlich der eindeutig operationseigene Run
bereinigt; VM-ID und dateigenaue VHDX-Reste werden kontrolliert. Primär- und
Cleanupfehler bleiben getrennt. Bei hartem Abbruch des gesamten aufrufenden
Prozesses ist die gespeicherte Operation manuell besitzgebunden zu prüfen;
es gibt keinen automatischen erneuten Installationsversuch. Reale Ausgaben
bleiben ausschließlich unter dem lokalen StateRoot, außerhalb des Checkouts.
Sie dürfen nicht als CI-Artefakte hochgeladen werden.
`local.log` ist derzeit nicht größenbegrenzt; der Einstieg enthält keinen
begrenzten Logcollector. Freier lokaler Speicher ist daher vor einer nativen
Abnahme zu prüfen. Ein Diagnose-Schreibfehler verdrängt weder den ursprünglichen
Installationsfehler noch einen getrennten Cleanupfehler.

Die synthetische Suite `Invoke-SsisOwnedInstallChecks.ps1` prüft Freigabe-,
Medien-, Argument-, Plan- und Teilfehlerverträge. Echte Installation, Neustart
und eigenes Runtime-Cleanup sind bis zur separaten nativen Abnahme
**NOT_EXECUTED**. SSISDB, Packages und ETL bleiben offen; es entsteht keine
öffentliche Provider- oder Editionsfreigabe.

**Abhängigkeit für die Wiederaufnahme der Kataloganlage:** Ein vollständiger,
versions- und hashgebundener Offlinebestand von
`Microsoft.SqlServer.Management.IntegrationServices` samt Abhängigkeiten ist
noch nicht belegt. Die allgemeine SSIS-Anleitung nennt Client Tools SDK,
der versionsbezogene Setupvertrag begrenzt `SDK` jedoch auf SQL 2019 und älter.
Deshalb werden weder `/FEATURES=SDK` noch ein geratenes SMO-Paket oder
`LoadWithPartialName` verwendet. Der Beschaffungscheckpoint unten trennt die
weiterhin offenen Paket-, Host- und Integritätsverträge; erst nach deren
Klärung folgen gebundener Paketprüfer und Kataloganlage. Quellen: [Setupfeature IS und SDK-Grenze](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17),
[SQL-2025-Editionen](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2025?view=sql-server-ver17),
[SSIS-Installation](https://learn.microsoft.com/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17).

### Beschaffungscheckpoint G: weiterhin offen

Der vollständige Beschaffungsscope unter `SFT-711`/`SFT-712` und
`AIX-001`/`AIX-008` bleibt offen. Dokumentenrecherche und begrenzte statische
Inventur ergeben keinen validierten Paket-, Installations- oder Funktionsvertrag.
Eine Bootstrappervorstufe ersetzt weder Vollmedien noch transitive Abhängigkeiten.

Der dokumentierte Herstellerweg ist eine SSMS-Komponenteninstallation mit
`Microsoft.SSMS.Component.IS`, auch aus einem selektierten Offline-Layout:
[Komponenten](https://learn.microsoft.com/en-us/ssms/install/workload-component-ids),
[Offline-Layout und Installation](https://learn.microsoft.com/en-us/ssms/install/create-offline).
Dies belegt keine eigenständige Beschaffung durch Kopieren einzelner IS-/SMO-DLLs.
Die vorgesehene Windows-/Hyper-V-IS-Installation und ihre native Abnahme bleiben
von der Bereitstellung des Managementclients getrennt.

Für einen eigenen Windows-x64-/WindowsPowerShell-5.1-/.NET-Framework-Host fehlen
noch ein exakter Bindingvertrag und eine isolierte Offline-Ladeprobe. Der
[PowerShell-Quickstart](https://learn.microsoft.com/en-us/sql/integration-services/ssis-quickstart-deploy-powershell?view=sql-server-ver17)
zeigt den API-Nutzungsweg, definiert aber keine vollständige versionsgebundene
SSMS-Assemblyauflösung für diesen Host. Sein Modulpin ist kein pauschaler Beleg
für eine zusätzlich erforderliche Abhängigkeit jedes SSMS-Bestands. Diese offene
Engineering-/Validierungsgrenze ist kein generelles Nutzungsverbot; SSMS-
Hostredirects dürfen nicht ungeprüft übernommen und .NET-Framework-/coreclr-
Bestände nicht vermischt werden.

Davon getrennt bleiben die Rechte zur Redistribution eines selbst
zusammengestellten Standalonepakets, dessen genaue Noticezuordnung und der
exakte Beschaffungs-/Integritätsvertrag ungeklärt. Die
[SSMS-22-Lizenz](https://learn.microsoft.com/en-us/legal/sql/ssms/sql-server-management-studio-22-license-terms)
verweist auf konkrete Distributable-Rechte; die verlinkte
[Distributable-/Utilities-Liste](https://learn.microsoft.com/en-us/legal/sql/ssms/ssms-redistribution-utilities)
bezeichnet beim Quellencheck weiterhin SSMS 21. Die
[Notice-Anleitung](https://learn.microsoft.com/en-us/legal/sql/ssms/ssms-third-party-notices)
ersetzt keine versionsgenaue Lizenzzuordnung. Lokale Nutzung einer vorhandenen
Installation und Weitergabe eines Pakets sind unterschiedliche Fragen.
Widersprüchliche Payloadgrößen sind vor einer exakten Katalogfreigabe zu klären;
ein Hashmatch rechtfertigt keine Größenanpassung und beweist allein keinen
Herstellertrust. Eine Größenabweichung allein beweist keine beschädigte DLL.

Begrenzte Wiederaufnahmeoptionen innerhalb derselben Aufgaben sind ein
herstellergeführter Layout-/Komponentenvertrag oder ein rechtlich geklärter
eigener Hostvertrag mit ausdrücklich begrenzter Supportaussage und separater
Offlineprobe. Erst daraus ergibt sich die noch zu schließende Abhängigkeitsmenge.
Keine weitere serielle Suche, Beschaffung oder Ladeprobe ist aus diesem
Checkpoint freigegeben. Die autonome Produktumsetzung von G endet hier;
unabhängige kanonische Slices können weitergehen. Registriert, herunterladbar,
lokal geprüft, installiert, konfiguriert und funktional bleiben getrennt.
SSISDB/ETL bleiben bis zur vollständigen Offlineclosure offen; C# bleibt
`USER_DEFERRED`.

### Reihenfolge der vollständigen Umsetzung

1. Einen Windows-/Hyper-V-Slot mit SQL Server, SSIS und SSISDB bereitstellen.
2. Eine kleine synthetische SQL-Quelle und ein getrenntes Warehouse erzeugen.
3. Ein katalogisiertes SSIS-Projekt mit Staging-, Dimensions- und Fakt-Package
   nach SSISDB deployen.
4. Environment und Parameter ohne Secretpersistenz binden.
5. Full Load, wiederholten No-op und einen Delta Load ausführen.
6. Zeilenzahlen, Schlüssel, Summen, Rejects und SSISDB-Status prüfen.
7. Einen kontrollierten Zielabbruch auslösen und den Lauf idempotent fortsetzen.
8. Stop, Start, VM-Restart, erneute Ausführung und Cleanup bestätigen.

## Abnahmekriterien

- Provision, Deployment und Ausführung erfolgen unattended und sind resumierbar.
- Wiederholtes Deployment erzeugt weder doppelte Projekte noch unkontrollierte
  SSISDB-Versionen oder Environments.
- Full Load, Delta Load und SCD liefern exakt erwartete synthetische Ergebnisse.
- Fehlerpfade bleiben sichtbar, sanitisiert und nach Behebung fortsetzbar.
- Kein Secret erscheint in Manifest, Plan, Command Line, State, Log oder Receipt.
- Hyper-V-Ressourcen, SSISDB-Objekte, Jobs, Testdaten und lokale Artefakte werden
  ausschließlich nach nachgewiesenem Eigentum entfernt.
- Docker- und Podman-Komponenten gelten nur nach getrennten realen Läufen als
  validiert; ihr Erfolg ersetzt keinen Windows-/SSIS-Nachweis.

## Nicht Teil des ersten Vertical Slice

- produktive ETL-Ausführung oder Übernahme produktiver Packages und Daten;
- allgemeine Azure-SSIS-IR- oder Cloud-Orchestrierung;
- frei installierte Drittanbieterconnectoren;
- SAP-, Oracle-, Teradata- oder Mainframe-Integration ohne eigenes Szenario;
- Behauptung vollständiger Linux-Parität;
- hochverfügbares SSISDB oder SSIS Scale Out; diese Pfade gehören zum
  Cluster-Backlog.

## Bei Umsetzung erneut zu prüfende Herstellerquellen

- [Integration Services installieren](https://learn.microsoft.com/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17);
- [SSIS Catalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17);
- [SSIS unter Linux: Features und Einschränkungen](https://learn.microsoft.com/sql/linux/sql-server-linux-ssis-known-issues?view=sql-server-ver17);
- [SSIS Scale Out](https://learn.microsoft.com/sql/integration-services/scale-out/integration-services-ssis-scale-out?view=sql-server-ver17);
- [SSIS-Features nach Edition](https://learn.microsoft.com/sql/integration-services/integration-services-features-supported-by-the-editions-of-sql-server?view=sql-server-ver17).
