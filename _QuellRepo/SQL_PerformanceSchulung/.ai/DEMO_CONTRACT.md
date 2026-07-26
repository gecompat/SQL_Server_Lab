# Demo-Vertrag

## Verbindliche Framework-Basis

Jede ausführbare Demo verwendet die Verträge aus `Demos/00_Framework/`:

- `FWK-001` für den read-only Preflight,
- `FWK-002` für Name, Eigentumsmarker und Lifecycle der synthetischen Testdatenbank,
- `FWK-003` für deterministische synthetische Datenprofile,
- `FWK-004` für sessionbezogene Baseline-, Demonstrations- und Vergleichsmessungen,
- `FWK-005` für Plan- und Statistikevidenz,
- `FWK-006` für deterministische Multi-Session-Orchestrierung,
- `FWK-007` für Query-Store- und Extended-Events-Lifecycle,
- `FWK-008` für Sicherheitsstufe, Bestätigung, Abbruch und Recovery,
- `FWK-009` als Dokumentstruktur,
- `FWK-010` für sequenzielle Phasen, Zeitbudgets, Summary-Auswertung und Cleanup,
- `FWK-011` für maschinenunabhängige Ergebnisassertionen,
- `FWK-012` für `PASS`, `WARN`, `SKIP`, `FAIL` und die zugehörigen Codes.

Eine Abweichung ist im Demo-README fachlich zu begründen und durch einen gleichwertigen oder strengeren Test nachzuweisen.

## Toolklassen

- SQL-Server-DMVs, Katalogsichten, Query Store und Extended Events sind Systemobjekte.
- Die mitgelieferten Python-Module, SQL-Vorlagen und `fwk`-Prozeduren sind User-defined Tools des Projekts.
- `sqlcmd` ist ein externes Microsoft-Tool. Das Framework installiert es nicht und gibt bei Fehlen `SKIP_TOOL_MISSING` aus.

## Pflichtangaben

Jede Demo dokumentiert:

1. stabile Demo-ID und Titel,
2. Lernziel,
3. fachliche Kernaussage und Evidenzklasse,
4. SQL-Server-Version, Compatibility Level, Edition und Betriebssystemabhängigkeiten,
5. erforderliche Rechte, Konfiguration und Ressourcen,
6. Mindestanforderungen an die Host-Hardware,
7. Sicherheitsstufe,
8. geschätzte Laufzeit, Sessionzahl und Speicherbelegung,
9. Setup und synthetisches Datenmodell,
10. Baseline-Messung,
11. kontrollierte Problemerzeugung,
12. Beobachtung und technische Evidenz,
13. Gegenmaßnahme,
14. Vorher-/Nachher-Vergleich,
15. erwartete Resultate und zulässige Abweichungen,
16. Cleanup, Abbruch und Wiederherstellung geänderter Optionen,
17. Quellen mit Abrufdatum,
18. Traceability zu Lernziel, Claim, Demo-ID und Testprofil.

## Empfohlener Dateiaufbau

| Datei/Pfad | Zweck |
|---|---|
| `README.md` | Lernziel, Ablauf, Voraussetzungen, Interpretation, Tests und Quellen |
| `00_Preflight.sql` | Version, Rechte, Edition, Datenbankzustand, Sicherheits- und Ressourcenprüfung |
| `10_Setup.sql` | idempotenter Aufbau der isolierten Labordaten |
| `20_Baseline.sql` | Ausgangsmessung |
| `30_Demonstration.sql` | kontrollierte Erzeugung des Effekts |
| `40_Observation.sql` | Plans, DMVs, Query Store oder Extended-Events-Evidenz |
| `50_Mitigation.sql` | gezielte Gegenmaßnahme |
| `60_Comparison.sql` | identische Messung nach der Gegenmaßnahme |
| `90_Cleanup.sql` | vollständige, wiederholbare Bereinigung und Recovery |
| `Sessions/` | nummerierte Batches für Multi-Session-Szenarien |
| `Expected/` | datenschutzgeprüfte, synthetische Erwartungsresultate und `FWK-011`-Verträge |
| `manifest.json` | optionaler `FWK-006`- oder `FWK-010`-Prozessvertrag |

Nicht jede Demo benötigt jede Datei. Fehlende Phasen sind im README zu begründen. Setup und Cleanup dürfen keine versteckte Abhängigkeit von einer Steuerdatenbank oder nicht mitgelieferten Objekten besitzen.

## Testdatenbankvertrag

Synthetische Testdatenbanken folgen dem Schema:

```text
SQLPERF_LAB_<DEMO-ID OHNE BINDESTRICH>_<RUN-TOKEN>
```

Der Name wird aus kanonischer Demo-ID und synthetischem Run-Token abgeleitet. Vor einer Entfernung müssen die Marker `SQLPERF.Project`, `SQLPERF.ContractVersion`, `SQLPERF.DemoId` und `SQLPERF.RunToken` vollständig und exakt übereinstimmen. Ein passender Name allein genügt nicht.

Der Datenaufbau verwendet keine realen Daten oder nicht deterministischen Zufallsquellen. Derselbe Seed und dieselben Generatorparameter müssen dieselbe fachliche Verteilung erzeugen; physische Page-Verteilung und Laufzeit sind davon ausdrücklich ausgenommen.

## Multi-Session-Regeln

Fachliche Sessionreihenfolge wird durch `fwk.USP_Signal` und `fwk.USP_WaitForSignal` gesteuert. Starre Wartezeiten dürfen nur Prozessstarts staffeln, nicht fachliche Abhängigkeiten beweisen. Sessionmanifeste enthalten keine Server-, Benutzer- oder Passwortwerte. `SQLCMDPASSWORD` ist die einzige zulässige Passwortquelle für SQL-Authentifizierung.

## Query-Store- und Extended-Events-Regeln

Query Store wird nur in der markierten Testdatenbank verändert. Vor `ENABLE` wird ein rekonstruierbarer Ausgangszustand gesichert; `CLEAR` und `RESTORE` benötigen ausdrückliche Bestätigungen.

Die Extended-Events-Referenzsession verwendet einen deterministischen `SQLPERF_*`-Namen, `ring_buffer` mit begrenztem Speicher und `STARTUP_STATE = OFF`. Eine Event-Datei oder automatischer Export ist nicht Bestandteil des Frameworks. Query-Store- oder XE-Exporte sind eigenständige Privacy-prüfpflichtige Artefakte.

## Sicherheitsstufen

### Grün

Lokal begrenzte T-SQL-Demo ohne relevante Instanzwirkung. In einer dedizierten, markierten Schulungsdatenbank ausführbar.

### Gelb

Erzeugt kontrolliert hohe CPU-, RAM-, TempDB-, I/O-, Log- oder Concurrency-Last. Benötigt ein bestätigtes isoliertes Lab, eine positive Laufzeitgrenze, Abbruchsignal und Recovery.

### Rot

Verändert Instanz- oder Betriebssystemkonfiguration, leert globale Caches, startet Dienste neu, manipuliert Infrastruktur oder erzeugt absichtlich beschädigte Zustände. Ausschließlich in einer bestätigten wegwerfbaren Lab-Umgebung mit dokumentiertem Resetpfad. Rote Demos laufen nicht im unbeaufsichtigten Standard-CI.

## Mess- und Ergebnisregeln

- Vorher und nachher dieselbe Abfrage, Parametrisierung und Messmethode verwenden.
- CPU, Duration, Logical Reads, Physical Reads, Writes, Rows und Memory Grant passend zum Thema erfassen.
- Cache- und Warm-up-Effekte ausdrücklich behandeln.
- Einzelläufe nicht als allgemeingültigen Benchmark darstellen.
- Hardwareabhängige Resultate als empirisch kennzeichnen.
- Instanzweite DMV-Summen nur als Delta eines definierten Zeitfensters interpretieren.
- Sessionbezogene Messungen müssen Start und Ende in derselben Session ausführen.
- Actual Execution Plan, Query Store, Extended Events und Statistikmetadaten sind Evidenzquellen, aber kein alleiniger Ursachenbeweis.
- Fachliche Invarianten werden als `EXACT` oder `RANGE` geprüft.
- Performancewirkungen werden bevorzugt als `RATIO_MAX`, `RATIO_MIN` oder `DIRECTION` beschrieben.
- Absolute Zeitgrenzen sind nur bei technisch kontrolliertem und dokumentiertem Ressourcenprofil zulässig.
- Die Gesamtergebnispriorität lautet `FAIL > SKIP > WARN > PASS`.

## Runtime-Harness-Regeln

Der Harness verwendet ein globales Zeitbudget für reguläre Phasen und ein separates begrenztes Cleanup-Budget. Ein erforderlicher `SKIP` beendet zustandsverändernde Folgephasen. Ein optionaler Evidenz-Skip wird als `WARN_OPTIONAL_EVIDENCE_SKIPPED` fortgeführt. Nach gestarteter Setup-Phase wird Cleanup unabhängig vom vorherigen Ergebnis versucht; Cleanup-Fehler ergeben `FAIL_CLEANUP`.

## Verbote

- Keine realen Diagnosedaten oder Screenshots als Repository-Artefakt.
- Keine globalen Eingriffe ohne rote Kennzeichnung und Preflight.
- Keine verschleierten Abhängigkeiten von nicht mitgelieferten Datenbanken.
- Keine Erfolgsaussage ohne messbare Evidenz.
- Kein `DROP DATABASE` aufgrund eines Namens allein.
- Keine Beendigung fremder Sessions allein nach Loginname, Application Name oder Hostname.
- Keine festen, maschinenunabhängig behaupteten Laufzeit- oder Ressourcenschwellen.
- Keine automatische Persistierung von Plan-XML, Querytexten, Event-Daten oder Prozessoutput als Repository-Artefakt.
