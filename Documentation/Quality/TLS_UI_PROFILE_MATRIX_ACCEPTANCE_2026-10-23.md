# Browserabnahme weiterer TLS-SQL-Profile vom 2026-10-23 (UTC)

## Ergebnis und Quellgrenzen

Die Aktion **TLS jetzt prüfen** bestand unter Windows mit dem echten
Produktserver und Edge zusätzlich für die vier unten genannten Zellen.
Der [Livevertrag](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md)
und die [Bedienanleitung](../HowTo/WORKFLOW_UI.md#tls-jetzt-prüfen) bleiben
maßgeblich. Positive HTTP-Antworten oder Produktanzeigen wurden nicht injiziert.

| Provider | SQL-Profil | Tatsächlicher Build | Fälle | Strikte UI-Resultate | Arrange | Rebind | Stand |
|---|---|---|---|---|---|---|---|
| Docker | 2019 CU32 | `15.0.4430.1` | 8 | 4 | 2 | 2 | A: PASS |
| Podman | 2019 CU32 | `15.0.4430.1` | 8 | 4 | 2 | 2 | A: PASS |
| Docker | 2022 CU27 | `16.0.4295.3` | 8 | 4 | 2 | 2 | A: PASS |
| Podman | 2022 CU27 | `16.0.4295.3` | 8 | 4 | 2 | 2 | B: PASS |

Stand A ist der unveränderte Produktstand nach PR #829, Basis
`9adb2e1aab82bdb0c21d1434665a6acf849e0ba0`. Stand B ergänzt die unten
beschriebene Generationskorrektur und deren zwei fokussierte Fälle.
Die Produktquellen blieben während jeder Zelle unverändert. Die drei grünen
A-Zellen wurden nicht auf B wiederholt; dies ist keine frisch gemeinsam
ausgeführte Matrix am finalen Integrationshead. Die frühere
[SQL-2025-CU9-Browserabnahme](TLS_UI_LIVE_QUALIFICATION_ACCEPTANCE_2026-10-23.md)
bleibt ein eigener Nachweis.

Die vier positiven Zellen ergeben 32 Fälle und 16 strikte UI-Clientresultate.
Acht Arrange- und acht Rebind-Resultate sind getrennt gezählt. Beide Stacks
sind `System.Data.SqlClient` und ODBC-`sqlcmd` mit `-N` ohne `-C`.
Das unabhängige Profiloracle prüft Build, Version, CU und den `0.3`-Record
mit dem tatsächlichen `SqlProfileId` für 2019 CU32 beziehungsweise 2022 CU27.

## Tatsächlicher Ablauf je positiver Zelle

1. Ein neues eigenes False-Lab qualifiziert beide strikten Clients.
2. Der erste echte UI-Klick liefert zwei frische Resultate für genau dieses Ziel.
3. Nach öffentlichem Stop/Start weist der zweite Klick das veraltete Ziel ab.
4. Der öffentliche Rebind qualifiziert beide Clients und aktualisiert die Startbindung.
5. Der dritte UI-Klick zeigt eine neue frische Beobachtung beider Clients.
6. Der tatsächliche Refreshklick verwirft diese Beobachtung.
7. Browser und Server enden; die gesamte gebundene Windows-Jobgruppe ist leer.
8. Erst danach entfernt der öffentliche Cleanup das eigene Lab. Container und
   Volume sind am ursprünglichen physischen Runtime-Pin abwesend; feste
   Exporte sind abwesend und der Bestandsvergleich besteht.

Je Zelle wurden genau drei UI-POSTs angenommen, zwei positive Beobachtungen
und eine Neustartablehnung empfangen. Keine gesperrten Browseranfragen oder
Seitenfehler traten auf. Es wurden keine Exporte erzeugt. Bestehende CA-,
Trust- und Originalkeybindungen sowie fremde Ressourcen blieben erhalten.

## Erhaltener FAIL und gezielte Korrektur

Der erste Podman-/SQL-2022-Lauf bleibt **FAIL**. Er empfing nach Neustart
eine serverseitige Ablehnung, konnte deren DOM-Fehlanzeige aber nicht mit
der bisherigen 100-ms-Abfrage bestätigen. Seine zwei partiellen UI- und zwei
Arrange-Resultate gehören nicht zu den positiven Summen; Rebind fand nicht statt.
Nach bestätigter Jobleere wurde auch dieses Lab tatsächlich entfernt;
Cleanup und Bestandsvergleich bestanden. Insgesamt entstanden fünf eigene
Labs, alle fünf sind entfernt. Originalbelege bleiben lokal erhalten.

Die Untersuchung reproduzierte eine zusätzliche Racebedingung mit der echten
Refreshfunktion und Komponente: Eine vor dem TLS-Klick gestartete
Hintergrundantwort kann erst nach dem terminalen Ausgang eintreffen und
dann die neue Erfolgs- oder Ablehnungsanzeige verwerfen. Der Fix erfasst vor
dem Request die Komponentengeneration und verwirft dessen Hintergrundantwort
nach beiden Awaits auch bei inzwischen beendeter Prüfung, wenn die Generation
gewechselt hat. Später neu gestartete automatische Refreshes und manuelle
Aktionen invalidieren weiterhin. Die rote Reproduktion und zwei ergänzte
Interleavings sind erhalten; die korrigierte JS-Prüfung bestand mit 25/0.

Der ursprüngliche Nativebeleg unterscheidet diese Racebedingung nicht eindeutig
von einem legitimen späteren Refresh, der eine kurze Fehlanzeige vor der
nächsten Abfrage ersetzt. Der neue private Driver liest deshalb zusätzlich
passiv tatsächliche DOM-Übergänge: ausschließlich sichtbare, verbundene
Statusknoten des eigenen Ziels im Abschnitt des echten zweiten
vertrauenswürdigen Klicks. Verborgene, fremde, abgelöste oder vor dem Klick
vorhandene Anzeigen gelten nicht. HTTP-Ablehnung und SQL-Oracles bleiben
zusätzlich erforderlich. Diese Beobachtung verändert weder DOM noch Antworten.
Der neue Podman-/SQL-2022-Lauf bestand mit diesem Nachweis vollständig auf B.

Produkt- und Kontrollreviews schlossen ohne offene Findings. Zwei Findings
der vorbereiteten Beobachtungssteuerung wurden vor deren Nativeausführung
behoben. Die betroffenen elf statischen Suites bestanden. Nur die eigene
anschließende Aggregation scheiterte an optional nicht erzeugten Cachedateien;
der tatsächliche Runnerabschluss wurde ohne Testwiederholung ausgewertet.
24 fokussierte Beobachtungs- und 37 Zulassungsfälle bestanden ohne Provideraktion;
das sind keine zusätzlichen nativen SQL-Nachweise. Finale Dokumentations-
und PR-Gates sind getrennte Integrationsbedingungen.

## Weiter offen

Diese Abnahme verwendet weiterhin den passenden serverseitigen Run-StateRoot;
eine globale Suche über alle Auditroots ist nicht belegt. Creationdialog,
Clipboard, weitere Patch-/Clientkontexte, öffentliche Linux-Registry-/Export-/
Consumerpfade, öffentliche Hyper-V-False-/Exportlane, operatives Renewal,
Recovery/Rollback und weitere Trust-/Consumerkontexte bleiben getrennt.
`WireCertificateFingerprint=NOT_OBSERVED` bleibt wahr; TLS-001 ist `partial`.
Rohdaten, Secrets und konkrete lokale
Zielbindungen bleiben außerhalb Git.
