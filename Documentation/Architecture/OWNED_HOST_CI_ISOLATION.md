# Eigener CI-Scope auf einem gemeinsam genutzten Windows-Host

## Isolierte Linux-TLS-Clientfixture

Der ausdrückliche Harness
[`Invoke-AuthenticatedTlsLinuxAcceptance.ps1`](../../Tests/Integration/Invoke-AuthenticatedTlsLinuxAcceptance.ps1)
verwendet einen neuen eigenen Run und dieselbe ursprüngliche Runtimepolicy.
Die zusätzliche Fixtureform `tls-linux-client-v1` akzeptiert ausschließlich
eine feste Argumentfolge und einen receiptgebundenen laufenden SQL-Container
der Instanz `primary` desselben Runs als Netzwerk-Namespace. Der Client nutzt
das bereits vorhandene unveränderliche SQL-2025-CU9-Stockimage als Werkzeugbasis;
sein SQL-Entrypoint wird nicht gestartet. Fehlende Images werden nicht geladen.

Fest sind Benutzer `10001:0`, schreibgeschütztes Root-Dateisystem, verworfene
Capabilities, `no-new-privileges`, 96 PIDs, 1 GiB RAM, eine CPU und ein begrenzter
Sleep-Prozess. Ein eigener ausführbarer tmpfs von höchstens 512 MiB nimmt das
hashgebundene PowerShell-Paket auf; `/tmp` bleibt `noexec` und auf 32 MiB begrenzt.
Hostmounts, veröffentlichte Ports, freie Befehle und zusätzliche Argumente sind
in dieser Createform ausgeschlossen. Allgemeine Createformen behalten ihre
bisherige tmpfs-Grenze. Der SQL-Run und jeder Client benötigen vor Erstellung
eigene Intents; Übernahme fremder Container bleibt ausgeschlossen.

Bei Podman entspricht der private UTS-Hostname exakt dem DNS-labelgültigen
eigenen Client-Intentnamen. Die zusätzliche feste Createoption ändert weder
den SQL-Zielnamen `localhost` noch dessen Zertifikats-SAN. Die gemeinsame
Hostsdatei wird nicht nachträglich bearbeitet. Docker erhält diese Option nicht.

Ein einzelner ausdrücklicher Lauf umfasst höchstens ein neues SQL-Lab, fünf
nacheinander erzeugte Clientnamespaces und vier eigene Leafschlüssel. Von
450 gezählten äußeren Dispatches sind die letzten 50 ausschließlich für
Cleanup vorgesehen; abgewiesene Aufrufe setzen den Zähler nicht zurück.
Interne Policy-/Ownershipabfragen der Produktaufrufe sind keine gemessene
Gesamtzahl nativer CLI-Aufrufe. Vor jedem SQL-Neustart ist der bisherige Client
entfernt; jeder Nachfolger bindet den aktuellen eigenen Netzwerk-Namespace neu.
Der Controller hält die tatsächliche Runtimelease bis zum bestätigten Workerende.
Ein geschütztes, gehaltenes Ticket bindet genau den eigenen Worker an den
lebenden Parent und dieselbe Quelle; es erteilt keine neue Ressourcenautorität.
Ready bindet PID und Startzeit des tatsächlich zugeordneten Workers. Eine
vollständig geschriebene und geschlossene temporäre Datei wird ohne Überschreiben
auf den festen Ready-Namen verschoben; der Worker sieht keine Teilbytes. Eine
atomare Einmalbeanspruchung, der noch gehaltene Dateileselock und ein vor
Leasefreigabe geschriebener Abschlussmarker verhindern parallele oder spätere
Ticketwiederverwendung. Andere Datei- oder Zugriffsfehler gelten nicht als
Nachweis des gehaltenen Locks.
Vor Provideraktionen muss der Worker seinem Windows-Job mit `KILL_ON_JOB_CLOSE`
zugeordnet sein. Neue gewöhnliche Dispatches enden nach 25 Minuten; laufende
öffentliche Lifecycleaufrufe stehen ebenfalls unter dem äußeren Prozessbudget.
Nach 30 Minuten wird der Worker samt Prozessbaum beendet; die Terminierung
wird einmalig für höchstens fünf weitere Sekunden durch null aktive Prozesse
im Windows-Job bestätigt. Auch nach gewöhnlichem Workerende werden verbliebene
Nachfahren beendet und geprüft. Ohne diese Bestätigung bleiben Job, Ticketlock
und Runtimelease für Recovery gehalten. Die fünf Minuten zwischen
Stopanforderung und Hardstop dienen kooperativem Cleanup. Vor einem weiteren
Start sperrt vorhandene Recoverycustody auch den bisherigen aufrufenden Thread;
die rekursive Mutexsemantik erteilt keine neue Arrange-Freigabe. Ein hängender Aufruf
begründet keine Garantie für abgeschlossenen Rollback. Hardstop, unbestätigtes
Workerende oder unvollständiger Cleanup bleiben FAIL mit Recoverybedarf;
erst tatsächliche Ressourcenabwesenheit erlaubt PASS. Ein Parentabbruch schließt
den nicht vererbten Jobhandle und beendet den gebundenen Worker ebenfalls.

Die Client-tmpfs-Eigentümerschaft wird für Docker mit festen `uid`-/`gid`-
Optionen und für Podman mit dessen `U`-Option bei unverändertem Benutzer
`10001:0` erzeugt. Die Option gilt ausschließlich für das feste eigene tmpfs,
nicht für Hostpfade oder Volumes. Vor der Podman-Paketinstallation muss die
beobachtete Eigentümerschaft `10001:0` mit Modus `0700` übereinstimmen.
Fehlende oder abweichende Werte sperren die Vorbereitung.

Docker muss weiterhin die feste `ALL`-Capabilityauswahl ausweisen. Podman
stellt entfernte Capabilities als Differenz seiner Standardmenge dar; dort
müssen die vorhandenen OCI-Felder für Effective und Bounding leer sein.
Vor jeder Podman-Paketinstallation werden zusätzlich alle fünf Capability-
Masken und `NoNewPrivs` direkt aus `/proc/1/status` des eigenen Clientcontainers
geprüft: ausschließlich Nullmasken und `NoNewPrivs=1` sind zulässig. Die
übrigen Namespace-, Benutzer-, Mount-, Port- und Read-only-Prüfungen bleiben
Pflicht. Geschützte Diagnostik speichert deren feste Wahrheitswerte, keine
vollständigen Inspectdaten; sie ist kein bestandener Kernel- oder TLS-Nachweis.
Vor der Podman-Paketinstallation wird außerdem der frisch gelesene private
UTS-Hostname gegen dieselbe eigene vollständige CID, den beobachteten
Konfigurationswert und den festen Intentnamen gebunden. Ein vom Intentnamen
abweichender tatsächlicher Hostname sperrt die Vorbereitung auch dann,
wenn seine Auflösung erfolgreich wäre. Zwei feste
`getent ahostsv4`-Abfragen prüfen `localhost` und diesen Eigenhostname mit
je höchstens drei Sekunden. Gespeichert werden nur Exitcodes und Wahrheitswerte
zur Lesbarkeit beziehungsweise zu passenden Aliasen in `/etc/hosts`.
Namen, Adressen und Dateiinhalte bleiben außerhalb dieses Diagnoserecords.
Auch bei einem Fehler des festen Shellaufrufs speichert dessen Fehlerbeleg
anstelle der tatsächlichen Argumente ausschließlich die feste NSS-Operationskennung.
Nur dieser feste Shelltext wird vor dem Dispatch von CRLF auf LF normalisiert;
ein verbleibendes einzelnes CR sperrt die Ausführung. Hostnamenargumente,
Transportdaten und Zugangsdaten werden nicht normalisiert. Eindeutige
Syntax- beziehungsweise Werkzeugfehlermeldungen erhalten feste Fehlercodes;
mehrdeutige oder unbekannte Meldungen bleiben unklassifiziert und fehlgeschlagen.
Eine fehlgeschlagene Auflösung sperrt die Vorbereitung. Diese OS-NSS-Beobachtung
belegt weder identische ODBC-Resolverparameter noch eine TLS-Qualifikation;
die gemeinsame Hostsdatei wird nicht geändert. Die Prüfung folgt der eigenen
Leaf-/SQL-Konfiguration und liegt vor der Paketinstallation und ersten Clientprobe.
ODBC-Positivfehler unterscheiden feste Kategorien für Clientexit, unerwartetes
stderr, SQL-Ergebnis und fehlende beziehungsweise unlesbare Treiberbeobachtung.
Ausdrückliche Anmelde- und Abfragetimeouts werden getrennt klassifiziert;
eine allgemeine Timeoutmeldung belegt keine dieser beiden Ursachen.
Version `1.0` behält drei Stringfelder. Version `2.0` ergänzt ausschließlich
für fehlgeschlagene ODBC-Positivproben sieben geschlossene Fakten: Exitcode,
monotone Kindlaufzeit, Treiberbeobachtung und zwei begrenzte TCP-Diagnosen im
eigenen Client-Namespace. Pro aufgelöster Loopback-Adressfamilie wird nach dem
bereits fehlgeschlagenen Client genau eine Verbindung an Port 1433 mit höchstens
einer Sekunde aufgebaut, ohne SQL-Abfrage oder TLS-Qualifikationsclaim.
Die tatsächlich vom ODBC-Client gewählte Adressfamilie bleibt `NOT_OBSERVED`.
Version `2.1` bindet zusätzlich die tatsächlichen sqlcmd-/Treiberhashes,
höchstens 13 feste Meldungskategorien und genau einen normalisierten numerischen
TCP-Providerfehlercode beziehungsweise dessen ausdrückliche Abwesenheit oder
Mehrdeutigkeit. Ein Boolean erfasst ausschließlich, ob `SQLCMDPASSWORD` beim
Kindstart gesetzt war; er belegt keine tatsächliche Verwendung im Client.
Passwortwert, Länge und Hash werden nicht erfasst. Meldungstexte, Dateipfade und Adressen gelangen nicht in diese
Fakten. Frühere Versionen bleiben mit ihren ursprünglichen Feldmengen lesbar.
Hostname, TLS-Optionen, Zeitgrenzen und Wiederholungszahl der eigentlichen
Clientprobe bleiben unverändert. Unbekannte Felder, Typen und Werte sowie
Duplikate werden verworfen. Rohtexte und Zugangsdaten werden nicht übertragen. Weder diese Einteilung noch
ein fehlender Treiberbeleg dürfen einen positiven oder negativen TLS-Fall bestehen lassen.

Für die SQL-2022-/SQL-2025-Leafvorbereitung bleibt die UID auf `10001` festgelegt;
die primäre Gruppe wird wie im operativen SQL-Pfad vom Imageaccount aufgelöst.
Zwei lesende Prüfungen vergleichen die zuvor erzwungene Gruppe mit der
Accountgruppe und prüfen den eigenen SQL-Datenpfad vor Leaf-/Keyänderungen.
Eine andere UID, eine widersprüchliche ausgewählte Gruppe oder fehlender Schreibzugriff
sperren die Vorbereitung. SQL-2019-Argumente und die feste
Clientfixtureidentität `10001:0` bleiben unverändert. Der geschützte Nachweis
dieser Prüfungen ist keine TLS-Qualifikation und keine Recoveryautorität.

Vor jedem Phase-/Cleanupbudget wird derselbe ursprüngliche physische Pin frisch
gegen Policy und Inkarnation geprüft. Seine Podman-Maschinenbindung stammt aus
der ursprünglichen Discovery; die Policyprojektion ersetzt sie nicht. Die
allgemeine OwnedHost-Freigabe für Maschinenbefehle wird nicht erweitert.
Vor dem ersten Provider-Arrange wird dieser physische Pin zusätzlich als
geschützter privater Nachweis gespeichert. Er dient der späteren Reconciliation;
die Nachweiskopie erteilt keine Ausführungs- oder Cleanupautorität.

Unerwartete Clientfehler verlassen die Probe als geschlossener JSON-Fehlerrecord
mit festem Code und fehlerhaftem Exitcode. Der Host übernimmt nur das begrenzte
Schema und bekannte Codes; formatierter Fehlertext ist kein Protokoll.
Rohdiagnosen und Eingaben werden nicht gespeichert. Solche Diagnosecodes
qualifizieren keinen negativen TLS-Fall. Die nach Cleanup tatsächlich beobachtete
Ressourcenliste wird privat vor ihrem Vergleich gespeichert, auch wenn der
anschließende unveränderte Bestandsvergleich scheitert.

Der Fixture-Issuer lebt nur im Speicher, Serverkeys bleiben im neuen eigenen
SQL-Container und die öffentliche CA-Datei liegt nur im Client-tmpfs. Trust gilt
ausschließlich für die beiden ausgewählten Kindprozesse. Bestehende CAs,
Hoststores und ursprüngliche Schlüssel werden nicht geändert. Der Harness
qualifiziert keine öffentliche Linux-Registry und keinen Linux-V2-Export.
Seine gezielte synthetische Suite ist Teil der betroffenen statischen Auswahl;
die native Matrix bleibt ausdrücklich gestartet und wird durch den Selektor
nicht zusätzlich automatisch ausgeführt.

Der bestehende `OwnedRunWindows`-Kern wird zusätzlich von der neuen
[operativen TLS-Lane](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) für ausschließlich
frische eigene `0.2`-Lab-StateRoots verwendet. Policy, Owner-only-Rootcustody,
Runreferenzen, Creationreceipts und gepinnte Lifecycle-/Cleanupaufrufe bleiben
unverändert. Der eigene TLS-Lab-Rootguard ist vom unveränderten CA-/Datei-ACLguard
getrennt. Eine ursprüngliche Engine-/Machine-Inkarnation speichert und prüft
dieser Consumer zusätzlich; sie wird nicht aus der Policy-Scopeprojektion
abgeleitet. Der folgende CI-Harness bleibt ein getrennter Consumer.
Die beiden Provider geben ihren StateRoot bei Volume-Create/-Initialisierung
und Container-Create/-Start/-Stop/-Remove ausdrücklich an den Operation-Wrapper
weiter. Dessen eigener Parameter darf den Effekt- und Diagnoselogkontext nicht
durch seinen leeren Default ersetzen. Eine Fixture mit tatsächlichem Wrapper
prüft beide Remove-Pfade; Creation-Fixtures verlangen ebenfalls den gebundenen Root.

Der Portvorschau-Harness verwendet einen frischen externen
`sql-lab-port-preview-<GUID-N>`-Parent plus getrennte Policy am `State`-Child.
Nur die eigene Parent-Location wird registriert; der moderne nichtpersistente
Run verwendet den Child-StateRoot. Keine existierende Policy/Run wird bewegt
oder adoptiert. ParentOperation, Policy-/Marker-/Catalog- und tatsächliche
Container-/Volume-Creation-/Intenthashes werden vor PublicRemove erneut geprüft.
Nach Cleanup müssen State REMOVED und exakte same-pin Ressourcenabwesenheit
bestätigt sein; andernfalls bleibt der Parent samt Registrierung/Custody.
Am 2026-10-05 bestanden Docker und Podman auf `bee35c5d` getrennt die
begrenzte PLAN_ONLY-Abnahme: je fünf öffentliche Previewaufrufe über Core,
Console-Menü und in-process HTTP, unveränderte Statebytes und bestätigtes
Own-Cleanup mit REMOVED/COMPLETED-Records und Ressourcenabwesenheit. Der
Vorher-/Nachher-Schutzvergleich blieb ohne Findings oder Beobachtungen.
Gerenderter Browser, HTTP-Netztransport, Preview-SQL/Endpoint und Apply sind
damit nicht geprüft. Der Harness ersetzt keinen kanonischen Provider-Gate
und startet keine Maschine/Runtime. Frühere Fehlerbelege bleiben unverändert.

## Auswahl und Vertrauensgrenze

Die Container-CI legt über `Tests/Common/OwnedHostTestScope.ps1` einen frischen,
expliziten StateRoot in einem kurzen GUID-Verzeichnis neben `RUNNER_TEMP` an.
So bleiben Ownershiprecords und private Runtime-Logs nach Jobabbruch erhalten,
ohne lange Docker-Desktop-Bindpfade einzuführen. Der interne Initializer schreibt
`owned-host-required` und die typisierte `owned-host-policy.json`. Root und
Policydatei erhalten den aktuellen Token-SID als Owner sowie geschützte ACLs
mit ausschließlich dessen FullControl. Ein vorhandener Root wird nicht
übernommen. Ein verlorener oder veränderter Policyrecord führt nicht zum
Standardpfad zurück. Ohne Profil bleiben die bisherigen Standardverträge
wirksam. Ein Pfad oder eine Umgebungsvariable allein erteilt keine Autorität.

`PolicyId` und `RootScopeId` bezeichnen den Root. `ParentOperationId` beschreibt
die Initialisierung; sie ist weder Präfix noch Gleichheitsbedingung für
Workflowoperationen. Jeder tatsächliche `New-LabRunState` persistiert seine
RunId, ScopeId, WorkflowOperationId und den Policyhash. Batchgeschwister sowie
SQL-Upgrade-Quell-/Zielruns behalten ihre unterschiedlichen Operationen. Fehlt
der Workflowcontext, allokiert der bestehende GUID-Generator eine eigene
Operation. Das Schema beschreibt Policy und Runreferenz; Laufzeitprüfungen
prüfen zusätzlich Dateirechte, Pfade, Hashes und tatsächliche Ressourcen.

## Explizite Providerroute

Docker verwendet ausschließlich den gespeicherten lokalen Named-Pipe-Host mit
`--host`. Podman verwendet `--remote --url --identity` für die ausgewählte
bereits erreichbare lokale Maschinenverbindung mit Loopback-SSH und
hashgebundener Identitydatei. Weder Context noch Defaultconnection werden bei
späteren Aufrufen erneut gewählt. Routingvariablen werden nur für den
Kindprozess entfernt. Alle Beobachtungen, Effekte und Kompensationen verwenden
denselben Pin. Der Transport begrenzt beide Ausgabepipes gemeinsam auf 1 MiB
und besitzt einen endlichen Timeout. Remotehosts und unbekannte Routen bleiben
vor Arrange gesperrt; das Profil startet keine Podmanmaschine.
Podman-Create prüft Clientoptionen bis zur validierten unveränderlichen
Image-Referenz über den bestehenden Create-Parser. Ein vorheriges `-c` bleibt
gesperrt; danach darf es als Shellargument des eigenen Containers passieren.
Lange Routingoverrides bleiben gesperrt. Intent-, Mount- und Imagebindungen
werden vor dem tatsächlichen Create weiterhin vollständig geprüft.

Die RuntimeScope-Projektion verwendet `EXPLICIT_POLICY_PIN`. Ihr DisplayName
ist eine Policyanzeige; die bestehende Formel `DisplayName|Endpoint|BackendKind`
bleibt erhalten. `REPORT_ONLY` und `PRESERVE_RUNTIME` gelten weiter. Daraus
folgt weder eine Enginegeneration noch Kompatibilität mit anderen Roots oder
mit Standard-Scopeidentitäten. Die Projektion ersetzt keine Löschautorität.

## Ressourcen und Cleanup

Alle vorbestehenden Container, Volumes, Netzwerke, Images, Tags, Tasks,
Desktop-/HKCU-Einstellungen und Hostdienste bleiben erhalten. Eigene
Container benötigen einen exklusiven Write-ahead-Intent, die tatsächliche
Creation-Receipt, vollständige 64-stellige CID und frische eigene Labels am
selben Pin. Namen, UUIDs oder Labels allein erlauben keine Adoption. Diese
Prüfung gilt auch für Sidecars, Probecontainer und Fehlerkompensation.

Eigene Volumes besitzen separate Creation-Receipts, Namensabwesenheit vor
Create und frische Inspect-/Labelbindung. Diese Records bleiben nach
Containerentfernung für Retained-Store-Beobachtung und Transfer erreichbar.
Entfernung prüft zusätzlich die bestehenden Store-/Attachmentverträge.
Ein gültig gebundener Run darf ein am selben Pin nachweislich abwesendes
Volume ohne Delete als bereits bereinigt behandeln, auch wenn Arrange vor
der Creation-Receipt abbrach. Fehler bei der Inventarbeobachtung bleiben
gesperrt; ein vorhandenes Volume benötigt weiterhin sämtliche Besitznachweise.
Podmans Besitzanpassung mit `U`, `U,ro` oder `U,rw` ist ausschließlich
für Named Volumes mit vollständiger Creation-Receipt und frischer Labelbindung
zulässig. Host-Bind-Mounts erhalten diese rekursive Besitzänderung nicht;
unbekannte oder doppelte Optionen und Docker-`U` bleiben gesperrt.
Vorhandene Netzwerke werden nur gelesen. Hostschreibpfade bleiben im eigenen
Root; gemeinsame Netzwerk-, CNI- und Cacheänderungen werden gesperrt.

Bibliotheksbackups binden zusätzlich den eigenen Run und den `DataRoot` im
Policyroot vor SQL- oder Dateieffekten. Ihre temporäre Exportdatei liegt in
einem frischen Verzeichnis unter diesem Root statt im globalen Tempverzeichnis.
Auch das temporäre Cleanup prüft die Root- und Pfadbindung. Ohne eigenes Profil
bleibt der bisherige temporäre Backupvertrag wirksam.
Die CI-Rootnamen behalten die vollständige GUID bei kurzem Präfix. Transfer-
Acceptance und Medien-Preflight allokieren ihre Daten direkt unter diesem Root
in frischen kurzen Verzeichnissen, damit die Evidence-Verzeichnisstruktur den
nativen Backup-Bind-Mount nicht unnötig verlängert. Das Daten-Cleanup verlangt
die unveränderte Policy und den prozesslokalen Allocationrecord mit Dateimarker;
vorhandene Verzeichnisse werden nicht adoptiert, Reparsepfade bleiben gesperrt.
Der Preflight entfernt seinen eigenen persistenten Ziel-Store nach Run-Cleanup
über den öffentlichen Retained-Store-Plan und dessen gebundenen Apply-Vertrag.
Bei fehlgeschlagener Bereinigung bleiben Daten und Custody für Recovery erhalten.
Wirft die Preflight-Erstellung vor Rückgabe einer Run-ID, bleibt auch ihr
möglicher partieller State erhalten; der Harness adoptiert keinen unbekannten Run.
Ein gleichzeitiger primärer Fehler und Cleanupveto behält die ursprüngliche
Exception; deren lokale `SqlServerLab.BackupCleanupStatus`-/
`SqlServerLab.BackupCleanupReason`-Metadaten zeigen den getrennten Recoverybedarf.

Der Package-Export-Recoverytest injiziert seinen kontrollierten Kopierfehler im
eigenen Profil erst am vorbereiteten nativen Prozessstart hinter den tatsächlichen
Route-, Custody- und Pfadprüfungen. Nur die exakte Runtime-Route und Container-ID
des Test-Runs treffen diese Fault-Injection; andere Aufrufe laufen unverändert weiter.

SqlPackage-ToolImages behalten ihre logischen Katalogschlüssel. Validierte
vorhandene Images dürfen über ihre unveränderliche Image-ID gelesen werden.
Podmans vollständige 64-stellige Hex-ID wird dabei zur gemeinsamen
`sha256:`-Referenz normalisiert. Verkürzte IDs bleiben für beide Provider gesperrt;
Docker benötigt weiterhin die vollständige präfixierte ID.
Ein notwendiger Build verwendet einen intern generierten Policy-/ImageKey-Tag,
exklusiven Intent, bestätigte Tagabwesenheit und `--pull=false`. Base und
Extractor müssen bereits unter dem katalogisierten Digest erreichbar sein;
fehlende Images lösen keinen Pull aus. Probecontainer gehören zum eigenen
Run. Imagecleanup entfernt ausschließlich den eigenen Tag ohne Prune oder
Force und erst nach terminalen referenzierenden Runs und ohne verbleibende
Containerreferenzen. Geteilte Tags oder Images werden nicht entfernt.

Autostart verwendet ausschließlich einen eindeutig eigenen Task und ein
hashgebundenes Koordinatorskript, Write-ahead-Receipt und exakte
Task-Revalidierung. Kein Force, keine Desktop-/HKCU-Änderung. Eine native
Task kann Principal und Logontrigger als Kontonamen statt SID zurückliefern.
Beide werden vor Create-Bestätigung oder Cleanup aufgelöst und mit dem exakten
Owner-SID verglichen; fremde, leere oder nicht auflösbare Identitäten bleiben
gesperrt. Die übrigen Action-, Trigger-, Principal- und Hashbindungen gelten weiter.
Eine registrierte
Task ist kein Nachweis tatsächlichen Logondispatchs. Öffentlicher Stop im
Profil überspringt gemeinsame Hostspeicherwartung auch aus verschachtelten
Lifecycle-/Gruppenpfaden. Der Standardvertrag für Hostspeicher bleibt bestehen.
Cleanupfehler behalten Ursache und Recoverybedarf; der Root wird nicht
pauschal rekursiv entfernt und seine lokalen Custodyrecords bleiben erhalten.

## Tatsächliche Pflichtketten und Grenzen

Sample-Artefakte verwenden im eigenen Profil standardmäßig die Bibliothek
`testdata-library` unter dem gebundenen StateRoot. Cache, sichtbare Bibliothek
und `LAB_GENERATED`-Baselines bleiben dadurch im eigenen Scope. Ein expliziter
Testdaten-Root muss absolut und innerhalb dieses Roots liegen. Policyverlust,
fremde Pfade und Reparse Points in den abgeleiteten Artifact- und Baselinepfaden
werden vor deren Initialisierung abgelehnt.
Auch später abgeleitete Digest-, Kategorie-, Objekt- und Quarantänepfade
werden vor Lesen, Schreiben oder Verschieben auf diese Grenze geprüft.
Die globale Bibliotheksauswahl des Standardprofils bleibt erhalten;
die Container-Kopiergrenze gilt weiter.

Docker-, Podman- und Mixed-Workflows geben denselben expliziten Root an ihre
bestehenden Harnesses weiter: Lifecycle/Matrix, Restore, Collation, Batch,
ToolAcceptance, PackageExport, PortableTransfer/Preflight, PITR, SQL-Upgrade,
AI-Vector und ausgewählte Podman-Samples. Native Restartpolicy-, Label- und
öffentliche DTO-Assertions bleiben erhalten. Hyper-V-Smoke nutzt den
bestehenden isolierten Reconcile-Vertrag und prüft Adapterabwesenheit; die
Hyper-V-Runtimeimplementierung wird dadurch nicht erweitert. Adaptergate und
vollständige Pflichtgateauswahl bleiben eigenständige Nachweise.

Der optionale CLI-Reconcile-Modus, InstanceStore-CLONE, parallele
Matrix-Runspaces im eigenen Profil und externe Runtime-ToolImage-Builds sind
vor Arrange ausdrücklich gesperrt. Sie werden nicht als bestandene Fälle
umgedeutet. Die fünf Pflichtgates bleiben vollständig auszuwählen. Rohlogs,
Pins, Hostwerte und native Diagnosen bleiben lokal; Uploads dürfen nur bereits
bereinigte Zusammenfassungen enthalten.

## Validation

`Invoke-OwnedHostIntegrationChecks.ps1` verwendet synthetische Records,
Transport-Spies und eigene PowerShell-Kinder für Transportgrenzen. Es führt
keine Provider-, SQL-, Task-, WSL- oder Desktopoperation aus. Die Suite
prüft zusätzlich den tatsächlichen Initializer für Docker, Podman und Mixed
mit synthetischen Discoveryantworten: Die ausgewählten Providernamen bleiben
bis zur Readinessprüfung erhalten. Diese Prüfung erzeugt keine native Policy.
Ein stabiler Diff benötigt gekoppelte statische Suites, unabhängige Reviews und getrennte native
Docker-, Podman-, Mixed-, Hyper-V- und Adapterpflichtgates am exakten Head.
Der CI-Selektor wählt diese fünf Gates auch bei einer isolierten Änderung am
OwnedHost-Core, seinem Root-Koordinator oder seinem Schema. Reine Änderungen
an der statischen Fixture oder dieser Dokumentation starten keine Runtime.
Vor und nach nativem Arrange müssen sämtliche vorbestehenden Ressourcen in den
durch die konkrete Operation tatsächlich erreichbaren Ressourcenscopes frisch
erfasst und als geschützt revalidiert werden. Die Schutzmatrix wird vor Arrange
aus Providerpin, erlaubten nativen Argumenten, tatsächlicher Aufruferkette und
Cleanupschritten festgelegt. Unbekannte Routen oder zusätzliche Operationspfade
bleiben gesperrt. Synthetische Checks, Readiness, Taskregistrierung und
historische Abnahmen ersetzen diese Nachweise nicht.

### Schutzmatrix für begrenzte Docker-/Podman-Operationen

Eine reine Containeroperation erfordert keine Hyper-V-Funktionsprüfung allein
wegen des gemeinsam genutzten Windows-Hosts. Voraussetzung ist eine geprüfte
Allowlist ohne VM-, VHDX-, Task-, Service- oder Hostkonfigurations-Schreibpfad,
einschließlich Cleanup und aufgerufener Hostkoordinatoren. Workflows mit solchen
Pfaden behalten den vollständigen Schutzumfang der jeweils betroffenen Klassen.

| Operationsumfang | Pflichtschutz und Grenze |
|---|---|
| Docker-/Podman-CreateOnly: eigene Containeranlage, Inspect und Entfernung; kein Start | Alle vorbestehenden Container, Volumes, Netzwerke, Images und Tags am betroffenen Pin frisch schützen; nur receiptgebundene eigene Ressourcen als erwartete Änderungen zulassen. Kein Pull, Build, Mount oder Publish; keine gemeinsamen Netzwerk-/Runtimeeingriffe. |
| Eigener StateRoot und Cleanup | Unveränderte Policy-/Runbindung, Write-ahead-Intent, vollständige CID, frische Besitzprüfung und bestätigtes Cleanup beziehungsweise sichtbarer Recoverybedarf. Keine Adoption fremder Ressourcen. |
| Host- und Backendressourcen | RAM-/CPU-Reserve, globale Ressourcenbelastung und verfügbarer Daemon-/Gastspeicher vor Arrange berücksichtigen; Verbrauch begrenzen. Daemonmetadaten und das DockerDesktop-/Podman-Backing können sich ändern. Keine Invarianz physischer Host- oder VHDX-Bytes behaupten. |
| SQL-/Receiverstart, interne Netze oder Named Volumes | Eigenständige erweiterte Schutzmatrix und getrennte Abnahme vor diesen zusätzlichen Operationen; kein Nachweis aus CreateOnly ableiten. |

Eine separate Vor-/Nachinventur dieser nicht erreichbaren Hostklassen ist für
genau diese CreateOnly-Allowlist nicht erforderlich; ihr Änderungsverbot bleibt
bestehen.

Diese Schutzklassifikation erteilt keine Ausführungsautorität und belegt keine
aktuelle native Abnahme. Sie verändert weder die CI-Auswahl noch die oben
genannten Pflichtgates. Nicht erreichbare Hostklassen bleiben vor Änderungen
geschützt; eine fehlende Hyper-V-Abnahme wird dadurch nicht zu einem PASS.

Die Consumer-Fixtures führen tatsächliche Provider-Inventar- und Create-Funktionen
mit null beziehungsweise mehreren Mounts, Transfer-Planung und die terminalen
PITR-, Upgrade- und Sample-Cleanupfunktionen mit gebundenen Transport-Spies aus.
Ein SQL-Wait mit realer Zeitmessung und synthetischem SQL-Probe bleibt auch nach
fünf Sekunden innerhalb seines konfigurierten Zeitfensters; ausgeschlossene
Hostwartung liefert keine erfundene Nichterreichbarkeitsdiagnose. Der öffentliche
New-Carrier wird gezielt durch Ausführung seiner tatsächlichen AST-Retryschleife
mit abweichender ambienter Runvariable geprüft. Diese begrenzte Prüfung deckt
weder die vollständige öffentliche Provisionierung noch native Wirkung ab.
