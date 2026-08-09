# Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung

| Merkmal | Wert |
|---|---|
| Status | `BINDING_IMPLEMENTATION_TARGET` |
| Runtime-Status | `PARTIALLY_IMPLEMENTED` |
| Stand | 2026-08-01 |
| Geltungsbereich | Docker, Podman und Hyper-V |
| Aktueller Ist-Nachweis | [`KNOWN_LIMITATIONS.md`](../Quality/KNOWN_LIMITATIONS.md) |

## 1. Zweck und Statusabgrenzung

Dieses Dokument definiert den verbindlichen Zielvertrag für:

- die Auswahl einer oder mehrerer öffentlicher Testdatenbanken bei der Ad-hoc- und Manifest-Erstellung;
- die automatische Bereitstellung aus Backup-, BACPAC-, Attach-, SQL-Skript- und Script-Bundle-Artefakten;
- die einmalige Vertrauensentscheidung bei fehlender SHA-256-Prüfsumme;
- einen lokalen, inhaltsadressierten Artifact Cache;
- wiederverwendbare `LAB_GENERATED`-Baselines;
- eine verständliche, kontextreiche Menüführung für Manifeste und Pfade.

Der Vertrag gilt providerübergreifend. Provider dürfen eigene Acquisition- oder
Execution Handler verwenden, müssen aber dieselben Sicherheits-, Integritäts-,
State-, Verification- und Cleanup-Regeln erfüllen.

Dieses Dokument ist **kein vollständiger Runtime-Nachweis**. Implementiert sind
der Backup-Handler für executable `.bak`-Varianten einschließlich Trust-Pfad,
Sample-Identität in Trust Store und Run Lock, Idempotenz- und
Output-Verification, die Mehrfachauswahl im Ad-hoc-Menü und per
`New-SqlServerLab -Sample` sowie eine Katalogauswahl im Manifest-Wizard.
Einzelne gepinnte SQL-Skript-Samples und sichere ZIP-Script-Bundles mit mehreren
fest katalogisierten Datenbankoutputs sind implementiert; Baseline-Erzeugung
bleibt offen.

Der gemeinsame Katalogvertrag für Artifact Type, Installation, erwartete
Outputs, Trust Policy und Größenmetadaten ist implementiert. Für die
festgelegten Manifestpfade sind `x-ui`-Semantik und kontextreiche
Wizard-Anzeigen einschließlich einer lokalen Vorschau relativer Hostpfade
implementiert. Diese Grundlagen führen weder eine Acquisition noch einen neuen
Installation Handler aus.

## 2. Verbindliche Entscheidungen

1. Eine Instanz kann keine, eine oder mehrere Testdatenbanken erhalten.
2. Ad-hoc-Menü und Manifest-Wizard verwenden denselben aufgelösten
   Sample-/Artifact-Vertrag.
3. Eine Katalogauswahl darf mehrere Datenbanken erzeugen, wenn das Artefakt dies
   ausdrücklich deklariert.
4. Jeder Artifact Type besitzt einen eigenen Handler hinter einem gemeinsamen
   Lifecycle.
5. Fehlt eine erwartete SHA-256-Prüfsumme, darf ein interaktiver Lauf einmalig
   nach Vertrauen fragen.
6. Nach Zustimmung wird das Artefakt zunächst temporär geladen, SHA-256
   berechnet und dauerhaft als erwartete Prüfsumme registriert. Spätere
   Verwendungen fragen für exakt dieselben Bytes nicht erneut.
7. Dieselbe URL mit anderen Bytes gilt als neues Artefakt. Ein Hash-Mismatch
   führt zum harten Abbruch und niemals zu einer stillen Aktualisierung.
8. Das ursprüngliche Manifest wird während Provisionierung oder Trust-Auflösung
   nicht still verändert.
9. Erfolgreich installierte Samples können nach Verification als
   `LAB_GENERATED`-Backup gesichert werden. Ein späterer Lauf verwendet die
   beste kompatible, verifizierte Baseline.
10. Runtime-Artefakte, Cache, Trust Store, konkrete Hostpfade und nicht
    sanitisierte Locks bleiben außerhalb des Repository.
11. Produktionsdaten und unklassifizierte Datenbankartefakte bleiben blockiert.

## 3. Aktueller Ausgangspunkt

| Fähigkeit | Ist-Stand |
|---|---|
| mehrere `instances[].databases[]` | strukturell und im Manifestpfad vorhanden |
| Restore lokaler oder entfernter `.bak`-Dateien | implementiert |
| SHA-256-Prüfung gegen eine bekannte Prüfsumme | implementiert |
| Sample-Katalog | vorhanden; direkte `.bak`-Backup-Varianten sind `executable` |
| Sample-Backup-Handler mit Trust-Pfad und Verification | implementiert (`Private/SampleArtifactHandlers.ps1`) |
| SQL-Skriptausführung | für einzelne T-SQL-Dateien vorhanden |
| SQL-Skript-Sample als Artifact Handler | implementiert für einzelne, gepinnte Skripte ohne Includes/Variablen (`Northwind`, `Chinook`) |
| ZIP-Backup als Artifact Handler | implementiert für exakt katalogisierte `.bak`-Payloads; Entpacken erfolgt nur temporär |
| mehrere Samples im Ad-hoc-Menü auswählen | implementiert (`Invoke-SqlServerLab`, `New-SqlServerLab -Sample`) |
| persistenter Trust Store und Manifest Lock | implementiert; Sample-Identität wird mitgeführt |
| inhaltsadressierter Artifact Cache und Quarantäne | implementiert |
| `LAB_GENERATED`-Baseline-Auswahl | Registry, deterministischer Key, exakte/kompatible Auswahl und Quarantäne implementiert; Backup-Erzeugung und Runtime-Präferenz offen |
| kontextbezogene Manifest-Menüführung | Pfadsemantik und Sample-Katalogauswahl vorhanden; Navigation/Planvorschau offen |

## 4. Gemeinsamer Artifact-Vertrag

### 4.1 Artifact Types

Die Zielarchitektur unterscheidet mindestens:

| `artifactType` | Zweck | Erste Zielpriorität |
|---|---|---|
| `backup` | direkter SQL-Server-Backup-Restore | hoch; bestehender Pfad |
| `sql-script` | einzelnes T-SQL-/sqlcmd-Installationsskript | hoch |
| `script-bundle` | Paket aus mehreren Skripten mit definiertem Entrypoint | hoch |
| `bacpac` | Import über ein nachgewiesenes `SqlPackage` | mittel |
| `archive-backup` | verifiziertes Archiv mit Backup als Payload | mittel |
| `attach` | kontrolliertes Attach katalogisierter MDF/LDF-Dateien | niedrig |

Neue Typen werden über registrierte Handler ergänzt. Ein unbekannter Typ wird
nicht anhand der Dateiendung geraten oder als anderer Typ ausgeführt.

### 4.2 Gemeinsamer Lifecycle

Jeder Handler implementiert logisch dieselben Phasen:

```text
Resolve
  -> Plan
  -> Acquire
  -> VerifyIntegrity
  -> Prepare
  -> Apply
  -> VerifyOutputs
  -> CreateBaseline (optional)
  -> RegisterCleanup
```

Vor `Acquire` müssen Datenklassifikation, Quelle, Lizenz, Ressourcenbedarf,
Egress und erwartete Seiteneffekte bekannt sein. Vor `Apply` müssen State und
Cleanup Plan existieren.

### 4.3 Erforderliche Katalogmetadaten

Eine ausführbare Variante benötigt mindestens:

- stabile Sample-ID und Variant-ID;
- Anzeigename, Beschreibung, Kategorie und Tags;
- `artifactType`;
- Quellseite und konkrete Artifact-URL beziehungsweise lokale
  Source-Referenz;
- Lizenz und Data Classification;
- erwartete Download- und Installationsgröße;
- minimale und maximale SQL-Server-Kompatibilität, soweit begrenzbar;
- `runtimeStatus`;
- erwartete SHA-256-Prüfsumme oder einen definierten Trust-Pfad;
- Handler-Version beziehungsweise Contract-Version;
- erwartete Datenbankausgaben;
- Preconditions und Required Capabilities;
- Timeout-, Verification-, Idempotency- und Cleanup-Policy;
- Baseline-Policy.

Typspezifische Metadaten bleiben in einem typisierten `installation`-Block.
Nicht anwendbare Felder werden nicht mit `null` simuliert.

## 5. Integrität, Vertrauen und Cache

### 5.1 Integrity Origins

Eine bekannte Prüfsumme trägt eine nachvollziehbare Herkunft:

| `integrityOrigin` | Bedeutung |
|---|---|
| `publisher-verified` | vom Herausgeber veröffentlichte und geprüfte Prüfsumme |
| `catalog-verified` | kontrolliert durch die Repository-Pflege übernommen |
| `user-trusted-generated` | nach expliziter Vertrauensfreigabe lokal berechnet |

Die Vertrauensfreigabe bestätigt konkrete heruntergeladene Bytes. Sie ist keine
dauerhafte pauschale Freigabe dafür, dass eine URL künftig beliebige andere
Inhalte liefern darf.

### 5.2 Interaktiver Ablauf ohne bekannte Prüfsumme

1. Menü zeigt Sample, Variante, Quellseite, konkrete URL, Herausgeber, Lizenz,
   Artifact Type, Größe und die fehlende Prüfsumme.
2. Benutzer kann abbrechen, Details anzeigen oder der Quelle für diesen
   einmaligen Acquisition-Vorgang vertrauen.
3. Bei Zustimmung wird in eine temporäre Datei unter dem lokalen State
   heruntergeladen.
4. SHA-256 wird über die vollständig geladene Datei berechnet.
5. Die berechnete Prüfsumme wird vor jeder Ausführung dauerhaft registriert.
6. Das Artefakt wird unter seinem Digest in den inhaltsadressierten Cache
   übernommen.
7. Der Handler prüft den Cache nochmals gegen die erwartete Prüfsumme.
8. Erst danach darf `Prepare` oder `Apply` beginnen.

Ein nicht interaktiver Lauf darf keine Zustimmung erfinden. Ohne bekannte
Prüfsumme aus Katalog, Trust Store oder passendem Manifest Lock endet der Plan
mit dem strukturierten Status `TRUST_REQUIRED`.

### 5.3 Persistenz

Vorgesehene lokale Ablage:

```text
<StateRoot>/trust/sample-artifacts.json
<StateRoot>/cache/artifacts/sha256/<sha256>/
<StateRoot>/runs/<RunId>/manifest.lock.json
```

Der Trust Store bleibt erhalten, wenn nur der Cache gelöscht wird. Ein späterer
Download derselben Quelle wird gegen die registrierte Prüfsumme geprüft.

Ein Run-spezifisches Manifest Lock enthält den vollständig aufgelösten
Artifact-Vertrag, aber keine Secrets. Für andere Hosts oder frische Runner kann
ein **sanitisiertes, portables Lock** ausdrücklich exportiert werden. Es darf
nur öffentliche Artifact-Identität, Source, SHA-256, Integrity Origin,
Handler-/Contract-Version und Kompatibilitätsmetadaten enthalten. Konkrete
Hostpfade, Benutzerinformationen, Secrets und Runtime-Endpunkte sind verboten.

Beispiel:

```json
{
  "sampleId": "wideworldimporters",
  "variant": "standard",
  "artifactType": "backup",
  "source": "https://example.invalid/sample.bak",
  "sha256": "<64 hex characters>",
  "integrityOrigin": "user-trusted-generated",
  "handlerContractVersion": "1"
}
```

### 5.4 Hash-Mismatch

Liefert eine bekannte Quelle andere Bytes:

- Status `ARTIFACT_INTEGRITY_MISMATCH`;
- kein Prepare, Apply oder Baseline-Fallback mit dem neuen Inhalt;
- alte Trust-Information bleibt nachvollziehbar erhalten;
- Anzeige von erwarteter und beobachteter SHA-256;
- erneute ausdrückliche Entscheidung erforderlich;
- Zustimmung erzeugt einen neuen versionierten Trust Record, keine stille
  Überschreibung.

Defekte oder widersprüchliche Cache-Einträge werden quarantänisiert und nicht
ausgeführt.

## 6. SQL-Skript- und Script-Bundle-Handler

### 6.1 Unterstützbare Installationsformen

Ein SQL-Skript-Sample ist automatisierbar, wenn der Katalog den Ablauf
vollständig beschreibt. Der aktuelle Handler unterstützt:

- ein einzelnes Skript;
- einen definierten Entrypoint;
- `GO` und `GO <count>`;
- Ausführung gegen `master`, eine vorhandene Zieldatenbank oder einen
  Self-Creating-Modus;
- genau eine erwartete erzeugte Datenbank.

`:r`, `:setvar`, `:connect` und Shell-Escapes sind für katalogisierte Samples
absichtlich nicht freigegeben. Script-Bundles benötigen weiterhin einen eigenen
Handler und bleiben `descriptive`.

### 6.2 Typspezifische Metadaten

Ein Script Handler benötigt mindestens:

- `entrypoint`;
- `workingDirectory`, relativ zur verifizierten Artifact Root;
- `executionMode`: `master`, `existing-database` oder
  `self-creates-databases`;
- optionales `targetDatabase`;
- genau einen erwarteten Datenbankoutput;
- erwartete Marker, Tabellen oder andere Verification Actions;
- `timeoutSeconds`;
- `idempotencyMode`;
- `partialFailurePolicy`;
- `baselinePolicy`.

Ein künftiges Bundle darf mehrere Datenbanken erzeugen. Die gesamte Liste muss
vor Ausführung im Plan sichtbar sein.

### 6.3 Sicherheitsgrenzen

- `!!` und andere Shell-Escapes werden für Sample-Skripte abgelehnt.
- `:connect` wird zunächst abgelehnt, bis ein eigener Multi-Instance-Vertrag
  existiert.
- Archive werden gegen Path Traversal und Überschreiben fremder Dateien
  geschützt entpackt.
- Script Bundles führen standardmäßig ausschließlich katalogisierte
  T-SQL-/sqlcmd-Inhalte aus. PowerShell, native Binaries oder beliebige
  Setup-Programme benötigen einen getrennten Deployment-Unit-Vertrag.
- Secretwerte werden nur zur Laufzeit gebunden und weder im Katalog noch im
  Lock gespeichert.

### 6.4 Idempotency und Teilfehler

Unterstützte Zielmodi:

| Modus | Verhalten |
|---|---|
| `fail-if-exists` | vorhandene erwartete Datenbank blockiert die Ausführung |
| `reuse-if-verified` | vorhandene Datenbank wird nur nach erfolgreicher Verification wiederverwendet |
| `recreate-owned` | nur eine nachweislich vom aktuellen Lab-Scope erzeugte Datenbank darf neu erstellt werden |

Vor Apply werden vorhandene Datenbanken und relevante Ownership-Marker
protokolliert. Cleanup entfernt nur Ressourcen, die nachweislich durch den
aktuellen Run erzeugt wurden. Kann ein Teilzustand nicht sicher kompensiert
werden, endet der Run mit `RECOVERY_REQUIRED`; fremde oder vorbestehende
Datenbanken werden nicht gelöscht.

Ein komplettes Script Bundle wird nicht pauschal in eine einzelne Transaktion
gezwungen. Datenbankerstellung, `GO`, Wiederanmeldung und scriptspezifische
Transaktionsgrenzen müssen erhalten bleiben.

## 7. Weitere Handler

### 7.1 Backup

Der bestehende `.bak`-Pfad wird in den gemeinsamen Handlervertrag überführt.
`FILELISTONLY`, File Mapping, Restore, Datenbankoptionen, Verification und
Cleanup bleiben getrennte Phasen. Backup-Ketten erfordern später einen eigenen
typisierten Plan.

### 7.2 BACPAC

Ein BACPAC darf nur angeboten werden, wenn ein kompatibles `SqlPackage`
read-only nachgewiesen wurde. Importziel, Editionseinschränkungen,
Ressourcenschätzung und Verification müssen vor Mutation sichtbar sein.

### 7.3 Archive und Attach

Archive werden zuerst als Artifact verifiziert und erst danach in einen
isolierten lokalen Scope entpackt. Attach ist nur für katalogisierte,
konsistente und exklusiv vom Lab verwaltete MDF/LDF-Sets zulässig. Fremde
Dateien oder bereits eingebundene Datenbanken werden nicht übernommen.

## 8. Mehrfachauswahl von Testdatenbanken

### 8.1 Ad-hoc-Menü

Die Aktion `Neue Umgebung erstellen` erhält nach SQL-Version, Provider und
Ressourcenprofil einen optionalen Schritt `Testdatenbanken`.

Das Menü:

- filtert Varianten nach SQL-Version, Provider Capabilities und lokal
  verfügbaren Tools;
- zeigt Name, Kurzbeschreibung, Artifact Type, erwartete Datenbanken,
  Download-/Installationsgröße, Lizenz, Quelle, Trust-Status und Cache-Status;
- erlaubt `Hinzufügen`, `Entfernen`, `Reihenfolge ändern`, `Details` und
  `Keine Testdatenbank`;
- erlaubt mehrere unabhängige Samples;
- zeigt Namens- und Output-Kollisionen vor dem Speichern oder Provisionieren;
- berechnet Storage- und Downloadbedarf in das Resource Assessment ein.

Die Auswahl wird intern als normales Manifest beziehungsweise als Bound Plan
repräsentiert. Es entsteht kein zweiter Ad-hoc-Sonderpfad.

### 8.2 Manifest-Wizard

Der Wizard bietet pro Instanz:

1. leere Datenbank anlegen;
2. lokale oder entfernte Restorequelle verwenden;
3. eine oder mehrere katalogisierte Testdatenbanken auswählen;
4. Auswahl bearbeiten oder entfernen.

Bei einer Sample-Auswahl werden ID und Variante gespeichert, nicht die jeweils
aktuelle URL kopiert. Der Bound Plan und das Lock halten die tatsächlich
aufgelöste Source und SHA-256 fest.

Ein Sample, das mehrere Datenbanken erzeugt, wird als eine Installation mit
mehreren erwarteten Outputs dargestellt. Explizite Datenbanknamen dürfen nur
überschrieben werden, wenn der Handler dies unterstützt und die Verification
darauf angepasst ist.

## 9. Verbesserte Manifest-Menüführung

### 9.1 Grundsatz

Der Wizard darf nicht nur einen Feldnamen oder `Pfad` anzeigen. Jede Eingabe
erklärt mindestens:

- fachliche Bedeutung;
- Zielscope: Host, Container, VM-Gast, SQL Server oder Artifact;
- ob die Angabe optional oder erforderlich ist;
- Defaultwert und warum er gilt;
- Bezugsbasis für relative Werte;
- aufgelösten Vorschauwert;
- ob das Ziel vorhanden sein muss oder erzeugt wird;
- relevante Seiteneffekte und Einschränkungen;
- mindestens ein passendes Beispiel.

Die Struktur bleibt aus dem JSON-Schema abgeleitet. Zusätzliche
Darstellungsmetadaten werden als `x-ui`-Annotationen direkt am Schemafeld
geführt, damit Struktur und Menübeschreibung nicht in getrennten Dateien
auseinanderlaufen. `description`, `default` und `examples` bleiben Fallbacks.

Pfadfelder benötigen in `x-ui` mindestens:

```text
pathKind
pathBase
pathScope
mustExistAtPlan
createdByRuntime
```

Eine statische Prüfung muss sicherstellen, dass jedes Pfadfeld diese Semantik
vollständig deklariert.

### 9.2 Verbindliche Pfadsemantik

| Feld | Scope | Basis relativer Angaben | Verhalten |
|---|---|---|---|
| Manifest-Zielpfad | Host | aktuelles Arbeitsverzeichnis des Aufrufs | Default `./lab-manifest.json`; Wizard erzeugt Datei |
| `restore.source` als Datei | Host | Verzeichnis des Manifests | muss beim Plan vorhanden sein |
| `drives[].hostPath` | Host | Verzeichnis des Manifests | Mount-/Ablageziel; Erzeugung nur nach expliziter Policy |
| `drives[].containerPath` | Container oder VM-Gast | keine; absolut im Zielsystem | kein Hostpfad |
| Datenbank-`files.*.path` | SQL-Server-Dateisystem | keine; absolut im Zielsystem | muss zu bereitgestelltem Storage passen |
| `postProvision[]` | Host | Verzeichnis des Manifests | Skript muss beim Plan vorhanden sein |
| Script-Bundle-`entrypoint` | Artifact | Root des verifizierten, vorbereiteten Artifacts | darf Artifact Root nicht verlassen |
| State-, Cache- und Trust-Pfade | Host Runtime State | `StateRoot` | werden berechnet und nicht als portable Manifestwerte behandelt |
| Hyper-V-Medien und Parent-VHDX | Host | Manifestverzeichnis oder expliziter lokaler Binding Root | bleiben lokal; keine Versionierung |

Vor dem Speichern zeigt der Wizard die aufgelöste Bedeutung, beispielsweise:

```text
Hostpfad:        .\storage\data
Relativ zu:      D:\LabDefinitions\Performance\
Aufgelöst:       D:\LabDefinitions\Performance\storage\data
Ziel im Gast:    /sqldata
Erzeugung:       bei Provisionierung, falls zulässig
```

Konkrete lokale Werte werden nur in der laufenden Konsole und im lokalen State
angezeigt, nicht in versionierte Diagnose- oder Dokumentationsartefakte
übernommen.

### 9.3 Navigation und Planvorschau

Jeder Wizard-Schritt unterstützt mindestens:

- Default mit `Enter`;
- kontextbezogene Hilfe mit `?`;
- zurück zum vorherigen Schritt;
- aktuelle Instanz- oder Gesamtzusammenfassung;
- Abbruch ohne partielle Manifestdatei.

Vor dem Speichern wird eine strukturierte Summary gezeigt:

- Instanzen, Versionen und Provider;
- Ressourcen und Storage-Rollen;
- Datenbanken und Sample-Ausgaben;
- Downloads, Quellen, Lizenzen und Trust-Anforderungen;
- lokale und Gastpfade mit ihrer jeweiligen Bedeutung;
- vorbereitete, aber nicht ausführbare Felder;
- erwartete Mutationen und Cleanup;
- Fehler und Warnungen.

Das Manifest wird erst nach erfolgreicher Schema- und Fachvalidierung atomar
geschrieben.

## 10. `LAB_GENERATED`-Baselines

### 10.1 Zweck

Nach einer erfolgreichen und verifizierten Erstinstallation darf der Runtimepfad
ein Lab-eigenes Backup erzeugen. Dadurch müssen umfangreiche Skriptinstallationen
oder wiederholte Imports nicht bei jedem Run erneut ausgeführt werden.

Eine Baseline ist nur gültig, wenn sie selbst SHA-256-verifiziert und vollständig
auf ihren Ursprung zurückführbar ist.

### 10.2 Baseline-Key

Mindestens folgende Werte bestimmen die Identität:

- Sample-ID und Variante;
- SHA-256 des ursprünglichen Artifacts;
- Artifact Type und Handler Contract Version;
- erwartete Datenbankausgaben;
- SQL-Server-Quellversion und relevante Edition-/Featureanforderungen;
- gewünschter Compatibility Level;
- installationsrelevante Variablen;
- Verification Contract Version;
- Baseline Format Version.

Ein anderer Quellhash invalidiert die Baseline. Nicht installationsrelevante
Runtimewerte wie Hostport oder RunId gehören nicht in den Key.

### 10.3 Auswahl der besten Ausgangsbasis

Die Auflösung erfolgt deterministisch:

1. exakte, verifizierte `LAB_GENERATED`-Baseline mit identischem Key;
2. ausdrücklich kompatible, verifizierte Baseline nach SQL-Server-Restore- und
   Feature-Regeln;
3. verifiziertes Originalartifact aus dem Cache;
4. erneuter Acquisition-Vorgang mit Integritätsprüfung.

Eine Baseline wird nie allein deshalb gewählt, weil sie neuer ist. Kompatibilität
und Verification haben Vorrang. Schlägt die Verification nach Restore fehl,
wird die Baseline quarantänisiert und kontrolliert auf das Originalartifact
zurückgefallen.

### 10.4 Plattformbezogene Zustände

Der detaillierte Hyper-V-, OS-/SQL-Image-, Drive-, Netzwerk-, Software-,
Reconcile- und Refresh-Vertrag steht in
[Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).

Providerübergreifend werden Datenbankartefakte bevorzugt von
Infrastrukturzuständen getrennt:

| Ebene | Empfohlener Aufsetzpunkt |
|---|---|
| Artifact | heruntergeladen und SHA-256-verifiziert |
| Datenbank | installiert, fachlich verifiziert, als `LAB_GENERATED`-Backup gesichert |
| Hyper-V OS | generalisierte OS-Evaluation als Parent-VHDX |
| Hyper-V Guest | OS konfiguriert, Integration und Baseline-Patches vorhanden |
| Hyper-V SQL | SQL Server in definierter Version, Edition und Featuremenge installiert |
| Szenario | nur bei hohem Wiederherstellungsnutzen und klarer Invalidierungsregel |

Testdatenbanken werden standardmäßig nicht dauerhaft in ein allgemeines
OS-Parent-Image eingebettet. Sie bleiben austauschbare Datenbankartefakte.
Hyper-V Checkpoints dienen dem Reset einer registrierten VM; portable
Wiederverwendung erfolgt über Parent-/Differencing-VHDX und verifizierte
Datenbank-Baselines.

Containerzustände werden nicht standardmäßig durch unkontrollierte
Container-Commits konserviert. Provider-Image, deklarative Konfiguration und
Datenbank-Baseline bleiben getrennt.

## 11. Resource Assessment, Verification und Cleanup

Das Resource Assessment berücksichtigt:

- Downloadgröße;
- temporären Acquisition- und Entpackbedarf;
- erwartete Restore-/Importgröße;
- zusätzliche Data-/Log-/TempDB-Flächen;
- Baseline-Erzeugung;
- providerbezogenen Overhead;
- Hostreserve.

Verification ist typspezifisch, umfasst aber mindestens:

- erwartete Datenbanknamen;
- `ONLINE`-Status;
- erwartete Compatibility und erforderliche Features;
- katalogisierte Tabellen, Marker oder Abfragen;
- optional scriptspezifische Versionsmarker.

Erst nach erfolgreicher Verification erhält die Installation den Status
`DATASET_READY` und darf eine Baseline erzeugen.

Cleanup und Compensation:

- entfernen nur Run-eigene temporäre Dateien und Datenbanken;
- bewahren Cache, Trust und Baselines entsprechend ihrer Retention Policy;
- löschen keine vorbestehenden Datenbanken oder fremden Dateien;
- führen bei unsicherem Teilzustand zu `RECOVERY_REQUIRED`;
- sind vor der ersten Mutation im Cleanup Plan registriert.

## 12. Fehler- und Statusvertrag

Mindestens folgende stabilen Statusklassen sind vorzusehen:

```text
TRUST_REQUIRED
ARTIFACT_ACQUISITION_FAILED
ARTIFACT_INTEGRITY_MISMATCH
ARTIFACT_TYPE_UNSUPPORTED
ARTIFACT_PREPARE_FAILED
ARTIFACT_HANDLER_CAPABILITY_MISSING
SAMPLE_OUTPUT_CONFLICT
SAMPLE_INSTALLATION_FAILED
SAMPLE_VERIFICATION_FAILED
BASELINE_NOT_COMPATIBLE
BASELINE_VERIFICATION_FAILED
DATASET_READY
RECOVERY_REQUIRED
```

Konsumenten werten strukturierte Codes und Results aus, nicht übersetzten
Konsolentext.

## 13. Implementierungswellen

### Welle 1 – Vertrag und Menümetadaten (`IMPLEMENTED_FOUNDATION`)

- Sample-Schema um typisierte Artifact- und Installation-Metadaten erweitern;
- `x-ui`-Metadaten und vollständige Pfadsemantik ergänzen;
- generische Sample-Auflösung auf den gemeinsamen Artifact-Vertrag umstellen;
- statische Vertrags- und Dokumentationschecks ergänzen.

Die Mehrfachauswahl selbst, mehrere Outputs aus einer Installation und ihre
Kollisionsprüfung benötigen das neue Manifest-/Bound-Plan-Modell. Sie waren
deshalb Bestandteil von Welle 3; der einzelne Backup-Restore wird weiterhin
streng gegen den erwarteten Katalognamen geprüft.

### Welle 2 – Acquisition, Trust und Cache

- gemeinsamer Artifact Resolver;
- temporärer Download;
- persistenter Trust Store;
- inhaltsadressierter Cache;
- Run Lock und sanitisiertes portables Lock;
- Hash-Mismatch- und Quarantänepfad;
- nicht interaktiver Status `TRUST_REQUIRED`.

**Implementiert am 2026-07-30:** Der gemeinsame Backup-Resolver lädt in einen
lokalen Staging-Bereich, berechnet SHA-256, verwaltet versionierte lokale
Trust-Records und verschiebt verifizierte Bytes in einen inhaltsadressierten
Cache. Abweichende Bytes werden quarantänisiert. `manifest.lock.json` enthält
nur sanitisierte Artifact-Identität und Integritätsmetadaten; ein portables Lock
kann aus diesem Inhalt erzeugt werden.

### Welle 3 – Backup-Samples und Mehrfachauswahl

- bestehenden `.bak`-Restore in den Handlervertrag überführen;
- Sample-Auswahl in Ad-hoc-Menü und Manifest-Wizard;
- mehrere Samples pro Instanz;
- AdventureWorks- und WideWorldImporters-Varianten nach erfolgreichem
  Trust-/Hash-Pfad ausführbar machen;
- Resource Assessment um Artifact-Bedarf ergänzen.

**Erweitert am 2026-08-07:** Der Sample-Handler
(`Private/SampleArtifactHandlers.ps1`) bindet die Sample-Identität an Trust
Store, Cache und Run Lock, setzt `fail-if-exists` durch und verifiziert die
erwartete Datenbank als `ONLINE` (`DATASET_READY`). Direkte
`.bak`-Backup-Varianten, fest katalogisierte ZIP-Backups (temporäres
Entpacken einer exakten `.bak`-Payload) sowie einzelne gepinnte SQL-Skripte
sind `executable`. Ohne Katalog-SHA-256 gilt der Trust-Pfad `interactive-once`,
nicht interaktiv endet die Aufloesung mit `TRUST_REQUIRED`. Mehrfachauswahl ist im Ad-hoc-Menü und über
`New-SqlServerLab -Sample` verfügbar; Kollisionen erwarteter Outputs werden als
`SAMPLE_OUTPUT_CONFLICT` abgewiesen. Der Manifest-Wizard bietet für
`sample`-Felder eine Katalogauswahl. Das Storage-Assessment rechnet Download-
und geschätzte Installationsgrößen ein. Das Überschreiben erwarteter
Zieldatenbanknamen und mehrere Outputs pro Installation bleiben offen.

### Welle 4 – SQL-Skripte und Bundles

- `sql-script`-Handler für einzelne gepinnte Skripte umgesetzt;
- `script-bundle`-Handler mit begrenzter sqlcmd-Unterstützung umgesetzt;
- erwartete mehrere Datenbankausgaben umgesetzt;
- Verification, Idempotency und fail-closed Recovery umgesetzt;
- Northwind als erster ausführbarer Script-Sample-Nachweis.

**Implementiert am 2026-08-09:** ZIP-Bundles werden erst nach Artifact-Trust in
einen temporären Scope extrahiert. Der katalogisierte Entrypoint darf nur
root-gebundene SQL-Includes und explizit freigegebene `GO`-/`:setvar`-Features
verwenden. Alle erwarteten Datenbanken werden vor Apply auf Konflikte und nach
Apply auf `ONLINE` geprüft; unsichere Teilzustände enden mit
`RECOVERY_REQUIRED` statt automatischer Fremddatenlöschung.

### Welle 5 – Baselines

- `LAB_GENERATED`-Backup-Erzeugung;
- Baseline Registry, Key und Verification;
- deterministische Auswahl der besten kompatiblen Baseline;
- Invalidierung und Fallback.

Teilstand: Das lokale, portable Register, die deterministische Key-Bildung,
exakte und kompatible Auswahl sowie Quarantäne bei fehlenden, pfadfremden oder
hashabweichenden Objekten sind implementiert. Noch offen sind die SQL-seitige
Backup-Erzeugung nach erfolgreicher Sample-Verifikation und die Runtime-
Präferenz mit Fallback auf das verifizierte Originalartefakt.

### Welle 6 – Weitere Artifact Types und Hyper-V-Bindung

- BACPAC;
- verifizierte Archive;
- kontrolliertes Attach;
- Parent-/Differencing-VHDX-Bindings;
- OS-, Guest-, SQL- und Szenario-Aufsetzpunkte.

Jede Welle hält Schema, Parser, Runtime, Beispiele, Tests, README,
`KNOWN_LIMITATIONS.md`, Katalogdokumentation und `.ai/repo_map.yaml` synchron.

## 14. Abnahmekriterien

Der Zielvertrag ist implementiert, wenn:

1. Benutzer im Ad-hoc-Menü mehrere kompatible Testdatenbanken auswählen können;
2. der Manifest-Wizard dieselbe Mehrfachauswahl und vollständige
   Kontextinformationen bietet;
3. jede Pfadfrage Scope, Default, Bezugsbasis und aufgelöste Vorschau erklärt;
4. fehlende SHA-256 im interaktiven Lauf genau einmal pro konkretem Artifact
   bestätigt werden kann;
5. Trust Store und Lock spätere Ausführungen ohne erneute Frage ermöglichen;
6. nicht interaktive Läufe fehlendes Vertrauen sicher mit `TRUST_REQUIRED`
   melden;
7. geänderte Bytes unter derselben URL immer einen harten Hash-Mismatch
   auslösen;
8. direkte Backups und mindestens ein SQL-Skript-Sample automatisiert,
   verifiziert und bereinigt werden;
9. ein Script Bundle mehrere erwartete Datenbanken sicher erzeugen kann;
10. eine verifizierte `LAB_GENERATED`-Baseline bevorzugt und bei Inkompatibilität
    verworfen wird;
11. keine Produktions-, unbekannten, fremden oder nicht verifizierten
    Datenartefakte ausgeführt werden;
12. Docker, Podman und Hyper-V denselben übergeordneten Artifact-Vertrag
    verwenden;
13. Statusdokumentation und Tests den tatsächlichen Runtimeumfang korrekt
    ausweisen.
