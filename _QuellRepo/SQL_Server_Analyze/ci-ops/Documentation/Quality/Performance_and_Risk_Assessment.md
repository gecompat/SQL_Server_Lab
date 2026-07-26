# Performance- und Risikobewertung

Stand: 2026-07-16

## Bewertungsrahmen

Die Bewertung betrachtet Eigenlast, Blocking-Risiko, Compile-/Versionsrisiko, Berechtigungsfehler, Ergebnisvollständigkeit und Wartbarkeit. Sie ersetzt keinen Last-, Compile- oder Plattformtest.

## Zentrale Risiken und Gegenmaßnahmen

### Versionsabhängige Quellen

Nicht vorhandene DMVs, DMFs, Views oder Spalten können bereits bei Kompilierung oder Statement-Kompilierung scheitern. Optionale Quellen werden deshalb über Version, Featurezustand und kurze dynamische Statements isoliert. Erwartete Fehler werden in Frameworkstatus übersetzt; andere Module laufen weiter.

### Berechtigungen

`HAS_PERMS_BY_NAME` und Katalogprobes sind Vorabindikationen, kein Ersatz für `TRY/CATCH`. Datenbanksichtbarkeit, Plattform, Edition, Rollenstatus und objektspezifische Regeln können weiterhin Teilresultate verursachen. Das Framework führt keine `GRANT`, `DENY`, `REVOKE`, Rollen-, Login- oder User-Anlage aus.

### Breite Plan- und Katalogscans

Plan Cache, Showplan XML, Query Store, Physical Stats und breite Cross-Database-Katalogläufe können hohe CPU-, I/O-, Speicher- oder Laufzeitkosten verursachen. Gegenmaßnahmen:

- gezielter Modus als Default;
- globale Zeilenbegrenzung getrennt von `@MaxAnalyseobjekte`;
- vollständige Datenbankkandidatenmenge vor globaler Bewertung und Sortierung;
- `@HighImpactConfirmed=1` für den tatsächlich aktivierten breiten Pfad;
- lokale Kandidatenmenge vor globalem Ranking;
- Gruppenpolicy vor dem teuren Quellzugriff;
- optionale Zeitbudgets und `LOCK_TIMEOUT`-Behandlung;
- XML-Shredding erst nach Kandidatenselektion.

### Metadaten und Blocking

Breite Diagnosepfade sollen Namensauflösungsfunktionen vermeiden, wenn Systemkatalog-Joins mit `READUNCOMMITTED` beziehungsweise `NOLOCK` ausreichen. Nicht auflösbare Namen ergeben ein Teilergebnis; technische IDs bleiben verfügbar. Installations- und lokale Temp-Tabellen-Prüfungen sind davon getrennt zu betrachten.

### Dynamic SQL

Datenbank-, Schema- und Objektidentifier werden aus validierten Parsergebnissen aufgebaut und mit `QUOTENAME` geschützt. Freier Benutzertext wird ausschließlich als Parameter an `sp_executesql` übergeben. Datenbankwechsel werden pro Quelle isoliert.

### Current State, Delta und Historie

Live-DMVs liefern Moment- oder kumulative Werte. Sampling innerhalb eines Aufrufs erzeugt ein Delta, aber keine persistente Historie. Query Store und vorhandene Extended Events sind getrennte persistente Quellen. Das Framework speichert standardmäßig nichts.

### Optionaler externer Kontext

Frühere Ansätze enthielten umgebungsspezifische Logging-, Metadaten-, Queue- und Hilfsobjekte. Diese statischen Abhängigkeiten wurden nicht migriert. Ein späterer Adapter muss vollständig konfigurierbar, dynamisch gequotet, minimal probiert und vom Core fehlertolerant getrennt sein.

### Große Text- und XML-Werte

SQL-Text, Batch-, Modul-, Input-Buffer-, Plan- und Event-XML können groß sein. Defaultausgaben kürzen oder lassen teure Inhalte opt-in. `@MaxSqlTextZeichen = 0` beziehungsweise `NULL` ist bewusst möglich, kann aber Netzwerk, Client und Speicher deutlich belasten.

## Status- und Fehlerklassen

Wesentliche Statuswerte sind `AVAILABLE`, `AVAILABLE_LIMITED`, `PARTIAL`, `SKIPPED`, `NOT_APPLICABLE`, `UNAVAILABLE_VERSION`, `UNAVAILABLE_PLATFORM`, `UNAVAILABLE_FEATURE`, `UNAVAILABLE_OBJECT`, `DATABASE_UNAVAILABLE`, `DENIED_PERMISSION`, `DENIED_GROUP`, `TIMEOUT`, `ERROR_HANDLED` und `INVALID_PARAMETER`.

## Weiterführende Verifikation

- dokumentierte Wiederholung des realen Tests für jede zusätzlich freizugebende SQL-Server-Version und Edition;
- Tests unter unterschiedlichen Performance-State-Berechtigungen;
- Windows- und Linux-Plattformpfade;
- große Plan-Cache-/Query-Store-Bestände;
- AG-Primary/Secondary, Replikation, Log Shipping und Resource Governor;
- Eventfile- und Ringbuffer-Limits;
- clientseitige Belastung durch ungekürzte Text-/XML-Ausgaben.
