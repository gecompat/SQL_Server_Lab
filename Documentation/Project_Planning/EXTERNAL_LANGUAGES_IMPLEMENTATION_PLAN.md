# Implementierungsplan für SQL Server External Languages

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_SQL2022_REFERENCE` |
| Stand | 2026-08-28 |
| Bestehende Arbeitspakete | `SFT-711`, `SFT-712` |
| Zielprovider | Hyper-V/Windows, Docker/Linux, Podman/Linux |
| Zielsprachen | Python, R, Java |

Dieses Dokument beschreibt Planung und abgeschlossenen SQL-2022-Referenzumfang
für SQL Server External Languages im providerneutralen Lab-Core. Es bleibt
selbst kein Runtime-Nachweis; maßgeblich sind Katalog, Code und die tatsächlich
ausgeführten providergetrennten Acceptances.

## 1. Ziel und Abgrenzung

Eine Lab-Instanz soll deklarativ eine zu SQL Server passende External Runtime
anfordern können. Der Planner löst daraus vor jeder Mutation genau eine
unterstützte Kombination aus SQL-Version, Betriebssystem, Distribution,
Provider, Runtime, Extension, Paketen und Installationsartefakten auf.

Der erste vollständige Zielumfang umfasst:

- Python und R über SQL Server Machine Learning Services;
- Java über SQL Server Language Extensions;
- Windows Server als Hyper-V-Gast;
- Linux-Container mit Docker und Podman;
- versionierte Derived Container Images als reproduzierbaren Container-Default;
- verifizierte Installationsmedien und eine resumierbare Gastinstallation für
  Hyper-V;
- eine echte Ausführung über `sp_execute_external_script` als abschließende
  Postcondition;
- providergebundene State-, Cleanup-, Recovery- und Validation-Evidence.

Nicht Teil dieser Umsetzung sind:

- eine allgemeine Python-, R- oder Java-Labplattform ohne SQL-Server-Bezug;
- beliebige Shell-Befehle aus einem Manifest;
- ungeprüfte Installation der jeweils neuesten Runtime oder Pakete;
- produktive Paket-Repositories oder ein allgemeiner Package-Hosting-Dienst;
- .NET Language Extensions, GPU-Stacks, Spark oder verteiltes Training;
- Hyper-V/Linux, da der konkrete Zielumfang Windows auf Hyper-V und Linux in
  Containern vorsieht.

## 2. Ermittelter Ist-Stand

Der bestehende Vertrag ist vorbereitet, aber nicht vollständig ausführbar:

- `Schemas/lab-manifest.schema.json` kennt
  `serverConfig.externalScripts` mit Python, R und Java;
- `Private/ServerConfig.ps1` enthält
  `Install-LabExternalLanguages`, das Pakete nach dem Containerstart mit
  `apt-get`, `pip` oder CRAN installiert;
- `Public/New-SqlServerLab.ps1` ruft diesen Pfad nur für Containerinstanzen auf;
- der Aufruf bindet den bereits ausgewählten Docker-/Podman-Provider nicht
  explizit an die Installation;
- `customImage` und `installMethod = pre-built` sind reserviert, aber nicht an
  die Imageauswahl gebunden;
- Java-Zusatzbibliotheken, Windows/Hyper-V, Installationsreceipts,
  Capability-Auflösung und echte Sprach-Postconditions fehlen;
- `Schemas/example-ml-services.json` beschreibt mehr Verhalten, als der
  aktuelle Runtimepfad zuverlässig nachweist;
- `software[]` ist im Desired State sichtbar, wird für die Runtimeprovider aber
  weiterhin als nicht unterstützt klassifiziert.

Der vorhandene `post-start`-Installer bleibt während der Migration ein
expliziter Legacy-Pfad. Er darf nicht zur Grundlage der Zielarchitektur werden,
weil die Mutation laufender Container weder reproduzierbar noch vollständig
recoverable ist.

## 3. Verbindliche Entwurfsentscheidungen

### 3.1 Ein gemeinsamer Softwarevertrag

External Runtimes sind spezialisierte SQL-bezogene Software. Die Umsetzung
verwendet deshalb den geplanten providerneutralen Softwarekatalog aus
`SFT-711` und keinen zweiten, unabhängigen Installationsvertrag.

`serverConfig.externalScripts` behält die SQL-Instanzkonfiguration wie
`enabled` und Resource-Governor-Werte. Auswahl und Installation der Runtime
werden in normalisierte Software-Intents überführt. Bestehende Manifeste werden
im Parser kompatibel normalisiert und erhalten bei mehrdeutigen oder nicht
reproduzierbaren Angaben eine klare Warnung beziehungsweise Ablehnung.

Das Zielmanifest soll sinngemäß folgenden Vertrag ausdrücken:

```json
{
  "software": [
    {
      "id": "sql-python",
      "version": "catalog-default",
      "scope": "sqlExternalRuntime",
      "packages": [
        { "name": "pandas", "version": "catalog-locked" }
      ]
    }
  ],
  "serverConfig": {
    "externalScripts": {
      "enabled": true,
      "resourceGovernor": { "maxMemoryPercent": 40 }
    }
  }
}
```

`catalog-default` und `catalog-locked` sind hier Zielnotationen, keine bereits
gültigen Manifestwerte. Der endgültige Schemaentwurf darf nur Werte zulassen,
die der Resolver deterministisch auflösen kann.

### 3.2 Katalog statt Installationslogik im Manifest

Ein neuer Softwarekatalog enthält pro Variante mindestens:

- stabile Software-ID, Runtime- und Extension-Version;
- SQL-Major-Version und gegebenenfalls Mindest-CU;
- Gastbetriebssystem, Distribution, Version und Architektur;
- erlaubte Provider;
- Quelle, Lizenz, SHA-256 und Integrity Origin;
- Paket- beziehungsweise Installerformat;
- Installationsrezept-Version und erforderliche Rechte;
- Neustart- und Serviceverhalten;
- Runtime-, Extension- und Package-Postconditions;
- Cleanup-, Retention- und Refresh-Regeln;
- Status `SUPPORTED`, `PREVIEW`, `DEPRECATED`, `RETIRED` oder `BLOCKED`.

Das Manifest darf keine freie `command`-Ausführung für External Runtimes
aktivieren. Netzwerkquellen ohne Version und Integritätsbindung werden vor der
Mutation abgelehnt.

### 3.3 Providerstrategie

- Docker und Podman verwenden standardmäßig ein aus dem katalogisierten
  SQL-Basisimage abgeleitetes OCI-Image.
- Das Derived Image ist an den Digest des Basisimages, den Softwarekatalog,
  Runtimeartefakte und Package Locks gebunden.
- Docker und Podman dürfen dasselbe OCI-Artefakt konsumieren; Build, Start,
  Rootless-Verhalten, Health, Cleanup und External-Script-Ausführung bleiben
  trotzdem getrennte Native-Nachweise.
- Hyper-V installiert Runtime und Extensions im Windows-Gast über den
  bestehenden resumierbaren Guest-Execution-Vertrag und verifizierte lokale
  Medien.
- Eine Mutation eines bereits laufenden Containers bleibt nur als ausdrücklich
  ausgewählter, nicht reproduzierbarer Legacy-Modus verfügbar und wird nicht
  als Standard oder vollständige Validation gewertet.

### 3.4 SQL- und Datenbank-Scope

Machine Learning Services, Launchpad, `external scripts enabled` und
Resource-Governor-Konfiguration sind Instanzverträge. `CREATE EXTERNAL
LANGUAGE`, `CREATE EXTERNAL LIBRARY` und die zugehörigen Berechtigungen können
datenbankbezogen sein. Der Planner hält beide Scopes getrennt und führt
Java-Bibliotheken nicht als Betriebssystempakete aus.

## 4. Supportmatrix und Einführungsreihenfolge

Die folgende Tabelle ist eine Implementierungspriorität und keine Aussage, dass
alle Kombinationen bereits unterstützt oder validiert sind.

| SQL-Version | Hyper-V/Windows | Docker/Linux | Podman/Linux | Priorität |
|---|---|---|---|---|
| 2022 | Python, R, danach Java | Python, R, danach Java | Python, R, danach Java | Referenzpfad |
| 2025 | eigenes Capability- und Runtime-Gate | eigenes Capability- und Runtime-Gate | eigenes Capability- und Runtime-Gate | nach 2022-Characterization |
| 2019 | getrennte Legacy-Varianten | getrennte Legacy-Varianten | getrennte Legacy-Varianten | nach modernem Pfad |

Begründung:

- Microsoft dokumentiert für SQL Server 2022 und spätere Versionen auf Windows
  Custom Runtimes für Python und R; die Runtimes werden nicht mehr von SQL
  Setup mitgeliefert.
- Für SQL Server 2022 auf Linux ist Python/R einschließlich Installation in
  Linux-Containern dokumentiert.
- Java ist auf Windows und Linux ein eigener Language-Extensions-Pfad mit
  Runtime, Extension-Registrierung und External Library.
- Die Linux-Anleitung für Machine Learning Services ist versionsspezifisch.
  SQL Server 2025 wird daher nicht stillschweigend aus einer 2022-Anleitung als
  unterstützt abgeleitet, sondern erst nach eigener Quellenprüfung und realem
  Providernachweis freigegeben.
- SQL Server 2019 besitzt andere gebündelte beziehungsweise CU-abhängige
  Installationsverträge und darf nicht denselben Handler mit nur einer anderen
  Versionsnummer verwenden.

Die ersten Katalogvarianten werden aus den Herstellerangaben für SQL Server
2022 aufgebaut. Konkrete Runtimeversionen wie Python 3.10, R 4.2 oder Java 11
werden nur in der jeweils belegten Variante gebunden und nicht als zeitlose
globale Defaults behandelt.

## 5. Umsetzung in Wellen

### Welle 1 – Characterization und sichere Grenze

1. Den bestehenden `post-start`-Pfad mit fokussierten Tests charakterisieren.
2. Die fehlende Providerübergabe im aktuellen Aufruf als Regressionstest
   festhalten.
3. Unverifizierte Kombinationen vor `apt-get`, `pip`, CRAN oder einem
   Gastinstaller ablehnen.
4. `Schemas/example-ml-services.json` eindeutig als Zukunftsbeispiel markieren
   oder auf den tatsächlich ausführbaren Teil reduzieren.
5. Den Legacy-Pfad im Planner sichtbar als `NON_REPRODUCIBLE` klassifizieren.

Gate: Kein External-Languages-Request kann mehr still auf die falsche Runtime,
ein ungebundenes Image oder eine unbelegte Supportannahme fallen.

### Welle 2 – Softwarekatalog und Capability Resolver (`SFT-711`)

1. `Catalogs/software.json` und das zugehörige JSON-Schema einführen.
2. Einen Resolver für SQL-Version, CU, OS, Distribution, Architektur, Provider,
   Runtime und Installationsmethode implementieren.
3. Provider-Metadaten um konkrete Capabilities wie
   `derived-image-build`, `sql-external-runtime` und
   `powershell-direct-software-installation` ergänzen.
4. Normalisierte Software-Intents in `Private/DesiredState.ps1` vollständig und
   geheimnisfrei persistieren.
5. Einen deterministischen Plan mit Artefaktbedarf, Downtime, Neustarts,
   Package Locks und Validation-Schritten erzeugen.
6. Ein sanitisiertes Installationsreceipt definieren; es enthält IDs,
   Versionen, Digests, Rezeptversionen, Status und Postconditions, aber keine
   lokalen Secret-, Medien- oder Hostpfade.

Gate: Jede Kombination endet vor der Mutation entweder in genau einem
reproduzierbaren Plan oder in `DECLARED_UNSUPPORTED` mit Begründung.

### Welle 3 – Derived Container Images für Python und R (`SFT-712`)

1. Einen versionierten Buildkontext aus dem SQL-Basisimage und der aufgelösten
   Softwarevariante erzeugen.
2. Basisimage per Digest binden; `latest` darf höchstens Eingabe für eine
   explizite Refresh-Operation sein.
3. Linux-Pakete, Runtime, Microsoft-Komponenten und Python-/R-Pakete mit
   aufgelösten Versionen und Integritätsdaten installieren.
4. EULA-Annahme ausdrücklich und kataloggebunden behandeln.
5. Extension- und Launchpad-Konfiguration im Image vorbereiten; erst der Run
   aktiviert instanzbezogene SQL-Konfiguration.
6. Image-Key, Buildreceipt, Retention und Cleanup in den bestehenden
   Artifact-Lifecycle integrieren.
7. Provideradapter so erweitern, dass sie das aufgelöste Derived Image statt
   immer `Get-SqlServerDockerImage` verwenden.

Gate je Provider:

- Image-Build abgeschlossen und Digest persistiert;
- Container startet mit der gespeicherten Providerbindung;
- SQL Readiness ist erfolgreich;
- Launchpad beziehungsweise `launchpadd` ist bereit;
- Python beziehungsweise R liefert über `sp_execute_external_script` eine
  erwartete Runtime- und Packageversion;
- Remove bereinigt Run-Ressourcen, ohne wiederverwendbare Images unkontrolliert
  zu löschen.

Implementierungsstand 2026-08-28: Das Rezept v5 bindet das SQL-2022-Basisimage,
Python-, R- und Java-Artefakte, SQL-Satellite-OpenSSL-Kompatibilität und den
sicheren Namespace-Launchvertrag vollständig. Die Python- und R-Stages binden
die benötigte Ubuntu-`libgomp1`-Laufzeit eigenständig per Version und SHA-256.
Docker und Podman bestanden
getrennte native Acceptances mit Python- und R-Datenroundtrip, Package- und
Worker-Identität vor und nach providergebundenem Neustart. Run-Ressourcen,
Derived Image und das test-eigene Podman-Netz wurden vollständig bereinigt.

### Welle 4 – Java in Linux-Containern

1. JRE/JDK und Language-Extension-Binary als getrennte katalogisierte
   Artefakte modellieren.
2. `JRE_HOME` und Extension-Pfad ausschließlich aus der aufgelösten Variante
   setzen.
3. `CREATE EXTERNAL LANGUAGE` idempotent pro Zieldatenbank ausführen.
4. Java-Testcode als synthetisches, versioniertes JAR mit dokumentierter Lizenz
   und SHA-256 bereitstellen.
5. Das JAR über `CREATE EXTERNAL LIBRARY` registrieren und mit
   `sp_execute_external_script` ausführen.
6. Drop-/Compensation-Schritte für External Library und External Language vor
   der Mutation registrieren.

Gate: Java gilt erst als bereit, wenn ein katalogisiertes Test-JAR innerhalb
von SQL Server ausgeführt wurde; `java -version` allein reicht nicht.

Implementierungsstand 2026-08-28: JDK, Extension, SDK-Quellen und synthetisches
Probe-JAR sind versioniert und SHA-256-gebunden; das compilerfreie Java-Image
und alle Python-/R-/Java-Kombinationsstages bauen. Datenbankgebundene DDL,
Content-Driftprüfung, Idempotenz und Fehlerkompensation sind gegen SQL Server
2022 nachgewiesen. Docker und Podman bestanden jeweils den echten SQL-JAR-
Datenroundtrip samt Worker-Identität vor und nach providergebundenem Neustart;
die Linux-Java-Variante ist `SUPPORTED`.

### Welle 5 – Hyper-V/Windows für Python und R

Voraussetzung ist ein real validierter Windows-SQL-Pfad mit den für Machine
Learning Services benötigten SQL-Setup-Features. Der aktuelle eingeschränkte
Prepared-Image-Klonpfad allein ist noch kein vollständiger Nachweis.

1. SQL-Image-Plan und `CompleteImage` um Machine Learning Services und Language
   Extensions erweitern.
2. Runtimeinstaller, Microsoft-Pakete und Offlineabhängigkeiten über den Media
   Root mit Lizenz, SHA-256 und Herkunft registrieren.
3. Installation und ACLs im Gast über PowerShell Direct ausführen.
4. Reboot und Launchpad-Neustart als resumierbare Zustände modellieren.
5. Runtimepfade instanzspezifisch konfigurieren; fremde parallele
   Python-/R-Installationen nicht automatisch übernehmen.
6. SQL-Konfiguration und reale Python-/R-Ausführung vom Host aus verifizieren.
7. Erst nach erfolgreicher Verification `EXTENSIONS_READY_RUN` persistieren.

Gate: Frischer Windows-Gast, SQL-Feature, Runtime, Launchpad, External Script,
Resume nach Reboot und vollständiges Cleanup sind in einem echten Hyper-V-Lauf
nachgewiesen.

Implementierungsstand 2026-08-28: SQL-Feature-Vertrag, SHA-256-gebundene
Offlinemedien, Gastinstaller, ACLs, RegisterRext, State/Recovery und der native
Acceptance-Runner sind implementiert. Python 3.10.11 und R 4.2.3 bestanden im
isolierten Windows-Server-2025-Klon den SQL-Datenroundtrip samt Runtime-, Paket-
und Worker-Identitätsprüfung vor und nach vollständigem VM-Kaltstart. Der
registrierte Cleanup-Plan entfernte VM, Child-VHDX und Parent-Kopie; der
ausgeschaltete Quell-Slot blieb unverändert. Die Varianten sind `SUPPORTED`.

### Welle 6 – Hyper-V/Windows für Java

1. Language-Extensions-Feature im SQL-Setup-Plan sicherstellen.
2. Eine katalogisierte, zur Extension passende Java-Runtime installieren.
3. Rechte für Launchpad und Extensionverzeichnis kontrolliert setzen.
4. External Language und synthetische External Library pro Datenbank
   registrieren.
5. Ausführung, Neustart, Resume und Cleanup analog zum Containerpfad prüfen.

Gate: Die gleiche fachliche Java-Postcondition wie unter Linux ist erfüllt;
nur die Installations- und Guest-Execution-Adapter unterscheiden sich.

Implementierungsstand 2026-08-28: Microsoft OpenJDK 17.0.20.1, Windows
Language Extension 1.1.0, das darin enthaltene SDK sowie das reproduzierbare
Probe-JAR sind SHA-256-gebunden. Offlineinstallation, DDL, Driftprüfung,
Kompensation und Cold-Start-Probe sind implementiert. Java 17.0.20.1 bestand
im selben isolierten Hyper-V-Lauf den echten SQL-JAR-Datenroundtrip samt
Worker-Identitätsprüfung vor und nach vollständigem VM-Kaltstart. Das
registrierte Cleanup war vollständig; die Variante ist `SUPPORTED`.

### Welle 7 – SQL Server 2025 und SQL Server 2019

1. Herstellerquellen und verfügbare Pakete je Plattform erneut prüfen.
2. Für SQL Server 2025 keine 2022-Paket- oder Runtimeannahme wiederverwenden,
   bis Kompatibilität belegt ist.
3. SQL Server 2019 als getrennte Legacy-Rezepte mit Mindest-CU und gebündelter
   Runtime behandeln.
4. Je Kombination ein fokussiertes Characterization-Ergebnis erzeugen.
5. Nur belegte Varianten auf `SUPPORTED` setzen; alle anderen bleiben
   `BLOCKED`, `PREVIEW` oder `DECLARED_UNSUPPORTED`.

Gate: Katalogstatus, Planner und tatsächliche Native-Evidence stimmen für jede
freigegebene Kombination überein.

### Welle 8 – UX, Reconcile und Refresh

1. CLI und Manifest-Wizard zeigen nur vom Resolver freigegebene Varianten.
2. Planvorschau nennt Downloads, Image-Build, Gastmutation, Reboots, Downtime,
   Package Locks und Verification.
3. Runtime- oder Packageänderungen werden als `rebuild`, `restart`,
   `recreate` oder `reprovision` klassifiziert; keine blinde In-place-Mutation.
4. Refresh baut ein neues Derived Image oder Gastartefakt neben dem bestehenden
   Zustand und schaltet erst nach erfolgreicher Validation um.
5. Alte Artefakte werden nur über Retention und scopegebundenen Cleanup
   entfernt.

Gate: CLI, Manifest, Desired State, Runtime, Reconcile und Cleanup verwenden
denselben aufgelösten Softwarevertrag.

Implementierungsstand Welle 8A, 2026-08-28: Der Manifest-Wizard bietet nur die
für SQL-Version, Provider und Betriebssystem als `RESOLVED` aufgelösten
External-Runtime-Varianten an. `Test-SqlServerLabManifest` liefert denselben
geheimnisfreien Plan mit Downloads, Derived-Image-Build oder Gastmutation,
Restart-/Downtime-Bedarf, vollständigen Package Locks und Verification. Eine
portable `PlanKey` bindet Plan, Installation Receipt, Derived-Image-Plan,
Buildreceipt, Run-State sowie Cleanup-/Recovery-Vertrag; Run-Cleanup entfernt
die gebundenen Laufzeitressourcen und behält wiederverwendbare Artefakte. Die
Vorschau trennt `rebuild`, `restart`, `recreate`, `reprovision` und `no-op`. Der ausführbare
allgemeine Reconcile- sowie der versionierte Refresh-/Umschaltpfad bleiben
eigenständige Folgearbeit und sind durch diesen read-only Slice nicht als
implementiert ausgewiesen.

Implementierungsstand Welle 8B, 2026-08-28: Für laufende SQL-2022-Docker- und
Podman-Runs mit bereits verifizierter External Runtime kann der öffentliche
Reconcile-Vertrag additive Runtime-Anforderungen aus einem Zielmanifest planen
und ausführen. Nicht-Software-Drift wird vor der Mutation abgelehnt. Der Apply-
Pfad baut das neue inhaltsadressierte Derived Image zuerst, journalisiert die
Umschaltung, erstellt den Ersatzcontainer über denselben Providervertrag wie die
Erstprovisionierung und übernimmt ihn erst nach SQL-Readiness sowie echten
`sp_execute_external_script`-Postconditions. Vor dem State-Commit wird auf den
alten Container zurückgerollt; danach wird dessen Cleanup resumierbar
abgeschlossen. Alte Images bleiben gemäß Retention erhalten. Runtime-Entfernung,
allgemeiner Packagewechsel und Hyper-V-Artifact-Refresh bleiben Folgearbeit.
Der vollständige Python-only-zu-Python/R/Java-Umschaltpfad bestand getrennte
native Docker- und Podman-Abnahmen auf Ubuntu 22.04 mit cgroup v1 einschließlich
Journal `COMPLETED`, Restart-Probes und Cleanup.

Implementierungsstand Welle 8C, 2026-08-28: Der Container-Reconcile-Pfad
unterstützt nun auch die explizite Entfernung einer Runtime. Für Java sind
External Language, SDK-Library und Probe-Library eigentumsgebunden registriert,
journalisiert und kompensierbar; `PLATFORM = LINUX` ist Bestandteil der
jeweiligen `CREATE EXTERNAL LIBRARY`-Dateispezifikation. SQL-Daten und die
beiden langlebigen Runtime-Artefaktverzeichnisse werden in drei getrennten
Volumes über Replacement-Container hinweg erhalten, während LaunchPad-Daten
und Sandboxes containerlokal bleiben. Der Startadapter synchronisiert ML-EULA,
Runtime-Konfiguration und Artefaktbesitz für Docker und Podman. Transiente
LaunchPad-Fehler `39011`/`39012` erlauben genau einen Container-Restart und
Probe-Retry; der Java-Ownership-Tracker bleibt dabei erhalten. Die native
Docker-/Podman-Abnahme bewies Python-only-Provisionierung, additiven
Python/R/Java-Refresh, Java-Removal, Python/R-Restart-Probes, SQL-Datenpersistenz
und vollständigen Cleanup aller vier run-eigenen Ressourcen.

Implementierungsstand Welle 8D, 2026-09-02: Für laufende SQL-2022-Windows-/
Hyper-V-Runs routet derselbe öffentliche Manifest-Reconcile zu einem getrennten
additiven Gastpfad. Neue Python-, R- und Java-PlanKeys werden VM- und
Zielhash-gebunden journalisiert, mit dem katalogisierten idempotenten Offline-
Installer angewandt und erst nach echten SQL-Postconditions, vollständigen
Installation Receipts und aktualisiertem Connection-State in den Desired State
übernommen. Plan, `WhatIf`, No-op, Fehler/Resume und Removal-Blockade sind
statisch und synthetisch belegt. Removal, Varianten-/Packagewechsel sowie
Artifact-Refresh bleiben Folgearbeit. Die direkte Gastinstallation besitzt
native SQL-2022-Evidence; der neue öffentliche Reconcile-Ablauf ist noch
`NOT_EXECUTED`.

Implementierungsstand Welle 8E, 2026-09-02: Docker und Podman unterstützen
nun auch die Entfernung der letzten External Runtime. Der Resolverplan besitzt
dafür die explizite Operation `RemoveExternalRuntime` mit leerem Ziel-Image-
Key. Der Executor baut kein leeres Derived Image, sondern erstellt neben dem
Rollback-Container einen Ersatz auf dem katalogisierten SQL-Basisimage,
übernimmt exakt das bestehende SQL-Datenvolume und sonstige Nicht-Runtime-
Mounts, deaktiviert `external scripts enabled` und entfernt Runtime-State sowie
Receipts erst nach SQL-Postcondition. Runtime-Sidecars werden lediglich
ausgehängt und bleiben bis zu ihrem normalen Retention-/Cleanup-Pfad erhalten.
Getrennte native Docker-/Podman-Abnahmen bestätigten Datenpersistenz,
Basisimage, `0/0`-Konfiguration, Restart, Journalabschluss und vollständigen
Cleanup. Hyper-V-Removal und freie Varianten-/Packagewechsel bleiben offen.

## 6. Betroffene Repositoryverträge

Mindestens gemeinsam zu prüfen und je Welle kohärent zu ändern sind:

| Bereich | Voraussichtlich betroffene Quellen |
|---|---|
| Manifest | `Schemas/lab-manifest.schema.json`, `Private/ManifestParser.ps1`, `Private/ManifestBuilder.ps1`, Beispiele |
| Katalog | neuer Softwarekatalog, Katalogschema, `Catalogs/README.md`, Resolver |
| Desired State | `Private/DesiredState.ps1`, Plan-/Diff-Darstellung, Run-State |
| Container | `Providers/Docker/DockerProvider.ps1`, `Providers/Podman/PodmanProvider.ps1`, Provider-Metadaten, Image-Build/Registry |
| Hyper-V | SQL-Image-Builder, Guest Execution, Provideradapter, Image-/Media-Registry, Resume-State |
| SQL-Konfiguration | `Private/ServerConfig.ps1`, Datenbank-Registrierung, Resource Governor |
| Lifecycle | State Machine, Cleanup Engine, Recovery und Artifact Retention |
| UX | Console-UI, Manifest-Wizard, Planvorschau und Benutzeranleitungen |
| Statuswahrheit | `.ai/PROJECT_CONTEXT.md`, `.ai/repo_map.yaml`, `README.md`, `KNOWN_LIMITATIONS.md` |
| Tests | fokussierte statische Suites sowie getrennte Docker-, Podman- und Hyper-V-Smokes |

Neue produktive Funktionen werden nicht exportiert, solange der vorhandene
Manifest- und Plannerpfad ausreicht. Falls später eine öffentliche
Image-Build- oder Refresh-Funktion erforderlich wird, gelten zusätzlich alle
gekoppelten öffentlichen Cmdlet-Verträge.

## 7. Sicherheits-, Lizenz- und Recovery-Vertrag

- External Scripts führen nicht vertrauenswürdigen Code außerhalb des SQL
  Engine-Prozesses aus. Aktivierung erfolgt nur auf ausdrücklichen Manifest-Intent.
- Runtime-, Extension-, JAR-, Wheel-, CRAN- und OS-Pakete sind
  Drittanbieterartefakte und benötigen Quelle, Lizenz, Version und Integrität.
- Freie Paketnamen ohne Lock und Hash sind im reproduzierbaren Modus unzulässig.
- Installer laufen nur im eigenen Container oder gebundenen Hyper-V-Gast und
  niemals gegen den Host.
- Provider, RunId, ScopeId, Image-Key und VM-Identität werden vor jeder Mutation
  erneut geprüft.
- Cleanup-Schritte werden vor Image-Build, Download, SQL-DDL und Gastmutation
  registriert.
- Ein Teilfehler endet in vollständiger Compensation oder sichtbar in
  `RECOVERY_REQUIRED`; `SQL_READY` darf nicht als `EXTENSIONS_READY_RUN`
  umgedeutet werden.
- Logs und Receipts enthalten keine Passwörter, Connection Strings, lokalen
  Medienpfade oder unkontrollierte Installer-Ausgaben.
- Paketdownloads verwenden Timeouts, begrenzte Retries und einen
  inhaltsadressierten Cache; Netzwerkfehler führen nicht zu einem teilweise
  freigegebenen Image.

## 8. Validation und Evidence

### 8.1 Statische Prüfungen

Für jede Welle sind mindestens erforderlich:

- Schema- und Katalogvalidierung;
- Resolver-Fixtures für unterstützte, blockierte und mehrdeutige Kombinationen;
- Providerbindungs-, Desired-State- und Receipt-Verträge;
- Tests gegen freie Commands, fehlende Hashes, unbekannte Varianten und
  unzulässige Pfade;
- Dokumentations- und Statuskonsistenz.

Während der Entwicklung wird zuerst die neue fokussierte Suite ausgeführt,
danach die betroffene Auswahl über `Invoke-ImpactedChecks.ps1`. Der stabile
Abschlussstand verwendet den projektweit erforderlichen statischen Gate genau
einmal.

### 8.2 Native Acceptance-Matrix

Jede freigegebene Zelle wird eigenständig ausgeführt und berichtet
`PASS`, `FAIL`, `NOT_EXECUTED` oder `UNSUPPORTED`:

| Sprache | Docker/Linux | Podman/Linux | Hyper-V/Windows |
|---|---:|---:|---:|
| Python | `PASS` – nativer Build, SQL-Roundtrip, Restart, Cleanup | `PASS` – nativer Build, SQL-Roundtrip, Restart, Cleanup | `PASS` – Gastinstallation, SQL-Roundtrip, VM-Kaltstart, Cleanup |
| R | `PASS` – nativer Build, SQL-Roundtrip, Restart, Cleanup | `PASS` – nativer Build, SQL-Roundtrip, Restart, Cleanup | `PASS` – Gastinstallation, SQL-Roundtrip, VM-Kaltstart, Cleanup |
| Java | `PASS` – nativer Build, DDL, JAR-Roundtrip, Restart, Cleanup | `PASS` – nativer Build, DDL, JAR-Roundtrip, Restart, Cleanup | `PASS` – Gastinstallation, DDL, JAR-Roundtrip, VM-Kaltstart, Cleanup |

Ein vollständiger positiver Nachweis prüft:

1. deterministische Auflösung und Preflight;
2. Build beziehungsweise Gastinstallation;
3. notwendige Restart-/Resume-Schritte;
4. SQL- und Launchpad-Readiness;
5. Runtimeversion;
6. ein kleines Daten-In/Data-Out-Skript über
   `sp_execute_external_script`;
7. mindestens ein katalogisiertes Zusatzpaket beziehungsweise Test-JAR;
8. State und sanitisiertes Receipt;
9. Stop, Start und erneute Verification;
10. Remove, Artifact-Retention und Cleanupstatus.

Docker-Evidence gilt nicht für Podman. Ein erfolgreicher Hyper-V-Lifecycle ohne
External-Script-Ausführung gilt nicht als External-Languages-Nachweis. Eine
reine `python --version`-, `R --version`- oder `java -version`-Prüfung reicht
nicht aus.

## 9. Definition of Done

Der SQL-2022-Referenzumfang der ersten Ausbaustufe ist abgeschlossen. Python,
R und Java werden über denselben Softwarevertrag für Docker, Podman und
Hyper-V geplant und jede der neun Provider-/Sprachzellen hat die definierte
Native Acceptance bestanden. SQL Server 2019 und 2025 bleiben ohne eigene
freigegebene Varianten ehrlich `DECLARED_UNSUPPORTED`; Refresh-/Rebuild- und
weitergehende Reconcile-Funktionen bleiben eigenständige Folgearbeit.

Die erreichten Abnahmekriterien sind:

- Python, R und Java sind über denselben providerneutralen Softwarevertrag
  geplant;
- SQL Server 2022 hat auf Docker, Podman und Hyper-V/Windows je Sprache die
  definierte Native Acceptance bestanden;
- Container verwenden standardmäßig Derived Images statt Laufzeitmutation;
- Hyper-V-Installationen sind resumierbar und durch Media-/Integrity-Evidence
  gebunden;
- SQL Server 2025 und 2019 besitzen ohne freigegebene Variante den ehrlichen
  Status `DECLARED_UNSUPPORTED`;
- External Language, External Library, Package- und Instanz-Scope sind korrekt
  getrennt;
- State, Cleanup und Recovery kennen den Softwarevertrag;
- Front-Door-Dokumentation, Schema, Beispiele, Known Limitations und Repo-Map
  den tatsächlichen Stand wiedergeben;
- nur tatsächlich ausgeführte Providerprüfungen als `PASS` oder `validated`
  bezeichnet werden.

## 10. Herstellerquellen für die Implementierung

Die Quellen müssen bei der Katalogaufnahme erneut auf Aktualität und konkrete
SQL-/OS-Anwendbarkeit geprüft werden:

- [SQL Server 2022 Machine Learning Services auf Windows](https://learn.microsoft.com/en-us/sql/machine-learning/install/sql-machine-learning-services-windows-install-sql-2022?view=sql-server-ver17)
- [SQL Server 2022 Machine Learning Services auf Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-machine-learning-sql-2022?view=sql-server-ver17)
- [Java Language Extension auf Windows](https://learn.microsoft.com/en-us/sql/language-extensions/install/windows-java?view=sql-server-ver17)
- [Java Language Extension auf Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-language-extensions-java?view=sql-server-ver17)
- [Custom Python Runtime und `CREATE EXTERNAL LANGUAGE`](https://learn.microsoft.com/en-us/sql/machine-learning/install/custom-runtime-python?view=sql-server-ver15)
- [Extensibility-Architektur und Launchpad](https://learn.microsoft.com/en-us/sql/machine-learning/concepts/extensibility-framework?view=sql-server-ver17)
- [SQL Server 2025 Linux Release Notes](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-release-notes-2025?view=sql-server-ver17)

