# Bekannte Restpunkte

Stand: 2026-07-22

Die Version `1.1.0-special.13` besitzt für Commit `8572c02ccec7b349d104ccf72a01489733fc03a7` grüne Actions-Gates auf SQL Server 2019, 2022 und 2025. Die Evidence deckt Installer, 34 Suiten, die versionsspezifischen Berechtigungsmatrizen, alle 181 P0-/P1-/P2-Fälle sowie die Welle-1- und Welle-2-Verträge auf disposable synthetischen Linux-Zielen ab; in der Spezialfallmatrix verbleibt keine `NOT_EXECUTED`-Zeile. Der aktuelle Evidence-Stand wird kanonisch in `Metadata/Quality/Test_Matrix.csv` geführt und durch `Code/Tests/Static/990_Validate_Release_Evidence.py` gegen Detailmatrix und Release-Audit geprüft.

Verbleibende Repository- und Evidenzpunkte:

- Keine offenen RQ-Punkte. `RQ-006` ist mit 347 primärquellengeprüften, eindeutigen Wait Types und einem statischen Katalogvertrag abgeschlossen.
- Keine offene fachliche Dokumentationslücke: alle 96 öffentlichen Procedure-Seiten einschließlich der eigenständigen und optionalen Pakete enthalten Zweck, sichere Leserichtung, Aussagegrenzen und technische Vertiefung beziehungsweise den vollständig strukturierten Baselinevertrag.
- Die vier ersten P1-IQP-Fälle sind automatisiert und commitbezogen nachgewiesen.
- Die vier P1-Contention-Fälle sind als sechzehnte Suite nachgewiesen. Der Page-Detail-Fall erzwingt keinen künstlichen realen PAGELATCH-Wait, sondern prüft den opt-in- und Zeilengrenzenvertrag; diese Einschränkung bleibt ausdrücklich erhalten.
- Die vier P1-Speicherfälle sind als siebzehnte Suite auf SQL Server 2019, 2022 und 2025 nachgewiesen. Speicherdruck und Resource-Semaphore-Waiter wurden nicht künstlich erzeugt; der Vertrag prüft die bedingte Interpretation aktueller DMV-Evidenz und bleibt deshalb `PASS_WITH_LIMITATIONS`.
- Die vier P1-Backupkettenfälle sind als achtzehnte Suite auf SQL Server 2019, 2022 und 2025 nachgewiesen. Die Suite verwendet ausschließlich die synthetische Testdatenbank, eine generisch benannte Datei im Default-Backupverzeichnis des disposable Targets und kurzlebige `msdb`-Historie; weil sie bewusst keinen Restore ausführt, bleibt sie `PASS_WITH_LIMITATIONS`.
- Die vier P1-Schema-/Designfälle sind als neunzehnte Suite auf SQL Server 2019, 2022 und 2025 nachgewiesen. Alle generischen Constraint-, FK-, Index- und Identity-Fixtures werden im Erfolgs- und Fehlerpfad ausdrücklich entfernt; Befunde bleiben Prüfaufträge ohne automatische DDL.
- Die acht P1-Statistikverteilungsfälle sind als zwanzigste Suite auf SQL Server 2019, 2022 und 2025 nachgewiesen. Die Suite verwendet begrenzte synthetische FULLSCAN-Histogramme, prüft gefilterte und inkrementelle Statistiken sowie einen tatsächlich verweigerten `CATALOG_DEEP`-Pfad. Sie beweist keine universelle Histogrammqualität und ersetzt keine großen Produktionsverteilungen oder Lasttests.
- Die vier P1-Availability-Fälle sind als einundzwanzigste Suite nachgewiesen. Suspend-, Queue- und Seeding-Positivpfade werden über produktiv verwendete reine Klassifikationsfunktionen geprüft; kein Failover, Suspend, Resume oder physisches Seeding wird ausgeführt.
- Die vier P1-Agent-/Alert-Fälle sind als zweiundzwanzigste Suite nachgewiesen. Der echte Leerzustand und gemeinsame Statusklassifikationen werden geprüft; Alerts, Operatoren, Jobs, Mail und `msdb` werden nicht verändert.
- Die sechs P1-Findings-Fälle sind als dreiundzwanzigste Suite nachgewiesen. Synthetischer Benutzer und Compatibility Level werden garantiert zurückgesetzt; die Feld-Whitelist beweist keinen vollständigen fachlichen Positivzustand aller Child-Module.
- Die 21 P2-Feature-Inventurfälle sind als vierundzwanzigste Vertragsgruppe nachgewiesen; nicht portable Komponenten bleiben capability-adaptive Vertragsnachweise.
- Die 14 P2-XTP-Fälle sind nachgewiesen; ein vollständiger Hashketten-DMV-Scan und echter Speicherdruck werden nicht erzwungen.
- Die 13 P2-Temporal-Fälle sind nachgewiesen; History-Nutzdaten, Periodenüberlappungen und realer Cleanup-Fortschritt werden nicht gelesen.
- Die 15 P2-Broker-Fälle sind nachgewiesen; Nachrichtenkörper, Queue-Payloads und Conversation-Mutationen bleiben ausgeschlossen.
- Die 16 P2-Full-Text-Fälle sind nachgewiesen; positive Full-Text-DDL auf Linux bleibt wegen der MCR-Komponentengrenze ein separater Plattformnachweis.
- Die 25 P2-Data-Capture-Fälle sind nachgewiesen; Change-Zeilen, Replikationscommands, Credentials und Remote-Topologien bleiben außerhalb der Repository-Evidence.
- Die zehn Encryption- und zehn Maintenance-Fälle sind vollständig nachgewiesen; Schlüssel-/Medieninhalte und operative Wartungsänderungen bleiben ausgeschlossen.
- Evidenzhinweis: Der nachfolgende direkte Dokumentationscommit `71f70830f4d9b8c6a0531c5eaf4116bd3806ac9d` enthielt zusätzlich zum Betreff einen Nachrichtentext und wurde vom Commit-Message-Gate erwartungsgemäß abgelehnt. Gemäß `RQ-005` wird bestehende Historie nicht umgeschrieben; er ist nicht der funktional ausgewiesene Release-Evidenzcommit.

Verbleibende fachliche beziehungsweise betriebliche Punkte:

- Der mitgelieferte Build- und Lifecycle-Katalog von `USP_ServerVersionInformation` besitzt den expliziten Stand 21. Juli 2026 und ersetzt keine spätere Katalogpflege. Ein nicht enthaltener oder neuerer Build liefert eine Evidenzlücke beziehungsweise `UNKNOWN_NEWER_BUILD`, aber keine automatische Veraltet-Aussage.
- Die synthetischen Welle-1-Verträge prüfen Unicode-/Surrogatgrenzen, native XML-Spaltentypen und fest definierte XML-Zustände. Sie beweisen weder die Darstellung in jeder grafischen Clientversion noch Größe, Struktur oder Interpretierbarkeit realer Produktionspayloads.
- Die TempDB-Arbeitstabellen von `USP_TemporalAnalysis` und den gemeinsamen TABLE-Helfern werden vor dem prozedurweiten No-Wait-Metadatenpfad erzeugt. Damit ist die in einem früheren Verifikationslauf beobachtete flüchtige TempDB-DDL-Lockkollision gezielt ausgeschlossen; fachliche Benutzer-Metadatenzugriffe bleiben weiterhin nonblocking und können kontrolliert als partiell enden.
- Die automatisierten synthetischen Linux-Vertragspfade ersetzen keine weiteren Feature-Positiv-, Grenzwert-, Last-, Windows- oder Azure-MI-Tests.
- Bei jeder weiteren Zielversion oder abweichenden Plattform sind Installer, Smoke Tests, Parametervertrag und `165_Filter_Output_Contract.sql` erneut auszuführen.
- Phase 7 liefert überwiegend Inventar- und Momentaufnahmen; zeitbasierte CPU-, NUMA- und Memory-Trends sind bewusst nicht Bestandteil dieses Ad-hoc-Pakets.
- DWH-/ETL-spezifische Adapter bleiben zurückgestellt.
- Die optionale Ausgabe des tatsächlichen Ausführungsplans bleibt bewusst außerhalb des Defaultpfads; Plan-XML kann groß und die Abfrage des Plans ressourcenintensiv sein.
- `USP_InMemoryOltpAnalysis` ist eine Momentaufnahme. Der Hashkettenpfad kann vollständige Tabellen scannen und bleibt opt-in; Defaultpool-Werte sind nicht datenbankgenau zurechenbar, Checkpointzustände und Transaktionsmengen benötigen Verlaufskorrelation.
- `USP_TemporalAnalysis` prüft keine Current- oder History-Zeilen. Periodenüberlappungen, tatsächlicher Cleanup-Fortschritt und nach `SYSTEM_VERSIONING=OFF` getrennte Tabellenpaare bleiben ohne zusätzliche, bewusst nicht ausgeführte Daten- oder Historienevidenz unbewiesen.
- `USP_ServiceBrokerAnalysis` liest keine Queue-Nutzdaten oder Nachrichtenkörper. Eine deaktivierte Queue, alte Transmission-Einträge, approximative Queue-Zeilen und Broker-DMV-Zustände beweisen weder eine Poison Message noch Routing-, Aktivierungs- oder Verarbeitungsursache; Laufzeitverlauf und kontrollierte externe Evidenz bleiben erforderlich.
- `USP_FullTextAnalysis` liest keine indizierten Inhalte, Keywords, Stopwords, Schlüsselwerte, Crawl-Logs oder Pfade. Population-, Batch- und FDHost-DMVs sind Momentaufnahmen; Alter, Fragmentzahl und Poolgröße benötigen Zeitreihe, Workload- und Suchlatenzkontext. Geschützte Laufzeitlogs dürfen nicht in Repositoryartefakte übernommen werden.
- `USP_DataCaptureDeepAnalysis` kann CT-Synchronisationsverlust nur für einen explizit gelieferten Consumer-Wasserstand bewerten. CDC-DMVs und Agenthistorien sind begrenzt und reset-/cleanup-abhängig. Remote Distributor, Pull-/Peer-to-Peer-Topologien und Subscriber-Netzpfade können außerhalb der lokalen Sicht liegen; eine Evidenzlücke ist kein gesunder Befund.
- `USP_EncryptionAnalysis` beweist weder den Besitz externer Schlüsselkopien noch Restorefähigkeit. TDE und explizite Backupverschlüsselung bleiben getrennt; Zertifikatablauf und lokaler Exportzeitpunkt sind Lebenszykluskontext.
- `USP_MaintenanceOperations` ist eine Momentaufnahme. Pause, Laufdauer, PVS-Größe und Jobüberlappung benötigen Betriebs- und Verlaufskontext; das Modul nimmt niemals selbst eine Wartungsänderung vor.
- `USP_ExternalRuntimeAnalysis` und `USP_ClrAnalysis` liefern einen zustandslosen Current-State-Kern. Der portable Vertrag aktiviert keine Runtime, führt kein Script aus und lädt keine Assembly. Feature-positive R-, Python-, Java-, C#-, Custom-Language- und SQL-CLR-Fälle sowie Windows-Securitykonstellationen bleiben deshalb getrennte Plattformnachweise.
- SC-023 besitzt einen als `IMPLEMENTED_ACTIONS_GATE` abgenommenen, separat installierbaren Performance-Counter-Slice, aber noch keine Wait-, I/O-, Datenbank-, Query-, Plan- oder Rollup-Sammler. SC-024 und SC-025 benötigen weiterhin externe autorisierte Komponenten beziehungsweise Ziele.
