# Neue SQL-Server-Lab-Anwendungsmöglichkeiten – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG_EXPLORATION` |
| Stand | 2026-08-30 |
| Zweck | neue fachliche Einsatzmöglichkeiten des Labs bewerten und priorisieren |

## Einordnung

Dieser Eintrag untersucht neue **Anwendungsmöglichkeiten** des SQL Server Labs.
Er ergänzt technische Provider-, Storage- und Lifecycle-Backlogs, ersetzt sie
aber nicht. Ein Anwendungsszenario beantwortet eine konkrete Benutzerfrage und
liefert dafür eine reproduzierbare SQL-Umgebung, Workload, Beobachtung,
Assertion und Cleanup. Zusätzliche Komponenten sind nur zulässig, wenn sie
diesem SQL-Zweck dienen.

Bereits eigenständig erfasst und deshalb hier nicht dupliziert sind:

- Windows-Sprache, Region, Tastaturlayout und Zeitzone;
- automatische Windows-Aktivierung in geeigneten Slot-Szenarien;
- PolyBase beziehungsweise SQL-Dateizugriff mit S3-kompatiblem Object Store;
- SQL Server 2025 Vector, Embeddings, lokales ONNX, Ollama und optionale
  Cloud-Endpunkte;
- Remote-Hyper-V-Steuerung sowie der priorisierte `Lab_Data`-Bugfix.

Die nachfolgenden Kandidaten sind geplante Lab-Produkte und kein Nachweis für
bereits implementierte Funktionen.

## Priorisierungskriterien

Ein Kandidat erhält eine hohe Priorität, wenn er:

1. eine häufige SQL-Server-Entscheidung oder einen realistischen Betriebsfall
   reproduzierbar unterstützt;
2. vorhandene Version-, Provider-, Backup-, Workload-, State- und
   Cleanup-Verträge wiederverwenden kann;
3. mit synthetischen oder ausdrücklich freigegebenen Daten auskommt;
4. eine maschinenprüfbare SQL-Postcondition besitzt;
5. nicht von einem einzelnen kostenpflichtigen Cloud-Dienst abhängt;
6. einen kleinen Vertical Slice erlaubt und später kontrolliert ausgebaut
   werden kann.

## Empfohlene neue Anwendungsszenarien

| Priorität | Szenario | Konkreter Nutzen | Erste sinnvolle Topologie | Provider-Eignung |
|---|---|---|---|---|
| P1 | Upgrade- und Regressionslab | Prüft vor einem Versionswechsel, ob Datenbank, Anwendung und Abfragepläne unter SQL Server 2022 oder 2025 korrekt und performant bleiben | Quellinstanz 2019/2022, Zielinstanz 2022/2025, synthetische Datenbank, reproduzierbare Workload, Query-Store-Vergleich | Side-by-side zuerst Docker und Podman; Windows-/In-place-Varianten später unter Hyper-V |
| P1 | Backup-, Restore- und Point-in-Time-Recovery-Übung | Trainiert und validiert Full-, Differential- und Log-Backupketten, RPO/RTO sowie Wiederherstellung nach Bedienfehler oder Ausfall | eine SQL-Instanz, begrenzte Transaktionsfolge, lokales Backupziel; später S3-Ziel und getrennte Restore-Instanz | Docker, Podman und Hyper-V getrennt |
| P1 | Applikations- und Treiberkompatibilitätsmatrix | Beantwortet, ob eine Anwendung mit .NET, JDBC, ODBC oder Python nach SQL-, Treiber-, TLS- oder Providerwechsel unverändert funktioniert | SQL-Instanz plus kleiner katalogisierter Testclient mit Pooling-, Transaktions-, Timeout- und Retry-Probes | Docker/Podman für SQL und Client zuerst; Hyper-V für Windows- und Integrated-Security-Fälle |
| P1 | Cross-Platform-Paritätslab | Zeigt nachvollziehbar, welche Datenbank- und Workloadverträge unter SQL Server auf Linux und Windows gleich sind und wo echte Capability-Grenzen liegen | dieselbe synthetische Datenbank und Workload auf Container-Linux und Hyper-V/Windows | Docker, Podman und Hyper-V als getrennte Evidence-Lanes |
| P1 | Schema-Deployment- und CI-Lab | Prüft DACPAC- oder Migrationstool-Deployments, Wiederholbarkeit, Drift, Datenmigration und fehlgeschlagene Releases in wegwerfbaren Umgebungen | SQL-Versionen 2019/2022/2025 plus ein katalogisierter Deployment-Client und kleine Versionsfolge | Docker und Podman zuerst; Hyper-V für Windows-spezifische Toolchains |
| P2 | Security-, Identity- und Verschlüsselungslab | Macht Windows Authentication, Kerberos/SPN, TLS, TDE, Backupverschlüsselung, Always Encrypted, Rollen und Negativtests reproduzierbar | SQL Server plus Domain Controller/DNS und Testclient; kleinere TLS-/Datenbankrollen-Lane ohne Domain | Hyper-V/Windows zuerst für AD/Kerberos; providerneutrale Teilmengen zusätzlich unter Docker/Podman |
| P2 | HA-/DR- und Failoverlab | Übt geplanten und ungeplanten Failover, Listener, Readable Secondary, Backuppräferenz und Recovery unter realen Netzwerkfehlern | zwei SQL-Knoten, optional DC/DNS/Witness und Network-Fault-Controller | Hyper-V/Windows als erste vollständige AG-Lane; Linux-AG, Log Shipping und Replication getrennt |
| P2 | CDC- und Event-Integrationslab | Prüft, wie SQL-Änderungen zuverlässig, geordnet und wiederaufnehmbar an nachgelagerte Systeme gelangen | SQL mit CDC plus lokaler Consumer; später katalogisierter Kafka-kompatibler Broker oder SQL-2025-Change-Event-Streaming zu Azure Event Hubs | lokale CDC-Lane unter Docker/Podman; Hyper-V für Windows-Fälle; Cloud-Lane ausschließlich opt-in |
| P2 | Betriebsautomatisierungs- und Recovery-Game-Day | Erzeugt kontrollierte Fehler bei SQL Agent, Backup, Storage, Netzwerk oder Dienstrestart und prüft Diagnose, Alarmierung, Repair und Cleanup | SQL-Instanz, SQL-Agent-Jobs, Fault Target, Observability-Probes und definierte Recovery-Schritte | providerneutraler Vertrag, native Evidence je Provider |
| P2 | Konsolidierungs- und Noisy-Neighbor-Lab | Untersucht Ressourcenisolation, `max server memory`, Resource Governor, TempDB, I/O und konkurrierende Workloads | mehrere Datenbanken oder Instanzen, kontrollierte Workloads und CPU-/RAM-/I/O-Grenzen | Docker und Podman für günstige Matrix; Hyper-V für hostnahe Windows-Vergleiche |
| P3 | Data-Governance- und Audit-Lab | Demonstriert Temporal Tables, Ledger, Row-Level Security, Dynamic Data Masking, Audit und kontrollierte Schlüsselrotation | eine SQL-Instanz, synthetische Rollen und manipulationsprüfbare Ereignisfolge | je nach Feature-Capability unter allen drei Providern |
| P3 | SQL-2025-JSON-, REST- und Hybrid-Search-Lab | Erprobt nativen JSON-Datentyp, JSON-Index, Regex/Fuzzy-Funktionen, externe REST-Aufrufe und optional die Kombination relationaler, JSON- und Vector-Suche | SQL Server 2025 plus lokaler HTTPS-Mock-Service; Vector-Lane referenziert den bestehenden Vector-Backlog | SQL-Kern unter Docker/Podman/Hyper-V; Preview-Funktionen immer getrennt ausgewiesen |
| P3 | Linked-Server-, Collation- und Distributed-Transaction-Lab | Reproduziert Cross-Instance-Abfragen, Collation-Konflikte, Delegation und Transaktionsgrenzen, die in Einzelinstanz-Labs nicht sichtbar werden | zwei SQL-Instanzen und ein Testclient; optional Domain Controller und MSDTC | Container für einfache Linked-Server-Fälle; Hyper-V/Windows für Kerberos und MSDTC |

## Empfohlene erste drei Vertical Slices

### 1. Upgrade- und Regressionslab

Dieses Szenario besitzt den höchsten unmittelbaren Nutzen und verwendet bereits
vorhandene SQL-Versionen, Restore, Query Store, Workloads und Provider. Der
erste Slice soll:

1. dieselbe synthetische Datenbank unter einer Quell- und Zielversion starten;
2. funktionale Vorher-/Nachher-Assertions ausführen;
3. die Datenbank zunächst mit unverändertem Compatibility Level übernehmen;
4. eine Query-Store-Baseline erfassen;
5. erst danach das Ziel-Compatibility-Level aktivieren und Regressionen
   vergleichen;
6. Ergebnis, Abweichungen und Cleanup maschinenlesbar berichten.

Ein In-place-Upgrade ist eine spätere, Windows-/Hyper-V-spezifische Lane und
wird nicht mit dem providerneutralen Side-by-side-Slice vermischt.

### 2. Backup-, Restore- und Point-in-Time-Recovery-Übung

Der erste Slice soll eine kleine Full-/Log-Backupkette erzeugen, eine
synthetische Fehlmutation durchführen und auf einen eindeutig markierten
Zeitpunkt davor wiederherstellen. Erwartete Zeilenstände, `DBCC CHECKDB`,
Backupmetadaten, gemessene Recovery-Dauer und Cleanup werden geprüft. Erst
danach folgen Differential-Backups, verschlüsselte Backups, Medienfehler,
S3-Ziele und Restore auf eine zweite Instanz.

### 3. Applikations- und Treiberkompatibilitätsmatrix

Der erste Slice verwendet einen kleinen, katalogisierten .NET-Testclient gegen
SQL Server 2022 und 2025. Er prüft Login, TLS, parametrisierte Queries,
Transaktion, Connection Pooling, kontrollierten Verbindungsabbruch, Retry und
Commit-Eindeutigkeit. JDBC, ODBC und Python erweitern denselben Clientvertrag,
erhalten aber jeweils eigene Runtime-Evidence.

## Gemeinsamer Szenariovertrag

Jedes zur Umsetzung ausgewählte Szenario benötigt mindestens:

- eine konkrete Benutzerfrage und eine dokumentierte Aussagegrenze;
- unterstützte SQL-Versionen, Editions- und Provider-Capabilities;
- eine kleine, synthetische oder lizenzklar freigegebene Datenbasis;
- deterministische Arrange-, Act-, Observe- und Assert-Schritte;
- getrennte positive und negative Tests;
- Resource Assessment, State und Cleanup vor der ersten Mutation;
- Restart-, Resume- und Repair-Verhalten, sofern Ressourcen persistent sind;
- sanitisierte Evidence ohne Secrets, reale Hostdaten oder produktive Inhalte;
- getrennte reale Nachweise für Docker, Podman und Hyper-V, wenn diese Provider
  als unterstützt ausgewiesen werden.

## Abhängigkeiten und Reihenfolge

- Die ersten P1-Slices können auf dem bestehenden Einzelinstanz-, Versions-,
  Restore-, Query-Store-, Adapter- und Batch-Core aufbauen.
- Security/Identity und vollständige HA/DR benötigen typisierte Domain-, DNS-,
  Zertifikats- und Mehrknotenverträge.
- Event-Integration benötigt eine klare Wahl zwischen lokaler CDC-Pipeline und
  dem cloudgebundenen SQL-2025-Change-Event-Streaming. Es gibt keinen stillen
  Cloud-Fallback.
- JSON-Index, Fuzzy Matching, Change Event Streaming und einzelne Vector-
  Funktionen von SQL Server 2025 bleiben bei Preview-Status getrennte,
  ausdrücklich aktivierte Capabilities.
- Ein Supporting Component wird erst katalogisiert, wenn Version, Bezugsquelle,
  Digest, Lizenz, Security, Ressourcenbedarf, Lifecycle und Exit-Pfad geprüft
  sind.

## Nicht Ziel dieses Backlogs

- ein allgemeines Active-Directory-, Kafka-, Hadoop-, REST- oder
  Observability-Lab ohne SQL-Server-Zweck;
- Produktionsmigrationen oder der Import unbekannter beziehungsweise
  produktiver Daten;
- absolute Performanceaussagen aus einem einzelnen Hostlauf;
- die pauschale Zusage aller Szenarien für alle Provider;
- Cloudaccounts, Abonnements, Tokens oder öffentliche Endpunkte automatisch
  anzulegen;
- Preview-Funktionen als stabil implementiert oder produktionsreif
  darzustellen.

## Bei Konkretisierung erneut zu prüfende Herstellerquellen

- [Neuerungen in SQL Server 2025](https://learn.microsoft.com/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17), insbesondere Preview-Status und Plattformgrenzen;
- [SQL Server mit der SSMS-Migrationskomponente aktualisieren](https://learn.microsoft.com/ssms/migrate/upgrade-sql-server);
- [Query-Store-Anwendungsszenarien](https://learn.microsoft.com/sql/relational-databases/performance/query-store-usage-scenarios?view=sql-server-ver17);
- [SQL-Server-Kompatibilitätszertifizierung](https://learn.microsoft.com/sql/database-engine/install-windows/compatibility-certification?view=sql-server-ver17);
- aktuelle Dokumentation der konkret gewählten Treiber, Security-, HA-/DR-,
  CDC-, Backup- und Supporting-Component-Versionen.
