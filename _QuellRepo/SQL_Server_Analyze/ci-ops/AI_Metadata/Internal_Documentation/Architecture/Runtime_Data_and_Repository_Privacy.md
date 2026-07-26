# Datenschutz- und Sicherheitsvertrag für Repositoryartefakte

**Status:** verbindlich
**Stand:** 20. Juli 2026
**Geltungsbereich:** Repository, GitHub-Inhalte und downloadbare Artefakte
**Nicht betroffen:** diagnostische Runtime-Ausgaben
**Maßgebliche Fassung:** dieses Dokument

## 1. Entscheidung

Dieser Vertrag gilt ausschließlich für Inhalte, die in Repositorydateien oder GitHub-Inhalte geschrieben beziehungsweise für Commits, Pull Requests, Issues, Dokumentation, Tests, Metadaten, Screenshots, generierte Dateien, Archive oder andere Downloads vorbereitet werden.

Er verändert keine diagnostische Runtime-Ausgabe. Resultsets, OUTPUT-Parameter sowie RAW-, CONSOLE-, TABLE- und JSON-Ausgaben der Procedures dürfen die für die angeforderte Diagnose erforderlichen realen Werte unverändert liefern, soweit der Datenbank-Sicherheitskontext dies erlaubt. Dieser Vertrag ist insbesondere kein Auftrag, Runtime-Spalten zu entfernen, Werte zu maskieren, zu kürzen, zu hashen oder zu pseudonymisieren. TABLE bleibt auf lokale `#Temp`-Tabellen derselben Sitzung begrenzt. Ein ausdrücklich installiertes Persistenzpaket wie SC-023 darf dieselben realen Laufzeitwerte in seiner betrieblichen Zieldatenbank dauerhaft speichern; dadurch entsteht kein Repositoryartefakt.

Reale personen-, benutzer-, kunden-, firmen-, organisations-, betriebs- oder umgebungsbezogene Informationen dürfen niemals Bestandteil eines Repository- oder Downloadartefakts werden. Das gilt unabhängig davon, ob sie aus Screenshots, Hardcopys, Chats, Uploads, bestehenden Skripten, Logs, Abfrageergebnissen, Ausführungsplänen oder anderen Diagnoseausgaben stammen.

Verboten sind solche realen Informationen insbesondere in:

- Repositorydateien und Git-Commits,
- Pull Requests, Issues, Reviewkommentaren und sonstigen GitHub-Inhalten,
- Quellcode, Kommentaren, Dokumentation, Screenshots und Beispielausgaben,
- Testdaten, Fixtures und erwarteten Testergebnissen,
- Metadaten, Inventaren und Auditresultaten,
- CSV-, JSON-, XML-, Text-, Log- und Diagnoseexporten,
- Build-, Installations- und Lieferpaketen einschließlich ZIP-Dateien,
- Audit-, Forschungs- und Fehlerberichten,
- späteren Snapshot-, Baseline-, Retention- oder DWH-Daten, sofern diese als Projektartefakt exportiert werden.

Eine Zustimmung hebt dieses Repositoryverbot nicht auf. Erfordert eine Aufgabe scheinbar reale interne oder personenbezogene Informationen in einem Repositoryartefakt, wird die Ausführung vor dem Schreiben oder Verpacken angehalten und nach einer nicht sensitiven fachlichen Alternative gefragt. Schweigen, vermutete Harmlosigkeit oder bereits vorhandener Zugriff gelten nicht als Freigabe.

## 2. Warum die frühere pauschale Formulierung falsch war

Die frühere Aussage, solche Informationen dürften grundsätzlich nie ausgegeben werden, vermischte zwei verschiedene Datenflüsse:

1. **Interaktive Diagnose:** Ein berechtigter Operator fragt den aktuellen Zustand des eigenen SQL Servers ab. Identitäts- und Umgebungswerte sind hier häufig fachlich notwendig, etwa um eine blockierende Session einem Login, Host oder Programm zuzuordnen.
2. **Persistierbares Projektartefakt:** Informationen werden in das Repository, nach GitHub oder in ein Projekt-/Downloadartefakt übernommen. Hier besteht das Risiko, dass Betriebs-, Kunden- oder Personendaten dauerhaft im Repository oder in dessen Historie landen. Eine autorisierte betriebliche Zieldatenbank außerhalb dieses Datenflusses ist kein Projektartefakt.

Ein pauschales Verbot in der ersten Ebene würde wesentliche Diagnosefunktionen unbrauchbar machen. Die verbindliche Grenze liegt deshalb beim Übergang von flüchtiger Laufzeitausgabe zu einem persistierbaren Artefakt.

## 3. Klassifikation der Datenflüsse

| Datenfluss | Reale Laufzeitwerte zulässig? | Regel |
|---|---:|---|
| Direktes SELECT-Resultset in SSMS/ADS | Ja | Nur im Rahmen der SQL-Server-Berechtigungen und des angeforderten Diagnosezwecks |
| CONSOLE- oder RAW-Resultset | Ja | Darf Identitäten und Umgebungsnamen diagnostisch anzeigen |
| JSON als OUTPUT-Parameter | Ja, solange nur flüchtig verwendet | Der aufrufende Consumer darf es nicht ungeprüft als Projektartefakt speichern |
| Vom Benutzer bewusst lokal gespeicherte Abfrageausgabe | Nicht Teil des Repositorys | Verantwortung und Speicherzweck müssen außerhalb des Projektpakets geklärt werden |
| Beispielausgabe in Dokumentation oder Issue | Nein | Ausschließlich synthetische Platzhalter verwenden |
| Testfixture, Snapshot oder Golden File | Nein | Ausschließlich synthetische, nicht rückführbare Daten verwenden |
| Repository, Commit, Pull Request oder Release | Nein | Keine realen Identitäts-, Unternehmens-, Kunden- oder Umgebungswerte |
| Downloadbares ZIP oder generierter Installer | Nein | Vor Auslieferung auf eingebettete Daten und unerwartete Dateien prüfen |
| SC-023-Snapshotdatenbank im Zielsystem | Ja | Darf vollständige reale Frameworkausgaben nach dem dokumentierten Zugriffs-, Retention-, Lösch- und Exportvertrag speichern |

Wichtig: Die Procedure-Ausgabe selbst bleibt unverändert. Erst ihre Übernahme in ein Repository-, GitHub- oder Downloadartefakt fällt unter diesen Vertrag. Eine außerhalb des Projektrepositorys betriebene Speicherung ist nicht Gegenstand dieses Liefergates. Der fachliche SC-023-Vertrag steht in `Documentation/Architecture/Snapshot_Baseline_Package_Contract.md`; zusätzliche betriebliche oder rechtliche Pflichten der Zielumgebung bleiben davon unberührt.

## 4. Betroffene Informationsklassen

Die folgende Liste ist bewusst weiter als klassische personenbezogene Daten. Ziel ist auch, versehentliche Betriebs- und Kundendaten aus dem Repository fernzuhalten.

### Identitäten und Akteure

- Login-, Benutzer-, Rollen-, Gruppen- und Dienstkontonamen,
- Benutzer-, Principal-, Session-, Request-, Connection- und Transaktions-IDs, sofern sie aus einer realen Umgebung stammen,
- E-Mail-Adressen, Operatoren, Empfänger und Ansprechpartner,
- Host-, Client-, Workstation-, Anwendungs- und Programmnamen,
- IP-Adressen, DNS-Namen, Domains und Verbindungsendpunkte.

### Organisation und Umgebung

- Firmen-, Kunden-, Mandanten-, Abteilungs- und Projektnamen,
- reale Server-, Instanz-, Cluster-, Availability-Group-, Listener- und Datenbanknamen,
- reale Schema-, Tabellen-, Spalten-, Index-, Job-, Queue-, Publication- und Subscription-Namen,
- proprietäre Datenbankstrukturen, Beziehungen, Namenskonventionen und internes Metadatenwissen,
- Dateipfade, Laufwerksnamen, Freigaben, URLs und Cloud-Ressourcen aus realen Umgebungen.

### Benutzerdefinierte Inhalte

- SQL-Texte und Input Buffer mit Literalen oder Kommentaren,
- Planparameter, Parameterwerte und Query-Store-Texte,
- Fehlermeldungen, Error-Log-Text, Agent-Output und Extended-Events-Payloads,
- Service-Broker-Nachrichteninhalte,
- benutzerdefinierte Extended-Events-Felder, Tags und Freitext,
- fachliche Beispielwerte, die auf Personen, Kunden oder reale Vorgänge schließen lassen.

## 5. Was ausdrücklich nicht verboten ist

Die Regel darf nicht so ausgelegt werden, dass der Quellcode keine generischen Systembegriffe mehr verwenden dürfte.

Zulässig sind:

- technische SQL-Server-Spalten- und Parameternamen wie login_name, session_id oder database_id,
- eindeutig generische, synthetische Bezeichner, die keine reale interne Struktur nachbilden,
- generische Schema- und Objektbezeichner wie monitor, dbo oder BeispielObjekt,
- öffentliche Produkt-, Hersteller- und Projektnamen in fachlichen Quellenangaben,
- bewusst veröffentlichte Lizenz-, Urheber- und Attributionstexte,
- öffentliche Links und bibliografische Angaben zu verwendeten Primär- und Referenzquellen.

Öffentliche Attribution ist kein versehentlich aus einer Kundenumgebung extrahierter Firmen- oder Benutzerwert. Sie bleibt erhalten, weil Lizenz und Herkunft nachvollziehbar sein müssen. Neue personenbezogene oder organisationsbezogene Attribution darf dennoch nicht ohne fachlichen Grund ergänzt werden.

## 6. Regeln für Quellcode und Laufzeit

1. Die Procedures dürfen reale Werte selektieren, wenn diese für die angeforderte Diagnose relevant sind.
2. Resultsets und OUTPUT-Parameter werden wegen dieses Vertrags weder anonymisiert noch inhaltlich reduziert.
3. Der Repositorycode darf keine realen Werte, internen Namen oder proprietären Strukturen aus einer konkreten Umgebung hart codieren oder kommentierend offenlegen.
4. Standardpfade bleiben entsprechend der bestehenden Architektur zustandslos. Ein separat installiertes und ausdrücklich aktiviertes Persistenzpaket darf Resultsets samt realer Werte in seiner Zieldatenbank speichern.
5. Secrets, Kennwörter, Tokens, Schlüsselmaterial und Verbindungszeichenfolgen dürfen niemals in ein Repository- oder Downloadartefakt übernommen werden.
6. Fehlende Berechtigungen werden als Status ausgegeben; sie werden nicht durch zusätzliche Rechtevergabe umgangen.

## 7. Regeln für Dokumentation, Tests und Forschung

- Alle Beispiele müssen eindeutig synthetisch sein, generische Bezeichner verwenden und dürfen keine reale interne Struktur imitieren.
- Laufzeitausgaben dürfen nicht aus einer realen Umgebung kopiert und anschließend nur teilweise geschwärzt werden. Sicherer ist eine vollständig synthetische Rekonstruktion.
- Screenshots realer Verwaltungstools sind ohne vorherige vollständige Prüfung ungeeignet.
- Issues, Chatprotokolle und Reviewkommentare sind ebenfalls persistierbare Artefakte.
- Informationen aus Screenshots, Hardcopys, Chats, Uploads und bestehenden Skripten dürfen nur abstrakt fachlich ausgewertet, nicht als interne Bezeichner oder Strukturen übernommen werden.
- Externe Beispielcodes werden nicht zusammen mit deren realen Umgebungswerten übernommen.
- Forschungsquellen werden verlinkt und zusammengefasst; fremder Code wird nicht ungeprüft kopiert.
- Prüfergebnisse nennen Regeln, Anzahl und Status, aber keine gefundenen sensitiven Werte.

## 8. Prüfvertrag vor Commit und ZIP

Vor jeder Lieferung sind mindestens folgende Prüfungen auszuführen:

1. Nur beabsichtigte Dateien befinden sich im Lieferumfang.
2. Der ZIP-Root ist ausschließlich SQL_Server_Analyze.
3. Git-Metadaten, temporäre Dateien, generierte Installer, Logs und lokale Abfrageergebnisse sind ausgeschlossen.
4. Neue oder geänderte Dokumente, Beispiele, Testdaten und Metadaten werden auf E-Mail-Adressen, IP-Adressen, Domains, lokale Pfade und realistisch wirkende Identitäts- oder Umgebungsnamen geprüft.
5. SQL-Dateien werden auf hart codierte Logins, Server, Datenbanken, Pfade, Endpunkte und fachliche Werte geprüft.
6. Synthetische Platzhalter werden manuell auf Eindeutigkeit und Nicht-Rückführbarkeit geprüft.
7. Treffer aus Lizenzen und Quellenangaben werden als beabsichtigte öffentliche Attribution klassifiziert; sie dürfen nicht stillschweigend entfernt werden.
8. Bei einem nicht eindeutig klassifizierbaren Treffer wird die Auslieferung angehalten und nachgefragt.

Das ausführbare Gate ist in `Code/Tests/Static/910_Validate_Repository_Privacy.py` implementiert und unter `AI_Metadata/Internal_Documentation/Quality/Repository_Privacy_Validation.md` beschrieben. Vor einem Commit wird es gegen die versionierten Dateien ausgeführt; vor einer ZIP-Lieferung zusätzlich mit `--archive-path` gegen den vollständigen Lieferumfang. Der Workflow `.github/workflows/repository-privacy-validation.yml` erzwingt denselben Vertrag in GitHub Actions.

Automatische Musterprüfungen sind nur ein unterstützender Filter und niemals ein Beweis für einen sicheren Artefaktbestand. Sie können weder alle personenbezogenen Informationen noch proprietäre Strukturen erkennen und nicht zuverlässig entscheiden, ob ein Name real oder synthetisch ist. Deshalb bleibt eine kontextbezogene Review erforderlich.

## 9. Abnahmekriterien

Die Entscheidung ist erfüllt, wenn:

- interaktive Diagnoseausgaben weiterhin die für die Analyse notwendigen Identitäten und Umgebungsbezüge liefern können,
- kein Resultset und kein OUTPUT-Parameter wegen dieses Vertrags maskiert oder reduziert wird,
- keine reale Laufzeitausgabe als Repository-, Test-, Dokumentations- oder Lieferinhalt eingecheckt wird,
- Code, Kommentare und Dokumentation keine aus Hardcopys, Screenshots, Chats, Uploads oder realen Umgebungen übernommenen internen Namen oder Strukturen enthalten,
- Beispiele ausschließlich eindeutig synthetische, generische Werte ohne Nachbildung realer interner Strukturen enthalten,
- Persistenz- und Exportfunktionen einen dokumentierten Datenschutz-, Berechtigungs-, Retention- und Löschvertrag besitzen; der erste SC-023-Slice ist separat implementiert und durch die synthetische Drei-Versionen-Matrix als `IMPLEMENTED_ACTIONS_GATE` abgenommen,
- ein uneindeutiger Datenfund die Fragepflicht auslöst,
- die Prüfung keine sensitiven Werte selbst in Auditmeldungen vervielfältigt.

## 10. Vorgehen bei einem Fund

Vor einem Commit wird die betroffene Datei nicht übernommen und durch eine synthetische Fassung ersetzt. Ist ein Wert bereits in Git veröffentlicht, genügt das Löschen in einem neuen Commit nicht, weil er in der Historie verbleiben kann. Dann sind Repositoryverantwortliche einzubeziehen und Reichweite, Historienbereinigung, bereits erzeugte Downloads sowie gegebenenfalls weitere Datenschutz- oder Sicherheitsmaßnahmen separat zu bewerten.
