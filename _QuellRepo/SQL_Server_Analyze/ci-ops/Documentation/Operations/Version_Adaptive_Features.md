# Versionsadaptive Featurestrategie

Öffentliche Objekte werden nicht nach einer SQL-Server-Version benannt. Jede allgemeine Analyse wählt intern die für die erkannte Version, Plattform und Capability vorgesehene Quelle.

Die folgenden Statuswerte beschreiben die Verfügbarkeit der jeweiligen Quelle:

- `AVAILABLE`: native Information verfügbar.
- `PARTIAL`: Aussage ist möglich, einzelne Zusatzfelder fehlen.
- `UNAVAILABLE_VERSION`: die Information existiert auf dieser Serverversion nicht.
- `UNAVAILABLE_PLATFORM`: nur auf einer anderen Plattform verfügbar.
- `UNAVAILABLE_FEATURE`: Feature nicht installiert/aktiviert.
- `DENIED_PERMISSION`: Quelle existiert, ist aber nicht lesbar.

Wenn eine neue Quelle nur zusätzliche Details liefert, bleibt die ältere äquivalente Kernaussage erhalten. Beispiele dafür sind das allgemeine Indexinventar ohne Vector-Metadaten, die allgemeine Query-Store-Auswertung ohne Replica-Dimension und die allgemeinen OS-DMVs ohne Linux-Host-DMVs.
