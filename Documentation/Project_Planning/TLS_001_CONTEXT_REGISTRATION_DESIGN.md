# TLS-001 – Client- und Signierkontexte registrieren

| Merkmal | Wert |
|---|---|
| Status | `DESIGN_PROPOSAL` mit privater Anfrage/Vorschau; keine Registry, dauerhafte Identitätsbindung oder Keyablage implementiert |
| Stand | 2026-10-16 |
| Grundlage | Ausgewählte [isolierte Lab-CA](TLS_001_ISOLATED_CA_DESIGN.md), private Anfrage- und Zielmetadatenverträge |
| Implementierter Teil | [Lesende .NET-API-Metadaten](../Architecture/AUTHENTICATED_TLS_BACKEND_METADATA.md) und [Windows-Kontextvorschau](../Architecture/AUTHENTICATED_TLS_CONTEXT_PREVIEW.md); keine Backend-/Clientqualifikation |

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
verlangt geklärte Ownership, Cleanup und Recovery. Der spätere Trustimport
behält seine eigene ausdrücklich freizugebende konkrete Preview aus D3.

Normales Run-Removal entfernt keine gemeinsamen Kontexte, CA oder Trustanker.
Retirement prüft registrierte Referenzen und erhält einen Tombstone; unbekannte
Nutzung blockiert Key-/Trustentfernung. Parallelität, Abbruch und fehlender
Commitnachweis bleiben sichtbar `RECOVERY_REQUIRED`, ohne automatisches
Adoptieren, Überschreiben oder Löschen vorhandener Records.

## Backend- und Keyschutzgrenze

Der Kandidat `DOTNET_X509` wird zunächst nur über sechs API-Signaturen geprüft.
Ein tatsächlicher CSR-Slice muss DER strikt begrenzen, vollständigen Verbrauch
und Signaturprüfung belegen sowie Extensions aus dem geschlossenen Labprofil
neu aufbauen. Keine Übernahme beliebiger CSR-Erweiterungen. Die dokumentierten
[Loaderoptionen](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequestloadoptions?view=net-10.0)
enthalten einen Schalter zum Überspringen der Signaturprüfung und einen zum
unsicheren Übernehmen von Extensions; beide sind für diese Lane ausgeschlossen.
Die aktuelle API-Präsenz belegt diese spätere Verarbeitung nicht.

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

Als Nächstes die geschlossene Registryrecordform, Größen-/Tiefegrenzen,
Referenz-/Revisionsinvarianten und Writer-/Crashgrenzen offline festlegen
und synthetisch prüfen. Noch keine native Registrierung oder Mutation.
Die Registrytransaktion folgt erst nach diesen festgelegten Grenzen;
CA-Keyschutz und konkrete Mutationsfreigaben bleiben separat.
Die bereits vorhandenen `ClientRef`-/`AuthorityRef`-Anfragen bleiben bis dahin
unaufgelöst. Native TLS-, Client- und Mindestlaufzeitabnahmen werden durch
diese Planung nicht ersetzt.
