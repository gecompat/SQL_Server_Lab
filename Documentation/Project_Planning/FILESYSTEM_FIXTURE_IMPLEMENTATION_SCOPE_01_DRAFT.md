# FSF-I01 – Erster Implementierungsscope: interner Fixture-Handle-Codec

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTATION_SCOPE_DECISION_DRAFT` – zur Abstimmung, nicht freigegeben |
| Scope | `FSF-I01`, Revision `0.1`, Stand 2026-10-11 |
| Grundlagen | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md) Revision `0.2`; [FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md), [FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md), [FSF-04](FILESYSTEM_FIXTURE_OWNERSHIP_CLEANUP_DRAFT.md), [FSF-05](FILESYSTEM_FIXTURE_SECURITY_DRAFT.md) und [FSF-06](FILESYSTEM_FIXTURE_TEST_STRATEGY_DRAFT.md) jeweils Revision `0.1`; ausdrücklich freigegeben am 2026-10-11 |
| Ziel | geschlossene Handleform intern im Speicher prüfen und deterministisch serialisieren; ein vollständig abnehmbarer erster Baustein |
| Basis der Bestandsanalyse | `origin/main` bei `a6b5a6b3`; Entwicklungs-PRs #737/#738 getrennt, Dokumentations-PR #740 |
| Aktueller Auftrag | ausschließlich diese Scopeausarbeitung und Dokumentation der FSF-06-Freigabe; keine Implementierung |

## 1. Empfehlung und Nutzen

Als ersten kleinen Scope empfehle ich den privaten Codec für die bereits in
FSF-03 festgelegte zweifeldrige Handleform. Er liest begrenzte UTF-8-JSONdaten,
prüft deren geschlossenen Aufbau und schreibt dieselbe Referenz in einer
festen kompakten Darstellung zurück. Synthetische Offline-Tests können den
gesamten Codec abnehmen, ohne einen Benutzer, SQL-Zugang oder eine Runtime
anzulegen. Der Baustein ist gemeinsam für spätere OS-only-, SQL-only- und
kombinierte manuelle/automatisierte Abläufe nutzbar.

Die eigentliche Benutzeranlage braucht zuvor geschützte Records, konkrete
Autorisierung, Ziel-/Generationsprüfung, Lifecycle-Reservierung und einen
gesicherten Cleanupweg. Dafür gibt es noch keine implementierte Fixturekette.
Ein sofortiger nativer Create-Slice müsste diese gekoppelten Voraussetzungen
mit implementieren und wäre kein kleiner erster Scope. FSF-I01 schließt einen
eigenständigen Formatvertrag vollständig; die Benutzerfunktion bleibt geplant.

Der Codec bestätigt ausschließlich Syntax/Form. Ein korrekt lesbarer fremder
Handle darf syntaktisch gültig sein und trotzdem später nicht auflösbar oder
autorisiert sein. Hier gibt es weder Owner-/Storeprüfung noch Admission,
Capability-AVAILABLE, READY, Erzeugungsnachweis oder Operationsfreigabe.

## 2. Konkret vorgeschlagenes Verhalten

| Eingang/Ausgang | Vertrag innerhalb FSF-I01 |
|---|---|
| Lesen | explizite UTF-8-Bytesequenz im Speicher, höchstens 256 Byte; genau ein JSONobjekt mit ausschließlich `ContractVersion` und `HandleId`, beide Strings |
| Version | exakt `1.0`; keine automatische Migration, Kürzung oder Versionsvermutung |
| ID | kanonische UUID-D-Form mit Kleinbuchstaben und Bindestrichen; leere/Nil-ID, Brace-/Compactform und nicht kanonische Eingaben ablehnen; kein zusätzlicher UUID-Versionszwang |
| Propertynamen | exakt geschrieben; nach JSON-Decodierung auf Duplikate prüfen, einschließlich unterschiedlich escapeter gleicher Namen; keine case-insensitive Hashtable als alleiniger Parser |
| JSONform | Feldreihenfolge und regulärer JSONwhitespace dürfen variieren, wenn die Gesamtgröße passt; keine Kommentare, trailing commas, zusätzlichen Roots, Arrays, geschachtelten Werte oder Präfixdaten |
| Schreiben | nur die geprüften beiden Stringfelder, feste Reihenfolge Version/ID, kompakte UTF-8-Darstellung ohne BOM; ID/Werte unverändert, ebenfalls höchstens 256 Byte |
| Fehler | fester begrenzter privater Fehler ohne Eingabeecho, Raw-Parserexception, Input-TargetObject, Stack-/Pfad-/Endpoint-/Secretmarker; keine neuen öffentlichen Fehler-/DTO-Verträge |
| Seiteneffekte | keine IO, UUID-Erzeugung, zufällige Schlüssel, Uhr-/Umgebungsabfrage, State-/Record-/Grant-/Indexanlage oder Provider-/SQL-Aufrufe |

Der Encoder verwirft Zusatzdaten nicht stillschweigend: unbekannte oder falsch
typisierte Eingaben sind ungültig. Kein Downcast eines nativen Runtimeobjekts
in einen scheinbar gültigen Handle. Typisierte private Signaturen werden im
Implementierungsslice so gewählt, dass rohe Nutzereingaben nicht bereits durch
ungeprüfte PowerShell-Objektkonvertierung ausgeführt oder offengelegt werden.
Das Vertrauensmodell aus FSF-05 für beliebigen same-user Hostcode bleibt bestehen.

Vorhandene Frameworkmittel unter der im Modulmanifest festgelegten
PowerShell-Mindestversion `7.2` verwenden; keinen JSONparser, neue Bibliothek,
Frameworkupgrade oder Package als Abhängigkeit einführen. Ein JSONreader muss
Duplicate Keys und UTF-8-Fehler zuverlässig vor jeder Objektprojektion prüfen.
Ein Ordner unter Private macht einen Helper noch nicht sicher: das Modul lädt
Private-Scripts automatisch; deshalb enthält die Datei ausschließlich
nebenwirkungsfreie Funktionsdefinitionen und keine Initialisierung mit Wirkung.

## 3. Erlaubte zukünftige Änderungsfläche

Die folgenden Pfade sind geplante Lieferartefakte, noch keine bestehenden
neuen Dateien. Die endgültige Freigabe gilt für diesen fachlichen Umfang;
vor Codebeginn Existenz, Namenskollisionen und aktuelle Sourcebasis prüfen.

| Pfad | Erlaubte Änderung im späteren FSF-I01-Auftrag |
|---|---|
| `Private/FixtureHandleContract.ps1` | neuer begrenzter privater Parser/Encoder; kein zusätzlicher Store, Adapter oder Controller |
| `Tests/Static/Invoke-FixtureHandleContractChecks.ps1` | neue fokussierte synthetische Offline-Suite für Abschnitt 5 und Import-/Privacygrenzen |
| `Tools/Get-CiTestSelection.ps1` | additive exakt pfadgebundene Zuordnung dieser beiden Dateien zur neuen Suite; nur diese reine Helperwirkung ohne Runtime-Smoke einordnen |
| `Tests/Static/Invoke-CiStrategyChecks.ps1` | positive/negative/mixed-path Auswahlassertions für die enge neue Zuordnung; vorhandene Fallbacks/Spuren erhalten |
| `.ai/repo_map.yaml` | neue tatsächliche private Quelle/Testzuordnung erst nach ihrer Implementierung; Planung und native offene Fähigkeiten getrennt behalten |
| dieses Scopedokument und Fixture-Backlog | Freigabe-/Umsetzungs-/Evidencezustand nachführen, genau an tatsächliche Leistung gebunden |
| `Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md` | kurzer ausgeführter Codec-/Selektor-Nachweis mit exakter Revision; keine native Fixtureabnahme behaupten |

Keine anderen Produktionsdateien ändern. Insbesondere keine Exports/Public-
Cmdlets, Manifest-/Inventar-/Recordschemas, Console-/UI-Routen, Provideradapter,
SecretProvider-/SqlReadiness-/CleanupEngine-/Lifecycleänderungen oder neue
Runtime-Harnesses. Modulmanifest und Loader bleiben unverändert; der vorhandene
Private-Loader muss die Datei fehlerfrei aufnehmen. Keine unabhängigen Refactorings.

## 4. Parallele Welle und Integrationsbedingung

Die read-only PR-Prüfung am 2026-10-11 zeigt: #737 bearbeitet Container-/Hyper-V-
Autostart; #738 bearbeitet den SMTP-Gateway und unter anderem
`Tools/Get-CiTestSelection.ps1`, `.ai/repo_map.yaml` und die Validierungsstrategie.
Damit überschneiden sich geplante Integrationsdateien mit #738. Die beiden
neuen Codecdateien sind in den geprüften PR-Ständen nicht vorhanden.
Dies ist eine Momentaufnahme, keine künftige Dateireservierung.

Vor einem späteren FSF-I01-Codeauftrag aktuellen main-/PR-Diff erneut lesen
und einen eigenen isolierten Implementierungsbranch von der dann aktuellen
Basis verwenden. Keine Änderungen, Stashes, Resets, Rebases oder Commits in
den Checkouts/Branches der parallelen Welle. Dokumentations-PR #740 erhält
weiterhin ausschließlich die Planung; Codecimplementation bekommt einen
eigenen kohärenten PR.

Die gemeinsamen Selektor-/Map-/Evidencehunks werden erst gegen eine geprüfte
Integrationsbasis übernommen: entweder enthält origin/main die einschlägigen
#738-Änderungen bereits, oder ihre konkret koexistierenden aktuellen Hunks
sind vor Integration abgeglichen. Kein automatisches Überschreiben/Übernehmen
einer ganzen Datei, keine fremde PRänderung und keine Wellenumpriorisierung.
Ist die Koexistenz unklar oder das gemeinsame Diff in Bewegung, darf der
gemeinsame Integrationshunk nicht veröffentlicht werden; der kohärente
FSF-I01-Abschluss wartet auf eine geklärte Basis. Die heutige Scopeplanung
ändert diese Dateien nicht außerhalb der Dokumentationsindizes.

## 5. Fokussierte Abnahmekriterien

Alle Fälle verwenden synthetische Handles und Marker; keine echten Owner-/
Run-/Ressourcenreferenzen. Sollbytes/Felder werden unabhängig vom Produktcodec
festgelegt. Es werden Vertragsverletzungen geprüft, keine bloßen Spiegeltests
der gewählten Implementierung. Die Teildeckung von FSF-06 ist ausdrücklich
auf C05/C07/C08 und Q01 beim Handle sowie den reinen Handleanteil von C01/C06
begrenzt. Diese gesamten Fallgruppen sind dadurch noch nicht bestanden.

| Kriterium | Zu prüfender konkreter Nachweis |
|---|---|
| `I01-A01` | gültiger synthetischer Handle wird als genau zwei Strings gelesen; Encoder liefert unabhängig festgelegte kompakte Sollbytes und dieselbe ID; Parsing allein erzeugt keinen fachlichen Outcome |
| `I01-A02` | beide Feldreihenfolgen/regulärer Whitespace innerhalb Größe akzeptiert; deterministische Ausgabe unverändert bei wiederholter Verarbeitung |
| `I01-A03` | gültige Eingaben mit 255/256 UTF-8-Bytes akzeptiert, 257 abgewiesen; Mehrbytezeichen, unvollständige/ungültige UTF-8-Sequenzen und Präfix-/BOMdaten nicht durch Zeichenzahlprüfung durchlassen |
| `I01-A04` | fehlende/unbekannte/zusätzliche Felder, falsch geschriebene Namen, doppelte und escaped-duplizierte Namen sicher abweisen; Zusatzdaten nicht still strippen |
| `I01-A05` | Null, Zahl, Boolean, Array, geschachtelter Wert, Kommentar, trailing comma, mehrere Roots, fehlerhaftes/abgeschnittenes JSON und leerer Eingang abgewiesen |
| `I01-A06` | unbekannte/falsch typisierte Version, ungeeignete/abweichend formatierte/Nil-UUID oder leere ID abgewiesen; keine Version-/IDmigration oder Neugenerierung |
| `I01-A07` | synthetische Passwort-/Endpoint-/Pfadmarker in falschen Eingaben/Parserfehlern fehlen in Resultat, ErrorRecord einschließlich TargetObject/InnerException, Streams/Verbose/Debug und Transcript |
| `I01-A08` | Parser/Encoder verändern keine Eingangsobjekte; keine Dateien/Records/Keys/Grants oder Provider-/SQL-/Prozessdispatches, auch nicht bei Fehlern; keine automatische UUID-Ausgabe |
| `I01-A09` | neue Datei lässt sich separat laden und im bestehenden Modul importieren; keine Namenskollision/LoadErrors, unveränderte Exportliste und keine Initialisierungswirkung |
| `I01-A10` | beide exakt genannten neuen Pfade jeweils mit `/` und `\` wählen die neue Suite; ähnliche Dateinamen/andere Ordner werden nicht fälschlich als Codec klassifiziert |
| `I01-A11` | reiner Codecscope wählt keine Provider-Runtimes; gemischte Änderung mit unbekannter Produktionsdatei oder Provider-/Lifecyclecode erhält deren vorhandene konservative Runtime-/Suiteauswahl |
| `I01-A12` | Modul-/PowerShell-Mindestversion, Syntax-/Analyzer-/Privacy-/Dokumentationschecks und betroffene bestehende Selektorassertions bestehen; Implementierung bleibt als interner Formbaustein dokumentiert |

Für den späteren stabilen Codecslice zuerst die neue fokussierte Suite, dann
die betroffene Selektorprüfung beziehungsweise den normalen Impactslice
ausführen. Bereits identisch ausgeführte Assertions nicht doppelt starten.
Die endgültige Auswahl umfasst neue Codec-Suite, erforderliche vorhandene
PowerShell-/Pester-/Analyzer-/CI-Strategie-, Dokumentations- und Privacychecks
gemäß aktuellem Selektor und Quellen. Keine Pflichtprüfung wegkonfigurieren.
Provider-/SQL-Smokes sind für einen belegbar reinen Codec nicht erforderlich;
ein breiterer tatsächlicher Diff ändert Auswahl und genehmigten Scope.

Die enge Selektorerweiterung verlangt keinen globalen Ausschluss für
Fixturedateien. Positiv-, Teilnamensnegativ- und gemischte Änderungen sind
Pflicht, damit der Codec nicht den konservativen Fallback anderer Dateien
unterdrückt. Diese Ausnahme folgt nachgewiesener reiner Formverarbeitung,
nicht allein einem Dateinamen oder fehlender aktueller Runtimeverfügbarkeit.

## 6. Abschluss und folgende Voraussetzungen

FSF-I01 ist abgeschlossen, wenn nur die erlaubte Änderungsfläche umgesetzt
ist, A01 bis A12 bestehen, der normale aktuelle Head-Gate grün ist und
Code/Tests/Selektor/Map/Evidence einen kohärenten Stand bilden. Lokal ausgeführte
Checks, CI und nicht ausgeführte native Nachweise getrennt berichten.
Die Freigabe dieses Scopes allein erteilt keine Benutzeranlage-/Runtimeautorität.

Danach bleiben getrennte Folgescopes erforderlich: privater gebundener Plan und
Autorisierung; geschützte Records/Schlüssel/Anker mit Hostnachweisen; native
Ziel-/READY-/Capabilityprüfung und wirksame Lifecycle-Reservierung; schließlich
ein vollständig abgesicherter kleiner nativer OS- oder SQL-Slice mit eigener
Ownership, Quieszenz, Retention und Cleanup. Deren Reihenfolge und Umfang
werden anhand der dann vorhandenen Quellen festgelegt. Dies ist ein
Abhängigkeitsausblick, keine automatische Freigabe dieser Arbeiten.

Zur Abstimmung steht **ein Scopepaket FSF-I01**, einschließlich der engen
Selektorintegration und des Abgleichs mit der parallelen Welle. Eine Zustimmung
gilt ausschließlich für diesen ersten Baustein. Der aktuelle Auftrag bleibt
Planung; begonnen wird erst nach einem konkreten Implementierungsauftrag.

Der Status ist `PENDING`. Noch keine Codecdatei, Testscript, Selektorregel oder
API angelegt; sämtliche Codec-Abnahmen sind `NOT_EXECUTED`. Gekoppelte Quellen
sind die sechs oben verlinkten Modelle, [Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md),
[Repo-Map](../../.ai/repo_map.yaml), [Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Kostenpolitik](../Quality/COST_EFFICIENT_DEVELOPMENT.md),
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md).
