# FSF-I02 – Nächster Implementierungsscope: privater Identitäts-Anfragevalidator

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_PRIVATE_REQUEST_VALIDATOR` – interner Formbaustein; native Fixtureverwaltung bleibt geplant |
| Scope | `FSF-I02`, Revision `0.1`, Stand 2026-10-11 |
| Freigabe und Auftrag | ausdrücklich durch den Repository-Eigentümer am 2026-10-11: FSF-I02 implementieren, eigener Branch/PR, parallele Welle schützen |
| Grundlage | FSF-01 Revision `0.2`, FSF-02 bis FSF-06 jeweils Revision `0.1`; alle freigegeben |
| Bestand | FSF-I01 in PR #741 integriert; `origin/main` bei `fea35ee9` |
| Ziel | einen geschlossenen privaten Anfragevertrag für getrennte OS-/SQL-Identitäten im Speicher vollständig prüfen |
| Aktueller Auftrag | ausschließlich der freigegebene private Anfragevalidator, synthetische Abnahme und begrenzte Integration; keine Identitätsanlage oder native Mutation |

## 1. Empfehlung und Abgrenzung

Als nächsten kleinen Baustein empfehle ich einen privaten Identitäts-
Anfragevalidator. Er prüft die Form, Mengen, ausdrücklichen Beziehungen und
Nutzungs-/Retentionangaben einer neuen Anfrage. OS-only, SQL-only und bewusst
kombinierte manuelle oder automatisierte Szenarien benötigen weder Dateien
noch einen Testexecutor. Beispielsweise kann eine SQL_PerformanceSchulung
zwei neue SQL-Logins und eigene Benutzer für dieselbe ausgewählte Datenbank
beschreiben; ihre verschiedenen Rechteprofile bleiben ausdrücklich ausgewählt.

Der integrierte [FSF-I01-Codec](FILESYSTEM_FIXTURE_IMPLEMENTATION_SCOPE_01_DRAFT.md)
prüft bereits den zweifeldrigen Handle. Er erzeugt keine Identitäten und
autorisiert nichts. Dieser Slice ergänzt einen anderen Formvertrag und ändert
weder Handlebytes noch Exporte oder dessen Fehlerverhalten.

Eine gültige Anfrage ist **kein gebundener Ausführungsplan und keine Freigabe**.
TargetRef, RequestRef, Datenbank- und Profilreferenzen werden hier nur formal
geprüft. Tatsächlicher Betreiber, Consumer, Run/Store, Zielgeneration, Profil-
und Datenbankauflösung, aktuelle Revision, frisches SQL-READY, Admission,
Ownership, Grant und Lifecycle-Reservierung bleiben spätere Voraussetzungen.
Der Validator darf weder `AVAILABLE`, `READY`, `CREATED` noch einen
angenommenen Plan oder nutzbaren Zugang behaupten.

Damit bleibt der Scope kleiner als eine Autorisierungs-/Store-/Createkette.
Der später nötige konkrete gebundene Plan wird aus dieser Anfrage und
unabhängig geprüftem privatem Kontext aufgebaut; Callerfelder werden dabei
nicht zu authentisierten Tatsachen erhoben.

## 2. Vorgeschlagener geschlossener Anfragevertrag

Dies sind freigegebene **private Vertragsentscheidungen**, im internen
Validator umgesetzt; keine öffentliche API oder externes Serialisierungsschema.

Eingang ist ausschließlich eine explizite UTF-8-Bytesequenz im Speicher.
Ein neues privates Script enthält nur nebenwirkungsfreie Funktionsdefinitionen.
Vor Projektion gilt: höchstens 16 KiB, strikt gültiges UTF-8 ohne BOM, genau
ein JSONobjekt, keine Kommentare, trailing commas, zusätzlichen Roots oder
unbekannten Felder. Nach JSON-Escape-Decodierung ordinale Feldnamen und
Duplicate Keys prüfen, auch in verschachtelten Objekten. Insgesamt höchstens
128 Propertyvorkommen und Tiefe 8; die feste Shape bleibt zusätzlich enger.
Die Tiefe zählt das Rootobjekt als 1 und jeden weiteren Objekt-/Arraycontainer
als eine Ebene. Keine PowerShell-Konvertierung beliebiger Laufzeitobjekte.

| Rootfeld | Vorgeschlagene Bedeutung und Form |
|---|---|
| `ContractVersion` | exakt String `1.0`; keine automatische Migration |
| `RequestRef` | Caller-Korrelation: kanonische nicht leere/Nil-UUID-D-Form in Kleinbuchstaben; kein Grant oder neuer Handle |
| `TargetRef` | gleichartige undurchsichtige Referenz auf das später separat gebundene SQL-Labziel; keine freie Route oder Zielgeneration |
| `ScenarioAlias` | 1 bis 32 ASCII-Buchstaben, Ziffern oder Unterstriche; logische SQL-Szenariokorrelation, kein Freitextmetadatenblock |
| `OsIdentities` | immer vorhandenes Array mit 0 bis 16 OS-/numerischen Deskriptoren |
| `SqlIdentities` | immer vorhandenes Objekt mit genau den Arrays `Logins` (0 bis 16) und `DatabaseUsers` (0 bis 32) |

Mindestens ein Identitätsdeskriptor ist Pflicht, insgesamt höchstens 64.
Die Teilobergrenzen, Byte-, Feld- und Tiefenbudgets gelten gleichzeitig;
ein maximaler Ressourcenzähler garantiert nicht, dass eine Anfrage mit allen
ausführlichen Deskriptoren ins kleinere Feld-/Bytebudget passt. Kein Override
und kein stilles Kürzen. Dateisystemressourcen sind in diesem Slice noch
nicht anforderbar; die Gesamtgrenze aus FSF-05 wird dadurch nicht erhöht.

### Getrennte Deskriptoren

| Array | Exakt erlaubte Pflichtfelder |
|---|---|
| `OsIdentities` | `Alias`, `Kind`, `Usage`, `Retention` |
| `SqlIdentities.Logins` | `Alias`, `Usage`, `Retention`; Art ausschließlich `SQL_AUTH_LOGIN`, durch dieses Array festgelegt |
| `SqlIdentities.DatabaseUsers` | `Alias`, `LoginAlias`, `DatabaseRef`, `ProfileAlias`, `Usage`, `Retention`; Art ausschließlich `SQL_DB_USER_MAPPED` |

`Alias`, `LoginAlias` und `ProfileAlias` verwenden die gleiche 1–32-ASCII-
Grammatik wie ScenarioAlias. `DatabaseRef` ist eine kanonische Nicht-Nil-UUID
wie TargetRef, keine Datenbankbezeichnung. ProfileAlias ist nur eine logische
Referenz: der spätere vertrauenswürdige Profilresolver muss das konkrete
nicht privilegierte Profil und seine gebundenen Objekte auflösen. Ein
syntaktisch erlaubter Alias bedeutet keine erlaubten Rechte. Keine freien
SQL-/Shelltexte, Objektlisten, Rollen, Grant-/Denybefehle oder Commands.

Für OS gilt exakt eine der Arten aus FSF-03: `WINDOWS_LOCAL_ACCOUNT`,
`LINUX_LOCAL_ACCOUNT`, `LINUX_NUMERIC_CONTEXT`. Ihre Formprüfung ist keine
Plattformfreigabe. Numerische Kontexte beschreiben die spätere eigene
Reservierung; sie enthalten keine frei vorgegebenen nativen UID/GID und
versprechen weder Konto, Passwort noch Kontenanmeldung. Name, SID, UID/GID,
Namespace und native Namenskollisionen werden erst im gebundenen Folgescope
ermittelt. SQL-Kindfelder oder Datenbank-/Loginreferenzen in OS-Deskriptoren
sind ebenso ungültig wie OS-Felder im SQL-Vertrag.

Aliase sind innerhalb des OS-Arrays und innerhalb des Loginarrays eindeutig.
Bei Datenbankbenutzern ist das Paar aus DatabaseRef und Alias eindeutig.
Für Kollisionsprüfung der ASCII-Aliase wird ordinal ohne Beachtung der
Groß-/Kleinschreibung verglichen; keine kulturabhängigen Steuerzeichenaliase.
Dies ersetzt keine native SQL-Collation-/OS-Kollisionsprüfung.
Ein gleichlautender OS- und SQL-Alias ist erlaubt und koppelt nichts.
LoginAlias eines DB-Benutzers muss genau einen Login **dieser Anfrage**
referenzieren; die Referenz ordinal in exakter Schreibweise nur innerhalb
dieses Loginarrays auflösen. Eine Caseabweichung der Referenz, ein OS-Alias oder
ein vorhandener fremder Login ist kein Ersatz. Unterschiedliche ausgewählte
Datenbanken erzeugen unterschiedliche Benutzerdeskriptoren.

Dieser kleine Slice beschreibt nur eine neue Anfrage. Ergänzungen zu bereits
existierenden eigenen Logins/Scopes, Inventarrevisionen, Remove/Recovery und
freie Dependencies bleiben späteren gebundenen Operationsverträgen vorbehalten.
Windows-Authentisierung, Contained User und WITHOUT LOGIN bleiben gemäß
FSF-02 zurückgestellt beziehungsweise ausgeschlossen, ohne Typausweichweg.

### Nutzung und Retention

Usage ist exakt `MANUAL`, `AUTOMATED` oder `MANUAL_AND_AUTOMATED` je Identität.
Es benennt beabsichtigte Nutzung, kein bereitgestelltes Credential oder
Programm. Manuelle numerische Rekonstruktion bleibt ein Prozess-/Rechtefall
ohne Kontenanmeldung. Automatisierung löst keine besondere Benutzerklasse aus.

Retention ist ein geschlossenes Objekt mit `Mode` und ausschließlich bei
`SCENARIO` einem optionalen `DurationSeconds`:

- `OPERATION`: keine DurationSeconds; nur für ausschließlich automatisierte
  Nutzung. Der spätere angenommene Operationsplan bestimmt das Nutzungsende.
- `SCENARIO`: eine ganzzahlige Dauer von 1 bis 86.400 Sekunden; fehlt sie,
  wird explizit auf 14.400 Sekunden normalisiert. Manuelle und gemischte
  Nutzung verlangen diesen Modus. Keine absolute Uhrzeit, Uhrabfrage oder
  Verlängerung in diesem Validator.

Ein DB-Benutzer darf seinen Login nicht länger benötigen als dessen
vereinbarter Umfang: SCENARIO beim Benutzer verlangt SCENARIO beim Login
mit mindestens derselben Dauer. Seine Usage muss vom Login umfasst sein.
Ein OPERATION-Benutzer darf einen länger behaltenen SCENARIO-Login
referenzieren. Keine automatische Retentionänderung oder Cascade.
Fristablauf und Relock werden hier weder überwacht noch ausgeführt;
sie löschen auch später keine Identitäten automatisch.

### Privates Ergebnis und Fehlergrenze

Erfolg liefert nur eine neue, von Eingangsbytes unabhängige private
Anfrageprojektion mit denselben Arten, Aliaswerten, expliziten Beziehungen
und normalisierter Dauer. Eingangsreihenfolge erhalten; nicht sortieren,
zusammenlegen oder Identitäten/UUIDs erzeugen. Keine JSON-Ausgabe-/Speicher-
API, Planhash, Inventarrevision oder synthetischer Erzeugungsbeleg.

Für den neuen Helper wird ein festes privates Ergebnis mit `Success`, `Value`
und `ErrorCode` vorgeschlagen: bei Ablehnung nur `Value = null` und
`FIXTURE_REQUEST_INVALID`. Keine Raw-Parserexception, Input-TargetObject,
Stack-/Pfad-/Endpoint-/Secretmarker in Streams oder Fehlerverlauf.
Bei Erfolg ist Value ein **privater** normalisierter Request, kein öffentliches
Inventar oder Logobjekt. Kein Logging/Echo gültiger oder ungültiger Rohrequests.
Das Ergebnis von FSF-I01 und öffentliche Fehlerverträge bleiben unverändert.

## 3. Freigegebene Änderungsfläche

| Geplanter Pfad | Begrenzte spätere Änderung |
|---|---|
| `Private/FixtureIdentityRequest.ps1` | neuer privater, reiner Byte-/Form-/Beziehungsvalidator; keine native Ausführung |
| `Tests/Static/Invoke-FixtureIdentityRequestChecks.ps1` | synthetische unabhängige Offline-Abnahme, tatsächlicher Modulimport und Privacy-/Nebenwirkungsgrenzen |
| `Tools/Get-CiTestSelection.ps1` | exakt additive Zuordnung dieser zwei Pfade; Ausnahme nur für ihre bewiesene reine Wirkung |
| `Tests/Static/Invoke-CiStrategyChecks.ps1` | exakte/ähnliche/gemischte Pfade prüfen; bisherige Codec-/Provider-/Cleanupauswahl erhalten |
| `.ai/repo_map.yaml` | tatsächliche private Quelle/Testzuordnung erst mit Umsetzung ergänzen |
| dieses Scopedokument, Fixture-Backlog und Planungsindex | Freigabe, Umsetzung und offene Folgescopes nachführen |
| `Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md` | tatsächlich ausgeführte, sourcegebundene Nachweise; kein Native-PASS |

Keine Änderung am FSF-I01-Codec, Manifest/Loader oder Exportliste, keine
Public-/Console-/UI-/HTTP-Schnittstelle, Schemas für externe API, Store/
Schlüssel/Anker/Journals, SecretProvider, SqlReadiness, Lifecycle, CleanupEngine,
Provideradapter oder Runtime-Harnesses. Nur vorhandene Frameworkmittel unter
PowerShell 7.2; keine neue Bibliothek oder Toolchain-Produktabhängigkeit.
Der I01-Regexcodec wird nicht zum allgemeinen Requestparser umgebaut.

## 4. Fokussierte Abnahme des späteren Slices

Sollrequests, erwartete Beziehungen und Grenzen unabhängig vom Validator
festlegen. Der Scope deckt nur die Form-/Anfrageanteile von FSF-06 T-C01,
T-C05, T-C07, T-C08 und T-Q01; keine gesamte Fallgruppe wird damit erfüllt.

Grenzfälle müssen das jeweils andere Budget einhalten; falls die feste Shape
einen rechnerischen Maximalwert nicht erreichbar macht, die strengere Shape-
Ablehnung nachweisen, statt einen ungültigen Rand als gültig zu behaupten.
Feldzählung schließt jedes Propertyvorkommen auf jeder Objektebene ein,
einschließlich vor Projektion erkannter Duplikate. Whitespace zählt zum
Bytebudget, nicht als Feld oder zusätzliche Tiefe.

| Kriterium | Konkreter erforderlicher Nachweis |
|---|---|
| `I02-A01` | OS-only, SQL-only und Kombination ohne Dateien; mehrere Benutzer, mehrere Datenbanken; MANUAL/AUTOMATED/gemischte Nutzung unverändert projiziert |
| `I02-A02` | gleiche OS-/SQL-Aliase bleiben unabhängig; nur ausdrückliche SQL-Loginbeziehung, keine automatische Verknüpfung oder Anlage zusätzlicher Ressourcen |
| `I02-A03` | unterschiedliche Case-/Escapeformen von Feldnamen, Duplicate Keys auf allen Ebenen, unbekannte Felder, falsche Version/UUID/Typen, BOM/defektes UTF-8, Kommentare/trailing commas/mehrere Roots abgewiesen; ordinale NUL-/Backspacegrenzen |
| `I02-A04` | 16/17 OS-, 16/17 Login- und 32/33 DB-Benutzerdeskriptoren, 32/33 Aliaszeichen, 128/129 Felder und 16.384/16.385 tatsächliche UTF-8-Bytes unabhängig prüfen; Shape- und Tiefenüberschreitungen (auch Tiefe 9) ablehnen; kombinierte Budgets und integer Overflow/Float/String statt Dauer; keine stille Kürzung |
| `I02-A05` | fehlender/fremder/OS-/mehrdeutiger LoginAlias, Aliasduplikate und doppelte DB-/Aliaspaare abgewiesen; unterschiedliche Datenbankreferenzen bleiben getrennt |
| `I02-A06` | Retentiondefault 14.400, gültige Dauer 1/86.400 und ungültige 0/86.401; MANUAL+OPERATION, SCENARIO-User+OPERATION-Login, zu kurze Logindauer und unpassende Usage blockiert; keine automatische Elternanpassung |
| `I02-A07` | freie Pfade, Credentials, native Namen/IDs, Owner-/Grant-/READYselbstauskunft, SQL/Shell und ausgeschlossene Identitätsarten nicht einschleusbar; numerische Kontexte ohne Konto-/Zugangszusage |
| `I02-A08` | synthetische Secret-/Endpoint-/Pfadmarker und Parserfehler fehlen in allen Ausgabestreams, Fehlerverlauf und eigenem Transcript; Eingang unverändert, separate private normalisierte Value |
| `I02-A09` | kein IO, Storescan, Schlüssel-/UUIDerzeugen, Clock-, Provider-/SQL-/Prozessdispatch, Grant/Reservation oder Top-Level-Initialisierung; tatsächlich unveränderte Modulexporte und keine LoadErrors |
| `I02-A10` | beide genauen neuen Pfade mit beiden Separatoren wählen die neue Suite; andere Ordner/Teilnamen/Caseabweichungen erhalten konservative Fallbacks; gemischte Diffs erhalten bestehende Suites und Runtimefähigkeiten |
| `I02-A11` | I01-Nichtregression, PowerShell 7.2 und aktueller Host, betroffene statische Suites und GitHub-Pflichtgate auf exaktem Integrationshead; Windows/Ubuntu getrennt von native OS-/SQL-Fähigkeiten |

Zuerst fokussierte neue Abnahme samt benötigter I01-Regressionsprüfung,
dann betroffene Auswahl über Invoke-ImpactedChecks. Unveränderte grüne
Prüfungen bei identischer relevanter Bindung nicht nochmals ausführen.
Die enge neue Zuordnung muss I01 erhalten; falls die neue Suite dessen
UUIDhelper verwendet, den direkten Aufrufer auch bei Änderungen am I01-Helper
in die Auswahl aufnehmen und beide Suiten koppeln. Keine globale Fixtureausnahme.
Bestehende Analyzer-/Pesterpflicht und Pflichtgate bleiben bestehen.
Nur eine neue fokussierte Suite, kein zusätzlicher AllChecks-Eintrag, keine
Providerstarts für nachgewiesen reine Formverarbeitung. Ein breiterer Diff
ändert Auswahl und genehmigten Scope; fehlende Native-Belege bleiben offen.

## 5. Parallele Welle und aktueller Dokumentationsscope

Bestandsaufnahme: #737 Autostart bei `46d68369`; #738 SMTP bei `fd9805b6`,
weiterhin auf dem Autostartbranch. Die geplanten neuen privaten Anfrage-/
Testpfade kommen in diesen PRs nicht vor. #738 bearbeitet jedoch Selektor,
Repo-Map und Validierungsstrategie. Diese Momentaufnahme reserviert keine
Dateien und ändert weder Priorität noch Scope der parallelen Welle.

Der historische Dokumentationsbranch in PR #742 basiert auf `origin/main`
bei `fea35ee9` und enthält ausschließlich den Scope-/Indexstand. Der eigene
Implementierungsbranch `codex/fixture-identity-request` baut auf dessen
freigegebenem Head `10741557` auf und ändert nur Abschnitt 3. PR #742 bleibt
unverändert; vor späterer main-Integration muss die Dokumentation integriert,
der Implementierungs-PR umgestellt und sein aktueller Pflichtgate geprüft sein.
Ausgeführte Offline-Abnahmen stehen in Abschnitt 7; Dokumentations-PASS allein
bleibt kein Validatornachweis. Native FSF-06-Abnahmen bleiben NOT_EXECUTED.

Vor späterem Codeauftrag aktuelle main-/PR-Diffs und Namenskollisionen
erneut prüfen, eigener isolierter Branch und eigener Implementierungs-PR.
Gemeinsame Selektor-/Map-/Evidencehunks erst gegen geprüfte aktuelle Basis
übernehmen. Keine fremden Worktrees/Branches ändern, staschen, resetten,
rebasen oder deren Jobs abbrechen. Bei unklarer Koexistenz den gemeinsamen
Hunk zurückhalten und die Basis klären; keine ganze Datei überschreiben.

## 6. Entscheidung und folgende Voraussetzungen

Das **Scopepaket FSF-I02** aus Abschnitt 2 einschließlich Nutzungs-/
Retentionregeln, Änderungsfläche und A01 bis A11 wurde ausdrücklich
freigegeben und konkret beauftragt. Der Freigabestatus ist `APPROVED`
für Revision `0.1`; die Autorität bleibt auf diesen privaten Baustein begrenzt.

Nach diesem Slice bleiben gesondert auszuarbeiten: tatsächlich gebundener
Plan und einmalige Autorisierung; geschützte Records/Schlüssel/Fortschrittsanker
mit Hostbelegen; native Ziel-/Datenbank-/Profil-/Rechteprüfung und wirksame
Lifecycle-Reservierung; danach ein kleiner eigenständig nutzbarer nativer
OS- oder SQL-Slice einschließlich Zugang, Ownership, Retention und Cleanup.
Dies ist ein Abhängigkeitsausblick ohne automatische Reihenfolge-/Ausführungsfreigabe.

## 7. Interne Umsetzung und begrenzte Evidence

`ConvertFrom-FixtureIdentityRequestBytes` liefert das private Ergebnis
Success/Value/ErrorCode, bei Ablehnung nur `FIXTURE_REQUEST_INVALID`.
Ein begrenzter interner Tokenreader prüft Strings, Integer, Objekt-/Array-
Struktur und die Budgets vor der Projektion. Feldnamen werden nach
Escape-Decodierung in ordinalen Dictionaries auf Duplikate geprüft.
Jede gültige geschlossene Form hat nur ASCII-UTF8-Bytes; ASCII-Unicode-Escapes
werden akzeptiert. Andere Bytes einschließlich BOM/defektem UTF8 können
keine gültige Form ergeben. Kein allgemeiner JSONreader oder Parserexception.
Auch eine überschriebene Length-ScriptProperty am byte[] wird nicht gelesen.

Die neue Suite bestand unter PowerShell 7.2.24/.NET 6.0.35 mit
**513 PASS / 0 FAIL**: unabhängige Sollprojektion, Budget-/Referenz-/Typ-/
Escape-/Retentionfälle, sämtliche abgeschnittenen Byteprefixe, Streams und
Fehlerverlauf, tatsächlicher Modulimport, unveränderte Exporte und eigener
entfernter Transcript. Die strengere 128-Feldgrenze verhindert gültige
Anfragen mit 32 ausführlichen DB-Benutzern; dieser Wert wird nicht als
bestandener gültiger Rand ausgegeben. 127/128-Feldfälle sind unabhängig
berechnet und akzeptiert, 129 Felder abgewiesen.

Geprüfte Git-Sourceblobs: Validator `1857f3a13c3304fd2c11afd57f1d0b3f83bdb933`,
Suite `70a78e0de7a5f32e72b9d331c01b269d06f91a17`.
Der betroffene lokale Abschluss-Gate unter PowerShell 7.6.6/.NET 10.0.12
bestand mit Validator 513/0, I01 116/0, CI-Strategie 599/0,
Dokumentation 1887/0, Pester 23/0 (kein Skip), Privacy 3/0 und Analyzer PASS
ohne Error-Fundmeldungen mit 24 freigegebenen Baselinebefunden;
Warnungen bleiben ausgewiesen. Selektor-Sourceblob
`9ccf8baf38de8eaf7b515ad73f2e8a9442a8f074`, CI-Assertions
`1e76c56508aa18ce3058316380a5275ece293d6e`.
Nach dieser Evidenceergänzung werden nur die betroffenen Dokumentations-/
Privacychecks wiederholt; die vier ausführbaren Quellen bleiben byteidentisch.
Der UUIDhelper aus FSF-I01 bleibt byteidentisch. Die genaue Selektorregel
koppelt beide Suiten an Änderungen seiner Quelle oder des neuen Validators;
die bestehenden I01-/unbekannten Produkt-/gemischten Providerfallbacks bleiben
erhalten. Lokaler Abschluss-Gate und GitHub-Integration werden getrennt
ausgewiesen; aus lokalen Läufen wird kein CI-PASS abgeleitet.
Keine Native-OS-/SQL-/Store-/Grant-/Cleanup-/manuellen Zugangsabnahmen.

Verarbeitungsaufwand: eine zusätzliche fokussierte Suite mit der gezielten
I01-Aufruferkopplung, keine neue AllChecks-Registrierung oder globale
Fixtureausnahme. Bestehende Analyzer-/Pesterpflicht und Pflichtgate bleiben
erhalten. Rohlogs und lokale Mindestversion-Toolchain bleiben unversioniert.

Gekoppelte Quellen: [Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md),
[FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md),
[FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md),
[FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md),
[FSF-04](FILESYSTEM_FIXTURE_OWNERSHIP_CLEANUP_DRAFT.md),
[FSF-05](FILESYSTEM_FIXTURE_SECURITY_DRAFT.md),
[FSF-06](FILESYSTEM_FIXTURE_TEST_STRATEGY_DRAFT.md),
[Repo-Map](../../.ai/repo_map.yaml), [Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Kostenpolitik](../Quality/COST_EFFICIENT_DEVELOPMENT.md),
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md).
