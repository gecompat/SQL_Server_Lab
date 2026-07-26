# FWK-004 – Messvertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | sessionbezogene Baseline-, Demonstrations- und Vergleichsmessungen |

## 1. Zweck

Der Messvertrag erfasst vergleichbare Laufzeitdaten, ohne einen einzelnen Messwert als universellen Benchmark zu behandeln. Er trennt sessionbezogene DMV-Deltas, vom Client ausgegebene `STATISTICS IO/TIME`-Informationen, Plan-Evidenz und fachliche Resultatgrößen.

Die Referenzimplementierung misst bewusst nur den aktuellen SQL-Server-Sessionkontext. Sie ist kein instanzweites Monitoring-System.

## 2. Messgrößen

`lab.USP_BeginMeasurement` und `lab.USP_EndMeasurement` erfassen:

- UTC-Start- und Endzeit,
- verstrichene Zeit als Wandzeit,
- Session-CPU-Differenz,
- Session-Differenzen für `reads`, `logical_reads` und `writes`,
- optional sessionbezogene Wait-Deltas,
- eine vom Aufrufer übergebene fachliche Zeilen- oder Ergebnismenge,
- Phase und Wiederholungsnummer.

Die Sessionzähler enthalten auch geringen Mess- und Prozeduroverhead. Für operatorbezogene Laufzeitevidenz ist zusätzlich `FWK-005` zu verwenden.

## 3. Scope und Berechtigungen

Start und Ende müssen in derselben Session erfolgen. Ein Wechsel der Session-ID führt zu `FAIL_STATE`.

Die Sichtbarkeit von `sys.dm_exec_session_wait_stats` ist versions- und berechtigungsabhängig. Für SQL Server 2019 wird bei fremden Sessions `VIEW SERVER STATE`, für SQL Server 2022 und höher `VIEW SERVER PERFORMANCE STATE` benötigt. Die Referenz misst nur die aktuelle Session, behandelt eine nicht verfügbare Wait-Erfassung aber kontrolliert als `WARN` und nicht als falsche Nullmessung.

## 4. Phasen

Zulässige Phasen sind:

- `BASELINE`,
- `DEMONSTRATION`,
- `MITIGATION`,
- `COMPARISON`,
- `WARMUP`.

`WARMUP` darf nicht in die fachliche Vorher-/Nachher-Bewertung einfließen. Baseline und Comparison verwenden denselben Statement-, Parameter-, Daten- und Cachevertrag oder dokumentieren die Abweichung.

## 5. Wiederholungen

Ein einzelner Lauf darf nur als Funktions- oder Richtungshinweis dienen. Für Performanceaussagen dokumentiert die Demo mindestens:

- Anzahl der Wiederholungen,
- ausgeschlossene Warm-up-Läufe,
- Median oder einen anderen begründeten robusten Lagewert,
- Streuung oder zulässige Bandbreite,
- identisches Ressourcenprofil.

Die Referenzimplementierung speichert Rohmessungen; Aggregation und Abnahme erfolgen über `FWK-011`.

## 6. Fehler- und Statusverhalten

- unbekannte Phase oder ungültige Wiederholungsnummer: `FAIL_CONTRACT`,
- nicht markierte Datenbank oder falscher Laufkontext: `FAIL_SAFETY`,
- unbekannte Run-ID, bereits beendeter Lauf oder Sessionwechsel: `FAIL_STATE`,
- nicht verfügbare optionale Wait-Erfassung: `WARN_RESOURCE_PROBE_APPROXIMATE`,
- erfolgreiche Messung: `PASS/OK`.

Ein Messfehler darf die fachliche Demo nicht als erfolgreich markieren. Cleanup bleibt unabhängig zu prüfen.

## 7. Datenschutz

Die Messung speichert keine Querytexte, Pläne, Login-, Host-, Programm- oder Servernamen. Die Run-ID ist zufällig und besitzt keine Benutzerbedeutung. Persistierte Messwerte liegen ausschließlich in der synthetischen Testdatenbank und werden mit ihr entfernt.

## 8. Abnahme

`FWK-004` ist implementiert, wenn:

- Start und Ende technisch gekoppelt sind,
- Sessionwechsel und doppelte Beendigung erkannt werden,
- CPU-, Zeit-, Read- und Write-Deltas nicht negativ ausgegeben werden,
- optionale Wait-Deltas getrennt und mit ihrem Erfassungsstatus dokumentiert werden,
- mehrere Phasen und Wiederholungen gespeichert werden,
- die Ausgabe durch `FWK-011` auswertbar ist.
