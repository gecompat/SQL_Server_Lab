# Native TLS-Abnahme für den eigenen Hyper-V-Referenzpfad

## Scope und Status

Die zusätzliche private Lane gilt für einen ausdrücklich ausgewählten eigenen
Windows-/Hyper-V-Run aus SQL 2025 RTM, tatsächlicher Engine-Build `17.0.1000.7`.
Die [native Referenzabnahme vom 2026-10-20](../Quality/TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md)
ist bestanden: neun Fälle, 18 Clientergebnisse, Ablauf, neuer Schlüssel,
striktes TLS nach Windows-Neustart und eigener Cleanup. Die Evidence ist aus
einem Setupdispatch und ausdrücklich gebundenen Fortsetzungen zusammengesetzt;
frühere Fehlversuche bleiben erhalten. Ein frischer durchgehender Gesamtlauf
des abschließenden Entrypoints wird damit nicht behauptet.
SQL 2019/2022, Linuxclients, der öffentliche Hyper-V-False-Erstellungspfad,
qualifizierter Hyper-V-Export und Toolbelt SC-2026-045 benötigen eigene Nachweise.
Der öffentliche Standard bleibt `Encrypt=True;TrustServerCertificate=True`.

## Dauerhafter einmaliger Setupversuch

Der [Writer](../../Private/AuthenticatedTlsSqlConsumerWriter.ps1) legt unter dem
frisch registrierten DataRoot `State/tls-sql-consumers` an. Ein globaler
kooperativer Mutex schützt die erstmalige Reservierung. Ein privater,
unveränderlicher `vm-<VmId>.json` bindet Operation, Run, Scope, VM, Root, Actor,
Quellen und Worker. Eine neue Operations-ID umgeht diese Reservierung nicht.
Sie bleibt auch nach Erfolg erhalten; es gibt keine automatische Freigabe
oder Recovery-Apply-Funktion.

Die private Operationsablage enthält vollständige geschlossene Journal-
Snapshots. `CreateNew`, exklusives Schreiben, `Flush(true)` und Readback
gehen dem jeweiligen Effekt voraus. Kein vorhandener Snapshot wird ersetzt.
Partielle Dateien bleiben erhalten und blockieren die Fortsetzung. Frische
Root-/Actorbindung und private CurrentUser-/SYSTEM-ACLs werden erneut geprüft.
Die Lane unterstützt die vorhandenen Windows-NTFS-/ReFS-Metadatenroots;
der separate NTFS-Rootanker wird dadurch nicht als Writer umgedeutet.

Das bestehende [Journal-Lesemodell](AUTHENTICATED_TLS_CONSUMER_GUARD.md)
bleibt konservativ: Nach Dispatch ist es `RECOVERY_REQUIRED`, mit
`ConsumerEnd=NOT_PROVEN` und ohne Retry-/Stop-/Cleanupfreigabe. Separate lokale
Setup-, Neustart- und Endbelege sind keine Signatur oder allgemeine Autorität.

## Tatsächliche Prozessgrenze

Der [feste Setup-only-Pfad](../../Private/AuthenticatedTlsHyperVSqlConsumer.ps1)
verwendet ausdrücklich VM-ID-Direct und `NoRetry`. Er reserviert den Dispatch
vor DVD-Anlage, Secretpersistenz und Setup. ISO-Hash, eigener Run, bestehendes
hostOnly-Netz, `VerifyOnly/Denied` und SQL-Prepared-RTM-Artefakt werden geprüft.
Der bisherige öffentliche CompleteImage-Ablauf wird nicht außen eingehüllt
und nicht automatisch umgestellt.

Ein eigener Gastintent wird vor genau einem Setupstart dauerhaft geschrieben.
Nach höchstens 90 Minuten bedeutet ein Timeout Erhalt und Recovery; kein
Parentkill, Job-Kill-on-close, Stop oder Neustart folgt daraus. Ein normaler
Exit `0/3010` reicht ebenfalls noch nicht: Ein frisches terminales
CompleteImage-Summary, keine sichtbaren Setup-/MSI-Prozesse, gestoppter
Windows Installer und ein nicht abandoned freier MSI-Mutex werden verlangt.
Der Ruhezustand muss zehn Sekunden bestehen.

Erst danach folgen dauerhafter Host-Neustartintent und genau ein
`Win32Shutdown(2)` ohne Force. Eine verlorene Antwort erlaubt ausschließlich
lesende Beobachtung. Derselbe VM-ID-Direct-Pfad muss einen streng jüngeren
Gastboot nachweisen. Nach mindestens 60 Sekunden Bootzeit werden erneut
Installer, Summaryhash, ausstehende Installer-/Neustart-/Rename- und
RunOnce-Einträge geprüft. Der Epochenwechsel belegt das Ende der alten
Gastprozesse; der gesonderte Setupabschluss und die Nachprüfung belegen den
beobachteten Installationszustand. Fehlende oder unbekannte Belege bleiben
Recovery. Ein Job allein würde servicegestartete Installer nicht einschließen.

Danach richtet ein fester begrenzter Gastblock ausschließlich die vorhandene
Defaultinstanz auf TCP 1433 und eine eigene Firewallregel für den gebundenen
Host ein. Er repariert weder Hostnetz noch WMI und prüft tatsächlichen Build
und alle vier online befindlichen Systemdatenbanken.

Die Grenze gilt für kooperierende eigene Labprozesse unter dem Runtime-Smoke-
Mutex. Gehaltene Quelllesehandles sind keine atomare VM-Reservierung oder
Abwehr gegen beliebige Codeausführung desselben Actors beziehungsweise eines
Host-/Gastadministrators. Eine beschädigte oder unlesbare Bindung blockiert.

Microsoft-Primärquellen:
[Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
[MSI-Mutex](https://learn.microsoft.com/en-us/windows/win32/msi/-msiexecute-mutex),
[asynchrone MSI-Aktionen](https://learn.microsoft.com/en-us/windows/win32/msi/custom-action-return-processing-options),
[Shutdown](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown).

## TLS-Proben und Cleanup

Der [Leafhelper](../../Private/AuthenticatedTlsHyperVLeaf.ps1) verwendet den
erhaltenen nicht exportierbaren Machine-CSP-/RSA3072-/SChannel12-/KeySpec1-
Schlüssel. Öffentlicher Modulus, Maschinen-CN, certreq-Binärhash und SAN werden
gebunden. CSR-Erzeugung verwendet `SMIME=FALSE`; Originalkeyanlage wird nicht
wiederholt. Die erneuerte Identität erhält genau einen neuen nicht exportierbaren
Gastkey. Kein privater SQL-Schlüssel verlässt den Gast.

Die bestehende ausdrücklich gewählte CA stellt öffentliche Leafs aus. Der
untrusted Gegenfall verwendet ausschließlich eine kurzlebige CA im Hostspeicher,
die in keinen Truststore importiert wird. Gastzertifikate werden an den
vorhandenen CSP-Key gebunden; die tatsächliche SQL-Dienstidentität erhält
Leserecht auf genau dessen Keydatei. Registrybindung, Dienststart und aktuelle
SQL-Lademeldung werden geprüft. Sie ersetzen keinen zusätzlichen Mitschnitt
des Wire-Zertifikats; dieser bleibt `NOT_OBSERVED`.

Der [Supervisor/Worker](../../Tests/Integration/Invoke-AuthenticatedTlsHyperVAcceptance.ps1)
bindet private Konfiguration, Actor, unveränderte Quellen, lokale Gates,
vorhandene CA-/Trust-/Clientreferenzen, VM, Disk und Adapter. Sein Gesamtbudget
beträgt 180 Minuten, mit einem Setupversuch. Unbekanntes Workerende führt zu
einem Cancelrecord, nicht zum Kill eines unbekannt aktiven Verbrauchers.

Tatsächlich geprüft wurden beide Windows-Clientstacks, jeweils mit
SQL-Abfrage und `encrypt_option=TRUE`: gültige Kette, untrusted CA mit getrenntem
True-Kontrollfall, falscher SAN, tatsächlich abgelaufenes zuvor gültiges Leaf
und Erneuerung mit neuem Key einschließlich eines weiteren geordneten
Gastneustarts mit erneuter strikter Prüfung. Dieser TLS-Persistenzfall ist
vom einmaligen Setup-Neustart getrennt. Strikte Proben verwenden False beziehungsweise
sqlcmd `-N` ohne `-C`, ohne Hostname-/Resolveroverride. Positive sqlcmd-Proben
beobachten und hashen den tatsächlich geladenen ODBC-Treiber.

Jede neue .NET-Probe verwendet einen eigenen NoProfile-Prozess und bindet die
tatsächlich geladene SqlClient-Assembly an MVID und Diskhash. Das Passwort
gelangt ausschließlich über begrenztes stdin in diesen lesenden Prozess;
Timeouts dürfen nur diesen eigenen Client beenden. Ein frischer Prozess ist
kein zusätzlicher Wire-Handshakebeleg. Vor dem echten Ablauf werden positive
Clientergebnisse und Leafdigest separat dauerhaft gespeichert. Der begrenzte
diagnostische Fall `short-isolated` verwendet denselben erhaltenen CSR/Key,
einen zusätzlichen eigenen Leaf und einen neuen Installationsintent. Er
wiederholt weder Setup noch CSR-Erzeugung oder einen alten Installationsintent.

Cleanup validiert alle eigenen Zertifikatsdigests, stellt die ursprüngliche
SQL-Zertifikatsbindung und Key-ACL wieder her, entfernt ausschließlich eigene
Zertifikate/Requestrecords, den eigenen neuen Renewalkey, Firewallregel und
DVD. Die bereits vorhandene VM, ihre Disks und der ursprüngliche CSP-Key bleiben
zweckgebunden gestoppt erhalten. Journale und öffentliche Requestdateien bleiben
als private Nachweise erhalten. Bei unbekanntem Verbraucherende erfolgt weder
Stop noch Removal. Der bestehende Hosttrust wird nicht verändert.
Der normale Lauf entfernt fünf eigene Zertifikate; die konkret gebundene
Fortsetzung entfernte sechs. Der erwartete Count sowie eindeutige Thumbprints
und DER-Digests werden vor Cleanup validiert und im Ergebnis ausgewiesen.
