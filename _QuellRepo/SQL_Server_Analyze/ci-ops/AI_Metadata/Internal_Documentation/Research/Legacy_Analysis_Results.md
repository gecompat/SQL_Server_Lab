# Analyseergebnisse aus früheren Diagnoseansätzen

Es wurden ausschließlich abstrahierte technische Erkenntnisse übernommen. Rohskripte, umgebungsspezifische Objektbezeichner, externe Hilfsfunktionen und kundenspezifische Integrationen sind nicht Bestandteil dieses Repositorys.

## Übernommene Erkenntnisse

- Laufende Statements werden über `statement_start_offset` und `statement_end_offset` aus dem Batchtext extrahiert.
- Kataloginformationen werden möglichst über Systemkataloge und DMVs gelesen; blockierende Namensauflösungsfunktionen werden in breiten Abfragen vermieden.
- Blocking wird als Beziehung zwischen wartendem Request, Blocker und Root Blocker modelliert.
- Wait Types werden kategorisiert und immer im zeitlichen beziehungsweise workloadbezogenen Kontext bewertet.
- Query Store wird je Datenbank gelesen; datenbankübergreifende Analysen wechseln kontrolliert den Datenbankkontext.
- Showplan- und Plan-Cache-Analysen sind opt-in und begrenzen Analyseobjekte unabhängig von der Ergebniszeilenbegrenzung.
- Optionale, umgebungsspezifische Logging- oder Metadatenadapter gehören nicht in den generischen Core.
- Externe Hilfsobjekte werden nicht vorausgesetzt; benötigte Parser und Hilfsfunktionen sind frameworkintern implementiert.

## Nicht übernommen

- Rohquellcode früherer Diagnosewerkzeuge
- konkrete Datenbank-, Schema-, Tabellen-, Funktions-, Login- oder Organisationsnamen
- kundenspezifische Logging-, ETL- oder Fachobjekte
- nicht allgemein gültige Berechtigungs- oder Infrastrukturannahmen
