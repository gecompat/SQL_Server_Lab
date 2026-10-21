# Isoliertes Lab mit authentifiziertem TLS

Der erste operative Pfad verbindet einen bereits vorhandenen, geschützten
Windows-CA-Kandidaten mit einem registrierten DataRoot, dem aktuellen Benutzer,
einem Signierkontext, einem Clientkontext und einem eigenen Trustscope.
Er importiert keinen Trust. Exaktes CA-DER muss bereits in CurrentUser/Root
liegen; DPAPI-Reopen mit Sign/Verify bestätigt den Besitz des CA-Schlüssels.
Die bestehende Registry-Payload `0.2` bindet Kandidat, CA-/verschlüsselte Keybytes,
Gültigkeit und Clientgeneration. Alte `0.1`-Payloads bleiben unverändert.
Trustscope-Referenzen sind eindeutig und auch nach abgebrochenen Intents reserviert.
Der Writer unterstützt lokale feste NTFS- und ReFS-Volumes; dieselben geschützten Journale, Sperren und nativen File.Replace-/Recoveryprüfungen gelten auf beiden. Die lokale ReFS-Writersuite bestand alle 45 Fälle einschließlich eigenem Cleanup. Der APIvertrag für den Dateiersatz ist bei [Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew) beschrieben.

`New-SqlServerLab -TrustServerCertificate:$false` verlangt Windows mit
PowerShell 7.5+, ausdrücklich Docker oder Podman, den lokal vorhandenen Katalogstand `2025-CU9`, `2022-CU27` oder `2019-CU32`,
`DataRoot`, `TlsControllerId`, `TlsLocationId` und `TlsCandidateId`.
Der Pfad erzeugt einen eigenen StateRoot unter
`State/authenticated-tls-labs/<AuditId>` und genau einen eigenen Run.
Autostart bleibt zwingend `off`; `on` wird abgelehnt. Der Pfad aktiviert keinen globalen Host-Autostartkoordinator.
Ohne Providerangabe bleibt Docker der Standard. Manifest, vorhandener StateRoot, Hostmounts und andere Provider werden vor
Provideraktionen abgelehnt. CA-Metadaten werden gemeinsam registriert;
bestehende SQL-Ziele werden nicht übernommen oder umkonfiguriert.

RSA-3072-Schlüssel und CSR entstehen als UID 10001 im eigenen Container.
Der private SQL-Schlüssel verlässt ihn nicht. Der Signierer stellt ein Leaf
für IP `127.0.0.1` mit einem Tag Gültigkeit aus. SQL erhält die exakten
Zertifikats-/Keypfade und Force Encryption; Stop/Start läuft über den öffentlichen
Lifecycle. Der lokale geschützte Bindungsrecord enthält Run, Scope, Instanz,
Container-/Image-ID, Port, Startzeit sowie Leaf-DER und Fingerprint.

Neue Bindungsrecords `SqlServerLab.AuthenticatedTlsLab/0.2` enthalten den
ausdrücklich gewählten Provider und die ursprüngliche Runtimebindung. Die geschlossene historische Form `0.1` bleibt
ausschließlich Docker zugeordnet; sie wird nicht als Podman interpretiert.
Die gespeicherte Runtime-Herkunft des Runs muss vor TLS-Mutationen und bei
Qualifikation zur aktuell beobachteten Runtime passen: Provider, Runtime-Scope,
Routing-Key und Engine-/Machine-Inkarnation. CLI-Aufrufe verwenden den gebundenen
Endpoint und unter Podman die zugehörige SSH-Identität. Geerbte Routingvariablen
werden entfernt; ein anderer Default führt nicht zu einem Providerfallback.

SQL 2022 CU27 verwendet die neue geschlossene Recordform `0.3` mit
`SqlProfileId=2022-CU27`. Sie übernimmt sämtliche Policy-, Custody-, Runtime-
und Digestbindungen aus `0.2`; ein fehlendes Profil erlaubt keinen Fallback.
Die historischen Formen `0.1`/`0.2` bleiben ausschließlich SQL 2025 CU9
zugeordnet. Der feste Katalogtag `2022-CU27-ubuntu-22.04` und Build
`16.0.4295.3` werden vor Erstellung und Qualifikation gegen den Katalog geprüft.
SQL 2019 CU32 verwendet dieselbe geschlossene Recordform `0.3` mit
`SqlProfileId=2019-CU32`, Katalogtag `2019-CU32-ubuntu-20.04` und exakt
Build `15.0.4430.1`. Ein Profilwechsel wird niemals aus einem Major oder Tag erraten.
Beide realen Clients müssen genau diesen Build und Verschlüsselung bestätigen.
Der signierte V2-Eintrag, seine Qualifikation und der versionsgebundene ENV-Key
müssen zum Recordprofil passen; auch neu gültig signierte Versionsumdeutungen
werden abgewiesen. Cleanup liest das geschlossene Profil ohne Katalog-, CA-
oder Trustabhängigkeit. SQL 2025 behält unverändert Build `17.0.5005.3`.

Der vorhandene [OwnedRunWindows-Kern](OWNED_HOST_CI_ISOLATION.md) erzeugt für
jedes neue `0.2`-Lab einen noch nicht existierenden privaten StateRoot und eine
dauerhafte Policy. Dieser Consumer ist ein eigenes TLS-Lab, keine Übernahme
eines bestehenden CI-Roots. Der TLS-Audit bindet die Policyinitialisierung;
die legitime Workflowoperation des Runs bleibt davon getrennt. Die frische
Runreferenz und Creation-/Custodyreceipts binden Policyhash, Scope und Ressourcen.
Öffentliche Erstellung, Stop, Start, Remove und Fehlerkompensation verwenden
dadurch dieselbe Route, auch in späteren Prozessen und bei geänderten
Routingvariablen. Fehlende oder beschädigte Policy erlaubt keinen Legacyfallback.
Der dedizierte TLS-Lab-Rootguard akzeptiert diese strengere Owner-only-Rootform;
CA-, Zertifikats-, Record- und Exportdateien behalten ihre bisherigen privaten
CurrentUser-/SYSTEM-ACLs. Der generische CA-ACLguard wird nicht erweitert.
Die policybasierte Scopeprojektion ist keine Enginegeneration: ursprünglicher
Routing-Key und Engine-/Machine-Inkarnation bleiben separat im geschützten
TLS-Record und werden am ursprünglichen Pin frisch gelesen. Podman benötigt
dabei keine neue Auswahl der Defaultconnection.

Der gepinnte Preflight löst den festen Katalogtag auf eine vollständige
SHA256-Image-ID auf. Vor Target-Intent und CSR muss das frisch beobachtete
Containerimage genau dazu passen. Neue `0.2`-Container starten unveränderlich
mit diesem Digest; native volle IDs mit oder ohne `sha256:` werden kanonisch
verglichen, Tags und Kurz-IDs abgelehnt. Historische `0.1`-Docker-Records behalten
ihren exakten Launch-Tagvertrag. Beide Provider geben den StateRoot ausdrücklich
an ihren Operation-Wrapper weiter, damit Arrange, Lifecycle, Compensation und
Diagnoselog unter derselben Policy bleiben.

Vor Qualifikation werden Eigentumslabels, aktueller Container, Image, Port,
Startzeit, Zertifikatsdatei, Keyrechte `600:10001`, SQL-Konfiguration und die
Lademeldung des aktuellen SQL-Prozesses frisch geprüft. Zwei echte Verbindungen
verwenden `Encrypt=True;TrustServerCertificate=False`: System.Data.SqlClient
und ODBC sqlcmd `-N` ohne `-C`. Beide lesen Build und `encrypt_option=TRUE`.
Der tatsächlich im sqlcmd-Prozess geladene ODBC-Treiber wird beobachtet und
seine Datei vor/nach der Probe gehasht. Danach werden CA-/Trust-/Client-/
Registry-/Serverbindungen erneut gelesen. Erst dann wird der gespeicherte
Connection String auf False gesetzt; die gemeinsame CLI-/GUI-Projektion zeigt
beide expliziten Flags. Für den isolierten StateRoot wird in einem eigenen CLI-/UI-Prozess die bestehende Prozessvariable `SQL_SERVER_LAB_STATE` auf den zurückgegebenen StateRoot gesetzt; keine persistente Umschaltung. Diese Anzeige ist selbst kein frischer Nachweis.

Der Nachweis benennt `WireCertificateFingerprint=NOT_OBSERVED`: die Bindung
belegt Datei, Konfiguration, SQL-Lademeldung und echte normale Clientvalidierung,
keinen zusätzlich mitgeschnittenen TLS-Handshake. Ein böswilliger Hostadministrator
oder derselbe Benutzer mit beliebiger Codeausführung liegt außerhalb dieses
lokalen Lab-Vertrags. Neustart, Port-/Client-/Trust-/Registrydrift oder Ablauf
sperren den Export. Die [explizite Container-Wiederbindung](AUTHENTICATED_TLS_CONTAINER_REBIND.md)
qualifiziert nach einem Neustart desselben Containers nur dessen neue Start-Epoche.
Automatische Reparatur und Renewal fehlen weiterhin.

## Expliziter qualifizierter Export

`Export-SqlServerLabTestEnvironment -TrustServerCertificate:$false` verlangt
den exakten eigenen `RunId`, `InstanceId`, `StateRoot` und ein neues
`OutputDirectory`. Er führt die beiden echten Verbindungen erneut aus.
Er schreibt separat `SqlServerLab.TestEnvironment/2.0`, eigenes Schema,
JSON, ENV, Markdown und Prompt. V1 und seine bestehende True/True-Gruppe
bleiben erhalten; Discoveryvariablen werden nicht geändert.

V2 verlangt echte Booleans true/false und einen RSA-3072-/SHA-256-/PKCS1-
signierten Payload mit Hash des vollständigen Eintrags und Qualifikation.
Der CA-Schlüssel signiert diesen privaten Exportnachweis; CA-DER ist beigefügt
und muss gegen die frisch aufgelöste Authority und den tatsächlichen Truststore
geprüft werden. Ein mitgeliefertes selbstsigniertes Zertifikat allein schafft
kein Vertrauen. Ausgabeordner und Dateien erhalten private CurrentUser-/SYSTEM-
ACLs. JSON und ENV enthalten Klartextkennwörter und bleiben lokal.

Gültigkeit: höchstens 15 Minuten, begrenzt durch das Leaf. Signatur, Flags,
Eintragshash, Referenzen und aktuelle native Bindungen werden beim Readback
geprüft. ENV/Markdown sind Begleitformate; autoritativ ist das signierte JSON.
Provider im Eintrag und in der signierten Qualifikation müssen zur eigenen
Runbindung passen. Auch eine gültige CA-Signatur erlaubt keine Umdeutung eines
Podman-Nachweises als Docker-Nachweis.
Ein bestehendes Exportverzeichnis wird nicht überschrieben.
Bestehende V1-Consumer benötigen einen expliziten V2-Cutover mit eigener
Abnahme. Dieser Pfad behauptet keine Toolbelt-/Analyze-Abnahme und keinen
Fallback auf V1 oder ein anderes SQL-Ziel.

## Fehler und Lebenszyklus

Vor Provideränderungen stehen eigener State, Intent und Cleanupzuständigkeit
fest. Einzelne Container-Kommandos haben 45 Sekunden Timeout; die private TLS-
Operation hat höchstens 100 gezählte TLS-Runtime-Kommandos und 20 Minuten Budget.
Die feste Runtime-Discovery wird vorab mit ihrem konservativen Maximum von sechs
Kommandos verrechnet; frische Inkarnationsprüfungen zählen ebenfalls. Die
darunterliegenden Custodyreader und der normale Lab-Lifecycle behalten ihre
eigenen vorhandenen festen Grenzen.
Die
Zertifikatsübergabe über stdin ist auf 16 KiB und zehn Sekunden begrenzt.
Ein eigenes explizites Budgetobjekt bindet Provider und Runtime und wird durch
alle privaten Schritte weitergegeben; unterschiedliche Operationen teilen keine
Zähler oder Fristen.
Der normale Lab-Lifecycle besitzt seine vorhandenen eigenen Grenzen.
Fehler nach erfolgreicher Runanlage entfernen ausschließlich den neuen Run
über `Remove-SqlServerLab`; unbestätigter Cleanup bleibt Recoverybedarf.
Intent-/Fehlernachweise werden lokal erhalten. Ein erfolgreicher Run bleibt
bewusst als nutzbares eigenes Lab bestehen und wird mit seinem zurückgegebenen
StateRoot gestartet, gestoppt oder entfernt. Der CA-/Trustscope wird dabei
nicht gelöscht und vorhandener Trust nicht entzogen.

Der Default der öffentlichen Erstellung und des bisherigen Exports bleibt
`Encrypt=True;TrustServerCertificate=True`. Hyper-V, Linuxclients und
andere SQL-/Patchstände außer SQL 2025 CU9, SQL 2022 CU27 und SQL 2019 CU32 sind für diesen operativen Export noch nicht freigegeben.
Die früheren getrennten nativen Kryptoproben erweitern diese Capability nicht.
Die öffentliche Podman-Abnahme vom 2026-10-20 und der zusammengesetzte
Docker-Regressionsnachweis sind in der Validierungsstrategie getrennt geführt.

Prüfwege: [Authority-Fixtures](../../Tests/Static/Invoke-AuthenticatedTlsAuthorityChecks.ps1),
[Export-Fixtures](../../Tests/Static/Invoke-AuthenticatedTlsLabChecks.ps1),
[native Abnahme](../../Tests/Integration/Invoke-AuthenticatedTlsLabAcceptance.ps1).
Statische oder injizierte Beobachtungen sind keine bestandene SQL-Verbindung.
