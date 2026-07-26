# Wait-Stats-Methodik

Die Methodik verbindet aktuelle Task-Waits mit kumulativen oder gesampelten Instanz-Waits. Die SQLskills-Waits-and-Queues-Referenzen dienen als praktische Vertiefung; die jeweilige SQL-Server-DMV und ihre dokumentierte Reset-Semantik bleiben für den Messvertrag maßgeblich.

1. Aktuelle Task-Waits werden nicht durch eine historische Ausschlussliste verborgen.
2. Instanz-Waits werden bevorzugt als Delta zwischen zwei Snapshots bewertet.
3. Ohne Messfenster werden kumulative Werte ausdrücklich als Kontext seit Start/Reset gekennzeichnet.
4. Benigne Hintergrund-Waits werden nur im Standardranking ausgeblendet und können eingeblendet werden.
5. Das Ranking zeigt standardmäßig die Waits, die zusammen bis zu 95 Prozent der Wartezeit erklären.
6. Resource-, Signal- und Gesamtwartezeit sowie Durchschnittswerte werden getrennt ausgewiesen.
7. Jeder Wait erhält Gruppe, Bedeutung, typisches Auftreten, mögliche Folgen, empfohlene Folgeprüfungen und eine direkte SQLskills-URL.
8. Neue/unbekannte Wait Types erhalten einen stabilen Fallback statt NULL.

## Referenzen

- [Microsoft: sys.dm_os_wait_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql)
- [Microsoft: sys.dm_os_waiting_tasks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-waiting-tasks-transact-sql)
- [SQLskills: Wait statistics methodology](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/)
- [SQLskills: Wait types library](https://www.sqlskills.com/help/waits/)
