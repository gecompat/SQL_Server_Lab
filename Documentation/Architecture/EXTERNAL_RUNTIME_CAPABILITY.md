# External-Languages-Entscheidung für einen Manifestentwurf

`Get-SqlServerLabExternalRuntimeCapability` ist der enge CORE-102-Teilvertrag
`SqlServerLab.ExternalRuntimeCapability/1.0`. Er bewertet eine zukünftige
Docker-/Podman-Linux-Instanz mit expliziter SQL-Katalogversion, Software-ID
(`sql-python`, `sql-r`, `sql-java`), Runtimeversion und Katalogvariante.
Diese Entwurfsangaben sind keine registrierte Run-/Scope- oder Besitzbindung.
C# und Hyper-V gehören nicht zu diesem Slice.

Der bestehende Software-Resolver bleibt die Katalogautorität. Sein Ergebnis
wird als `CatalogDecision` mit `DECLARED_SUPPORTED` oder `BLOCKED` und einem
festen Reason-Code projiziert. Unbekannte Anforderungen erhalten keine
zurückgespiegelte Identität oder Rohbegründung. Eine unterstützte Identität
stammt aus dem aufgelösten Katalog. Der Launchmodus und die erforderliche
cgroup-Version kommen aus dem bestehenden Containerrezept, einschließlich der
ausdrücklich ausgewählten SQL-2025-Variante `sql2025-shared-user-v2`.

Standardmäßig ist `CurrentReadiness` gleich `NOT_CHECKED`; kein Hostwerkzeug
wird aufgerufen. `-CheckProviderReadiness` veranlasst bei katalogunterstützter
Anforderung genau eine lesende `info --format`-Abfrage über den absoluten
HostTools-Aufrufpfad. Der native Formatstring projiziert nur OS, cgroup und
Rootless-/Security-Metadaten. Der vorhandene RAM-basierte Prozessreader begrenzt
die Ausführung auf 20 Sekunden und beide Streams zusammen auf 64 KiB; sein
separater Terminierungsversuch wartet höchstens fünf Sekunden. Synchroner
Prozessstart und Dispose sind keine Kernel-Wallclock-Garantie. Es gibt keinen
Retry, Bootstrap, Pull, vollständigen Client-Readiness-Aufruf, Storagezugriff
oder erneuten Modulimport durch diese API.

Die Antwort wird auf einen geschlossenen, typisierten Vertrag reduziert.
Fehlende Docker-`SecurityOptions` und unbekannte/nullwertige Rootless-, OS- oder
cgroup-Fakten werden abgelehnt. Podmans `v1`/`v2` wird ausdrücklich auf `1`/`2`
normalisiert. Stringwerte werden nicht in Boolwerte umgedeutet. Erst danach
erhält der bestehende Hostclassifier ausschließlich die internen Fakten,
sodass sein ungebundener nativer Fallback nicht erreicht wird.

`READY` bestätigt ausschließlich die Hostvoraussetzung des konkreten
Launchmodus. `SqlLanguageExecution` und `TargetAuthorization` bleiben
`NOT_CHECKED`, `ExecutionSupported` und `MutationAllowed` bleiben `false`,
`Actions` bleibt leer. Tool-/Runtimefehler, Timeout, Streamgrenze, unbestätigte
Terminierung und ungeeignete Hostkombinationen bleiben `BLOCKED`. Pfade,
Endpoints, volle Providerantworten, Security-Options, im Standardvertrag 1.0 PlanKeys, Secrets und
Rohfehler werden nicht zurückgegeben.

Der Standardvertrag 1.0 behält `HistoricalEvidence=NOT_RECORDED` und
`MappingStatus=NOT_DEFINED`. Das ausdrückliche Opt-in `-IncludeRecordedEvidence`
verwendet Version 1.1 und die unten beschriebene exakte historische Identität.
Ältere Referenzabnahmen werden weder umetikettiert noch zu aktueller Bereitschaft.
Es entsteht keine zweite Registry und kein persistiertes Assessment.

## Manifestdialog

Die vorhandene Softwareauswahl verwendet denselben Reducer. Sie zeigt auch
Katalogablehnungen mit festen Gründen an; blockierte Varianten werden nicht
übernommen. Eine unterstützte Katalogvariante darf als Entwurf gewählt werden,
während die Hostprüfung ausdrücklich `NOT_CHECKED` bleibt. Das ist keine
Ausführungsfreigabe: vorhandene Erstellungs-/Reconcile-Guards bleiben wirksam.
Die Aktion **Hostvoraussetzungen bewusst lesend prüfen** beobachtet den
ausgewählten Provider einmal für alle Varianten. Ein neu erkannter Block
entfernt bereits gewählte ungeeignete Varianten aus dem RAM-Entwurf.
Zurück, Abbruch, sechs bestehende Manifestfelder und die Warnung des
SQL-2025-Modus ohne Launchpad-Sandbox bleiben erhalten.

Die bestehende private `Get-LabExternalRuntimeSelectionOptions`-Rückgabe,
Desired-State-Assessment, Manifestfelder und Runtime-Executor bleiben
unverändert. Die API ist über den allgemeinen Konsolenbefehlszugang erreichbar.
Die vollständige CORE-102-Kombinationenmatrix bleibt offen.
Synthetische Transportprüfungen sind keine aktuelle
Docker-/Podman-/SQL-Sprachabnahme.

## Geführter Browserconsumer

Unter **Lab erstellen → Python / R / Java: Katalog und Hostvoraussetzungen**
werden Provider und SQL-Version ausdrücklich gewählt. Öffnen und Ändern lesen
keinen Host. **Katalogvarianten lesen** verwendet den bestehenden Reducer ohne
Hostbeobachtung; maximal 128 Varianten zeigen auch feste Ablehnungsgründe.
Blockierte Varianten können nicht gewählt werden. **Katalogentscheidung anzeigen**
ruft dieselbe Public-API ohne Probe auf. Erst **Hostvoraussetzungen bewusst lesend
prüfen** setzt `CheckProviderReadiness=true`. Linux ist das explizite Ziel;
C# und Hyper-V bleiben außerhalb dieses Dialogs.

`POST /api/external-runtime-capability` besitzt getrennte `ReadOptions`- und
`Evaluate`-Körper. Die Grenze verlangt den tatsächlichen IPv4-Loopback-Listener,
seinen Port und eine nichtleere identische Origin. Das ist keine neue
Authentifizierungs- oder Besitzautorität. JSON wird als striktes UTF-8 auf
8192 Bytes, 4096 Zeichen, Tiefe 2 und 16 Knoten begrenzt; doppelte oder anders
geschriebene Feldnamen, unbekannte Felder, Nullwerte und Typumdeutungen sperren.
Öffentliche Eingaben enthalten niemals Providerfakten. Antworten besitzen den
geschlossenen Browservertrag `SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0`
mit validierten Katalogidentitäten und dem unveränderten Public-Entscheid.

Der bestehende UI-Modulhost führt den Aufruf synchron aus, ohne Job oder
erneuten Import. 20 Sekunden Prozessausführung plus bis zu fünf Sekunden
Terminierungsversuch begrenzen weder den gesamten HTTP-Aufruf noch den Listener.
Eingaben bleiben im Browser-RAM. Abbruch, Escape und neue Auswahl verwerfen die
Anzeige; späte Erfolge und Fehler werden ignoriert. Eine bereits angeforderte
lesende Hostprüfung wird dadurch nicht als gestoppt behauptet. Es gibt keinen
Apply-, Speicher-, Start- oder Manifestübernahmepfad. Historisches Mapping und
SQL-Sprachabnahme bleiben unverändert offen; CORE-102 ist damit nicht vollständig.

Die getrennte gerenderte Katalogabnahme bestand am 2026-10-07 auf `c99869e2`:
zwölf unveränderte Produktassets und 36 gebundene Katalog-/Rezept-/Quellhashes,
102 Requests, vier Optionsreads und genau vier öffentliche Entscheidungen.
Docker Java/2019 und Python/2022 sowie Podman R/2022 und die explizite
Java/2025-shared-user-Variante wurden über die tatsächliche HTTP-Route geprüft.
Blockierte Optionen waren deaktiviert; Öffnen/Bearbeiten löste keine Aktion aus,
Wiederöffnen löschte Auswahl und Ausgabe. Keine Skriptfehler oder instrumentierten
verbotenen Effekte; eigener Listener und Tab geschlossen. Vier Bootstrapreads
waren synthetisch. Der isolierte Modulkontext verwendete tatsächliche Kataloge,
Provider-Metadaten und Rezept-/Lockdateien; Produktmodulimport, Hostprüfung,
historischer Lookup, State, Provider-Runtime, Secrets, Installation und SQL
blieben ungenutzt. Das bestätigt den Browser-Katalogpfad, keine Native-Abnahme.

## Exakte historische Identität (CORE-102/BASE)

Der bestehende Nachweisindex unterstützt getrennt Version 1.0 und die geschlossene
Version 1.1. Datenrecords werden durch diese Änderung nicht übernommen: die elf
bestehenden Records bleiben unverändert. 1.0 enthält keine nachträglich abgeleitete
Runtimeidentität. 1.1 verlangt `Identity` und `ObservedHostProfile` pro Record.
`LEGACY_UNSPECIFIED` mit nullwertigem Profil ist ausdrücklich unbekannt, kein
Wildcard. Die Familie `EXTERNAL_RUNTIME_CONTAINER/1.0` ist ausschließlich an
`Capability=external-runtime-capability`, Docker/Podman und SQL 2019/2022/2025
gebunden. Andere Fähigkeiten werden nicht über Slugähnlichkeit zugeordnet.

Der exakte Schlüssel umfasst Capability, Provider, nichtnullwertige SQL-Version,
Linux-Ziel, Ubuntu-Distribution, Architektur, Software-ID, Runtimeversion,
Varianten-ID, den ursprünglichen `plan.PlanKey`, `recipe.baseImage.sha256`,
Launchmodus und erforderliche cgroup-Version. `recipe.operatingSystem` ist die
Ubuntu-Distribution. Diese vorhandenen Resolver-/Rezeptwerte sind keine neuen
Ausführungsgrants. Aufgezeichnete Plattform und beobachtetes OS/cgroup/rootless
sind eigene Dimensionen; eine Windows-Testplattform beweist kein Windows-Gastziel.
Typisiertes null, Boolwerte und Strings bleiben verschieden.

Zellen gruppieren zusätzlich nach RecordedPlatform, Scope und vollständigem
ObservedHostProfile. Alle ursprünglichen Records bleiben ordinal geordnet erhalten.
`RecordCount` zählt Records, nicht Zellen. Für denselben vollständigen Schlüssel,
SourceRevision, Test und Date setzen widersprüchliche Result-/Cleanupwerte den
Boolwert `HistoryConflict`. Andere Daten oder Revisionen sind getrennte Historie;
es gibt keinen Latest-Winner. Native PASS verlangt im neuen Schema ein tatsächlich
aufgezeichnetes Linux/rootful-Profil, passende cgroup und Cleanup PASS. Ein
Lifecycle-Test ist kein SQL-Sprachnachweis. Die Quellenreferenz bleibt unüberprüft;
auch ein schema-validierter Native PASS wird als aktuelle Abnahme `UNKNOWN`
ausgegeben. STATIC_CONTRACT/PACKAGE haben native `NOT_APPLICABLE`.

Public `-IncludeRecordedEvidence` liefert 1.1 mit Status/Mapping/Reason:
NOT_RECORDED/NOT_DEFINED bei ungelöster Katalogidentität oder Legacyindex,
NOT_RECORDED/DEFINED bei keinem exakten Match, RECORDED_HISTORY_ONLY/DEFINED
bei vorhandener Historie. Fehlender, ungültiger oder nicht unterstützter Index
sowie überschrittene Ausgabegrenze ergeben UNAVAILABLE/UNAVAILABLE und leere Zellen.
CurrentReadiness wird davon nicht verändert. Browser, Manifestdialog und alte
Public-Aufrufe bleiben beim geschlossenen Standardvertrag 1.0.

Das Tool-Opt-in `-IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix`
liefert ausschließlich den geschlossenen Vertrag
`SqlServerLab.RepositoryCapabilityInventory/1.2`: ContractVersion, SourceScope,
EvidenceBoundary, Status, ReasonCode, ReferenceVerificationStatus, RecordCount,
Cells, MutationAllowed, CurrentExecutionStatus und CurrentReadinessStatus.
SourceScope ist RECORDED_IDENTITY_MATRIX_ONLY. Sources/Functions/Exports/Providers
werden in diesem Format bewusst nicht inventarisiert. Der frühe reine Dateipfad
lädt nur den Tool-eigenen Helper nach Reparseprüfung; die frei gewählte Datenwurzel
kann keinen Helper oder Modulimport liefern. Alte Tool-Formate 1.0/1.1 bleiben
unverändert und lehnen einen neuen 1.1-Index ab, statt dessen Identität abzuflachen.

Index und vollständige neue Opt-in-Antwort sind auf 262144 UTF-8-Bytes und maximal
128 Records begrenzt; die Antwort wird vollständig gemessen, nicht abgeschnitten.
Doppelte, case-gefaltete oder falsch geschriebene 1.1-JSON-Felder werden abgelehnt.
Validierung und Parsing verwenden dieselben gelesenen Bytes. Referenzen bleiben
NOT_VERIFIED, aktuelle Ausführung NOT_EXECUTED und Readiness NOT_CHECKED.
Ein späterer Producer muss seine ursprüngliche Resolver-/Rezeptidentität sowie
plattform-/scopespezifischen Test, Revision, Datum, Result und Cleanup aus dem
echten Originalnachweis liefern. Diese Schemaänderung erfindet solche Belege nicht,
lädt keine Referenzen und ersetzt weder producerbezogene Privacyreview noch die
fehlende Native-/SQL-Abnahme oder vollständige CORE-102-Matrix.
