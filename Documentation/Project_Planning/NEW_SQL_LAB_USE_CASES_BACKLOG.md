# Neue SQL-Server-Lab-Anwendungsmöglichkeiten – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG_EXPLORATION` |
| Stand | 2026-10-15 |
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
- Remote-Hyper-V-Steuerung sowie der priorisierte `Lab_Data`-Bugfix;
- SSIS ETL, Data Warehouse, inkrementelle Verarbeitung, Betrieb und Recovery;
- SSAS Tabular, Multidimensional, Semantic Models, Processing und Analytics;
- die kombinierte End-to-End-BI-Pipeline von OLTP über SSIS und Warehouse bis
  SSAS;
- SQL-AG/FCI, SSISDB-HA/Scale Out, SSAS-WSFC/Query-Scale-out und das spätere
  Clustered End-to-End BI.

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
| P2 | Stresstest-, Last- und Replay-Lab | Untersucht SQL-Server-Verhalten unter steigender Parallelität, Dauerlast und reproduzierter Workload; Werkzeugkandidaten: OStress, HammerDB, OStress Replay und JMeter | eine isolierte SQL-Instanz, synthetische Datenbank und separater Lastgenerator mit begrenztem Lastprofil | SQL-Ziele unter Docker, Podman und Hyper-V getrennt prüfen; Ausführungsplattform des Lastgenerators separat bewerten |
| P3 | Data-Governance- und Audit-Lab | Demonstriert Temporal Tables, Ledger, Row-Level Security, Dynamic Data Masking, Audit und kontrollierte Schlüsselrotation | eine SQL-Instanz, synthetische Rollen und manipulationsprüfbare Ereignisfolge | je nach Feature-Capability unter allen drei Providern |
| P3 | SQL-2025-JSON-, REST- und Hybrid-Search-Lab | Erprobt nativen JSON-Datentyp, JSON-Index, Regex/Fuzzy-Funktionen, externe REST-Aufrufe und optional die Kombination relationaler, JSON- und Vector-Suche | SQL Server 2025 plus lokaler HTTPS-Mock-Service; Vector-Lane referenziert den bestehenden Vector-Backlog | SQL-Kern unter Docker/Podman/Hyper-V; Preview-Funktionen immer getrennt ausgewiesen |
| P3 | Linked-Server-, Collation- und Distributed-Transaction-Lab | Reproduziert Cross-Instance-Abfragen, Collation-Konflikte, Delegation und Transaktionsgrenzen, die in Einzelinstanz-Labs nicht sichtbar werden | zwei SQL-Instanzen und ein Testclient; optional Domain Controller und MSDTC | Container für einfache Linked-Server-Fälle; Hyper-V/Windows für Kerberos und MSDTC |

## Empfohlene erste drei Vertical Slices

### 1. Upgrade- und Regressionslab

Ein enger [SQL-2022-/SQL-2025-Referenztest](../Quality/SQL_VERSION_UPGRADE_REFERENCE.md)
ist implementiert: eigene synthetische Quelle und neues Ziel, öffentlicher
BackupSetId-Transfer, erhaltene Kompatibilität 160 vor separatem Wechsel auf 170,
feste funktionale Prüfungen, beobachtete Dauern und operationsgebundenes Cleanup.
Die getrennte native Docker-/Podman-Abnahme bestand am 2026-09-21 auf `46340200`;
der unabhängige Nachlauf bestätigte je Provider zwei entfernte Own-Runs und keine
Runtime-Residuen. Query-Store-Auswertung, Anwendungs-/Planregressionen und weitere
Versionspaare dieser breiteren Planung sind damit noch nicht umgesetzt.

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

Der priorisierte Infrastrukturstream
[`TLS-001`](#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
konkretisiert hier den sicheren Labzugang für vorhandene Verbraucher. Er ist
kein zweites Security-Lab und ersetzt weder die übrige Treibermatrix noch den
späteren P2-Vertrag für Identity und Verschlüsselung. Seine Lieferpriorität
steht im [Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md#12-verbindliche-nächsten-fünf-entwicklungswellen).

Der erste Slice verwendet einen kleinen, katalogisierten .NET-Testclient gegen
SQL Server 2022 und 2025. Er prüft Login, TLS, parametrisierte Queries,
Transaktion, Connection Pooling, kontrollierten Verbindungsabbruch, Retry und
Commit-Eindeutigkeit. JDBC, ODBC und Python erweitern denselben Clientvertrag,
erhalten aber jeweils eigene Runtime-Evidence.

#### TLS-001 – authentifizierte TLS-Verbindungen der Testumgebungen

| Merkmal | Festlegung |
|---|---|
| Priorität | `P1`; höchste nächste Priorität unmittelbar nach dem laufenden SSISDB-Stream, Benutzerauftrag vom 2026-10-15 |
| Status | `planned`; Bestandsanalyse der Quellen und Backlog ausgearbeitet, keine TLS-Produktimplementierung oder Livequalifikation durch diesen Eintrag |
| Abhängigkeit | **Toolbelt SC-2026-045 – authentifizierte Liveabnahme** |
| Auslöser | [Toolbelt PR #322](https://github.com/gecompat/SQL_Server_Toolbelt/pull/322), geprüfter Head `8772e9d6a1d538e6fcb22da3f0bd03c83a28e88a`; PR bei der Prüfung am 2026-10-15 offen, kein behaupteter Merge |
| Verantwortung | Lab: Serverzertifikate, Identität, Client-Trust, Export und Bereitschaft; Toolbelt: eigener Preflight und tatsächliche Clientverbindungen |
| Entwicklungsreife | Eigene isolierte Lab-CA am 2026-10-16 zur Planung ausgewählt; [konkreter Entwurf](TLS_001_ISOLATED_CA_DESIGN.md), D1–D4-Parameter und native Bestandsaufnahme vor Mutation weiter offen |
| Aktueller Auftrag | Autonome Welle am 2026-10-16 ausdrücklich wieder gestartet; anschließend Fortsetzung bis zur echten TLS-Lab-Abnahme beauftragt, damit Toolbelt SC-2026-045 weiterführen kann. Isolierte Lab-CA ausgewählt; konkrete fehlende Freigaben gezielt anhand reviewbarer Previews klären. Bestehende geschützte Zertifikats-/Trust-/Resolver-/Testzielbindungen bleiben bis zur passenden konkreten Freigabe unverändert |

Aktueller privater Teilschritt ist der
[Windows-CA-Kandidat mit lesender Trust-Vorschau](../Architecture/AUTHENTICATED_TLS_CA_CANDIDATE.md).
Er bleibt `UNREGISTERED_UNQUALIFIED`; native lokale Crypto-/ACL-/DPAPI-
Fixtures ersetzen keine Registrierung, Trustmutation oder TLS-Lab-Abnahme.
Die allgemeine Registrytransaktion bleibt offen. Toolbelt PR #322 ist am
2026-10-16 inzwischen gemergt (Merge
`985b9d8a9df1dad9b1c13e868b7eac0a7758bd6f`); der aktuelle Consumer verlangt
weiterhin echte Booleans `true`/`false`, System.Data.SqlClient und sqlcmd
`-N` ohne `-C`. Die authentifizierte Liveabnahme bleibt `NOT_EXECUTED`.
Der eigene dauerhafte CA-Kandidat ist inzwischen lokal erfolgreich angelegt
und frisch lesend geprüft; reale Identitäten und Digests bleiben privat.
Die konkrete menschliche Trustfreigabe ist gesichert. Die
[private Importtransaktion](../Architecture/AUTHENTICATED_TLS_TRUST_IMPORT.md)
implementiert fünfminütige Freigabebindung, geschütztes Intent/Commit und
lesenden Recoverybefund. Native Storemutation und eigentliche TLS-Abnahme
sind durch deren Datei-/ACL-/Lock- und injizierte Storetests nicht belegt.
Der separat geprüfte echte Importworker wurde genau einmal ausgeführt und
nach 60 Sekunden beendet. Frisch lesend: CA `ABSENT`, Journal
`RECOVERY_REQUIRED`, passender gültiger Intent ohne Commit/Lock, kein
bestätigter Import. UI-Wahl: kein Dialog sichtbar, sichtbares Fenster nach geprüfter Recovery gewünscht; kein automatischer Retry oder Journalremove.
Die folgende [private CSR-Kryptolane](../Architecture/AUTHENTICATED_TLS_LEAF_CSR.md)
prüft öffentlichen CSR-Proof, expliziten SAN und frische Kandidatenbindung und
signiert ein unabhängig geprüftes öffentliches Leaf mit dem DPAPI-Key.
Eigene Tempfixtures bleiben getrennt vom echten Kandidaten. Das synthetische
Subject/Attributprofil ist keine native Windows-certreq-/CSP-/KeySpec-/SQL-
Qualifikation. NativeTarget, Registrierung und TLS bleiben `NOT_EXECUTED`.
Die [private einmalige Trust-Recovery](../Architecture/AUTHENTICATED_TLS_TRUST_RECOVERY.md)
konkretisiert jetzt den gültigen ursprünglichen Intent ohne normalen Commit:
Originalbytes bleiben erhalten, frische Preview bindet separate Adapterevidence,
ein Recoveryintent begrenzt den neuen Versuch. Bereits vorhandener Trust bleibt
unattributiert; unklare Recovery darf nicht wiederholt werden. Die tatsächliche
sichtbare Adapterausführung ist getrennt belegt: Die
[native Trust-Recovery](../Quality/TLS_CA_TRUST_ACCEPTANCE_2026-10-16.md)
bestand mit Exitcode 0, frischem exaktem Trust und `RECOVERY_IMPORT_RECORDED`.
Originalintent bytegleich, kein ursprünglicher Commit und kein verbleibender Lock.
Der erste eigene Docker-SQL-2025-Lauf belegte die Ablehnung der unvertrauten
Kette vor SQL-Arbeit und vollständiges Cleanup ohne Bestandsdateidrift;
die OpenSSL-CSR-Subjectkodierung wird jetzt eng zusätzlich akzeptiert.
Die spätere [Windows-Probe](../Quality/TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
bestand mit beiden positiven strikten Stacks, .NET-Gegenfällen für unvertraute
Kette und falsches SAN am gleichen IPv4-Endpunkt sowie vollständigem Cleanup.
Die [anschließende echte Ablauf-/Erneuerungsprobe](../Quality/TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
bestand für beide Windows-Stacks mit unvertrauter Kette, echtem Ablauf ohne
vorherigen Hostkontakt zum kurzen Leaf, falschem SAN und Erneuerung mit neuem
Key. Eigener Cleanup und Bestandsdateierhalt bestanden. Operative Registry,
qualifizierter Export, vollständige Client-/Providermatrix und SC-2026-045 bleiben offen.

**Istzustand und Vertragslücke.** Die Prüfung der Repositoryquellen am
2026-10-15 ergibt:

- [`Public/TestEnvironment.ps1`](../../Public/TestEnvironment.ps1) exportiert
  `encrypt = true` und `trustServerCertificate = true` und baut auch den
  Connection String mit diesen Werten. `host` stammt aus der Instanzinformation,
  ersatzweise aus deren Verbindungstarget; eine SAN-/Client-Trust-Prüfung
  qualifiziert diese Angabe nicht. `READY` beruht auf Run-/Runtimezustand und
  vorhandenen Verbindungsdaten, ohne authentifizierte Clientverbindung.
- [`Schemas/test-environment.schema.json`](../../Schemas/test-environment.schema.json)
  verlangt im Vertrag `SqlServerLab.TestEnvironment/1.0` beide TLS-Felder mit
  `const: true`. Ein Export mit dem sicheren Zielwert `false` wäre derzeit
  schemawidrig. Die vorhandenen synthetischen
  [Exporttests](../../Tests/Static/Invoke-TestEnvironmentChecks.ps1) belegen
  keine Zertifikatsinfrastruktur oder authentifizierte Liveverbindung.
- Der Export kopiert Schema und
  [`LOCAL_SQL_TESTING_PROMPT.md`](../User/LOCAL_SQL_TESTING_PROMPT.md) neben
  JSON, `.env` und Markdown. Der Prompt verlangt bisher ausdrücklich
  `TrustServerCertificate=True`. Auch diese Verbraucherführung muss migrieren.
  Das bestehende lokale Klartext-Secretformat ist ein gesondert zu beachtender
  Vertrag; keine Exportdateien oder kompletten Connection Strings als Evidence
  veröffentlichen.
- Docker-/Podman-Healthchecks verwenden derzeit `sqlcmd -C`;
  [`Private/SqlReadiness.ps1`](../../Private/SqlReadiness.ps1) und
  [`Private/HyperVLabEnvironment.ps1`](../../Private/HyperVLabEnvironment.ps1)
  enthalten ebenfalls Verbindungen mit Trust-Override. Diese internen Probes
  sind kein Nachweis für den authentifizierten Verbraucherzugang und dürfen
  künftig nicht als dessen Qualifikation dienen.
- Im geprüften Toolbelt-Head verlangen `Tests/CI/run-lab-local.ps1` und
  `Set-SqlClientTlsPolicy.ps1` Verschlüsselung mit Zertifikatsprüfung;
  `run-lab-target.sh` verwendet `-N` ohne `-C`. Die Boolean-Prüfung weist
  abweichende Exportwerte bereits vor dem Verbindungsaufbau ab. Der im PR
  dokumentierte Vertragsblocker ist deshalb kein nachgewiesener CA-, DNS-,
  Zertifikats- oder Client-Trust-Fehler.
- Vorhandene Zertifikate, SANs, Ketten, Ablaufdaten, SQL-Bindungen und die
  effektiven Trust Stores der lokalen Windows-/Linux-Clients wurden in diesem
  Backlogauftrag **nicht live untersucht**. Weder Vorhandensein noch Fehlen ist
  belegt. Eine lokale, read-only Bestandsaufnahme ist erster Umsetzungsschritt;
  nur bereinigte Klassifikationen gelangen in versionierte Dokumentation.

**Verbindliche Discovery.** Toolbelt liest zuerst
`SQL_SERVER_LAB_TEST_ENV_FILE`, sonst
`SQL_SERVER_LAB_DATA_ROOT/Exports/TestUmgebung.json`. Für die Variablen gilt im
geprüften Runner Prozess vor Benutzer. `SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE`
hat Vorrang, sonst gilt `TestUmgebung.schema.json` neben dem Export. Ein
gesetztes `SQL_SERVER_LAB_TEST_ENV_PROMPT_FILE` muss lesbar sein; der Labexport
stellt die zugehörige `TestUmgebung.prompt.md` bereit. Keine freie Dateisuche,
kein stiller Ersatzpfad und kein Ignorieren eines fehlerhaften Overrides.
Diese Regeln einschließlich Prompt-Discovery mit Export, Schema und den
Verbrauchern gemeinsam prüfen.

**Lösungsvorschlag und offene Entscheidungen.** Die Tabelle beschreibt
Vorschläge, keine bereits freigegebenen Architekturentscheidungen.

| Entscheidung | Vorschlag und Alternative | Exakt noch festzulegen |
|---|---|---|
| D1 – Zertifikatsautorität und Lifecycle | Bereits vorhandene geeignete Lab-PKI verwenden, falls Bestandsaufnahme und Rechteprüfung passen; sonst explizit eingerichtete Lab-CA mit getrennt geschütztem Signierschlüssel. Serverleaf mit passendem SAN, Server-Authentication-Eignung, gültiger Kette und nur für den SQL-Dienst lesbarem privatem Schlüssel. Alternative: betreiberseitig gelieferte Zertifikate mit validierter Import-/Erneuerungsschnittstelle. | Zuständige CA, Aussteller-/Signierautorität, Schlüsselablage und ACL/Dateimodus, Gültigkeit, Erneuerungsvorlauf, Sperr-/Rücknahmeverfahren, Ausfallverhalten und verantwortlicher Betreiber. Keine automatische Beschaffung oder globale PKI-Anlage. |
| D2 – Identität und Namensauflösung | Pro SQL-Ziel einen stabilen, aus allen vorgesehenen Clientkontexten auflösbaren Lab-DNS-Namen exportieren und denselben Namen im Zertifikat prüfen. Portweiterleitung ändert den Port, nicht die geprüfte Identität. Alternative: explizite IP-SANs für tatsächlich stabile IP-Ziele; kein stiller Wechsel auf IP, localhost, anderen Host oder Provider. | Namensraum, DNS-/Resolververantwortung, Container-/VM-/WSL-/Hostzugriffswege und erlaubte scopegebundene Resolveränderungen samt Rücknahme; Nachweis bei jeder relevanten Weiterleitung. Kein Hostname-Override als Ersatz für einen passenden Export. |
| D3 – Client-Trust und Berechtigungen | Trust im tatsächlichen Windows-/Linux-Ausführungskontext des jeweiligen System.Data.SqlClient- und sqlcmd-/ODBC-Clients herstellen und prüfen. Nur ausdrücklich bestätigte Lab-CA-/Storebindungen verändern; Änderungen mit Vorzustand und Ownership journalisieren. Alternative: vorhandene geeignete System-PKI ohne neue Trustanker. | Konkrete Clients/Versionen, interaktive Benutzer, Dienst-/Runneridentitäten, WSL/Container und privilegierte Kontexte; je Kontext effektiver Trust Store, Import-/Removalrechte und Freigabe. Gemeinsam genutzte oder vorbestehende Trustanker niemals beim Lab-Cleanup entfernen. Prozesslokaler Trust zählt nur bei belegter Unterstützung beider konkreter Clients. |
| D4 – Vertrag und Migration | Explizit versionierter Nachfolgevertrag mit getrenntem TLS-Bereitschaftsnachweis; sichere Exporte erst nach Qualifikation. Alte Artefakte erkennbar halten und für den authentifizierten Pfad ablehnen. Alternative: abgestimmte Revision von 1.0 nur nach nachgewiesenem gemeinsamen Consumer-Cutover. | Versionskennung, Koexistenz-/Cutoverpfade, unterstützte Leserversionen, Verhalten bei unqualifizierten Zielen/Gruppen und Ablauf der Legacyablösung. Toolbelt, Analyze, PerformanceSchulung, lokale Skripte, `.env`-/Markdownnutzer und Agenten-Prompt inventarisieren; deren tatsächliche Versionsannahmen prüfen. Schemaänderung nicht isoliert ausrollen. |

**Geordnete Arbeitspakete.** Alle Schritte bleiben innerhalb des ausdrücklich
betroffenen Lab-Scopes. Vor Mutation müssen State, Preview, Rechte, Cleanup und
Recovery feststehen; an offenen Freigabegrenzen nur den betroffenen Schritt
anhalten.

| Slice | Ergebnis und Abnahmegrenze |
|---|---|
| `TLS-001a` – Bestandsaufnahme/ADR | Exporter, Schema, alle Verbraucher und Providerpfade gemeinsam lesen; vorhandene Zertifikatsinfrastruktur und tatsächliche Clientkontexte read-only prüfen. D1–D4 entscheiden; ADR und begrenzten Provisionierungs-/Erneuerungs-/Rollbackvertrag ausarbeiten. Reine Erreichbarkeit, Exportabweichung, DNS-, Ketten-, Identitäts-, Ablauf- und Client-Trust-Probleme getrennt klassifizieren. |
| `TLS-001b` – Server und Clients | Reproduzierbare Ausstellung/Import, SQL-Zertifikatsbindung, Dienstrechte, vollständige Kette und erforderlichen Neustart pro Docker, Podman und Hyper-V lösen. Client-Trust und Auflösung im gewählten Scope einrichten. Renewal mit erneuter Clientqualifikation, Fehlern, Abbruch/Resume und nachvollziehbarer Rücknahme prüfen; private Schlüssel und Credentials nur im vorgesehenen lokalen Secret-/Konfigurationsbereich. |
| `TLS-001c` – Export und Migration | Schema, Exporter, JSON/`.env`/Markdown, Connection-String-Erzeugung, Resolver, Prompt, Benutzerreferenz und Verbraucher zusammen aktualisieren. Qualifizierte Ziele exportieren echte Booleans `encrypt = true`, `trustServerCertificate = false`. Qualifikation an Zielidentität, Zertifikat, Client-/Treiber-/Trustkontext und Aktualität binden; bei Renewal, Namens-/Trust-/Kontextänderung invalidieren. Runtime-READY und TCP-Erreichbarkeit bleiben von TLS-Bereitschaft getrennt. Plattform-/Versions-/Patch-/CU- und explizite Providerauswahl sowie Gruppensperre erhalten; kein Ersatz auf ein anderes bereites Ziel. |
| `TLS-001d` – Liveabnahme und Betrieb | Beide Clientstacks mit positiven und negativen Fällen auf der vereinbarten Matrix ausführen, anschließend gemeinsam mit dem Toolbelt-Labpreflight abnehmen. Architektur, Einrichtung, Betrieb, Erneuerung, Migration und Fehlerdiagnose dokumentieren; Provider-/Kontextgrenzen und offene Kombinationen sichtbar halten. |

**Risiken und Schutzgrenzen.** Ein CA-Import kann andere Anwendungen des
gleichen Clients beeinflussen; fehlende Rechte, geteilte Trustanker und
unbekannte Trust Stores blockieren den betreffenden Mutationsschritt.
Namensdrift bei NAT/Portweiterleitung und unterschiedliche Windows-/Linux-
Trust Stores können einen lokal erfolgreichen Test für andere Verbraucher
wertlos machen. Ablauf oder fehlerhafte Erneuerung kann Tests unterbrechen;
veraltete Qualifikation muss dann fail-closed entfallen. Der bestehende
`const: true`-Vertrag und alte Prompts erfordern einen koordinierten Cutover.
Kein `TrustServerCertificate=True`, kein `sqlcmd -C`, kein Abschalten der
Verschlüsselung und kein stiller Hostname-/Provider-Fallback im neuen
authentifizierten Pfad. Ein pauschaler Flagwechsel löst keines dieser Risiken.
Rollback stellt ausschließlich eigene vorher journalisierte Bindungen wieder
her; unsicherer Alttransport ist keine erfolgreiche TLS-Recovery.

**Akzeptanzkriterien und noch offene Evidence.**

1. Schema-/Exporttests prüfen fehlende TLS-Felder, `null`, String-/Zahlwerte,
   falsche Boolean-Werte, widersprüchliche Connection Strings und jede
   Discovery-/Overridevariante einschließlich Prompt. Sichere Werte und
   erhaltene Auswahl-/Gruppenregeln sind positiv belegt; unqualifizierte Ziele
   erhalten durch Flags oder Runtime-READY keinen TLS-Erfolg.
2. System.Data.SqlClient und genau der vom Toolbelt verwendete
   sqlcmd-/ODBC-Client verbinden verschlüsselt mit geprüfter Kette und der
   exportierten Serveridentität, führen eine echte SQL-Abfrage aus und prüfen
   den verschlüsselten Transport. Ausführung auf dem SQL-Host allein genügt
   nicht. Client-/Treiberstand und tatsächliche Ausführungsidentität werden
   lokal nachvollziehbar gebunden, öffentlich nur bereinigt klassifiziert.
3. Nicht vertrauenswürdige Kette, falscher Servername und abgelaufenes
   Zertifikat scheitern jeweils in **beiden** Clientstacks vor fachlicher
   SQL-Arbeit. Isolierte Negativfixtures verwenden, keine gemeinsam benutzten
   Zertifikate oder Trustanker für die Fehlererzeugung verändern. DNS-,
   TCP-/Runtime-, Authentisierungs- und Vertragsfehler getrennt berichten.
4. Mindestens folgende sechs SQL-Zielkombinationen werden je tatsächlichem
   Windows-/Linux-Clientkontext und beiden Clientstacks qualifiziert. Docker,
   Podman und Hyper-V bleiben getrennte Evidence; unzutreffende Kombinationen
   nur mit begründeter Capabilitygrenze ausschließen, offene niemals grün werten.

   | SQL-Zielplattform | SQL Server 2019 | SQL Server 2022 | SQL Server 2025 |
   |---|---|---|---|
   | Windows / Hyper-V | `NOT_EXECUTED` | `NOT_EXECUTED` | `NOT_EXECUTED` |
   | Linux / Docker und Podman getrennt | `NOT_EXECUTED` | `NOT_EXECUTED` | `NOT_EXECUTED` |

5. Provisionierung, Neustart, Erneuerung, Migrationscutover, fehlgeschlagener
   Client-Trust-Import und scopegebundener Cleanup/Rollback sind reproduzierbar.
   Keine fremden Stores, CA-Einträge, Zertifikate, Endpoints oder Daten ändern;
   Schlüssel, Zugangsdaten, vollständige Connection Strings und reale
   Labinventare bleiben außerhalb versionierter/public Evidence.
6. Die Abhängigkeit **Toolbelt SC-2026-045 – authentifizierte Liveabnahme**
   schließt erst mit schema- und policykonformem Export, qualifiziertem
   Serverzertifikat/Hostnamen, wirksamem Trust in den tatsächlichen
   Clientkontexten und erfolgreichem Toolbelt-Labpreflight samt echten
   Verbindungen beider Stacks und Negativfällen. Exakte Toolbelt-/Labstände,
   ausgeführte Matrixzellen, offene Zellen und Cleanupstatus getrennt nennen.
   Flag-, Schema-, Offline- und frühere Produktläufe ersetzen diese Liveabnahme
   nicht. Der aktuelle Backlogauftrag führt diese Prüfungen nicht aus.

## Themenbereich Stresstest, Last und Replay

Status: `BACKLOG_EXPLORATION`. Ziel ist eine reproduzierbare Untersuchung von
Durchsatz, Antwortzeiten, Fehlern, Blocking und Ressourcenengpässen unter
kontrollierter SQL-Server-Last. Die Werkzeuge sind Kandidaten für eine spätere
Bewertung; ihre Integration und Runtime-Eignung sind noch nicht nachgewiesen.

| Werkzeug / Stichwort | Zu untersuchender Einsatz |
|---|---|
| OStress | Wiederholte und parallele Ausführung definierter T-SQL-Workloads |
| HammerDB (Hammer DB) | Standardisierte SQL-Server-Workloads und Vergleich mehrerer Laststufen |
| OStress Replay | Reproduktion einer synthetisch erzeugten Workload; konkrete Toolkette, Eingabeformat, Timing und Reihenfolge vor Umsetzung klären |
| JMeter | JDBC-basierte SQL-Server-Last mit parametrierten Abfragen und Transaktionen |

Der erste Slice soll eine kleine synthetische Datenbasis und einen bewerteten
Lastgenerator verwenden. Vor der Umsetzung sind folgende Punkte zu klären:

- SQL-Version, Edition, Provider sowie Tool-, Treiber- und Lizenzanforderungen;
- reproduzierbare Lastprofile mit Warm-up, Parallelität, Laufzeit, Datenmenge
  und festem Lese-/Schreib- beziehungsweise Transaktionsmix;
- harte Ressourcen- und Zeitgrenzen, Hostreserve, Abbruch sowie eigenes Cleanup
  für Lastgenerator und erzeugte SQL-Daten;
- Messung von Durchsatz, Antwortzeit-Perzentilen, Fehler-/Timeout-Raten,
  Deadlocks, Waits und CPU-/RAM-/I/O-Auslastung;
- SQL-Assertions für erwartete Datenstände und Transaktionskonsistenz;
- vergleichbare Baseline- und Wiederholungsläufe mit dokumentierten
  Messbedingungen; ein einzelner Hostlauf begründet keine allgemeine
  Performanceaussage.

Replay verwendet ausschließlich synthetische Eingaben. Last- und Fault-Szenarien
bleiben getrennte Verträge; ihre spätere Kombination baut auf dem bestehenden
[Szenariovertrag](SCENARIO_CONTRACT_BACKLOG.md) auf. Für das Ressourcenprofil
`Stress` gelten die explizite Bestätigung und harten Grenzen aus dem
[Masterplan](MASTER_IMPLEMENTATION_PLAN.md#102-ressourcenprofile).

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
