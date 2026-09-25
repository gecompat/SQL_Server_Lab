# Querschnittliche Plattformfähigkeiten – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG_CANDIDATES` |
| Stand | 2026-09-25 |
| Zweck | bisher nicht eigenständig geplante, SQL-zentrierte Plattformlücken dauerhaft erfassen |
| Autorität | Planung und Priorisierung; keine Runtime-, Secret-, Export-, Import-, Update- oder Löschautorität |

## Einordnung

Dieser Backlog erfasst querschnittliche Fähigkeiten, für die im Repository
bisher kein eigener belastbarer Zielvertrag vorhanden war. Er ergänzt die
fachlichen Szenario-, Provider-, Storage-, Evaluation-, BI- und KI-Backlogs
und dupliziert sie nicht.

Die Aufnahme eines Themas bedeutet, dass die Lücke nicht verloren geht. Sie
ist noch keine Architekturentscheidung und kein Implementierungsnachweis.
Themen mit zentralem Dienst, Mehrbenutzerbetrieb, externer Infrastruktur oder
neuen Abhängigkeiten bleiben `DECISION_REQUIRED`, bis Scope, Betrieb,
Security, Recovery und Exit-Strategie ausdrücklich entschieden sind.

Bereits eigenständig geplant und deshalb hier nur als Abhängigkeit behandelt
werden insbesondere:

- vollständiger Evaluation-Refresh und Instanzmigration;
- Artifact Refresh/Rebuild für Medien, VHDX und Derived Images;
- Hyper-V-Ausbau, Remote-Hyper-V, Windows-Locale und Slot-Aktivierung;
- persistente Storage-Wiederverwendung, Retention und Datenbankpakete;
- Scenario Engine, Fault Injection und neue SQL-Anwendungsszenarien;
- SQL Server 2025 KI-/Vector-Funktionen, PolyBase/S3 sowie SSIS, SSAS und
  Cluster.

## Gemeinsame Leitplanken

Jede spätere Umsetzung muss:

- einen konkreten SQL-Server-Lab-Zweck besitzen;
- portable, geheimnisfreie Pläne und stabile Objektidentitäten verwenden;
- State, Scope, Ownership, Cleanup und Recovery vor der ersten Mutation
  festlegen;
- lokale Einzelplatznutzung weiterhin ohne zentralen Dienst ermöglichen;
- externe Dienste und neue Abhängigkeiten optional und austauschbar halten;
- Offline-, Mehrbenutzer- oder API-Fähigkeit nicht aus einem Dateiexport oder
  einem UI-Prototyp ableiten;
- geplante Funktionen bis zum statischen und nativen Nachweis ausdrücklich als
  nicht implementiert ausweisen.

## Priorisierte Kandidaten

Die vollständige CLI-Abdeckung ist seit 2026-09-25 als übergreifende
Anforderung akzeptiert; ihre Einordnung in die Ausführungsreihenfolge bleibt
offen. Sie gilt auch für die nachstehenden fachlichen Fähigkeiten.

## Vollständige CLI-Abdeckung aller Lab-Funktionen

Status: `ACCEPTED_NEED`; Zielvertrag im Backlog, keine Aussage über bereits
vollständige Implementierung oder Abnahme.

Alle benutzerseitigen Funktionen und Operationen des SQL Server Labs müssen
über die CLI mit dem zentralen Einstieg `Invoke-SqlServerLab` erreichbar sein.
Das umfasst sowohl die Erstellung als auch die vollständige Verwaltung und
nachträgliche Änderung bestehender Labs. Ein ausschließlich in einer anderen
Oberfläche, einem separaten Cmdlet oder einem Hilfsskript erreichbarer
Produktworkflow erfüllt dieses Ziel noch nicht. Interne Hilfsfunktionen
müssen dafür nicht einzeln öffentlich werden.

Der Scope umfasst insbesondere:

- Lab-, Run- und Instanzinventar, Status, Verbindungen, Readiness und Diagnose;
- Erstellen, Starten, Stoppen, Neustarten, Klonen, Aktualisieren und Entfernen;
- Testdatenbanken nachträglich auswählen, hinzufügen, ändern und entfernen
  sowie Datenbank-, Backup-, Restore-, Import- und Exportoperationen;
- SQL-Konfiguration, Ressourcen, Ports, Netzwerk, Storage und Autostart;
- External Languages, Software und KI-Integration einschließlich External
  Models und ihrer Konfiguration;
- Kataloge, Medien, Images, persistente Speicher, Wartung, Reconcile,
  Wiederaufnahme und Recovery sowie weitere bestehende und künftige
  benutzerseitige Lab-Funktionen.

### Abnahmekriterien

1. Eine vollständige Funktionsmatrix ordnet jede Produktoperation ihrer
   CLI-Navigation, dem öffentlichen Ausführungsvertrag, den Voraussetzungen,
   den Provider-/Versionsgrenzen und dem Abnahmenachweis zu. Fehlende
   CLI-Zugänge bleiben einzeln als offene Arbeit sichtbar.
2. Alle unterstützten Operationen sind über `Invoke-SqlServerLab` auffindbar
   und ausführbar. Für vorhandene Labs sind aktuelle Einstellungen sichtbar
   und unterstützte Änderungen ohne manuelle State-Dateibearbeitung möglich.
3. Dieselben fachlichen Operationen besitzen dokumentierte, parametrisierte
   öffentliche PowerShell-Aufrufe für Skripte und unbeaufsichtigte Abläufe;
   diese benötigen keine interaktive Menübedienung. Die genaue Zuordnung von
   Parametern und Cmdlets wird im Implementierungsslice festgelegt.
4. CLI und andere Oberflächen verwenden denselben geprüften Core. Planung,
   Vorschau beziehungsweise `WhatIf`, Zielbindung, erforderliche Bestätigungen,
   Secret-Behandlung, Idempotenz sowie Cleanup-/Recovery-Verträge bleiben
   erhalten. Ein erforderlicher Neuaufbau wird mit Auswirkungen ausgewiesen,
   nicht als unterbrechungsfreie Änderung dargestellt.
5. Nicht unterstützte Kombinationen liefern vor einer Mutation einen
   verständlichen Grund. CLI-Abdeckung erzeugt keine neue Providerfähigkeit
   und darf vorhandene Schutzprüfungen nicht umgehen.
6. Abnahmen decken Erstellen und nachträgliches Ändern bestehender Labs,
   wiederholten Aufruf, Persistenz nach Neustart sowie Fehler-/Recoverypfade
   ab. Docker, Podman und Hyper-V erhalten getrennte Nachweise für die jeweils
   unterstützten Funktionen. Neue Produktfunktionen werden künftig gemeinsam
   mit CLI-Zugang, Hilfe und passenden Tests abgenommen.

Erster Umsetzungsschritt ist die Bestandsaufnahme mit Abgleich gegen
[CLI-Abnahmematrix](../Quality/CLI_ACCEPTANCE_MATRIX.md), öffentliche Cmdlets,
Konsolenmenüs und weitere Produktoberflächen. Vorhandene CLI-/UI-Pläne werden
wiederverwendet; eine vollständige Lückenanalyse ist mit diesem Eintrag noch
nicht durchgeführt.

Die weitere Behebung von External Languages (Java/Python/R) unter Podman auf
Windows/WSL ist auf Benutzerentscheidung vom 2026-09-25 vorerst zurückgestellt;
diese Kombination bleibt nicht unterstützt. Das schränkt andere unterstützte
Podman-Funktionen nicht ein und widerruft keine getrennte native Linux-Evidence.
Ein künftiger Ausbau für native Linux-Hosts ist ein eigener Implementierungspunkt.
Die [bekannten Grenzen](../Quality/KNOWN_LIMITATIONS.md) bleiben maßgeblich.

## Weitere priorisierte Kandidaten

| Priorität | Fähigkeit | Planungsstatus | Erster sinnvoller Vertical Slice |
|---|---|---|---|
| P0 | Evaluation-Watchdog und Benachrichtigung | `IMPLEMENTED_READ_ONLY` | read-only Prüfung aller registrierten Windows-/SQL-Evaluationsfristen mit lokalem fälligen Ereignis und sanitisierter Ausgabe |
| P0 | Portabler Gesamt-Lab-Export/-Import | `IMPLEMENTED_STATIC_CONTRACT` | einen pfad- und secretfreien Backup-Referenzvertrag mit Integritäts-Evidence an einen bestehenden Container-Ziel-Run binden; Export, Rekonstruktion und Import folgen getrennt |
| P0 | Externe Secret-Store-Anbindung | `IMPLEMENTED_STATIC_CONTRACT` | providerneutrale `SecretRef` über PowerShell SecretManagement auflösen, ohne Wert in State, Plan oder Log zu persistieren |
| P1 | Zentrale Observability und Evidence | `IMPLEMENTED_VALIDATED_REFERENCE` | Aggregierte Server-, Datenbank-, Query-Store- und Wait-Metriken eines gebundenen Runs read-only und sanitisiert erfassen; Docker und Podman sind für SQL-2025 nativ referenziert, Extended Events, Retention, externe Provider und Hyper-V folgen getrennt |
| P1 | Verwaltete Recovery Points | `ACCEPTED_NEED` | applikationskonsistenter Recovery Point eines Hyper-V-SQL-Runs mit Restore-Probe und expliziter Retention |
| P1 | Framework- und State-Upgrade-Lifecycle | `IMPLEMENTED_READ_ONLY` | eine versionierte, reversible Migration eines synthetischen alten Run-State in ein neues Schema |
| P2 | Offline-/Air-Gap-Distributionspaket | `ACCEPTED_NEED` | hash- und lizenzgebundener Export bereits freigegebener Medien, Kataloge und Samples ohne Secrets oder Runtime-State |
| P2 | Erweiterte Kapazitäts-, Reservierungs- und Quotensteuerung | `DECISION_REQUIRED` | read-only Hostbudget für parallele SQL-Runs mit CPU-, RAM-, Storage- und `HyperVHeavy`-Reservierungen |
| P3 | Mehrbenutzer-, Rollen- und Ownership-Modell | `DECISION_REQUIRED` | gemeinsame read-only Inventur mit getrennten Operatoridentitäten und unveränderlichem Audit, noch ohne Remote-Mutation |
| P3 | Stabile Automation-API und IaC-Adapter | `IMPLEMENTED_READ_ONLY` | versionierter lokaler read-only Plan-Endpunkt; Terraform, Ansible, DSC oder Pulumi erst danach als austauschbare Adapter bewerten |
| P1 | Relationaler Mehrdatenbank-Vergleich | `IMPLEMENTED_READ_ONLY_CORE` | `RELATIONAL_CORE/1.0`: verwaltete Containerpaare nur lesend, PK-sortiert und wertfrei vergleichen; die gesonderte Ein-Datenbank-Ausführung in einen neuen eigenen Run ist implementiert, bestehende Ziele und Mehrdatenbanktransfer bleiben `BLOCKED` |

## Relationaler Mehrdatenbank-Vergleich

`Test-SqlServerLabRelationalCoreComparison` implementiert ausschließlich den read-only Vergleichskern. Er nimmt mehrere feste Run-/Instanz-/Datenbankpaare entgegen, akzeptiert weder Connection Strings noch Hosts, SQL-Texte oder Secrets und bindet jede Seite vor der SQL-Verbindung an einen live verwalteten Docker-/Podman-Container und dessen aktuellen RuntimeScope. Zugangsdaten werden nur aus dem lokalen Run-Secret-Store als `SecureString` entnommen und für jede Seite getrennt in einem in-process `SqlCredential` verwendet.

`RELATIONAL_CORE/1.0` lässt nur normale diskbasierte Benutzertabellen mit aktivem, ungefiltertem Primärschlüssel und einer kleinen expliziten Typmenge zu. RLS, System-, Temporal-, FileTable- und externe Tabellen sowie alle nicht zugelassenen Typen blockieren den betreffenden Vergleich fail-closed. Der Reader vergleicht Zeilen in Primärschlüsselreihenfolge streamingbasiert und prüft jeden zugelassenen Feldwert vollständig; ein Hash allein genügt nicht. Findings enthalten nur Codes, Paar-ID und Tabellenordinal, niemals Rohwerte, Objektnamen, Endpunkte oder Credentials. Der Vergleich selbst führt keine Transferaktion aus und erteilt keine Schreibautorität. Der separate [Ein-Datenbank-Executor](../Architecture/PORTABLE_CONTAINER_TRANSFER.md) erstellt ausschließlich einen eigenen SQL-2025-Linux-Ziel-Run mit eigenem Volume. Sein enger Scope ist offline mit 32 Assertions sowie nativ für Docker und Podman getrennt am 2026-09-20 mit jeweils zwölf Assertions und vollständigem Cleanup belegt. Bestehende Ziele, Mehrdatenbank- und Gesamt-Lab-Transfer bleiben offen.

Die Prioritäten ordnen nur die Untersuchung. Sie ändern nicht die kanonische
Ausführungsreihenfolge des Development Execution Plans.

## Evaluation-Watchdog und Benachrichtigung

Der vorhandene Workflow kann Evaluationsmetadaten anzeigen und eine zu kurze
Restlaufzeit beim Aufbau blockieren. `Get-SqlServerLabEvaluationWatch` bewertet
die registrierten Windows- und SQL-Evaluationen getrennt. Für als RUNNING
registrierte Hyper-V-Instanzen projiziert er zusätzlich ausschließlich die
bereits persistierte Windows-Aktivierungsevidenz mit ihrer eigenen Frist.
Für registrierte RUNNING-/STOPPED-Hyper-V-SQL-Runs liest er eine SQL-Gastfrist
nur aus einem separaten schema- und bindungsvalidierten Receipt;
eine Live-VM- oder Gastabfrage findet dafür nicht statt. Der Befehl erzeugt
stabile, sanitisierte Fälligkeitsereignisse und kann neue Ereignisse mit
`-RecordEvents` lokal idempotent deduplizieren. Der Standardaufruf bleibt
vollständig read-only; auch die optionale Ereignisaufzeichnung verändert weder
Images, Lizenzen noch Runs. `Invoke-SqlServerLabEvaluationWatchTrigger` führt
denselben Watch sofort und anschließend in einem explizit begrenzten
foreground-Intervall aus. Er registriert keine Windows-Aufgabe, startet keine
Runtime und führt keinen Netzwerk- oder Gastzugriff aus. SQL-Gast-Capture,
Native-Abnahme und optionale Benachrichtigungskanäle bleiben offen. Der
minimale, teilweise implementierte SQL-Gast-Slice ist im
[eigenen Evidence-Backlog](SQL_GUEST_EVALUATION_EVIDENCE_BACKLOG.md)
festgelegt: Er trennt rungebundenen SQL-Gast-Receipt, Aktualität,
Read-only-Projektion und Native-Evidence von Image- und Windows-Metadaten.

Der Zielvertrag muss mindestens definieren:

- getrennte Fristen für Windows, SQL Server und verwendete Images;
- für SQL-Gäste eine versionsgebundene, an Run/Scope/Instanz/VM/Image und
  SQL-Readiness gebundene Evidence statt einer abgeleiteten Imagefrist;
- konfigurierbare Warnschwellen mit 30 Tagen als Standard;
- idempotente lokale Ausführung und persistierte, geheimnisfreie
  Deduplizierung;
- Zustände `OK`, `WARNING`, `CRITICAL`, `EXPIRED`, `UNKNOWN` und
  `REFRESH_BLOCKED`;
- optionale Benachrichtigungskanäle ohne verpflichtenden Cloud-Dienst;
- Übergabe an den vollständigen Evaluation-Refresh nur als geprüfter Plan;
- keine automatische Aktivierungs-, Lizenz-, Cutover- oder Löschmutation.

## Portabler Gesamt-Lab-Export/-Import

Vorhandene Backup-, Datenbankpaket- und Testumgebungsexporte übertragen nicht
den vollständigen Controller- und Labzustand. Benötigt wird ein eigener
Transportvertrag für den Wechsel auf einen neuen Host oder Controller.

`Get-SqlServerLabPortableLabImportPlan` implementiert den ersten read-only
Preflight für `SqlServerLab.PortableLabPackage/1.1`. Er bindet stabile
`BackupSetId`-Referenzen mit CHECKSUM-, VERIFYONLY-, SHA-256- und
Größen-Evidence an einen bereits bestehenden Docker-/Podman-Ziel-Run. Der Plan
schreibt nichts, akzeptiert keine Secrets und setzt immer
`ExecutionImplemented=false`; weder ein Paketexport noch eine Zielrun-Erzeugung
oder ein Datenbankimport ist damit implementiert oder validiert.

Das portable Paket umfasst ausschließlich explizit ausgewählte und
klassifizierte Bestandteile:

- Labmanifest, Desired State und kompatible Schema-/Modulversion;
- stabile Run-, Instanz-, Storage-, Artifact- und Package-Referenzen;
- katalogisierte Medien- und Image-Locks samt Hashes, jedoch keine pauschale
  Kopie fremder Runtime-Caches;
- freigegebene Backups, Datenbankpakete und portable Exchange-Artefakte;
- sanitisierte Netz-, Ressourcen- und Provideranforderungen;
- Secret-Referenzen und Wiederbindungsanforderungen, niemals Secretwerte;
- Import-Preflight, Konfliktauflösung, Journal, Resume, Rollback und
  Gleichwertigkeitsbericht.

Hostgebundene Pfade, Runtime-IDs, Hyper-V-Switches, Docker-Contexts,
Podman-Machines, Credentials und Lizenzschlüssel müssen am Ziel neu gebunden
oder als Blocker ausgewiesen werden. Ein Archiv allein gilt nicht als
erfolgreicher Import.

## Externe Secret-Store-Anbindung

Die aktuelle lokale DPAPI- und Prozessvariablen-Grenze bleibt gültig.
`Get-LabManifestEnvironmentSecret` löst die bestehende, eng benannte
`SQL_SERVER_LAB_SECRET_*`-Referenz zuerst über die Prozessvariable und danach
optional über PowerShell SecretManagement auf. Der externe Rückgabewert muss
ein `SecureString` sein; fehlende, fehlerhafte oder anders typisierte
Referenzen enden vor einer Mutation fail-closed. Der statische Vertrag belegt
Umgebungsvariablenvorrang, erfolgreiche SecretManagement-Auflösung und den
Gegenbeweis. Credential Manager, konkrete Vaults und Key Vault bleiben
optionale spätere Adapter und dürfen keine Core-Abhängigkeit werden.

Erforderlich sind:

- stabile `SecretRef` ohne Providerdetail im fachlichen Manifest;
- Capability- und Erreichbarkeitsprobe vor der ersten Mutation;
- Secretwerte nur kurzzeitig im Arbeitsspeicher;
- keine Werte oder Fragmente in State, Journal, Evidence, Fehlern oder
  Prozessargumenten;
- Rotation und fehlende Version als sichtbarer Recovery-/Blockerzustand;
- providergetrennte Tests mit synthetischen Secrets.

## Zentrale Observability und Evidence

`Get-SqlServerLabSqlObservabilityEvidence` implementiert einen ersten
versionierten `SqlServerLab.SqlObservabilityEvidence/1.0`-Vertrag. Er bindet
eine direkte Quelle oder einen bestehenden Run an aggregierte Server-,
Datenbank-, Query-Store- und Wait-Metriken. SQL-Texte, Datenbank-, Login- und
Hostnamen sowie Secretwerte werden nicht projiziert oder gespeichert. Der
statische Mock-Vertrag ergänzt zwei getrennte native Referenzläufe vom
2026-09-20: Docker und Podman bestanden jeweils mit einem eigenen SQL-2025-
Linux-Run die öffentliche rungebundene Capture vor und nach Restart,
synthetische Query-Store-Datenbank, persistenten Datenmarker, Privacy-Grenzen
und scopegebundenen Cleanup. Dies ist keine Freigabe für Hyper-V, externe
Provider oder allgemeines Monitoring.

Weiterhin offen bleiben:

- Storage- und Hostressourcenmetriken sowie SQL-Readiness-Receipts;
- ausgewählte Extended Events und SQL-Agent-/Backupzustände;
- providerneutrale Zeit-, Run-, Instanz- und Szenariobindung;
- Datenminimierung, Redaction und Größen-/Aufbewahrungsgrenzen;
- reproduzierbare Exportpakete ohne Abfragetexte, Objekt-, Host- oder
  Benutzernamen, sofern diese nicht ausdrücklich synthetisch freigegeben sind;
- getrennte Evidence-Profile für Diagnose, Regression, Evaluation-Refresh und
  Fault-Szenarien;
- keine allgemeine Monitoring-Plattform ohne SQL-Zweck.

## Verwaltete Recovery Points

Hyper-V-Checkpoints und Exporte sind derzeit enge run-lokale Recovery Points;
automatische Checkpoints bleiben deaktiviert. Es fehlt ein öffentlicher,
providerbewusster Lifecycle mit SQL-Konsistenz und Restore-Nachweis.

`Get-SqlServerLabHyperVRecoveryPointPlan` ist als `IMPLEMENTED_READ_ONLY`
erster Inventarvertrag verfügbar. Er projiziert vorhandene, eindeutig an einen
Hyper-V-Run gebundene Checkpoints ohne VM-Namen oder Hostpfade und blockiert
unklare Bindungen fail-closed. Er ersetzt weder Checkpoint-Erstellung noch
SQL-Quiesce, Retention oder eine Restore-Probe.

Ein Recovery Point benötigt:

- exakte Run-/Instanz-/VM-/Storage- und Parentbindung;
- SQL-Quiesce-, Backup- oder andere dokumentierte Konsistenzmethode;
- `WhatIf`, Journal, Referenzen, Retention und Kapazitätsprüfung;
- nachgewiesenen Restore in ein unabhängiges Ziel;
- Schutz aktiver oder referenzierter Recovery Points vor Cleanup;
- getrennte Providersemantik statt behaupteter Checkpoint-Parität.

## Framework- und State-Upgrade-Lifecycle

`Update-SqlServerLabContainer` beziehungsweise Reconcile aktualisiert eine
Lab-Runtime, aber nicht das Framework selbst. `Get-SqlServerLabRunStateUpgradePlan`
klassifiziert bereits einen einzelnen lokalen Run-State gegen
`SqlServerLab.RunState/1.0`. Neue Run-States erhalten diese Vertragsversion
bereits bei der Erstellung; Planung und Upgrade-Aufruf ergeben `NO_ACTION`
ohne Schreibzugriff. Historische unversionierte States werden nicht automatisch
markiert und bleiben ohne `metadata.syntheticStateFixture=true` blockiert.
Der Executor migriert nur ausdrücklich synthetische Legacy-States; unbekannte
Versionen und unvollständige States bleiben blockiert. Der Plan ist pfad- und
secretfrei sowie vollständig read-only; er führt selbst keine Migration aus.
Ein kontrollierter Vertrag für neue Modulversionen und veränderte lokale Schemas
bleibt erforderlich.

Der Vertrag muss beinhalten:

- Kompatibilitätsmatrix für Modul-, Manifest-, State-, Catalog- und
  Receipt-Versionen;
- read-only Upgrade-Plan vor jeder Änderung;
- gesicherte Ausgangsrevision, atomare Migration, Rollback und Resume. Der
  vorhandene Resume-Slice finalisiert nur ein hashgebundenes `PENDING`-Journal
  nach vollständig beobachtetem atomarem Zielcommit; fehlende Mutation,
  geänderte Source oder unvollständiger Zielstate blockieren fail-closed;
- Weiterverwendung alter Runs oder eine klare `MANUAL_REQUIRED`-/
  `UNSUPPORTED`-Grenze;
- keine automatische Repository-, Modul- oder Abhängigkeitsaktualisierung ohne
  expliziten Operatorauftrag;
- Migrationstests über synthetische historische Fixtures.

## Offline-/Air-Gap-Distributionspaket

Ein Air-Gap-Paket ist kein unkontrollierter Mirror. Es enthält nur rechtlich
und technisch freigegebene, vollständig gehashte Inhalte und eine
maschinenlesbare Herkunfts- und Lizenzprojektion.

Mindestens erforderlich sind:

- Auswahlplan nach SQL-Version, Provider, Szenario und Zielplattform;
- vollständiges Hashmanifest und Signaturprüfung, wo verfügbar;
- katalogisierte SQL-/Windows-Medien, Samples, Tools und Derived-Image-
  Buildinputs nur innerhalb ihrer jeweiligen Distributionsrechte;
- Import in `Lab_Base`/`Lab_Data` mit erneuter Integritätsprüfung;
- Delta-Pakete und fehlende Inhalte ohne stille Netzwerknachladung;
- Ausschluss von Secrets, lokalem Run-State und nicht freigegebenen Caches.

## Erweiterte Kapazitäts-, Reservierungs- und Quotensteuerung

Resource Assessment und der vorhandene Scheduler prüfen einzelne Ressourcen
und serialisieren `HyperVHeavy`. Noch offen ist ein controllerweites Budget-
und Reservierungsmodell.

Vor einer Architekturentscheidung sind zu klären:

- harte und weiche Budgets für CPU, RAM, Storage, Ports und parallele Builds;
- Reservierung, Lease-Ablauf, Fairness und Recovery nach Prozessabbruch;
- Quoten je Benutzer, Projekt oder Szenarioklasse;
- NUMA-, CPU-Affinitäts-, I/O-Latenz- und Storage-Tier-Profile für
  Performance-Labs;
- Verhalten bei gemeinsam genutzten externen Runtimes;
- keine Hostüberbuchung allein aufgrund deklarierter Sollwerte.

## Mehrbenutzer-, Rollen- und Ownership-Modell

Der lokale Einzeloperator bleibt Standard. Ein Mehrbenutzermodus benötigt vor
jeder Umsetzung eine neue Architektur- und Security-Entscheidung.

Zu entscheiden sind:

- Identität, Authentisierung und Rollen für Lesen, Planen, Ausführen,
  Freigeben und Löschen;
- eindeutiges Ownership von Runs, Storage, Images, Secrets und Recovery Points;
- Freigabegrenzen für lizenzierte Medien und mutierende Hostoperationen;
- Konkurrenzkontrolle, Audit, Quoten und Notfallwiederherstellung;
- lokaler beziehungsweise zentraler Controller sowie dessen Hochverfügbarkeit;
- Erhalt der vollständig lokalen Einzelplatznutzung.

## Stabile Automation-API und IaC-Adapter

`Get-SqlServerLabAutomationPlan` implementiert den ersten lokalen
`SqlServerLab.AutomationApiPlan/1.0`-Slice. Er projiziert ausschließlich eine
feste, sanitierte Auswahl bereits öffentlicher Plan-/Action-Grenzen und liefert
immer einen `NOT_EXECUTED`-Resultvertrag. Er liest keinen Lab-State, verbindet
keine Runtime und schreibt nichts. PlanId und PlanKey sind je gültigem Action-
Wert deterministisch. Fehlende oder ungültige Eingaben werden ohne
Wertreflexion als `BLOCKED` ausgewiesen. Der Slice erteilt keine Autorisierung,
ersetzt keine Revalidierung, Locks, Idempotenz- oder Resume-Verträge und führt
keine Terraform-, Ansible-, DSC- oder Pulumi-Adapter ein.

Die öffentliche PowerShell-API bleibt der aktuelle Produktvertrag. Eine
zusätzliche Service- oder IaC-Schnittstelle darf erst nach einem eigenen
versionierten Plan-/Action-/Result-Vertrag entstehen.

Der Zielvertrag muss trennen:

- read-only Planung von autorisierten Mutationen;
- Idempotenzschlüssel, Revision, Locks, Long-Running Operations und Resume;
- Secret- und Hostwertgrenzen;
- Authentisierung, Autorisierung und Audit bei Remotezugriff;
- lokale CLI-/PowerShell-Funktion ohne dauerhaften Service;
- austauschbare Adapter für Terraform, Ansible, DSC oder Pulumi ohne
  Parallelgovernance und ohne Providerlogik im Adapter.

Kubernetes- oder allgemeine Cloud-Orchestrierung bleibt außerhalb dieses
Backlogs und erfordert weiterhin einen konkreten SQL-Bedarf sowie eine eigene
Architekturentscheidung.

## Umsetzungsreihenfolge

1. Für jeden Kandidaten Istgrenzen, konsumierende Verträge und Blocker
   vollständig inventarisieren.
2. `ACCEPTED_NEED`-Themen als getrennte kleine Zielverträge konkretisieren;
   `DECISION_REQUIRED`-Themen zuerst durch eine Architekturentscheidung
   begrenzen.
3. Schema, read-only Plan und sanitisierte Projektion vor mutierenden
   Executoren implementieren.
4. Genau einen synthetischen Vertical Slice mit Recovery und Cleanup je
   Fähigkeit ausführen.
5. Provider- oder Hostparität ausschließlich nach getrennten nativen
   Nachweisen behaupten.

## Definition of Done für diesen Backlog

Dieser Sammelbacklog ist abgearbeitet, wenn für jedes Thema genau einer der
folgenden terminalen Zustände dokumentiert ist:

- als eigener Zielvertrag priorisiert und anschließend implementiert sowie im
  geforderten Scope validiert;
- nach einer dokumentierten Architekturentscheidung bewusst ausgeschlossen;
- durch einen anderen kanonischen Backlog vollständig übernommen und dorthin
  rückverfolgbar verlinkt.

Ein Thema darf nicht allein wegen einer vorhandenen UI, eines Skripts, eines
Dateiexports oder eines statischen Plans als abgeschlossen markiert werden.

## Abhängigkeiten

- [Vollständiger Instanz-Refresh vor Evaluation-Ablauf](FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG.md)
- [Persistente Storage-Wiederverwendung und Lab_Data](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md)
- [Neue SQL-Server-Lab-Anwendungsmöglichkeiten](NEW_SQL_LAB_USE_CASES_BACKLOG.md)
- [Providerneutraler Batch-, Queue- und Resume-Workflow](PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md)
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)

Dieser Backlog autorisiert keine neue öffentliche API, keinen zentralen
Dienst, keine externe Verbindung und keine Mutation. Jede Umsetzung benötigt
einen eigenen begrenzten Vertrag und die dazugehörigen Prüfungen.
