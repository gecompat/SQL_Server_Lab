# Architekturentscheidungen

1. Installationsdatenbank wird über den Platzhalter `[DeineDatenbank]` in jedem SQL-Skript explizit gewählt.
2. Das Schema lautet `[monitor]`.
3. Öffentliche API-Namen und Resultsetspalten sind exakt case-sensitiv.
4. Steuerwerte werden getrimmt und in eine kanonische Großschreibung überführt.
5. Gleiche Funktionalität verwendet überall denselben Parameternamen, Datentyp und dieselbe Semantik.
6. Standard-Scope sind alle sichtbaren, online befindlichen Benutzerdatenbanken; es gibt weder einen impliziten CURRENT-Scope noch eine datenbankbezogene Vorbegrenzung. Exakte Namen und Pattern schränken ausschließlich explizit ein, Systemdatenbanken bleiben opt-in.
7. Eine High-Impact-Bestätigung wird ausschließlich für tatsächlich aktivierte ressourcenintensive Analysepfade verlangt und muss vor deren erstem Systemzugriff geprüft werden; leichte Cross-Database-Pfade bleiben ohne Deep-Gate nutzbar.
8. RAW, CONSOLE, TABLE und JSON basieren innerhalb eines Aufrufs auf derselben kanonisch materialisierten Datenbasis. CONSOLE liefert normalerweise genau ein fachliches Resultset; TABLE verwendet ausschließlich die benannte JSON-Mehrfachzuordnung `@ResultTablesJson`.
9. TABLE-Resultsetnamen und Schemas sind stabil im Resultsetinventar dokumentiert. Unbekannte Namen, doppelte Ziele und ungültige lokale Temp-Tabellen werden vor dem fachlichen Systemzugriff abgelehnt.
10. Datenbank-, Schema-, Objekt- und weitere exakte Filter können Mehrfachwerte über bracket-aware Pipe-Listen erhalten.
11. Regex ist ein optionales versionsabhängiges Feature und wird nie stillschweigend in LIKE umgedeutet.
12. Query Store ist datenbankbezogen; globale Top-N-Ausgaben verwenden lokale Kandidatenmengen und ein abschließendes globales Ranking.
13. Memory Grants werden mit Workload Group, Resource Pool, Resource Semaphore und fachlich benannten Prozentkennzahlen korreliert.
14. Historische, umgebungsspezifische Quellen werden nicht im Repository archiviert.
15. Git ist die maßgebliche Versions- und Integritätsquelle; ein zusätzliches per-Datei-Hash-Manifest wird nicht gepflegt.
16. Der Platzhalter `[DeineDatenbank]` darf nur als einleitender `USE`-Kontext oder in ausdrücklich gekennzeichneten Beispielen vorkommen, nie als ausführbares internes Stringliteral.
17. Historische Quellenanalysen werden ausschließlich abstrahiert als Systemquellen-, Capability-, Abhängigkeits- und Risikokatalog migriert.
18. Tool-Hintergrundabfragen werden ausschließlich diagnostisch über priorisierte, aktivierbare `LIKE`-Regeln in `monitor.ToolBackgroundQueryPattern` klassifiziert. Default ist Ausblenden; Opt-in zeigt Regel und Konfidenz. Blocking filtert nur erkannte Tool-Blätter und erhält Tool-Zwischen-/Root-Blocker normaler Ketten.
19. `USP_CurrentBlocking` materialisiert vollständige sichtbare Ketten vor Session- und Toolfilterung und liefert neben direktem Blocker die lesbare Kette sowie Status-, Identitäts-, Transaktions- und Statementkontext des äußersten Root Blockers.
