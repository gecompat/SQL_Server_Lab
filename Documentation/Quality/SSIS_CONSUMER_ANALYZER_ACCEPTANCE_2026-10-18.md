# SSIS-Consumerpakete und Analyzervergleich im isolierten Lab

## Ergebnis und Bindung

Die vier ursprünglichen Consumerpakete und der anschließende Analyzervergleich
sind im eigenen, frisch angelegten Hyper-V-Lab abgenommen. Geprüft wurde
SQL_Server_Lab auf `54f7f2cd58b6a9be64f6c1b703267b65499df6a6` und der
unveränderte SQL_Server_Analyze-Quellstand
`a5efc761986dc77c313f981fa29af58d27c3be55`. Eine weitere Produktkorrektur war
nicht erforderlich. Der Default blieb `Encrypt=True;TrustServerCertificate=True`.

Die Neuanlage verwendete den öffentlichen Manifestweg mit SSIS-Fixture und
einem vorhandenen geprüften `SQL_PREPARED_SEALED`-Image. SQL Server 2025
Enterprise Developer RTM `17.0.1000.7`, 4096 MiB und zwei virtuelle Prozessoren
waren gebunden. Windows-Aktivierung war `NotRequested`, Egress `Denied`.
Der öffentliche Komponenteninstaller lieferte
`INSTALLED_AND_RESTART_VERIFIED`; die öffentliche Fixture war mit `7/4/1`
bereit. Es gab keine zusätzliche CU-Installation oder manuelle
Editions-/Lizenzänderung.

Das hashgeprüfte Original-ISPAC blieb unverändert. Eigene Paketkopien
behielten die ursprünglichen Paket-/Task-IDs und die Fehler-/Lookupsemantik.
Ihre Verbindung wurde auf die eigene Datenbank mit `MSOLEDBSQL19`, Windows-
Authentifizierung und beiden TLS-Werten `True` gebunden. Nur der Basic-Task
erhielt zusätzlich einen echten SQL-Marker und eine begrenzte Wartezeit zur
Beobachtung des laufenden Katalogprozesses. Kein Forced-Success wurde gesetzt.

## Tatsächliche Katalog- und Providerergebnisse

| Paket | Katalogstatus | SQL-LogProvider-Zeilen | Fachliche Prüfung |
|---|---|---|---|
| `ExampleBasicSuccess` | `7` | 12 | Eigener SQL-Marker genau einmal; tatsächliche Verschlüsselung `TRUE`, Windows/NTLM |
| `ExampleSqlFailure` | `4`, erwartet | 16 | Kontrollierter SQL-Fehler im eigenen Task; ursprünglicher Fehlertext erhalten |
| `ExampleLookupDuplicate` | `7` | 60 | Erwartete Full-Cache-Duplikatwarnung; drei Ausgabezeilen mit geprüften Schlüsseln und Werten |
| `ExampleLookupMiss` | `4`, erwartet | 61 | Erwarteter Lookup-Miss im eigenen Task; Eingaben und erlaubte partielle Ausgabe geprüft |

Alle vier Ausführungen liefen tatsächlich über den eigenen SSIS-Katalog mit
64-Bit-Runtime. Jede schrieb genau ein `PackageStart` und ein `PackageEnd` in
die selbst erzeugte `dbo.sysssislog`. Die beiden Erfolgsfälle enthielten keine
unerwarteten Fehlerereignisse. Der aktive Basic-Katalogprozess wurde über
Ausführung, aktive SQL-Anforderung, Prozess-ID, Startzeit und Image gebunden;
die Prozessbindung wurde nach dem Modulsnapshot erneut geprüft.

Die Lookupdiagnosen sind an den jeweiligen eigenen Task, Ereignistyp und
nativen Fehlercode gebunden: Duplikat `-2145349404`, Miss `-1071607778`.
Komponentenname, Lookupklasse und Taskzuordnung stammen aus den hashgebundenen
Originalbytes. Für den Textvergleich wird ausschließlich das exakt aus
Taskname und Ereignis abgeleitete Katalogpräfix entfernt. Der verbleibende
Meldungskörper muss ordinal mit dem SQL-LogProvider übereinstimmen.

## Vergleich der unveränderten Analyzer-Procedures

Sieben hashgebundene SQL-Quelldateien wurden ausschließlich in einer eigenen
Frameworkdatenbank installiert. Nur deren Datenbankheader wurde beim Laden
im Speicher auf das eigene Ziel gebunden. Die Analyze-Quelldateien wurden
nicht bearbeitet. Der Hostzugriff verwendete die öffentliche Generated-API;
beide TLS-Werte waren `True`, die tatsächliche SQL-Verbindung verschlüsselt.

| Procedure und Prüfumfang | Ergebnis |
|---|---|
| `monitor.USP_SsisLegacyLogAnalysis`, alle vier Fälle mit `MaxZeilen=0/1/2` | Zwölf Vergleiche bestanden; neun Standarddatensätze, 94 Felder in TABLE/JSON, N+1-Begrenzung |
| Unabhängige native Legacy-Referenz | Gespeicherte Timelinefelder, Ereigniszahlen, erster Fehler samt vollständigem Text, Diagnosetexte und gepaarte Zeiten geprüft |
| `monitor.USP_SsisCatalogExecutionAnalysis`, alle vier Fälle | Tatsächlicher Status und Meldungsanzahl sowie sechs Metadatenfelder je Katalogmeldung verglichen |
| `monitor.USP_SsisPackageAnalysis`, alle vier Originalpakete | Paketname, Anzahl und Eigenschaften von Root und Task sowie Name und Art des einen Verbindungsmanagers mit Original-XML verglichen |
| Legacy-Ausgaben `RAW`, `CONSOLE`, `NONE` am SQL-Fehlerfall | Neun/ein/kein Ergebnisgrid und jeweils neun JSON-Datenarrays; RAW vollständig feldweise, erster Fehlertext auch in CONSOLE identisch |

Die sechs Katalogfelder sind `EventMessageId`, `MessageType`, `MessageCode`,
`EventName`, `MessageSourceName` und `SubcomponentName`; Nullwerte werden
ebenfalls verglichen. Die 94-Feld-Prüfung belegt TABLE-/JSON-Parität. Sie
bedeutet keine unabhängige Neuberechnung aller 94 Felder. Die davon getrennte
native Referenz deckt die in der Tabelle benannten Inhalte ab. Der
Paketvergleich behauptet keine GUID-/LogProviderprojektion, die der Analyzer
nicht ausgibt, und keine vollständige Datenflussanalyse.

## Erhaltene Fehlschläge und begrenzte Fortsetzung

Es gab genau eine eigene VM und vier tatsächlich gestartete Consumerpakete.
Zwei vorangehende Testvorbereitungen führten kein Paket aus: Zuerst scheiterte
die Testeingabe an der Arraybehandlung von Windows PowerShell 5.1 noch vor
dem SQL-Zugriff. Danach scheiterte das Deployment am im Testcode fehlenden
SDK-Projektnamen. Die Fortsetzung prüfte die eigene Datenbanknonce, den
eigenen projektlosen Ordner und das Fehlen bisheriger Paketwirkungen. Sie
löschte oder setzte keine Daten zurück. Erst danach wurden die vier Pakete
einmal ausgeführt.

Der erste Analyzervergleich bestand Basic und SQL-Fehler und stoppte bei
einer zu engen Lookupprüfung im Testcode: Erwartet war ein anderer
Komponentenname und ein Text ohne Katalogpräfix. Die korrigierte Prüfung
wurde an den gespeicherten Meldungen mit positiven und negativen Fällen
charakterisiert und unabhängig geprüft. Eine an Fehlreceipt, Run/VM und
vorhandene eigene Frameworkdatenbank gebundene Fortsetzung verglich nur die
beiden offenen Fälle und die Ausgabeformen. Kein Paket wurde wiederholt,
keine Frameworkinstallation neu ausgeführt. Die ursprünglichen Fehlbelege
bleiben privat erhalten und zählen nicht als erfolgreiche Teilabnahmen.

## Cleanup, Schutz und Grenzen

Der öffentliche Run-Cleanup lieferte `CLEANUP_SUCCEEDED`; eigene VM und VHD
sind abwesend. Damit wurden auch eigene Consumerprojekte und Testdatenbanken
entfernt. Der Controller gab die Runtime-Sperre regulär frei; ihre sofortige
Verfügbarkeit wurde anschließend geprüft.

Die geschützte Analyze-Quelle blieb unverändert. Vor/nachher waren vier
SQL-Projektionen für die geschützten Ausführungen, Ereignisse,
Katalogeigenschaften und Datenbanken identisch. Run-/Connection-Dateihashes,
die sieben Analyze-Quelldateihashes, Analyze-HEAD und sauberer Checkout sowie
der Original-ISPAC-Hash waren unverändert. Globale Historienretention wurde
nicht geändert. Reale Identitäten, Rohlogs, Receipts und Zugangsdaten bleiben
außerhalb der Versionskontrolle.

Ein Implementierer und der bereits zuständige unabhängige Reviewer wurden
verwendet. Das endliche Fenster umfasste höchstens eine VM und sechs
Paketstarts; tatsächlich waren es eine VM und vier Starts. Die abschließende
Repositoryänderung dokumentiert den Nachweis. Der Pfadselektor bestimmt dafür
die betroffenen statischen Prüfungen; ein weiterer unveränderter Native-Lauf
ist daraus nicht erforderlich. Tatsächliche Modellkosten wurden nicht gemessen.

Dieser Nachweis ergänzt die
[frische öffentliche Basic-Abnahme](SSIS_PUBLIC_FRESH_PROVISIONING_ACCEPTANCE_2026-10-18.md)
um die übrigen ursprünglichen Consumerpakete und den beschriebenen
Standard-Analyzervergleich. Andere SQL-/IS-Builds, Docker, Podman,
Least-Privilege-Rollen, beliebige Consumerpakete, zusätzliche Analyzer-
Opt-in-Ausgaben und ein weiterer gerenderter GUI-Test sind hier nicht
abgenommen. Die historische Ursache der ursprünglich nicht auflösbaren
Komponententypen wird durch diesen erfolgreichen Lauf nicht rückwirkend
erklärt. Für Lifecycle, Ownership und Cleanup gilt weiterhin der
[Fixturevertrag](../Architecture/SSISDB_TEST_FIXTURE.md).
