# FSF-05 – Freigegebenes Sicherheitsmodell für getrennte OS-/SQL-Identitäten

| Merkmal | Wert |
|---|---|
| Status | `SECURITY_MODEL_APPROVED` – Sicherheitsmodell freigegeben |
| Entwurf | `FSF-05`, Revision `0.1`, Stand 2026-10-11 |
| Freigabe | ausdrücklich durch den Repository-Eigentümer am 2026-10-11 |
| Grundlagen | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md) Revision `0.2`; [FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md), [FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md) und [FSF-04](FILESYSTEM_FIXTURE_OWNERSHIP_CLEANUP_DRAFT.md) jeweils Revision `0.1`, ausdrücklich freigegeben am 2026-10-11 |
| Anforderungsquelle | [Fixture-Verwaltungs-Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md); eigenständige manuelle und automatisierte Benutzeranlage, Dateien optional |
| Repositorybasis der Bestandsanalyse | `a6b5a6b3`; keine Fixture-Implementierung oder native Sicherheitsevidence |
| Autorität | freigegebenes Sicherheitsmodell; keine Implementierungs-, Benutzeranlage-, Secret-, Konfigurations-, Sitzungsbeendigungs- oder Löschfreigabe |

E1 bis E10 wurden ausdrücklich freigegeben. FSF-01 bis FSF-05 sind
freigegeben; FSF-06 bleibt offen. Die FSF-05-Freigabe erlaubt noch keinen
Implementierungsbeginn. Die Begriffe unten beschreiben
Entwurfsanforderungen, keine bereits vorhandenen APIs, Stores oder Fähigkeiten.

## 1. Schutzbereich, Akteure und Vertrauensgrenzen

Das Lab stellt synthetische, nicht privilegierte Szenarioidentitäten in genau
einem ausdrücklich ausgewählten, bereits laufenden verwalteten SQL-Labziel
bereit. OS-Konto, SQL-Login und gemappter Datenbankbenutzer bleiben getrennte
Ressourcen. Mehrere Benutzer sowie manuelle Schulungen und Rekonstruktionen
sind vorgesehen; weder ein Testexecutor noch eine Dateisystem-Fixture ist nötig.

| Akteur oder Grenze | Annahme und Schutzpflicht |
|---|---|
| Lokaler Betreiber | Authentisierter Host-OS-Benutzer kontrolliert den vertrauenswürdigen Koordinator, seine Schlüssel und die konkrete Operationsfreigabe. Ein deklarierter Owner-/Consumername ist keine Authentisierung. |
| Consumer auf dem Host | Vertrauenswürdiger Aufrufer innerhalb derselben Betreiber-Sitzung; strukturierte Requests können trotzdem fehlerhaft, manipuliert oder veraltet sein. Keine Betreibercredentials an Szenariotests weitergeben. |
| Szenariobenutzer im Gast/Container beziehungsweise SQL | Potenziell untrusted; darf nur sein qualifiziertes nicht privilegiertes Profil nutzen. Manipulierte Dateien, Links, Rechte, offene Sitzungen und SQL-Eingaben dürfen keine zusätzliche Koordinatorautorität erzeugen. |
| Andere Hostbenutzer und Datensatzkopien | Geschützte lokale Grenzen plus authentisierte Verschlüsselung verhindern Lesen/Ändern ohne Schlüssel; fremde Handle-/Storekopien autorisieren nichts. |
| Transport und Ziel | OS-Zugang an VM-ID beziehungsweise Runtime-Endpunkt/full Container-ID gebunden; SQL-Kanal authentisiert denselben zuvor gebundenen Dienst. Ein erreichbarer Port reicht nicht. |
| Privilegierte Infrastruktur | Hostadministrator/root, Hypervisor-/Runtimeadministration, Gastadministrator/root und SQL-sysadmin gehören zur vertrauenswürdigen Basis. Ihre Kompromittierung ist außerhalb der Sicherheitsgarantie. |

Beliebiger Code unter dem Host-OS-Konto des Betreibers, Speicherdumps durch
privilegierte Akteure, kompromittierte Images/Helper/SqlClient sowie vollständiger
Host-Rollback einschließlich Schlüsseln und Fortschrittsanker sind ebenfalls
außerhalb der Garantie. Das Modell schafft keine Prozessisolation zwischen
zwei Programmen desselben Hostbenutzers und keine allgemeine Sandbox für
Schulungscode. Untrusted Szenariocode läuft unter den Szenarioidentitäten.
Ein erkanntes Verlassen dieser Annahmen sperrt weitere Fixture-Mutationen;
es erlaubt keine automatische Reparatur oder Adoption.

## 2. Autorisierung, Zielbindung und feste Operationen

Der erste Umfang verwendet ausschließlich lokale vertrauenswürdige
Koordinatoraufrufe in der authentisierten Betreibersitzung. Neue HTTP-, Browser-,
Remote- oder allgemeine IPC-Endpunkte sind nicht Teil dieser Freigabe.
Bestehende Workflow-UI-Capabilities ersetzen weder diese Sitzung noch die
konkrete Zustimmung. OS- und SQL-Betreiberzugänge bleiben interne Labzugänge;
fehlende Rechte werden nicht durch Installation, Elevation oder Policyänderung
beschafft. Der Koordinator prüft die vorhandenen Rechte für jeden Adapter.

Die getrennte Freigabe aus FSF-03 bindet die tatsächliche Betreiberidentität,
Consumer-/Run-/Storekontext, Zielgeneration, Aktion, ausgewählte ResourceRefs,
ExpectedInventoryRevision, Profile, Retention, Kompensation und Frist an genau
den zuvor geprüften Plan. Keine Wildcardfreigabe, freie Statewurzel, freie SQL-
oder Shellvorlage, automatische Plananpassung oder implizite Cascade. Auch
automatisierte Szenarien benötigen diese begrenzte Autorisierung; ein Handle
oder RequestRef bleibt kein Bearercredential.

Der Koordinator registriert die Freigabe privat mit kryptografisch zufälliger
Operationsreferenz. Annahme und Verbrauch erfolgen einmal unter der
Scope-/Lifecycle-Reservierung und vor Zielmutation. Ein wiederholter Request
darf nur den gebundenen Status beobachten. Bereits angenommene Operationen
dürfen innerhalb ihrer festen Deadline die vorab genehmigten Schritte und
Kompensationen fortsetzen; ein verbrauchter oder abgelaufener Grant autorisiert
keinen neuen Plan. Kein erneutes Mutieren nach unklarem Dispatch.

Alle Lifecyclepfade müssen dieselbe Reservierung respektieren. Ein privates
Fixture-Lock allein genügt nicht. Vor jedem mutierenden Schritt werden native
Zielbindung, Eigentum, effektive Rechte und frisches authentisiertes SQL-READY
erneut geprüft; dies gilt auch für OS-only und Cleanup. Ausschließlich
VM-ID-gebundenes PowerShell Direct beziehungsweise gepinntes Docker-/Podman-
Exec; kein WinRM-Fallback, TrustedHosts, privileged Container, Hostnamespace,
Runtime-Socketmount oder Providerwechsel.

## 3. Geschützte Records, Schlüssel und Rollback

Private Records und Secrets werden mit unabhängigen zufälligen 256-Bit-
Schlüsseln je Run-/Storegeneration und Zweck geschützt. Vorgeschlagen ist
AES-256-GCM mit 12-Byte-Nonce und 16-Byte-Tag aus einer qualifizierten vorhandenen
Frameworkimplementierung. Authentisierte Zusatzdaten binden die Version,
Schlüsselkennung, Zweck, Controller-/Store-/Owner-/Run-/Zielgeneration,
Ressourcenreferenz, Revision und Journalfolge. Der Decoder akzeptiert nur
begrenzte eindeutige Formate; doppelte/unbekannte Felder werden abgelehnt.
Ein einfacher Hash, opaque ID oder ACL allein ersetzt diesen Schutz nicht.
Die konkrete vorhandene .NET-/OS-Kombination muss qualifiziert werden; kein
stiller Algorithmusfallback oder Frameworkupgrade. Grundlage sind
[Microsoft AesGcm](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.aesgcm?view=net-8.0)
und [OWASP Cryptographic Storage](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html).

| Hostprofil | Schutz der zufälligen Datenschlüssel |
|---|---|
| Windows | Wrapping über vorhandenes DPAPI `CurrentUser`, gebunden an diesen Betreiber und Host; kein `LocalMachine`-Fallback. Verschlüsselte Schlüsseldateien nur im ignorierten gebundenen Run-Scope. |
| Linux | Explizites Sitzungs-Unlock mit maskierter eigener Schlüsselpassphrase: 20 bis 128 Zeichen, keine Szenariopasswörter. KEK über PBKDF2-HMAC-SHA-256 mit mindestens 600.000 Iterationen, zufälligem 32-Byte-Salt und versionierten Parametern; zufällige Datenschlüssel authentisiert wrappen, nur verschlüsselt im ignorierten Run-Scope speichern. |
| Unattended | Nur ein separat qualifizierter, bereits verfügbarer Secretprovider mit passender Owner-/Host-/Runbindung darf Unlock ersetzen. Ohne diesen bleibt unattended blockiert; automatisierte Tests innerhalb einer entsperrten Betreibersitzung sind vorgesehen. |

Weder Passphrase noch rohe Schlüssel werden neben den Records, in argv,
Environment, Konfiguration oder Klartextdateien persistiert. Linux-Mode `0600`
und Base64 sind kein Ersatz für Wrapping. DPAPI schützt nicht den Transport
und kann bei Verlust des Benutzerkontexts unzugänglich werden. Die
[DPAPI-Dokumentation](https://learn.microsoft.com/en-us/windows/win32/seccrypto/example-c-program-using-cryptprotectdata)
begründet die Benutzerbindung; der KDF-Mindestwert folgt der
[OWASP-Empfehlung](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Dies ist eine Projektentscheidung zur Schlüsselableitung, keine Behauptung
über FIPS-Zertifizierung oder unbegrenzte Passphrasesicherheit.

Ein separater lokaler Fortschrittsanker im geschützten Betreiber-Control-Scope
außerhalb kopierbarer Lab_Data-/Run-Datensätze hält Controller-/Storegeneration,
Schlüsselkennungen, Nonce-Hochstände, Journal-Commitfolge, Grantverbrauch und
den kompakten Nichtwiederverwendungsindex. Er enthält keine Secrets, nativen
Zielwerte oder Rohdaten. Seine Integrität und Schreibexklusivität müssen mit
vorhandenen OS-Mitteln gegen andere Hostbenutzer belegt sein; ein frei wählbarer
Ankerpfad ist unzulässig. Dieser Hostzustand ist geplant, derzeit nicht vorhanden.

Vor jeder Verschlüsselung wird ein pro Schlüssel eindeutiger 96-Bit-Zählerwert
unter exklusiver Reservierung dauerhaft im Anker verbraucht. Lücken sind
zulässig; Wiederverwendung, Überlauf oder Zurücksetzen mit demselben Schlüssel
sind unzulässig. Dauerhaftigkeit umfasst Flush und atomare Veröffentlichung
auf qualifiziertem lokalen Storage. Unbekannte Dauerhaftigkeit blockiert.
Ein Crash nach Nonceverbrauch darf höchstens eine Lücke hinterlassen.
Auch Linux-Wrapping verlangt Nonceeindeutigkeit; jede neue Schlüsselhülle
erhält einen frischen Salt und separat abgeleiteten KEK. Keine Wiederverwendung
alter Hüllenparameter für veränderte Schlüsselwerte.

Record- und Ankerupdate sind keine gemeinsame Transaktion. Vorabintent,
Commitfolge und Recorddigest werden abgestimmt geführt; jede Crashlücke oder
Abweichung bleibt `UNCERTAIN` mit gehaltener Reservierung. Ein älterer gültig
authentisierter Record passt nicht zum aktuellen Anker und erlaubt keine
Mutation. Fehlender Anker/Schlüssel, unbekannter KeyId, Storekopie, Migration
oder bekanntes Restore werden nicht durch Neugenerieren und Übernahme alter
Ressourcen geheilt. Keine automatische Schlüsselrotation im ersten Umfang.

Ein lokaler Anker erkennt keinen vollständigen gemeinsamen Rollback von Host,
Anker und Schlüsseln. Ein MAC beweist ebenfalls keine native Konto- oder
Datenbankgeneration. Ohne separat qualifizierten externen monotonen Anker
gibt es keine solche Garantie; externe Anker/TPM und Restoremigration gehören
nicht zum ersten Umfang. Diese Grenze muss bei jeder späteren Abnahme sichtbar
bleiben; bekannte Restoreereignisse sperren die Fortsetzung.

## 4. Secrets, Zugang und authentisierte SQL-Verbindungen

OS-Passwort und SQL-Passwort sind unabhängig. Generierte Szenariopasswörter
enthalten 32 kryptografisch zufällig gewählte Zeichen und erfüllen zusätzlich
die unveränderte native Passwortpolicy. Manuell gewählte Passwörter werden
maskiert erfasst, umfassen 20 bis 128 Zeichen und müssen ebenfalls jede native
Policy erfüllen; keine stille Kürzung, Normalisierung oder Abschwächung.
Eine stärkere Zielpolicy gewinnt. Linux-Exec-/numerische Profile benötigen
kein Passwort; Passwort-/SSH-Login bleibt dort außerhalb des ersten Umfangs.

Für manuelle Windows-/SQL-Anmeldung kann der Betreiber das zuvor maskiert
gewählte Passwort im bereits vorhandenen qualifizierten Client selbst eingeben.
Der separate lokale Zugang liefert nur die erforderlichen privaten Namen,
Datenbank-/Zielbindung und Nutzungsroute. Generierte Secrets werden ausschließlich
einem vorab qualifizierten authentisierten Credentialkanal im Speicher
übergeben. Ohne diesen bleibt diese Zugangsvariante blockiert; allgemeine
Pipelineausgabe, Passwortanzeige, Clipboard, Browserstorage, argv, `sqlcmd -P`,
Environment und temporäre Klartextdateien sind ausgeschlossen.

Automatisierte Nutzung erhält ebenfalls nur das ausgewählte Szenariocredential
für denselben Ziel-/ResourceRef-/Operationskontext. Keine SA-, Gastadmin- oder
Runtimecredentials an Consumer oder Szenariotests. Secretabruf ist separat
autorisiert, kurzlebig und einmalig; native Passwörter werden dadurch weder
automatisch geändert noch ungültig. Eigene Passwortänderung im Szenario kann
den gespeicherten Zugang veralten lassen: Drift melden, keinen Reset erzwingen.
SecureString ist nur ein Eingabemittel, keine Garantie für verschlüsselten
Prozessspeicher. Buffer werden soweit möglich freigegeben; Managed-Strings,
Clientinternals und privilegierte Dumps begrenzen die Zusage.

Für Betreiberprobe, SQL-Anlage und Szenarioclient gilt explizite TLS-
Verschlüsselung mit Serverauthentisierung: `Encrypt=Mandatory` und
`TrustServerCertificate=False` im qualifizierten SqlClient. Zulässig sind
vorhandene vertrauenswürdige Zertifikatskette mit korrekter Namensbindung oder
ein über einen unabhängigen geschützten Kanal vorab gebundenes Serverzertifikat
mit nachgewiesener Pinprüfung in der konkreten Treiberversion. Kein TOFU,
beliebiger Callback, Trust-Override oder stiller Fallback. TLS und native
Zielgeneration sind getrennte Prüfungen; ein Zertifikat allein beweist kein
Lab-Ownership. Zertifikatsinstallation, Truststore-/SQL-Konfigurationsänderung
oder neuer Netzwerkkanal werden nicht durch die Fixtureverwaltung ausgeführt.
Fehlt der vorhandene qualifizierte Kanal, blockiert auch OS-only-Admission.
Die Anforderungen folgen der
[SqlClient-Dokumentation](https://learn.microsoft.com/en-us/sql/connect/ado-net/encryption-and-certificate-validation?view=sql-server-ver17);
versionsabhängige Pins müssen separat getestet werden.

## 5. Effektive Rechte, Injection und Identitätsgeneration

Vorlagen sind geschlossen und versioniert: typisierte begrenzte IDs,
festgelegte Aktionen, parametrisierte SQL-Werte und korrekt quotierte native
Identifier. Kein freies SQL, Shellfragment, Commandtext oder Pfad aus dem
Request. Secretwerte dürfen nicht in erzeugtem Commandtext, Helperstdout,
SQL-Fehlermeldungen oder Transcript persistiert oder ausgegeben werden.
Unvermeidbare native Klartextverarbeitung erfolgt nur kurzzeitig im privaten
authentisierten Ausführungskanal und im vertrauenswürdigen Ziel. Parametrisierte
Werte sind zu bevorzugen; unvermeidbare native Passwortsyntax bleibt in diesem
Kanal und benötigt einen belegten logfreien Pfad. Keine Shellinterpolation oder
Passwortübergabe als Prozessargument. Eine Bibliothek beziehungsweise native
Eingaberoute, die dies nicht sicher ermöglicht, ist nicht qualifiziert.

Windowskonten bleiben lokale Nichtadministratoren mit eigenen SID-Bindungen;
keine Administratorgruppe, Systemprivilegien oder neue RDP-/Anmelderechte.
Linuxkonten/numerische Kontexte bleiben in bestehenden Namespace-/UID-/GID-
Grenzen ohne sudo, Capabilities, Host-Subuidänderung oder privilegierte Gruppen.
Kontodatenbankhelper müssen anhand vorhandener Version und Konfiguration
qualifiziert sein: NSS, Hooks, Backups, Home, Gruppen und Seiteneffekte sind
begrenzt nachzuweisen. Kein vollständiges SAM-/passwd-/shadow-Backup als
Fixturejournal und keine globale Rücksetzung.

SQL-Profile erlauben ausschließlich FSF-02-Verbindung, Objektlesen, ausgewählte
DML und negative Objektzugriffe auf vorher qualifizierten vorhandenen
Labobjekten. Effektive Rechte umfassen `public`, `guest`, Rollen, vererbte
OS-Gruppen/ACLs, Ownershipketten, Views und DML-Trigger. Signierte Module,
`EXECUTE AS`, externe Effekte oder Trigger können eine scheinbar kleine DML-
Berechtigung erweitern: ohne nachgewiesenen Profilrahmen blockiert das Objekt.
Keine freien DDL-/EXECUTE-/Impersonationrechte, db_owner, sysadmin oder
Änderung fremder Principals/Objekte zur Herstellung eines negativen Tests.
Ein reines GRANT-/DENY-Inventar beweist die effektive Grenze nicht.

SID/UID, principal_id, Pfad, Zeitstempel und selbst angelegte Marker sind keine
universellen unveränderlichen Geburtstoken. Zulässiger Generationsnachweis
verknüpft eigene bestätigte Erzeugung, ununterbrochene Ziel-/Namespacebindung
und eine qualifizierte native Inkarnationsprüfung beziehungsweise nachweislich
ausschließlich koordinierte Identitätsänderungen innerhalb des Vertrauensmodells.
Die konkreten Backendkombinationen müssen zeigen, wie Löschung/Neuanlage,
Dienst-/Datenbankrestore, Containerersetzung und UID-/Principal-Wiederverwendung
erkannt oder innerhalb ihrer geprüften Grenze ausgeschlossen werden.

Fehlt dieser Nachweis, ist die betreffende Capability blockiert. Ein Hash
beobachteter Kontoattribute oder MAC über den Record schließt Wiederverwendung
nicht aus. Unbekannte/externe Änderung beendet die Kette; kein automatisches
Adoptieren, Rebinding oder Entfernen der Ersatzressource. Ein Adminangriff
kann innerhalb gleicher IDs unsichtbar sein und liegt außerhalb der Garantie;
das wird nicht als universell gelöst dargestellt. FSF-06 entscheidet anhand
getrennter nativer Evidence, welche Kombination diesen Vertrag tatsächlich trägt.

## 6. Laufende Nutzung und Rennen beim Cleanup

FSF-04 bleibt unverändert: kein KILL, ForceLogout, Prozesskill, automatisches
Deaktivieren oder Passwortwechseln. Aktive oder unbekannte Nutzung blockiert
Cleanup. Ein Broker darf neue eigene Zugangshandoffs stoppen; er kann bereits
ausgegebene Passwörter, SSMS-Verbindungen, Pools oder OS-Sitzungen dadurch
nicht zurückrufen. SQL kann Identitätsinformationen in offenen Verbindungen
zwischenspeichern; Rechte-/Loginänderung beendet nicht alle Verbindungen.
Siehe [Microsoft ALTER LOGIN](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-login-transact-sql?view=sql-server-ver17).

Ein positiver Quieszenzbeleg benötigt vollständige Beobachtbarkeit der relevanten
SQL-/OS-Nutzung, kooperativ geschlossene Szenarioclients/Pools, unterbundene
neue eigene Dispatches sowie native Schutzmechanismen gegen Wiederanmeldung
und Objektwechsel zwischen Prüfung und Löschung. Dabei dürfen die verbotenen
Kontosperr-/Sitzungsaktionen nicht als Ersatz verwendet werden. Eine leere
DMV-/Prozessliste, Wartefrist oder Labreservierung allein reicht nicht.
Beispielsweise verweigert natives `DROP LOGIN` laut
[Microsoft](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-login-transact-sql?view=sql-server-ver17)
die Entfernung eines angemeldeten Logins. Das ist eine mögliche abschließende
SQL-Schutzbarriere; sie ersetzt weder den vorherigen Ruhebeleg noch die
getrennte Qualifikation von DB-Benutzer-/Datei-/OS-Entfernung und deren Rennen.

Unverwaltete manuelle Zugangswege können diese Voraussetzungen verletzen.
Dann bleibt die Benutzeranlage beziehungsweise Nutzung nur im qualifizierten
Profil zulässig, Cleanup jedoch `BLOCKED`/`RECOVERY_REQUIRED`, bis ein neuer
expliziter Plan einen hinreichenden Ruhebeleg erhält. Das Lab verspricht
keinen erzwungenen Rückbau beliebiger manueller Sitzungen. Ist bereits bei
Admission kein vertragsgemäßer späterer Cleanupweg nachweisbar, blockiert
die Capability vor Anlage; eine Retentionfrist umgeht dies nicht.

Jede Deleteoperation muss den überprüften nativen Gegenstand atomar oder mit
gleichwertiger qualifizierter Racekontrolle treffen. Wenn die native API nur
einen inzwischen austauschbaren Namen annimmt, genügt ein zusätzlicher
Name-only-Check nicht. Unbelegbare Rennen blockieren den Adapter. Timeout
beweist kein Ende einer entfernten Aktion; keine automatische Wiederholung,
keine Freigabe der Reservierung ohne Endebeleg und keine Hintergrundmutation.

## 7. Dateisystem, Profile und Außenressourcen

Eigene feste Roots und private Objektidentitäten werden an qualifizierte lokale
Dateisysteme gebunden. Native objektgebundene, relativ zum geprüften Parent
ausgeführte Operationen müssen Reparse-/Symlink-/Mountwechsel während der
Operation verhindern oder sicher erkennen. Stringnormalisierung mit späterem
rekursiven Löschen genügt nicht. Junctions, Hardlinks, bind mounts, Volumes,
shared/host storage, fremde Kinder und unerwartete Objektwechsel blockieren;
keine Linkzieltraversierung oder Mount-/ACL-Reparatur. Synthetische erlaubte
Linktests dürfen nur den eigenen Outside-Sentinel innerhalb des äußeren
Fixture-Roots betreffen. Der Sentinel bleibt unverändert; der äußere Root
wird erst nach bestätigter Leerheit entfernt.

Die enge Windows-Profil-Ausnahme aus FSF-04 benötigt vor erster Nutzung eigene
neue SID, vorregistrierten privaten GuestProfileRoot, Abwesenheitsnachweis,
kontrollierte eigene Profilentstehung und vollständige begrenzte native
Registry-/Datei-/Linknebenwirkungen. Geladene, spezielle, gemeinsame,
bestehende oder unbekannte Profile bleiben unangetastet. `Loaded=False` allein
beweist keine Quieszenz und ein Profilpfad allein kein Eigentum. Ohne
qualifizierten nativen Profilcleanup bleibt profilbildender manueller Zugang
blockiert; kein rekursiver Ordnerfallback. Linux-Home außerhalb eigenen
Fixture-Scopes ist nicht zugelassen. Workloaddateien werden nicht durch UID
oder Ordnerlage nachträglich zu eigenen Ressourcen.

## 8. Freigegebene Grenzen und Aufbewahrung

Die folgenden Erstprofilwerte sind Designentscheidungen, keine Messwerte oder
Leistungszusagen. Stärkere native Grenzen gelten zusätzlich. Eine Erweiterung
benötigt eine eigene Vertragsentscheidung; kein unbegrenzter Override.

| Gegenstand | Grenze und Verhalten |
|---|---|
| Request | 16 KiB UTF-8, Tiefe 8, insgesamt 128 Felder; unbekannte/doppelte Felder, Overflow und freie Pfade ablehnen; Secretkanal getrennt. |
| Handle/Inventar | FSF-03 unverändert: Handle 256 Byte; Result 64 KiB; 64 ResourceRefs; 64 Dependencies je Ressource; 16 ReasonCodes. |
| Identitäten | Je Instanz ein Scope; je Scope höchstens 16 OS-Konten/numerische Kontexte, 16 SQL-Logins und 32 DB-Benutzer; zusammen mit Dateien höchstens 64 öffentliche Ressourcen. |
| Namen | Synthetische logische Aliase maximal 32 ASCII-Zeichen aus Buchstaben, Ziffern und Unterstrich; native Windowskonten maximal 20, Linuxkonten 32, SQL-Principals 64 Zeichen. Private generierte Namen, native Reserved-/Case-/Collationregeln und Kollisionsprüfung zusätzlich; keine Übernahme eines Bestandsnamens. |
| Dateien/Profile | Je Scope einschließlich eigener Profilnebenwirkungen höchstens 1.024 nachgewiesene Objekte, 256 MiB und Tiefe 16; unbekannte oder größere native Profilwirkung blockiert vor Erstnutzung. Kein Quota durch Entfernen unbekannter Dateien herstellen. |
| Private Metadaten | Einzelrecord 64 KiB, Journalbudget je Scope 16 MiB; höchstens 64 offene Scopes je Controller. Vor Mutation Platz für Intent, Receipt und erwartete Kompensation/Cleanup reservieren. |
| Anker/Abschlussindex | Höchstens 100.000 Nichtwiederverwendungseinträge und 64 MiB je Controllergeneration, einschließlich reservierter zukünftiger Abschlüsse. Erschöpfung blockiert neue Scopes; kein Purge offener Ownershipdaten. |
| Grant/Unlock | Grant und Credentialhandoff innerhalb 60 Sekunden einmalig annehmen; Sitzungs-Unlock maximal 30 Minuten ohne automatische Verlängerung. Begonnene feste Operation höchstens bis ihrer Deadline; Relock entfernt keine Konten. |
| Freshness/Deadline | READY beim jeweiligen Dispatch höchstens 5 Sekunden alt; einzelne lesende Probe höchstens 5 Sekunden, mutierender nativer Aufruf höchstens 30 Sekunden, Gesamtoperation höchstens 120 Sekunden und 2.048 geplante Schritte. Keine Erhöhung nach Beginn. |
| Retry | Null automatische Mutationsretries; nach Timeout höchstens eine zusätzliche lesende Recoveryprobe je Ressource und Operation innerhalb der Gesamtdeadline. Weitere Beobachtung benötigt eine neue explizite Recoveryoperation. |
| Retention | OPERATION gemäß angenommenem Plan; SCENARIO standardmäßig 4 Stunden, höchstens 24 Stunden je ausdrücklich genehmigtem Zeitraum und innerhalb desselben Runs. Verlängerung separat authentisiert und revalidiert, keine automatische Renewal. Ablauf sperrt neue Nutzung bis Verlängerung/Cleanup, löscht nichts. |
| Abschlussdaten | Detaillierte geschützte Records 30 Tage nach bestätigtem Run-Ende entfernen; kompakte geheimnisfreie Nichtwiederverwendungseinträge bis zur bestätigten Stilllegung der Controllergeneration. Offene/unklare Records nicht zeitgesteuert entfernen. |

Native Szenariocode-Ausführung und dessen Datenänderungen sind keine allgemeine
Quota-Sandbox. Obige Limits begrenzen die Fixtureverwaltung; sie rechtfertigen
kein Löschen fremder Workloaddaten. Ein Helper darf auch bei Deadline nicht
ungebundene späte Zielwirkung hinterlassen. Wenn sein Ende nicht belegt ist,
bleibt die Operation unklar; Folgeaktionen und Unlock der Reservierung bleiben
gesperrt. Die Deadline führt nicht zu KILL/ForceLogout im Ziel.

Vorhandene Verbindungen/Sitzungen werden durch Retentionablauf oder Relock
nicht beendet. Der Koordinator stoppt nur neue eigene Handoffs/Dispatches;
er behauptet keine native Sperre bereits ausgegebener Credentials. Erneute
Nutzung über das Lab benötigt den neuen gebundenen Grant. Aufbewahrte Benutzer
bleiben bis zu ihrem gesicherten Cleanup native Ressourcen.

Secrets bleiben ausschließlich im geschützten lokalen Run-Scope und so lange,
wie bestätigte eigene lebende Ressourcen beziehungsweise Recovery sie
benötigen. Nach gesichertem Ende ihrer Verwendung werden Secretwerte und
temporäre verschlüsselte Secretartefakte entfernt; Schlüssel für noch offene
Records bleiben erhalten. Keine Tombstones mit Passwort, Endpoint, SID/UID,
native Namen oder Pfaden; keine offene Ressource durch Recordlöschung verstecken.
Run-Ende ist erst nach FSF-04-Abschluss belegt, nicht durch TTL oder SQL-Ausfall.

## 9. Privacy, Fehler und tatsächlicher Repositorystand

Öffentliche Ausgaben bleiben im FSF-03-Inventar: opaque Referenzen, Profile,
Zustände und begrenzte ReasonCodes. Private Diagnosen minimieren native Daten,
speichern keine Passwort-/Connectionstring-/Kontodatenbankrohdaten und bleiben
lokal ignoriert. Keine privaten Records, Endpoints, Namen, Exceptions oder
Helperausgaben in Evidence, Exports, PRs oder Repository. Manuelle private
Zugangsdetails sind eine gesonderte Ausgabe mit geprüftem Empfänger und Zweck.

Unbekannter Handle und Handle eines anderen Owners erhalten denselben
begrenzten Ablehnungsgrund, ohne Existenzoffenlegung. Vollständige konstante
Laufzeit wird nicht behauptet. Für FSF-06 sind insbesondere REQUEST_INVALID,
AUTHORIZATION_REQUIRED, INTEGRITY_UNVERIFIED, GENERATION_UNVERIFIED,
CAPABILITY_UNAVAILABLE, RIGHTS_UNVERIFIED, USAGE_ACTIVE_OR_UNKNOWN, SCOPE_DRIFT,
DEADLINE_EXCEEDED, DISPATCH_UNCERTAIN, QUOTA_EXCEEDED,
SECRET_CHANNEL_UNAVAILABLE, SQL_CHANNEL_UNVERIFIED und RECOVERY_REQUIRED zu
prüfen. Dies ist ein vorgeschlagener begrenzter Fehlerkatalog, kein neuer DTO.

Der bestehende [SecretProvider](../../Private/SecretProvider.ps1) verwendet
unter Windows DPAPI mit vorhandenem LocalMachine-Fallback und unter Linux
Base64 plus Dateirechte. Er erfüllt dieses neue Modell daher nicht unverändert.
Die bestehende [SQL-Readiness](../../Private/SqlReadiness.ps1) setzt in ihrem
Verbindungspfad `TrustServerCertificate=True`; ihre grüne Probe ist keine
Serverzertifikatsvalidierung für FSF-05. Bestehende SA-Policy, UI-Capability,
Cleanup-Engine und Owned-Host-CI sind keine Fixture-Sicherheitsabnahme.
Diese Bestandsgrenzen bleiben ausdrücklich dokumentiert; in diesem Slice
werden keine Helfer, Exports, Policies, Schemafelder oder Runtimepfade geändert.

## 10. Freigegebene Entscheidungen und nächster Nachweis

| ID | Freigegebenes Modell innerhalb FSF-05 | Konsequenz |
|---|---|---|
| `E1` | Explizites Vertrauensmodell mit vertrauenswürdigem lokalen Betreiber und privilegierter Infrastruktur | Kein Schutzversprechen gegen same-user Hostcode, kompromittierte Administratoren oder vollständigen Host-Rollback. |
| `E2` | Lokale authentisierte Sitzung, exakter einmaliger Plan-Grant und durchgehende Ziel-/Lifecyclebindung | Keine Bearerautorität durch Handle, freie Vorlagen, HTTP-Erweiterung oder Rechtebootstrap. |
| `E3` | Zweckgetrennte AES-256-GCM-Records/Secrets, qualifiziertes Wrapping und separater Fortschrittsanker | Keine Base64-/Plaintext-/LocalMachine-Fallbacks; Crash-/Rollbacklücken blockieren; kein Anker als native Ownershipgarantie. |
| `E4` | Getrennte starke Szenariocredentials, maskierte manuelle Eingabe und qualifizierter einmaliger Speicherkanal | Manuelle und automatisierte Nutzung erhalten nur eigene Szenariorechte; unattended ohne sicheren Provider blockiert. |
| `E5` | SQL-TLS mit geprüfter Serveridentität und zusätzlicher nativer Zielgeneration | Kein TrustServerCertificate-Override/TOFU; fehlende bestehende sichere Verbindung blockiert auch OS-only. |
| `E6` | Geschlossene nicht privilegierte Profile mit effektiver Rechte-/Helper-/Inkarnationsprüfung | Kein GRANT-/SID-/UID-/Markerbeweis allein; nicht belegbare Backendkombinationen blockieren. |
| `E7` | Positive vollständige Quieszenz und native Racekontrolle ohne erzwungenes Sitzungsende | Unverwaltete Zugänge dürfen keinen ungesicherten Cleanup erzeugen; Snapshot und Lock allein reichen nicht. |
| `E8` | Objektgebundene Dateioperationen und eng nachgewiesene Windows-Profilnebenwirkung | Fremde Kinder, Link-/Mountdrift oder unbekannte Profilwirkung bleiben unangetastet. |
| `E9` | Feste Fristen/Quotas, reserviertes Journalbudget und getrennte Secret-/Record-/Indexretention | Kein automatischer Retry, TTL-Cleanup oder Purge unklarer Ownership zur Platzgewinnung. |
| `E10` | FSF-05 genehmigt ausschließlich dieses Sicherheitsmodell | FSF-06 sowie Implementierung und jede native Abnahme bleiben offen. |

FSF-06 muss positive und negative Nachweise für Autorisierung/Replay,
fremde Handle, Secretkanäle/TLS, Record-/Anker-/Nonce-Crashgrenzen, Unlockverlust,
Ressourcenersetzung/Restore, effektive SQL-/OS-Rechte, Quieszenz/Races,
Datei-/Profil-Escape, Limits und Recovery getrennt je Windows/Hyper-V,
Linux/Docker und Linux/Podman festlegen. Eine offene native Sicherheitsgrenze
wird als Capabilityblocker geführt, nicht durch einen Mock überdeckt.
Alle Fixture-Implementierungs- und Runtimebelege sind weiterhin offen.

Der Repository-Eigentümer hat FSF-05 am 2026-10-11 ausdrücklich freigegeben.
Der Abstimmungsstatus ist `APPROVED` für Revision `0.1` und E1 bis E10.
Als nächster Schritt liegt der [FSF-06-Teststrategieentwurf](FILESYSTEM_FIXTURE_TEST_STRATEGY_DRAFT.md)
zur Abstimmung vor; FSF-06 sowie sämtliche Implementierungs-/Runtimebelege
bleiben offen. Gekoppelte Quellen sind FSF-01 bis FSF-04,
[Repo-Map](../../.ai/repo_map.yaml), [Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md) und
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
Die verlinkten Primärquellen wurden am 2026-10-11 geprüft; sie belegen native
Eigenschaften, keine Projektimplementierung oder ausgeführte Fixtureabnahme.
