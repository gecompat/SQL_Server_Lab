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
PowerShell 7.5+, Docker, den lokal vorhandenen Katalogstand `2025-CU9`,
`DataRoot`, `TlsControllerId`, `TlsLocationId` und `TlsCandidateId`.
Der Pfad erzeugt einen eigenen StateRoot unter
`State/authenticated-tls-labs/<AuditId>` und genau einen eigenen Run.
Autostart bleibt zwingend `off`; `on` wird abgelehnt. Der Pfad aktiviert keinen globalen Host-Autostartkoordinator.
Manifest, vorhandener StateRoot, Hostmounts und andere Provider werden vor
Provideraktionen abgelehnt. CA-Metadaten werden gemeinsam registriert;
bestehende SQL-Ziele werden nicht übernommen oder umkonfiguriert.

RSA-3072-Schlüssel und CSR entstehen als UID 10001 im eigenen Container.
Der private SQL-Schlüssel verlässt ihn nicht. Der Signierer stellt ein Leaf
für IP `127.0.0.1` mit einem Tag Gültigkeit aus. SQL erhält die exakten
Zertifikats-/Keypfade und Force Encryption; Stop/Start läuft über den öffentlichen
Lifecycle. Der lokale geschützte Bindungsrecord enthält Run, Scope, Instanz,
Container-/Image-ID, Port, Startzeit sowie Leaf-DER und Fingerprint.

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
sperren den Export. Automatische Reparatur, Renewal und Rebind fehlen.

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
Ein bestehendes Exportverzeichnis wird nicht überschrieben.
Bestehende V1-Consumer benötigen einen expliziten V2-Cutover mit eigener
Abnahme. Dieser Pfad behauptet keine Toolbelt-/Analyze-Abnahme und keinen
Fallback auf V1 oder ein anderes SQL-Ziel.

## Fehler und Lebenszyklus

Vor Provideränderungen stehen eigener State, Intent und Cleanupzuständigkeit
fest. Einzelne Docker-Kommandos haben 45 Sekunden Timeout; die private TLS-
Operation hat höchstens 100 eigene Docker-Kommandos und 20 Minuten Budget. Ein eigenes explizites Budgetobjekt wird durch alle privaten Schritte weitergegeben; unterschiedliche Operationen teilen keine Zähler oder Fristen.
Der normale Lab-Lifecycle besitzt seine vorhandenen eigenen Grenzen.
Fehler nach erfolgreicher Runanlage entfernen ausschließlich den neuen Run
über `Remove-SqlServerLab`; unbestätigter Cleanup bleibt Recoverybedarf.
Intent-/Fehlernachweise werden lokal erhalten. Ein erfolgreicher Run bleibt
bewusst als nutzbares eigenes Lab bestehen und wird mit seinem zurückgegebenen
StateRoot gestartet, gestoppt oder entfernt. Der CA-/Trustscope wird dabei
nicht gelöscht und vorhandener Trust nicht entzogen.

Der Default der öffentlichen Erstellung und des bisherigen Exports bleibt
`Encrypt=True;TrustServerCertificate=True`. Podman, Hyper-V, Linuxclients und
andere SQL-/Patchstände sind für diesen operativen Export noch nicht freigegeben.
Die früheren getrennten nativen Kryptoproben erweitern diese Capability nicht.

Prüfwege: [Authority-Fixtures](../../Tests/Static/Invoke-AuthenticatedTlsAuthorityChecks.ps1),
[Export-Fixtures](../../Tests/Static/Invoke-AuthenticatedTlsLabChecks.ps1),
[native Abnahme](../../Tests/Integration/Invoke-AuthenticatedTlsLabAcceptance.ps1).
Statische oder injizierte Beobachtungen sind keine bestandene SQL-Verbindung.
