# TLS-001a – Entwurf einer isolierten Lab-CA

| Merkmal | Wert |
|---|---|
| Status | `DESIGN_PROPOSAL` mit privatem Windows-CA-Kandidaten; keine authentifizierte TLS-Abnahme |
| Stand | 2026-10-16 |
| Auftrag | Autonome Entwicklung ausdrücklich wiederaufgenommen; eigene isolierte Lab-CA mit ausdrücklich freizugebendem Client-Trust planen |
| Kanonischer Scope | [TLS-001](NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen) |
| Freigegebene Richtung | Eigene isolierte Lab-CA; die Auswahl ist keine Import-, Neustart- oder Änderungsfreigabe für bestehende Testziele |

Der Benutzer hat anschließend die autonome Umsetzung bis zur echten TLS-Lab-
Abnahme ausdrücklich beauftragt, damit Toolbelt SC-2026-045 weiterführen kann.
Konkrete fehlende Freigaben werden anhand reviewbarer Previews abgefragt;
die Schutzgrenzen und nachfolgenden einzelnen Mutationsgrenzen bleiben bestehen.

## Ausgangslage und Aussagegrenze

PR #755 integriert den priorisierten Backlog nach dem abgeschlossenen SSISDB-
Stream. Exporter, Schema und Agenten-Prompt verwenden weiterhin den Vertrag
`SqlServerLab.TestEnvironment/1.0` mit Trust-Override. Die lesende Prüfung des
konfigurierten Exports bestätigt diese Werte für die sechs Gruppenmitglieder;
der gespeicherte Status `READY` wurde dabei nicht durch SQL neu bestätigt.
Die exportierten Verbindungsidentitäten sind IP-Adressen. Lokatoren,
Credentials und konkrete Hostwerte bleiben ausschließlich lokal.

Der Windows-Host stellt System.Data.SqlClient, ODBC-sqlcmd und installierte
ODBC-Treiber bereit. Eine installierte Treiberversion beweist nicht, welchen
Treiber sqlcmd tatsächlich lädt. Linux-, Dienst- und Runnerkontexte sowie
Serverzertifikate, SANs, Ketten, SQL-Bindungen und Schlüsselrechte sind noch
nicht live untersucht. Aus der Exportabweichung folgt kein Zertifikatsfehler.
Analyze und PerformanceSchulung bleiben für den Consumer-Cutover gesondert zu
inventarisieren; die erhaltene SSISDB-Quelle besitzt einen eigenen Vertrag.

## D1 – CA, Schlüssel und Lifecycle

Vorgeschlagen wird eine CA pro ausdrücklich registriertem Lab-Vertrauensbereich,
mit eigener stabiler ID und Generation. Keine Übernahme einer Host-, Firmen-
oder vorbestehenden CA und keine automatische Registrierung als allgemeine PKI.
Ein Serverleaf bindet genau eine eigene Run-/Instanz-/Runtimeidentität und die
ausgewählten Verbindungsidentitäten. Der CA-Signierschlüssel verbleibt in einem
geschützten Signierkontext außerhalb von Git und getrennt von SQL, Exporten,
Containermounts und Gästen. SQL erhält ausschließlich seinen eigenen Leafkey.

Der erste konkrete Backend-Scope muss die tatsächlich verfügbaren Signier-,
CSR- und Keyschutzfähigkeiten prüfen. Keine vorausgesetzte OpenSSL-Installation,
kein Download und keine stille Backendwahl. Nach Möglichkeit entsteht der
Leafkey im Zielkontext; zur Signierung werden nur CSR und öffentliche Daten
übertragen. Ein nötiger Schlüsseltransfer verlangt einen eigenen geschützten
Transport- und Löschvertrag. Ausgaben, Receipts und Fehler enthalten keine
Schlüsselbytes, PFX-Passwörter oder Connection Strings.

Vorgeschlagenes Labprofil: RSA mit mindestens 3072 Bit und SHA-256, CA mit
`CA=true`, `pathLen=0` und ausschließlich den benötigten Signierrechten;
Leaf mit `CA=false`, Server Authentication und separatem Schlüssel. Diese
Parameter sind noch kein qualifiziertes Kompatibilitätsprofil. Für Windows
zusätzlich CSP-/`AT_KEYEXCHANGE`-Eignung und SQL-Dienstzugriff prüfen; Linux
benötigt passende Dateirechte. Microsoft beschreibt diese plattformspezifischen
[Zertifikatsanforderungen](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements?view=sql-server-ver17)
und [Linux-Bindungen](https://learn.microsoft.com/en-us/sql/linux/security/encrypted-connections?view=sql-server-ver17).

Vorgeschlagene Fristen: CA höchstens 365 Tage, Leaf höchstens 30 Tage und nie
über das CA-Ende hinaus; Erneuerung ab sieben Tagen Restlaufzeit. Zeitprüfung
erfolgt in UTC, ohne automatische Fristverlängerung. Erneuerung erzeugt einen
neuen Key und eine neue Generation; Aktivierung erst nach beiden Clientproben.
Vorherige Bindung und eigener Rollback bleiben erhalten, solange sie gültig sind.
Ein kompromittierter Key sperrt den Bereich und seine Qualifikationen; Ersatz,
explizite Entfernung der registrierten Trustbindungen und erneute Abnahme sind
erforderlich. Eine allgemeine CRL-/OCSP-Infrastruktur oder globale Sperrwirkung
wird durch diesen ersten Lab-Scope nicht behauptet.

## D2 – geprüfte Identität ohne Resolveränderung

Die private [CSR-Kryptolane](../Architecture/AUTHENTICATED_TLS_LEAF_CSR.md)
konkretisiert jetzt D1/D2 für einen begrenzten öffentlichen RSA-3072-/SHA-256-
CSR mit echter Proof-of-Possession und vollständigem DER-Verbrauch. Der
gebundene DPAPI-Kandidatenkey signiert erst nach geschlossener Prüfung.
Genau ein ausdrücklicher IP-/DNS-SAN, CA=false, DigitalSignature/KeyEncipherment
und ServerAuthentication werden neu aufgebaut; Frist 1 bis 30 Tage innerhalb
der CA-Gültigkeit, ohne Kürzen. Der feste synthetische Subject und enge
Requestattribute bleiben eine Fixture-Kryptolane. Native Run-/Targetbindung,
Windows-certreq/CSP/KeySpec/Dienstrechte, Linux-Keyablage und SQL-Kompatibilität
sind damit nicht qualifiziert; keine AuthorityRef oder TLS-Freigabe entsteht.

Der erste Entwurf erhält die ausdrücklich ausgewählte Verbindungsidentität.
Numerische Ziele benötigen einen typisierten IP-SAN, DNS-Ziele einen passenden
DNS-SAN. Kein Wildcard-SAN und kein Ersatz durch CN, localhost, einen anderen
Host oder einen Client-Hostname-Override. Eigene neue Fixtures erhalten fest
gebundene Adressen beziehungsweise Ports; Portweiterleitung verändert den zu
prüfenden Namen nicht. Ein IP-/Namenswechsel invalidiert die bisherige Bindung
vor Export und verlangt Neuausstellung und erneute Clientprüfung.

IP-SAN-Unterstützung wird für System.Data.SqlClient und den tatsächlich
geladenen ODBC-sqlcmd-Stack separat belegt. Falls eine Kombination damit nicht
qualifizierbar ist, bleibt sie gesperrt; eine DNS-/Resolverlösung wird dann als
gesonderter konkreter Vorschlag ausgearbeitet. Die
[ODBC-Dokumentation](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/connection-string-keywords-and-data-source-names-dsns?view=sql-server-ver17)
fordert die Übereinstimmung der Verbindungsidentität mit dem Zertifikat.

## D3 – konkrete Client-Trustfreigabe

Die [private einmalige Recovery](../Architecture/AUTHENTICATED_TLS_TRUST_RECOVERY.md)
erhält einen gültigen ursprünglichen Intent ohne normalen Commit bytegenau
und bindet eine neue fünfminütige Preview an dessen Original-/Approvalbytes.
Nur ein eigener dauerhafter Recoveryintent kann einen neuen Versuch erlauben;
unklare Recovery bleibt terminal, vorhandener Trust unattributiert. Tatsächliche
Humanfreigabe, neue sichtbare Fensterwahl und alte Workerbeendigung prüft ein
separater vertrauenswürdiger Adapter nach Integration. Der Recoverycode selbst
erzeugt keine Autorität; dessen native Ausführung ist `NOT_EXECUTED`.

Der [private Windows-Trustimport](../Architecture/AUTHENTICATED_TLS_TRUST_IMPORT.md)
konkretisiert jetzt diese Grenze mit fünfminütiger exakter Freigabebindung,
geschütztem Intent/Commit und lesendem Status. Der kooperative Lock ist keine
globale Store-Atomizität; ein Importreceipt erteilt keine Löschautorität.
Eine eigene dauerhafte CA mit lokal erfolgreichem DPAPI-Reopen/Sign/Verify
und frischer Trustvorschau existiert. Die konkrete menschliche Freigabe ist
gesichert. Der separat geprüfte native Worker wurde genau einmal ausgeführt
und nach 60 Sekunden beendet. Frisch lesend: CA `ABSENT`, Journal
`RECOVERY_REQUIRED`, passender gültiger Intent, kein Commit und kein Lock;
kein bestätigter Import. UI-Wahl: kein Dialog sichtbar, sichtbares Fenster nach geprüfter Recovery gewünscht; kein automatischer Retry oder Journalremove.
Die Suite mutiert keinen Rootstore. Native Policy-/UI-Effekte und begrenzte
Add-Laufzeit bleiben unqualifiziert; ein äußerer Worker darf nach Timeout
keinen unklaren Intent automatisch wiederholen oder entfernen.

Für Windows wird zunächst `CurrentUser/Root` der ausdrücklich ausgewählten
Ausführungsidentität vorgeschlagen. Die Preview muss Store, Identität, CA-ID,
öffentlichen Zertifikatsdigest, Vorzustand, Nutzung durch andere Ziele und
Entfernungswirkung benennen. Erst die Freigabe dieser konkreten Preview erlaubt
den Import. Kein automatischer `LocalMachine`-Import; Dienste und Runner sind
separate Identitäten. Die Wirkung auf andere Anwendungen desselben Benutzers
gehört zur Preview. Keine private CA-Schlüsselablage im Rootstore.

Linux beginnt mit einem eigenen isolierten Clientkontext und dessen tatsächlich
verwendetem Truststore. Der ungenutzte Linuxhost wird nicht gestartet. Ein
prozesslokaler Zertifikatsmechanismus zählt nur bei nachgewiesener Unterstützung
beider konkreter Clientstacks; installierte CA-Dateien allein genügen nicht.
Die erforderlichen Pakete, Versionen und Rechte sind vor Arrange zu prüfen.

Import und Removal benötigen ein dauerhaftes besitzgebundenes Journal und
exakte Vor-/Nachbedingungen. Vorhandene identische Trustanker werden als
vorbestehend klassifiziert und nie als eigene Importe entfernt. Ein normaler
Run-Cleanup entfernt keinen gruppenweit verwendeten Trustanker. Eigenes
CA-Removal erhält eine separate Preview und prüft alle registrierten
Verbraucherbindungen; unbekannte oder offene Nutzung blockiert die Entfernung.
Abbruch, parallele Operationen und unbestätigte Rücknahme erhalten sichtbaren
Recoverybedarf. Kein Name-only-, Wildcard- oder globales Store-Cleanup.

## D4 – koordinierter Nachfolgevertrag

Vorschlag: `SqlServerLab.TestEnvironment/2.0` mit eigenem Schema und explizitem
Consumer-Cutover. Das bisherige 1.0-Schema wird nicht stillschweigend umdefiniert.
Ein V2-Reader muss unbekannte Versionen und Legacy-Trust-Override ausdrücklich
abweisen. Discovery und Overridevorrang bleiben erhalten; kein zweites
Dateisuchverfahren und kein stiller Fallback auf ein anderes Ziel oder V1.

V2 verlangt echte Booleans `encrypt=true` und `trustServerCertificate=false`
sowie einen separat authentifizierten Qualifikationsnachweis. Dieser bindet
Run/Instanz, Runtime, Endpointidentität, Leaf-/CA-Generation, Clientbinaries,
geladene Treiber, Ausführungsidentität und effektiven Trustkontext. Vorgeschlagene
Frische: höchstens 15 Minuten und niemals über Zertifikatsfristen hinaus.
Geänderte Bindungen, unbekannte Aktualität oder fehlender Nachweis sperren den
authentifizierten Export. Callerfelder oder gespeichertes Runtime-READY können
keinen solchen Nachweis herstellen. Öffentliche Projektionen bleiben ohne
Hostlokatoren und Credentials; das bestehende private Secretformat erhält
durch diese Planung keine erweiterten Verteilungsrechte.

Schema, Exporter, JSON/ENV/Markdown, Connection Strings, Resolver, Prompt und
Verbraucher wechseln gemeinsam. Für Toolbelt ist dessen tatsächlicher
Preflight mit beiden Clientstacks erforderlich; Analyze, PerformanceSchulung
und lokale Skripte erhalten eigene Versions-/Discoveryprüfungen. Die bisherige
Alles-oder-nichts-Gruppe und explizite Provider-/Versions-/Patchauswahl bleiben.
Keine automatische Umschaltung der geschützten sechs Ziele oder SSISDB-Quelle.

## Nächster ausführbarer Scope und Abnahme

Der erste [private Anfragevertrag](../Architecture/AUTHENTICATED_TLS_REQUEST.md)
implementiert inzwischen die geschlossene Formprüfung für CA-/Leafprofile und
Client-Trust-Previews. Referenzen und angeforderte Tupel sind unaufgelöst;
Erfolg erteilt weder Capabilitynachweis noch Ausführungsautorität. Der private
[Zielmetadatenresolver](../Architecture/AUTHENTICATED_TLS_TARGET_METADATA.md)
bindet jetzt echte RunId und ausdrückliche Instanzwahl unter registriertem Root
an gespeicherte Docker-/Podman-Container-/Versions-/Endpointdaten. Native
Runtime-/Ownershipprüfung bleibt offen; Hyper-V ist ausdrücklich gesperrt.
Der [Registrierungsentwurf](TLS_001_CONTEXT_REGISTRATION_DESIGN.md) trennt
ClientRef, SignerContextRef und AuthorityRef. Die
[Backendmetadaten](../Architecture/AUTHENTICATED_TLS_BACKEND_METADATA.md)
entdecken sechs .NET-API-Signaturen nach ausdrücklicher aktueller Prozesswahl;
sie erzeugen keine Identitätsbindung oder Backendqualifikation. Die private
[Windows-Kontextvorschau](../Architecture/AUTHENTICATED_TLS_CONTEXT_PREVIEW.md)
beobachtet jetzt nach geschlossener Anfrage Token-/Host-/Profilmetadaten und
Client-Diskbytes; sie registriert keine Referenz und qualifiziert keinen
Client oder Signierer. Der private
[Offline-Referenzindex](../Architecture/AUTHENTICATED_TLS_REGISTRY_INDEX.md)
prüft jetzt geschlossene Byteformen, Referenz-/Revisionsinvarianten und
Tombstones. Die [privaten Metadatenpayloads](../Architecture/AUTHENTICATED_TLS_REGISTRY_PAYLOAD.md)
vor Keyanlage, kanonische Digests und intern frische Prozessbindung sind
implementiert und synthetisch geprüft; eine getrennte lesende Windows-
Beobachtung traf alle drei Metadatenbindungen. Root-/Trustscopeauflösung und
vollständige Binderqualifikation bleiben offen; der Writer-/Crashvertrag bleibt Planung.
Die [Registry-Gesamtform](../Architecture/AUTHENTICATED_TLS_REGISTRY_DOCUMENT.md)
prüft jetzt offline die exakte Payload-/Index-/Digestzuordnung und vollständige
Übergänge. Die [lesende Rootbindung](../Architecture/AUTHENTICATED_TLS_REGISTRY_ROOT.md)
vergleicht jetzt registrierte Windows-Rootmetadaten und eine bestehende Registrydatei.
Kein atomarer Snapshot oder Autoritätsnachweis. Vorgezogen ist jetzt der
[private Windows-CA-Kandidat](../Architecture/AUTHENTICATED_TLS_CA_CANDIDATE.md):
RSA-3072, SHA-256/PKCS1, kritische CA/pathLen0 und KeyCertSign/CrlSign,
höchstens 365 Tage einschließlich fünf Minuten Rückdatierung, neue UUIDv4
und synthetischer Subject ohne SAN. Geschützte CurrentUser-Ablage und
DPAPI-verschlüsseltes PKCS8 werden an eigenen Tempfixtures tatsächlich
geprüft; die konkrete ReadOnly-Trust-Vorschau erhielt inzwischen menschliche Freigabe.
Kandidat bleibt `UNREGISTERED_UNQUALIFIED`. Registrytransaktion gemäß
Writer-/Crashvertrag und eigene Crash-/Parallelitätsfixtures bleiben offen;
keine automatische Pfadadoption. Der private CSR-Kryptobeweis und der
separate Trustversuch oben ersetzen weder Registrywrites noch native
Target-/SQL-Signierqualifikation. Die ursprüngliche Reihenfolge
darunter bleibt als historische Scopegrenze erhalten.

Zuerst den geschlossenen privaten Anfragevertrag für CA-/Leaf-/Trustpläne und
ihre sourcegebundene Offlineprüfung konkretisieren. Noch keine öffentliche API,
PKI-Anlage, Schlüsselöffnung, Trustmutation oder Provideraktion. Das Ergebnis
benennt unterstützte Backend-/Clientkontexte, harte Grenzen, Vorbedingungen,
Ownership, Abbruch und Recovery; unbekannte Kombinationen bleiben gesperrt.
Ein Manifestfeld oder Exportcutover gehört erst zum nachfolgenden vertikalen
Scope mit seinen gekoppelten Tests.

Danach native Abnahmen ausschließlich an frischen eigenen Ressourcen:
Docker, Podman und Hyper-V getrennt, zunächst SQL 2025, anschließend 2019 und
2022 mit jeweils ausdrücklich ausgewählten Patchständen. Beide Clientstacks
prüfen erfolgreiche SQL-Verbindung und Transportverschlüsselung. Nicht
vertraute Kette, falsche Identität und Ablauf müssen in getrennten negativen
Fixtures vor fachlicher SQL-Arbeit scheitern. Renewal, Identitätswechsel,
Trustdrift, Abbruch/Resume und Cleanup erhalten eigene Assertions. Kein
Trustbypass, keine Abschaltung der Verschlüsselung und kein stiller TLS-Downgrade.

Aktuelle Evidence: Quellen-/Exportmetadaten und Clientverfügbarkeit lesend
geprüft; der private Windows-Kandidatenpfad besitzt lokale native Crypto-/
DPAPI-/ACL-Fixtures. Ein eigener dauerhafter CA-Kandidat außerhalb der Tests
ist inzwischen lokal angelegt und mit frischer lesender Trustvorschau geprüft;
reale Runtimeidentitäten bleiben privat. Die Importtransaktion ist mit eigenen
Datei-/ACL-/Lockfixtures und injizierten Storegrenzen geprüft. Der echte
Trustversuch blieb nach Timeout unbestätigt und verlangt lesende Recovery.
Die eigene temporäre CSR-Kryptofixture belegt keine operative SQL-Bindung;
Clientverbindungen und die gesamte TLS-Matrix bleiben `NOT_EXECUTED`.
Die noch offenen D1–D4-Parameter
werden vor dem jeweils betroffenen mutierenden Scope konkret abgenommen.
