# Öffentlicher isolierter Linux-Clientkontext

Status: **Docker und Podman mit SQL Server 2025 CU9 nativ geprüft**.

Der [öffentliche Docker-Fall](../Quality/LOCAL_VALIDATION_STRATEGY.md#2026-11-17-ordinal-150)
und der [öffentliche Podman-Fall](../Quality/LOCAL_VALIDATION_STRATEGY.md#2026-11-23-öffentlicher-podman-preflight)
belegen jeweils beide Clientstacks.

Dieser Schnitt konkretisiert den öffentlichen Linuxblock der
[TLS-001-Abschlussübersicht](../Project_Planning/TLS_001_COMPLETION_CHECKLIST.md).
Windows bleibt Controller, Registry- und Signierautorität; die SQL-Clients
laufen in einem ausdrücklich eigenen isolierten Linuxcontainer. Das ist
kein Port der privaten CA-Schlüssel oder DPAPI auf einen Linuxhost.

## Identität und Trust

Ein eigener LinuxClientRef bindet Controller und eigenen Run, Provider,
ursprüngliche Runtime-Inkarnation, SQL- und Clientcontainer, Images,
Clientprogramme, UID sowie den tatsächlich verwendeten isolierten Truststore.
Die Registrierung muss vor ihren Effekten journalisiert sein. Eine erneute
Beobachtung prüft dieselben Ressourcen und Bytes; gespeicherte Fakten allein
erteilen keine Freigabe. Vorbestehende CA, Schlüssel und Trust bleiben erhalten.
Nur das öffentliche CA-Zertifikat gelangt in den eigenen Linux-Truststore.
Cleanup und Fehlerbehandlung gehören zu derselben besitzgebundenen Transaktion.

Der neue Kontext bindet den vollständigen CA-Dateihash zusätzlich zum
DER-Fingerprint. Ein privates Home und eine leere isolierte CA-Verzeichnisquelle
gehören zum Trustvertrag; vorhandene Benutzerstores dürfen nicht unbemerkt
hinzukommen. Metadaten dazu sind erneut nativ zu beobachten und pro Login an
die tatsächlich verwendete Prozessumgebung zu binden.

Der Linuxendpoint und seine Zertifikatsidentität sind gesonderte signierte
Fakten. Der bisherige Windowsendpoint (127.0.0.1 mit Hostport) und dessen IP-SAN
dürfen nicht in localhost:1433 umgeschrieben werden. Ein Linuxcontainer im
eigenen SQL-Netznamespace benötigt eine ausdrücklich gewählte und geprüfte
Endpoint-/SAN-/Namespacebindung. Bestehende Windowsrecords behalten ihren
bisherigen Vertrag.

## Export und frische Prüfung vor dem Login

Die Exportbasis bleibt SqlServerLab.TestEnvironment/2.0. Die Qualifikation
für einen Linuxclient verlangt beide tatsächlich im gebundenen Kontext
ausgeführten Stacks. Sie verwendet weder die Windows-Clientdigests noch eine
frühere private Kryptoprobe als Ersatz.

Eine endliche Controllersitzung hält genau einen privaten V2-Bytesnapshot
und eine opaque Referenz. Der Linuxconsumer fordert vor jedem Login eine
frische öffentliche Controllerprüfung derselben Bytes an. Der Controller
prüft Registry, Run, Runtime, Client, Trust und den gewählten Endpoint neu.
Der Consumer darf keinen Modul-, Root- oder Codepfad aus dem Export beziehen.
Die Sitzung und ihr Transport gehören ausschließlich zum eigenen überwachten
Clientprozess; ein serialisiertes Sitzungsobjekt oder eine gespeicherte Antwort
begründet keine Autorität.

Der private Protokollkern begrenzt eine Sitzung auf höchstens fünf Minuten
innerhalb der ursprünglichen Qualifikationsfrist, 16 seriell geprüfte Requests,
2048 Requestbytes und einen einmaligen Request-Identifier. Fehlende, verspätete,
wiederholte oder widersprüchliche Antworten sperren die Sitzung. Eine Antwort
ist höchstens 15 Sekunden ab Abschluss der aktuellen Controllerprüfung gültig
und verlängert die Exportfrist nicht. Ihre Beobachtungszeit darf höchstens fünf
Sekunden vor diesem Abschluss liegen; der Peer akzeptiert deshalb höchstens
20 Sekunden zwischen Beobachtung und Ablaufzeit und verlangt, dass diese
gesamte Gültigkeit länger als der gemessene Austausch dauert. So ist die
Antwort bei Empfang noch nicht abgelaufen, ohne Controller- und Linuxuhr
gegeneinander zu vergleichen.
Der native Transport muss diese Antwort unmittelbar vor dem zugehörigen
Client-Open prüfen. Diese Zahlen sind Protokollgrenzen, keine gemessene
Laufzeit oder Transportgarantie.

UTC-Rücksprünge sperren die Sitzung; ein zusätzliches monotones Zeitbudget
verhindert eine Verlängerung durch eine stehende oder verlangsamte Wanduhr.
Der Controller verankert auch die unveränderliche Qualifikationsfrist beim
Sitzungsstart und berechnet ihr Restfenster aus UTC und monoton verstrichener
Zeit konservativ. Der synchrone Verifier-Austausch ist auf 15 Sekunden
begrenzt; das Controller-Antwortticket muss länger als der vollständige
gemessene Roundtrip gültig bleiben und darf höchstens 20 Sekunden umfassen.
Vor einer Antwort müssen mindestens 40 Sekunden Qualifikationsrestzeit
verbleiben. Der Peer zieht die gesamte gemessene Austauschzeit ab und verlangt
unmittelbar vor Open auf derselben weiterlaufenden monotonen Uhr noch 30
Sekunden. Bei einem 15-Sekunden-Roundtrip muss die Antwort daher mindestens 45
Sekunden ausweisen; kürzere Fenster werden abgewiesen. Das private Openfenster
ist nicht serialisierbar und hängt nicht von der Linux-Wanduhr oder deren
Abstand zur Controlleruhr ab.

## Explizite Bediengrenze

Eine neue False-Erstellung nimmt zusätzlich TlsClientPlatform=Linux und
TlsLinuxPowerShellPackage entgegen. Das vorhandene offizielle
PowerShell-7.6.6-linux-x64-Paket wird nach festem Umfang und SHA-256 geprüft;
es gibt keine Hostinstallation oder automatische Beschaffung. Die neue
geschlossene Labrecordform 0.4 bindet SqlProfileId, ClientPlatform und
LinuxClientRef. Alte Windowsrecords werden nicht konvertiert.

Der eigene Client nutzt das vorhandene SQL-2025-CU9-Stockimage als Werkzeugbasis.
Er besitzt einen privaten PID-Namespace, UID 10001, keine Capabilities,
NoNewPrivileges, schreibgeschützten Root und privates tmpfs. Seine Lebenszeit
ist auf 30 Minuten begrenzt. Ein gestoppter oder abgelaufener Client wird nicht
still ersetzt. SQL-Restart invalidiert die Epoche; Update-SqlServerLabTlsBinding
weist diese Form vor einer Rebindmutation ab. Eine spätere Erneuerungs- oder
Generationsfunktion benötigt einen getrennten Nachweis.

Test-SqlServerLabTlsQualification prüft in dieser ausdrücklichen Form beide
tatsächlichen Linuxstacks. Der V2-Export bindet DNS-/Namespaceendpoint und
Kindidentität. Sein Windowscontroller prüft globale Elternbindung, runlokalen
Kindrecord und tatsächliche Ressourcen erneut. Intent und Kindrecord bleiben
als CA-Nutzungsbelege erhalten; erst bestätigte Cliententfernung und kanonisches
REMOVED schließen diese Nutzung. Das ist keine CA-Retirementfreigabe.

Invoke-SqlServerLabLinuxPreflight erhält privat gelesene ExportBytes, RunId,
InstanceId, StateRoot und einen ausdrücklich vertrauenswürdigen ToolbeltRoot.
Alternativ liest Path die ausdrücklich gewählte private Exportdatei genau
einmal. Der direkte Windows-V2-Reader weist Linux-Namespaceexports ab;
Windowsconsumer erhalten dadurch keinen localhost-Endpunkt im falschen
Ausführungsort. Der öffentliche Controllerverifier ist nur innerhalb der
privat aktiven Sitzung mit derselben opaque Referenz, denselben Bytes und
dem aktuellen Stack erreichbar.
Er hält acht feste transitive Lab-/Toolbeltquelldateien gegen Änderung und
prüft deren Kopien. Die Vordergrundsitzung führt nur den dedizierten read-only
Preflight aus: System.Data.SqlClient und ODBC 18/sqlcmd prüfen SQL-Build und
encrypt_option. Feature-, Deployment- und Shelladapter erhalten keinen
pauschalen Linuxnachweis.
Der neue dedizierte Linuxhelper verändert den bereits qualifizierten
Windows-Helper und dessen kanonischen Runner nicht. Historische Rechte-,
Paket- und Sourcepins werden nicht auf neue Bytes umgeschrieben.

Die separate SqlServerLab.LinuxPeer-Komponente exportiert ausschließlich den
öffentlichen Bytesreader. Ohne private Liveinitialisierung erzeugt sie weder
Sitzung noch Controllerautorität. Credentials und Exportbytes werden über
stdin übertragen und stehen nicht in Kommandozeilen oder Gastdateien.

CLI-Ende allein schließt die Gast-Custody nicht. Nach dem Ende wird der eigene
private PID-Namespace geprüft. Bei einem Consumerfehler wird nur der
receiptgebundene Client kanonisch entfernt; unbestätigte Prozess-/IO-Enden
halten Custody und Recoverymarker. Remove-SqlServerLab bestätigt den
Client-Cleanup vor SQL-Cleanup. Elternrun, CA, Hosttrust und bestehende
Schlüssel werden durch einen Consumerfehler nicht übernommen.

Ein nicht erfolgreicher Bridge-Kindprozess liefert zusätzlich ausschließlich
seinen numerischen Exitcode, den HELLO-Status, die Zahl der Controllerprüfungen,
den RESULT-Status, den letzten erfolgreich verifizierten Clientstack (oder
`none`), eine feste stderr-Klasse und die Anzahl der stderr-Bytes. Der Stackwert
ist ein bestätigter Fortschrittsmeilenstein; er beweist nicht, welche interne
Operation danach scheiterte oder zeitlich hängen blieb. Rohes Gast-stderr wird
nie über die öffentliche Fehlergrenze ausgegeben. Diese Felder beschreiben den
erreichten Protokollfortschritt und eine geschlossene Fehlerklasse. Der
gebootstrapte Consumer sendet bei einem Fehler des Toolbelt-
Preflights ein privates, Base64-codiertes `FAILURE`-Frame mit genau Schema,
Status und Fehlercode. Der Controller nimmt es nur nach `HELLO` und mindestens
einer gebundenen Verifieranfrage an, validiert Feldformen und eine feste
Allowlist und verlangt einen Fehler-Exit. Roher Fehlertext und zusätzliche
Felder werden verworfen. Das separate versionierte Fehler-JSON des Linux-Probes
darf ebenfalls nur seinen fest erlaubten Fehlercode in die Fehlerklasse
übernehmen; `Facts` und übrige Ausgabefelder bleiben verworfen. Die Klasse
ersetzt weder die vollständige Gastdiagnose noch eine erneute Native-Abnahme.

Der Linux-Bytesreader erhält intern zusätzlich feste Fehlerklassen für
Verifierantwort, Exportdokument, Payload und Bindung. Diese Klassen enthalten
weder Exception-Text noch Pfade oder Exportdaten und passieren die Consumer-
Grenze nur über eine geschlossene Allowlist. Sie zeigen den fehlgeschlagenen
Prüfschritt, nicht die vollständige Ursache; unbekannte Fehler bleiben beim
generischen Ablehnungscode. Der Windows-Reader bleibt unverändert.

## Getrennte Abnahme

Der private Sitzungsprotokollkern allein registriert keinen Kontext, startet
keinen Prozess und führt keinen SQL-Login aus. Öffentliche API, native
Transportbindung, Trustjournal, V2-Reader und Toolbeltintegration sind gemeinsam
abzunehmen. Offlinefälle und die vorhandene private Linux-Kryptomatrix ersetzen
diese öffentliche Laufzeitabnahme nicht. Allgemeine Linuxhosts, Hyper-V und
andere Consumer bleiben getrennte Grenzen.
