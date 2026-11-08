# Öffentlicher Windows-TLS-Neuaufbau: Nachweis und offene Gesamtprobe

## Ergebnis und Bindung

Der öffentliche Windows-/Hyper-V-/SQL-2025-RTM-Neuaufbau ist erstmals
ununterbrochen nativ nachgewiesen. Der zusätzliche SQL-Consumer des
Abnahmekoordinators wurde dagegen nicht ausgeführt; dessen Gesamtstatus bleibt
`FAIL`. Ein separater frischer Windows-Cleanup-Audit bestand acht Prüfungen.
Dies ist kein Gesamt-PASS des Koordinators und kein Abschluss von TLS-001.

Geprüft wurden die unveränderten Produktquellen aus
[`6c6c6c3c`](https://github.com/gecompat/SQL_Server_Lab/tree/6c6c6c3c80f8eda1c8302a1775d4b3fb164c9238).
Ein eigenes Lab aus einem zulässigen vorbereiteten Image durchlief genau einen
öffentlichen `New-SqlServerLab`-Aufruf mit `Provider=hyperv`, `Version=2025`,
`TrustServerCertificate=False` und dem vorhandenen registrierten Windowskontext.
Das Vertragsprofil ist SQL 2025 RTM, Build `17.0.1000.7`.
Die Quellen waren vor Ausführung gebunden und während des Laufs gegen Änderungen
gesichert. Private Originale und der unveränderte ausgeführte Testadapter bleiben
außerhalb der Versionskontrolle.
Produkt-APIs, Schema und Installationsartefakte wurden nicht geändert.

## Tatsächlich ausgeführte Abschnitte

| Abschnitt | Ergebnis | Bedeutung |
|---|---|---|
| Öffentliche Neuerstellung | PASS | Offline-OOBE, reguläre Aktivierung und SQL-Vorbereitung ohne Fortsetzung desselben Runs; temporäre Aktivierungs-NIC bereinigt |
| Initiale Windows-TLS-Qualifikation | PASS | Echte strikte System.Data.SqlClient- und ODBC-sqlcmd-Verbindungen; öffentliche Rückgabe `QUALIFIED` |
| Öffentlicher signierter V2-Export | PASS | Erneute frische Qualifikation über beide strikten Stacks und signierter Export für genau diesen Run |
| Öffentlicher Snapshotreader | PASS | Dateilesen und anschließende Prüfung derselben `ExportBytes` |
| Zusätzliche SQL-Consumer-Anmeldung | NOT EXECUTED | Testadapterfehler vor Erzeugung beziehungsweise Öffnen der SQL-Verbindung |
| Öffentlicher eigener Remove-Weg | PASS | Worker bestätigt `REMOVED`; eigener temporärer Export entfernt |
| Worker / Supervisor als Gesamtfall | FAIL / FAIL | Ursprüngliche Ergebnisse bleiben erhalten; keine nachträgliche Aufwertung |
| Separater frischer Cleanup-Audit | PASS | Acht lesende Prüfungen in einem weiteren Windows-Prozess |

Die Neuerstellung verwendete weder eine vorhandene VM noch eine manuelle
Aktivierungs-/CompleteImage-Fortsetzung oder einen separat aufgerufenen privaten
TLS-Finalizer. Die vier strikten Clientresultate gehören zum initialen Aufbau
und Export dieses neuen eigenen Runs. Sie sind keine zusätzliche
SQL-2019/2022-Matrix und keine neue SSIS-Ausführung.

## Ausführungskontext und Vorlauf

Der bereits registrierte CA-/Clientkontext lag in einer virtualisierten
App-Paket-Dateisicht. Ein gewöhnlicher erhöhter Prozess derselben Identität
sah diese private CA-Ablage nicht; zusätzlich wich der beobachtete
SqlClient-Pfad ab. Die Vorprüfung lehnte diesen Kontext vor einer VM-Anlage ab.
Die Registrierung blieb unverändert. Gleiche Benutzeridentität, Profil und Host
allein bewiesen hier keine identische Dateisicht.

Der korrigierte Einstieg verwendete einen bereits erhöhten Prozess und den
vorhandenen registrierten Paketkontext über das dokumentierte
[`Invoke-CommandInDesktopPackage`](https://learn.microsoft.com/en-us/powershell/module/appx/invoke-commandindesktoppackage?view=windowsserver2025-ps)
mit `PreventBreakaway`. Die bestehenden Identitäts-, Client-, Authority- und
Quellprüfungen blieben erforderlich. Es wurden weder CA-Dateien kopiert noch
Trust, Konten, Gruppen, Pakete oder Sicherheitseinstellungen geändert.
Vom erfolgreichen Kontextstart bis zum eigenen Cleanup erfolgten keine
manuellen Gast-, SQL- oder TLS-Schritte.

Das ist eine geprüfte Ausführung in genau diesem registrierten Kontext, keine
allgemeine Zusage über beliebige paketierte oder nicht paketierte Prozesse.
Microsoft beschreibt die zugrunde liegende
[Datei- und Registryvirtualisierung](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)
und die begrenzten Garantien des Debugstarters. Der Starter ersetzt insbesondere
keine Prüfung der tatsächlichen Erhöhung und Authority.

## Adapterfehler, Gegenprobe und Cleanup

Der zusätzliche Consumer verwendete beim ConnectionStringBuilder
`ConnectTimeout` als PowerShell-Zuweisung. Diese wurde als nicht unterstütztes
Schlüsselwort behandelt. Der Fehler trat vor der SQL-Anmeldung auf. Die
vorangegangenen öffentlichen Aufbau-, Export- und Readeraufrufe hatten bereits
erfolgreich geendet.

Die Korrektur des privaten Testadapters verwendet ausdrücklich den Indexer mit `Connect Timeout`,
`Pooling` und `ConnectRetryCount`. Elf Offlineassertions reproduzieren den
ursprünglichen Fehler und prüfen die korrigierte Vorbereitung einschließlich
unverändertem Ziel, Datenbank, synthetischer Anmeldung, erforderlicher
Verschlüsselung, `TrustServerCertificate=False`, Timeout und ausgeschaltetem
Pooling/Retry. Sie öffnen keine SQL-Verbindung. Der korrigierte vollständige
Adapter ist **nativ nicht ausgeführt**. Er ersetzt weder das ausgeführte Original
noch dessen Fehlstatus.

Der Worker bestätigte das Ende seiner eigenen Consumer und entfernte das Lab
über den öffentlichen Remove-Weg. Der Supervisor lehnte den nicht erfolgreichen
Gesamtfall ab, bevor sein regulärer Abschlussaudit erreicht wurde. Sein
konservativer Recovery-Status bleibt unverändert. Der danach separat ausgeführte
frische Windows-Audit prüfte innerhalb derselben Frist:

- Abwesenheit der exakt gebundenen eigenen VM;
- eigenen Runstatus `REMOVED` mit gleicher Scopebindung;
- Abwesenheit des eigenen temporären Exports;
- unveränderten fremden VM-Bestand einschließlich erfasster Zustände;
- unveränderte Switch-Baseline;
- unveränderte CurrentUser-Root-Zertifikatbaseline;
- unveränderte erfasste Dateien anderer Verbraucher und Root-/Storage-Metadaten;
- unveränderte gebundene Quellen.

Der Audit führte keine SQL- oder Gastoperation aus. Er bestätigt Cleanup und
Baseline, nicht den fehlenden SQL-Consumer oder einen Gesamt-PASS. Eine separate
unabhängige Beobachtung sämtlicher Diskpfade wird nicht behauptet.

## Verbleibender Umfang

Die frühere Aussage „öffentlicher ununterbrochener Neuaufbau nicht ausgeführt“
ist für den oben gebundenen Erstellungsabschnitt geschlossen. Zum Stand dieses
Nachweises war die korrigierte frische Gesamtprobe mit zusätzlicher
SQL-Consumer-Anmeldung noch offen. Sie wurde später im
[gebundenen Native-Runner-Nachweis](BOUNDED_WINDOWS_TLS_RUNNER_ACCEPTANCE_2026-11-04.md)
bestanden. Der ursprüngliche Adapterfehler und sein Worker-/Supervisor-FAIL
bleiben unverändert erhalten; die auf ein eigenes Lab begrenzte Welle wird
nicht rückwirkend aufgewertet.

Der [komponierte Nachweis vom 2026-10-31](TLS_WINDOWS_OPERATIONAL_SSIS_ACCEPTANCE_2026-10-31.md)
bleibt unverändert an seinen damaligen Run und Consumer gebunden. Er wird weder
als neue Ausführung noch als Ersatz für den hier fehlenden Gesamtfall dargestellt.
Weitere Windowsprofile, Zertifikatserneuerung, Neustartwiederbindung,
Wire-Zertifikatfingerprint und die vollständige TLS-001-Matrix bleiben getrennt.
