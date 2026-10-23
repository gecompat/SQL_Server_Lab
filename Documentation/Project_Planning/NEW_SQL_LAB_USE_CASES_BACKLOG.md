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

Die [konfigurationsbasierte TLS-Prüfstatusanzeige](../Quality/TLS_CONFIGURATION_STATUS_DISPLAY_2026-10-22.md)
ergänzt CLI, SQL-Zielkarte und Verbindungsübersicht. Zwei getrennte native
Windows-/Docker-/Podman-SQL-2025-CU9-Abnahmen bestanden einschließlich eigener
Bereinigung. Gespeichertes False meldet `NOT_EVALUATED` und behauptet keine
aktuelle Prüfung. Die [explizite öffentliche Live-API](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md)
ergänzt eine gebundene aktuelle Beobachtung ohne Secrets; ihr [nativer Nachweis](../Quality/TLS_LIVE_QUALIFICATION_API_ACCEPTANCE_2026-10-23.md)
bestand alle sechs Windows-/Docker-/Podman-Profilzellen mit eigenem Cleanup.
Eine dedizierte Liveprüfaktion am SQL-Ziel
und deren gerenderte Frische-/Driftanzeige bleiben Teil des offenen TLS-001c-Scope.

Die zusätzliche [echte Windows-Produktseitenabnahme](../Quality/TLS_WINDOWS_RENDERED_CONNECTION_SETTINGS_2026-10-21.md)
schließt die gespeicherte TLS-Anzeige an eigenen qualifizierten Docker-/Podman-
SQL-2025-CU9-Labs: frischer abgeschlossener Workflow-Snapshot, passender
Endpoint, explizite False-Werte und exakt angezeigter Connection String.
Der reproduzierte Inventurcachefehler ist korrigiert; ursprünglicher Docker-
FAIL und getrennte PASS-Nachläufe bleiben erhalten. Creation-Dialog,
Clipboard und gesonderte aktuelle Livequalifikationsstatusanzeige bleiben offen. Der
verlinkte Nachweis führt die weiteren Matrix-, Lifecycle-, Consumer- und
Trustkontext-Schritte; `TLS-001` bleibt `partial`.

Die separate Windows-/SQL-2022-CU27-Neustart-/Rebind-Abnahme bestand unter Docker und Podman je zwölf Fälle und zwölf bezeichnete strikte Clientergebnisse auf Build `16.0.4295.3`, Recordform `0.3` mit `SqlProfileId=2022-CU27`, eigenem Cleanup und Bestandsvergleich. Damit sind diese beiden fehlenden Rebind-Kombinationen geschlossen; die übrigen TLS-001-Verträge bleiben getrennte offene Scopes.

Die zusätzliche native Neustart-/Rebind-Abnahme für Windows-/SQL-2025-CU9 mit Docker und Podman bestand je zwölf Fälle und zwölf strikte Clientergebnisse auf Build `17.0.5005.3`, Recordform `0.2` ohne `SqlProfileId`, eigenem Cleanup und Bestandsvergleich. Die unabhängige Oracleprüfung unterscheidet Property-Abwesenheit von vorhandenen null-/Leerwerten. Weitere Patch-/Clientkombinationen und die übrigen offenen TLS-001-Verträge bleiben getrennte Scopes.

Die explizite Wiederbindung nach Containerneustart ist im [begrenzten Vertrag](../Architecture/AUTHENTICATED_TLS_CONTAINER_REBIND.md) implementiert und getrennt nativ unter Windows/SQL 2019 CU32 mit Docker und Podman geprüft: je zwölf Fälle und zwölf strikte Clientergebnisse mit eigenem Cleanup. Docker belegt den Stand vor der fokussiert geprüften Offsetkorrektur, Podman den korrigierten Stand; der ursprüngliche Podman-FAIL bleibt erhalten. Der Befehl ändert nur die Start-Epoche derselben eigenen policygebundenen Containerbindung nach beiden strikten Clients. Finale PR-Pflichtgates bleiben Integrationsbedingung; automatische Erneuerung/Reparatur und die Gesamtmatrix bleiben offen.

SQL 2019 CU32 ist als nächstes geschlossenes operatives Windows-/Docker-/Podman-Profil mit Build `15.0.4430.1` implementiert. Der bestehende `0.3`-Record bindet ausdrücklich `2019-CU32`; historische SQL-2025- und SQL-2022-Bindungen bleiben erhalten. Beide getrennten nativen operativen Abnahmen bestanden je sieben Fälle, sechs strikte Clientergebnisse und vollständigen eigenen Container-/Volume-/Exportcleanup. Frühere Kryptoproben bleiben getrennte Nachweise; die finalen PR-Pflichtgates sind Integrationsbedingung.


Die [native Hyper-V-Referenzabnahme vom 2026-10-20](../Quality/TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md)
ist für Windowsclients und SQL 2025 RTM bestanden: gültige Kette,
untrusted CA, falscher SAN, echter Ablauf, neuer Schlüssel, striktes TLS nach
Windows-Neustart und eigener Cleanup. Öffentliche Hyper-V-False-Erstellung,
qualifizierter Export, weitere Versions-/Clientkombinationen und Toolbelt
SC-2026-045 bleiben davon getrennt; der Gesamtstatus bleibt `partial`.

Der [Windows-V2-Consumer-Cutover](../Quality/TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
ist für die sechs geschlossenen Docker-/Podman-SQL-Profile separat abgenommen.
Weitere Consumer-/Plattformpfade bleiben offen. Die folgenden privaten
Vorstufen beschreiben ihre eigene begrenzte Funktion, nicht den inzwischen
erreichten Gesamtstand des öffentlichen Windows-Consumerpfads.

Der [private Consumer-Guard](../Architecture/AUTHENTICATED_TLS_CONSUMER_GUARD.md) ergänzt gehaltene NTFS-Lesehandles und feste SQL-Journalmetadaten. Das ist eine vorbereitende interne Grenze, kein Gastverbraucherende, Recovery-Apply oder vollständiger TLS-001-Abschluss.

Die begrenzte [private Authoritybindung](../Architecture/AUTHENTICATED_TLS_AUTHORITY_BINDING.md)
ergänzt den Writer um CA-Kandidat/Ciphertext/DER, exakte aktive Client-/
Signiergeneration und ReadOnly-Trust. Frische Prüfung gilt auch für unveränderte
Generationen und Recoverycommit. Das sind Metadaten und eigene Tempfixtures;
keine tatsächliche Adoption der bestehenden CA, native Gesamtqualifikation
oder Exportfreigabe. Diese private Vorstufe allein gab SC-2026-045 noch nicht frei.

Der spätere [private Windows-Registrywriter](../Architecture/AUTHENTICATED_TLS_REGISTRY_WRITER.md)
ergänzt inzwischen aktive Client-/Signiermetadaten vor Keyanlage mit frischer
Actor-/Volumeprüfung, geschützter Ablage, atomarem Ersatz und expliziter
Recovery. Eigene NTFS-Tempfixtures belegen Prozessabbrüche, Parallelität und
Cleanup; native Client-/Signiermetadaten wurden getrennt im eigenen Tempbereich
registriert. Das registriert keine CA und qualifiziert keinen TLS-Export.
Weitere CA-/Trustscopezuordnungen und Retirement bleiben P1. Öffentliche
Moduswahl ist nur in den oben genannten geschlossenen Containerprofilen
abgenommen; der Creationdialog bleibt getrennt offen.

| Merkmal | Festlegung |
|---|---|
| Priorität | `P1`; höchste nächste Priorität unmittelbar nach dem laufenden SSISDB-Stream, Benutzerauftrag vom 2026-10-15 |
| Status | `partial`; operative Windows-/Docker-/Podman-Profile SQL 2019 CU32, 2022 CU27 und 2025 CU9, deren V2-Consumerpfad und explizite Live-API separat nativ abgenommen; private Windows-/Hyper-V-SQL-2025-RTM-Referenz nativ abgenommen. Öffentliche Hyper-V-/Linuxpfade, weitere Consumer, UI-Liveaktion und Lifecycle-/Trustkontexte bleiben offen |
| Abhängigkeit | **Toolbelt SC-2026-045 – authentifizierte Liveabnahme** |
| Auslöser | [Toolbelt PR #322](https://github.com/gecompat/SQL_Server_Toolbelt/pull/322), geprüfter Head `8772e9d6a1d538e6fcb22da3f0bd03c83a28e88a`; PR bei der Prüfung am 2026-10-15 offen, kein behaupteter Merge |
| Verantwortung | Lab: Serverzertifikate, Identität, Client-Trust, Export und Bereitschaft; Toolbelt: eigener Preflight und tatsächliche Clientverbindungen |
| Entwicklungsreife | [Modus-/CA-Entwurf](TLS_001_ISOLATED_CA_DESIGN.md) und begrenzter [operativer Vertrag](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md); weiterführende Matrix-, Consumer- und Lifecycle-Anforderungen bleiben P1 |
| Aktueller Auftrag | Autonome Welle am 2026-10-16 ausdrücklich wieder gestartet; anschließend Fortsetzung bis zur echten TLS-Lab-Abnahme beauftragt, damit Toolbelt SC-2026-045 weiterführen kann. Isolierte Lab-CA ausgewählt; konkrete fehlende Freigaben gezielt anhand reviewbarer Previews klären. Bestehende geschützte Zertifikats-/Trust-/Resolver-/Testzielbindungen bleiben bis zur passenden konkreten Freigabe unverändert |
| Modus und Default | `Encrypt=True;TrustServerCertificate=True` bleibt der Standard mit geringerem Einrichtungsaufwand. `False` wird ausdrücklich gewählt und benötigt qualifizierte Zertifikats-/Clientbindung; im operativen Windows-/Docker-SQL-2025-CU9-Scope implementiert. Weitere Kombinationen bleiben P1; [verbindliche Modusentscheidung](TLS_001_ISOLATED_CA_DESIGN.md#verbindliche-moduswahl-und-standard) |
| Sofortumsetzung | Die Bedingung vom 2026-10-16 stellte den damaligen unvollständigen Zertifikats-/Trustpfad zurück. Der nachfolgende ausdrückliche Auftrag implementierte den eigenen operativen Teilscope; fehlende weitere Voraussetzungen bleiben im P1-Backlog. |

##### Voraussetzungen und Startentscheidung vom 2026-10-16

Die Bedingung für die sofortige Produktumsetzung war am 2026-10-16 **nicht erfüllt**.
Die [ausgeführte Vorprüfung](../Quality/LOCAL_VALIDATION_STRATEGY.md#tls-modi-bedingte-vorprüfung-vom-2026-10-16)
trennt lesende Readiness und Quellenbefunde von fehlender TLS-Liveabnahme.
Der damalige Umfang blieb mit hoher Priorität im bestehenden TLS-001-Stream:
Voraussetzungen in `TLS-001b`, konsistente Moduswahl und Connection Settings in
`TLS-001c`, echte Verbindungsabnahme in `TLS-001d`. Es entsteht kein paralleler
Implementierungsstream und keine vorgezogene Anzeige einer funktionsfähigen
`False`-Option. Die folgende Vorprüfung ist historisch; der inzwischen integrierte
operative Windows-/Docker-Teilscope und seine Grenzen stehen im verlinkten
Fachvertrag und im aktuellen Status oben.

| Geprüfter Bereich | Ergebnis und Aussagegrenze |
|---|---|
| Docker, Podman und Hyper-V | Jeweils `Test-SqlServerLabClientReadiness.ps1 -Operation Create`: `READY_WITH_WARNINGS`, Provider erreichbar, Modul/Exports und Storage vorhanden. Einziger Warncode `TARGET_AUTHORIZATION_REQUIRED` bezeichnet die spätere Zielprüfung; kein Installations- oder Erreichbarkeitsblocker. |
| Clients | System.Data.SqlClient und natives `sqlcmd` verfügbar, SQL-ODBC-Treiber installiert. Der von sqlcmd tatsächlich geladene Treiber und eine authentifizierte SQL-Verbindung sind dadurch nicht nachgewiesen. |
| Aktueller Implementierungsstand | Quellenprüfung von `main` auf `2fed9a89eb948d16fac51329d5863dd08b43ed52`: private CA-/CSR-/Trustbausteine vorhanden, aber keine integrierte operative SQL-Zertifikatsbindung oder vollständige Client-/Zielqualifikation. Exporter und 1.0-Schema bleiben auf `true` festgelegt. |
| Trustimport | Der [letzte dokumentierte native Versuch](https://github.com/gecompat/SQL_Server_Lab/blob/2fed9a89eb948d16fac51329d5863dd08b43ed52/Documentation/Architecture/AUTHENTICATED_TLS_TRUST_IMPORT.md) ist nach Timeout unbestätigt (`RECOVERY_REQUIRED`); dies ist kein frisch erhobener Storebefund oder bestätigter Trust. Der [CSR-Kryptobeweis](https://github.com/gecompat/SQL_Server_Lab/blob/2fed9a89eb948d16fac51329d5863dd08b43ed52/Documentation/Architecture/AUTHENTICATED_TLS_LEAF_CSR.md) ersetzt keine SQL-/Dienst-/Clientbindung. |
| Echte Verbindungen beider Modi | In dieser Vorprüfung `NOT_EXECUTED`; die fehlenden TLS-Voraussetzungen wurden nicht durch neue CA-Anlage, Trustimport, Serverkonfiguration oder einen Providerstart hergestellt. |

**Startbedingungen für die zurückgestellte Produktumsetzung:** Eine ausdrücklich
gebundene eigene Testinstanz besitzt ein gültiges, zur Verbindungsidentität
passendes Serverleaf samt geschütztem Dienstkey und reproduzierbarer
SQL-Bindung. Der konkrete Clientkontext vertraut der Kette nachweislich;
ein offener Trustintent ist vor Wiederverwendung über den bestehenden
Recoveryvertrag geklärt. Der tatsächliche SqlClient-/sqlcmd-Stack kann damit
eine echte verschlüsselte SQL-Abfrage mit `TrustServerCertificate=False`
ausführen. Ownership, Cleanup und Recovery sind für diese eigenen Ressourcen
geklärt. Readiness oder erfolgreiche Signierung allein reichen nicht aus.

**Gebündelter P1-Lieferumfang nach Erfüllung dieser Voraussetzungen:**

- beide Modi bei Erstellung wählbar, Standard immer
  `Encrypt=True;TrustServerCertificate=True`;
- effektive Werte und getrennter Prüfstatus unmittelbar in den CLI-/GUI-
  Connection Settings, konsistent mit State, kopiertem Connection String und
  allen Exportformen;
- echte SQL-Anmeldung und Abfrage mit beiden Clientstacks und beiden Modi,
  nachgewiesene Transportverschlüsselung, negative Zertifikatsfälle bei `False`
  und kein automatischer Rückfall auf `True`;
- getrennte Provider-/Versions-/Clientnachweise sowie bestätigter eigener
  Cleanup; fehlende Kombinationen bleiben offen.

**Nachfolgender begrenzter Auftrag:** Der bereits funktionierende einfache
Standard wurde unabhängig davon ausdrücklich implementiert. Der gemeinsame
Container-Connection-String-Erzeuger ergänzt `Encrypt=True` zu seinem bestehenden
`TrustServerCertificate=True`; der SSMS-Registrierungsexport wechselt von
`Encrypt=False` zu demselben Standard. Testumgebungsexport und Hyper-V-Strings
verwenden beide Werte bereits. Bestehende gespeicherte Strings werden nicht
migriert. Das schließt weder die zusätzliche `False`-Moduswahl noch die
erweiterte Anzeige des Qualifikationsstatus ab; diese bleiben im P1-Umfang.

**Podman-Default-Abnahme vom 2026-10-17:** Der bedingte Folgeauftrag konnte mit
bereits erreichbarer Runtime, lokal vorhandenen Images und Clients sowie
`RESOURCE_OK` ausgeführt werden. Der
[getrennte Nachweis](../Quality/LOCAL_VALIDATION_STRATEGY.md#podman-tls-default-abnahme-vom-2026-10-17)
bestand für SQL 2019/2022/2025 mit sechs echten verschlüsselten Verbindungen
und vollständigem eigenem Cleanup bei unveränderten Inventaren und erfassten
vorhandenen Run-Dateien. Kein zusätzlicher offener Default-Abnahmeblocker für
Podman; weitere authentifizierte Matrixfälle und die gesonderte Prüfstatusanzeige bleiben offen.

**Bedingte Fortsetzung vom 2026-10-17: Voraussetzungen teilweise vorhanden.**
Die frische lesende Bootstrapprüfung meldet Docker, Podman und Hyper-V `READY`.
Die bestehende CA-Vorschau und der identische CurrentUser/Root-Trust sind
bestätigt; am gebundenen Root fehlt jedoch die operative TLS-Registrydatei.
Der vorhandene Writer unterstützt ausschließlich Client-/Signiermetadaten
vor Keyanlage, keine Zuordnung des bestehenden CA-Keys zu Authority und
Trustscope. In der vorhandenen sechsteiligen Exportgruppe gelangen zwei
SQL-2025-Kontrollanmeldungen mit `Encrypt=True;TrustServerCertificate=True`
(Docker und Hyper-V). Dieselben Ziele lehnten `False` mit
`SEC_E_UNTRUSTED_ROOT` vor der ersten SQL-Abfrage ab. Die Gruppe enthält kein
bereites registriertes Podman-SQL-2025-Ziel; die Podman-Runtime selbst ist bereit.
Der [ausgeführte Prüfweg](../Quality/LOCAL_VALIDATION_STRATEGY.md#bedingte-tls-fortsetzung-vom-2026-10-17)
belegt deshalb keinen qualifizierten Gruppenexport. Die früheren isolierten
TLS-Probes bleiben eigene Nachweise an inzwischen bereinigten Testzielen.

CA-/Trustscopebindung und qualifizierter `False`-Export bleiben **P1**.
Fortsetzungsbedingungen sind die operative Bindung von CA-/Keygeneration,
Signierer und Client-Trustscope sowie ein ausdrücklich ausgewähltes SQL-Ziel
mit gültiger passender Serverkette und erfolgreichen strikten Verbindungen
beider Clientstacks. Erst danach folgt der gekoppelte Export-/Schema-/Prompt-
und Consumer-Cutover mit Frische- und Driftprüfung. Der bedingte Auftrag
veranlasste keine neue CA-/Trust-/Servereinrichtung. Der Default bleibt
`Encrypt=True;TrustServerCertificate=True`.

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
Key. Eigener Cleanup und Bestandsdateierhalt bestanden. Eine getrennte eigene
[Podman-Probe](../Quality/TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle für SQL 2025 CU9 samt Cleanup.
Die nachfolgende [Container-Versionsmatrix](../Quality/TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
bestand separat je acht Windows-Clientfälle mit Docker und Podman für SQL 2019
CU32 und SQL 2022 CU27, jeweils mit eigenem Cleanup und frischem Schutzvergleich.
Operative Registry, qualifizierter Export, Linuxclients, Hyper-V, Trustdrift,
TLS-Abbruch/Resume und SC-2026-045 bleiben offen.
Die separate [Linux-Clientvorbereitung](../Quality/TLS_LINUX_CLIENT_CAPABILITY_2026-10-16.md)
beobachtete die tatsächlichen PowerShell-/SqlClient-/sqlcmd-Bausteine in einem
isolierten eigenen Clientcontainer. SqlClient erreichte nur einen erwarteten
lokalen Netzwerkfehler; sqlcmd führte nur Hilfe aus. Alle eigenen Fixtures sind
entfernt, Bestandsdateien frisch erhalten. Kein Linux-TLS-, Trust-, Registry-
oder Exportnachweis; die Matrixzellen und SC-2026-045 bleiben unverändert offen.

Der spätere konkret freigegebene
[Linux-Trustversuch](../Quality/TLS_LINUX_TRUST_ATTEMPT_2026-10-17.md)
scheiterte an der privaten Dateivorbereitung ohne Capabilities vor dem ersten
TLS-Probeprozess. Eigener Client und SQL-Ziel samt Volumes und temporärer
Host-Secretdatei sind entfernt, Schutzvergleiche frisch bestanden. Prozess-Trust
beider Stacks und geladener Linux-ODBC bleiben unqualifiziert. Der nächste
geplante Versuch lässt UID 10001 die eigene Datei direkt erstellen; er braucht
eine neue konkrete Vorschau und Freigabe statt eines alten Intent-Replays.
Der separat freigegebene [UID-Nachfolger](../Quality/TLS_LINUX_DIRECT_UID_PARTIAL_ACCEPTANCE_2026-10-17.md)
bestand die native Dateianlage und eine strikte Linux-CLR-SQL-Verbindung mit
Verschlüsselung. ODBC scheiterte am als gültig geplanten IP-SAN-Fall mit einer
Namensablehnung. Eigener Cleanup und frische Schutzvergleiche bestanden;
Trustentzug/-wiederherstellung und geladener ODBC bleiben offen. Eine neue
`DNS localhost`-Vorschau ändert keine Resolver und verlangt neue Freigabe;
SC-2026-045 bleibt gesperrt.

Der anschließend neu konkret freigegebene
[localhost-Versuch](../Quality/TLS_LINUX_LOCALHOST_PRETRUST_ATTEMPT_2026-10-17.md) scheiterte vor der Client-Trustdateianlage:
`getent ahosts/hosts` beobachtete nur die freigegebenen Loopback-Adressen,
der zusätzliche .NET-Auflösungsprozess startete jedoch wegen des schreibgeschützten
Homeverzeichnisses nicht. Keine TLS-Probes oder Client-Trustanlage; eigener Cleanup,
frische Abwesenheit und Schutzvergleiche bestanden. Eine neue rein planende
Vorschau ergänzt ausschließlich das prozesslokale `HOME=/tmp` für diesen
Auflösungsaufruf. Sie ist ungetestet und verlangt eine neue konkrete Freigabe,
ein neues Budget und gebundene geprüfte Quellen. Kein Replay; die vollständige
TLS-Abnahme und Toolbelt SC-2026-045 bleiben offen.

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

**Lösungsvorschlag und offene Entscheidungen.** Beide Modi und der einfache
Standard sind gemäß Benutzerauftrag festgelegt. Die folgenden technischen
Ausgestaltungen bleiben Vorschläge; insbesondere begründet der optionale
authentifizierte Pfad keine CA-/Trustpflicht für einfache Labs. Eine entsprechend
qualifizierte Instanz kann beide Clientoptionen bedienen; der Wechsel der
Clientoption allein erfordert keine zweite Instanz. Provider-/Versions-/
Clientkombinationen benötigen trotzdem eigene Nachweise.

| Entscheidung | Vorschlag und Alternative | Exakt noch festzulegen |
|---|---|---|
| D1 – Zertifikatsautorität und Lifecycle | Bereits vorhandene geeignete Lab-PKI verwenden, falls Bestandsaufnahme und Rechteprüfung passen; sonst explizit eingerichtete Lab-CA mit getrennt geschütztem Signierschlüssel. Serverleaf mit passendem SAN, Server-Authentication-Eignung, gültiger Kette und nur für den SQL-Dienst lesbarem privatem Schlüssel. Alternative: betreiberseitig gelieferte Zertifikate mit validierter Import-/Erneuerungsschnittstelle. | Zuständige CA, Aussteller-/Signierautorität, Schlüsselablage und ACL/Dateimodus, Gültigkeit, Erneuerungsvorlauf, Sperr-/Rücknahmeverfahren, Ausfallverhalten und verantwortlicher Betreiber. Keine automatische Beschaffung oder globale PKI-Anlage. |
| D2 – Identität und Namensauflösung | Pro SQL-Ziel einen stabilen, aus allen vorgesehenen Clientkontexten auflösbaren Lab-DNS-Namen exportieren und denselben Namen im Zertifikat prüfen. Portweiterleitung ändert den Port, nicht die geprüfte Identität. Alternative: explizite IP-SANs für tatsächlich stabile IP-Ziele; kein stiller Wechsel auf IP, localhost, anderen Host oder Provider. | Namensraum, DNS-/Resolververantwortung, Container-/VM-/WSL-/Hostzugriffswege und erlaubte scopegebundene Resolveränderungen samt Rücknahme; Nachweis bei jeder relevanten Weiterleitung. Kein Hostname-Override als Ersatz für einen passenden Export. |
| D3 – Client-Trust und Berechtigungen | Trust im tatsächlichen Windows-/Linux-Ausführungskontext des jeweiligen System.Data.SqlClient- und sqlcmd-/ODBC-Clients herstellen und prüfen. Nur ausdrücklich bestätigte Lab-CA-/Storebindungen verändern; Änderungen mit Vorzustand und Ownership journalisieren. Alternative: vorhandene geeignete System-PKI ohne neue Trustanker. | Konkrete Clients/Versionen, interaktive Benutzer, Dienst-/Runneridentitäten, WSL/Container und privilegierte Kontexte; je Kontext effektiver Trust Store, Import-/Removalrechte und Freigabe. Gemeinsam genutzte oder vorbestehende Trustanker niemals beim Lab-Cleanup entfernen. Prozesslokaler Trust zählt nur bei belegter Unterstützung beider konkreter Clients. |
| D4 – Vertrag und Migration | Explizit versionierter Nachfolgevertrag für beide Modi; `encrypt=true` bleibt fest, `trustServerCertificate` entspricht der ausdrücklichen Moduswahl und ist standardmäßig `true`. Authentifizierte Bereitschaft mit `false` erst nach separater Qualifikation; keine automatische Herabstufung bei Fehlern. Das 1.0-Schema nicht stillschweigend umdefinieren; den einfachen Modus dauerhaft erhalten. | Genaue Feldform, Versionskennung, Koexistenz-/Cutoverpfade, unterstützte Leserversionen und Verhalten bei unqualifizierten Zielen/Gruppen abstimmen. Toolbelt, Analyze, PerformanceSchulung, lokale Skripte, `.env`-/Markdownnutzer und Agenten-Prompt inventarisieren; deren tatsächliche Versions- und Modusannahmen prüfen. Ein Consumer darf `false` verlangen, ohne den globalen Labstandard zu ändern. Schemaänderung nicht isoliert ausrollen. |

**Geordnete Arbeitspakete.** Alle Schritte bleiben innerhalb des ausdrücklich
betroffenen Lab-Scopes. Vor Mutation müssen State, Preview, Rechte, Cleanup und
Recovery feststehen; an offenen Freigabegrenzen nur den betroffenen Schritt
anhalten.

| Slice | Ergebnis und Abnahmegrenze |
|---|---|
| `TLS-001a` – Bestandsaufnahme/ADR | Exporter, Schema, alle Verbraucher und Providerpfade gemeinsam lesen; vorhandene Zertifikatsinfrastruktur und tatsächliche Clientkontexte read-only prüfen. D1–D4 entscheiden; ADR und begrenzten Provisionierungs-/Erneuerungs-/Rollbackvertrag ausarbeiten. Reine Erreichbarkeit, Exportabweichung, DNS-, Ketten-, Identitäts-, Ablauf- und Client-Trust-Probleme getrennt klassifizieren. |
| `TLS-001b` – Server und Clients | Reproduzierbare Ausstellung/Import, SQL-Zertifikatsbindung, Dienstrechte, vollständige Kette und erforderlichen Neustart pro Docker, Podman und Hyper-V lösen. Client-Trust und Auflösung im gewählten Scope einrichten. Renewal mit erneuter Clientqualifikation, Fehlern, Abbruch/Resume und nachvollziehbarer Rücknahme prüfen; private Schlüssel und Credentials nur im vorgesehenen lokalen Secret-/Konfigurationsbereich. |
| `TLS-001c` – Moduswahl, Export und Migration | Modus bei Erstellung ausdrücklich wählbar und im State gebunden; API, Konsole und Browser verwenden denselben Standard `Encrypt=True;TrustServerCertificate=True` ohne eigene CA-/Trustpflicht. CLI-/GUI-Connection-Settings zeigen beide effektiven TLS-Werte und den getrennten Qualifikationsstatus unmittelbar am gewählten Ziel. Schema, Exporter, JSON/`.env`/Markdown, Connection-String-Erzeugung, Resolver, Prompt, Benutzerreferenz und Verbraucher zusammen aktualisieren. Der gewählte Modus bestimmt echte TLS-Booleans; nur im qualifizierten authentifizierten Modus gilt `trustServerCertificate = false`. Qualifikation an Zielidentität, Zertifikat, Client-/Treiber-/Trustkontext und Aktualität binden; bei Renewal, Namens-/Trust-/Kontextänderung invalidieren. Runtime-READY und TCP-Erreichbarkeit bleiben von TLS-Bereitschaft getrennt. Bestehende Labs und Standardexporte nicht automatisch umstellen. Plattform-/Versions-/Patch-/CU- und explizite Providerauswahl sowie Gruppensperre erhalten; kein Ersatz auf ein anderes bereites Ziel oder den einfachen Modus. |
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
   zum gewählten Modus widersprüchliche Boolean-Werte und Connection Strings
   sowie jede Discovery-/Overridevariante einschließlich Prompt. Sichere Werte und
   erhaltene Auswahl-/Gruppenregeln sind positiv belegt; unqualifizierte Ziele
   erhalten durch Flags oder Runtime-READY keinen authentifizierten TLS-Erfolg.
   Erstellung ohne Moduswahl verwendet `Encrypt=True;TrustServerCertificate=True`
   ohne eigene CA-/Client-Trusteinrichtung. Ausdrückliches `False` blockiert bei
   fehlender Qualifikation; keine automatische Umschaltung. API, Konsole,
   Browser, State und alle Exportformen geben dieselbe Wahl wieder.
   CLI und GUI zeigen in den Connection Settings ausdrücklich `Encrypt=True`
   und den effektiven Wert von `TrustServerCertificate`, ergänzt um die Bedeutung
   der Zertifikatsprüfung und deren gesonderten Qualifikationsstatus. Fehlende,
   veraltete oder widersprüchliche Daten dürfen keine erfolgreiche Prüfung
   vortäuschen; Anzeige und kopierter Connection String müssen übereinstimmen.
2. Im Modus mit Zertifikatsprüfung verbinden System.Data.SqlClient und genau
   der vom Toolbelt verwendete sqlcmd-/ODBC-Client mit geprüfter Kette und der
   exportierten Serveridentität, führen eine echte SQL-Abfrage aus und prüfen
   den verschlüsselten Transport. Ausführung auf dem SQL-Host allein genügt
   nicht. Client-/Treiberstand und tatsächliche Ausführungsidentität werden
   lokal nachvollziehbar gebunden, öffentlich nur bereinigt klassifiziert.
   Der Standard erhält einen getrennten positiven SQL-/Verschlüsselungsnachweis;
   am für Zertifikatsprüfung qualifizierten Ziel funktionieren beide
   Clientoptionen. Das belegt keine Zertifikatsprüfung des Standardmodus.
3. Nicht vertrauenswürdige Kette, falscher Servername und abgelaufenes
   Zertifikat scheitern im Modus mit Zertifikatsprüfung jeweils in **beiden**
   Clientstacks vor fachlicher SQL-Arbeit. Isolierte Negativfixtures verwenden,
   keine gemeinsam benutzten
   Zertifikate oder Trustanker für die Fehlererzeugung verändern. DNS-,
   TCP-/Runtime-, Authentisierungs- und Vertragsfehler getrennt berichten.
4. Mindestens folgende SQL-Zielkombinationen werden je tatsächlichem
   Windows-/Linux-Clientkontext und beiden Clientstacks qualifiziert. Docker,
   Podman und Hyper-V bleiben getrennte Evidence; unzutreffende Kombinationen
   nur mit begründeter Capabilitygrenze ausschließen, offene niemals grün werten.

   | SQL-Zielplattform | SQL Server 2019 | SQL Server 2022 | SQL Server 2025 |
   |---|---|---|---|
   | Windows / Hyper-V | `NOT_EXECUTED` | `NOT_EXECUTED` | Private SQL-2025-RTM-Referenz mit Windowsclients bestanden; öffentliche False-/Exportlane offen |
   | Linux / Docker und Podman getrennt | Windowsclients: je acht Fälle für CU32; Linuxclients: je neun Kryptofälle bestanden | Windowsclients: je acht Fälle für CU27; Linuxclients: je neun Kryptofälle bestanden | Windowsclients: je acht Fälle für CU9; Linuxclients: je neun Kryptofälle bestanden |

   Die [Linux-Kryptomatrix](../Quality/TLS_LINUX_CLIENT_MATRIX_ACCEPTANCE_2026-10-22.md)
   ergänzt getrennt je Provider und Profil neun Fälle mit 18 Clientergebnissen:
   16 strikt und zwei positive Bypasskontrollen ohne übergebenen CA-Trust.
   Trustentzug, falscher SAN, echter Ablauf und neues Leaf mit anderem Schlüssel
   sowie eigener Cleanup sind belegt. Docker und Podman bleiben an ihre
   verschiedenen Quellframes gebunden; keine erneute gemeinsame Native-Abnahme
   am finalen Integrationshead. Öffentliche Linux-Erstellung ohne eigene CA,
   Registry, Export und Consumer sind damit nicht abgenommen.

   Die [getrennten Container-Versionsbelege](../Quality/TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
   bleiben historische Kryptoproben. Die späteren öffentlichen Windows-Client-/
   Container-Lab-, V2-Export- und Neustart-/Rebind-Nachweise sind für SQL 2019 CU32,
   2022 CU27 und 2025 CU9 jeweils getrennt ausgeführt. Öffentliche Linux-
   Registry-/Export-/Consumerpfade und die vollständige Matrix bleiben offen;
   keine dieser Aussagen ersetzt die öffentliche Hyper-V-Lane oder die Consumer-Abnahme.

   Die spätere [Windows-V2-Consumer-Abnahme](../Quality/TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
   bestand für diese sechs Containerprofile zusätzlich den öffentlichen
   Reader, echten Toolbelt-Preflight und Verbindungen beider Stacks sowie
   die Ablehnung einer gefälschten Signatur vor SQL-Arbeit. Alle acht eigenen
   Labs einschließlich zweier erhaltener Fehlversuche sind entfernt.
   Linux-Verbraucher des öffentlichen V2-Pfads und die öffentliche Hyper-V-Lane
   bleiben offen.

   Die spätere [Linux-Trustdriftabnahme](../Quality/TLS_LINUX_SQL2025_TRUST_DRIFT_ACCEPTANCE_2026-10-17.md)
   bestand separat mit sechs strikten SqlClient-/ODBC-Fällen auf Docker/SQL 2025
   CU9 und vollständigem eigenem Runtime-Cleanup. Sie schließt nur positive
   Verbindung, Trustentzug und Wiederherstellung ein. Die neuere Linux-Kryptomatrix
   ergänzt Ablauf, neues Leaf und falschen SAN in sechs Zellen; öffentliche
   Registry und Export bleiben davon getrennt offen.

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
## CU-Metadatenbindung am 2026-10-17

Der lesende Diagnostic-/TLS-Zielmetadatenpfad erhält jetzt katalogisierte
Docker-/Podman-CU-Kurzbezeichner und exakte Tags als vollständige Runselektoren.
Der Reader bindet zusätzlich Basisjahr, exakten Katalogtag und Katalogbuild;
unbekannte CUs, widersprüchliche Tags und ein Jahresfallback bleiben gesperrt.
Dies ist ein synthetisch geprüfter Metadatenvertrag, keine nachträgliche
Qualifikation der früheren nativen CU-Fixtures. Linux-TLS, Hyper-V, operative
Registry, Exportcutover und vollständige Abnahme bleiben offen; SC-2026-045
bleibt gesperrt. Details im
[TLS-Zielmetadatenvertrag](../Architecture/AUTHENTICATED_TLS_TARGET_METADATA.md).

## TLS-001: operativer erster Pfad

Der nächste begrenzte Scope ergänzt öffentliche Windows-/Docker-/Podman-
Erstellung und V2-Export für SQL 2022 CU27 mit geschlossener Profilbindung.
Die getrennten nativen Docker-/Podman-Abnahmen bestanden je sieben Fälle,
sechs strikte Clientergebnisse und eigenen Cleanup. Die vollständige
TLS-001-Matrix und weitere Consumerkontexte bleiben offen. Container-Neustart/
Rebind und der begrenzte Windows-V2-Consumer-Cutover sind inzwischen getrennt
abgenommen; operative Zertifikatserneuerung und Recovery bleiben eigene Scopes.

Die zusätzliche öffentliche Windows-/Podman-SQL-2025-CU9-Lane ist implementiert:
ausdrückliche Providerwahl, eigene `0.2`-Bindung, frische Runtime-Herkunft und
providergebundener signierter V2-Export. Die native öffentliche Abnahme vom
2026-10-20 bestand sieben Fälle mit sechs strikten Clientergebnissen und
vollständigem eigenem Cleanup. Die fokussierten Prüfungen und betroffene
Regression sind grün; die erforderlichen PR-Gates bleiben Integrationsbedingung.
Frühere getrennte Podman-TLS-Nachweise werden nicht umgedeutet.

Der [operative Windows-/Docker-SQL-2025-CU9-Pfad](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md) mit bestehender CA-/Trustscopebindung, eigener SQL-Zertifikatsbindung, True/False-Anzeige und separatem qualifiziertem V2-Export ist implementiert und nativ geprüft. P1 bleiben die übrigen operativen Provider-/Client-/SQL-Kombinationen, V2-Consumer-Cutover und automatisches Renewal/Rebind. Die früheren Default-True/True-Nachweise sind davon getrennt und bleiben erhalten.
