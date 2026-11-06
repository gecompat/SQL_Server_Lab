# Aktuelle TLS-Prüfung eines eigenen Labs

`Test-SqlServerLabTlsQualification` prüft ausdrücklich einen bereits erstellten
eigenen operativen TLS-Run. Die Prüfung eignet sich vor der nächsten Verwendung
eines Labs, dessen gespeicherte Optionen `Encrypt=True` und
`TrustServerCertificate=False` anzeigen. Gespeicherte Flags und Runtime-READY
allein belegen keine aktuelle Zertifikatsprüfung.

## Voraussetzungen und Aufruf

Der [operative TLS-Vertrag](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) bleibt
maßgeblich für Erstellung, geschützte eigene Bindung, registrierten
Windows-Clientkontext und vorhandenen CurrentUser/Root-Trust. Unterstützt sind
Windows mit PowerShell 7.5+, Docker oder Podman und die geschlossenen Profile
SQL 2019 CU32, 2022 CU27 und 2025 CU9. Der zusätzliche
[Windows-/Hyper-V-Vertrag](AUTHENTICATED_TLS_WINDOWS_OPERATIONAL_LAB.md)
unterstützt einen eigenen Windows-SQL-2025-RTM-Run mit dem geschlossenen Profil
`WINDOWS-2025-RTM`. Seine VM-, Boot- und SQL-Dienstbindungen werden frisch
beobachtet; dafür werden keine Containerfelder erzeugt.
`RunId`, `InstanceId` und der private
`StateRoot` müssen genau zu diesem eigenen Lab gehören. Ein Standardlab ohne
diese Bindung wird dadurch nicht zum authentifizierten Lab.

Nach dem [Erstellen und Verbinden](../User/Getting_Started.md#7-verbindung-herstellen)
verwenden Sie die tatsächlich zurückgegebenen Werte:

```powershell
Test-SqlServerLabTlsQualification -RunId $lab.RunId `
    -InstanceId primary -StateRoot $lab.StateRoot
```

Der Befehl führt beide vorhandenen strikten Clientprüfungen erneut aus:
`System.Data.SqlClient` und das registrierte ODBC-`sqlcmd` mit `-N` ohne `-C`.
Beide öffnen eine echte Verbindung und lesen den erwarteten SQL-Build sowie
`encrypt_option=TRUE` der eigenen Sitzung. Container, ursprünglicher
Runtime-Pin, Image, Port, Start-Epoche, Leaf, Keyrechte, SQL-Konfiguration,
CA-/Client-/Registrybindung und tatsächlicher Trust werden über den vorhandenen
Qualifikationskern frisch geprüft. Der tatsächlich geladene ODBC-Treiber wird
beobachtet und seine Binärdatei vor und nach der Probe gebunden.

## Ergebnis und Bedeutung

Nur ein positiver, während dieses Aufrufs entstandener Nachweis beider Stacks
ergibt `SqlServerLab.TlsLiveQualificationResult/0.1` mit
`Status=QUALIFIED_AT_OBSERVATION`. Das geschlossene Ergebnis enthält:

| Feld | Bedeutung |
|---|---|
| `RunId`, `InstanceId`, `Provider` | Ausdrücklich ausgewähltes eigenes Ziel |
| `SqlVersion`, `Patch`, `SqlBuild` | Exakt geprüftes geschlossenes SQL-Profil |
| `Encrypt`, `TrustServerCertificate` | Echte Booleans `True` und `False` |
| `QualifiedAtUtc`, `ObservedAtUtc` | Zeitpunkt der strikten Qualifikation und abschließenden Ergebnisprüfung |
| `ExpiresAtUtc` | Unveränderte maximale Frist des vorhandenen Nachweises: höchstens 15 Minuten, zusätzlich durch das Leaf begrenzt |
| `ClientChecks`, `Evidence` | Beide bezeichneten echten Clientstacks |
| `WireCertificateFingerprint` | `NOT_OBSERVED`; kein zusätzlicher mitgeschnittener Handshake |

Credentials, Connection Strings, Endpoints, Hostpfade, Zertifikate,
Authority-/Clientreferenzen und deren Digests werden nicht ausgegeben. Die
interne Qualifikation wird nicht als öffentliches Ergebnis durchgereicht.

Das Ergebnis gilt für den beobachteten Zustand. Es reserviert keine Runtime,
verlängert keine Frist und wird nicht als positive Qualifikation gespeichert.
Neustart, Zertifikats-, Trust-, Client-, Registry- oder Zieländerungen
invalidieren den Nachweis unmittelbar, auch vor `ExpiresAtUtc`. Vor späterer
Verwendung den Befehl erneut ausdrücklich ausführen. Ein Ergebnis aus einem
früheren Aufruf wird nicht übernommen.

## Fehler und nächste Schritte

Ein nicht unterstützter Host meldet vor der ersten Zielprüfung
`TLS_LIVE_QUALIFICATION_WINDOWS_POWERSHELL_7_5_REQUIRED`. Andere Fehler liefern
`TLS_LIVE_QUALIFICATION_REJECTED` ohne native Rohdiagnose oder Secretwerte.
Dieser Fehler bedeutet fehlende Qualifikation; er behauptet keine bestimmte
Zertifikats-, Netzwerk- oder Loginursache.

Prüfen Sie zuerst den ausdrücklich gewählten eigenen Run und dessen
[operativen Voraussetzungen](AUTHENTICATED_TLS_OPERATIONAL_LAB.md).
Nach einem beabsichtigten eigenen Containerneustart ist die
[explizite Wiederbindung](AUTHENTICATED_TLS_CONTAINER_REBIND.md) erforderlich;
dieser Test repariert keine Start-Epoche. Es gibt keinen Fallback auf True,
einen anderen Endpoint, Provider, Clientkontext oder SQL-Patchstand.

Für einen exportierbaren Vertrag verwenden Sie anschließend den
[qualifizierten V2-Export](AUTHENTICATED_TLS_OPERATIONAL_LAB.md#expliziter-qualifizierter-export)
und den [öffentlichen Bytesnapshotreader](AUTHENTICATED_TLS_V2_READER.md).
Dieser Aufruf erzeugt keine Exportdateien, ändert keine gespeicherte Bindung
und verändert weder Zertifikate, Keys, Truststores noch SQL-Konfiguration.
Der einfache True/True-Erstellungsstandard bleibt ohne eigene CA-Pflicht.

## Oberfläche, Prüfung und verbleibender Scope

Die API ist über den vollständigen öffentlichen Befehlszugang erreichbar.
Unter **Verbindungen und CMS** ergänzt **TLS jetzt prüfen** eine ausdrückliche
Aktion für das einzelne Windows-/Docker-/Podman-Ziel mit gespeicherten
True/False-Werten. Auf anderen Hosts bleibt die Aktion deaktiviert; der
allgemeine UI-Mindeststand ändert sich dadurch nicht. Die
[Connection Settings](SQL_CONNECTION_SETTINGS.md) und deren konfigurationsbasierter
Prüfstatus bleiben getrennt von dieser aktuellen Beobachtung.

Der authentifizierte POST übermittelt ausschließlich Run, Instanz und Provider.
Der Server löst den StateRoot aus aktuellen registrierten Metadaten auf und
führt die öffentliche API in einem Hintergrundjob aus. Die Oberfläche bleibt
bedienbar; während eines nicht terminalen Jobs wird kein zweiter solcher Job
angenommen. Je Serversitzung werden höchstens 64 dieser Jobs angenommen.
Ein weiterer TLS-Job wird außerdem abgewiesen, sobald die beiden Tabellen
für Thread- und persistente UI-Jobs zusammen 256 Einträge enthalten. Diese
Annahmegrenze ändert keine übrige Jobroute. GET liest ausschließlich den angenommenen Job.
Es gibt keine automatische Wiederholung einer Probe. Unklarer Browserabbruch
behauptet kein Backendende; der Server behält die Jobzuständigkeit bis zum
terminalen Zustand beziehungsweise seinem bestehenden Shutdownpfad.

Die Anzeige nennt die erfolgreiche Beobachtung und ihren Zeitpunkt. Sie
speichert keine positive Qualifikation und verleiht keine Exportautorität.
Neue Workflowansicht, weiterer Button, Formularaktion, Hintergrundwechsel
oder Ablauf verwerfen die Anzeige. Eine verspätete Antwort aus einer früheren
Ansicht wird verworfen. Polling ist auf 300 reine Statuslesungen begrenzt.
Die automatische Workflowaktualisierung wartet während des laufenden
TLS-Jobs. Bereits unterwegs befindliche automatische Antworten rendern in
dieser Zeit keine neue Ansicht. Eine vor dem TLS-Klick gestartete Antwort
wird bei geänderter Ansichtsgeneration auch nach Jobende verworfen.
Danach neu gestartete automatische Aktualisierungen setzen wieder ein;
ausdrückliche Aktualisierung und andere Benutzeraktionen bleiben bedienbar
und verwerfen auch während der Prüfung verspätete Ergebnisse.
Ein unbestätigter Ausgang startet keine neue Probe. Die getrennte
[native Browserabnahme](../Quality/TLS_UI_LIVE_QUALIFICATION_ACCEPTANCE_2026-10-23.md)
bestand unter Windows für Docker und Podman mit SQL 2025 CU9: je acht Fälle
und vier strikte UI-Clientresultate, einschließlich Neustartablehnung,
frischem Ergebnis nach Wiederbindung, Refreshverfall und eigenem Cleanup.
Die [zusätzliche Profilabnahme](../Quality/TLS_UI_PROFILE_MATRIX_ACCEPTANCE_2026-10-23.md)
belegt Docker und Podman für SQL 2019 CU32 und 2022 CU27 mit getrennten
Quellständen: drei frühere positive Zellen und ein korrigierter
Podman-/SQL-2022-Nachlauf; dessen erster FAIL bleibt erhalten.
Beide Abnahmen verwenden den passenden serverseitigen Run-StateRoot.
Die zusätzliche [Ressourcenprofilabnahme](../Quality/TLS_UI_LIVE_RESOURCE_PROFILES_ACCEPTANCE_2026-10-25.md)
schließt diese separate Liveaktion für Standard (4 CPU, 4096 MiB) und
Performance (8 CPU, 8192 MiB), beide Provider und alle drei operativen
SQL-Profile. Tatsächliche Inspectwerte, beide strikten Clients, Ablehnung
nach Neustart, Wiederbindung, Refreshverfall und eigener Cleanup sind belegt.
Die [authentifizierte Browser-Erstellung](AUTHENTICATED_TLS_UI_CREATION.md)
mit privatem ResultRef bleibt ein eigener Vertrag und Nachweispfad.
Weitere Erstellungsoptionen, Clipboard sowie weitere Patch-/Clientkontexte
bleiben offen.

Die [fokussierte Suite](../../Tests/Static/Invoke-AuthenticatedTlsLiveQualificationChecks.ps1)
prüft sechs Profil-/Providerprojektionen, geschlossene Typen und Ausgabe,
veraltete, zukünftige und abgelaufene Nachweise, ETS-Getter, Capabilityguard und den
tatsächlichen öffentlichen Wrapper mit injiziertem Backend. Das sind keine
echten SQL-Verbindungen. Betroffene statische Regression und aktuelle
native Providerbelege werden in der
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) getrennt
geführt. Die sechs getrennten Windows-/Docker-/Podman-Zellen der drei
geschlossenen SQL-Profile bestanden den [gezielten API-Nachweis vom 2026-10-23](../Quality/TLS_LIVE_QUALIFICATION_API_ACCEPTANCE_2026-10-23.md)
einschließlich Neustartablehnung, frischer Beobachtung nach Wiederbindung und
eigenem Cleanup. Ungetestete Kombinationen sind kein PASS.

Öffentliche Linux-Registry-/Export-/Consumerpfade, Hyper-V-False-Lane,
operatives Renewal/Recovery und die übrige TLS-001-Matrix bleiben eigene
Scopes. Die früheren abgeschlossenen TLS-Nachweise werden nicht wiederholt
oder als aktueller Nachweis dieser API umgedeutet.
