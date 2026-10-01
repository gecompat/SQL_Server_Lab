# Lesende Prüfung eines registrierten CMS

Der optionale Fachpfad liest genau den bereits registrierten verwalteten CMS.
CLI und Browser verwenden `Invoke-SqlServerLabWorkflowAction` mit
`GetCmsInspectionState` und anschließend ausdrücklich `InspectCms`.
Der erste Aufruf liest ausschließlich vorhandene Registrierung und Run-Dateien.
Er startet keine Runtime, liest kein Secret und öffnet keine SQL-Verbindung.
Eine abgebrochene Auswahl führt keine Prüfung aus.

Die Registrierung muss `ConnectionCenterCms/1.0` oder `/1.1` sein. Run-ID,
primäre Instanz, Provider, Scope und kanonischer aktiver StateRoot sowie SHA-256 der vorhandenen CMS-, Run-,
Connection- und optionalen Layoutdateien bilden die serverseitige Auswahl.
Die HTTP-Schnittstelle `/api/cms-inspection` nimmt nur diesen Auswahlsschlüssel
an; Host, Port, Passwort, StateRoot und SQL sind keine Clientparameter.
Vor dem Secretlesen wird der laufende eigene Container anhand seiner exakten
ID, Run-/Scope-/Instanzlabels und der aktuellen lokalen Runtimeidentität geprüft.
Genau eine native Veröffentlichung von 1433/tcp auf einer Loopbackadresse muss
mit dem gespeicherten Port und Ziel übereinstimmen. Die SQL-Verbindung verwendet
nur das so bestätigte native Ziel. Fehlende, fremde, wildcard- oder mehrdeutige
Mappings bleiben unbekannt. Dateien oder Vorfahren mit Reparsepoints werden
abgelehnt. Diese frischen Vorher-/Nachherprüfungen sind keine atomare physische
Verzeichnis- oder Endpointbindung gegen konkurrierende Hoständerungen.

Docker und Podman sind getrennte Provider. Hyper-V wird vor Providerabfragen
als nicht unterstützt abgewiesen: bestehende reparierende Runtime-Statuspfade
werden nicht als lesende Abkürzung verwendet. Keine Einrichtung, Adoption,
Synchronisation, Exportdatei, Start-, Stop- oder UAC-Aktion gehört zur Prüfung.

Der eigene Worker verwendet das vorhandene run-lokale Secret ausschließlich
als SecureString/SqlCredential für `sa`, ohne Secretargumente oder Querydateien.
Die vorhandene lokale Secretablage bleibt unverändert; daraus folgt keine neue
plattformübergreifende Verschlüsselungszusage. SqlClient verbindet verschlüsselt
mit der vorhandenen lokalen Zertifikatvertrauensregel. Verbindungsbudget: drei
Sekunden, feste SELECT-Abfrage: fünf Sekunden, eigener Worker: zwanzig Sekunden,
Streamabschluss und bestätigter eigener Prozessabbruch: jeweils zwei Sekunden.
Nicht bestätigter Abschluss oder Kill bleibt `UNKNOWN`, niemals erfolgreich.

Die feste Abfrage liest SQL-Major und Anzahlen mit Lab-Metadaten markierter
Gruppen und Server in msdb. SQL 2019/2022/2025 müssen zur gespeicherten Version
passen; eine konfigurierte eigene Rootgruppe muss eindeutig vorhanden sein.
Knoten-, Server- und Gruppennamen werden nicht zurückgegeben, weil bestehende
CMS-Namen optional generierte Passwortaliase enthalten können. Counts bestätigen
keine vollständige Hierarchie, keine Synchronisationsfrische und keine
Verbindungen zu Mitgliedsservern. Die vorhandene SA-Anmeldung ist keine Abnahme
eines Least-Privilege-Rollenmodells oder einer SSMS-Anmeldung.

Der feste Vertrag `SqlServerLab.CmsInspection/1.0` hat zwölf Felder:
`ContractVersion`, `Status`, `Code`, `RunId`, `InstanceId`, `Provider`,
`SelectionKey`, `ObservedAt`, `SqlMajor`, `ManagedGroupCount`,
`ManagedServerCount`, `Notice`. `NOT_CONFIGURED` und `NOT_CHECKED` haben keinen
Beobachtungszeitpunkt und keine SQL-Zähler. Nur `OBSERVED` enthält gemessene
nichtnegative sichere Ganzzahlen; null und echte Null sind verschieden.
`UNKNOWN` enthält keine SQL-Werte und ausschließlich feste Fehlercodes.
Auswahl- und Runtimebindungen werden nach der SQL-Abfrage erneut geprüft;
Drift verwirft das Ergebnis. Der Elternprozess akzeptiert nur die genaue DTO-
Form, aktuelle UTC-Zeit und dieselbe Auswahl. Rohdiagnosen, Secrets, Endpunkte,
Dateipfade und Namen gelangen nicht in den öffentlichen Vertrag.

Im Browser verwirft Schließen die offene Antwort; es beendet keinen fremden
Prozess und behauptet keine bereits gestartete SQL-Abfrage abzubrechen.
Eine spätere oder anders gebundene Antwort verändert die geschlossene Ansicht
nicht. Wiederholung erfordert eine neue bewusste Auswahl. CLI-Fallback und
Cursoroberfläche benutzen denselben Core.

Die Offline-Fixture `Tests/Static/Fixtures/CmsInspectionChecks.ps1` wird durch
`Invoke-ConnectionCenterCmsChecks.ps1` entdeckt. Core, echte Public-/HTTP-/CLI-
Adapter, eigener Prozess und JavaScript-Handler werden mit synthetischen
Grenzen geprüft. Reale providergebundene CMS-/SQL-Abnahme und SSMS-/Mitglieds-
verbindungen bleiben getrennte erforderliche Nachweise; ein Docker-Core-Smoke
beweist nicht automatisch die optionale CMS-Funktion.
Die CLI-Prüfauswahl gilt nur für die aktive Registrierung; ein abweichender privater CMS-StateRoot erhält keine Inspectionfreigabe.
