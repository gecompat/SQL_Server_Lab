# Projektkontext für KI-gestützte Fortsetzung

## Ziel

Entwicklung eines performanten, read-only orientierten SQL-Server-Diagnoseframeworks im Schema `[monitor]` für SQL Server 2019 und höher.

## Feste Verträge

- Collation: Das Framework verwendet durchgängig explizite `COLLATE SQL_Latin1_General_CP1_CS_AS`-Klauseln in Vergleichen, Temp-Tabellen, TVF-Rückgabewerten und GROUP-BY-Operationen. Es funktioniert grundsätzlich auf beliebigen Collations. Getestet und garantiert wird ausschließlich `SQL_Latin1_General_CP1_CS_AS`. Objekt-, Parameter-, Spalten- und Aliasnamen im Frameworkcode sind case-sensitiv.
- Jedes SQL-Skript beginnt mit `USE [DeineDatenbank];` und `GO`.
- Beispielaufrufe sind nur als `[monitor].[Objektname]` zu schreiben.
- Öffentliche Procedures verwenden `@ResultSetArt = 'CONSOLE'` als Default; Steuerwerte werden intern case-insensitiv normalisiert.
- `RAW` ist der stabile technische Vertrag, `CONSOLE` die formatierte Ad-hoc-Ausgabe, `TABLE` der benannte Mehrfach-Export und `NONE` unterdrückt fachliche Resultsets.
- `CONSOLE` liefert im Normalfall genau ein fachliches Resultset; leere fachliche Ergebnisse erhalten eine verständliche Console-Zeile, während RAW und TABLE keine künstliche Datenzeile erzeugen.
- `TABLE` verwendet ausschließlich `@ResultTablesJson`; die stabilen Resultsetnamen und nativen Schemas stehen in `Metadata/Inventory/ResultSets.csv`.
- JSON wird optional über `@Json nvarchar(max) OUTPUT` mit Metadaten und benannten Arrays geliefert.
- `@MaxZeilen`: positiv begrenzt, `NULL` oder `0` bedeutet vollständig, negativ ist ungültig.
- Exakte Mehrfachfilter verwenden bracket-aware Pipe-Listen; Pipe trennt nur außerhalb von `[...]`.
- Patternfilter sind von exakten Listen getrennt und unterstützen `like:`, versionsabhängig `regex:` und `regexi:`.
- Query Store wird im Kontext jeder ausgewählten Quelldatenbank gelesen.
- Statementtext wird zentral anhand der Byte-Offsets extrahiert; Batch-, Modul- und Input-Buffer-Text sind getrennte Diagnoseinformationen.
- Standardmäßig werden alle sichtbaren, online befindlichen Benutzerdatenbanken verarbeitet; explizite Namens- und Patternfilter schränken ein, Systemdatenbanken bleiben opt-in und es gibt keinen CURRENT-Scope oder `@MaxDatenbanken`.
- Katalogzugriffe sollen Locking/Blocking minimieren; nur tatsächlich aktivierte ressourcenintensive Pfade verlangen `@HighImpactConfirmed = 1` vor dem ersten teuren Zugriff.
- Der frameworkweite Datenbank-, CONSOLE- und TABLE-Vertrag wird durch die Integrationssuiten `187` bis `189` abgesichert.
- Tool-Hintergrundaktivität wird in Current Sessions, Requests, Blocking-Blättern und aktuellen Waiting Tasks standardmäßig ausgeblendet. Die Erkennung verwendet metadatengetriebene `LIKE`-Regeln, ist kein Sicherheitsmerkmal und bleibt über `@ToolHintergrundabfragenEinbeziehen=1` vollständig sichtbar.
- Blocking liefert `BlockingChain` und `RootBlocker*`-Kontext; ein Tool als Zwischen- oder Root-Blocker einer normalen Abfrage darf nicht aus der Kette entfernt werden.
- P0/P1-Reihenfolge und Aussagegrenzen stehen in `Documentation/Architecture/Special_Case_Modules.md`.
- `monitor.USP_DiagnosticFindings` ist der letzte Aggregator und hängt über definierte JSON-Verträge von den vorherigen Spezialfallmodulen ab; Schema, IQP und Contention bleiben dort opt-in.
- `monitor.USP_SpecialFeatureInventory` trennt sichtbare Nutzung beziehungsweise reine Konfiguration von Plattform-Capability und gibt ausdrücklich kein Gesundheitsurteil ab.
- `monitor.USP_InMemoryOltpAnalysis` isoliert jede XTP-Quelle, aktiviert Hashketten nur opt-in mit `CATALOG_DEEP` und gibt ausschließlich Prüfhinweise mit Evidenzgrenzen statt automatischer DDL aus.
- `monitor.USP_TemporalAnalysis` liest nur sichtbare Temporal-Kataloge, Retention-Schalter, approximative Partitionsstatistik und History-Indexmetadaten; Zeilenkonsistenz, Cleanup-Erfolg und früher getrennte Tabellenpaare werden nicht behauptet.
- `monitor.USP_ServiceBrokerAnalysis` isoliert Queue-, Kapazitäts-, Aktivierungs-, Transmission- und Conversation-Quellen; Queue-Nutzdaten und Nachrichtenkörper bleiben ausgeschlossen und ein deaktiviertes RECEIVE wird nicht automatisch als Poison Message klassifiziert.
- `monitor.USP_FullTextAnalysis` isoliert Katalog-, Fragment-, Population-, Batch-, Semantik-, Memory-Pool- und FDHost-Quellen; Inhalte, Keywords, Stopwords, Schlüsselwerte, Crawl-Logs, Pfade und Full-Text-DDL bleiben ausgeschlossen.
- `monitor.USP_DataCaptureDeepAnalysis` bewertet CT-Verlust nur mit Consumer-Wasserstand, isoliert CDC- und lokale Replikationsquellen und behandelt Remote-Topologie als Evidenzlücke; Change-Zeilen, Commands, Fehlertexte, Credentials und DDL bleiben ausgeschlossen.
- `monitor.USP_EncryptionAnalysis` trennt TDE von expliziter Backupverschlüsselung und liest keine Schlüssel-, Medien-, Konto- oder geschützten Inhaltsdaten; externe Schlüsselkopie und Restore bleiben außerhalb des Beweisumfangs.
- `monitor.USP_MaintenanceOperations` liest Jobaktivität nur bei explizitem Filter und führt keine Resume-, Abort-, Kill-, Cleanup- oder Jobaktion aus; SQL-/Jobinhalte und Identitäts-/Clientdaten bleiben ausgeschlossen.
- Actions führen Installer, 34-Suite-Release-Gate und synthetische Berechtigungsmatrix versionshart auf SQL Server 2019, 2022 und 2025 aus.
- Maßgebliche Runtime-Evidenz wird commitbezogen in `Metadata/Quality/Test_Matrix.csv` und `Metadata/Quality/Release_Gate_Evidence.csv` verknüpft.

## GitHub-Veröffentlichung aus ChatGPT-Laufzeiten

- Scheitert ein direkter HTTPS-Push nachweislich ausschließlich an fehlenden GitHub-Credentials der Laufzeit, darf derselbe Push nicht erneut versucht werden.
- Vor dem Connector-Fallback muss der aktuelle Stand von Remote-`main` neu gelesen und der vollständige beabsichtigte Änderungsumfang gegen diese Basis geprüft werden.
- Der unveränderte, bereits geprüfte Commit-Tree wird über den GitHub Connector ohne Force-Push auf einem neuen, eindeutig benannten Branch veröffentlicht; `main` wird dabei niemals direkt aktualisiert und ein bestehender Branch nicht überschrieben.
- Aus diesem Branch wird ein Draft-PR gegen den neu geprüften Stand von `main` erstellt.
- Ist der freigegebene Umfang auf `AI_Metadata/` beschränkt, dürfen ausschließlich Pfade unterhalb dieses Ordners enthalten sein. Sobald eine Änderung außerhalb von `AI_Metadata/` vorhanden ist oder nicht sicher ausgeschlossen werden kann, darf weder veröffentlicht noch ein PR erstellt werden; die Verarbeitung wird mit einer Scope-Meldung beendet.

## Verbindliche Repository-Abgrenzung: Produktlinie vs. CI/Operations-Linie

- Die Hauptlinie ist der Produktzweig und enthält Installations-, Dokumentations-, Beispiel- und Lab-/Repro-artefakte des Frameworks.
- Die Operations-/Validation-Linie enthält GitHub-Actions, Runner, Tests, Release-Gates, Qualitätsnachweise und verwandte Automatisierungsartefakte.
- Änderungen an Framework-Objekten, Installern, Beispielen und Dokumentation gehören in die Produktlinie.
- Änderungen an `.github/workflows/`, Runner-Skripten, Test-Assets und Release-/Quality-Mechanik gehören in die Operations-/Validation-Linie.
- Eine Vermischung beider Ebenen ist ab sofort nicht mehr die Standard-Strategie; bei Bedarf sind getrennte Änderungen oder getrennte Branches zu verwenden.

## Datenschutz und Portabilität

- Das Datenschutz-Liefergate gilt ausschließlich für Repository-, GitHub- und Downloadartefakte. Resultsets, OUTPUT-Parameter sowie RAW-, CONSOLE- und JSON-Ausgaben werden deshalb weder anonymisiert noch fachlich reduziert.
- Reale personen-, benutzer-, kunden-, firmen-, organisations-, betriebs- oder umgebungsbezogene Informationen dürfen niemals in Code, Kommentaren, Dokumentation, Beispielen, Tests, Fixtures, Audits, Metadaten, Screenshots oder Downloads stehen.
- Das Verbot umfasst interne Datenbankstrukturen, Namenskonventionen und proprietäres Metadatenwissen aus Screenshots, Hardcopys, Chats, Uploads, bestehenden Skripten, Logs und Diagnoseausgaben.
- Technische Systemspalten und generische API-Namen sind zulässig; Beispiele verwenden ausschließlich eindeutig synthetische, generische Werte und bilden keine reale interne Struktur nach.
- Öffentliche Quellen-, Lizenz- und Urheberangaben sind beabsichtigte Attribution und werden nicht als versehentliche Umgebungsdaten behandelt.
- Eine Zustimmung oder vorhandener Zugriff hebt das Repositoryverbot nicht auf.
- Bei uneindeutigen Datenfunden muss vor dem Schreiben oder Verpacken angehalten und nach einer nicht sensitiven Alternative gefragt werden.
- Maßgebliche Entscheidung: `AI_Metadata/Internal_Documentation/Architecture/Runtime_Data_and_Repository_Privacy.md`.

### Verbindlicher Kurzprompt

> In Repository-, GitHub- und Downloadartefakte dürfen niemals reale personen-, firmen-, kunden-, organisations-, betriebs- oder umgebungsbezogene Informationen oder proprietäre interne Strukturen übernommen werden, auch nicht aus Screenshots, Hardcopys, Chats, Uploads, Skripten, Logs oder Diagnoseausgaben. Beispiele und Tests verwenden ausschließlich eindeutig synthetische, generische Werte ohne Nachbildung realer interner Strukturen. Resultsets und OUTPUT-Parameter der Procedures bleiben diagnostisch vollständig und werden durch diese Regel nicht anonymisiert. Bei Zweifeln vor dem Schreiben anhalten und nach einer nicht sensitiven Alternative fragen; eine Zustimmung hebt das Repositoryverbot nicht auf.
