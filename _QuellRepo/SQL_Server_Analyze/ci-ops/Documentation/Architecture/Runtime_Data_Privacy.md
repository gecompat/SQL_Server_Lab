# Datenschutz und Laufzeitausgaben

## Zweck und Geltungsbereich

SQL Server Analyze ist ein lesendes Diagnoseframework, aber Diagnoseevidenz kann schutzbedürftige Betriebs- und Anwendungsinformationen enthalten. Dieser Vertrag gilt für CONSOLE-, RAW-, TABLE- und JSON-Ausgaben, Meldungen, lokale Temp-Tabellen sowie das optionale Snapshot-/Baseline-Paket.

Das Framework anonymisiert Resultsets nicht automatisch. Eine automatische Ersetzung würde technische Korrelation, Handles, Objektbeziehungen und Ursache-Wirkungs-Prüfungen verfälschen. Zugriff, Anzeige, Export, Übertragung, Aufbewahrung und Löschung bleiben daher kontrollierte Betriebsentscheidungen.

## Möglicherweise schutzbedürftige Felder

| Kategorie | Typische Inhalte | Vorkommen |
|---|---|---|
| Identität und Client | Login, Original Login, Host, Programmname, Clientadresse | Sessions, Requests, Blocking, Agent- und Sicherheitsanalysen |
| SQL- und Modultext | aktuelles Statement, Batch, Moduldefinition, Input Buffer | Current State, Plan Cache, Showplan, Query Store |
| Objekt- und Datenbanknamen | Datenbank, Schema, Tabelle, Index, Statistik, Spalte | nahezu alle objekt- und datenbankbezogenen Analysen |
| Plan- und Laufzeitevidenz | Showplan-XML, Parameterdarstellung, Handles, Hashes, Kardinalitäten | Plan Cache, Query Store, PLAN-001 |
| Ereignisinhalte | XE-Payload, Deadlockgraph, Blocked-Process-Report, Errorlogtext | Extended Events und Engine-Ereignisse |
| Histogrammwerte | Grenzwerte, Verteilungswerte und tokenisierte Schlüssel | Statistikverteilungs- und Plananalyse |
| Infrastruktur | Replica-, Server-, Pfad-, Job-, Operator- und Mailkontext | Infrastruktur, Availability, Agent und Server Health |
| persistierte Evidenz | Metriken und optional freigegebene Payloads | Snapshot-/Baseline-Paket |

Auch scheinbar technische Werte können in Kombination Rückschlüsse auf Mandanten, Produkte, Geschäftsprozesse, Zeitpläne oder interne Topologie erlauben.

## Datenminimierung

1. Mit dem kleinsten fachlich ausreichenden Scope beginnen.
2. Setzen Sie Zeilen- und Datenbanklimits.
3. Aktivieren Sie SQL-Text, vollständigen Batch, Modultext, Input Buffer, XML, XE-Eventdaten und Histogrammwerte nur bei konkretem Bedarf.
4. Zuerst `CONSOLE` verwenden; `RAW`, `TABLE` und JSON nur für eine begründete Weiterverarbeitung.
5. Exakte Datenbank-, Objekt-, Session-, Query-, Plan- oder Zeitfilter einer unbeschränkten Sammlung vorziehen.
6. High-Impact-Bestätigung niemals als Datenschutzfreigabe missverstehen. Sie steuert Ressourcenpfade, nicht die zulässige Nutzung der Daten.

## Ausgabearten

### CONSOLE

CONSOLE ist für die interaktive Sichtung optimiert und reduziert die Zahl der dargestellten Resultsets. Die fachliche Breite einer Zeile bleibt jedoch erhalten. Bildschirmfreigaben, Kopieren und Abfragehistorie können Inhalte vervielfältigen.

### RAW

RAW ist die vollständige technische Schnittstelle. Status, Warnungen und sämtliche exportierbaren Fachresultsets können mehr Kontext als CONSOLE enthalten. RAW eignet sich für kontrollierte Analyse und Integration, nicht für ungeprüfte Weitergabe.

### TABLE

TABLE schreibt nur in lokale `#Temp`-Tabellen des aktuellen Aufrufers. Diese Begrenzung verhindert eine versehentliche persistente Zieltabelle, ersetzt aber keine Zugriffskontrolle innerhalb der Session. Folgeabfragen, Joins und Exporte können den Scope erweitern.

### JSON

JSON entsteht aus derselben Materialisierung wie die Resultsets. Das Format ist leicht übertragbar und kann mehrere fachliche Bereiche bündeln. Behandeln Sie OUTPUT-Variablen, Clientlogs und Anwendungstelemetrie deshalb bewusst.

## Text-, Plan- und Ereignispfade

SQL-Text und Plan-XML können Literale, Parameterdarstellungen, Objektnamen, Kommentare oder Anwendungsstruktur enthalten. `@MaxSqlTextZeichen` begrenzt Darstellung und Transfer, ist aber keine Anonymisierung. Handles und Hashes sind Korrelationsschlüssel; auch sie können zusammen mit anderen Daten sensibel werden.

Extended-Events-Procedures lesen nur bereits vorhandene Sessions und Targets. Der generische Eventlesepfad kann dennoch vollständige Payloads liefern. Dateipfade, Eventnamen, Zeitfenster und Zeilenlimits eng wählen. Deadlock- und Blocked-Process-Resultsets können Statements, Ressourcen und Prozessattribute mehrerer Sessions verbinden.

Histogramme können reale Schlüsselgrenzen enthalten. Die PLAN-001- und Statistikverteilungspfade kennzeichnen sensitive Werte beziehungsweise bieten tokenisierte Formen; die Freigabe eines Histogrammreads bleibt eine bewusste Entscheidung.

## Optionales Snapshot-/Baseline-Paket

Das optionale Paket persistiert nur nach separater Installation, expliziter Zielbindung und aktiver Collectorpolicy. Für jeden Collector sind Scope, Zeitsemantik, Retention, Budget und Payloadfreigabe festzulegen.

- Rohmetriken, Rollups und Payloads besitzen getrennte Retentionwerte.
- `PayloadEnabled = 0` bleibt der sichere Ausgangspunkt.
- Purge arbeitet nach konfigurierter Retention in begrenzten Batches.
- Ein Softbudget verhindert keine kurzfristige Überschreitung, sondern steuert die dokumentierte Reaktion.
- Die Zieldatenbank benötigt einen eigenen Berechtigungs-, Backup-, Verschlüsselungs- und Löschvertrag.

Ein Snapshot ist keine anonyme Baseline. Datenbank-, Scope- und Zeitbezug können auch ohne SQL-Text betriebliche Informationen darstellen.

## Berechtigungen und Verantwortlichkeit

Das Framework vergibt keine SQL-Server-Berechtigungen. SQL-Server-Rechte bestimmen die sichtbaren Quellzeilen; die interne Analyseklassenpolicy begrenzt ressourcenintensive Pfade. Beide Mechanismen ersetzen keine fachliche Berechtigung zur Verwendung oder Weitergabe der Ergebnisse.

Für automatisierte Nutzung sollte ein dedizierter, minimal berechtigter Sicherheitskontext verwendet werden. Zugriff auf persistierte Snapshotziele und auf Systeme, die JSON- oder TABLE-Ergebnisse übernehmen, ist separat zu regeln.

## Leere, partielle und gekürzte Daten

Datenschutzbedingte Minimierung verändert die Aussagegrenze:

- deaktivierter SQL-Text verhindert textbezogene Bewertung;
- ein enges Zeitfenster kann frühere Ereignisse ausschließen;
- `IsPartial = 1`, fehlende Berechtigung oder nicht lesbare Datenbank kann den sichtbaren Scope verkleinern;
- Zeilenlimits können relevante Kandidaten abschneiden;
- Retention kann historische Evidenz bereits entfernt haben;
- gekürzter Text ist kein vollständiger Beleg.

Diese Einschränkungen im Analyseergebnis mitführen. Ein datensparsamer Lauf darf nicht als vollständiger Negativnachweis dargestellt werden.

## Sichere Betriebsfolge

1. Fragestellung und zulässigen Datenumfang bestimmen.
2. Wählen Sie über den [Analysis Navigator](../Reference/Analysis_Navigator.md) den engsten passenden Einstieg.
3. Prüfen Sie die Procedure-Seite auf sensible Felder, Kosten und Voraussetzungen.
4. Führen Sie CONSOLE mit kleinen Limits und deaktivierten optionalen Text- und Payloadpfaden aus.
5. Ergänzen Sie nur fehlende Evidenz gezielt in RAW, TABLE oder JSON.
6. Ergebnisempfänger, Ablageort und Aufbewahrungsdauer vor einem Export festlegen.
7. Temporäre und persistierte Kopien nach dem geltenden Löschvertrag entfernen.
8. In Berichten Scope, Partialität, Kürzung und Retention offen ausweisen.

## Verwandte Verträge

- [RAW-, CONSOLE-, TABLE- und JSON-Architektur](Output_RAW_CONSOLE_JSON.md)
- [SQL-Text-, Statement-, Batch- und Modulkontext](SQL_Text_Statement_Batch_Module.md)
- [Snapshot-/Baseline-Paketvertrag](Snapshot_Baseline_Package_Contract.md)
- [Resultset-Konventionen](../Reference/Resultset_Conventions.md)
- [Parameter-Lesehilfe](../Analysis_Guides/Parameter_Reading_Guide.md)
