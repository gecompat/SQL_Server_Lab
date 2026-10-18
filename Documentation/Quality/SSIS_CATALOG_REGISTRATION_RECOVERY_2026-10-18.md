# SSIS-Katalogruntime: Installationserkennung und SQL-LogProvider

## Ergebnis und Grenze

Im eigenen isolierten Windows-/Hyper-V-Lab bestand das aus den ursprünglichen
Basic-Paketbytes abgeleitete Paket nach einer herstellerkonformen IS-only-
Nachinstallation unter SYSTEM drei vollständige Katalogtests. Eine eigene
Datenbank und eigene Katalogobjekte ersetzten die Consumerziele. Die erhaltene
Analyze-Quelle und das Original-ISPAC wurden nicht verändert.

Die historischen unbekannten Typen `OLEDB` und `Microsoft.LogProviderSQLServer`
wurden nicht reproduziert. Behoben wurde der aktuelle Fehler
`DTS_E_SSISSTANDALONENOTINSTALLED` (`-1073679321`): vorhandene Runtime-Dateien
waren ohne ausreichende IS-Feature-/Editionsregistrierung verfügbar. Eine
Standard-/Enterprise-Featuregrenze des Basic-Pakets wurde nicht beobachtet.

## Unterscheidende Diagnose

Die Engine lief zunächst als Enterprise Developer auf `17.0.1000.7`. Ein echter,
an die eigene aktive Katalogausführung gebundener Prozesssnapshot belegte
`ISServerExec.exe` und die tatsächlich geladenen DTS-/DtsConn-/DTSLog-Module.
Nach dem vorhandenen CU9 und einem geordneten Windows-Neustart meldete die
Engine `17.0.5005.3`; die geladenen drei Module waren ebenfalls CU9. Der
SQL-LogProvider scheiterte trotzdem mit demselben Installationsfehler. Der
RTM-Dateiversion des Prozessimages allein lässt sich deshalb keine Ursache
zuordnen.

Die ursprünglichen Setup-/MSI-Logs meldeten erfolgreiches IS-Setup und das
Schreiben der Enterprise-Developer-SKU. Im laufenden Gast fehlten dagegen
die IS-MSI-Produktregistrierung sowie `170\DTS\Setup` in beiden Registry-
Sichten. Der öffentliche Installer hatte unmittelbar nach Setup einen harten
VM-Neustart verwendet; Windows bestätigte ein unerwartetes Abschalten.
Ein alleiniger kausaler Nachweis für den Registrierungsverlust ist das nicht.

Eine weitere IS-only-Installation als abgekoppelter Administratorprozess
scheiterte bereits in `MsiEnumRelatedProducts` mit Windows-Fehler `1018`
(`ERROR_KEY_DELETED`). Windows meldete außerdem ein temporäres
Administratorprofil. Es liefen anschließend keine Installer mehr; der
Windows-Installer-Dienst war beendet. Derselbe unterstützte IS-Installationsweg
aus derselben hashgebundenen lokalen Enterprise-Developer-ISO bestand unter
einer eigenen einmaligen SYSTEM-Aufgabe mit Exitcode `0`. Manuelle Änderungen
von Lizenz- oder Editionsregistrierung erfolgten nicht.

Danach waren die IS-MSI regulär registriert und `Edition`/`EditionType` in
beiden Sichten `Enterprise Developer Edition`. Diese Werte und die
MSI-Registrierung blieben nach einem geordneten Windows-Neustart erhalten.
Der Vergleich belegt die wirksame Wiederherstellung, aber keine vollständige
Rekonstruktion des ursprünglichen Profil-/Registrierungsverlusts.

## Echte Verbindungstests

Jeder Test verlangte Status `7`, keine Fehlerereignisse, genau eine eigene
SQL-Markerzeile und vom SQL-LogProvider selbst erzeugte `sysssislog`-Ereignisse.
Die Tabelle war vorher nicht vorhanden. Connection Manager, SQL-LogProvider
und SQL-Task stammten aus dem hashgebundenen Paket; Forced Success war entfernt.
Pro Test wurden eine neue eigene Datenbank und eigene Katalogobjekte angelegt.

| Vergleich | Katalogstatus | SQL-Marker | Logzeilen | Fehler |
|---|---|---|---|---|
| CU9 nach OS-Neustart, vor IS-Wiederherstellung | `4` | 1 | 0 | zweimal `-1073679321` |
| Nach SYSTEM-IS-Installation, vor Neustart | `7` | 1 | 12 | keine |
| Nach geordnetem Windows-Neustart | `7` | 1 | 12 | keine |
| Separater Dienstkontext nach Wiederherstellung | `7` | 1 | 12 | keine |

Alle drei erfolgreichen Tests verwendeten `MSOLEDBSQL19` mit ausdrücklich
`Encrypt=True;TrustServerCertificate=True`; der SQL-Task beobachtete tatsächlich
`encrypt_option=TRUE` und Windows/NTLM. Die zwölf Logzeilen enthielten jeweils
`PackageStart` und `PackageEnd`. Der aktuelle Katalogprozess lud auch im
erfolgreichen Zustand das RTM-Prozessimage und die CU9-DTS-/DtsConn-/DTSLog-
Module. Pfade, Prozessidentitäten und Datei-Hashes bleiben ausschließlich lokal.

Der zusätzliche Legacydienst konnte nach der Wiederherstellung starten und
wurde anschließend wieder gestoppt/deaktiviert. Seine separate
`GetServerVersionEx`-API lieferte weiterhin `0`/`None` und keine Version. Das ist
keine beobachtete Edition des Katalogprozesses. Der normale Erfolgsfall benötigt
diesen Dienst nicht und bestand bei gestopptem/deaktiviertem Dienst.

## Produktkorrektur und Validierung

Der additive Komponenteninstaller verwendet eine einmalige SYSTEM-Aufgabe ohne
Trigger und geschützte ProgramFiles-Dateien. Er verhindert Setup-Replay bei
unklarem Ergebnis, begrenzt den Worker, prüft die Feature-/Editionsregistrierung
vor und nach einem geordneten Windows-Neustart und verlangt eine tatsächlich
neue Bootzeit. Dateipräsenz allein reicht nicht mehr für `ALREADY_INSTALLED`.
Der Komponentenpfad verwendet keinen harten VM-Reset mehr. Ein unbekanntes
Installerende behält Medium und Operationsdateien für Recovery; ein beendeter
Task wird nur bei unveränderter Bindung entfernt. Löschfehler bleiben sichtbar.

Die fokussierten statischen Checks prüfen unter anderem Registrierungswerte,
NoReplay-Dispatch, Bootnachweis und tatsächliche Cleanup-Vetos bei laufendem
Task, unbekanntem Consumerende und veränderter Task-/Operationsbindung. Auch
bei fehlender Aufgabe ist ein unabhängig gebundener terminaler Consumerstatus
Pflicht; Schedulerfehler werden nicht als Abwesenheit behandelt. Alle 132
fokussierten Assertions bestanden. Der
produktive Registrierungsreader wurde im eigenen Gast lesend mit `OBSERVED`
ausgeführt. Die drei obigen Pakettests gehören zum unabhängig geprüften
isolierten Diagnosecontroller; sie sind kein vollständig wiederholter frischer
öffentlicher Provisionierungslauf mit dem korrigierten Produktcode. Dieser
zusätzliche End-to-End-Nachweis war nicht Teil dieses Vergleichs. Die folgende
[frische öffentliche P1-Abnahme](SSIS_PUBLIC_FRESH_PROVISIONING_ACCEPTANCE_2026-10-18.md)
bestand inzwischen direkt auf SQL-2025-RTM einschließlich echter OLEDB-/
SQL-LogProvider-Verbindung, TLS-Anzeige und vollständigem Cleanup.

Der Ablauf ergänzt keine wiederkehrende Aufgabe: pro Installation gibt es
eine manuell gestartete Gastaufgabe ohne Trigger, einen begrenzt wartenden
Worker und einen geordneten Neustart. Ein nach dem Neustart gestoppter
Standard-SQL-Dienst wird höchstens einmal gestartet, ohne den Starttyp zu
ändern. Der vorhandene Selektor bestimmt die betroffenen statischen Suites;
zusätzliche unveränderte Providerläufe sind kein Ersatz für den gesonderten
öffentlichen SSIS-Nachweis. Rohlogs werden lokal ausgewertet. Der unabhängige
Reviewer wird für den stabilen Produktdiff und konkrete neue Findings
wiederverwendet; eine zusätzliche Reviewkette wird nicht eingeführt. Tatsächliche
Modellkosten wurden nicht gemessen.

Das eigene Lab wurde vollständig entfernt: VM und eigene VHD fehlten danach,
die gemeinsame Runtimesperre wurde freigegeben. Die Run-/Connection-Dateihashes
der geschützten Quelle sowie ihre vier vor/nachher gelesenen Projektionen
(Ausführungen/Ereignisse `10/11/12`, Katalogeigenschaften, Datenbanken) blieben
unverändert. Es wurde keine globale Historienretention verändert. Rohreceipts,
Originalartefakt und reale Identitäten bleiben außerhalb von Git.

## Herstellerquellen

- [SSIS installieren](https://learn.microsoft.com/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17)
- [SQL-Setup über die Befehlszeile](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17)
- [SSIS-Dienst und sein begrenzter Zweck](https://learn.microsoft.com/sql/integration-services/service/integration-services-service-ssis-service?view=sql-server-ver17)
- [SSIS-Logging](https://learn.microsoft.com/sql/integration-services/performance/integration-services-ssis-logging?view=sql-server-ver17)
- [Restart-VM führt einen harten Neustart aus](https://learn.microsoft.com/powershell/module/hyper-v/restart-vm?view=windowsserver2025-ps)
- [Windows-Fehler 1018](https://learn.microsoft.com/windows/win32/debug/system-error-codes--1000-1299-)
