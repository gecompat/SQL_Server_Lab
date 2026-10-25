# Native Recovery einer unterbrochenen TLS-Wiederbindung

Am 2026-10-25 wurden zwei getrennte neue eigene Windows-Containerlabs über
den öffentlichen Integrationseinstieg mit `-ExerciseRebindRecovery` abgenommen.
Maßgeblich ist der [Wiederbindungsvertrag](../Architecture/AUTHENTICATED_TLS_CONTAINER_REBIND.md).

| Kontext | Tatsächlicher SQL-Build | Record | Ergebnis |
|---|---|---|---|
| Docker / SQL 2025 CU9 | `17.0.5005.3` | `0.2`, ohne `SqlProfileId` | 15 Fälle PASS, eigener Cleanup PASS |
| Podman / SQL 2019 CU32 | `15.0.4430.1` | `0.3`, `2019-CU32` | 15 Fälle PASS, eigener Cleanup PASS |

Beide Zellen verwenden den gleichen stabilen Produkt- und Harnessstand nach
der unten beschriebenen Parameterkorrektur. Die spätere Integration aktueller
`main`-Änderungen ist ein eigener Prüfschritt; sie ist kein neuer Native-Lauf.

## Geprüftes Verhalten

Der Harness erstellt ein eigenes authentifiziertes Lab und prüft beide echten
Windows-Clientstacks: System.Data.SqlClient und ODBC/sqlcmd. Ein tatsächlicher
öffentlicher Stop/Start macht die alte Start-Epoche und den alten Export ungültig.
Eine auf genau dieses eigene Lab begrenzte Testinjektion unterbricht die
Wiederbindung nach dem atomaren Metadatenersatz. Sie wird vor Recovery entfernt.

Die folgenden Ergebnisse wurden in beiden Zellen ausgeführt:

- Die offene Transaktion ist sichtbar und sperrt gewöhnliche Qualifikation.
- `WhatIf` verändert keine Metadaten.
- `Complete` prüft beide strikten Clients frisch und liefert
  `QUALIFIED_METADATA_COMMITTED`; der alte Export bleibt ungültig.
- Nach einem weiteren echten Stop/Start und einer zweiten Unterbrechung stellt
  `Rollback` nur die exakten eigenen Vorgängermetadaten wieder her. Das Ergebnis
  ist `ROLLED_BACK_UNQUALIFIED` mit `NOT_EXECUTED`, kein TLS-PASS.
- Erst eine spätere ausdrückliche Wiederbindung qualifiziert erneut. Ein neuer
  qualifizierter False-Export führt seine beiden realen Clients aus.

Die 15 Fälle umfassen die bestehenden Arrange-/Export-/CLI-/GUI-/Manipulations-
und Neustartprüfungen sowie acht Recoveryfälle. Die Fallanzahl ist keine
instrumentierte Gesamtzahl aller SQL-Netzwerkverbindungen.

Beide positiven Läufe endeten mit vollständig leerer Windows-Prozessgruppe,
tatsächlich entferntem eigenen Run, bestätigter Container-/Volumeabwesenheit
am ursprünglichen Runtime-Pin, entfernten festen Exporten und bestandenem
Bestandsvergleich. Die vorhandene Authority blieb unverändert. Recovery selbst
ändert ausschließlich eigene Metadaten; bestehende Keys und Trust werden erhalten.

## Erhaltene Fehler und Regression

Der erste Docker-Versuch scheiterte vor Allocation und ohne angelegtes Lab:
Ein Adapter verwendete eine callerrelative PowerShell-Skriptvariable für den
Modulimport. Die Korrektur hält die exakte Modulreferenz über eine Closure.
Ein tatsächliches separates Harnessskript charakterisiert diesen Grenzfall;
sechs fokussierte Prüfungen bestanden ohne Provider- oder SQL-Aktion.

Der zweite Docker-Lauf bestand elf Fälle einschließlich echter Complete-
Recovery und scheiterte anschließend am Harnessaufruf von `Start-SqlServerLab`
mit dem nicht unterstützten Parameter `Confirm`. Sein eigenes Lab wurde
vollständig entfernt. Der ursprüngliche FAIL und seine Teilresultate bleiben
erhalten und werden nicht als vollständiger PASS umgedeutet.

Eine dauerhafte statische Prüfung vergleicht die benannten öffentlichen
Szenarioargumente mit den tatsächlichen exportierten Cmdlet-Metadaten. Sie
reproduzierte exakt den falschen Startparameter: 163 PASS / 1 FAIL. Nach dessen
Entfernung bestand die Suite mit 164 PASS / 0 FAIL; die sechs betroffenen
statischen Suites einschließlich vollständigem Analyzer bestanden separat.
Die früheren lokalen Zwischenfehler bleiben ebenfalls eigene Belege.

Produkt, Parameterkorrektur und native Steuerung wurden unabhängig ohne offene
Findings reviewt. Lokale Rohbelege und Zugangsdaten bleiben außerhalb Git.
Die erforderlichen PR-Gates bleiben ein eigener Integrationsnachweis.

## Grenzen

Diese Abnahme betrifft die Recovery der Start-Epochen-Metadaten in den beiden
genannten Kontexten. Sie belegt keine Zertifikatserneuerung, allgemeine
Journalreparatur, fremde Ziele, Linux-/Hyper-V-Recovery oder alle weiteren
SQL-/Patch-/Clientprofile. Rollback qualifiziert nichts. Der Wire-Fingerprint
bleibt `NOT_OBSERVED`. Der [endliche TLS-001-Restumfang](../Project_Planning/TLS_001_COMPLETION_CHECKLIST.md)
und der vollständige Zertifikatslebenszyklus bleiben offen.
