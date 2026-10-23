# Native Browserabnahme der TLS-Liveaktion vom 2026-10-23 (UTC)

## Ergebnis und Grenze

**TLS jetzt prüfen** bestand am ausgewählten SQL-Ziel in der echten
Windows-Produktoberfläche mit Docker und Podman separat. Der
[Vertrag](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md) trennt die
Beobachtung beider strikten Clients von gespeicherter Konfiguration und Export.
Der vollständige Produktserver, seine Assets, authentifizierter Operatorzugang
und ein echter Edge-Browser waren beteiligt; keine Erfolgsantwort oder
positive DOM-Anzeige wurde injiziert.

| Provider | SQL-Profil und tatsächlicher Build | Fälle | Strikte UI-Clientresultate | Arrange | Rebind | Ergebnis |
|---|---|---|---|---|---|---|
| Docker | 2025 CU9, `17.0.5005.3` | 8 | 4 | 2 | 2 | PASS |
| Podman | 2025 CU9, `17.0.5005.3` | 8 | 4 | 2 | 2 | PASS |

Beide positiven Zellen liefen auf demselben unveränderten Produktstand.
Insgesamt sind das 16 vollständige Fälle und acht strikte UI-Clientresultate.
Die vier Arrange- und vier Rebind-Resultate sind getrennt gezählt. Beide
Stacks sind `System.Data.SqlClient` und ODBC-`sqlcmd` mit `-N` ohne `-C`;
die bestehende öffentliche API verlangt verschlüsselte SQL-Abfragen auf dem
erwarteten Build. Nach Nativeabschluss änderte sich nur Nachweisdokumentation.

## Tatsächliche Fälle je Provider

| Fall | Nachgewiesenes Verhalten |
|---|---|
| Eigene Anlage | Neues eigenes False-Lab mit zwei strikten Clientresultaten |
| Erster UI-Klick | Genau ausgewähltes Ziel, echter POST/Job/GET, zwei frische strikte Resultate und sichtbare Beobachtungszeit |
| Echter Neustart | Öffentlicher Stop/Start desselben eigenen Labs; zweiter Klick endet abgewiesen, kein neues positives Ergebnis |
| Öffentlicher Rebind | Qualifizierte Metadatenwiederbindung mit zwei strikten Clientresultaten |
| Dritter UI-Klick | Zwei weitere strikte Resultate mit neuem Qualifikationszeitpunkt, sichtbare frische Beobachtung |
| Aktualisieren | Tatsächlicher Refreshklick verwirft die Beobachtung |
| Prozessende | Eigener Browser und Server terminal; gesamte gebundene Windows-Jobgruppe nachweislich leer |
| Eigener Cleanup | Öffentlicher Remove erst nach Prozessende, Container-/Volumeabwesenheit am ursprünglichen physischen Runtime-Pin, feste Exporte abwesend, Bestandsvergleich bestanden |

Je Zelle wurden genau drei UI-POSTs angenommen, zwei vollständige positive
Beobachtungen und eine Neustartablehnung empfangen. Keine gesperrten
Browseranfragen oder Seitenfehler traten auf. Es wurde kein Export erzeugt.
Bestehende CA-/Trust-/Originalkeybindungen und fremde Ressourcen blieben erhalten.

## Ursprünglicher Fehler und gezielte Korrektur

Der erste Dockerlauf bleibt **FAIL**. Die SQL-Prüfung lieferte bereits ein
frisches Ergebnis beider Clients; die automatische Workflowaktualisierung
montierte währenddessen die Ansicht neu und verwarf diese Antwort als verspätet.
Das war keine vollständige erfolgreiche UI-Abnahme. Seine zwei partiellen
UI- und zwei Arrange-Clientresultate werden nicht den positiven Zellen zugerechnet.

Der Fix verschiebt automatische Aktualisierungen während des laufenden Jobs
und verwirft auch bereits unterwegs befindliche automatische Antworten in
dieser Zeit. Manuelles Aktualisieren und andere Aktionen bleiben bedienbar
und invalidieren verspätete Ergebnisse. Nach Jobende läuft die automatische
Aktualisierung weiter. Die tatsächliche Refreshfunktion und Komponente
reproduzierten den Fehler rot; die korrigierte JS-Prüfung bestand mit 23/0.

Zusätzlich scheiterte die private Zusammenfassung bei genau einem Fall an
einer PowerShell-Arraykonvertierung. Der alte Fehler wurde an den tatsächlichen
AST-Anweisungen reproduziert; die korrigierte Zusammenfassung und die
Folgelauf-Budgetbedingungen bestanden zusammen 31 Offlinefälle ohne Provideraktion.
Der erste Lauf wurde nach bestätigter ganzer Jobleere tatsächlich entfernt;
sein zusätzlicher Bestandsvergleich bestand. Insgesamt entstanden drei neue
eigene Labs, alle drei sind entfernt. Originale FAIL-Belege bleiben lokal erhalten.

Die drei ursprünglichen Produktreviewfindings zu Auditstate-Resolver,
skalaren DTO-Typen und gemeinsamen Jobtabellen sind geschlossen; HTTPfokus
24/0. Statische betroffene Läufe bestanden mit 16, anschließend 15 und nach
dem Laufzeitfix elf ausgewählten Suites. Unveränderte grüne Prüfungen wurden
als solche wiederverwendet. Produkt- und Controllerreviews waren vor Native
ohne offene Findings; finale Dokumentations- und PR-Gates bleiben eigene Schritte.

## Weiter offen

Die nachfolgende [UI-Profilabnahme](TLS_UI_PROFILE_MATRIX_ACCEPTANCE_2026-10-23.md)
belegt SQL 2019 CU32 und 2022 CU27 mit eigenen getrennten Quellständen;
sie erweitert diesen ursprünglichen SQL-2025-Nachweis nicht rückwirkend.

Diese Abnahme verwendet den passenden serverseitigen Run-StateRoot für
das eigene registrierte Ziel. Sie belegt keine globale Suche über alle
Auditroots. Andere UI-SQL-Profile belegt der oben verlinkte Nachfolger
gesondert. Creationdialog und Clipboardpfade,
öffentliche Linux- und Hyper-V-Lanes, operatives Renewal/Recovery und weitere
Trust-/Consumerkontexte bleiben getrennte Scopes. Die frühere
[sechszellige API-Abnahme](TLS_LIVE_QUALIFICATION_API_ACCEPTANCE_2026-10-23.md)
wurde nicht wiederholt. `WireCertificateFingerprint=NOT_OBSERVED` bleibt wahr.
TLS-001 ist weiterhin `partial`; Rohdaten, Secrets und konkrete Zielbindungen
bleiben lokal außerhalb Git.
