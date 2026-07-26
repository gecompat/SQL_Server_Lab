# Verbindliche Zeilenbegrenzung

Stand: 2026-07-20

Diese Regeln trennen das Limit der zurückgegebenen Zeilen vom Budget für vorgelagerte Quellarbeit und Tiefenanalysen. Ein kleines Ergebnislimit bedeutet daher nicht automatisch, dass nur wenige Quellzeilen gelesen oder sortiert wurden.

- Die öffentliche Ergebnisbegrenzung heißt ausschließlich `@MaxZeilen`.
- Standardaufrufe verwenden eine endliche Ergebnisbegrenzung.
- `@MaxZeilen = NULL` oder `0` liefert technisch alle fachlich passenden Zeilen.
- Negative Werte liefern `INVALID_PARAMETER`, bevor teure Datenzugriffe beginnen.
- Jede Verwendung von `TOP` besitzt ein fachlich stabiles `ORDER BY`.
- `@MaxAnalyseobjekte` bleibt ein eigenständiges Tiefenanalysebudget und darf nicht mit `@MaxZeilen` vermischt werden.
- Bei globalen Query-Store-Ranglisten wird je Quelldatenbank lokal `N+1` gelesen und anschließend global `TOP (N)` gebildet. Dadurch wird nicht der vollständige Query Store aller Datenbanken materialisiert.
- Datenbankkandidaten werden vor der globalen Bewertung oder Sortierung nicht willkürlich gekürzt.
