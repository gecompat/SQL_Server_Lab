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

Ein separater test-only Browserharness
`Tests/Integration/Invoke-ConnectionCenterCmsInspectionBrowserAcceptance.ps1` liefert das exakte
Produktmarkup, den CMS-Block aus `Ui/app.js`, CSS und die tatsächliche
HTTP-Adapter-/Dispatchroute auf einem begrenzten eigenen Loopbacklistener.
Nur die WorkflowActions werden durch feste synthetische Antworten ersetzt;
Modulimport, State, Provider, Secret und SQL werden nicht ausgeführt. Zehn
gerenderte Fälle prüfen explizite Auswahl, nullable Werte gegenüber echter
Null, Major 15/16/17, Hyper-V-Sperre, falsche Bindung, unsichere Ganzzahl,
sanitisierten Fehler, Busy-/Wiederholungsgrenzen und Schließen vor später Antwort.
Der Operatorrecord ist eine UI-Beobachtung, keine Runtime- oder Cleanupautorität;
19 unabhängig gemessene HTTP-Aktionen und unveränderte Produktquelldigests müssen
passen. Listener und eigene Browseransicht werden anschließend geschlossen,
lokale Nachweise bleiben erhalten. Dieser gerenderte synthetische Nachweis
bestand am 2026-10-07 auf `56fae2de`: zehn Fälle, exakt 19 gemessene HTTP-Aktionen,
vier unveränderte Produktquelldigests und geschlossener eigener Listener/Browser-Tab.
Major 15/16/17, echte Null, nullable unbekannter Befund, Hyper-V-Sperre,
verworfenes Bindungs-/Zählerergebnis, sanitisierten Fehler und Busy-/Wiederholungs-
sowie Close/Late-Grenzen wurden sichtbar geprüft. Ganze UI-Seite und native
Browser-bis-SQL-Abnahme bleiben separat; dies ist kein SQL-/Providernachweis.

Der additive test-only `Invoke-ConnectionCenterCmsFullPageAcceptance.ps1`
liefert die tatsächliche vollständige Seite mit unveränderten index-/CSS-/
JavaScriptbytes. Die zehn Produkt-JavaScripts einschließlich Navigation und
CMS werden gemeinsam geladen; dreizehn Produktquellen inklusive HTTP-Quelle
werden gebunden. Nur vier feste synthetische Bootstrapreads und die tatsächliche
CMS-Adapter-/Dispatchroute mit synthetischen Workflowantworten sind freigegeben.
Jobpolling und Listener sind begrenzt; andere Endpunkte führen keinen Effekt aus.
Die Abnahme verlangt alle zwölf Assets, vollständigen Bootstrap ohne Skriptfehler,
Navigation zum CMS und genau zwei bewusste CMS-Aktionen. Der Operatorrecord
bleibt eine UI-Beobachtung ohne Runtime- oder Cleanupautorität. Kein Modul,
State, Provider, Secret oder SQL wird ausgeführt. Dieser additive Browsernachweis
bestand am 2026-10-07 auf `c6a1458d`: zwölf Assets, dreizehn unveränderte
Produktquelldigests und 53 gemessene Requests einschließlich 33 Job-/drei
Workflowreads sowie genau zwei CMS-Aktionen. Echte Navigation, Registrierung
ohne SQL-Verbindung, explizite Prüfung mit Major 17/drei Gruppen/echter Null
für Server und Schließen wurden ohne Skriptfehler sichtbar geprüft; eigener
Listener/Browser-Tab sind geschlossen. Der erste Lauf mit leerer Bytearray-
Antwort scheiterte; korrigiert, lokale Fehlerevidence erhalten. Native
Browser-bis-SQL-Abnahme und andere UI-Aktionen bleiben offen.

Die Offline-Fixture `Tests/Static/Fixtures/CmsInspectionChecks.ps1` wird durch
`Invoke-ConnectionCenterCmsChecks.ps1` entdeckt. Core, echte Public-/HTTP-/CLI-
Adapter, eigener Prozess und JavaScript-Handler werden mit synthetischen
Grenzen geprüft. Reale providergebundene CMS-/SQL-Abnahme und SSMS-/Mitglieds-
verbindungen bleiben getrennte erforderliche Nachweise; ein Docker-Core-Smoke
beweist nicht automatisch die optionale CMS-Funktion.
Die CLI-Prüfauswahl gilt nur für die aktive Registrierung; ein abweichender privater CMS-StateRoot erhält keine Inspectionfreigabe.

Der test-only Harness `Tests/Integration/Invoke-ConnectionCenterCmsInspectionAcceptance.ps1`
registriert ausschließlich seinen frisch angelegten eigenen SQL-Run als
CMS. Er verwendet einen externen `sql-lab-cms-inspection-<GUID-N>`-Parent mit
getrennten OwnedHost-Policies am Parent/State und prüft aktive Route/native
Engineidentität gegen den gespeicherten Custody-Pin. Vor der eigentlichen
Leseprüfung werden synthetische CMS-Metadaten separat arrangiert: zwei markierte
Gruppen/ein Server und unmarkierte Kontrollen. Kein Mitglied wird kontaktiert.
Die tatsächlichen WorkflowActions verwenden den echten geerbten Workerroot.
Stale Auswahl und fehlender markierter Root müssen UNKNOWN/null ergeben;
anschließend müssen zwei Workeraufrufe OBSERVED mit dem passend gebundenen
SQL-Major und 2/1 liefern. `-Version` wählt genau 2019/2022/2025 (Default 2025);
der SQL-Preflight verwirft eine abweichende gespeicherte Version vor Effekt und
Secretlesen, der DTO-Check einen abweichenden gemessenen Major 15/16/17. Datei- und
deterministisch sortierte Hashes sämtlicher Zeilen beider CMS-Tabellen bleiben
vor/nach den lesenden Fällen gleich. Dies ist keine atomare Endpointbindung.
Cleanup nutzt den öffentlichen Remove-Vertrag nur mit exakter eigener Custody,
anschließender same-pin Abwesenheit und hashgesicherten Terminalkopien.
Unreturned/Drift/Fehler behalten den gesamten Parent zur Recovery.
Die getrennte native Docker-/Podman-Abnahme bestand am 2026-10-07 auf
`56e8aabf`: stale Auswahlveto, fehlender Root UNKNOWN/null, zweimal echter
Worker OBSERVED/17/2/1, gleiche Rootdatei-/CMS-Tabellenhashes und bestätigtes
Own-Cleanup samt bytegesicherten Terminalrecords. Der bidirektionale
Schutzvergleich hatte je null Findings; die begrenzte Podman-Zeitplanbeobachtung
eines Windows-Systemtasks hat keine Callerzuordnung. Zwei frühere Harnessfehler
sind korrigiert; ihre eigenen Runtime-Ressourcen sind entfernt und Fehlerparents
bleiben zur Recovery erhalten. Historische Protection-Failures werden dadurch
nicht aufgehoben. UI, Sync, SSMS, Mitgliedszugriffe, Windows, weitere katalogisierte
Builds und Least-Privilege-Authentisierung bleiben getrennt.
Die additive Versionsauswahl bestand am 2026-10-07 auf `ef5a8fa9` in vier
getrennten frischen Abnahmen: Docker und Podman jeweils mit SQL Server 2019
und 2022. Beide Workeraufrufe lieferten pro Run den passenden Major 15
beziehungsweise 16 und 2/1; fehlender Root UNKNOWN/null, stale Auswahlveto,
unveränderte Datei-/CMS-Tabellenhashes und bestätigtes Own-Cleanup mit je zwei
hashgesicherten Terminalkopien bestanden ebenfalls. Alle vier bidirektionalen
Schutzvergleiche hatten null Findings; Podman/2022 beobachtete eine begrenzte
Windows-Systemtask-Zeitplanänderung ohne Callerzuordnung. Dies erweitert nur
den begrenzten Worker-/SQL-Lesenachweis auf diese Linux-Basisversionen.
