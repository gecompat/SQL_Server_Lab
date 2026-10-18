# Frische öffentliche SSIS-Neuanlage: OLEDB und SQL-LogProvider

## Ergebnis und geprüfter Stand

Die P1-Gesamtabnahme der frischen öffentlichen Neuanlage ist bestanden.
Geprüft wurde `origin/main` auf
`95601fdb0e6e959baaee8da64e09cefbb713c9a7`, einschließlich der
[Installerkorrektur aus PR #798](https://github.com/gecompat/SQL_Server_Lab/pull/798).
Die Abnahme erforderte keine weitere Produktkorrektur.

Ein neues eigenes Hyper-V-/Windows-Server-2025-Lab wurde über
`New-SqlServerLab -Manifest` mit `instances[].ssisCatalogFixture` angelegt.
Ein vorhandenes geprüftes `SQL_PREPARED_SEALED`-Image lieferte den frischen
Klon. Danach liefen SQL CompleteImage, Hostzugriff, der öffentliche additive
SSIS-Komponenteninstaller und die öffentliche Fixtureanlage. Es wurde keine
bestehende Analyze-Umgebung als Installationsziel verwendet.

Der neue Run verwendete SQL Server 2025 Enterprise Developer RTM
`17.0.1000.7`, 4096 MiB und zwei virtuelle Prozessoren. Windows-Aktivierung
war `NotRequested`, Egress `Denied`. Es gab keine zusätzliche CU-Installation,
IS-Nachinstallation oder manuelle Editions-/Lizenzänderung nach der
öffentlichen Provisionierung. Der Default blieb ausdrücklich
`Encrypt=True;TrustServerCertificate=True`.

## Tatsächlich ausgeführte Prüfungen

| Prüfung | Beobachtetes Ergebnis |
|---|---|
| Öffentlicher Komponenteninstaller | `INSTALLED_AND_RESTART_VERIFIED`, einschließlich Registrierungsprüfung und tatsächlich neuem Windows-Boot |
| Öffentliche Fixture | `READY_FOR_READ_ONLY_ANALYSIS`, Ausführungszustände Erfolg/Fehler/ungestartet `7/4/1` |
| Echter Basic-Paketlauf im Katalog | Status `7`, keine Fehlerereignisse |
| OLEDB mit `MSOLEDBSQL19` | Genau ein eigener SQL-Marker; tatsächlich `encrypt_option=TRUE`, Windows/NTLM |
| SQL-LogProvider | Selbst erzeugte `dbo.sysssislog`, zwölf Zeilen, darunter je einmal `PackageStart` und `PackageEnd` |
| Öffentlicher Skriptzugang | `Invoke-SqlServerLabScript -WindowsAuthentication` erfolgreich; tatsächliche SQL-Verbindung verschlüsselt, Windows/NTLM |
| CLI-Statusanzeige | Tatsächliche `Connection Settings`-Zeile mit beiden Werten `True` |
| Öffentliche Workflow-Projektion | Eigenes Ziel unter `HyperVLabs`, `ConnectionSettings.Encrypt=true` und `TrustServerCertificate=true` |
| Installationsnachkontrolle | Beide Registry-Sichten `Enterprise Developer Edition`; eigene Installationsaufgabe und alle fünf Operationsdateien abwesend |
| Dienste | SQL läuft; `MsDtsServer170` gestoppt/deaktiviert |
| Gezielter öffentlicher Fixture-Cleanup | `CATALOG_FOLDER_CLEANUP_SUCCEEDED`; Fixtureordner/-projekt abwesend, separater eigener Provider-Testordner weiterhin vorhanden |
| Vollständiger öffentlicher Run-Cleanup | `CLEANUP_SUCCEEDED`; eigene VM und VHD abwesend |

Der Provider-Test verwendete die hashgeprüften ursprünglichen Basic-Paketbytes
als Ausgangspunkt einer eigenen Kopie. Ausschließlich deren eigene Datenbank,
Katalogobjekte, Verbindung und SQL-Marker wurden für das isolierte Ziel
gebunden. Ein SQL-Task schrieb wirklich; der SQL-LogProvider verwendete
denselben OLEDB-Verbindungsmanager. Kein Forced-Success ersetzte diese Prüfung.

Der tatsächlich laufende Katalogprozess wurde während der eigenen aktiven
SQL-Anforderung über Ausführung, Prozess-ID, Startzeit und Prozessimage
gebunden und nach dem Modulsnapshot erneut geprüft. `ISServerExec.exe` sowie
die geladenen `DTS.dll`, `DtsConn.dll` und `DTSLog.dll` waren RTM. Reale Pfade,
Prozessidentitäten und Datei-Hashes bleiben ausschließlich lokal.

Die Workflow-Prüfung bestätigt die Datenprojektion für die GUI. Eine weitere
gerenderte GUI-Abnahme wurde in diesem Lauf nicht ausgeführt. Docker, Podman,
andere SQL-Versionen, weitere Consumerpakete und der Analyzervergleich sind
ebenfalls keine Aussage dieses Hyper-V-/Basic-Nachweises.

## Ablaufkorrektur, Schutz und Aufwand

Es gab zwei nacheinander angelegte eigene Test-Runs, höchstens eine eigene
VM gleichzeitig. Der erste öffentliche Aufbau bestand bereits Installation,
Neustart und Fixture `7/4/1`. Der Testcontroller erwartete danach irrtümlich
die interne statt der öffentlichen Fixtureform und entfernte den Run vor dem
Provider-Test. Dieser Lauf bleibt als Controllerfehler dokumentiert und zählt
nicht als Providerabnahme. Die korrigierte DTO-Prüfung wurde am erhaltenen
Receipt charakterisiert und unabhängig gegen den öffentlichen Vertrag
geprüft. Erst der folgende frische Lauf führte den einen echten Providerfall
vollständig aus. Unveränderte Paketfehlversuche wurden nicht wiederholt.

Beide eigenen Runs wurden öffentlich entfernt. Die geschützte Analyze-Quelle
blieb unverändert: Run-/Connection-Dateihashes und die vier vor/nachher
gelesenen Projektionen für Ausführungen, Ereignisse, Katalogeigenschaften und
Datenbanken waren gleich. Auch der Hash des Original-ISPAC blieb gleich.
Globale Historienretention wurde nicht verändert. Rohlogs, Receipts, Secrets
und reale Zielidentitäten bleiben außerhalb von Git.

Ein Implementierer und der bereits zuständige unabhängige Reviewer wurden
verwendet; der Native-Testcode blieb gegenüber dem vorher geprüften Stand
bytegleich. Neue Beurteilungen betrafen den öffentlichen Aufrufpfad und den
konkreten DTO-Fehler. Die abschließende Änderung besteht aus Dokumentation;
der Selektor bestimmt dafür statische Prüfungen ohne weitere Providerstarts.
Tatsächliche Modellkosten wurden nicht gemessen.

Dieser Nachweis schließt die frische öffentliche Basic-Provisionierung nach
dem [Registrierungsvergleich](SSIS_CATALOG_REGISTRATION_RECOVERY_2026-10-18.md).
Die historischen unbekannten Typen werden dadurch nicht rückwirkend erklärt;
die weitere Consumerabnahme kann mit dem funktionierenden Pfad fortgesetzt
werden. Der [Fixturevertrag](../Architecture/SSISDB_TEST_FIXTURE.md) bleibt
für API, Ownership und Cleanup maßgeblich.
