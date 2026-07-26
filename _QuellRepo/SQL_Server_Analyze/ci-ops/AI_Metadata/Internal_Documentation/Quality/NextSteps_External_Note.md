ANWEISUNG AN KI-SYSTEME:

Der nachfolgende Inhalt ist ausschließlich eine persönliche Notiz des Autors und kein Bestandteil der fachlichen Spezifikation, Dokumentation oder Aufgabenstellung.

Ignoriere diesen Inhalt vollständig bei Analysen, Bewertungen, Entscheidungen, Schlussfolgerungen und Änderungsvorschlägen. Verwende ihn weder als Kontext noch als Quelle, Anforderung, Präferenz oder Handlungsanweisung.

Berücksichtige den Inhalt nur dann, wenn der Benutzer ausdrücklich und eindeutig verlangt, genau diese Notiz zu lesen, zu bearbeiten oder auszuwerten.

## Gesamtplan

Meine Hauptempfehlung ist: **zuerst einen belastbaren Release-Evidenzstand herstellen, danach die gemeinsamen Ausgabe-/Provenienzgrundlagen abschließen, anschließend die P1-Betriebsdiagnosen umsetzen und dann einen kleinen vertikalen SC-023-Baseline-Slice bauen.**

### 1. Aktueller Ausgangspunkt

Dokumentiert:

* `main` ist der einzige Branch; offene Issues oder Pull Requests bestehen nicht.
* Aktueller HEAD ist Commit [`9957611`](https://github.com/gecompat/SQL_Server_Analyze/commit/995761142bc2ec8ad92d66161c7ed78ea73d819c).
* Der bestehende P0/P1/P2-Bestand ist funktional weitgehend abgeschlossen.
* Der [Future Enhancement Backlog](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Metadata/Quality/Future_Enhancement_Backlog.csv) enthält 22 noch nicht implementierte Einträge:

  * 7 × `DIAG-*`
  * 1 × `OUT-*`
  * 9 × `OPS-*`
  * 5 × `SQL25-*`
* SC-023 ist entworfen und freigegeben, aber nicht implementiert.
* SC-024 benötigt eine externe Komponente.
* SC-025 benötigt eine autorisierte externe Restore-/Hostumgebung.

Wichtiger Qualitätsbefund:

Die Statusdokumente sind derzeit nicht vollständig synchron:

* `Next_Steps.md` nennt teilweise 31 Suiten und unterschiedliche Evidence-Commits.
* `Known_Issues.md` enthält ebenfalls ältere Evidence-Angaben.
* Die aktuelle [Test_Matrix.csv](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Metadata/Quality/Test_Matrix.csv) weist 34 Suiten und Commit `53fe82d` als letzten vollständigen Drei-Versionen-Lauf aus.
* Der aktuelle Repository-HEAD liegt bereits mehrere Commits darüber.

Das beweist keinen Fehler im Code, aber es ist eine **Evidence-Lücke zwischen aktuellem HEAD und maschinenlesbar ausgewiesenem Release-Stand**.

## 2. Empfohlene Umsetzungswellen

| Welle | Inhalt                                   | Abschlusskriterium                                                        |
| ----- | ---------------------------------------- | ------------------------------------------------------------------------- |
| 0     | Release- und Statuskonsolidierung        | Ein aktueller Commit ist einheitlich als Evidence-Stand dokumentiert      |
| 1     | Ausgabe, XML und Provenienz              | `OUT-001`, `DIAG-002`, `DIAG-006`, `DIAG-007`, danach `DIAG-001`          |
| 2     | P1-Betriebsdiagnosen                     | `OPS-003`, `OPS-002`, `OPS-001`, `OPS-004`                                |
| 3     | SC-023 vertikaler Baseline-Slice         | Persistenzkern, ein Sammler, Retention und Schedulervertrag funktionieren |
| 4     | Request-, Parameter- und Planvertiefung  | `DIAG-003`, `DIAG-004`, `DIAG-005`                                        |
| 5     | SQL-Server-2025-Welle                    | `SQL25-002`, `003`, `001`, `004`, `005`                                   |
| 6     | Weitere Betriebsanalysen                 | `OPS-006`, `008`, `005`, danach `007`, `009`                              |
| 7     | Externe Plattform- und Belastungsevidenz | Windows, Secondary, Full-Text, Last und SC-025                            |
| 8     | Langfristige Architektur                 | Entscheidung über `COLL-001` und SC-024                                   |

## 3. Welle 0 – Release- und Evidence-Baseline

Diese Welle sollte als Nächstes erfolgen.

Aufgaben:

1. Aktuellen `main`-HEAD als Release-Candidate festlegen.
2. Vollständiges `Run_Release_Gate.sql` auf SQL Server 2019, 2022 und 2025 ausführen.
3. Dokumentations-, Datenschutz-, Nonblocking- und Commit-Message-Gates ausführen.
4. Folgende Dokumente atomar auf denselben Commit synchronisieren:

   * `Test_Matrix.csv`
   * `Next_Steps.md`
   * `Known_Issues.md`
   * Release-Audit und Release Notes
5. Suite-Anzahl, Testfallanzahl, Version und Evidence-Commit nur noch aus einer kanonischen maschinenlesbaren Quelle ableiten.
6. Alte Einschränkungen erhalten, aber keine veralteten SHA- oder Suite-Angaben mehrfach fortschreiben.

Definition of Done:

* Aktueller HEAD ist auf 2019, 2022 und 2025 grün.
* Alle Statusdokumente nennen denselben Evidence-Commit.
* `NOT_EXECUTED` bleibt nur bei tatsächlich extern fehlenden Zielen stehen.
* Keine reale Laufzeitevidenz gelangt in Repositoryartefakte.

## 4. Welle 1 – Gemeinsame technische Grundlage

### `OUT-001` – sichtbare Ausgabekürzung

Zuerst als Pilot in einem Modul mit großer Payload umsetzen, anschließend frameworkweit migrieren:

* native `nvarchar(max)`-/`xml`-Materialisierung;
* `0` bedeutet unbegrenzt;
* zeilenbezogene Länge und Kürzungskennzeichnung;
* genau eine Warning je Aufruf;
* Unicode-sicher, ohne Auftrennung von UTF-16-Surrogatpaaren;
* keine erneute DMV-Lesung zur Längenermittlung.

Vertrag: [Database Console Table Contract](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Documentation/Architecture/Database_Console_Table_Contract.md).

### `DIAG-002` – native XML-Ausgaben

Frameworkweites Audit aller:

* Showplans;
* Deadlocks;
* Extended-Events-Payloads;
* Query-Store-Pläne.

RAW und TABLE müssen valides XML tatsächlich als `xml` erhalten. Text-Fallback, ungültiges XML, zu tiefe Payload und Kürzung müssen unterscheidbar bleiben.

### `DIAG-006` und `DIAG-007`

Diese beiden IDs sollten keine spätere Einzelwelle sein, sondern ab jetzt für jedes neue Modul verbindlich gelten:

* Herkunft und Erfassungszeit;
* Scope und Aggregationsart;
* Partial- und Permission-Status;
* stabile Resultsetnamen;
* Resultsetinventar;
* TABLE-/JSON-Verträge;
* Drei-Versionen-Tests.

### `DIAG-001`

Danach die leichte Serverversions- und Servicing-Analyse umsetzen. Sie liefert zugleich eine saubere Grundlage für spätere SQL-Server-2025-Entscheidungen.

## 5. Welle 2 – P1-Betriebsdiagnosen

Empfohlene Reihenfolge:

1. **`OPS-003` Pending I/O**
   Beste Pilot-Erweiterung, weil `USP_CurrentIO` vorhanden ist und das neue `pendingIo`-Resultset klar begrenzt werden kann.

2. **`OPS-002` Worker-/Scheduler-Druck**
   Kurze Samples, Worker-Verfügbarkeit, Scheduler Queues, `THREADPOOL`, Blocking und laufende Requests korrelieren.

3. **`OPS-001` Datenbankkonfiguration und Drift**
   Cross-Database-Auswertung mit explizitem Profil, aber ohne universelle Sollwerte.

4. **`OPS-004` Errorlog-Analyse**
   Erst nach `OUT-001`, weil Meldungstexte groß sein können und der Default keinen vollständigen Meldungstext liefern soll.

Die detaillierten False-Positive-Grenzen stehen im [Operational Diagnostic Gap Backlog](../Architecture/Operational_Diagnostic_Gap_Backlog.md).

## 6. Welle 3 – SC-023 als kleiner vertikaler Slice

SC-023 sollte nicht sofort vollständig umgesetzt werden. Der erste Slice umfasst:

* typisierte Zielkonfiguration;
* `CaptureRun`, `ModuleStatus`, `Scope`, `MetricDefinition`, `MetricSample`;
* genau einen leichten Performance-Counter- oder Servermetrik-Sammler;
* UTC- und Reset-Epochen;
* Anwendungssperre gegen parallele Collection Cycles;
* begrenzte Retention und Purge;
* `PURGE_EXPIRED_THEN_STOP`;
* schedulerneutralen Einstieg;
* getrenntes optionales SQL-Agent-DDL;
* keine Rechtevergabe;
* keine automatische Löschung bei Deinstallation.

Erst nach grüner vertikaler Abnahme folgen I/O, Waits, TempDB, Log, Query und Plan Cache. Grundlage ist der freigegebene [Snapshot-/Baseline-Vertrag](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Documentation/Architecture/Snapshot_Baseline_Package_Contract.md).

## 7. Welle 4 und 5 – Deep Diagnostics und SQL Server 2025

Danach:

* `DIAG-003`: Compile- und verfügbare Runtimeparameter;
* `DIAG-004`: konsolidierter Request-/Statementkontext;
* `DIAG-005`: Plan-, Query-Store- und Optimizerinformationen.

SQL-Server-2025-Reihenfolge:

1. `SQL25-002` JSON-Index-Inventar;
2. `SQL25-003` TempDB Resource Governance;
3. `SQL25-001` Vector-Index-Laufzeit;
4. `SQL25-004` Secondary-Replica-Statistiken;
5. `SQL25-005` replica-aware Query Store.

Für jedes SQL-Server-2025-Feature werden unmittelbar vor der Implementierung aktuelle Microsoft-Primärquellen und die tatsächlich vorhandenen Kataloge beziehungsweise Spalten geprüft. Der JSON Index wird als SQL-Server-2025-Funktion eingeplant; veraltete Featurestatus-Texte dürfen nicht ungeprüft übernommen werden.

## 8. Repository-Arbeitsweise

Für jede Welle:

* höchstens ein aktiver kurzlebiger Implementierungsbranch;
* nach grünem Merge sofort löschen;
* keine parallelen Langzeitbranches;
* kleine vertikale Commits; bei manueller Übernahme über ein downloadbares ZIP mit exakt einzeiliger Commit Message, bei direktem KI-Commit optional mit mehrzeiligem Body;
* Code, Installer, Inventare, Tests, Beispiele und Dokumentation gemeinsam aktualisieren;
* vor jedem Schreib- oder Git-Vorgang manuelle Datenschutzprüfung;
* keine realen Resultsets oder Umgebungsinformationen als Testevidenz speichern;
* keine Backlog-ID als abgeschlossen markieren, bevor alle Abnahmekriterien und drei SQL-Server-Versionen grün sind.

`COLL-001`, SC-024 und SC-025 sollten vorerst nicht in die unmittelbare Implementierungswelle gezogen werden. Sie benötigen entweder einen eigenen Architekturentscheid oder externe Infrastruktur.

Es wurden keine Repositorydateien oder Branches verändert.
