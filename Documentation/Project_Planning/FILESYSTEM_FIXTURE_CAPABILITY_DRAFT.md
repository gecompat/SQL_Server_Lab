# FSF-02 – Freigegebenes Capability-Modell für OS-/SQL-Identitäten und Dateisystem-Fixtures

| Merkmal | Wert |
|---|---|
| Status | `CAPABILITY_MODEL_APPROVED` – Fähigkeitsmodell freigegeben |
| Entwurf | `FSF-02`, Revision `0.1`, Stand 2026-10-11 |
| Freigabe | ausdrücklich durch den Repository-Eigentümer am 2026-10-11 |
| Grundlage | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md), Revision `0.2`, ausdrücklich freigegeben am 2026-10-11 |
| Anforderungsquelle | [Fixture-Verwaltungs-Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md) |
| Repositorybasis der Bestandsanalyse | `a6b5a6b3`; keine neue Provider- oder SQL-Runtime-Evidence |
| Gegenstand | getrennte Identitätsarten, Plattformmatrix, Nutzungsarten, Profile, Voraussetzungen und Blocker |
| Autorität | freigegebenes Fähigkeitsmodell; keine Implementierungs-, Benutzeranlage- oder Runtimefreigabe |

Die Entscheidungen B1 bis B8 wurden ausdrücklich freigegeben. Die Freigaben
von FSF-01 und FSF-02 genehmigen Architekturrahmen und Fähigkeitsmodell
einschließlich eigenständiger manueller und automatisierter OS-/SQL-
Benutzeranlage. FSF-03 und FSF-04 wurden anschließend als Handle-Vertrag und
Ownership-/Cleanupmodell freigegeben; FSF-05 und FSF-06 bleiben einzeln
freizugeben; erst danach darf eine Implementierung beginnen. Die Bezeichnungen
unten sind fachliche Entwurfsbegriffe, keine vorhandenen API-, Schema- oder
Fehlercodes. Bestehende Providerdeklarationen werden nicht erweitert.

## 1. Getrennte Verträge und Capability-Bewertung

Eine Anfrage benennt genau ein laufendes ausgewähltes SQL-Labziel, den
Szenariozweck, die Nutzungsart, den eigenen Ressourcenscope und die benötigten
Fähigkeiten. OS-Identitäten, SQL-Logins, Datenbankbenutzer und optionale
Dateisystem-Fixtures können getrennt angefordert und ausdrücklich kombiniert
werden. Gleiche Szenarioaliase verbinden keine Sicherheitsidentitäten.
Insbesondere erzeugt ein OS-Konto keinen SQL-Login und ein SQL-Login kein OS-Konto.

Der Entwurf trennt drei Fragen:

| Ebene | Vorgeschlagene Bedeutung | Grenze |
|---|---|---|
| Geplanter Umfang | `IN_SCOPE`, `DEFERRED` oder `OUT_OF_SCOPE` je Fähigkeit | Beschreibt eine Designentscheidung, keine implementierte Unterstützung. |
| Spätere Zielprüfung | `AVAILABLE`, `BLOCKED`, `UNSUPPORTED` oder `UNKNOWN` je angeforderter Fähigkeit | `AVAILABLE` verlangt frische gebundene Nachweise aller Voraussetzungen; `UNKNOWN` erlaubt keine Mutation. |
| Ausführungsnachweis | Implementierung und ausgeführte Provider-/SQL-Belege getrennt ausweisen | Für diesen Entwurf vollständig nicht implementiert beziehungsweise nicht ausgeführt. |

`BLOCKED` bedeutet, dass eine grundsätzlich vorgesehene Fähigkeit auf dem
konkreten Ziel an einer Voraussetzung scheitert; `UNSUPPORTED` bezeichnet eine
ausdrücklich ausgeschlossene Kombination. Beobachtungen dürfen nicht aus
historischen Zuständen, Katalogmetadaten oder der anderen Runtime übernommen
werden. Ein verfügbares Werkzeug allein beweist weder Rechte noch Ownership.
Auch ein positives Capability-Ergebnis ersetzt weder die ausdrückliche
Operationsfreigabe noch Handle, Journal oder Reservierung.

Fehlt eine angeforderte Fähigkeit, wird die gesamte neue Mutation vor ihrem
Beginn blockiert. Es gibt keinen stillen Wechsel von Podman zu Docker, von
benanntem Konto zu numerischer UID, von Windows- zu SQL-Authentisierung oder
von manueller Aufbewahrung zu automatischem Cleanup. Eine reduzierte Anfrage
benötigt eine ausdrückliche neue Auswahl. Während der Ausführung eintretende
Drift führt zu einem Teilfehler mit Recovery nach FSF-04, nicht zu einem
behaupteten atomaren Erfolg über OS und SQL hinweg.

## 2. OS-Identitäten je Plattform

`IN_SCOPE` bedeutet in den folgenden Tabellen stets bedingt geplant. Es gibt
noch keinen produktiven Fixture-Adapter und keinen positiven Laufzeitnachweis.

| Fähigkeit | Windows / Hyper-V | Linux / Docker | Linux / Podman |
|---|---|---|---|
| Eigenständiges benanntes OS-Konto | `IN_SCOPE`: neues lokales, nicht administratives Gastkonto, SID-gebunden | `IN_SCOPE`: neues lokales Containerkonto mit eigener freier UID/GID und nachprüfbarer Namensauflösung | `IN_SCOPE`: gleicher fachlicher Zweck, eigene Prüfung der Konto- und Namespacefähigkeit |
| Reine numerische UID/GID-Konstellation | `UNSUPPORTED`: kein Ersatz für Windows-SIDs | `IN_SCOPE`: ausdrücklich gewählter numerischer Prozess-/Dateirechtefall ohne behauptetes Benutzerkonto | `IN_SCOPE`: zusätzlich nutzbare Namespacezuordnung nachweisen |
| Mehrere Szenariobenutzer | `IN_SCOPE`: unterschiedliche eigene Konten/Profile im selben Szenarioscope | `IN_SCOPE`: unterschiedliche eigene Konten oder numerische Konstellationen | `IN_SCOPE`: eigener Kollisions- und Mappingnachweis |
| Manuelle Nutzung benannter Konten | `IN_SCOPE`: vorhandener zulässiger lokaler Gastzugang; Kontoanlage und nutzbarer Anmeldeweg getrennt prüfen | `IN_SCOPE`: vorhandenes gepinntes Exec als dieser Benutzer, mit geprüftem Programm-/Shellzugang | `IN_SCOPE`: vorhandenes gepinntes Exec als dieser Benutzer, mit separater UID-/Gruppenprüfung |
| Automatisierte Nutzung | `IN_SCOPE`: fester geprüfter Benutzerkontext im Gast | `IN_SCOPE`: fester Exec-Benutzerkontext im ausgewählten Container | `IN_SCOPE`: gleicher Vertrag, eigener Providerbeleg |
| Domain-/AD-/Entra-Identitäten, Hostkonten, Dienstkontoänderung | `OUT_OF_SCOPE` | `OUT_OF_SCOPE` | `OUT_OF_SCOPE` |

### Windows-Voraussetzungen

- Ausschließlich das ausgewählte lokale Windows-Gastziel über PowerShell Direct
  mit VM-ID; vorhandener Betreiberzugang bleibt privat. Keine WinRM-Ausweichroute.
- Lokale Kontenverwaltung muss vorhanden und im Gast nutzbar sein. Name,
  resultierende SID, Mitgliedschaften und wirksame Rechte müssen geprüft werden.
  Namenskollisionen werden abgewiesen; fremde Konten werden nicht übernommen.
- Keine Administratorgruppe, Dienst-/Treiberrechte, Änderung bestehender
  Gruppenrechte oder Sicherheitsrichtlinien. Notwendige unprivilegierte
  Gruppenmitgliedschaften gehören zum ausdrücklichen Profil und eigenen Journal.
- Kontoanlage garantiert keine interaktive Anmeldung. Für manuelle Anmeldung
  müssen ein vorhandener Kanal und dessen wirksame Anmelderechte passen;
  RDP-Aktivierung, Firewalländerung und neue globale Anmelderechte bleiben verboten.
- Eine Windows-Anmeldung kann Profilverzeichnisse außerhalb des Fixture-Roots
  erzeugen. Deren Erkennung, Ownership und zulässiger Rückbau müssen FSF-04/FSF-05
  regeln. Ohne diese Abdeckung bleibt dieser Nutzungsweg blockiert.

Lokale Konten und SIDs sind Windows-Konstrukte; sie werden nicht durch eine
Unix-UID nachgebildet. Die Kontoanlage mittels vorhandener Windows-Werkzeuge
ist technisch von der Freigabe des Anmeldewegs getrennt.
[Microsoft: New-LocalUser](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.localaccounts/new-localuser?view=powershell-5.1).

### Linux-Voraussetzungen

- Gepinnter Runtimeendpunkt und vollständige Container-ID; laufendes Ziel,
  aktuelle Namespacezuordnung und wirksamer Exec-Kontext müssen bewiesen sein.
- Für ein benanntes Konto: vorhandene geeignete lokale Kontowerkzeuge,
  schreibbare lokale Kontodatenbank und nachvollziehbare NSS-Auflösung.
  Read-only- oder gemeinsam beziehungsweise vom Host eingebundene
  Kontodatenbanken blockieren die Anlage. Keine Installation fehlender Programme.
- Neue Namen, UID und GID müssen kollisionsfrei und innerhalb des bestehenden
  Mappings nutzbar sein. Keine UID/GID `0`, keine privilegierten Gruppen oder
  Zusatz-Capabilities für Szenariobenutzer. Zusatzgruppen sind ausdrücklich
  auszuwählen und in ihrer effektiven Wirkung zu prüfen.
- Rootful und rootless werden getrennt geprüft. Rootless ist nicht pauschal
  ausgeschlossen; fehlende freie nutzbare IDs sind ein Blocker. Keine Änderung
  von Host-Subuid/Subgid, User Namespaces oder SELinux/AppArmor/Seccomp.
- Ein bereits zulässiger interner Betreiberkontext darf Konten verwalten;
  dafür werden weder `--privileged` noch Hostnamespaces, neue Mounts oder
  Runtime-Sockets in das Ziel eingeführt.
- Benannte Konten erhalten im ersten Profil keine Passwort-/SSH-Anmeldung und
  kein automatisch erzeugtes Home außerhalb des eigenen Scopes. Manuelle Nutzung
  erfolgt über vorhandenes Exec. Home, Shell und Programme müssen bei Bedarf
  ausdrücklich auf vorhandene beziehungsweise eigene gebundene Ressourcen zeigen.
- Reine UID/GID-Fälle haben keinen zugesagten Namen, kein Passwort und keine
  interaktive Kontenanmeldung. Es werden reservierte numerische Kontexte und
  eigene Ressourcen verwaltet; es darf dafür kein fremdes Konto gelöscht werden.

Exec kann einen Benutzer beziehungsweise UID/GID auswählen; daraus folgt noch
keine Kontoanlage, Passwortanmeldung oder korrekte Zusatzgruppenwirkung. Diese
Punkte benötigen getrennte Prüfungen.
[Docker: container exec](https://docs.docker.com/reference/cli/docker/container/exec/),
[Podman: exec](https://docs.podman.io/en/latest/markdown/podman-exec.1.html).

## 3. SQL-Identitäten als eigenständiger Vertrag

SQL-Principals werden ausschließlich auf der gebundenen ausgewählten Instanz
und bei Datenbankbenutzern auf ausdrücklich ausgewählten bestehenden
Labdatenbanken verwaltet. Eine reine SQL-Anfrage benötigt keinen
Gastadministrator und keine OS-Kontoanlage. Der vorhandene private SQL-
Betreiberzugang muss die erforderlichen Operationen bereits erlauben.
Eine globale Berechtigung wird nicht an Szenariobenutzer weitergegeben.

| Identitätsart | Windows / Hyper-V | Linux / Docker | Linux / Podman | Anmeldung und Grenze |
|---|---|---|---|---|
| Neuer SQL-Authentisierungslogin | `IN_SCOPE` | `IN_SCOPE` | `IN_SCOPE` | Eigenständiger Instanzprincipal; Mixed Mode muss bereits aktiv und sicherer Zugang vorhanden sein. |
| Neuer Datenbankbenutzer für eigenen SQL-Login | `IN_SCOPE` | `IN_SCOPE` | `IN_SCOPE` | Explizite Zuordnung zum nachgewiesenen eigenen Login; eigenes Profil je ausgewählter Datenbank. |
| Eigener Datenbankbenutzer `WITHOUT LOGIN` | `DEFERRED` | `DEFERRED` | `DEFERRED` | Keine direkte Anmeldung; separate spätere Entscheidung zu begrenzter Impersonation erforderlich. |
| Contained User mit Passwort | `DEFERRED` | `DEFERRED` | `DEFERRED` | Getrennte datenbankgebundene Authentisierung; keine automatische Aktivierung von Containment. |
| Windows-Login für eigenes lokales Gastkonto | `DEFERRED` | `OUT_OF_SCOPE` im ersten Linux-Vertrag | `OUT_OF_SCOPE` im ersten Linux-Vertrag | Nur ausdrückliche OS-/SQL-Verknüpfung mit SID- und Client-Authentisierungsnachweis; noch kein vereinbarter Ausführungspfad. |
| AD-/Kerberos-/Entra- oder Zertifikat-/Schlüsselidentitäten | `OUT_OF_SCOPE` | `OUT_OF_SCOPE` | `OUT_OF_SCOPE` | Kein Identitätsdienst-, Trust-, Zertifikats- oder Authentisierungsbootstrap. |

Der erste vorgeschlagene Umfang deckt damit echte, eigenständig anlegbare
SQL-Logins sowie zugehörige separat verwaltete Datenbankbenutzer ab. Ein
Login darf ohne zusätzliche Datenbankbenutzer angefordert werden; Zugriff
auf eine ausgewählte Fach-/Schulungsdatenbank benötigt die ausdrückliche
Zuordnung. Ein Datenbankbenutzer kann später zu einem bereits eindeutig
eigenen Login desselben Szenarioscopes ergänzt werden. Fremde oder nur
gleichnamige Logins werden nicht verwendet. Benutzer in mehreren Datenbanken
bleiben getrennte Ressourcen mit eigenen Rechten und Cleanupabhängigkeiten.

Ein Login authentisiert an der Instanz, ein gemappter Datenbankbenutzer trägt
Datenbankrechte. Ein Benutzer `WITHOUT LOGIN` kann sich nicht anmelden;
ein Contained User ist ein anderer Authentisierungsvertrag. Diese Unterschiede
werden in Ergebnis und manueller Anleitung sichtbar gehalten.
[Microsoft: Create a login](https://learn.microsoft.com/en-us/sql/relational-databases/security/authentication-access/create-a-login?view=sql-server-ver17),
[Microsoft: CREATE USER](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-user-transact-sql?view=sql-server-ver17).

SQL-Voraussetzungen und Blocker:

- Aktuelle Instanz- und Datenbankbindung; Name, Port oder SQL-Major-Version allein
  reichen nicht. Restore, Recreate, Wechsel des Dienstes oder einer Datenbank
  machen eine erneute Generation-/Ownershipprüfung erforderlich.
- Frisches authentisiertes SQL-READY gemäß FSF-01; das persistente `SQL_READY`
  oder ein Statusaufruf ersetzt diese Prüfung nicht. Timeout und Frischegrenzen
  werden in FSF-05/FSF-06 festgelegt.
- Namens-/SID-Kollision, unklare eigene Zuordnung, fehlende Betreiberrechte,
  ungeeignete Authentisierung oder nicht überprüfbare effektive Rechte blockieren.
- Keine Änderung von Authentisierungsmodus, Dienstkonto, Datenbankoptionen,
  fremden Principals oder globalen `public`-/`guest`-Rechten; keine automatische
  Datenbankanlage. SQL-Zugang funktioniert unabhängig von optionalen Dateien.
- SQL-Versionen und Providerkombinationen werden gegen die aktuellen
  Projektkataloge geprüft. Deren derzeitige `SUPPORTED`-Versionen 2019, 2022 und
  2025 sind keine Fixture-Freigabe. Jede konkrete Kombination benötigt FSF-06-
  Evidence; Nachweise von External Languages oder anderen Features sind nicht
  auf die Identitätsverwaltung übertragbar.

## 4. Nicht privilegierte Berechtigungsprofile

Profile sind geschlossen auszuwählen; freie Shell, frei eingespeistes SQL und
beliebige Rollen-/Gruppenlisten sind kein Bestandteil dieses Vertrags.
Synthetische Szenarioaliase dürfen benannt werden; die endgültige kollisionsfreie
Namensabbildung und Grenzen folgen in FSF-03/FSF-05.

| Profilfamilie | Vorgeschlagener erster Umfang | Ausgeschlossene Erweiterung |
|---|---|---|
| OS-Basiskonto | eigenes nicht privilegiertes Konto; geprüfter manueller oder automatisierter Nutzungskontext | Admin/root/sudo, Servicekonten, neue globale Anmelde- oder Gruppenrechte |
| SQL-Verbindung | eigener SQL-Login, nur erforderlicher Verbindungszugang und geprüfte unvermeidbare Basisrechte | Serverrollen, `CONTROL SERVER`, breite Metadaten-/Adminrechte |
| SQL-Objektlesen | eigener gemappter Benutzer, `SELECT` auf explizit ausgewählten synthetischen Labtabellen/-views | pauschales Lesen sämtlicher Datenbanken oder fremder Daten |
| SQL-Objekt-DML | eigener gemappter Benutzer, ausdrücklich gewählte `SELECT`/`INSERT`/`UPDATE`/`DELETE`-Teilmenge auf gebundenen Labtabellen | DDL, Eigentümerwechsel, `db_owner`, Berechtigungsvergabe und freies `EXECUTE` |
| SQL-Negativfall | gezielt fehlender Zugriff beziehungsweise `DENY` einer ausgewählten Objektberechtigung nur am eigenen Benutzer | Änderung bestehender Benutzer, gemeinsamer Rollen oder Objekte zur Erzeugung des Negativfalls |
| Dateirechte | Rechte an eigenen gebundenen Fixture-Dateien gemäß Abschnitt 6 | fremde ACLs/Besitzer, Hostpfade, globale Freigaben |

Die SQL-Profile ermöglichen beispielsweise Leser, Schreiber und Benutzer ohne
gewählten Objektzugriff für dieselbe Schulung. Sie sind keine allgemeine
SQL-Workloadausführung; die Szenariositzungen führt der Operator oder Consumer
anschließend selbst aus. Funktionen, Prozeduren, Schema-/Datenbankrollen,
Performance-Diagnoserechte und weitere Privilegienprofile benötigen spätere
ausdrückliche Erweiterungen und sind im ersten Umfang nicht zugesagt.

Effektive Rechte zählen, einschließlich geerbter Gruppen-/Rollenrechte,
`public`, `guest` und möglicher Rechteketten. Breitere vorhandene Rechte dürfen
nicht durch den Profilnamen verdeckt werden. Fehlt ein belastbarer Nachweis
der erlaubten und verbotenen Wirkungen, bleibt die Anlage/Nutzung blockiert;
FSF-05 konkretisiert den Nachweis. Die Rechte fremder Principals werden zur
Herstellung eines Profils nicht eingeschränkt.

## 5. Manuelle und automatisierte Szenarien

| Nutzungsart | Identitätsanlage und Zugang | Lebensdauer |
|---|---|---|
| Manuelle Schulung / Rekonstruktion | Eigenständige Auswahl eines oder mehrerer OS- und/oder SQL-Benutzer; vorhandener sicherer Zugang unter der jeweiligen Szenarioidentität | ausdrücklich aufbewahrter Szenarioscope bis zum vereinbarten Nutzungsende innerhalb des Lab-Runs |
| Automatisiertes Szenario | Gleiche Identitätsarten und Rechteprofile; Consumer erhält nur den dafür begrenzten Nutzungskontext | begrenzter Operationsscope oder ausdrücklich aufbewahrter Szenarioscope |

Eine manuelle SQL-Schulung mit zwei eigenen SQL-Logins und unterschiedlichen
Datenbankrechten benötigt weder OS-Benutzer noch Dateisystem-Fixture oder
Testexecutor. Umgekehrt sind eigene OS-Konten für eine SQL-bezogene
Rekonstruktion ohne neue SQL-Principals zulässig. Ein zusammengesetztes Szenario
wählt beide Verträge ausdrücklich aus. Numerische UID/GID-Fälle dürfen nicht als
manuell anmeldbare Benutzer präsentiert werden.

Zugangsdaten verbleiben in privater lokaler Secretverwaltung; getrennte eigene
Credentials je Authentisierungsidentität, keine gemeinsame OS-/SQL-Passwortkopie.
Manuelle Nutzung benötigt eine ausdrücklich angeforderte sichere lokale
Übergabe/Anmeldung. Weder Repository, normales Handle/Ergebnis, Journal,
Kommandozeile noch Logs dürfen Klartextsecrets enthalten. FSF-03/FSF-05 legen
die konkrete sichere Übergabe fest. Ohne sie ist die benötigte Nutzungsart
blockiert. Eine Container-Exec-Nutzung benötigt kein Benutzerpasswort.

FSF-01 erlaubt zunächst genau einen Szenario-Ressourcenscope pro Instanz mit
mehreren Identitäten und mehreren manuellen SQL-Sitzungen. Mutationen sind
serialisiert und an die wirksame Lifecycle-Reservierung gebunden. Testende
oder Dateisystem-Cleanup darf aufbewahrte Benutzer nicht implizit entfernen.
Fristablauf markiert Cleanupbedarf; er veranlasst keine blinde TTL-Löschung.
Aktive Benutzersitzungen und Folgen von Kontenentfernung sind in FSF-04/FSF-05
zu entscheiden; erzwungenes Beenden ist hier nicht freigegeben.

## 6. Optionale Dateisystem-Fähigkeiten

| Fähigkeit | Windows / Hyper-V | Linux / Docker | Linux / Podman |
|---|---|---|---|
| Eigene Verzeichnisse und Dateien | `IN_SCOPE`: privater Gastpfad auf geeignetem NTFS | `IN_SCOPE`: privater Containerpfad | `IN_SCOPE`: privater Containerpfad, eigener Mappingbeleg |
| Besitzer und Rechte | `IN_SCOPE`: präzise SID-gebundene NTFS-ACLs | `IN_SCOPE`: UID/GID und Unix-Mode-Bits | `IN_SCOPE`: UID/GID und Unix-Mode-Bits innerhalb bestehender Zuordnung |
| POSIX-ACLs / NTFS-Emulation | keine POSIX-Emulation | POSIX-ACLs `DEFERRED`, keine NTFS-Emulation | POSIX-ACLs `DEFERRED`, keine NTFS-Emulation |
| SQL-Dienstzugriff auf eigene Dateien | `IN_SCOPE`: vorhandene Dienstidentität exakt ermitteln und nur am eigenen Root berechtigen | `IN_SCOPE`: wirksame SQL-Prozess-UID/GID und Pfadzugang nachweisen | `IN_SCOPE`: zusätzlicher Namespace-/Labelnachweis |
| Link-/Escape-Testfall | `IN_SCOPE`: Junction/Reparse Point als eigene synthetische Ressource | `IN_SCOPE`: eigener Symlink | `IN_SCOPE`: eigener Symlink mit getrenntem Providerbeleg |
| Outside-Sentinel | `IN_SCOPE`: außerhalb innerem Testroot, innerhalb eigenem äußerem Fixture-Root | `IN_SCOPE`: gleiche Begrenzung | `IN_SCOPE`: gleiche Begrenzung |
| Host-Bind-Mount, Shared Volume, Hostpfad | `OUT_OF_SCOPE` im ersten Profil | `OUT_OF_SCOPE` im ersten Profil | `OUT_OF_SCOPE` im ersten Profil |

Der eigene Root muss auf bestehendem privatem Zielstorage liegen. Es werden
keine Volumes, Mounts oder Infrastruktur erstellt. Ungeeignete Read-only-,
Shared-, Host- oder unerklärte Mountgrenzen blockieren die Dateioperation.
Ein Image-Dateisystem wird nicht ohne Prüfung automatisch als sicherer privater
Storage betrachtet. Beim Cleanup werden Links selbst behandelt; fremde
Linkziele werden nicht traversiert. Die genaue Rootgrenze, Outside-Sentinel-
Auslegung und sichere Dateioperation sind trotz FSF-01 weiterhin ausdrücklich
in FSF-04/FSF-05 zu bestätigen. Fehlende Linkfähigkeit blockiert nur eine
Anfrage, die diese Fähigkeit ausdrücklich verlangt; sie ist für reine
Benutzeranlage keine Voraussetzung.

## 7. Abnahmebedarf und noch zu konkretisierende Grenzen

Die spätere Capability-Ermittlung ist lesend und startet/repariert kein Ziel.
Sie darf keine Probeidentitäten oder Schreib-Probe-Fixtures anlegen. Für
Schreibfähigkeiten, die lesend nicht sicher bewiesen werden können, wird keine
Verfügbarkeit behauptet. FSF-05/FSF-06 müssen dafür eine belastbare
Nachweisstrategie liefern oder die Fähigkeit blockiert lassen.

Vor Implementierung müssen FSF-03 bis FSF-06 insbesondere festlegen:

- sichere Ziel-/Datenbankgeneration, minimale öffentliche Ergebnisse und
  private SID-/UID/GID-/Mount-/Credentialbindung;
- Namen, Konto-/Dateimengen, Größen, Laufzeiten, Probe-Timeouts und Frische als
  endliche Grenzen; fehlende konkrete Grenzen erlauben keine Ausführung;
- Konto-/Home-/Windows-Profilnebenwirkungen, eigene Gruppen, Sitzungen,
  Teilerfolg, unbekannter Antwortstatus und Cleanupreihenfolge;
- wirksame Rechteprüfung und sichere Secretübergabe je Nutzungsart;
- Reservierung durch sämtliche mutierenden Labpfade und Driftbehandlung.

FSF-06 muss mindestens folgende Fälle separat belegen: OS-only und SQL-only;
manuelle Anmeldung und automatisierte Nutzung; zwei SQL-Benutzer mit
unterschiedlichen positiven/negativen Objektzugriffen; benanntes Linuxkonto
gegen reinen UID/GID-Fall; Windows-Anmeldeblocker; Namens-/SID-/UID-Kollision;
rootful/rootless und Mappingfehler; fehlender Mixed Mode; Read-only-/Shared-
Kontodatenbank; unzulässige Mountgrenzen; SQL-/Datenbankdrift; erhaltene fremde
Principals und erhaltene manuelle Benutzer nach Dateisystem-Cleanup. Docker,
Podman und Hyper-V bleiben getrennte Providerbelege.

## 8. Freigegebene Capability-Entscheidungen

| ID | Freigegebenes Modell innerhalb FSF-02 | Konsequenz |
|---|---|---|
| `B1` | Getrennte OS-, SQL-Login-, Datenbankbenutzer- und Dateifähigkeiten; keine automatische Kopplung | Eigenständige Benutzeranlage ist ohne Testexecutor und ohne Dateien vorgesehen. |
| `B2` | Benannte Windows-/Linuxkonten sowie ausdrücklich numerische Linuxfälle; rootless bedingt statt pauschal ausgeschlossen | Konto- und Anmeldefähigkeit werden getrennt geprüft; keine Host-/Namespaceänderung. |
| `B3` | Erster SQL-Umfang: SQL-Authentisierungslogins und eigene gemappte Datenbankbenutzer | Windows-Authentisierung, Contained User und `WITHOUT LOGIN` bleiben eigene spätere Entscheidungen. |
| `B4` | Geschlossene nicht privilegierte Profile für Verbindung, Objektlesen, ausgewählte DML und negative Zugriffsfälle | Wirksame Rechte müssen passen; keine freie Rollen-/SQL-/Shellkonfiguration. |
| `B5` | Manuelle und automatisierte Nutzung gleichberechtigt, mit bewusst begrenzter Aufbewahrung und eigener sicherer Zugangsmethode | Testende entfernt keine aufbewahrten Identitäten; keine Klartextcredentials im Handle. |
| `B6` | Dateien optional, private Zielpfade; NTFS-ACLs beziehungsweise Unix-Mode-Bits, begrenzte Link-/Sentinelfälle | Shared-/Hoststorage und POSIX-ACL-Erweiterungen gehören nicht zum ersten Profil. |
| `B7` | Capability-Ermittlung fail-closed, lesend und je konkrete Kombination; kein stiller Fallback | Fehlende Evidence/Frische/Freigabe bleibt ein Blocker; Providerdeklaration reicht nicht. |
| `B8` | FSF-02-Freigabe genehmigt ausschließlich dieses Fähigkeitsmodell | FSF-03 bis FSF-06 benötigen separate Einzelfreigaben; keine Implementierung oder Zielmutation. |

Der Repository-Eigentümer hat FSF-02 am 2026-10-11 ausdrücklich freigegeben.
Der Abstimmungsstatus ist `APPROVED` für Revision `0.1` und B1 bis B8.
Der [FSF-03-Handle-Vertrag](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md) wurde anschließend
am selben Tag freigegeben. Das [FSF-04-Ownership-/Cleanupmodell](FILESYSTEM_FIXTURE_OWNERSHIP_CLEANUP_DRAFT.md)
wurde danach am selben Tag freigegeben. Als nächster Schritt liegt der
[FSF-05-Sicherheitsentwurf](FILESYSTEM_FIXTURE_SECURITY_DRAFT.md)
zur Abstimmung vor; FSF-05 und FSF-06 bleiben offen. Die technischen Primärquellen
oben wurden am 2026-10-11 geprüft; sie erklären Plattformmechanismen und
erteilen keine Projektfreigabe. Gekoppelte Projektquellen bleiben
[FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md),
[Repo-Map](../../.ai/repo_map.yaml),
[Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md) und
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
