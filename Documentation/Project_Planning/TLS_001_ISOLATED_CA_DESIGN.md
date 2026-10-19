# TLS-001a – Entwurf einer isolierten Lab-CA

Die [interne strikte Aktivierungsprüfung](../Architecture/HYPERV_SQL_COMPLETION_BOUNDARY.md)
bindet VerifyOnly/Denied an die ausgewählte VM-ID, ohne neue Aktivierung oder
Netzreparatur. Sie stellt weder einen CA-/Trustkontext noch vollständige
öffentliche Setupbindung oder native CA-/SQL-/TLS-Qualifikation her.

Der [strikte interne Run-Reader](../Architecture/HYPERV_SQL_COMPLETION_BOUNDARY.md)
schließt eine vorgelagerte VM-ID-/Rename-Lesegrenze ohne Write.
Er ersetzt weder durchgängige öffentliche Setupbindung noch Verbraucherende
oder native CA-/SQL-/TLS-Abnahme.

Die vorgelagerte [SQL-Abschlussgrenze](../Architecture/HYPERV_SQL_COMPLETION_BOUNDARY.md)
bindet explizite Roots und unterbindet Transportreplay mutierender Gastblöcke.
Sie ist keine native Setup-, CA-, ServiceACL- oder TLS-Abnahme und erteilt
keine neue Autorität für unbekannte Teilzustände.

Die [Windows-CSP-Charakterisierung vom 2026-10-18](../Quality/TLS_HYPERV_WINDOWS_CSP_CHARACTERIZATION_2026-10-18.md)
belegt inzwischen einen eigenen nicht exportierbaren Gastkey und Host-CSR-Proof.
Der additive erwartete Maschinen-CN des privaten Leafvertrags ist eine reine
Kryptoerwartung. Der echte CSR mit zusätzlichem S/MIME bleibt abgelehnt;
CA-Ausstellung, Storeannahme, SQL-Dienstrechte und TLS stehen weiterhin aus.

Ein späterer Request verwendete nativ denselben Schlüssel mit `SMIME=FALSE`.
Sein ursprünglicher Hostabschluss scheiterte am UTF8-Subject-DER und bleibt
fehlgeschlagen erhalten. Die getrennte Readerkorrektur prüft dieselben
öffentlichen Bytes ohne Gast-/Keywiederholung; keine neue CA-/TLS-Autorität.

## Integrierter Teilscope vom 2026-10-18

Der [operative Vertrag](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md)
beschreibt die inzwischen implementierte und nativ abgenommene Windows-/Docker-
SQL-2025-CU9-Lane mit CA-/Trustscopebindung und separatem signiertem False-Export.
Der einfache True/True-Default bleibt erhalten. Die folgenden Entwurfsstände
und weiteren Matrix-/Consumeranforderungen ersetzen diesen begrenzten Vertrag
nicht und belegen keinen vollständigen TLS-001-Abschluss.

## Private Authority-Metadatenform vom 2026-10-17

Die [Authoritybindung](../Architecture/AUTHENTICATED_TLS_AUTHORITY_BINDING.md)
verbindet `0.2`-CA-Payloads mit geschütztem Kandidaten/Ciphertext/DER,
exakter aktiver Client-/Signiergeneration und frischer ReadOnly-Trustlesung.
Der bestehende Writer prüft vor Intent, Ersatz, Commit und Recoverycommit;
unveränderte Generationen werden für aktive CAs nicht übersprungen.
Kein Keyopen, Storewrite, tatsächliche Adoption der bestehenden CA oder
SQL-Effekt. Der Befund bleibt METADATA_BOUND_NOT_TLS_QUALIFIED und nicht
atomar; handlebasierte Rootanker und volle TLS-/Exportqualifikation sind offen.

| Merkmal | Wert |
|---|---|
| Status | Operative Windows-/Docker-SQL-2025-CU9-Lane integriert; weitere Matrix, Consumer und Lifecycle offen |
| Stand | 2026-10-18 |
| Auftrag | Autonome Entwicklung ausdrücklich wiederaufgenommen; eigene isolierte Lab-CA mit ausdrücklich freizugebendem Client-Trust planen |
| Kanonischer Scope | [TLS-001](NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen) |
| Freigegebene Richtung | Eigene isolierte Lab-CA; die Auswahl ist keine Import-, Neustart- oder Änderungsfreigabe für bestehende Testziele |

Der Benutzer hat anschließend die autonome Umsetzung bis zur echten TLS-Lab-
Abnahme ausdrücklich beauftragt, damit Toolbelt SC-2026-045 weiterführen kann.
Konkrete fehlende Freigaben werden anhand reviewbarer Previews abgefragt;
die Schutzgrenzen und nachfolgenden einzelnen Mutationsgrenzen bleiben bestehen.

## Ausgangslage und Aussagegrenze

Der spätere [private Windows-Registrywriter](../Architecture/AUTHENTICATED_TLS_REGISTRY_WRITER.md)
implementiert inzwischen die Metadatenlane vor Keyanlage mit ausdrücklicher
leerer Initialisierung, aktiven Client-/Signierrecords, frischer Actor-/
Volumeprüfung, privater Ablage, kooperativen Sperren und expliziter Recovery.
Eigene NTFS-Tempfixtures prüfen atomaren Ersatz, echte Prozessabbrüche,
Konkurrenz und Cleanup. Operative CA-/Trustscopezuordnung, Retirement,
öffentliche Moduswahl und qualifizierter Export bleiben offen. Die folgenden
früheren Planungsstände sind dadurch keine aktuelle Behauptung eines
vollständig fehlenden Metadatenwriters.

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

## Verbindliche Moduswahl und Standard

Der Benutzerauftrag vom 2026-10-16 präzisiert das Ziel: Beide Verbindungsarten
müssen beim Erstellen einer Lab-Umgebung wählbar sein. Standard ist die Variante
mit geringerem Einrichtungsaufwand. Die folgenden Festlegungen ersetzen eine
pauschale Ablösung des bisherigen Zugangs. Die öffentliche False-Wahl und der
authentifizierte Runtimepfad sind inzwischen im oben begrenzten Scope implementiert.

| Modus | Verbindung | Einrichtungsaufwand und Verwendung |
|---|---|---|
| Standard | `Encrypt=True;TrustServerCertificate=True` | Verschlüsselung ohne Prüfung der Serveridentität durch den Client; keine eigene Lab-CA oder Client-Trusteinrichtung als Voraussetzung. Für einfache isolierte Labs und dafür geeignete Verbraucher. |
| Zertifikatsprüfung, ausdrücklich gewählt | `Encrypt=True;TrustServerCertificate=False` | Gültiges, an SQL gebundenes Serverzertifikat mit passender Verbindungsidentität, geschütztem Schlüssel und wirksamem Client-Trust. Für Verbraucher und Szenarien, die authentifizierte TLS-Verbindungen verlangen. |

Die Bedeutung der beiden Einstellungen und die Zertifikatsvoraussetzungen sind
in der [Microsoft-Dokumentation](https://learn.microsoft.com/en-us/sql/connect/ado-net/encryption-and-certificate-validation?view=sql-server-ver17)
beschrieben. Verschlüsselung bleibt in beiden Modi eingeschaltet. Der Standard
belegt keine authentifizierte Serveridentität; Zertifikatsprüfung ist keine
Voraussetzung für die Erstellung jeder einfachen Lab-Umgebung.

`TrustServerCertificate` ist eine Cliententscheidung. Eine für `False` korrekt
eingerichtete SQL-Instanz kann grundsätzlich auch mit `True` angesprochen werden;
zwei Instanzen oder getrennte Serverzertifikate sind dafür nicht erforderlich.
Das gilt für das hier verlangte `Encrypt=True`; `Encrypt=Strict` und ein
serverseitiger Strict-Zwang gehören nicht zu diesem gemeinsamen Modusvertrag.
Die tatsächliche Kompatibilität bleibt je Provider, SQL-Version und Client zu
prüfen. Ein Szenario oder Consumer darf Zertifikatsprüfung zwingend verlangen;
dann ist der einfache Standard für diesen Auftrag ungeeignet.

Die Moduswahl muss Erstellung, gespeicherte Konfiguration, API, Konsole,
Browser und Export konsistent verbinden. In den Connection Settings von CLI
und GUI stehen `Encrypt=True` und der effektive Wert von
`TrustServerCertificate` direkt beim gewählten Ziel, auch ohne Anzeige eines
vollständigen Connection Strings oder eines Passworts. Das weiterführende Anzeigeziel erläutert
„Zertifikatsprüfung deaktiviert“ bei `True` beziehungsweise
„Zertifikatsprüfung erforderlich“ bei `False`. Ein getrennter Status zeigt, ob
die authentifizierte Verbindung für den gebundenen Client-/Zielkontext
qualifiziert, ungeprüft, veraltet oder blockiert ist. Der Flagwert allein
begründet keinen Erfolgsstatus. Fehlende oder widersprüchliche Metadaten werden
sichtbar benannt und nicht als erfolgreicher Standardwert ausgelegt. Anzeige,
kopierter Connection String und Export müssen übereinstimmen; beide
Oberflächen benötigen dafür eigene Prüfungen. Die angegebene Flagprojektion ist
bereits implementiert; ergänzende Erläuterungen und der gesonderte Prüfstatus
sind weiterführender P1-Scope, kein behaupteter aktueller GUI-Qualifikationsstatus.

Ohne ausdrückliche Auswahl gilt der Standard; Provider oder SQL-Version wählen
keinen anderen Modus implizit.
`False` darf erst nach erfolgreicher Qualifikation für den konkreten Client-
und Zielkontext als bereit exportiert werden. Fehlt diese Qualifikation,
blockiert der angeforderte Modus ohne Rückfall auf `True`. Bestehende Labs werden
nicht automatisch umkonfiguriert. Der einfache Standard bleibt dauerhaft
unterstützt und ist kein abzulösender Übergangsmodus.

Die nachfolgende Umsetzungsvorgabe vom 2026-10-16 erlaubt die sofortige
Produktumsetzung nur bei bereits vorhandenen und funktionierenden
Voraussetzungen. Die [Vorprüfung und Startentscheidung](NEW_SQL_LAB_USE_CASES_BACKLOG.md#voraussetzungen-und-startentscheidung-vom-2026-10-16)
bestätigte damals Provider-/Storage- und Clientverfügbarkeit, aber keinen vollständigen
operativen Zertifikats-/Trust-/SQL-Pfad. Beide Modi einschließlich CLI-/GUI-
Connection-Settings und echter Verbindungsabnahme wurden deshalb als
zusammenhängender P1-Umfang zurückgestellt. Der spätere ausdrücklich beauftragte
operative Teilscope oben ergänzt diese historische Startentscheidung; die
damalige Vorprüfung war keine TLS-Liveabnahme und richtete keine Voraussetzungen ein.

Ein weiterer begrenzter Auftrag setzt den bereits funktionierenden Standard
jetzt unabhängig davon um. Neue gemeinsame Container-Connection-Strings
enthalten ausdrücklich `Encrypt=True;TrustServerCertificate=True`; dasselbe
gilt für neue SSMS-Registrierungsexporte. Die normalen Connection-String-
Anzeigen in CLI und GUI erhalten dadurch beide ausdrücklichen Werte. Das
schloss weder die spätere `False`-Moduswahl noch die erweiterte Prüfstatusanzeige ab.
Die [lesende Abnahme des Standardmodus](../Quality/LOCAL_VALIDATION_STRATEGY.md#expliziter-tls-standard-vom-2026-10-16)
ist von der späteren operativen Abnahme und der weiterhin offenen Gesamtmatrix zu unterscheiden.

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

Der integrierte operative Export verwendet bereits `SqlServerLab.TestEnvironment/2.0`
mit eigenem [Schema](../../Schemas/test-environment-authenticated.schema.json),
echten Booleans `encrypt=true`/`trustServerCertificate=false` und signiertem
Qualifikationsnachweis. Der True/True-Standard bleibt im unveränderten V1-
Vertrag. Beide Formate werden getrennt ausgegeben; bestehende Discovery wird
nicht umgeschaltet. Der Consumer-Cutover benötigt weiterhin eine eigene Abnahme.

Der zuvor lokal geplante gemeinsame Nachfolgevertrag für beide Modi bleibt
als Erweiterungsziel erhalten. Ein solcher Vertrag muss zusätzlich echte
Booleans `encrypt=true`/`trustServerCertificate=true` ausdrücken können und
braucht eine ausdrücklich abgestimmte neue Version; er darf das bestehende
V2-False-Schema nicht stillschweigend umdefinieren. Die genaue Feldform ist
vor Implementierung gemeinsam mit den Consumern festzulegen.
Ein Reader weist unbekannte Versionen und einen für seinen Auftrag
ungeeigneten Modus ausdrücklich ab. Ein Consumer wie Toolbelt SC-2026-045 darf
weiterhin ausschließlich den authentifizierten Modus akzeptieren; daraus
entsteht keine globale Zertifikatspflicht für alle Labs. Discovery und
Overridevorrang bleiben erhalten; kein zweites Dateisuchverfahren und kein
stiller Fallback auf einen anderen Modus, ein anderes Ziel oder V1.

Der Modus mit Zertifikatsprüfung verlangt zusätzlich einen separat
authentifizierten Qualifikationsnachweis. Dieser bindet
Run/Instanz, Runtime, Endpointidentität, Leaf-/CA-Generation, Clientbinaries,
geladene Treiber, Ausführungsidentität und effektiven Trustkontext. Vorgeschlagene
Frische: höchstens 15 Minuten und niemals über Zertifikatsfristen hinaus.
Geänderte Bindungen, unbekannte Aktualität oder fehlender Nachweis sperren den
authentifizierten Export. Callerfelder oder gespeichertes Runtime-READY können
keinen solchen Nachweis herstellen. Öffentliche Projektionen bleiben ohne
Hostlokatoren und Credentials; das bestehende private Secretformat erhält
durch diese Planung keine erweiterten Verteilungsrechte.

Schema, Exporter, JSON/ENV/Markdown, Connection Strings, Resolver, Prompt und
Verbraucher wechseln gemeinsam. Jeder Export gibt den gewählten Modus konsistent
wieder; ein zusätzlicher authentifizierter Export darf den einfachen Standard
nicht unbemerkt überschreiben. Für Toolbelt ist dessen tatsächlicher
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
2022 mit jeweils ausdrücklich ausgewählten Patchständen. Beide Modi erhalten
getrennte positive SQL-/Verschlüsselungsnachweise in beiden Clientstacks.
Der Standard muss ohne eigene CA und Trustimport erstellbar sein. Am für
Zertifikatsprüfung qualifizierten Ziel müssen beide Clientoptionen funktionieren.
Nicht vertraute Kette, falsche Identität und Ablauf müssen in getrennten negativen
Fixtures im Modus mit Zertifikatsprüfung vor fachlicher SQL-Arbeit scheitern.
Moduswahl, Default, widersprüchliche Exporte und ausbleibender automatischer
Rückfall erhalten eigene Assertions. Renewal, Identitätswechsel,
Trustdrift, Abbruch/Resume und Cleanup erhalten eigene Assertions. Kein
Trustbypass im authentifizierten Modus, keine Abschaltung der Verschlüsselung
und kein stiller TLS-Downgrade.

Aktuelle Evidence: Quellen-/Exportmetadaten und Clientverfügbarkeit lesend
geprüft; der private Windows-Kandidatenpfad besitzt lokale native Crypto-/
DPAPI-/ACL-Fixtures. Ein eigener dauerhafter CA-Kandidat außerhalb der Tests
ist inzwischen lokal angelegt und mit frischer lesender Trustvorschau geprüft;
reale Runtimeidentitäten bleiben privat. Die Importtransaktion ist mit eigenen
Datei-/ACL-/Lockfixtures und injizierten Storegrenzen geprüft. Der echte
erste Trustversuch blieb nach Timeout unbestätigt. Die später separat geprüfte
[sichtbare Recovery](../Quality/TLS_CA_TRUST_ACCEPTANCE_2026-10-16.md) bestand
inzwischen mit Exitcode 0 und frischer exakter Trustnachbeobachtung;
`RECOVERY_IMPORT_RECORDED`, Originalintent bytegleich und kein verbleibender Lock.
Die eigene temporäre CSR-Kryptofixture belegt keine operative SQL-Bindung;
Die erste eigene Docker-SQL-2025-Probe belegte anschließend die Ablehnung der
unvertrauten Kette vor SQL-Arbeit. Nach Ablehnung des realen OpenSSL-CSRs
wurde nur der eigene Run vollständig entfernt; Bestandsdateien blieben gleich.
Die korrigierte feste UTF8-Subjectform besteht den erhaltenen öffentlichen
CSR-Readercheck ohne Key-/Store-/Runtimezugriff. Die spätere
[Windows-Probe](../Quality/TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
bestand mit beiden strikten positiven Stacks und .NET-Gegenfällen für
unvertraute Kette und falsches SAN am gleichen IPv4-Endpunkt. Nur der eigene
Run wurde entfernt; Bestandsdateien blieben bytegleich. Für die echten
Ablaufgegenfälle erlaubt die private Signierlane nun alternativ native
30–300 Sekunden ab tatsächlichem UTC-Beginn, ohne Rückdatierung/Uhränderung.
Die [anschließende echte Ablauf-/Erneuerungsprobe](../Quality/TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
bestand für beide Windows-Stacks mit unvertrauter Kette, echtem Ablauf,
falschem SAN und Erneuerung mit neuem Key; eigener Cleanup und Bestandsdateien
sind bestätigt. Die getrennte eigene [Podman-Probe](../Quality/TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle für SQL 2025 CU9 samt Cleanup und
frischem Bestandsdateivergleich. Die nachfolgende [Container-Versionsmatrix](../Quality/TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle separat mit Docker und Podman für
SQL 2019 CU32 und SQL 2022 CU27 samt eigenem Cleanup. Linuxclients, Hyper-V,
Trustdrift, TLS-Abbruch/Resume, vollständige TLS-Matrix, Registry und
qualifizierter Export bleiben offen.
Die nachfolgende [Linux-Clientvorbereitung](../Quality/TLS_LINUX_CLIENT_CAPABILITY_2026-10-16.md)
beobachtete PowerShell, SqlClient-Konstruktion mit erwartetem lokalem
Netzwerkfehler und den ersten sqlcmd-Hilfeaufruf. Alle eigenen Fixtures entfernt,
Bestandsdateien frisch erhalten. Keine CA-Datei oder Truständerung; die konkrete
Linux-Trustentscheidung, Kontextregistrierung und tatsächliche Linux-TLS-Probes
bleiben separat. Die Windows-Freigabe wurde nicht erweitert.
Die noch offenen D1–D4-Parameter
werden vor dem jeweils betroffenen mutierenden Scope konkret abgenommen.

Der spätere ausdrücklich freigegebene
[isolierte Linux-Trustversuch](../Quality/TLS_LINUX_TRUST_ATTEMPT_2026-10-17.md)
scheiterte vor den TLS-Probes an der privaten Dateivorbereitung: Root ohne
Capabilities konnte die Datei nicht an UID 10001 umhängen. Eigener Client,
SQL-Ziel, Volumes und temporäre Secretdatei sind entfernt; Workerende,
Abwesenheit, Bestandsdateien und bestehender Windows-Trust frisch geprüft.
Ein Nachfolger plant direkte Dateianlage durch UID 10001 ohne `chown` oder
Zusatzprivilegien. Er benötigt eine neue konkrete Freigabe, einen endlichen
Abschnitt und unabhängig geprüfte gebundene Quellen; kein Intent-Replay.
Linux-TLS, Registry und SC-2026-045 bleiben offen.
Der danach separat freigegebene
[UID-Nachfolger](../Quality/TLS_LINUX_DIRECT_UID_PARTIAL_ACCEPTANCE_2026-10-17.md)
bestand die native direkte Dateianlage durch UID 10001 und eine strikte
Linux-CLR-Verbindung mit SQL-Build und Verschlüsselung. ODBC lehnte den als
positiv geplanten IP-SAN-Fall wegen Namensabweichung ab; kein bestandener
Wrong-SAN-Gegenfall und keine allgemeine Aussage über IP-SAN-Unterstützung.
Eigener Cleanup und frische Schutzvergleiche bestanden. Eine neue konkrete
`DNS localhost`-Vorschau plant normale Namensprüfung ohne Resolveränderung;
neue Freigabe und gebundene Quellen bleiben erforderlich. Beide Stacks,
Trustdrift, geladener ODBC, Registry und SC-2026-045 bleiben offen.
## CU-Metadatenbindung am 2026-10-17

Die nachfolgende [Linux-Trustdriftabnahme](../Quality/TLS_LINUX_SQL2025_TRUST_DRIFT_ACCEPTANCE_2026-10-17.md)
bestand auf einem eigenen Docker-/SQL-2025-CU9-Ziel mit beiden strikten Stacks,
kontrolliertem Trustentzug und Wiederherstellung. Geladener ODBC und frischer
vollständiger Runtime-Cleanup sind bestätigt. Die korrigierte generische
Zertifikatsablehnung benötigt eine vorherige erfolgreiche Kontrolle und null
SQL-Arbeit; der erste Harnessfehler bleibt erhalten. Andere Matrixfälle,
operative Registry, öffentliche Moduswahl und qualifizierter Export bleiben offen.

Der anschließend neu konkret freigegebene
[localhost-Versuch](../Quality/TLS_LINUX_LOCALHOST_PRETRUST_ATTEMPT_2026-10-17.md) scheiterte vor der Client-Trustdateianlage:
`getent ahosts/hosts` beobachtete nur die freigegebenen Loopback-Adressen,
der zusätzliche .NET-Auflösungsprozess startete jedoch wegen des schreibgeschützten
Homeverzeichnisses nicht. Keine TLS-Probes oder Client-Trustanlage; eigener Cleanup,
frische Abwesenheit und Schutzvergleiche bestanden. Eine neue rein planende
Vorschau ergänzt ausschließlich das prozesslokale `HOME=/tmp` für diesen
Auflösungsaufruf. Sie ist ungetestet und verlangt eine neue konkrete Freigabe,
ein neues Budget und gebundene geprüfte Quellen. Kein Replay; die vollständige
TLS-Abnahme und Toolbelt SC-2026-045 bleiben offen.

Der lesende Diagnostic-/TLS-Zielmetadatenpfad erhält jetzt katalogisierte
Docker-/Podman-CU-Kurzbezeichner und exakte Tags als vollständige Runselektoren.
Der Reader bindet zusätzlich Basisjahr, exakten Katalogtag und Katalogbuild;
unbekannte CUs, widersprüchliche Tags und ein Jahresfallback bleiben gesperrt.
Dies ist ein synthetisch geprüfter Metadatenvertrag, keine nachträgliche
Qualifikation der früheren nativen CU-Fixtures. Linux-TLS, Hyper-V, operative
Registry, Exportcutover und vollständige Abnahme bleiben offen; SC-2026-045
bleibt gesperrt. Details im
[TLS-Zielmetadatenvertrag](../Architecture/AUTHENTICATED_TLS_TARGET_METADATA.md).
