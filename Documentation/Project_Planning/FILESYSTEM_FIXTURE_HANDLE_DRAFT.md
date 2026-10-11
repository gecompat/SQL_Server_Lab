# FSF-03 – Fixture-Handle für getrennte OS-/SQL-Identitäten

| Merkmal | Wert |
|---|---|
| Status | `HANDLE_DECISION_DRAFT` – zur Abstimmung, nicht freigegeben |
| Entwurf | `FSF-03`, Revision `0.1`, Stand 2026-10-11 |
| Grundlage | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md), Revision `0.2`, und [FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md), Revision `0.1`; beide ausdrücklich freigegeben am 2026-10-11 |
| Anforderungsquelle | [Fixture-Verwaltungs-Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md) |
| Repositorybasis der Bestandsanalyse | `a6b5a6b3`; keine neue Fixture-Implementierung oder Runtime-Evidence |
| Gegenstand | stabiler Handle, getrennte Ressourcenreferenzen, private Bindung, Freigabegrenze und sanitisierter Ergebnisumfang |
| Autorität | Dokumentationsentwurf; keine Implementierungs-, Benutzeranlage-, Zugangs- oder Löschfreigabe |

Dieser Entwurf konkretisiert den Handle-Vertrag innerhalb der freigegebenen
Architektur und Fähigkeiten. Alle Entscheidungen C1 bis C9 sind Vorschläge.
FSF-03 bis FSF-06 bleiben einzeln freizugeben; erst danach darf eine
Implementierung beginnen. Die Feldnamen und Beispiele unten beschreiben
einen geplanten Vertrag. Sie führen weder ein JSON-Schema noch öffentliche
Cmdlets, Exporte, Statefelder oder Secretformate ein.

## 1. Drei getrennte Objekte

| Objekt | Zweck | Vertrauensgrenze |
|---|---|---|
| Fixture-Handle | stabile undurchsichtige Referenz auf genau einen eigenen Szenario-Ressourcenscope | keine Credentials, Zielroute oder Operationsfreigabe |
| Inventarprojektion | begrenzter sanitisierter Snapshot der getrennten eigenen Ressourcen und ihrer Beziehungen | historischer Bestand; keine aktuelle Readiness oder Eigentumsbestätigung |
| Private lokale Records | tatsächliche Ziel-/Owner-/Runbindung, Ressourcenidentität, Journal und Credentialreferenzen | ausschließlich der zuständige lokale Lab-Koordinator darf auflösen |

Ein Szenarioscope hat zunächst genau einen Handle; innerhalb dieses Scopes
können mehrere OS- und SQL-Identitäten sowie optionale Dateisystem-Fixtures
liegen. Damit bleiben reine OS-Anlage, reine SQL-Anlage und eine ausdrücklich
gewählte Kombination gleichberechtigt. Die FSF-01-Grenze eines aktiven
Szenarioscopes pro Instanz wird nicht erweitert. Ressourcen können getrennte
Nutzungsenden haben; ein kurzer Dateitest beendet keine aufbewahrte Benutzeranlage.

Der Handle ist kein Bearer-Token: Sein Besitz authentisiert keinen Aufrufer
und genehmigt keine Anlage, Anmeldung oder Entfernung. Auch Kenntnis einer
Ressourcenreferenz ersetzt keine aktuelle Autorisierung.

## 2. Minimaler versionierter Handle

Der serialisierbare Handle enthält ausschließlich zwei Pflichtfelder:

| Feld | Vorgeschlagene Form | Bedeutung |
|---|---|---|
| `ContractVersion` | exakt `1.0` | Version der geschlossenen Handleform, unabhängig von Modul-, SQL-, Inventar- und Journalversion |
| `HandleId` | neu erzeugte undurchsichtige ID im kanonischen UUID-Format | stabile Referenz; kein Name, Pfad, Provider- oder Benutzerbezeichner |

Synthetisches Formatbeispiel, nicht ausführbar:

```json
{
  "ContractVersion": "1.0",
  "HandleId": "a40873d6-5d24-4ad9-972e-8b253b4d19b6"
}
```

Vorgeschlagene Parsergrenzen: höchstens 256 UTF-8-Bytes, ein Objekt, nur diese
beiden Stringfelder, eindeutige exakt geschriebene Propertynamen, keine
Kommentare, zusätzlichen Felder, Arrays oder geschachtelten Werte. Unbekannte
Versionen, Nullwerte und ungeeignete IDs werden vor einer privaten Auflösung
abgewiesen. Es gibt keine automatische Migration oder Versionsvermutung.

Die ID bleibt bei Erweiterung, Profiländerung innerhalb des freigegebenen
Umfangs und eigener Teilentfernung stabil. Sie wird nach Abschluss nie für
einen neuen Scope wiederverwendet. Ein neuer Lab-Run oder Ersatz eines Ziels
erhält keine Fortsetzung des alten Handles. Der Handle enthält absichtlich
keinen veränderlichen Inventarstand; dieser wird gesondert gebunden.

Ein Consumer darf den Handle für manuelle Fortsetzung lokal speichern, ohne
damit Secrets zu speichern. Kein automatischer Export, Upload oder Eintrag in
das Repository. Undurchsichtige IDs können Läufe korrelieren und unterliegen
weiterhin der Privacy-Policy. Import aus fremden Stores oder automatische
Suche nach einer passenden Runtime ist ausgeschlossen.

## 3. Getrennte Ressourcenreferenzen und Beziehungen

Jede eigene logische Ressource erhält eine unabhängige undurchsichtige
`ResourceRef`. Sie bleibt während dieser Ressourcenlebensdauer stabil und
wird nach Entfernung nicht erneut vergeben. Neu angelegte gleichnamige
Benutzer erhalten neue Referenzen und neue Erzeugungsnachweise.

| Geplante Ressourcenart | Eigene Referenz und private Identität | Zulässige Beziehung |
|---|---|---|
| `WINDOWS_LOCAL_ACCOUNT` | eigene ResourceRef; lokale Gast-SID, Name und Konto-Erzeugungsnachweis privat | keine automatische SQL-Zuordnung |
| `LINUX_LOCAL_ACCOUNT` | eigene ResourceRef; Name, UID/GID, Namensauflösung und Konto-Erzeugungsnachweis privat | eigene Dateirechte nur ausdrücklich gewählt |
| `LINUX_NUMERIC_CONTEXT` | eigene ResourceRef; numerische Reservierung und Namespacebindung privat | bezeichnet kein Konto und keinen Passwortzugang |
| `SQL_AUTH_LOGIN` | eigene ResourceRef; Instanzprincipal, SID und Erzeugungsnachweis privat | mehrere ausdrücklich gewählte eigene Datenbankbenutzer möglich |
| `SQL_DB_USER_MAPPED` | eigene ResourceRef je ausgewählter Datenbank; Datenbank-/Principal-/SIDbindung privat | genau ein nachgewiesener eigener SQL-Login desselben Scopes |
| `FILESYSTEM` | eigene ResourceRef für ein gebundenes Dateiressourcenpaket; Root, einzelne Pfade, Rechte und Erzeugungsnachweise privat | ausdrücklich gewählte eigene OS-Referenzen; bestehende SQL-Dienstidentität nur private Bindung |

Gleichlautende Aliase oder native numerische IDs bilden keine Beziehung.
OS- und SQL-Referenzen sind nicht austauschbar. Eine SQL-Loginreferenz darf
nicht als Datenbankbenutzer verwendet werden; ein Datenbankbenutzer in einer
anderen Datenbank ist eine andere Ressource. Windows-Authentisierung,
Contained User und `WITHOUT LOGIN` werden gemäß FSF-02 im ersten Vertrag
nicht ausgegeben oder durch allgemeine Typfelder eingeschleust.

Öffentlich sichtbare `Dependencies` enthalten ausschließlich eigene
ResourceRefs desselben Handles. Bei einem gemappten Datenbankbenutzer ist
die eigene Loginreferenz Pflicht. Ein Dateiressourcenpaket kann ausdrücklich
von eigenen OS-Konten abhängen. Bestehende Dienstkonten, globale Gruppen,
Mounts oder fremde Principals werden weder als eigene Ressourcen ausgegeben
noch aufgrund einer solchen Beziehung zur Entfernung freigegeben.

Die genaue Entfernung und Abhängigkeitsprüfung folgen in FSF-04. Für FSF-03
gilt bereits: Eine Operation darf ihren ausdrücklich gewählten Satz nicht
stillschweigend um abhängige Ressourcen erweitern. Verhindert eine erhaltene
Abhängigkeit das gewünschte Cleanup, wird blockiert und ein neuer konkreter
Plan benötigt. Es gibt keinen impliziten Cascade-Delete.

## 4. Begrenzte Inventar- und Ergebnisprojektion

Der Consumer erhält neben dem Handle einen gesonderten Snapshot mit eigener
Ergebnisversion. Vorgeschlagene Pflichtfelder:

| Feld | Inhalt und Grenze |
|---|---|
| `ResultContractVersion` | exakt `1.0`; getrennt von Handle- und internem Recordformat |
| `Handle` | der minimale Handle; `null` bei Ablehnung ohne dauerhaft registrierten eigenen Scope |
| `Outcome` | feste Kategorie `OBSERVED`, `CREATED`, `BLOCKED`, `PARTIAL`, `RECOVERY_REQUIRED` oder `REMOVED`; kein freier Fehlertext |
| `InventoryRevision` | positive monoton steigende Ganzzahl für einen gebundenen Inventarstand, sonst `null`; kein SQL-/Provider-Versionswert |
| `Resources` | begrenzte Liste eigener ResourceRefs mit Art, geschlossenem FSF-02-Profil, Nutzungsart, Retentionkategorie, Zustand und eigenen Dependencies |
| `ReasonCodes` | begrenzte Liste fester fachlicher Kategorien; keine Runtimeausgaben oder Eingabeechos |

Ein Ressourceneintrag hat ausschließlich die folgenden Pflichtfelder:

| Feld | Vorgeschlagener geschlossener Inhalt |
|---|---|
| `ResourceRef` | eigene kanonische UUID; keine native Principal-ID |
| `Kind` | genau eine der sechs Ressourcenarten aus Abschnitt 3 |
| `Profile` | passend zur Art: `OS_BASE`, `NUMERIC_CONTEXT`, `SQL_CONNECT`, `SQL_OBJECT_READ`, `SQL_OBJECT_DML`, `SQL_OBJECT_DENIED` oder `FILESYSTEM_NATIVE`; konkrete Objekt-/Rechteteilmengen bleiben privat gebunden |
| `UseMode` | `MANUAL` oder `AUTOMATED`, wie ausdrücklich angefordert; Wechsel benötigt einen neuen gebundenen Plan |
| `RetentionMode` | `OPERATION` oder `SCENARIO`; manuelle Aufbewahrung und bewusste automatisierte Retention verwenden `SCENARIO` |
| `State` | `CREATED`, `REMOVED` oder `UNCERTAIN`; keine Behauptung einer aktuellen Nutzbarkeit |
| `Dependencies` | Liste eigener ResourceRefs desselben Handles; bei fehlenden Abhängigkeiten leer |

Diese Profile benennen ausschließlich die in FSF-02 freigegebenen Familien;
sie erweitern keine Rechte. Ein SQL-Login trägt `SQL_CONNECT`, ein gemappter
Benutzer sein ausgewähltes Objektprofil. Die Zulässigkeit von Art, Profil und
Nutzungsart wird gemeinsam geprüft, nicht aus einem beliebigen String abgeleitet.

Vorgeschlagene Grenzen: höchstens 64 Ressourcen, je Ressource höchstens 64
eigene Dependencies, höchstens 16 ReasonCodes und insgesamt 64 KiB UTF-8.
Keine freie Metadatenmap. Profil- und Codevokabular wird vor Implementierung
abschließend mit FSF-05/FSF-06 festgelegt. Überschreitung blockiert vor einer
neuen Mutation; Listen werden nicht still gekürzt. Diese Ausgabeobergrenzen
erhöhen keine Konto-, Datei- oder Laufzeitquota aus FSF-05.

Ressourcenzustände unterscheiden `CREATED`, `REMOVED` und `UNCERTAIN` als
gespeicherte Beobachtung. Sie beweisen weder frische Readiness noch aktuelle
Existenz oder erlaubte Nutzung. Bei `UNCERTAIN` bleibt Mutation blockiert,
bis ein eigener begrenzter Recoverypfad die Lage klärt. Nicht angelegte
Anfrageteile werden durch das Operationsergebnis beschrieben, nicht als
erzeugte Inventarressourcen ausgegeben.

`Outcome` beschreibt nur die angefragte Operation. `REMOVED` bei ausgewählten
Dateien bedeutet nicht, dass sämtliche Benutzer entfernt oder der gesamte
Scope geschlossen wurden. Ein Teilfehler darf keinen Gesamterfolg liefern;
ein unbekannter Antwortstatus bleibt sichtbar. Detailregeln für bestätigte
Absenz und Scopeabschluss folgen in FSF-04.

Die Projektion enthält keine nativen Benutzer-/Login-/Datenbanknamen, SIDs,
UID/GIDs, Principal-IDs, Pfade, Endpoints, Run-State-Rohdaten, Providerbefehle,
Credentialreferenzen oder Secrets. Die für manuelle Anmeldung benötigten
synthetischen Namen und Zielinformationen gehören zum getrennten privaten
Nutzungskanal in Abschnitt 7. Consumer ordnen ResourceRefs über ihre eigene
Anfragekorrelation zu; diese Korrelation wird privat gebunden und ist kein
fremder Alias zur Ressourcenübernahme.

## 5. Private lokale Auflösung und Bindung

Die Auflösung erfolgt ausschließlich innerhalb eines ausdrücklich gewählten,
bereits vertrauenswürdig gebundenen lokalen Lab-Controller-/Storekontexts.
Ein freier Statepfad oder eine andere Storedatei aus dem Consumerobjekt wird
nicht akzeptiert. Keine globale Storesuche, kein Legacyfallback und keine
Adoption anhand eines Benutzer-, VM- oder Containernamens.

| Private Bindungsgruppe | Erforderlicher Inhalt im künftigen Record |
|---|---|
| Herausgeber / Store | Controlleridentität, zulässige Storewurzel und Storegeneration; unveränderliche Bindung des ausgegebenen Handles |
| Owner / Consumer | nachgewiesener lokaler Operator-/Aufruferkontext, ausdrücklich gebundener Consumer und Zweck; ein eingegebener Ownername reicht nicht |
| Run / Ziel | Run-ID, Scope-ID, ausgewählte Instanz, Provider, OS-Klasse, Generation und gepinnte Route; für Container vollständige Containeridentität, für Hyper-V VM-ID |
| SQL / Datenbank | tatsächlich geprüfte Instanz-/Dienstgeneration; je SQL-Benutzer die explizite Datenbankgeneration und eigene Loginzuordnung |
| Ressourcen | ResourceRef, native Identität, Erzeugungsreceipt, Profil, effektive Rechtebindung, eigene Abhängigkeiten und Lebensdauer |
| Operation / Evidence | Inventarrevision, eigener Journalbezug, reservierter Mutationsscope und jüngste gebundene Beobachtung; historische Evidence bleibt als solche markiert |
| Secrets | getrennte private Referenzen für Betreiber- und Szenariocredentials; keine Secretwerte im Inventar oder Journal |

Port, SQL-Major-Version, Datenbankname, Principal-ID oder UID allein reichen
nicht als dauerhafte Identität; Wiederanlage kann solche Werte wiederverwenden.
FSF-04/FSF-05 müssen die native Generation-/Erzeugungsbindung nachweisen.
Ein erfolgreicher Metadatenlookup beweist keine aktuelle Runtimeidentität.
OS-only behält den SQL-Ziel-/READY-Bezug, verlangt aber keine neuen SQL-
Principals; SQL-only verlangt keinen OS-Adminpfad und keine OS-Kontoanlage.

Handleidentität und Zielbindung ändern sich nicht bei einem Neustart des
Koordinatorprozesses. Fortsetzung ist nur bei demselben überprüften Store,
derselben Generation und frischem Aufrufernachweis möglich. Kopierter,
zurückgesetzter, beschädigter oder nicht vertrauenswürdig gebundener Store
erlaubt keine automatische Fortsetzung. Wiederherstellung, Ownershiptransfer,
Hostwechsel und Storemigration benötigen spätere eigene Verträge.

## 6. Freigabe, Revision und Manipulationsschutz

Vor jeder Nutzung gilt die Prüfsequenz: Handleform → privater Kontext und
Recordintegrität → Owner-/Run-/Zielbindung → konkret ausgewählter Ressourcensatz
und Profil → aktuelle Autorisierung → erforderliche Reservierung, Capability,
frisches READY und Driftprüfung. Reines lokales Inspect darf historische
Metadaten lesen, ohne einen Runtimeaufruf zu starten; es verspricht keine
Verfügbarkeit. Alle Zielmutationen einschließlich Cleanup bleiben an READY
gebunden, wie in FSF-01 freigegeben.

Jede Mutation verwendet außerhalb des stabilen Handles eine explizite
`ExpectedInventoryRevision` und einen konkreten Plan mit ausgewählten
ResourceRefs. Die Freigabe bindet Operation, Handle, Inventarrevision,
Ressourcensatz, Rechte-/Nutzungsprofil, Zielgeneration und begrenzte Gültigkeit.
Sie wird nicht als übertragbarer Teil des Handles ausgegeben. Änderungen am
Inventar, an Retention, Profilen, Abhängigkeiten oder einer unklaren Operation
invalidieren alte Mutationspläne. Ein stale Plan wird nicht auf den aktuellen
Stand umgebogen. Ein neues Inspect und eine neue konkrete Freigabe sind nötig.

Revisionstest und Journalregistrierung müssen unter derselben wirksamen
Reservierung erfolgen; ein vorab gelesener Versionswert allein verhindert
kein Rennen. Einzelheiten zu Einmalverbrauch, Retry, Commitgrenzen und verlorenen
Antworten bleiben FSF-04/FSF-05 vorbehalten. Ein Grant oder Handle kann weder
die externe Runtime gegen Adminaktionen sperren noch einen Teilfehler atomar
rückgängig machen.

Manipulierte Handlefelder liefern keine alternativen Bindungen: Die native
Identität wird nur aus dem geprüften privaten Record ermittelt. Unbekannte
oder fremde IDs, Typverwechslung, fremde Dependencies, Recorddrift und ungültige
Revisionen blockieren ohne Eingabeecho oder Geheimnisoffenlegung. Die externe
Antwort darf nicht verraten, ob ein nicht autorisierter fremder Handle existiert.

Der private Store benötigt restriktive Rechte, begrenzte sichere Reads und
authentisierte Integrität für Handle-, Ressourcen- und Journalbindungen.
Dateirechte oder ein ungekeyter Hash allein sind kein Manipulationsnachweis.
FSF-05 entscheidet das konkrete plattformübergreifende Schlüssel-/Storemodell
und den Schutz vor Rollback beziehungsweise kopierten Records. Fehlt dieser
Nachweis, bleibt Ausführung blockiert. Es wird kein eigener Kryptografie-
Algorithmus entworfen und keine Sicherheit gegen einen kompromittierten
Koordinator, denselben privilegierten Operator oder dessen Schlüssel behauptet.

## 7. Manueller und automatisierter Nutzungskanal

Der gleiche Handle kann für automatisierte Operationen und bewusst
aufbewahrte manuelle Szenarien verwendet werden. Nutzungsart und Lebensdauer
werden je Ressource privat festgehalten und im begrenzten Inventar klassifiziert.
Ein Testconsumer erhält damit keine Rechte an einer daneben aufbewahrten
Identität; Cleanup bleibt an den konkret freigegebenen Satz gebunden.

Für eine manuelle Anmeldung wählt der Operator eine konkrete ResourceRef und
erneuert seinen privaten Aufrufernachweis. Erst nach Ziel-/Rechte-/Nutzungsprüfung
stellt das Lab einen getrennten begrenzten lokalen Zugang bereit: synthetischer
Benutzername, notwendige Ziel-/Datenbankinformationen und, falls benötigt,
sichere Credentialübergabe. Für automatisierte Nutzung gilt die gleiche
Trennung; kein allgemeiner Betreiberzugang für Consumer. Numerische Linuxfälle
werden als solche präsentiert und erhalten keinen behaupteten Kontologin.

Der Nutzungskanal ist kein serialisierbarer Credentialblock im Handle oder
Inventar. Kein Secret in Kommandozeilen, normalen Ergebnissen, Logs oder
Dateiexporten; keine Passwortkopplung zwischen OS und SQL. FSF-05 legt lokale
Übergabe, Fristen, Speicherfreigabe und Grenzen bestehender Clients fest.
Das Lab startet damit keinen allgemeinen Workloadexecutor und verspricht
keine Abschaltung bereits externer SQL-/OS-Sitzungen durch Handleinvalidierung.

Die vorhandene [SA-Secretverwaltung](../../Private/SecretProvider.ps1) ist
kein fertiger Szenariocredentialvertrag. Ihre Plattformpfade werden nicht
ungeprüft für neue Benutzer übernommen. Insbesondere ist eine dort vorhandene
Base64-Repräsentation kein Verschlüsselungsnachweis. Ein sicherer Umgang mit
neuen Szenariocredentials bleibt Voraussetzung in FSF-05.

## 8. Teilfehler, Fortsetzung und spätere Abnahme

Eine Creation erhält einen eigenen privaten Operationbezug vor Zielmutation.
Ein vom Aufrufer vorab vergebener undurchsichtiger `RequestRef` wird dafür
privat an denselben autorisierten Store-/Owner-/Consumerkontext und den exakten
Anfrageplan gebunden. Er ist eine Korrelation, kein Grant und kein weiterer
Handle. Wiederverwendung für eine andere Anfrage blockiert; eine passende
Wiederholung darf nur den gebundenen Status abfragen, bis FSF-04 einen sicheren
Retry ausdrücklich bestimmt. Das Ergebnis eines fremden RequestRefs wird
nicht offengelegt.
Sobald eigene Ressourcen entstanden sein können, müssen Handle/Inventar und
Journal deren Zustand dauerhaft nachvollziehbar halten. Bei Teilfehlern wird
ein vorhandener gebundener Handle zurückgegeben, ohne unklare Ressourcen als
erfolgreich angelegt zu behaupten. Bei verlorener Antwort darf anhand eines
eigenen Operationbezugs im selben autorisierten Scope nachgesehen werden;
blindes erneutes Create und automatische Übernahme gefundener Konten sind
verboten. FSF-04 konkretisiert Idempotenz und unbekannte Mutationsantworten.

Nach bestätigter vollständiger Entfernung bleibt mindestens ein gebundener
Abschlussrecord zur Verhinderung von Wiederverwendung und zur Idempotenz.
Tombstoneumfang und Aufbewahrungsdauer sind FSF-04/FSF-05-Entscheidungen,
keine unbegrenzte State-Retention. Ein gelöschter oder verlorener Record erlaubt
keine neue Adoption alter Runtime-Ressourcen. Recovery benötigt einen eigenen
nachgewiesenen Pfad und erweitert den Handle nicht um fremde Ziele.

FSF-06 muss später insbesondere prüfen: geschlossene Parsergrenzen;
OS-only/SQL-only und mehrere SQL-Datenbankbenutzer; Referenz-/Typverwechslung;
fremder Owner/Consumer/Store; kopierter oder zurückgesetzter Record; stale
Revision und Rennen; Login-/UID-/Zielwiederanlage; Manipulation von Beziehungen;
keine implizite Cascade; wiederholter Cleanup; Teilfehler und Antwortverlust;
Fortsetzung manueller Nutzer nach Dateientfernung; fehlender Secretzugang und
Privacy sämtlicher Erfolgs-/Fehlerprojektionen. Docker, Podman und Hyper-V
bleiben getrennte Nachweise.

## 9. Entscheidungen zur Abstimmung

| ID | Vorschlag für FSF-03 | Konsequenz |
|---|---|---|
| `C1` | Ein stabiler minimaler Handle pro Szenarioscope, nur ContractVersion und HandleId | Kein Credential, Pfad, Runtimeziel oder Grant im Handle. |
| `C2` | Unabhängige ResourceRefs je OS-Konto, numerischem Kontext, SQL-Login, Datenbankbenutzer und Dateiressourcenpaket | Mehrere Benutzer und Datenbanken bleiben getrennt; keine automatische OS-/SQL-Kopplung. |
| `C3` | Eigene explizite Abhängigkeiten; kein implizites Cascade-Cleanup | Aufbewahrte Benutzer und fremde Dienstidentitäten werden nicht mit entfernt. |
| `C4` | Begrenzte versionierte Inventarprojektion neben dem Handle; keine nativen Identitäten oder Secrets | Bestand/Outcome bleiben von Readiness, Eigentumsnachweis und manuellen Zugangsdetails getrennt. |
| `C5` | Auflösung nur im ausdrücklich gebundenen privaten lokalen Store mit Owner-/Consumer-/Run-/Zielgeneration | Keine freie Statewurzel, Storesuche, Adoption oder automatische Migration. |
| `C6` | Explizite ExpectedInventoryRevision und konkrete ressourcen-/operationsgebundene Freigabe außerhalb des Handles | Alte Kopien autorisieren keine geänderten Pläne; Reservierung und frische Prüfungen bleiben Pflicht. |
| `C7` | Private Recordintegrität und getrennte lokale Nutzungskanäle, Sicherheitsdetails in FSF-05 | Kein Sicherheitsversprechen durch opaque IDs, Dateirechte oder vorhandene SA-Secretpfade. |
| `C8` | Dauerhafte Teilfehler-/Abschlusszuordnung ohne Wiederverwendung; Recovery/Idempotenzdetails in FSF-04 | Antwortverlust erzeugt keine blinde zweite Anlage und keinen Zielwechsel. |
| `C9` | FSF-03-Freigabe genehmigt nur diesen Handle-Vertrag | FSF-04 bis FSF-06 und jede Implementierungs-/Runtimefreigabe bleiben offen. |

Der Abstimmungsstatus ist `PENDING`. Gekoppelte Quellen sind
[FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md),
[FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md),
[Repo-Map](../../.ai/repo_map.yaml),
[Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Projektintegrationsvertrag](../Architecture/PROJECT_INTEGRATION_CONTRACT.md),
[Diagnosebundlegrenze](../Architecture/DIAGNOSTIC_BUNDLE.md) und
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
Die bestehenden Diagnose- und Workflow-UI-Verträge werden nicht um Fixture-
Autorität erweitert. Dieser Slice prüft ausschließlich Dokumentation und
Privacy; sämtliche Handle-/Provider-/SQL-Laufzeitnachweise sind nicht ausgeführt.
