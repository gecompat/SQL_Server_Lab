# Masterplan-Ergänzung: verbindliche Scope-, Versions-, Artefakt- und Recovery-Regeln

| Merkmal | Wert |
|---|---|
| Status | `BINDING_ADDENDUM` |
| Stand | 2026-08-12 |
| Bezieht sich auf | `MASTER_IMPLEMENTATION_PLAN.md` |
| Vorrang | Diese Ergänzung und `SQL_SERVER_CENTRIC_SCOPE_DECISION.md` haben bei widersprüchlichen Formulierungen Vorrang. |

## 1. SQL-Server-zentrierte Architekturgrenze

Der Masterplan ist ausschließlich als Plan für ein **SQL-Server-Lab** zu verstehen.

SQL Server ist stets:

- Hauptzweck des Runs;
- primäre fachliche Zielplattform;
- Bezugspunkt für DataSets, Datenbankartefakte, Workload, Observation und Assertion;
- Grund für jede zusätzlich bereitgestellte Supporting Component.

Supporting Components sind nur zulässig, wenn sie für einen SQL-Zweck erforderlich sind, beispielsweise Domain Controller für Kerberos oder Hadoop für PolyBase.

## 2. Versionsoffener SQL-Server-Vertrag

Formulierungen wie „SQL Server 2019, 2022 und 2025“ bezeichnen den **derzeit
vorgesehenen aktiven Katalog- und Bereitstellungsumfang**. Sie sind nicht als
dauerhafte Ober- oder Untergrenze des Lab-Core zu verstehen. Die eigene
SQL-Lab-Runtime-Abnahme verwendet je Provider ausschließlich SQL Server 2025.
Die reale Windows-/Linux-Kompatibilitätsmatrix 2019/2022/2025 wird in
`SQL_Server_Analyze` und `SQL_Server_Toolbelt` ausgeführt.

Verbindlich gilt:

- Core-Schemas enthalten kein festes Enum einzelner Produktjahre;
- SQL-Versionen werden über einen versionierten Katalog und Version Constraints aufgelöst;
- neue SQL-Server-Versionen können durch Katalogeintrag, Provider-Mapping, Capability Record und Validierung ergänzt werden;
- alte Versionen können über `DEPRECATED`, `RETIRED` oder `BLOCKED` aus dem aktiven Umfang genommen werden;
- historische Vertragsinformationen bleiben erhalten;
- Packages können konkrete Versionen, Major-Versionen oder Capability-basierte Constraints anfordern.

Vorgesehene Versionsstatus:

```text
EXPERIMENTAL
SUPPORTED
DEPRECATED
RETIRED
BLOCKED
```

## 3. Datenbankartefakte und Backups

Das Verbot von Produktionsbackups darf nicht als allgemeines Backupverbot ausgelegt werden.

Zulässig und ausdrücklich vorgesehen sind:

- im Lab erzeugte Backups synthetischer oder sonst zulässiger Labdatenbanken;
- Fortsetzung eines späteren Runs auf Basis eines zuvor erzeugten Lab-Backups;
- öffentliche Demo- und Beispieldatenbanken mit dokumentierter Quelle, Lizenz, Hash und Versionskompatibilität;
- lokal bereitgestellte Entwicklungs-, Test- oder Lab-Backups, sofern sie ausdrücklich als Nicht-Produktionsartefakt klassifiziert werden.

Unzulässig bleiben:

- Produktionsbackups;
- aus Produktivsystemen extrahierte reale Daten;
- unklassifizierte oder unbekannte Artefakte;
- automatische Übernahme lokaler Backups in Repository, GitHub-Inhalte oder Downloadpakete.

Jedes Datenbankartefakt benötigt mindestens Klassifikation, Hash, Größeninformationen, Versions- und Restore-Kompatibilität, Verifikation, Retention sowie Cleanup Policy.

## 4. Ressourcen-Preflight

Vor jeder Mutation wird ein Resource Assessment erstellt. Es prüft mindestens:

- physische und logische CPU-Kapazität;
- physischen und verfügbaren RAM;
- freien Speicher je Storage-Rolle;
- Peakbedarf für Images, VHDX, Container-Layer, Data, Log, TempDB, Backups, Download, Entpacken und Restore;
- Provider- und Virtualisierungs-Overhead;
- Ports, Netzwerke, Medien, sichere Pfade und Rechte;
- Hostreserve während Aufbau, Betrieb und Cleanup.

Ergebnisstatus:

```text
RESOURCE_OK
RESOURCE_WARNING
RESOURCE_INSUFFICIENT_OVERRIDABLE
RESOURCE_HARD_BLOCK
RESOURCE_UNKNOWN
```

## 5. Bewusste Ressourcenübersteuerung

Eine vorhergesagte Unterversorgung darf die Installation nicht automatisch verhindern.

Ein Run mit `RESOURCE_INSUFFICIENT_OVERRIDABLE` darf nach expliziter Bestätigung gestartet werden. Der Override:

- bleibt im lokalen Run State sichtbar;
- verändert weder Messwerte noch Status;
- nennt die betroffenen Ressourcendimensionen und erwarteten Fehlerfolgen;
- setzt keine Timeouts, Failure Policies oder Cleanup-Regeln außer Kraft;
- darf absolute Package- und Provider-Safety-Limits nicht umgehen.

Nicht übersteuerbar sind insbesondere unsichere Pfade, fehlende Providerfähigkeit, fehlende Rechte, blockierte SQL-Versionen, unzulässige Datenklassifikation, fehlende Secrets oder Lizenzen, fremde Ressourcen und ein fehlender Cleanup Plan.

## 6. Cleanup und Recovery vor jeder Mutation

Vor `Provision` muss ein vollständiger, maschinenlesbarer Cleanup Plan existieren.

Verbindliche Regeln:

- lokaler Run State wird vor der ersten Mutation angelegt;
- jede Mutation wird vor Ausführung registriert;
- tatsächliche Provider-IDs werden unmittelbar nach Erzeugung gespeichert;
- Cleanup verwendet Run ID, Owner Marker und tatsächliche IDs, nicht nur Namen;
- Fehler starten standardmäßig automatische Compensation in umgekehrter Abhängigkeitsreihenfolge;
- unvollständiges Cleanup ergibt `RECOVERY_REQUIRED`;
- Cleanup ist idempotent und wiederaufnehmbar;
- öffentliche Commands umfassen mindestens `ResumeCleanup`, `RecoverRun` und `DestroyRun`.

Ein absoluter Ausschluss verwaister Ressourcen ist bei Hostausfall oder externem Providerverlust technisch nicht garantierbar. Der State-, Marker-, ID- und Recovery-Vertrag muss jedoch einen deterministischen automatischen Aufräumpfad bereitstellen und offene Reste sichtbar halten.

## 7. Priorisierte Roadmap

### Phase A – SQL-Server-Core

- Package-, Purpose- und Schemafamilie;
- SQL Version Catalog;
- Docker-, Podman- und Hyper-V-Provider;
- katalogbasierte Windows-/Linux-Bereitstellung für SQL Server 2019, 2022 und
  2025 bei SQL Server 2025 als Core-Runtime-Referenz;
- Resource Assessment und bewusster Overcommit;
- State, Secret, Binding, Cleanup und Recovery;
- Quick Environment.

### Phase B – SQL-Daten- und Projektintegration

- DataSet- und Database-Artifact-Vertrag;
- Lab-erzeugte Backups und Folgeruns;
- mindestens eine öffentliche Demo-Datenbank;
- `SQL_PerformanceSchulung`-Package;
- `SQL_Server_Analyze`-Package;
- `SQL_Server_Toolbelt`-Package;
- Workloads, Probes und Assertions;
- SQL-bezogene Fault Injection.

### Phase C – SQL-Infrastrukturkonstellationen

- Domain Controller und DNS;
- mehrere SQL-Server-Knoten;
- Windows Authentication und Kerberos;
- WSFC, AG und FCI;
- getrennte Data-/Log-/TempDB-Storage-Rollen;
- Netzwerk- und I/O-Simulation.

### Phase D – SQL-Integrationskonstellationen

Nur bei konkretem SQL-Bedarf:

- PolyBase mit Hadoop;
- REST-/HTTP-Datenquelle oder Testclient;
- ETL-, File-, Object-Storage- oder Messaging-Komponenten;
- zusätzliche Datenplattformen als SQL-Quelle, Ziel oder Vergleichssystem.

## 8. Kernprovider

Hyper-V, Docker und Podman sind verbindliche Kernprovider. Keiner davon darf zu einer bloßen späteren Option herabgestuft werden.

Die Provider erfüllen denselben übergeordneten Vertrag:

- `DetectCapabilities`;
- `AssessResources`;
- read-only `Plan`;
- `Provision`;
- tatsächliche Ressourcen-IDs;
- Health und SQL Readiness;
- Runtime Bindings;
- `Status`, `Stop`, `Start`, `Reset`, `Down` und `Destroy`, soweit fachlich unterstützt;
- `ResumeCleanup`;
- scope-gebundener Cleanup.

Providerunterschiede werden über Capabilities dargestellt und nicht durch falsche Gleichwertigkeitsbehauptungen verdeckt.

## 9. Abnahmekriterien

- SQL Server ist in allen öffentlichen Einstiegsdokumenten eindeutig Hauptzweck.
- Jedes ausführbare Package besitzt `SqlPurpose`.
- SQL-Versionen sind katalog- und constraintbasiert statt dauerhaft fest codiert.
- Der aktuelle Bereitstellungskatalog umfasst SQL Server 2019, 2022 und 2025;
  der SQL-Lab-Core wird je Provider nur mit SQL Server 2025 abgenommen.
- `SQL_Server_Analyze` und `SQL_Server_Toolbelt` führen die reale
  Windows-/Linux-Entwicklungs- und Abnahmematrix 2019/2022/2025.
- `SQL_PerformanceSchulung` verwendet standardmäßig die aktuelle Linux-
  Umgebung und fordert Abweichungen nur szenariobezogen an.
- Neue Versionen und das kontrollierte Ausgrenzen alter Versionen erfordern keinen Core-Neuentwurf.
- Lab-Backups und öffentliche Demo-Datenbanken sind zulässige, verifizierte Artefakte.
- Produktions- und unklassifizierte Daten bleiben blockiert.
- CPU, RAM, Storage und Provider-Overhead werden vor Mutation bewertet.
- Ressourcenunterversorgung kann bewusst übersteuert werden.
- Safety-, Scope- und Datenklassifikationsblocker bleiben nicht übersteuerbar.
- Vor jeder Mutation existiert ein Cleanup Plan.
- Fehlgeschlagene Installationen lösen automatisches und wiederaufnehmbares Cleanup aus.
- Supporting Components sind an einen SQL-Zweck gebunden.
- Hyper-V, Docker und Podman stehen gleichrangig im Zielvertrag.
- Es entsteht keine allgemeine Labplattform außerhalb des SQL-Server-Zwecks.
