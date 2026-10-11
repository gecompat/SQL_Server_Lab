# FSF-04 – Ownership, Cleanup und Recovery für OS-/SQL-Identitäten

| Merkmal | Wert |
|---|---|
| Status | `OWNERSHIP_CLEANUP_DECISION_DRAFT` – zur Abstimmung, nicht freigegeben |
| Entwurf | `FSF-04`, Revision `0.1`, Stand 2026-10-11 |
| Grundlagen | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md) Revision `0.2`, [FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md) Revision `0.1`, [FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md) Revision `0.1`; ausdrücklich freigegeben am 2026-10-11 |
| Anforderungsquelle | [Fixture-Verwaltungs-Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md) |
| Repositorybasis der Bestandsanalyse | `a6b5a6b3`; keine neue Fixture-Implementierung oder Runtime-Evidence |
| Gegenstand | eigene Erzeugung, Vorabjournal, getrennte Lebensdauer, Entfernung, Absenzbelege, Teilfehler und Recovery |
| Autorität | Dokumentationsentwurf; keine Implementierungs-, Benutzeranlage-, Sitzungsbeendigungs- oder Löschfreigabe |

Alle Entscheidungen D1 bis D10 sind Vorschläge. Die drei bisherigen Freigaben
genehmigen Architektur, Fähigkeiten und Handle-Vertrag. FSF-04 bis FSF-06
bleiben einzeln freizugeben; erst danach darf eine Implementierung beginnen.
Bezeichnungen und Zustände unten sind fachliche Entwurfsbegriffe, keine neuen
Statefelder, APIs oder ausführbaren Cleanupaktionen.

## 1. Ownership ist eine nachgewiesene Beziehung

Ownership benötigt zusammen eine authentisierte private Recordkette,
denselben Controller-/Store-/Owner-/Consumer-/Run-/Zielkontext, eine vorab
registrierte Erzeugungsabsicht, einen bestätigten eigenen Erzeugungsnachweis
und eine frische Bindung an dieselbe native Ressource. Kein Einzelmerkmal
ersetzt diese Kette. Die Identitätsarten bleiben gemäß FSF-03 getrennt.

| Ressource | Eigener Erzeugungsnachweis und aktuelle Prüfung | Unzureichender Nachweis |
|---|---|---|
| Windowskonto | vorherige Namensabwesenheit, gebundene Kontoanlage, resultierende Gast-SID und kontrollierte eigene Mitgliedschaften | Name, SID aus ungeprüftem Handle oder Kontobeschreibung allein |
| Linuxkonto | freie Namen/UID/GID im bestehenden Namespace, gebundene Kontoanlage und beobachtete eigene Kontodatensätze; erneute Identitäts-/Generationprüfung | UID, Name, GECOS-Marker oder gleicher Dateibesitzer allein |
| Numerischer Linuxkontext | eigene private ID-Reservierung und unveränderte Namespacebindung; keine behauptete Kontoanlage | eine freie oder später wiederverwendete UID als Kontoeigentum |
| SQL-Login | Abwesenheit vor Create, gebundene Erzeugung und private Principal-/SID-/Instanzgeneration | Name oder Principal-ID allein |
| Datenbankbenutzer | eigene Erzeugung in genau der gebundenen Datenbankgeneration, eigene Principal-/SIDbindung und explizite eigene Loginreferenz | Datenbankname, SID-Mapping oder gleichnamiger Benutzer in einer anderen Datenbank |
| Dateiressourcenpaket | eigene Root-/Objekterzeugung, private Objektidentitäten und Manifest der erlaubten Pfade/Rechte/Linkziele | Pfadpräfix, Markerdatei, Besitzer oder Zeitpunkt allein |

Account-/SQL-/Dateierzeugung und lokales Journal bilden keine verteilte
Transaktion. Insbesondere lassen Linux-UIDs und numerische Principal-/Datei-IDs
eine mögliche Wiederverwendung zu. Das konkrete Verfahren zur Erkennung
derselben Ressourcengeneration und die verbleibenden Admin-/Nebenläufigkeits-
grenzen sind in FSF-05 zu belegen. Ohne ausreichenden Nachweis bleibt eine
vorhandene Ressource unverändert und Cleanup blockiert. Ein Marker macht eine
fremde oder nachträglich gefundene Ressource nicht zu einer eigenen.

## 2. Vorabjournal und Annahme einer Operation

Vor der ersten Zielmutation müssen Handle-/RequestRef-Bindung, erwartete
Inventarrevision, Zielgeneration, Scope-Reservierung und konkreter Plan
dauerhaft registriert sein. Dazu gehören neu reservierte ResourceRefs,
Ressourcenarten, erlaubte Nebenwirkungen, eigene Abhängigkeiten, Lebensdauer,
Fehlerverhalten und Cleanupumfang. Native IDs bleiben privat; Secrets und
fremde Accountdatensätze werden nicht in das Journal kopiert.

Die Annahme verbraucht die konkrete Operationsfreigabe genau einmal unter
derselben wirksamen Reservierung wie Revisionstest und Journalregistrierung.
Die private Operation darf anschließend nur ihre registrierten Schritte und
vorab genehmigte Kompensation fortsetzen. Ihr eigener Journalfortschritt ist
kein wiederverwendbarer alter Grant. Eine andere Operation, Planänderung,
ungültige Recordkette oder unbekannte Generation benötigt neue Prüfung und
konkrete Freigabe. Persistenz-, Integritäts- und Rollbackschutz folgen in FSF-05.

Jeder mutierende Schritt hat einen eigenen Vorabrecord mit ausgewählter
Ressource, exakter Aktion, gebundener Zielroute, Vorbedingungen und erwarteter
Wirkung. Das Ergebnis wird danach mit beobachteter nativer Identität und
Erzeugungs-/Entfernungsbeleg dauerhaft bestätigt. Journalfehler vor Dispatch
verhindert die Mutation. Journalfehler nach Dispatch erzeugt `UNCERTAIN`,
sperrt weitere Zielmutationen und erhält Reservierung sowie Recoverybedarf.

| Privater Schrittstand | Bedeutung | Zulässige Folge |
|---|---|---|
| `INTENT_RECORDED` | Absicht dauerhaft; Dispatch noch nicht bestätigt | Dispatch nur innerhalb derselben angenommenen Operation und bei nachgewiesenem Nichtbeginn |
| `CREATE_CONFIRMED` | eigene Erzeugung und native Identität bestätigt | vereinbarte Nutzung oder konkret freigegebenes eigenes Cleanup |
| `DELETE_INTENT_RECORDED` | eigene Löschung vorab gebunden | genau dieser Schritt nach erneuter Prüfung; kein Name-only-Fallback |
| `REMOVAL_CONFIRMED` | gleiche Zielgeneration und eigene Ressourcenabsenz bestätigt | idempotente Beobachtung, keine neue Löschung |
| `UNCERTAIN` | Zielwirkung, Recordfortschritt oder Antwortstatus unklar | ausschließlich begrenzte Beobachtung/Recovery; kein blinder Retry |

Ein Crash nach Create, aber vor dauerhaftem Erzeugungsreceipt ist ein echter
Unsicherheitsfall. Vorabintent und jetzt vorhandener gleichnamiger Benutzer
reichen nicht zur Adoption oder automatischen Kompensation. Nur ein eigener
nachweisbarer Erzeugungsbeleg kann Recovery autorisieren; andernfalls bleiben
Ressource, eigener Record und Blocker erhalten. Ein bloßer Name-/UID-Vergleich
darf diese Lücke nicht verdecken.

## 3. Nebenwirkungen gehören zum eigenen Ressourcenplan

OS-Konten ändern notwendigerweise Datensätze in der Gast-/Container-
Kontenverwaltung außerhalb eines Dateisystem-Fixture-Roots. Das ist ein
ausdrücklich gebundener Identitätsvertrag, keine allgemeine Dateischreibfreigabe.
Vorhandene fremde Datensätze, Credentials, Gruppenrechte und globale
Konfigurationen bleiben erhalten. Kein Restore einer gesamten früheren
Kontodatenbank als Rollback: Er könnte parallel entstandene fremde Änderungen
überschreiben.

Der jeweilige vorinstallierte Backendpfad muss seine tatsächlichen Effekte
kennen: Kontodatensätze, eigene nicht privilegierte Mitgliedschaftskanten,
gegebenenfalls eigene Hilfsgruppe, Home/Profil sowie Werkzeug-Backups oder
Hooks. Nicht begrenzbare, unerklärte oder fremde Nebenwirkungen blockieren
bereits Create. Die bloße Verfügbarkeit von `useradd`/`userdel` oder einer
Windows-API belegt keinen sicheren Backendvertrag.

Eigene Hilfsgruppen und sonstige Unterressourcen werden privat mit ihrem
Erzeugungsreceipt und sämtlichen eigenen Nutzern registriert. Sie erweitern
die sechs öffentlichen Ressourcenarten aus FSF-03 nicht. Eine vorbestehende
Gruppe bleibt fremd; nur eine ausdrücklich genehmigte Mitgliedschaft des
eigenen neuen Kontos darf entstehen beziehungsweise mit ihm entfallen.
Eine eigene Hilfsgruppe darf erst entfernt werden, wenn keine erhaltene eigene
oder fremde Mitgliedschaft beziehungsweise Nutzung besteht.

SQL-Kontenanlage erzeugt keine Datenbank und keinen OS-Account. Ein eigener
Login kann mehrere separat registrierte eigene Datenbankbenutzer tragen.
Objekte, Rollen, Schemas, Jobs oder Datenbanken, die später fremd oder außerhalb
des genehmigten Profils mit ihm verbunden werden, werden nicht automatisch
zu Fixture-Ressourcen. Unerwartete Ownership ist ein Cleanupblocker.

## 4. Lebensdauer und ausdrücklich gewählter Cleanupumfang

Die Lebensdauer wird je ResourceRef geführt, nicht allein je Handle. Der
Szenarioscope endet erst, wenn sämtliche eigenen Zielressourcen bestätigt
entfernt und erforderliche lokale Abschlussarbeiten erledigt sind.

| Anlass | Vorgeschlagenes Verhalten |
|---|---|
| Ende eines automatisierten Operationsscopes | vorab genehmigtes Cleanup eigener `OPERATION`-Ressourcen wird unabhängig vom Testergebnis versucht; Blocker erzeugen Recoverybedarf |
| Ende eines Dateitests | nur konkret gewählte Dateiressourcen; erhaltene OS-/SQL-Identitäten bleiben nutzbar |
| Manuelle Aufbewahrung / automatisierte Retention | `SCENARIO`-Ressourcen bleiben bis zum ausdrücklich erklärten eigenen Nutzungsende innerhalb des Runs |
| Fristablauf oder Consumercrash | sichtbarer Cleanupbedarf, keine ungebundene TTL-Löschung oder automatische Scopewiederverwendung |
| Geplantes Run-Ende | eigenes Fixture-Cleanup vor einer separat autorisierten Infrastrukturaktion; offene Identitäten blockieren regulären Scopeabschluss |
| SQL-/Runtime-Ausfall oder fremde externe Entfernung | keine Infrastruktur-Reparatur und keine behauptete Fixture-Absenz; gebundener Recoverybedarf bleibt erhalten |

Cleanup benötigt einen konkreten ausgewählten ResourceRef-Satz, dessen
zulässige Abhängigkeiten, `ExpectedInventoryRevision` und Operationsfreigabe.
Es gibt kein implizites „alles dieses Benutzernamens“, „alles dieser UID“ oder
Cascade-Delete. Verhindert eine erhaltene eigene Ressource die Entfernung
einer ausgewählten Ressource, wird vor Mutation blockiert und ein neuer
reviewbarer Satz benötigt. Fremde Abhängigkeiten dürfen nicht mit ausgewählt
oder durch Ownershiptransfer aufgelöst werden.

Für Create/Extend legt der Plan das Verhalten bei Fehlern vorab fest:
`COMPENSATE_NEW` entfernt nur bestätigte neue eigene Ressourcen dieser Operation;
alternativ kann ausdrücklich `KEEP_CONFIRMED` für gewünschte Szenarioretention
gewählt werden. Unklare Ressourcen bleiben immer Recoveryfälle. Bestehende
aufbewahrte Benutzer werden nicht zur Kompensation einer fehlgeschlagenen
Erweiterung entfernt. Eine bestätigte Retention ist kein Gesamterfolg für
nicht angelegte Anfrageteile.

Neue Rechte-/Mitgliedschaftskanten an erhaltenen eigenen Identitäten müssen
als einzelne private Effekte mit geprüftem Vorzustand journalisiert werden.
Eine vorab genehmigte Kompensation darf nur solche bestätigten neuen Effekte
zurücknehmen, wenn deren aktuelle Bindung und erwarteter Zustand weiterhin
passen. Sie darf weder das erhaltene Konto löschen noch pauschal einen früheren
ACL-/Rollen-/Kontodatensatz überschreiben. Bei Drift oder unklarer Wirkung
bleibt der Profileffekt als Recoverybedarf erhalten.

## 5. Cleanupablauf und getrennte Reihenfolge

1. Handle, privaten Kontext, Recordintegrität, Owner/Consumer, Inventarrevision
   und Auswahl prüfen; konkreten Plan annehmen und Reservierung halten.
2. Neue Lab-Nutzungsübergaben für die ausgewählten Ressourcen im eigenen
   Koordinator sperren. Bereits ausgegebene Credentials und externe Sitzungen
   sind dadurch nicht widerrufen.
3. Frische Zielgeneration, Capability und authentisiertes SQL-READY prüfen,
   auch bei OS-only und jedem Cleanup. Kein Start/Repair als Voraussetzungshilfe.
4. Alle bekannten eigenen und fremden Abhängigkeiten, Sessions/Prozesse,
   Profile, Mount-/Linkgrenzen und Ressourcenidentitäten prüfen. Bei einem
   Blocker vor der ersten Löschung bleibt der gesamte gewählte Satz unverändert.
5. Den vorab gebundenen Abhängigkeitsgraphen abarbeiten. Vor jedem nativen
   Schritt dessen Ownership, Ziel, READY-/Freigabefrische und Vorbedingungen erneut prüfen,
   Delete-Intent dauerhaft schreiben, Schritt ausführen und Wirkung bestätigen.
6. Bei Drift, unklarer Antwort oder Fehler keine weiteren Zielmutationen
   ausführen. Bereits bestätigte Fortschritte bleiben erhalten, Restbedarf
   wird sichtbar. Keine automatische Wiederanlage gelöschter Benutzer.
7. Erst nach bestätigter Ressourcenabsenz eigene nicht mehr benötigte
   Szenariocredentials und temporäre Übergaben entfernen. Journal-/Abschluss-
   records bleiben nach den begrenzten Regeln in Abschnitt 9 bestehen.

| Teilvertrag | Vorgeschlagene Ordnung und Grenze |
|---|---|
| SQL | ausgewählte eigene Datenbankbenutzer vor ihrem ausgewählten eigenen Login; alle gemappten Benutzer, auch außerhalb des erwarteten Inventars, prüfen; keine neuen orphaned Users erzeugen |
| OS | eigene ausgewählte Datei-/Home-/Profilressourcen und Mitgliedschaftsabhängigkeiten vor Kontoentfernung; eigene ungenutzte Hilfsgruppen anschließend |
| Numerischer Linuxkontext | eigene gewählte Dateiressourcen entfernen und private Reservierung abschließen; niemals `userdel` für eine UID-only-Konstellation |
| Dateiressourcenpaket | eigene registrierte Blätter und Links selbst, dann eigene leere Verzeichnisse, zuletzt äußerer Root; keine ungebundene rekursive Löschung |
| OS und SQL gemeinsam | nur ausdrücklich gewählte Beziehungen ordnen den Graphen; keine angenommene OS-/SQL-Kopplung und keine plattformübergreifende Atomarität |

SQL Server kann einen Login mit noch gemappten Benutzern entfernen und dabei
orphaned Users hinterlassen. Aktive Logins sowie Ownership an Securables,
Serverobjekten oder Agent-Jobs können die Loginentfernung verhindern;
Datenbankbenutzer mit eigener Securable-Ownership können ebenfalls nicht
einfach entfernt werden. Der Fixture-Vertrag blockiert solche Fälle ohne
KILL, Ownershiptransfer oder fremde Objektlöschung.
[Microsoft: DROP LOGIN](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-login-transact-sql?view=sql-server-ver17),
[Microsoft: DROP USER](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-user-transact-sql?view=sql-server-ver17).

## 6. Aktive Sitzungen und Kontenentfernung

Der erste Cleanupvertrag beendet keine SQL-/OS-Sitzungen oder Prozesse
zwangsweise. Der Operator beziehungsweise Consumer beendet seine Nutzung
selbst; der Koordinator prüft anschließend deren Ende. Erhaltene Benutzer
oder fremde Sitzungen dürfen nicht ausgesperrt werden. Es gibt keinen
automatischen Passwortwechsel, Kontensperrung, `KILL`, Force-Logout oder
Prozessabbruch als Cleanuphilfsmittel.

Ein vorhandener passender Session-/Prozess-/Profilbezug blockiert die
betroffenen Schritte. Fehlende Beobachtungsrechte, nicht zurechenbare Tokens,
Pooling/Impersonation oder unbekannte Prozesswirkung werden nicht als
Sitzungsfreiheit behandelt. Die sichere Quieszenz zwischen Prüfung und
Löschung sowie native Race-Guards sind in FSF-05/FSF-06 zu belegen; ein
einmaliger Snapshot und eine Lab-Sperre allein garantieren das nicht.
Fehlt der Nachweis für eine Kombination, bleibt ihre Entfernung blockiert.

Windowskonten werden nur anhand der bestätigten aktuellen eigenen Gast-SID
entfernt. Konto- und Profilrückbau sind getrennte Schritte. Die dokumentierte
SID-basierte Kontoentfernung ist ein mögliches vorhandenes Primitiv und kein
Nachweis für Fixture-Ownership oder Profilcleanup.
[Microsoft: Remove-LocalUser](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.localaccounts/remove-localuser?view=powershell-5.1).

Linuxkontoentfernung benötigt einen geprüften Werkzeug-/Konfigurationsvertrag,
einschließlich eigener Gruppeneffekte und vorhandener Hooks. Es werden weder
Force-Modi noch pauschale Home-/Mailspool-Löschung verwendet. Die shadow-utils-
Dokumentation beschreibt Prozessblocker, optionale Home-/Mailentfernung,
Hooks und konfigurationsabhängige Gruppenentfernung. Diese Effekte müssen
für das tatsächlich vorhandene Image separat bewertet werden; die Upstream-
Beschreibung ist keine Kompatibilitätszusage für BusyBox oder andere Backends.
[shadow-utils: userdel](https://raw.githubusercontent.com/shadow-maint/shadow/master/man/userdel.8.xml).

## 7. Root, Outside-Sentinel und eigene Home-/Profilressourcen

FSF-04 schlägt ausdrücklich die FSF-01-Auslegung vor: Ein neu erzeugter
äußerer Fixture-Root enthält den inneren Testroot, eigene Arbeitsverzeichnisse
und optional einen separat nachgewiesenen Outside-Sentinel als Geschwister
des Testroots. „Outside“ bedeutet außerhalb des inneren Roots, weiterhin
innerhalb des eigenen äußeren Scopes. Kein beliebiger bestehender Außenpfad
und keine Host-/Shared-Storage-Ausnahme.

Erzeugung, Identität und erwartetes Schutzprofil des Sentinels werden vor dem
Test separat registriert. Der Test darf ihn nicht verändern. Eine Abweichung
blockiert automatisches Paketcleanup und erzeugt Recoverybedarf. Nur ein
ausdrücklich ausgewählter eigener Cleanupschritt darf ihn nach Prüfung
entfernen. Linktestziele liegen im ersten Profil innerhalb des eigenen äußeren
Roots; Linkentfernung behandelt den Link selbst und traversiert kein Ziel.

Jedes zu entfernende Objekt benötigt einen eigenen Manifest-/Erzeugungsbezug
und frische Objekt-, Besitzer-, Rechte-, Mount-/Volume- und Linkbindung.
Unbekannte Kinder, zusätzliche Mounts, neue/abweichende Reparse-/Symlinkziele,
Hardlinks oder unerklärte Besitzer-/ACLdrift blockieren. Die erste Variante
erlaubt keine Hardlink-Testprofile. Der äußerste Root wird nur leer entfernt;
keine Löschung sämtlicher Inhalte aufgrund einer Markerdatei oder UID.
Erlaubte Inhaltsänderungen an eigenen Testdateien sind keine Ownershipdrift,
sofern Profil, Objektidentität und Grenzen erhalten bleiben. Neue unbekannte
Workloaddateien werden nicht anhand ihres Besitzers automatisch adoptiert.

Linux-Homes liegen, falls ausdrücklich angefordert, im eigenen geplanten
Dateipaket. Vorbestehende Homes und Mailspools bleiben fremd. Eigene Gast-
oder Containerdateien werden nicht über Hostzugriff oder neue Mounts entfernt.

Für Windows schlägt FSF-04 eine eng begrenzte Nebenwirkungsregel vor:
Ein durch den kontrollierten ersten Gebrauch des neuen eigenen Gastkontos
erzeugtes lokales Profil darf als private Unterressource dieses Kontos
registriert werden. Es ist eine ausdrückliche Ausnahme für OS-Profilverwaltung
außerhalb des gewöhnlichen Fixture-Roots, keine allgemeine Pfadfreigabe.
Vor Nutzung sind Profilabwesenheit, erwartete Gastprofilwurzel und eigener
SID-Bezug vorab zu binden; danach ist die eigene Profilerzeugung zu bestätigen.
Vorbestehende, spezielle, gemeinsam genutzte, geladene oder nicht eindeutig
eigene Profile werden nicht entfernt. Ein vorhandener nativer Profilpfad
muss seine gesamten Effekte einschließlich Link-/Registrygrenzen nachweisen;
kein manuelles rekursives Löschen eines Benutzerverzeichnisses als Ersatz.
Ohne diesen Nachweis bleibt der profilbildende manuelle Zugang gemäß FSF-02
blockiert. FSF-05 muss diese eng begrenzte Ausnahme ausdrücklich absichern.

Die Windows-Profilklasse führt SID, lokalen Profilpfad und Ladezustand als
getrennte Informationen. Sie ersetzen keinen eigenen Erzeugungsnachweis.
[Microsoft: Win32_UserProfile](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/userprofileprov/win32-userprofile).

## 8. Absenz, Idempotenz und unbekannte Antworten

| Beobachtung im gleichen verifizierten Zielkontext | Bewertung und Folge |
|---|---|
| Eigene Ressource vorhanden und vollständig gebunden | Cleanup nur nach aktueller Freigabe und allen Vorbedingungen |
| Exakte Ressource nach bestätigt dispatchter eigener Löschung nachweislich abwesend | `REMOVAL_CONFIRMED`; wiederholtes Cleanup beobachtet, löscht nichts erneut |
| Ressource aus einem Intent ohne Erzeugungsreceipt autoritativ abwesend und kein möglicher späterer Dispatch mehr offen | ohne Delete als keine Zielressource verblieben dokumentieren; keine eigene Erzeugung behaupten |
| Erwartete Ressource ohne eigenen Löschbeleg plötzlich abwesend | externe Veränderung/Drift; nicht als eigener Löschsuccess oder automatischer Scopeabschluss behandeln |
| Gleicher Name/UID/Pfad jetzt mit anderer Identität oder Generation | fremde beziehungsweise ersetzte Ressource; niemals löschen oder übernehmen |
| Ziel/SQL/Datenbank nicht erreichbar, Beobachtung fehlgeschlagen oder Record verloren | unbekannt; keine Absenz, Recovery erforderlich |

Ein Exitcode, `IF EXISTS`, leerer Suchoutput oder ein abgelegter Tombstone
allein beweist keine aktuelle Absenz. Bestätigung braucht eine autoritative
gebundene Beobachtung derselben Ressource beziehungsweise des exakt
vorregistrierten Zielorts und einen nicht mehr offenen Dispatch. Eine
verschobene/umbenannte Ressource wird nicht durch Namensabwesenheit als
entfernt erklärt; erkanntes Umbenennen oder Verschieben ist Drift.

Nach einer mutierenden Dispatchentscheidung gibt es zunächst null automatische
Wiederholungen. Eine passende RequestRef-Wiederholung liefert nur den privaten
gebundenen Status. Nach Abbruch/Timeout wird höchstens eine zusätzliche
begrenzte lesende Recoverybeobachtung je betroffener Ressource und Operation
versucht; weitere Schritte benötigen eine ausdrückliche neue Recoveryoperation.
Konkrete harte Fristen und Listenlimits sind vor Implementierung in FSF-05/
FSF-06 festzulegen. Die 64-Ressourcen-Grenze aus FSF-03 wird nicht erhöht.

Ein Clienttimeout oder Prozessende beweist nicht, dass eine bereits gestartete
SQL-/Gast-/Containeraktion beendet ist. Solange eine späte Wirkung möglich
bleibt, wird weder neu angelegt noch erneut gelöscht oder die Reservierung
freigegeben. Keine detached/background Zielmutation im ersten Backendprofil.
Ein sicherer erneuter mutierender Versuch benötigt nachgewiesene Beendigung
des vorigen Dispatchs, aktuellen eigenen Zustand, einen neuen konkreten Plan
und Freigabe. Ein altes RequestRef wird nicht neu interpretiert.

## 9. Recovery, Run-Ende und begrenzte lokale Retention

Recovery erhält bestätigte Schritte und den verbleibenden Ressourcensatz.
Sie ist weder automatische Reparatur noch Eigentumsübernahme. Ein verlorenes
Journal, ungültige Integrität oder nicht mehr prüfbare Zielgeneration blockiert
Mutation. Für solche Fälle werden kein Force-Cleanup, fremdes Statefile,
Hostfallback oder neu gestartetes Ersatzlab verwendet.

Alle erreichbaren regulären Lifecyclepfade müssen vor ihrer späteren
Implementierung offene Szenarioreservierungen respektieren. Stop/Remove/
Recreate/Reattach werden nicht als Fixture-Cleanup benutzt. Das vereinbarte
Nutzungsende führt zuerst zu geprüftem Fixture-Cleanup, danach zur Freigabe
der Reservierung und erst dann gegebenenfalls zu einer separat autorisierten
Infrastrukturaktion. Der aktuelle Slice ändert keinen Lifecyclepfad.

SQL-Ausfall erlaubt auch für reine OS-/Dateiressourcen keine READY-Ausnahme.
Externes Entfernen einer VM/eines Containers bestätigt nicht deren einzelne
Fixture-Ressourcen. Ein eigener „Ziel endgültig verloren“-Abschluss- oder
Ownershiptransfervertrag bleibt außerhalb des ersten Scopes; offene Recovery
wird sichtbar erhalten. Fristablauf darf dieses Problem nicht durch Löschung
privater Records verdecken.

Vorgeschlagene lokale Retention: Offene/unklare Ressourcen behalten die
minimalen geschützten Recoveryrecords; Warnung bei Ablauf, keine automatische
Entfernung der erforderlichen Evidence. Nach bestätigtem vollständigem
Scopeabschluss werden Klartextübergaben und eigene nicht mehr benötigte
Credentials entfernt. Ein minimaler Tombstone bleibt für den Run erhalten;
nach dessen bestätigtem Ende bleiben Handle-/ResourceRef-/RequestRef-Nicht-
wiederverwendung und Idempotenz durch einen kompakten gebundenen Abschluss-
index erhalten. Detaillierte operative Records dürfen dann nach einer
ausdrücklich festgelegten endlichen Frist entfallen. Frist, Indexquota und
Vertrauensschutz sind FSF-05-Entscheidungen; bei erreichter Quota wird neue
Annahme blockiert statt offene Records zu verwerfen. Kein unbegrenztes Rohlogarchiv.

Die generische [Cleanup-Engine](../../Private/CleanupEngine.ps1) kennt
providergebundene Pläne und umgekehrte Schrittfolgen. Daraus folgt noch kein
Account-/SQL-Ownershipbeweis, kein sicheres native Identity-Cleanup und keine
Fixture-Reservierung. Auch der [Owned-Host-CI-Vertrag](../Architecture/OWNED_HOST_CI_ISOLATION.md)
ist kein allgemeiner Consumer- oder Fixture-Löschvertrag. Beide werden in
diesem Entwurf weder geändert noch als fertiger Fixture-Backend zugesagt.

## 10. Entscheidungen zur Abstimmung und nächste Nachweise

| ID | Vorschlag für FSF-04 | Konsequenz |
|---|---|---|
| `D1` | Ownership durch private gebundene Recordkette, Vorabintent, eigene Erzeugung und frische native Identität | Namen, UID/SID, Pfad oder Marker allein erlauben keine Löschung. |
| `D2` | Dauerhafter Plan und Schrittjournal vor Mutation; Freigabe einmal annehmen; Crashlücken bleiben unklar | Kein Retry/Adoption ohne Beleg; angenommene Operation bleibt exakt begrenzt. |
| `D3` | Retention je ResourceRef und ausdrücklicher Satz; COMPENSATE_NEW oder bewusstes KEEP_CONFIRMED vorab wählen | Dateitestende entfernt keine aufbewahrten Benutzer; keine implizite Cascade. |
| `D4` | Abhängigkeitsgraph: eigene DB-Benutzer vor eigenem Login, eigene Dateien/Profile vor OS-Konto | Fremde Abhängigkeiten/Ownership blockieren statt Transfer oder orphaned Users. |
| `D5` | Kein erzwungenes Sitzungs-/Prozessende oder automatisches Sperren/Passwortwechseln | Aktive oder nicht sicher ausgeschlossene Nutzung blockiert; Quieszenzbelege folgen in FSF-05/FSF-06. |
| `D6` | Outside-Sentinel nur außerhalb innerem Testroot innerhalb eigenem äußerem Root; Manifestcleanup ohne Zieltraversierung | Host-/Shared-Storage, unbekannte Kinder, Hardlinks und Grenzdrift bleiben blockiert. |
| `D7` | Accountdatensätze und nachgewiesene eigene Hilfsressourcen separat; eng begrenzte Windows-Profilnebenwirkung zulassen | Keine globale Kontodatenbank-Rücksetzung; Profilrückbau verlangt eigenen SID-/Erzeugungs-/Sicherheitsbeleg. |
| `D8` | Eigene Löschung plus gebundene Absenz von unbekannter/externer Abwesenheit unterscheiden; null automatische Mutationsretries | Wiederholung beobachtet; unklarer Dispatch blockiert neue Wirkung und Reservierungsfreigabe. |
| `D9` | READY auch für Cleanup; Fixture-Cleanup vor regulärem Run-Ende, Records bis gebundenem Abschluss erhalten | Kein Infrastrukturfallback, SQL-unabhängige Löschroute oder TTL-Verschleierung von Recovery. |
| `D10` | FSF-04-Freigabe genehmigt ausschließlich dieses Ownership-/Cleanupmodell | FSF-05/FSF-06 und jede Implementierungs-/Runtimefreigabe bleiben offen. |

FSF-05 muss insbesondere Recordintegrität/Rollback, native Generation,
Quieszenz/Races, Backendnebenwirkungen, sichere Profil-/Dateioperation,
Fristen/Quotas und Secret-/Tombstoneretention konkretisieren. FSF-06 benötigt
getrennte positive/negative Belege für Windows/Hyper-V, Linux/Docker und
Linux/Podman: Crash an jedem Journalübergang; späte Antworten; UID-/Principal-
Wiederverwendung; aktive Sessions; foreign Ownership; erhaltene manuelle
Benutzer; eigene/fremde Gruppen und Profile; geänderte Mounts/Links/Sentinel;
unbekannte Kinder; teilweise Entfernung; SQL-Ausfall; zweimaliges Cleanup
und bestätigte eigene Absenz. Keine native Löschung wird hier ausgeführt.

Der Abstimmungsstatus ist `PENDING`. Gekoppelte Quellen bleiben
[FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md),
[FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md),
[FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md),
[Repo-Map](../../.ai/repo_map.yaml),
[Arbeitsregeln](../../.ai/WORKING_RULES.md) und
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
Die technischen Primärquellen wurden am 2026-10-11 gelesen; sie erklären
native Grenzen, keine Projektfreigabe oder ausgeführte Fixture-Evidence.
