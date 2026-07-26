# Migrationsinventar und Ablöseentscheidungen

| Merkmal | Wert |
|---|---|
| Status | `PLANNED_REVIEW_REQUIRED` |
| Stand | 2026-07-26 |
| Quellrepositories | `gecompat/SQL_Server_Analyze`, `gecompat/SQL_PerformanceSchulung` |
| Zielrepository | `gecompat/SQL_Server_Lab` |
| Grundsatz | keine Entfernung aus Quellrepositories vor funktionaler Abnahme und Compatibility-Pfad |

## 1. Ziel

Dieses Dokument klassifiziert die vorhandenen Lab- und Infrastrukturanteile und legt fest, welche Verantwortung künftig in welchem Repository liegt.

Es ist zunächst ein **Funktionsinventar**, keine dateiweiser Kopierauftrag. Vor jeder konkreten Migration wird der aktuelle Quellstand erneut geprüft.

## 2. Klassifikationen

| Status | Bedeutung |
|---|---|
| `MIGRATE_CORE` | generische Funktion in den Lab Core übernehmen |
| `MIGRATE_PROVIDER` | providerbezogene Funktion in Hyper-V, Docker oder Podman übernehmen |
| `REIMPLEMENT_CONTRACT_FIRST` | Funktion fachlich übernehmen, aber erst nach neuem Contract neu implementieren |
| `KEEP_PROJECT_PACKAGE` | bleibt fachlicher Inhalt des Quellprojekts und wird über Package eingebunden |
| `WRAP_TEMPORARILY` | vorhandener Einstiegspunkt delegiert während der Übergangsphase an das neue Lab |
| `REFERENCE_ONLY` | nur als Architektur- oder Testreferenz verwenden |
| `RETIRE_AFTER_ACCEPTANCE` | erst nach vollständiger Ersatzabnahme entfernen |
| `DO_NOT_MIGRATE` | nicht zum Zielbild passend oder unsicher |

## 3. `SQL_Server_Analyze/QuickStart`

### 3.1 `QuickStart/Docker`

Quelle:

- <https://github.com/gecompat/SQL_Server_Analyze/tree/main/QuickStart/Docker>

Bestehende Stärken:

- einfacher Menüeinstieg;
- direkte Aktionen für Start, Status, Stop und Remove;
- Auswahl von SQL Server 2019, 2022 und 2025;
- Ressourcenprofile;
- Storage-Layouts;
- Portprüfung;
- Scope-Marker;
- Docker-Labels;
- sequenzieller Start;
- Health plus SQL-Erreichbarkeit;
- Frameworkinstallation;
- Verbindungsinformationen;
- Linux-native Slow-I/O-Option;
- klare Docker-Desktop-Grenzen.

Entscheidungen:

| Funktionsgruppe | Zielstatus | Ziel |
|---|---|---|
| Menüführung | `MIGRATE_CORE` | `QUICK`-Modus |
| SQL-Versionenauswahl | `MIGRATE_CORE` | `SqlPurpose` und Quick Request |
| Ressourcenprofile | `REIMPLEMENT_CONTRACT_FIRST` | Resource Profile Contract |
| Portprüfung | `MIGRATE_PROVIDER` | Docker-/Podman-Preflight |
| Scope-Marker und Labels | `MIGRATE_CORE` plus `MIGRATE_PROVIDER` | Ownership- und State-Vertrag |
| Storage-Layouts | `REIMPLEMENT_CONTRACT_FIRST` | Storage Claims und lokale Bindings |
| Docker Compose | `MIGRATE_PROVIDER` | Docker Provider |
| Docker-Desktop-Volume-Modell | `REFERENCE_ONLY` bis Provider-Spike | Docker Capability Mapping |
| Linux Bind Mounts | `MIGRATE_PROVIDER` | Docker Provider |
| Slow-I/O | `REIMPLEMENT_CONTRACT_FIRST` | Fault Type und Linux Capability |
| Frameworkinstallation | `KEEP_PROJECT_PACKAGE` | Analyze Deployment Unit |
| Connection Summary | `MIGRATE_CORE` | sanitisierte Binding-Darstellung |
| Setup-/Uninstall-Einstieg | `WRAP_TEMPORARILY` | delegiert an Lab CLI |

Nicht unverändert übernehmen:

- `.env` als allgemeiner Secretvertrag;
- Docker-spezifische Logik im fachlichen Quick Package;
- eigenes paralleles State-Modell;
- hart verdrahtete Frameworkdatenbank außerhalb des Analyze-Package-Vertrags.

### 3.2 `QuickStart/HyperV`

Quelle:

- <https://github.com/gecompat/SQL_Server_Analyze/tree/main/QuickStart/HyperV>

Bestehende Ideen:

- Windows- und Linux-Gäste;
- Differencing Disks;
- getrennte Data-/Log-Disks;
- Windows Authentication und vollständiger SQL Agent;
- Netzwerkprofile;
- I/O-Profile;
- gemischte Topologien;
- Ressourcenprofile;
- Scope-Marker und Remove-Vertrag.

Entscheidungen:

| Funktionsgruppe | Zielstatus | Ziel |
|---|---|---|
| Hyper-V-Betriebsmodi | `REIMPLEMENT_CONTRACT_FIRST` | Hyper-V Provider und SQL Environment Blueprint |
| Differencing Disks | `MIGRATE_PROVIDER` | Hyper-V Image/Lifecycle |
| Windows-/Linux-Guestrollen | `REIMPLEMENT_CONTRACT_FIRST` | Component Types |
| Data-/Log-/TempDB-VHDX | `MIGRATE_PROVIDER` | Storage Claims |
| Netzwerkprofile | `REIMPLEMENT_CONTRACT_FIRST` | Fault/Network Types |
| I/O-Profile | `REIMPLEMENT_CONTRACT_FIRST` | Fault/Storage Types |
| feste IP-Beispiele | `REFERENCE_ONLY` | keine versionierten realen Bindings |
| Domain/AG/Linked-Server-Ideen | `KEEP_PROJECT_PACKAGE` beziehungsweise spätere SQL-Packages | SQL Scenario Catalog |
| Frameworkinstallation | `KEEP_PROJECT_PACKAGE` | Analyze Package |
| Setup-/Uninstall-Einstieg | `WRAP_TEMPORARILY` | Lab CLI |

Der bestehende Stand wird vor Übernahme technisch verifiziert. Planungsdokumentation ist kein Runtime-Nachweis.

## 4. `SQL_Server_Analyze/Lab/QuickTest`

Quelle:

- <https://github.com/gecompat/SQL_Server_Analyze/tree/main/Lab/QuickTest>

Dieser Bereich enthält die stärkeren Lifecycle-, State-, Secret-, Ownership- und Evidence-Verträge.

### 4.1 Zu übernehmende Core-Verträge

| Vertrag | Zielstatus |
|---|---|
| read-only Preflight | `MIGRATE_CORE` |
| strukturierte Reason Codes | `MIGRATE_CORE` |
| Install startet Versionen sequenziell | `MIGRATE_CORE` |
| Health plus SQL Query plus Major-Version-Prüfung | `MIGRATE_CORE` und Provider |
| Run-ID | `MIGRATE_CORE` |
| Owner Marker | `MIGRATE_CORE` |
| tatsächliche Container-/Netzwerk-IDs | `MIGRATE_CORE` und Provider |
| State vor erster Mutation | `MIGRATE_CORE` |
| Zustände `READY`, `STOPPED`, `DOWN` | `MIGRATE_CORE` |
| Stop/Start ohne Identitätswechsel | `MIGRATE_CORE` |
| Reset nur für temporäre Scopes | `MIGRATE_CORE` |
| Down versus Destroy | `MIGRATE_CORE` |
| Frameworkupdate ohne Lifecycle-Mutation | `KEEP_PROJECT_PACKAGE` plus Core-Grenze |
| Generated Secret lokal und ignoriert | `MIGRATE_CORE` |
| keine user-supplied Secretpersistenz | `MIGRATE_CORE` |
| `-WhatIf` und Confirmation | `MIGRATE_CORE` |
| Recoverystatus bei Teilfehler | `MIGRATE_CORE` |

### 4.2 Provideranteile

| Bereich | Zielstatus |
|---|---|
| Compose Core | `MIGRATE_PROVIDER` |
| Docker Override | `MIGRATE_PROVIDER` |
| Podman Override | `MIGRATE_PROVIDER` |
| Container Labels | `MIGRATE_PROVIDER` |
| Runtimeinspect und Full IDs | `MIGRATE_PROVIDER` |
| Container Health | `MIGRATE_PROVIDER` |
| Volume-/Pfadlogik | `REIMPLEMENT_CONTRACT_FIRST` |

### 4.3 Fachliche Analyze-Anteile

| Bereich | Zielstatus |
|---|---|
| Framework Builder/Installer | `KEEP_PROJECT_PACKAGE` |
| `LabAnalyze`-Datenbank | `KEEP_PROJECT_PACKAGE`, künftig als Binding |
| Frameworkvalidierung | `KEEP_PROJECT_PACKAGE` |
| Analyzer- und Finding-Evidence | `KEEP_PROJECT_PACKAGE` |
| Analyze-spezifische Scenario Catalogs | `KEEP_PROJECT_PACKAGE` |

## 5. `SQL_Server_Analyze/Lab` jenseits `QuickTest`

Quelle:

- <https://github.com/gecompat/SQL_Server_Analyze/tree/main/Lab>

Vorhandene relevante Konzepte:

- Contracts;
- Topologies;
- Scenario Manifests;
- Evidence Schema;
- Capability Mapping;
- Arrange/Act/Observe/Assert/Cleanup;
- Wave- und Runtime-Validierungen.

Entscheidung:

- generische Contracts werden mit dem neuen Lab Contract verglichen;
- SQL-Analyze-spezifische Assertions bleiben im Analyze Package;
- Provider-, State- und Fault-Logik wird in `SQL_Server_Lab` konsolidiert;
- bestehende Scenario IDs werden nach Möglichkeit erhalten;
- kein pauschales Kopieren aller historischen Labdateien.

## 6. `SQL_PerformanceSchulung/Infrastructure`

Quelle:

- <https://github.com/gecompat/SQL_PerformanceSchulung/tree/main/Infrastructure>

Der Bereich ist derzeit als Infrastrukturzielstruktur dokumentiert und enthält geplante Docker-, Podman-, Hyper-V- und Shared-Anteile.

Entscheidung:

| Bereich | Zielstatus |
|---|---|
| generische Providerlogik | `DO_NOT_MIGRATE` als zweite Implementierung; künftig Lab Provider |
| SQL-Schulungs-Environment-Referenzen | `KEEP_PROJECT_PACKAGE` |
| Quick-Environment-Anleitung | `KEEP_PROJECT_PACKAGE` als Consumer-Doku |
| Ressourcen- und I/O-Anforderungen je Demo | `KEEP_PROJECT_PACKAGE` |
| Providerprofile | `REIMPLEMENT_CONTRACT_FIRST` im Lab |
| Compatibility Wrapper | `WRAP_TEMPORARILY` |

## 7. `SQL_PerformanceSchulung/Demos`

Quelle:

- <https://github.com/gecompat/SQL_PerformanceSchulung/tree/main/Demos>

Der fachliche Demo-Vertrag bleibt im Schulungsrepository.

### 7.1 Bleibt im Schulungsrepository

- Demo-ID und Lernziel;
- Preflight;
- Setup;
- Baseline;
- Demonstration;
- Observation;
- Mitigation;
- Comparison;
- Cleanup;
- synthetische Datenmodelle;
- Multi-Session-Steuerung;
- erwartete Resultate und Invarianten;
- Sicherheitsstufe Grün/Gelb/Rot;
- Quellen und didaktische Dokumentation.

### 7.2 Wird als Package-Schnittstelle ergänzt

- `SqlPurpose`;
- Environment Reference;
- Required Provider Capabilities;
- Resource Profile;
- Fault Profile;
- DataSet Definition;
- Workflow Mapping;
- Runtime Binding Requirements;
- Evidence und Assertion Mapping.

## 8. Privacy-, Sprach- und Lizenzregeln

Aus den Quellrepositories übernommen und für das Lab angepasst:

- keine realen Personen-, Firmen-, Kunden-, Organisations- oder Umgebungsdaten in Repositoryartefakten;
- Runtimeausgaben und lokale States getrennt von exportierbaren Summaries;
- ausschließlich synthetische Beispiele;
- Secretwerte nie im Repository;
- deutsche Projektdokumentation;
- etablierte englische Fachbegriffe bleiben erhalten;
- englische technische Codes und Feldnamen;
- englische Lizenz-Masterfassung;
- öffentliche Attribution `gecompat - Gerhard Pisch` bleibt erhalten.

## 9. Übergangsstrategie

### Phase 1 – keine Ablösung

- `SQL_Server_Lab` Contracts und Providerbasis aufbauen;
- Quellfunktionen unverändert als Referenz behalten;
- keine Quellordner löschen.

### Phase 2 – Pilot-Delegation

- ein Docker Quick Environment;
- ein Podman Quick Environment;
- ein Hyper-V Quick Environment;
- Analyze Package;
- Performance Package;
- Wrapper in Quellrepositories.

### Phase 3 – Funktionsparität

Für jede Quellfunktion wird nachgewiesen:

- neuer Zielpfad;
- Contract;
- Providerabdeckung;
- Tests;
- Dokumentation;
- Safety-/Privacy-Parität;
- Cleanup-Parität.

### Phase 4 – Deprecation

- alte Einstiegspunkte zeigen klare Migrationshinweise;
- Wrapper bleiben für einen definierten Übergangszeitraum;
- neue Features werden nur im neuen Lab Core entwickelt.

### Phase 5 – Entfernung

Erst nach:

- Abnahme aller benötigten Funktionen;
- aktualisierten Consumer-Dokumenten;
- erfolgreich getesteten Wrappern;
- Prüfung offener Branches;
- Bestätigung, dass kein benötigtes Artefakt nur im Altpfad existiert.

## 10. Dateiweises Inventar

Vor der tatsächlichen Migration wird pro Quellrepository ein maschinenlesbares Inventar erzeugt mit:

- Source Path;
- SHA-256;
- Funktion;
- Dependencies;
- Privacy Classification;
- Migration Status;
- Target Package/Provider/Core Path;
- Replacement Contract;
- Validation Evidence;
- Retirement Status.

Dieses Inventar darf keine lokalen Runtimewerte enthalten.

## 11. Konfliktregeln

Bei abweichenden bestehenden Implementierungen gilt:

1. Safety- und Ownership-Vertrag von `Lab/QuickTest` hat Vorrang vor einfacherer QuickStart-Löschlogik.
2. verständliche Benutzerführung aus `QuickStart` wird als Oberfläche beibehalten.
3. fachliche Demo- und Analyzerlogik verbleibt im Quellprojekt.
4. Docker und Podman werden getrennt validiert.
5. Hyper-V-Planung wird nicht als implementiert behandelt, bevor Native Tests vorliegen.
6. `SqlPurpose` und SQL-zentrierter Scope haben Vorrang vor allgemeinen Erweiterungsformulierungen.

## 12. Abnahmekriterien

- keine generische Labfunktion wird in drei Repositories parallel weiterentwickelt;
- Quellprojekte behalten fachliche SQL-Inhalte;
- Lab Core besitzt Provider, State, Secret, Binding, Workflow und Cleanup;
- Docker, Podman und Hyper-V sind gleichrangige Kernprovider;
- Analyze- und Performance-Package verwenden denselben Contract;
- alte Pfade werden erst nach Paritätsnachweis entfernt;
- jede Migration besitzt Source, Target und Validation Evidence;
- keine reale Umgebung oder Secretinformation wird übernommen.
