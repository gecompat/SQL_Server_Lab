# Release Notes

## Stand 2026-07-21 – Welle 2 Betriebsdiagnosen

- Commit `8572c02ccec7b349d104ccf72a01489733fc03a7` hat Installer, alle 34 Release-Gate-Suiten, den Welle-2-Begleitvertrag und die Berechtigungsmatrizen auf [SQL Server 2019](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699638), [SQL Server 2022](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699733) und [SQL Server 2025](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699655) bestanden; das 2025-Gate enthält zusätzlich die Regex-Matrix.
- `OPS-003` erweitert `monitor.USP_CurrentIO` um das benannte Resultset `pendingIo`, zwei begrenzte Beobachtungen, Datei-/Scheduler-/Request-/Wait-Kontext, physische Pfade nur per Opt-in und eine ausdrücklich nicht kausale Einzelwertbewertung.
- `OPS-002` ergänzt `monitor.USP_WorkerPressureAnalysis`: Schedulerqueues, Workeraggregate, `THREADPOOL`, Blocking und begrenzte Requests bleiben getrennte Evidenz; ein Einzelindikator erzeugt keine Empfehlung für `max worker threads`.
- `OPS-001` ergänzt `monitor.USP_DatabaseConfigurationAnalysis` mit versionsadaptiven Datenbank-, Scoped-Configuration- und Query-Store-Werten. Lokale Variation und explizite Profilabweichung sind getrennt; das Modul führt keine Konfigurationsänderung aus.
- `OPS-004` ergänzt `monitor.USP_ErrorLogAnalysis` mit begrenzten SQL-Server- und optionalen Agent-Archiven, Kategorien und Zeitfenstern. Vollständige Meldungstexte und Agentzugriff sind Opt-in; Logrotation und operative Änderungen sind ausgeschlossen.
- Der Begleitvertrag `191_Wave2_Operational_Diagnostics_Runtime_Contract.sql` prüft Installation, Signaturen, NONE/JSON/TABLE/CONSOLE, eingeschränkte Rechte und kontrollierte synthetische Positivpfade innerhalb der bestehenden 26. Ausgabesuite. [Dokumentation/Nonblocking](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699523), [Datenschutz](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699628), [Commit-Messages](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699639) und der [Ausgabe-Pilot](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29817699554) sind ebenfalls grün.

## Stand 2026-07-21 – Welle 1 Ausgabe, XML und Provenienz

- Commit `fd0edabc811e5c5ffc2253da4196a95f6779e959` hat Installer, alle 34 Release-Gate-Suiten und die Berechtigungsmatrizen auf [SQL Server 2019](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091324), [SQL Server 2022](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091252) und [SQL Server 2025](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091262) bestanden; das 2025-Gate enthält zusätzlich die Regex-Matrix.
- `OUT-001` ist frameworkweit umgesetzt: große Textwerte bleiben intern `nvarchar(max)`, `0` hebt das sichtbare Limit auf, positive Limits kürzen UTF-16-surrogatsicher und melden je Zeile Ursprungslänge/Kürzungsstatus sowie höchstens eine Warnung je Aufruf.
- `DIAG-002` liefert valide Showplan-, Query-Store-, Deadlock- und Extended-Events-Payloads in RAW und TABLE nativ als `xml`; NULL, leere Quelle, ungültiges XML und das dokumentierte XML-Tiefenlimit bleiben unterscheidbar.
- `DIAG-006` und `DIAG-007` sind als verbindliche Provenienz-, Zeit-, Partialitäts-, Resultset-, TABLE-/JSON- und Drei-Versionen-Verträge in den betroffenen Modulen, Inventaren und Tests umgesetzt.
- `DIAG-001` ergänzt `monitor.USP_ServerVersionInformation` mit Produkt-, Build-, Branch-, Lifecycle- und Katalogstatus. Die Bewertung verwendet ausschließlich den mitgelieferten, auf den 21. Juli 2026 datierten Offline-Katalog; unbekannte oder neuere Builds werden nicht pauschal als veraltet bewertet.
- Der Begleitvertrag `190_Wave1_Output_Xml_Version_Runtime_Contract.sql` prüft Unicode-/Surrogatgrenzen, native XML-Typen, Provenienz und Offline-Buildbewertung innerhalb der bestehenden 26. Ausgabesuite. [Dokumentation/Nonblocking](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091316), [Datenschutz](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091274), [Commit-Messages](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091275) und der [Ausgabe-Pilot](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29812091243) sind ebenfalls grün.

## Stand 2026-07-21 – Welle 0 Release- und Evidence-Konsolidierung

- Commit `57ea12b81096dd4b10adb7ebb0fb4b6b5c65be45` hat Installer, alle 34 Release-Gate-Suiten und die Berechtigungsmatrizen auf [SQL Server 2019](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843161), [SQL Server 2022](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843138) und [SQL Server 2025](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843126) bestanden; das 2025-Gate enthält zusätzlich die Regex-Matrix.
- [Dokumentation und Nonblocking-Metadaten](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843203), [Repository-/ZIP-Datenschutz](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843157) und [einzeilige Commit-Messages](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29805843171) sind auf demselben Commit grün.
- `Metadata/Quality/Test_Matrix.csv` ist die kanonische maschinenlesbare Quelle für Release, Evidence-Commit, Suite-/Fallzahlen, Zielbuilds, Image-Digests und Actions-Verweise. Ein neuer statischer Vertrag gleicht Release-Gate-Detailmatrix, Release-Audit und aktuelle Statusdokumente dagegen ab.
- Die bestehenden Evidenzgrenzen bleiben unverändert: Feature-positive Windows-/Azure-MI-Zustände, kontrollierte Last, echter Failover, externe Restore-Nachweise und operative Mutationen sind durch die synthetischen Linux-Gates nicht bewiesen.

## Stand 2026-07-21 – Root-Blocker-Ketten und Tool-Hintergrundfilter

- `USP_CurrentBlocking` liefert die lesbare vollständige `BlockingChain` sowie
  Identität, Session-/Requeststatus, offene Transaktionen, letzte Requestzeiten
  und SQL-Textkontext des äußersten Root Blockers. Die Statementquelle
  unterscheidet aktiven Request, zuletzt bekannte Verbindung, nicht verfügbar
  und nicht angefordert.
- Sessionfilter wirken auf die bereits rekonstruierte Kette. Dadurch bleibt der
  Root-Kontext erhalten, wenn eine ausgewählte Session an beliebiger Stelle der
  Kette vorkommt.
- `@ToolHintergrundabfragenEinbeziehen=0` blendet erkannte Object-Explorer-,
  Copilot- und SQL-Prompt-Hintergrundaktivität in Sessions, Requests,
  Blocking-Blättern und aktuellen Waiting Tasks standardmäßig aus; Opt-in zeigt
  Regelcode, Kategorie, Erkennungsart und Konfidenz.
- Blocking bleibt kettenbewahrend: Ein Tool als Zwischen- oder Root-Blocker
  einer normalen Abfrage wird nicht entfernt. Nur eine erkannte Toolabfrage als
  blockiertes Blatt wird im Default unterdrückt.
- Die Erkennung ist über aktive `LIKE`-Muster in
  `monitor.ToolBackgroundQueryPattern` steuerbar. Framework-Seed, lokale
  Erweiterungen, Priorität und lokales Deaktivieren sind installerfest; die
  Klassifikation bleibt ausdrücklich eine Diagnoseheuristik.
- Installer, Overview-Weitergabe, JSON-/TABLE-Schemas, Resultset- und
  Parameterinventar, Beispiele, Architektur, Primärquellen und Integrationsgate
  sind auf den neuen Vertrag synchronisiert.

## Stand 2026-07-20 – vollständige Blocking-Ressourcensicht

- `USP_CurrentBlocking` klassifiziert und übersetzt Wait- und Lockressourcen
  jetzt begrenzt in Datenbank-, Objekt-, Index-, Partitions-, Datei-, Seiten-,
  Zeilen- und Metadatenkontext; die unveränderten Rohwerte und nativen IDs
  bleiben immer erhalten.
- `@BlockingObjektTiefe` trennt `NONE`, den ressourcenschonenden Default
  `STANDARD` und den gruppengeschützten Pfad `DEEP`. Das Kandidatenlimit ist
  über `@MaxObjektAufloesungen` zwischen 1 und 1000 steuerbar; beide Parameter
  werden auch von `USP_CurrentOverview` an das Blockingmodul durchgereicht.
- `DEEP` liest `sys.dm_tran_locks` ausschließlich für Sessions erkannter
  Blockingketten. Alle gelieferten Locktypen werden ausgegeben; bekannte Typen
  werden bestmöglich aufgelöst, unbekannte und interne Typen transparent als
  `RAW_ONLY` oder `PARTIAL` ausgewiesen.
- Negative SQL-Server-Blocker-IDs `-2` bis `-5` werden als DTC-, Recovery- oder
  Latch-Owner beschrieben. Nach dem materialisierten Kern-Snapshot wird jeder
  deduplizierte Anreicherungskandidat einzeln mit `LOCK_TIMEOUT 0` verarbeitet.
  Ein Metadatenlock markiert deshalb nur diesen Kandidaten als `TIMEOUT`; rohe
  Ressource und native IDs sowie alle übrigen Bereiche bleiben erhalten.
- Objekt-, Schema-, Index-, Partitions- und Statistiknamen werden direkt aus den
  `sys.*`-Katalogsichten gelesen. Blockierungsanfällige Metadatenfunktionen wie
  `OBJECT_ID()` und `OBJECT_NAME()` werden auch für bekannte TempDB-Objekt-IDs
  nicht verwendet. Separate Meta-Zähler weisen partielle, rohe, abgewiesene,
  zeitüberschrittene, fehlerhafte und limitbedingt ausgelassene Kandidaten aus.
- Das additive Blocking-Resultset und der JSON-Vertrag verwenden Schema-Version
  2; Parser-, Installer-, Inventar- und Dokumentationsverträge sind synchronisiert.

## Stand 2026-07-20 – vertiefter Wait-Type-Katalog `1.1.0-special.12`

- Alle 347 kuratierten Wait Types beantworten zusätzlich Einordnung,
  Begründung, häufige Ursachen, mögliche Wirkung, Gegenbeweise,
  Minderungsansätze, verwandte Waits und Messhinweise. Seltene interne Waits
  bleiben ausdrücklich als begrenzte Evidenz gekennzeichnet.
- Die bisher gemeinsame `SourceReference` bleibt ausschließlich der Beleg für
  offizielle Namen und Kurzdefinitionen. Die neue normalisierte
  `WaitTypeCatalogSource` trennt Definition, Messmethodik, Interpretation sowie
  Diagnose/Minderung und nennt die jeweils unterstützten Felder.
- Jeder Framework-Wait besitzt mindestens vier typisierte Quellen; acht
  besonders entscheidungsrelevante Waits erhalten eine zusätzliche exakte
  Diagnosequelle. Der Seed umfasst damit 1.396 Quellenzuordnungen und mehr als
  zwanzig unterschiedliche Quellziele.
- `TVF_WaitTypeInfo` liefert die neuen Analysefelder und die Quellenanzahl;
  `TVF_WaitTypeSources` gibt exakte Quellen aus und kennzeichnet bei neuen,
  unbekannten Waits einen generischen Quellenfallback transparent.
- Installer, Frameworkvertrag, Smoke-Test, Inventar, Evidenzdatei,
  Betriebsdokumentation und Offline-Validator sind synchronisiert. Der
  Validator verhindert insbesondere eine Rückkehr zu einer einzigen
  pauschalen Quelle.

## Stand 2026-07-20 – SSMS-Installationsanleitung

- Die Installationsreferenz führt nun vollständig durch Repositorydownload,
  Versions- und Collationprüfung, Datenbankanlage, Erzeugung und Ausführung des
  eigenständigen Installers, Smoke-Test, Berechtigungsprüfung, ersten Aufruf,
  Upgrade und typische Fehlerbilder.
- Für SSMS ist der eigenständige Installer als robuster Standardweg dokumentiert;
  der SQLCMD-Include-Installer bleibt als Alternative für Entwicklung und
  Automatisierung erhalten.
- Der alternative SSMS-SQLCMD-Weg beschreibt nun ebenfalls den vollständigen
  Ablauf von der getrennten Arbeitskopie und repositoryweiten
  Platzhalterersetzung über Modus- und Include-Kontrolle bis zu Smoke-Test und
  Fehlerdiagnose. `Install_All.sql` beendet den Include-Lauf mit
  `:ON ERROR EXIT` beim ersten SQL-Fehler.

## Stand 2026-07-20 – Deep-Analysis-Authoring konsolidiert

- Die 84/84-Drafts bleiben als nicht kanonisches Authoring-Archiv erhalten; veraltete Zukunfts- und Offen-Markierungen sind durch Abschlussstand und klare erneute Rechercheauslöser ersetzt.
- `USP_CurrentWaits` und `USP_QueryStoreWaitStats` verweisen ausschließlich auf kanonische Grundlagen- und Familienguides.
- Eine neue Versions-/Primärquellenmatrix verbindet SQL Server 2019, 2022 und 2025, Compatibility-/Berechtigungsgrenzen und feature-positive Evidenzlücken mit offiziellen Microsoft-Quellen.
- Der neue externe Linkvalidator prüft URL-Struktur repositoryweit und blockiert dauerhafte HTTP-404-/410-Ziele im Analysis-Guide-/Quellenscope; transiente Fremdsystemfehler bleiben nicht blockierende Warnungen.
- Beim ersten vollständigen Lauf wurden veraltete Microsoft-Learn-Pfade für Execution-, I/O-, Statistics-, Index-, Plan-, PVS-, Query-Store-, Thread-/Task- und HADR-Quellen korrigiert.

## Stand 2026-07-20 – SC-023 Snapshot- und Baseline-Design freigegeben

- Der Architekturentscheid für eine separate, konfigurierbar benannte Snapshot-Datenbank je SQL-Server-Instanz ist freigegeben; die Implementierung bleibt bis zu einem eigenen Auftrag zurückgestellt.
- Typisierte Konfiguration, Sammler- und Retentionrichtlinien ersetzen ein verpflichtendes allgemeines Key-Value-Modell. Normalisierte Metriken werden mit vollständigen versionierten Payloads kombiniert.
- Granularität, Schedulervertrag, laufinterne Quellenwiederverwendung, Reset-Epochen, Partialität, Retention, Größenbudget, Purge, Löschung und Exportdefaults sind verbindlich dokumentiert.
- Die betriebliche Snapshot-Datenbank darf vollständige reale Frameworkausgaben speichern. Ausschließlich Repository-, GitHub-, Test-, Dokumentations- und Downloadartefakte bleiben auf synthetische Daten begrenzt.
- MANUAL, EXTERNAL und SQL_AGENT verwenden denselben schedulerneutralen Procedure-Einstieg; das Paket erstellt selbst keinen Agentjob. Ein anonymisierter Export bleibt ein separates Folgevorhaben.

## Stand 2026-07-21 – erster SC-023-Persistenz-Slice implementiert

- Zwei getrennte, idempotente Installer halten `Install_All.sql` zustandslos und installieren die Framework- beziehungsweise Zielseite nur nach ausdrücklicher Auswahl.
- `USP_ConfigureSnapshotTarget`, `USP_RunSnapshotCollectionCycle` und `USP_PurgeSnapshotData` bilden Konfiguration, schedulerneutralen Lauf und begrenzte Retention ab; das Paket erstellt keine Datenbank, Rechte oder Agentjobs.
- Genau ein Performance-Counter-Collector persistiert Raw- und interpretierte Samples mit UTC-, Partialitäts- und Reset-Epochenvertrag. Payloadpersistenz ist standardmäßig aus und bei Aktivierung verlustfrei komprimiert und gehasht.
- No-wait-Applock, Due-Prüfung, child-first Batch-Purge und `PURGE_EXPIRED_THEN_STOP` verhindern parallele Doppelreads und das stille Löschen frischer Evidenz.
- Der separate [SQL-Server-2019-/2022-/2025-Workflow](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29860488769) ist auf Commit `c4e2ee6114b7de9cae9236d390a93a81e78599e9` grün; der erste Slice steht auf `IMPLEMENTED_ACTIONS_GATE`. Alle Repositoryfixtures sind synthetisch.

## Stand 2026-07-19 – laufinterne Wiederverwendung von Analyseergebnissen

- `USP_ServerHealthAnalysis` erhebt Integritäts-, Kapazitäts- und Buffer-Pool-Evidenz nur einmal und reicht die Resultate im selben Lauf an `USP_DiagnosticFindings` weiter.
- `InvocationStatus=REUSED_PARENT_RESULT` macht die Wiederverwendung sichtbar; partielle Parent-Evidenz bleibt partiell.
- Ein eigenständiger `USP_DiagnosticFindings`-Aufruf liest weiterhin frisch. Es entsteht kein sitzungs- oder aufrufübergreifender Cache.
- Der Laufzeitvertrag prüft nun sechs Findings-Fälle, darunter Parent-Reuse und Standalone-Frischlesung.
- `USP_PlanCacheAnalysis` materialisiert `sys.dm_exec_query_stats` bei mindestens zwei aktiven Consumern einmalig; Query Stats, Query Hash und die Showplan-Kandidatenauswahl verwenden denselben laufgebundenen Stand.
- Ein einzelner Plan-Cache-Consumer und jeder direkte Child-Aufruf lesen weiterhin frisch. `READPAST` wird nicht verwendet; ein gescheiterter gemeinsamer Read führt zum isolierten Frischlese-Fallback.

## Stand 2026-07-20 – frameworkweiter Ausgabe-Vertrag 2.0

- Alle 82 öffentlichen Analyse-Procedures akzeptieren ausschließlich die benannte TABLE-Zuordnung `@ResultTablesJson`; der frühere Einzelzielparameter ist entfernt.
- CONSOLE liefert je Procedure im Normalfall ein fachliches Grid und bei leerer Fachmenge genau eine verständliche Zeile; technische Meta-Grids und leere Details werden unterdrückt.
- Der gemeinsame Preflight lehnt unbekannte Resultsetnamen, doppelte Ziele und ungültige Temp-Tabellen vor dem fachlichen Systemzugriff ab.
- `USP_CurrentOverview` materialisiert jedes Child genau einmal und verwendet dessen expliziten Status-, Partialitäts- und Zeilenvertrag für Summary, Details, JSON und TABLE.
- Globale Temp- und permanente Tabellen, gefüllte Ein-Spalten-Tabellen, sonstige Schemaabweichungen sowie nicht sicher reproduzierbare Typen werden kontrolliert abgelehnt.
- Alle in Procedures und Tests erzeugten lokalen Temp-Tabellen tragen einen objektbezogenen Namen; die gemeinsamen Auswahl-Helper erhalten die konkreten Namen als Parameter.
- Katalogzugriffe verwenden projektweit `WITH (NOLOCK)` und `LOCK_TIMEOUT 0`; potenziell blockierende Metadatenfunktionen sind durch direkte `sys.*`-Abfragen oder einen expliziten Nicht-verfügbar-Status ersetzt. Ein statischer Gate schützt den Vertrag.
- `Metadata/Inventory/ResultSets.csv` inventarisiert alle 94 TABLE-exportierbaren Resultsets einschließlich stabiler Namen und geordneter nativer Schemas.
- Die Suiten 187 bis 189 prüfen Writer, Pilot und frameworkweiten Ausgabe-Laufzeitvertrag synthetisch auf SQL Server 2019, 2022 und 2025.
- Commit `53fe82d57e6d3d53b5a16ec1c220ccb98c2050f8` hat Installer, alle 34 Release-Gate-Suiten, Berechtigungsmatrizen und die zusätzliche SQL-Server-2025-Regex-Matrix bestanden: [2019](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29738745942), [2022](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29738745932), [2025](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29738746060).

## Stand 2026-07-19 – integrierte technische Analyse-Guides

- Die sieben technischen Vertiefungsfelder aus den Familien-Drafts sind in alle 84 kanonischen Procedure-Seiten übernommen.
- Ein gemeinsames Execution-, Zeit- und Evidenzmodell zentralisiert Beobachtungsarten, Session-/Request-/Taskbezug, Workerzustände, Waitformel, Gegenproben und Änderungsgrenzen.
- Der statische Dokumentationsvertrag erzwingt die 84/84-Abdeckung, alle Vertiefungsfelder und den Link auf das gemeinsame Grundlagenmodell.
- Die Authoring-Drafts bleiben als nicht kanonischer Redaktionsnachweis erhalten und sind eindeutig als integriert markiert.
- SC-002 bis SC-010 sind mit der vorhandenen Drei-Versionen-Actions-Evidenz auf `IMPLEMENTED_ACTIONS_GATE` abgeglichen.
- Das versehentlich versionierte Python-Cacheartefakt wurde entfernt; `.gitignore` verhindert neue `__pycache__`-/`*.pyc`-Artefakte.
- Die bestehende synthetische Credential-Erzeugung des Statistics-Evidence-Workflows ist nun präzise regel-, pfad- und hashgebunden in der Datenschutz-Allowlist erfasst.

## Stand 2026-07-18 – vollständige P2-Evidenz und 31-Suite-Gate

- Commit `40d54fdc195b5cfa0015e2cbe281da595e427ab0` hat den vollständigen 31-Suite-Vertrag auf SQL Server 2019, 2022 und 2025 bestanden.
- Die 115 zuvor offenen P2-Zeilen sind als `PASS_WITH_LIMITATIONS` dokumentiert; damit besitzen alle 181 Spezialfallzeilen Evidence.
- Feature Inventory, XTP, Temporal, Service Broker, Full-Text, Data Capture, Encryption und Maintenance besitzen jeweils eine eigene Laufzeitsuite.
- Reale Nutzdaten, Payloads, Secrets, Credentials, SQL-/Jobtexte und Umgebungsbezeichner werden nicht in Repositoryartefakte übernommen.
- Full-Text-DDL auf Linux, feature-positive Windows-/Azure-MI-Zustände, Lasttests, echter Failover und externe Restorebeweise bleiben separate Evidence-Klassen.

## Stand 2026-07-18 – Verschlüsselung, Wartung und Drei-Versionen-Gate `1.1.0-special.9`

- `SC-020` durch `monitor.USP_EncryptionAnalysis` implementiert: TDE-Zustand/Scan, sichtbarer Zertifikatlebenszyklus, getrennte explizite Backupverschlüsselung sowie aggregierte Always-Encrypted-/Ledger-Anzahlen.
- Keine Schlüsselpfade, Signaturen, verschlüsselten Werte, Backupmedien, Konten oder privaten Schlüssel; Thumbprints werden nicht ausgegeben. Lokaler Exportzeitpunkt und Zertifikatablauf bleiben begrenzte Lebenszyklusevidenz.
- `SC-022` durch `monitor.USP_MaintenanceOperations` implementiert: resumierbare Indexoperationen, technische Wartungsrequests, SQL-Server-2022+-PVS-Details und nur explizit gefilterte Agentaktivität.
- Keine SQL-Texte, Jobschritte/-befehle, Meldungen, Konten, Clientdaten oder Wait-Ressourcen; keine Resume-, Abort-, Kill-, Cleanup-, Jobstart- oder Jobstop-Aktion.
- `168_Special_Case_Runtime_Contract.sql` führt alle P2-Module gegen die synthetische Testdatenbank aus und validiert Status und JSON.
- `169_P0_Runtime_Contract.sql` führt 15 Positiv-, Leer-, Grenz- und Resetfälle mit generischen DBCC-, Dateioptions-, Performance-Counter- und XE-Fixtures aus. `INT-DENIED` und `CAP-DENIED` laufen in der versionsspezifischen Berechtigungsmatrix unter einem tatsächlich eingeschränkten synthetischen Serverlogin; alle 17 P0-Fälle sind automatisiert und commitbezogen auf drei Versionen nachgewiesen.
- Der neue Page-Detail-Positivfall hat eine ungültige Altannahme offengelegt: `sys.dm_db_page_info` liefert `alloc_unit_id`, aber keinen `alloc_unit_type_desc`. `USP_DatabaseIntegrityAnalysis` gibt deshalb die dokumentierte `AllocUnitId` aus, ohne einen Typ zu erfinden.
- Die echten Restricted-Login-Fälle haben eine sicherheitsgefilterte Leere offengelegt: Integritäts- und Kapazitätsanalyse kennzeichnen fehlendes `VIEW SERVER STATE` beziehungsweise `VIEW SERVER PERFORMANCE STATE` nun ausdrücklich als `AVAILABLE_LIMITED` und `IsPartial=1`; zulässige Resultset-Inhalte bleiben unverändert.
- Eine Instanz ohne aktivierte oder ohne auswertbare Nicht-Basis-Zeilen in `sys.dm_os_performance_counters` wird nun ausdrücklich als `UNAVAILABLE_OBJECT` und partiell behandelt; der P0-Vertrag akzeptiert diesen dokumentierten Umgebungszustand nur dann, wenn keine Snapshot- oder Ratenwerte erfunden werden.
- SQL Server 2025 hat gleich benannte Counteridentitäten mit unterschiedlichen `cntr_type`-Werten offengelegt. Der Sampling-Schlüssel umfasst nun den Typ, exakt identische DMV-Zeilen werden dedupliziert und Vorher/Nachher werden nie über verschiedene Typen korreliert.
- Commit `ffb95bd57c8e08300410ad268a92cc5379ee45f7` hat den 14-Suite-Vertrag einschließlich 16 automatisierter P0-Fälle auf SQL Server 2019, 2022 und 2025 bestanden. `PC-RESET` bleibt als einziger P0-Fall für einen kontrollierten Neustart zwischen zwei Samples offen.
- `PC-RESET` verwendet mit `monitor.TVF_InterpretPerformanceCounter` denselben extrahierten Rechenpfad wie die DMV-Auswertung. Ein synthetisch fallender Counter liefert `COUNTER_RESET_DURING_SAMPLE` und `MetricValue=NULL`; Commit `7e3ba1a4e2fa79761c2daf24bee23dd73feed297` hat diesen Vertrag auf SQL Server 2019, 2022 und 2025 bestätigt.
- P1 beginnt mit einer fünfzehnten Release-Gate-Suite: SQL Server 2019 grenzt PSP/OPPO-Kataloge ab, SQL Server 2022+ prüft PSP bei Compatibility Level 160, SQL Server 2025 prüft OPPO bei Level 170 und alle Targets prüfen Query Store OFF. Datenbankoptionen werden wiederhergestellt; Commit `0efeb1877ffa6b31fc8deb714ac7659b40db7cd6` hat alle vier Fälle auf den vorgesehenen Versionen bestätigt.
- Drei Actions-Gates erzwingen SQL Server 2019/2022/2025, Compatibility Level 150/160/170, case-sensitive Collation, Installer, 15 Suiten und synthetische Berechtigungsfälle.
- Die sechzehnte Suite deckt Contention-Delta, kumulative Kennzeichnung, Counterreset und den begrenzten opt-in-Page-Detail-Pfad ab. `monitor.TVF_InterpretContentionCounter` ist der gemeinsame reine Rechenpfad für deterministische Delta-/Rate-/Resetverträge; Commit `e26f246e7b9e21b2d882ac69feaa32fb3f5f36c9` hat die Suite auf SQL Server 2019, 2022 und 2025 bestätigt.
- Mehrfach vorkommende technische Latchklassen und Spinlocknamen werden vor dem Samplevergleich aggregiert. Damit bleibt die temporäre Identität eindeutig und Zähler verschiedener gleich benannter DMV-Zeilen werden nicht willkürlich gegeneinander verglichen.
- Der interne `WAITFOR DELAY`-Wert verwendet das von SQL Server akzeptierte technische Zeichenformat `hh:mm:ss`; ein zuvor verwendeter `time`-Wert führte reproduzierbar zu Fehler 9815.
- Nach sporadisch vollständig verlorenen kurzen Event-Bursts verteilt `EV-SEVERE` nun zwanzig kontrollierte Ereignisse zeitlich und verwendet längere Dispatch-/Flushfenster vor und nach dem Sessionstop. `error_reported` bleibt wegen der SQL-Server-2019-Vertragsgrenze im zulässigen Single-Event-Loss-Modus; der Test bleibt auf das generische synthetische Event und die kurzlebige XEL-Datei begrenzt.
- Die kontrollierten Severity-16-Ereignisse verwenden den klassischen `RAISERROR`-Pfad und prüfen die generische Fehlernummer 50000; dies vermeidet versionsabhängige Unterschiede bei abgefangenen `THROW`-Ereignissen.
- Die siebzehnte Suite deckt leichten Speicherbaselinepfad, bedingte Pressure-Findings, einen strukturell vollständigen Resource-Semaphore-Snapshot und den ausdrücklich aktivierten, begrenzten Buffer-Descriptor-Scan ab. Veränderliche Semaphore-Zähler werden innerhalb der erfassten Momentaufnahme validiert und nicht durch einen zeitlich späteren DMV-Read verglichen. Commit `d9d7c5bb4ffb5b9b408c1781718364d5c7ac89a8` hat die Suite auf SQL Server 2019, 2022 und 2025 bestätigt; künstlicher Speicherdruck und Grant-Waiter wurden nicht erzeugt.
- Die achtzehnte Suite automatisiert fehlende Full-Evidenz, eine nicht mehr zur neuesten Fullbasis passende Differentialzeile, eine kontrolliert sichtbare Logkettenlücke und fehlende Restorehistorie. Sie verwendet nur die synthetische Testdatenbank und eine generisch benannte Datei im Default-Backupverzeichnis des disposable Targets, bereinigt die kurzlebige `msdb`-Historie, stellt das Recovery Model wieder her und führt bewusst keinen Restore aus. Commit `f3d9c014adb3227ab39e21e16052dca7285a6a87` hat die Suite auf SQL Server 2019, 2022 und 2025 bestätigt.
- Die neunzehnte Suite automatisiert nicht vertrauenswürdige Constraints, fehlende FK-Stützindizes, exakt gleiche Indexdefinitionen und hohen Identity-Typwertebereichsverbrauch. Alle generischen DDL-Fixtures werden im Erfolgs- und Fehlerpfad ausdrücklich entfernt. Commit `c405946d7806472f42cfc38430d5ada33620780c` hat die Suite auf SQL Server 2019, 2022 und 2025 bestätigt.
- Die zwanzigste Suite automatisiert acht Statistikverteilungsfälle mit begrenzten synthetischen FULLSCAN-Histogrammen: gleichmäßig, dominant, Tail-konzentriert, geändert, gefiltert, inkrementell, kandidatenseitig begrenzt und `CATALOG_DEEP`-verweigert. Commit `f4bf1d4333e7f4a38814dea72a0799ca1d949364` hat die Suite auf SQL Server 2019, 2022 und 2025 bestätigt. Die Auswertung bleibt Indikator und führt weder Statistikupdates noch Benutzerdaten-Scans aus.
- Die einundzwanzigste Suite automatisiert vier Availability-Fälle. HADR-Abwesenheit wird real geprüft; Suspend-, Queue- und Seedingzustände verwenden dieselben reinen Klassifikationsfunktionen wie die Procedure. Commit `bdb8f66e20f015e7c563e6d3747144400897b281` ist auf SQL Server 2019, 2022 und 2025 grün.
- Die zweiundzwanzigste Suite automatisiert vier Agent-/Alert-Fälle, ohne Agent- oder `msdb`-Objekte anzulegen oder zu verändern. Keine Adress-, Mail-, Jobschritt- oder Meldungsinhalte werden gelesen.
- Die dreiundzwanzigste Suite automatisiert sechs normalisierte Findings-Fälle: Feld-Whitelist, partielle Child-Evidenz, opt-in Defaults, Parent-Reuse, Standalone-Frischlesung und Compatibility-Gate. Synthetischer Benutzer und Compatibility Level werden in Erfolgs- und Fehlerpfad bereinigt.
- Der erste materialisierte Duplicate-Index-Fall hat eine Spaltenzahlabweichung im produktiven Befund-INSERT offengelegt. Tabellenobjekt und beide Indexbezüge werden nun den elf vorgesehenen Feldern eindeutig zugeordnet; technische Testdiagnosen geben weiterhin nur die Fehlernummer und keinen Meldungsinhalt aus.
- Die drei Linux-Gates lösen den öffentlichen `*-latest`-Pull-Tag in einen validierten unveränderlichen Image-Digest auf, starten exakt diesen Digest und erfassen `SERVERPROPERTY('ProductVersion')`; Build und Digest werden als rein technische Evidence dokumentiert.
- Das SQL-Server-2025-Gate hat den Regex-Prädikatvertrag gehärtet: `REGEXP_LIKE(...)` und `NOT REGEXP_LIKE(...)` ersetzen repositoryweit unzulässige Vergleiche mit `0` oder `1`; ein statischer Check schützt vor Regression.
- Die Regex-Matrix meldet konsistent zehn Verträge. Der statische Check ist nun ein eigenständiger Validator mit acht generischen Selbsttests, erkennt mehrzeilige Fehlformen und gibt bei einem Fund keinen Quellzeileninhalt aus.
- Ein eigenes Actions-Gate erzwingt für neue Pull-Request- und Main-Commits exakt einzeilige Commit Messages, ohne historische Nachrichten umzuschreiben oder den Message-Inhalt in Fehlmeldungen auszugeben.
- SQL Server 2025 meldet fehlendes `VIEW SERVER PERFORMANCE STATE` zusätzlich mit Fehler 371. Alle isolierten Berechtigungsfehler-Zuordnungen behandeln ihn kontrolliert als `DENIED_PERMISSION`; ein statischer Check schützt die vollständige Zuordnung.
- SC-023 besitzt inzwischen den separat installierbaren ersten Performance-Counter-Slice; weitere Sammler und Rollups bleiben offen. SC-024/SC-025 besitzen sichere Schnittstellenverträge beziehungsweise ein externes Runbook, benötigen aber weiterhin externe autorisierte Infrastruktur oder Ziele.

## Stand 2026-07-18 – Data-Capture-/Replikations-Deep-Dive `1.1.0-special.8`

- `SC-019` durch `monitor.USP_DataCaptureDeepAnalysis` als sechstes P2-Modul implementiert.
- Change Tracking bewertet `MinValidVersion` nur gegen einen explizit gelieferten Consumer-Wasserstand. Ohne Wasserstand wird kein Synchronisationsverlust behauptet; ein Wasserstand unter dem Minimum erzeugt einen hochkonfidenten Reinitialisierungsbefund.
- CDC-Capture-Instanzen, Drop-Pending, älteste verfügbare Zeitgrenze, Scan-Aggregat/neueste Sitzung, gruppierte Fehler und Capture-/Cleanup-Jobs sind isolierte read-only Quellen.
- Kontinuierliches und zeitgesteuertes CDC erhalten unterschiedliche Latenzeinordnung. Retention plus Cleanup-Toleranz bleibt eine Heuristik mit Workload- und Timinggrenze.
- Lokale Distribution-, Log-Reader- und Merge-Agenten werden mit aggregiertem Rückstand, neuester History, Subscription-Status, Konflikten und Retries ausgewertet.
- Remote oder unzugängliche Distributor-Topologien werden als Evidenzlücke und niemals als gesunder Zustand behandelt. Inaktive Subscription oder Fail/Retry beweisen für sich keine notwendige Reinitialisierung.
- Keine Change-Zeilen, Replikationsbefehle, Kommentare, Fehlertexte, LSNs, Credentials, Agentjob-Commands, Konfliktzeilen oder DDL.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenzen, Analysehandbuch, Backlog und 25 neue Spezialfalltestfälle synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; der dokumentierte synthetische Vorgängerlauf umfasst `SC-019` nicht.

## Stand 2026-07-18 – Full-Text-Deep-Dive `1.1.0-special.7`

- `SC-018` durch `monitor.USP_FullTextAnalysis` als fünftes P2-Modul implementiert.
- Sichtbares Feature-Gate aus Full-Text-Komponentenstatus, Katalogen, Indizes und semantischen Indexspalten; bei negativem sichtbarem Scope werden keine abhängigen Laufzeitquellen aufgerufen.
- Kataloge und Indizes liefern Enablement, eindeutigen Schlüsselindex, Change Tracking, Crawl-Kontext, Spalten-/Semantikanzahl und aggregierte Fragmentevidenz ohne Tabelleninhalt oder Schlüsselwerte.
- Aktuelle Populationen, ausstehende Batches und semantische Ähnlichkeitspopulation werden als getrennte best-effort Quellen behandelt. Leere DMVs sind weder Historie noch Abschlussnachweis.
- Batches werden ohne Batch-IDs, Speicheradressen oder Inhalte nach Fehlercode und Retryzustand aggregiert; Dokumentfehler werden nur gezählt.
- Querybare Fragmente mit Status 4 oder 6 werden gezählt und größenmäßig aggregiert. Fragment-, Batch-, Laufzeit- und Größenwerte bleiben konfigurierbare Heuristiken ohne universellen Grenzwert.
- Full-Text-Memory-Pools und FDHosts liefern serverweiten Kontext; FDHosts werden ohne Hostnamen oder Prozess-IDs nach Typ aggregiert.
- Kein Zugriff auf Keywords, Stopwords, Parser-Eingaben, Crawl-Logs oder Pfade; kein `ALTER FULLTEXT`, kein Populationstart und keine Reorganisation.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenzen, Analysehandbuch, Backlog und Spezialfalltestmatrix synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; die statische Implementierung ist keine Zielsystemfreigabe.

## Stand 2026-07-18 – Service-Broker-Deep-Dive `1.1.0-special.6`

- `SC-017` durch `monitor.USP_ServiceBrokerAnalysis` als viertes P2-Modul implementiert.
- Sichtbares Feature-Gate aus Datenbankschalter, benutzerdefinierten Queues und Services; negativer Scope ruft keine abhängigen Broker-Quellen auf und bleibt ausdrücklich kein vollständiger Abwesenheitsbeweis.
- Queue-Schalter, Aktivierungskonfiguration, Service-Zuordnungsanzahl und approximative Nachrichten-/Speicherwerte werden ohne Zugriff auf Queue-Nutzdaten ermittelt.
- Queue-Monitor und aktivierte Tasks sind getrennte, isolierte Server-DMV-Quellen; fehlende Rechte reduzieren nicht die zugängliche Katalog-, Transmission- oder Conversation-Evidenz.
- `sys.transmission_queue` wird ausschließlich nach nicht-payloadhaltigen Metadaten, Alter und Status gruppiert. Nachrichtenkörper und Conversation-Handles werden nicht referenziert.
- Conversation Endpoints werden nur nach Zustand, Initiator-/Systemflag und Lifetime aggregiert; Gruppen-IDs, Schlüsselkennungen und Nachrichteninhalt bleiben ausgeschlossen.
- RECEIVE-OFF kann Folge automatischer Poison-Message-Erkennung nach wiederholten Rollbacks oder manueller Konfiguration sein. Das Modul meldet deshalb einen Prüfhinweis und keine bewiesene Poison Message.
- Kein `RECEIVE`, keine Queue-Änderung, kein `END CONVERSATION` und keine automatische Routing-, Aktivierungs- oder Kapazitätsmaßnahme.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenzen, Backlog und Spezialfalltestmatrix synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; die statische Implementierung ist keine Zielsystemfreigabe.

## Stand 2026-07-17 – Temporal-Tables-Deep-Dive `1.1.0-special.5`

- `SC-016` durch `monitor.USP_TemporalAnalysis` als drittes P2-Modul implementiert.
- Negatives Feature-Gate ruft keine abhängigen Quellen auf und bleibt auf den sichtbaren Metadatenscope begrenzt.
- Current-/History-Zuordnung, SYSTEM_TIME-Periodenspalten und datenbank-/tabellenweite Retention-Konfiguration werden aus `sys.tables`, `sys.periods`, `sys.columns` und `sys.databases` ermittelt.
- Approximative Zeilen- und Größenwerte stammen ausschließlich aus `sys.dm_db_partition_stats`; Current- und History-Zeilen werden nicht gelesen.
- Ein aktiver sichtbarer B-Tree-History-Index mit führendem Periodenende und Periodenstart wird als dokumentierte Baseline geprüft. Das Ergebnis ist kein automatischer DDL-Vorschlag und kein universelles Workload-Optimum.
- Endliche Retention bei deaktiviertem datenbankweitem Cleanup erzeugt einen Konfigurationshinweis. Der Schalter beweist weder Cleanup-Ausführung noch -Fortschritt.
- Periodenüberlappungen und sonstige Datenkonsistenz werden ohne Zeilenscan oder `DBCC CHECKCONSTRAINTS` nicht behauptet. Nach `SYSTEM_VERSIONING=OFF` getrennte Tabellen werden ohne erhaltene Zuordnung nicht erraten.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenzen, Backlog und Spezialfalltestmatrix synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; die statische Implementierung ist keine Zielsystemfreigabe.

## Stand 2026-07-17 – In-Memory-OLTP-Deep-Dive `1.1.0-special.4`

- `SC-015` durch `monitor.USP_InMemoryOltpAnalysis` als zweites P2-Modul implementiert.
- Feature-Gate aus sichtbaren speicheroptimierten Tabellen, Tabellentypen und `MEMORY_OPTIMIZED_DATA`-Dateigruppen; negativer sichtbarer Scope bleibt ausdrücklich kein Abwesenheitsbeweis.
- Tabellen-/Indexspeicher, XTP-Memory-Consumer, Hashindexkatalog, Checkpointzustände, aktive Transaktionen und Resource-Governor-Poolkontext als getrennte best-effort Quellen integriert.
- Die potenziell vollständige Tabellen scannende Hashindex-Laufzeit-DMV ist standardmäßig deaktiviert und benötigt zusätzlich `CATALOG_DEEP`.
- Bucket-Leeranteil und Kettenlängen erzeugen nur konfigurierbare Prüfhinweise. Duplikate, Verteilung und Abfrageprädikate müssen vor jeder DDL-Entscheidung separat geprüft werden.
- Checkpointzustand `WAITING FOR LOG TRUNCATION`, aktive Transaktionsmenge und Poolauslastung werden nur als Momentaufnahme mit Gegenprüfung ausgewiesen; der Defaultpool wird nie einer Datenbank als Druckbefund zugerechnet.
- Keine Benutzertabellendaten, Moduldefinitionen, SQL-Texte, Checkpoint-Pfade, GUIDs, Session-, Benutzer- oder Transaktionskennungen werden gelesen.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenzen, Backlog und Spezialfalltestmatrix synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; die statische Implementierung ist keine Zielsystemfreigabe.

## Stand 2026-07-17 – Beginn P2 `1.1.0-special.3`

- `SC-021` durch `monitor.USP_SpecialFeatureInventory` als erstes P2-Modul implementiert.
- 18 Featureklassen werden je ausgewählter Datenbank ausschließlich aus aggregierten, sichtbaren Systemkatalogen als `DETECTED`, `CONFIGURED_ONLY`, `NOT_DETECTED_VISIBLE_SCOPE`, `UNAVAILABLE_VERSION` oder `SOURCE_UNAVAILABLE` klassifiziert.
- Capability und Nutzung getrennt: Das vorhandene `USP_ServerFeatureCapabilities` bleibt für Plattformverfügbarkeit zuständig; die neue Procedure inventarisiert sichtbare Verwendung und empfiehlt passende, teils noch geplante Deep-Dive-Module.
- Externe Locations, Connection Options, Credentials, Service-Broker-Payloads, CLR-Binaries, Moduldefinitionen und Benutzertabellen werden nicht gelesen.
- Native JSON-/Vector-Nutzung wird nur über den jeweiligen Systemtyp erkannt; JSON in Zeichenketten oder Moduldefinitionen wird bewusst nicht behauptet.
- Installer, Frameworkvertrag, Smoke-/API-Test, Beispiele, Inventare, Referenz, Backlog und Spezialfalltestmatrix synchronisiert.
- Laufzeitstatus bleibt vollständig `NOT_EXECUTED`; die P2-Implementierung erweitert keine Laufzeitfreigabe.

## Stand 2026-07-17 – Abschluss P1 `1.1.0-special.2`

- SQLCMD-Runner `Code/Tests/Run_Release_Gate.sql` für vier verbindliche Integrationsverträge und acht Bereichs-Smoke-Tests, synthetische Suite-Evidenzvorlage und datenschutzkonformes Runbook ergänzt; alle Zielzeilen bleiben bis zur realen Ausführung `NOT_EXECUTED`.
- `SC-011` durch `monitor.USP_StatisticsDistributionAnalysis` geschlossen.
- Histogrammzugriff je Datenbank vorab auf 1–250 priorisierte Statistiken begrenzt und durch `CATALOG_DEEP` geschützt.
- Numerische Evidenz für dominante Histogrammschritte, Gleichheits-/Range-Skew, Tail-Konzentration, Änderungen seit dem Statistikstand und inkrementelle Partitionsvariation ergänzt.
- Konkrete Histogrammgrenzwerte werden für diese Kennzahlen nicht benötigt; das Modul liest keine Datenzeilen und führt kein `UPDATE STATISTICS` aus.
- Skew-, Tail- und Modification-Signale ausdrücklich als Prüfhinweis statt als Planursache oder Out-of-Range-Beweis klassifiziert.
- Objektorchestrator und normalisierte Findings um getrennte, standardmäßig deaktivierte Statistikverteilungs-Opt-ins erweitert.
- Installer, Smoke Test, Spezialfall-API-Vertrag, Inventare, Beispiele, Referenz, Backlog und Testmatrix synchronisiert.
- Widersprüchliche Aussage in `Known_Issues.md` korrigiert: real getestet ist der Basisstand; die Spezialfallwelle bleibt `NOT_EXECUTED`.

## Stand 2026-07-17 – Spezialfallwelle `1.1.0-special.1`

- Dokumentierbare, datenschutzkonforme Testmatrix mit explizitem `NOT_EXECUTED`-Planungsstatus ergänzt.
- P0-Module für Datenbankintegrität, Kapazität, korrekt typisierte Performance Counter und kritische Engine-Ereignisse implementiert.
- Die erste P1-Welle mit IQP, interner Contention, Buffer Pool, Backupketten, Schema-/Designkorrektheit, tiefer Availability-Evidenz, Agent-/Alert-Monitoring und normalisierten Findings umgesetzt; die noch offene Statistikverteilung wurde anschließend in `1.1.0-special.2` geschlossen.
- Kostenintensive oder detailreiche Pfade standardmäßig deaktiviert oder opt-in ausgeführt.
- `USP_DiagnosticFindings` aggregiert ausschließlich definierte JSON-Vertragsfelder und übernimmt keine SQL-/Plantexte, Pfade, Mailinhalte oder freien Meldungstexte.
- Gesamtinstaller, vier Orchestratoren, Objekt-/Parameter-/Systemquelleninventare, Referenzen, Hilfe, Beispiele, Smoke Test und Spezialfall-API-Vertrag erweitert.
- Der Standalone-Installer übernimmt die kanonische, abhängigkeitssichere Include-Reihenfolge direkt aus `Install_All.sql`.
- Performance-Counter-Quotienten verwenden Zähler- und Basisdeltas; Backup-, Quorum- und Orchestratorstatus wurden in der statischen Tiefenprüfung präzisiert.
- Der frühere Basisstand war real getestet; für diese neue Implementierungswelle liegen noch keine dokumentierten Zielmatrixläufe vor.

## Stand 2026-07-17 – Verbindlicher Repository-Datenschutzvertrag

- Datenschutz-Liefergate ausdrücklich auf Repository-, GitHub- und Downloadartefakte begrenzt.
- Klargestellt, dass Resultsets, OUTPUT-Parameter sowie RAW-, CONSOLE- und JSON-Ausgaben weder anonymisiert noch fachlich reduziert werden.
- Reale interne Datenbankstrukturen, Namenskonventionen und proprietäre Metadaten aus Screenshots, Hardcopys, Chats, Uploads, Skripten, Logs und Diagnoseausgaben ausdrücklich aus Repositoryartefakten ausgeschlossen.
- Festgelegt, dass auch Zustimmung oder vorhandener Zugriff das Repositoryverbot nicht aufheben.
- Automatische Musterprüfung als unterstützenden Filter statt als Sicherheitsbeweis eingeordnet; uneindeutige Funde halten den Schreib- und Lieferprozess an.

## Stand 2026-07-17 – Datenschutzpräzisierung und Spezialfallanalyse

- Datenschutzgrenze korrigiert: Diagnostisch erforderliche Identitäts- und Umgebungswerte dürfen in interaktiven Runtime-Ausgaben erscheinen, aber niemals in Repository-, Dokumentations-, Test- oder Downloadartefakte übernommen werden.
- Verbindlichen Prüf- und Fragevertrag für persistierbare Artefakte ergänzt.
- Vorhandene Analyseabdeckung erneut auf Objekt-, Systemquellen- und Capability-Ebene geprüft.
- Frühere pauschale Abdeckungsprozentwerte verworfen und durch eine evidenzbasierte Prioritäts-, Kosten- und Bedingtheitsmatrix ersetzt.
- 25 fehlende oder zu vertiefende Spezialfallklassen als maschinenlesbaren Backlog dokumentiert.
- Integrität, Kapazität, kritische Engine-Ereignisse und korrekt typisierte Performance-Counter als erste technische Ausbaustufe priorisiert.
- Aktuelle Microsoft-Primärquellen sowie öffentliche Prüfkataloge des SQL Tiger Toolbox und des SQL Server First Responder Kit abgeglichen; kein fremder Code übernommen.

## Stand 2026-07-17 – Real getesteter Gesamtstand

- Gesamtinstaller und Frameworkfunktionen wurden nach Angabe des Projektverantwortlichen vollumfänglich real getestet.
- Falsche Sortierspalte in `monitor.USP_IndexOperationalStats` korrigiert.
- Mehrdeutige Spaltenreferenzen im dynamischen SQL von `monitor.USP_QueryStoreRegressions` vollständig mit dem CTE-Alias qualifiziert.
- `SET QUOTED_IDENTIFIER ON` für die Extended-Events-Procedures mit XML-Methoden sowie für die Index-Operational-Stats-Procedure ergänzt.
- Integrationsprüfung `165_Filter_Output_Contract.sql` für Listen-, Pattern-, JSON- und öffentliche Procedure-Verträge ergänzt.
- Der getestete Gesamtstand ist die neue kanonische Projektbasis.

## Stand 2026-07-16 – Abschluss der Repositorymigration

- Datenbankplatzhalter aus ausführbarer interner Logik entfernt; aktuelle Installationsdatenbank wird über `DB_ID()` ermittelt.
- Letzten umgebungsspezifischen Präfixhinweis aus den Beispielen entfernt.
- Procedure-Referenz auf die kanonischen `Code/...`-Pfade umgestellt.
- Veraltete Installations-, Test- und Recherchepfade korrigiert.
- Das bisherige Dateihashmanifest entfernt; Git ist die maßgebliche Versions- und Integritätsquelle.
- Systemquellen-, Capability-, Abhängigkeits- und Performance-/Risikokatalog als abstrahierte Migrationsergebnisse ergänzt.
- Root-README und lokale Arbeitskopie mit dem aktuellen `LICENSE.md`-Stand synchronisiert.
- Datenschutz- und Portabilitätsprüfung erneut ausgeführt.

## Stand 2026-07-16 – Compilekorrektur und Installer-Neubau

- Beschädigtes Unicode-Stringliteral in `monitor.USP_CheckFrameworkCapabilities` korrigiert.
- Unzulässige CTE-Spaltenreferenz im `TOP`-Ausdruck von `monitor.TVF_DatabaseCandidates` durch parameterbasierte Berechnung ersetzt.
- `IF`-/`TRY`-/`CATCH`-Blöcke in `monitor.USP_PlanCacheAnalysis`, `monitor.USP_QueryStoreAnalysis`, `monitor.USP_ExtendedEventsAnalysis` und `monitor.USP_ServerHealthAnalysis` eindeutig strukturiert.
- Server-Health-Orchestrator setzt Child-Statusvariablen vor jedem Modulaufruf zurück.
- Phaseninstaller und Gesamtinstaller vollständig aus den korrigierten kanonischen Objektdateien neu aufgebaut.
- Statische Prüfung um String-, Block-, Parameter- und Installer-Synchronitätskontrollen erweitert.

## Stand 2026-07-15 – Filter-, Ausgabe- und Memory-Vertrag

- Öffentliche API auf case-sensitive Bezeichner und case-insensitive Steuerwerte konsolidiert.
- `@AlleDatenbanken` entfernt; Datenbankscope über bracket-aware `@DatabaseNames`/Patterns.
- Listenparser für SQL-Namen, Full Object Names, allgemeine Textwerte und numerische IDs ergänzt.
- `like:`, `regex:` und `regexi:` mit versionsadaptiver Regex-Ausführung ergänzt.
- RAW-, CONSOLE-, NONE- und JSON-Ausgaben für alle öffentlichen Analyse-Procedures vereinheitlicht.
- Query Store auf explizite Quelldatenbanken und referenzierte Datenbanken getrennt; lokales N+1 plus globales Top N.
- Memory-Grant-Ausgabe um Workload Group, Resource Pool, Resource Semaphore, maximalen Request-Grant und Prozentkennzahlen erweitert.
- `RequestMaxMemoryGrantPercent` verwendet die präzise DMV-Quelle, ohne Datentyp-Suffix im öffentlichen Namen.
- Sämtliche Phaseninstaller und der Gesamtinstaller aus 81 kanonischen Objektdateien neu aufgebaut.
- Referenzhandbuch, Beispielaufrufe, Parameterinventar und QA-Berichte aktualisiert.

## Teststatus

Der Basisstand vor `1.1.0-special.1` wurde nach Angabe des Projektverantwortlichen real getestet. Commit `7e3ba1a4e2fa79761c2daf24bee23dd73feed297` des Stands `1.1.0-special.9` hat die commitbezogenen Actions-Läufe für SQL Server 2019, 2022 und 2025 einschließlich 14 Suiten, aller 17 P0-Fälle, Berechtigungsmatrizen und der eigenständigen SQL-Server-2025-Regex-Matrix erfolgreich abgeschlossen. Die Freigabe gilt mit Einschränkungen für disposable synthetische Linux-Ziele; weitere Feature-Positiv-, Grenzwert-, Last-, Windows-, Azure-MI- und externe Fälle bleiben gesondert.

<!-- BEGIN API_15_STATEMENT_CONTEXT -->
## Stand 2026-07-16 – CONSOLE-Default und Statementkontext

- `CONSOLE` ist frameworkweit die Standardausgabe; `RAW` bleibt der explizite technische Vertrag.
- Zentrale Inline-TVF `monitor.TVF_StatementText` extrahiert das laufende Statement aus den Byte-Offsets eines Requests.
- Live-Request-Module verwenden denselben Offsetvertrag; `USP_CurrentBlocking` und `USP_CurrentTransactions` geben nicht mehr irrtümlich den vollständigen Batch als aktuelles Statement aus.
- `monitor.USP_CurrentRequests` zeigt Modulname und -typ, Byte-/Zeichenoffsets, Start-/Endzeilen und das exakte aktuelle Statement.
- Vollständiger Batch-/Modultext und Input Buffer sind separat opt-in; `@MaxSqlTextZeichen = NULL/0` liefert vollständige Texte.
- CONSOLE enthält ein eigenes schmales `SQL-Kontext`-Resultset; JSON verwendet die benannten Arrays `requests`, `statements`, `batches`, `inputBuffers` und `warnings`.
- Optionale Modul- und Input-Buffer-Auflösung erfolgt erst nach dem Ergebnislimit, um unnötige Arbeit zu vermeiden.
- Der technische Ausführungskontext umfasst unter anderem Verschachtelungsebene, Transaction-/Connection-ID, Scheduler/Task, Workload Group, Resource Pool sowie Statement-Handle und Statement-Context-ID.
- `@MaxSqlTextZeichen` ist frameworkweit vereinheitlicht: positiv kürzt, `NULL`/`0` liefert den vollständigen Text, negative Werte sind ungültig.
<!-- END API_15_STATEMENT_CONTEXT -->

- `PLAN-001`: eigenständig installierbarer Execution-Plan-Kern mit statementgenauer Operatoranalyse, Evidence JSON, Statistik-/Histogrammkorrelation, `DERIVED_ONLY`-Datenschutzdefault und Integration in den Gesamtinstaller. Der öffentliche V1-Vertrag ist eingefroren. Commit `6938e813b62634b48106852f8e7954c4bd262698` hat Gesamtgate und Permission Matrix auf [SQL Server 2019](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29851011360), [SQL Server 2022](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29851011381) und [SQL Server 2025](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29850785277) bestanden; der 2025-Lauf enthält zusätzlich isolierten Teilinstallervertrag und Regex Matrix. Der [Output-Pilot](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29851011377) ist auf allen drei Zielversionen erfolgreich.
