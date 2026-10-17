# TLS-001 – Client- und Signierkontexte registrieren

| Merkmal | Wert |
|---|---|
| Status | `DESIGN_PROPOSAL` mit privater Anfrage/Vorschau; keine Registry, dauerhafte Identitätsbindung oder Keyablage implementiert |
| Stand | 2026-10-16 |
| Grundlage | Ausgewählte [isolierte Lab-CA](TLS_001_ISOLATED_CA_DESIGN.md), private Anfrage- und Zielmetadatenverträge |
| Implementierter Teil | [Lesende .NET-API-Metadaten](../Architecture/AUTHENTICATED_TLS_BACKEND_METADATA.md), [Windows-Kontextvorschau](../Architecture/AUTHENTICATED_TLS_CONTEXT_PREVIEW.md), [Offline-Referenzindex](../Architecture/AUTHENTICATED_TLS_REGISTRY_INDEX.md), [Vor-Key-Payloads](../Architecture/AUTHENTICATED_TLS_REGISTRY_PAYLOAD.md) und [Registry-Gesamtform](../Architecture/AUTHENTICATED_TLS_REGISTRY_DOCUMENT.md); keine Backend-/Clientqualifikation |

## Identitäten getrennt erhalten

`ClientRef` bezeichnet künftig einen ausdrücklich ausgewählten logischen
Ausführungskontext für die beiden SQL-Clientstacks. `AuthorityRef` bezeichnet
die logische Lab-CA innerhalb eines registrierten Vertrauensbereichs.
Ein zusätzliches `SignerContextRef` bezeichnet ihren kontrollierten
Signierkontext. `AuthorityRef` darf nicht unmittelbar als Benutzer-, Prozess-
oder Signierer-ID umgedeutet werden. Eine CA verweist auf genau einen
registrierten Signierkontext; ihre eigene Zertifikats-/Keygeneration bleibt
eine getrennte Revision. Kein Registryeintrag öffnet einen Key oder verändert
Trust. Die bestehenden kleinen D-UUIDs bleiben erhalten; IDs werden bei
Retirement reserviert und nie einem anderen Objekt neu zugeordnet.

Vorgeschlagene erste Ausführungslane: ausdrücklich ausgewählter Windows-
Benutzerkontext mit geladenem Profil, Hostbindung und CurrentUser/Root für
den Client. Service, Runner, Gast und anderer Host erhalten separate
Kontexte. Die API-Probe im aktuellen Prozess trifft diese Auswahl nicht.
Linux bleibt für echte Registrierung/Keyablage zunächst gesperrt, bis der
isolierte Trustkontext beider Clientstacks und ein eigener geschützter
Signierkontext konkret nachgewiesen sind. Die Metadatenprobe darf dort laufen.

## Eigene lokale Registry und Revisionen

Vorgeschlagen wird genau eine kontrollierte Registry unter dem ausdrücklich
registrierten `Lab_Data/State/authenticated-tls` je Controller/Root. Sie liest
keine freien StateRoots oder globalen Konfigurationen. Bestehende Root-,
Controller-, Location- und Volume-Verträge bleiben die Metadatenbasis;
Host-/Ausführungsbindung muss frisch nativ ergänzt werden. Kopierte Marker
beweisen keinen unveränderten Host. Schreibrechte auf Metadaten sind keine
kryptographische Attestation und keine Autorisierung gegen lokale Administratoren.

Vorläufiger Contract: `SqlServerLab.AuthenticatedTlsContextRegistry/0.1`.
Geschlossene Records ohne Duplicate Keys, begrenzte Bytes/Tiefe/Anzahlen und
ein atomar serialisierter Writer sind vor Implementierung festzulegen und
synthetisch mit Crash-/Parallelitätsfällen zu prüfen. Der minimale Recordumfang:

| Record | Gebundene Daten; ausschließlich lokal |
|---|---|
| Client | `ClientRef`, Generation, Controller/Root-/Hostbindung, native Ausführungsidentität, ausgewählter Profil-/Storekontext, beide konkreten Stackbinaries und deren Digests |
| Signierkontext | `SignerContextRef`, Generation, Controller/Root-/Hostbindung, native Ausführungsidentität, expliziter Backend-/Keyschutztyp, opaque Keyhandle bei späterer Keyanlage |
| CA | `AuthorityRef`, Trustbereich, Verweis auf `SignerContextRef` und dessen Generation; später öffentliche CA-Digests, Gültigkeit und getrennte Key-/Zertifikatsgeneration |

Pfade sind Lokatoren, Binärdigests und Generationen binden Revisionen. SID,
native Hostbindung und ausgewählter Zweck werden nicht aus Anzeigenamen,
Umgebungsvariablen oder Administratorgruppenmitgliedschaft abgeleitet.
Eine tatsächliche Änderung der Ausführungsidentität erzeugt eine neue
Kontextidentität. Binär-/Backend-/Trustkontextänderungen benötigen eine neue
Revision und sperren die alte Qualifikation. Bestehende IDs werden nicht
still neu belegt. Öffentliche Ergebnisse projizieren nur feste Statuscodes;
SID, Profile, Locatoren und Hashes privater Metadaten bleiben lokal.

Die Registrierung beginnt mit einer konkreten Kontextvorschau und bewusster
Auswahl im aufrufenden Workflow. Die notwendige Autorität kann bereits aus
dem konkreten Auftrag stammen; diese Planung fordert keinen zusätzlichen
Dialog für jede gewöhnliche Metadatenaktion. Eine generische Discovery oder
Caller-UUID ersetzt jedoch keine tatsächliche Kontextwahl. Registryanlage
verlangt geklärte Ownership, Cleanup und Recovery. Der separate Trustimport
behält seine eigene ausdrücklich freizugebende konkrete Preview aus D3.

Normales Run-Removal entfernt keine gemeinsamen Kontexte, CA oder Trustanker.
Retirement prüft registrierte Referenzen und erhält einen Tombstone; unbekannte
Nutzung blockiert Key-/Trustentfernung. Parallelität, Abbruch und fehlender
Commitnachweis bleiben sichtbar `RECOVERY_REQUIRED`, ohne automatisches
Adoptieren, Überschreiben oder Löschen vorhandener Records.

## Konkretisierter Writer-/Crashvertrag – noch nicht implementiert

Der [Offline-Index](../Architecture/AUTHENTICATED_TLS_REGISTRY_INDEX.md) legt
jetzt geschlossene Referenzrecords, Grenzen und gültige Übergänge fest.
Er ist ein eigener Teilvertrag, keine vollständige persistierbare Registry.
Die geplante `AuthenticatedTlsContextRegistry/0.1` behält ihre vollständigen
privaten Payloads: native Identität, Profil-/Store-/Backend-/Binärmetadaten
und später Key-/Zertifikatsrevisionen. Die geschlossenen Metadatenpayloads
vor Keyanlage, kanonische Digestbildung und intern frische Prozessbindung
sind implementiert und synthetisch geprüft. Die Registry-Gesamtform prüft
jetzt auch die exakte Index-/Payload-/Digestzuordnung und vollständige
Dokumentübergänge. Die [lesende Rootbindung](../Architecture/AUTHENTICATED_TLS_REGISTRY_ROOT.md)
prüft jetzt die bestehende Registrydatei gegen registrierte Windows-Rootmetadaten;
keine atomare oder native Host-/Actorqualifikation. Writer und Zugriffsschutz fehlen noch.
Indexdigests allein dürfen nicht als geprüfte Payloads gelten; Key-/
Zertifikatsdaten behalten ihren späteren eigenen Vertrag.

Vorgeschlagene erste Writerlane: genau der registrierte lokale Windows-Root,
keine Netzfreigabe, keine Pfadadoption und keine globalen Konfigurationen.
Vor jeder Aktion müssen Ownership, private Ablage-/Zugriffsgrenze, Frische
der Ausführungsbindung und genaue Metadatenautorität feststehen. Ein Prozess
hält einen exklusiven, rootgebundenen Writerlock mit begrenzter Wartezeit.
Nach Locknahme liest und validiert er den tatsächlichen vollständigen
Ausgangsstand neu. Revision allein genügt nicht: erwartete Quellbytes und
deren Digest sowie alle Root-/Controller-/Actorbindungen müssen passen.
Alle kooperierenden Writer verwenden dieselbe Autorität; die Sperre schützt
nicht gegen Administratoren oder fremde, nicht kooperierende Dateischreiber.

Der geplante Ablauf ist strikt geordnet: frische native Bindung und Quellcheck,
privater dauerhafter Intent mit Transaktions-ID, eigene begrenzte Kandidatdatei
im selben Volume, vollständige Kandidatenprüfung, Flush, erneuter Quellcheck
unter Lock, atomarer Ersatz, unabhängiges Rücklesen und dauerhafter Commitbeleg.
Erst danach wird ein Erfolg projiziert oder eine Referenz veröffentlicht.
Kein Append-/Overwrite-Fallback bei fehlender Dateisystemfähigkeit. Der konkrete
Windows-Lock-/Flush-/Ersatzmechanismus samt Haltbarkeit ist noch zu wählen und
empirisch zu prüfen; der Offline-Übergangsvalidator implementiert dies nicht.

| Unterbrechungsgrenze | Geplante Behandlung; keine ausgeführte Recovery |
|---|---|
| Vor durablem Intent | Kein reservierter/veröffentlichter Record; kein Registryersatz |
| Intent vorhanden, Kandidat fehlt oder ist unvollständig | `RECOVERY_REQUIRED`; ausschließlich belegte eigene Transaktionsartefakte prüfen, keine breite Suche oder Löschung |
| Kandidat geprüft, Ersatz noch nicht begonnen | Abweichender Ausgangsdigest sperrt; kein automatisches Überschreiben eines neueren Standes |
| Ersatz begonnen oder erfolgt, Commitbeleg fehlt | Ergebnis bleibt unklar; kein Erfolg oder blindes Wiederholen. Exakte Quell-/Kandidatenbytes, Intent, Root-/Actorbindung und tatsächlicher Stand müssen unter Lock aufgeklärt werden |
| Dauerhafter Commitbeleg vorhanden | Erfolg nur nach passendem Rücklesebefund; abweichender Zustand bleibt `RECOVERY_REQUIRED` |

Intents müssen einmal reservierte Referenzen erhalten; Abbruch gibt keine
bereits registrierte oder veröffentlichte ID zur Wiederbelegung frei. Cleanup
betrifft nur exakt eigene registrierte Transaktionsartefakte. Unbekannte
Referenzen oder Nutzungen blockieren Retirement und Key-/Trustentfernung.
Der Index prüft nur das vorgeschlagene Tombstoneformat, keinen tatsächlichen
Referenzbestand. Native Lock-, Crash-, Parallelitäts-, Flush-, Recovery- und
Cleanupnachweise fehlen vollständig und gehören zum späteren Writerscope.

## Backend- und Keyschutzgrenze

Der Kandidat `DOTNET_X509` wird zunächst nur über sechs API-Signaturen geprüft.
Der [private CSR-Slice](../Architecture/AUTHENTICATED_TLS_LEAF_CSR.md) begrenzt
DER strikt, belegt vollständigen Verbrauch und echte RSA-3072-/SHA-256-
Signaturprüfung und baut Extensions aus dem geschlossenen Labprofil neu auf.
Keine Übernahme beliebiger CSR-Erweiterungen. Die dokumentierten
[Loaderoptionen](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequestloadoptions?view=net-10.0)
enthalten einen Schalter zum Überspringen der Signaturprüfung und einen zum
unsicheren Übernehmen von Extensions; beide sind für diese Lane ausgeschlossen.
Die eigene native Tempfixture prüft diese Kryptoverarbeitung; die frühere
API-Präsenz allein belegt sie nicht. Native Target-/SQL-Fähigkeit bleibt offen.

Der bestehende [`SecretProvider.ps1`](../../Private/SecretProvider.ps1) ist
kein ausgewählter CA-Keyprovider: Er besitzt einen Windows-LocalMachine-
Fallback und eine Linux-Base64-Ablage mit Dateirechten. Diese Produktverträge
bleiben erhalten. Für die CA braucht es einen eigenen Schutzvertrag ohne
stille Erweiterung des Ausführungs-/Entschlüsselungskreises. Ein fehlendes
Benutzerprofil oder fehlender Keyschutz blockiert die Signierlane.
Konkrete Container-/ACL-/Recovery- und Schlüsselablageverfahren werden vor
Keyanlage entschieden und abgenommen; aus API-Präsenz entsteht keine Freigabe.

Windows-SQL-Leaves behalten ihre gesonderten CSP-/KeySpec-/Dienst-ACL-
Anforderungen. Ein auf dem Host vorhandener RSA-Konstruktor belegt diese
Targetfähigkeit nicht. Linux-Dateirechte, targetlokale Keyerzeugung, CSR-
Transport, exakter Runtimebesitz und getrennte Docker-/Podman-/Hyper-V-
Abnahmen bleiben die entsprechenden nachfolgenden Verträge.

## Implementierte Vorschau und nächster begrenzter Scope

Der private geschlossene Kontextantrag und die lesende Windows-Kontextvorschau
sind implementiert. Genau `CURRENT_WINDOWS_PROCESS` ist auswählbar. Native
Token-, Profil-/Hive- und lokale Hostmarkermetadaten sowie beim Client die
bereits geladene SqlClient-Assembly und erste sqlcmd-Application werden
beobachtet. Diskdigests messen kein geladenes Image; sqlcmd-Flavor und ODBC-
Treiber bleiben unqualifiziert. Fehlende Werte sperren den Gesamtbefund.
Referenzen bleiben unregistriert, `Ready` und `MutationAllowed` false.
Noch keine Registrywrites oder Key-/Storeöffnung.

Der geschlossene Offline-Referenzindex mit Byte-/Tiefen-/Recordgrenzen und
unveränderlichen Rollen, Identitätsangaben und Tombstones ist implementiert.
CA-Signierkanten und Generationen werden geprüft. Der Writer-/Crashvertrag
oben ist Planung; reine konkurrierende Kandidaten sind kein nativer Raceproof.
Die privaten Vor-Key-Payloadformen, kanonischen Inhaltsdigests und intern
frische Prozessbindung sind implementiert; die neue Suite verwendet nur
synthetische Bytes und gemockte native Vorschauen. Eine getrennte direkte
Windows-Beobachtung bestätigte beide Kontext- und die CA-Signiermetadatenbindung
mit synthetischen Referenzen. Root und Trustscope bleiben unaufgelöst,
vollständige Binderqualifikation und spätere Key-/Zertifikatsrecords offen.
Die geschlossene Registry-Gesamtform mit vollständiger Payload-/Index-/
Digestzuordnung und Dokumentübergängen ist offline implementiert und
synthetisch geprüft. Die lesende Windows-Rootbindung mit fester Registrydatei
ist implementiert und an eigenen synthetischen Files geprüft. Die private
Registrytransaktion mit frischer Kontextbindung, privatem Zugriffsschutz und
nativen Crash-/Parallelitätsfällen gemäß obigem Vertrag bleibt offen.
Vorgezogen ist der [Windows-CA-Kandidat](../Architecture/AUTHENTICATED_TLS_CA_CANDIDATE.md)
mit eigenem geschütztem DPAPI-Key und lesender Trust-Vorschau; eigene
Tempfixtures liefern lokale native Kryptoevidence. Der Kandidat ist
ausdrücklich `UNREGISTERED_UNQUALIFIED` und umgeht keine Registrytransaktion.
Keine automatische Pfadadoption, native Registrierung oder Trustmutation.
Operativer CA-Keyschutz und konkrete Mutationsfreigaben bleiben separat.
Der getrennte [private Trustimport](../Architecture/AUTHENTICATED_TLS_TRUST_IMPORT.md)
ergänzt jetzt eigene geschützte Freigabe-/Intent-/Commitdateien außerhalb des
Kandidaten und lesenden Status. Er ist kein allgemeiner Registrywriter und
registriert keine AuthorityRef oder CA. Ein eigener dauerhafter Kandidat und
seine konkrete gesicherte menschliche Importfreigabe existieren; die native
Storemutation ist durch die injizierten Storetests weiterhin nicht ausgeführt.
Der separat geprüfte echte Worker wurde einmal nach 60 Sekunden beendet:
frisch lesend CA `ABSENT`, Journal `RECOVERY_REQUIRED`, passender gültiger
Intent ohne Commit/Lock, kein bestätigter Import. UI-Wahl: kein Dialog sichtbar, sichtbares Fenster nach geprüfter Recovery gewünscht;
kein automatischer Retry oder Journalremove. Der private CSR-Slice benötigt keinen Store,
registriert keine AuthorityRef und liefert nur ein öffentliches unqualifiziertes
Leaf. Fester synthetischer Subject und enges Attributset qualifizieren keinen
Windows-certreq-/CSP-/KeySpec-/SQL-Request.
Die bereits vorhandenen `ClientRef`-/`AuthorityRef`-Anfragen bleiben bis dahin
unaufgelöst. Die [private einmalige Trust-Recovery](../Architecture/AUTHENTICATED_TLS_TRUST_RECOVERY.md)
ergänzt eigene Records außerhalb der Kandidatendateien und erhält Originalowner,
Preview und Intent unverändert. Sie ist kein Registrywriter, kein allgemeines
Rearm und kein Ersatz für tatsächliche Human-/UI-/Workerprüfung im Adapter.
Ihre spätere [native sichtbare Ausführung](../Quality/TLS_CA_TRUST_ACCEPTANCE_2026-10-16.md)
bestand mit Exitcode 0, frischem exaktem Trust, `RECOVERY_IMPORT_RECORDED`
und unverändertem Originalintent, ohne ursprünglichen Commit oder verbleibenden Lock.
Die spätere [begrenzte Windows-Probe](../Quality/TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
belegt beide positiven strikten SQL-Clientstacks sowie .NET-Gegenfälle und eigenen
Cleanup. Die [anschließende Ablauf-/Erneuerungsprobe](../Quality/TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
bestand mit unvertrauter Kette, echtem Ablauf, falschem SAN und Erneuerung
mit neuem Key für beide Windows-Stacks. Vollständige Matrix und qualifizierter
Export bleiben offen; keine Registrierung oder zusätzliche Ausführungsautorität.
Die separate [Podman-Probe](../Quality/TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md)
bestand ebenfalls alle acht Windows-Clientfälle für SQL 2025 CU9 samt eigenem
Cleanup und Schutzvergleich. Die spätere [Container-Versionsmatrix](../Quality/TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle separat mit Docker und Podman für
SQL 2019 CU32 und SQL 2022 CU27 samt eigenem Cleanup und frischem Schutzvergleich.
Linuxclients, Hyper-V, operative Registry und Export sind dadurch nicht belegt.
Die spätere [Linux-Clientfähigkeitsprobe](../Quality/TLS_LINUX_CLIENT_CAPABILITY_2026-10-16.md)
beobachtete nur PowerShell, SqlClient-Konstruktion mit lokalem Netzwerkfehler
und den ersten sqlcmd-Hilfeaufruf im eigenen isolierten Namespace. Keine
CA-Datei, Truständerung oder SQL-Abfrage; alle eigenen Fixtures entfernt.
Das implementiert keinen Linux-Kontextselektor, Registryrecord oder TLS-Nachweis.
Der spätere [freigegebene Trustversuch](../Quality/TLS_LINUX_TRUST_ATTEMPT_2026-10-17.md)
scheiterte vor TLS an `chown` ohne Capabilities. Eigene Ressourcen und
temporäre Secretdatei sind entfernt; Abwesenheit und Schutzvergleiche frisch
bestätigt. Eine neue Vorschau plant Dateianlage durch UID 10001 ohne zusätzliche
Privilegien. Die verbrauchte Freigabe erlaubt keinen zweiten Client;
Kontextregistrierung und Linux-TLS bleiben offen.
Der [separat freigegebene UID-Nachfolger](../Quality/TLS_LINUX_DIRECT_UID_PARTIAL_ACCEPTANCE_2026-10-17.md)
belegte inzwischen direkte UID-Dateianlage und eine strikte CLR-SQL-Verbindung.
ODBC lehnte den als positiv geplanten IP-SAN-Fall wegen Namensabweichung ab.
Eigener Cleanup und Schutzvergleiche bestanden. Kein geladener ODBC-Nachweis,
Trustentzug/-wiederherstellung oder Registryrecord; die neue `DNS localhost`-
Vorschau benötigt eigene Freigabe und gebundene Quellen.
Referenzen bleiben weiterhin
unaufgelöst. Native TLS-, Client- und Mindestlaufzeitabnahmen werden durch
diese Planung nicht ersetzt.
## CU-Metadatenbindung am 2026-10-17

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
