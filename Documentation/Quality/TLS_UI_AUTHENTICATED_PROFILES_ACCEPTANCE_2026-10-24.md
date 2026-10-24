# Authentifizierte SQL-2019-/SQL-2022-Erstellung – Abnahme vom 2026-10-24

## Umfang und Ergebnis

Die zusätzliche Browser-Erstellung wurde unter Windows getrennt mit Docker
und Podman für SQL 2019 CU32 und SQL 2022 CU27 geprüft. Alle vier Zellen
verwendeten `compact`, Instanz `primary`, ausgeschalteten Autostart, keine
persistenten Stores und keine zusätzlichen SQL-Features. Bestehende CA,
Clientbindung und CurrentUser-Trust waren Voraussetzung.
Die [Anleitung](../HowTo/WORKFLOW_UI.md#authentifiziertes-container-lab-erstellen)
führt durch den Dialog; der [Fachvertrag](../Architecture/AUTHENTICATED_TLS_UI_CREATION.md)
beschreibt Allokation, Profilbindung und Fehlergrenzen.

| Provider | SQL-Profil | Tatsächlicher Build | Ergebnis | Fälle | Darin Browserfälle | Strikte UI-Clientresultate | Zusätzliche Arrange-Resultate |
|---|---|---|---|---:|---:|---:|---:|
| Docker | 2019 CU32 | `15.0.4430.1` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |
| Podman | 2019 CU32 | `15.0.4430.1` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |
| Docker | 2022 CU27 | `16.0.4295.3` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |
| Podman | 2022 CU27 | `16.0.4295.3` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |

Insgesamt bestanden 32 Fälle, darin 24 Browserfälle, 16 strikte UI- und acht
zusätzliche Arrange-Clientresultate. Zwei sichtbare positive Liveprüfungen je
Zelle verwendeten jeweils System.Data.SqlClient und ODBC/sqlcmd. Die zusätzliche
öffentliche API-Prüfung band unabhängig das genaue Ziel und den tatsächlichen
Build. Interne Creator-/Rebind-Probes werden nicht zusätzlich gezählt.
Alle vier reservierten Labs wurden tatsächlich erstellt und entfernt;
es gab keine nativen Wiederholungsversuche dieser Welle.

## Tatsächlich geprüfter Ablauf

Der unveränderte Produktserver lieferte seine Assets und Antworten an einen
frischen Browserkontext. Die feste Requestgrenze ließ genau einen Create-
und sieben Zielaktionsrequests zu; sie ersetzte keine Serverantworten.
Je Zelle bestanden:

1. Private Allokationsbindung vor der Policy-/Runanlage sowie unabhängige
   Prüfung von kanonischem Record, Profil, OwnBinding und ursprünglichem Pin.
2. Zusätzliche strikte API-Prüfung beider Clients am tatsächlichen SQL-Build.
3. Echte False-Erstellung mit ausdrücklich gewähltem SQL-Profil im Dialog,
   `COMPLETE`, sichtbarem Profil und gebundener Zielreferenz.
4. Erste sichtbare positive UI-Liveprüfung beider Clients.
5. Stop/Start und Ablehnung einer erneuten Livequalifikation; unabhängig
   beobachtetes `TLS_LAB_RESTART_REQUIRES_REBIND` vor weiteren Clients.
6. Ausdrückliche Wiederbindung und frische positive UI-Liveprüfung.
7. Lesende Aktualisierung mit Verfall der früheren Liveanzeige.
8. Tatsächlicher UI-Remove bis `REMOVED` und `Aktion: COMPLETE` mit danach
   dauerhaft deaktiviertem Remove-Knopf.

Die letzten sechs Punkte sind die sechs Browserfälle. Browser und Seite sind
geschlossen; alle vier Windows-Jobs waren tatsächlich leer. Der übergeordnete
Cleanup bestätigte jeweils den bereits durch die UI entfernten Run,
Same-Pin-Container-/Volumeabwesenheit und den vollständigen Bestandsvergleich.
CA, Trust, ursprüngliche Schlüssel, fremde Worktrees, Stashes und bestehende
geschützte Archive blieben erhalten.

## Quellen, lokale Prüfungen und Aussagegrenzen

Alle vier nativen Zellen liefen auf demselben unveränderten Produktstand:
Frame `0502117B29F9B2DE41E3B6E77FFD3FF16DC4AB3BB6D57112AE5ADC6199059691`,
vollständige Baseline
`227F59E7C31BB53C608F1C5F7B2642D3D8F0D3DEF3A23275C548561C49004DC7`.
1613 Quelldateien einschließlich Git-Zuordnung sowie 28 An-/Abwesenheiten der
nativen AGENTS-Kette waren gebunden. Nach Native wurden nur Markdowndateien
für diesen Nachweis und seine Lesewege geändert.

Die fehlende Auswahl war zuvor durch den abgewiesenen 2019-Request und den
fehlenden Profiltext im Renderer reproduziert. Der Produktfokus bestand danach
61 PowerShell- und 28 JS-Fälle. Ein ausgewählter Zehnsuitenlauf wurde vor den
letzten drei Suites unterbrochen; Ursache unbekannt, der gesamte alte
Prozessbaum war danach nachweislich abwesend. Sieben originale PASS-Abschlüsse
einschließlich des vollständigen Analyzers bleiben erhalten. Ein unabhängig
gefundener veralteter Dialoghinweis wurde durch genau eine HTML-Textersetzung
korrigiert. Danach bestanden ausschließlich die drei fehlenden Suites und
Docs/Privacy für das Textdelta. Diese Belege sind kein neuer gemeinsamer
Zehnsuitenlauf. Die geprüften Analyzerinputs blieben unverändert.

Der unabhängige Produktreview und die getrennte Quellenreview der festen
Abnahmesteuerung hatten keine offenen Findings. Deren geänderte Grenzen
bestanden 30 synthetische Zulassungs- und 22 Requestboundary-Fälle ohne
Provideraktion oder kanonische Mutation. Ein ursprünglicher Splatfehler der
privaten Fokusfixture und ein früherer lokaler Testlauncherfehler bleiben
separat erhalten. Beide verursachten weder Provideraktionen noch
Labreservierungen und sind keine nativen Lab-Fehlversuche.

Die frühere [SQL-2025-CU9-Abnahme](TLS_UI_AUTHENTICATED_CREATION_ACCEPTANCE_2026-10-24.md)
einschließlich ihrer ursprünglichen FAILs bleibt eigenständig; sie wurde
nicht wiederholt. Der einfache True/True-Standard bleibt erhalten.
Weitere Ressourcenprofile, andere Patch-/Client-/Plattformkombinationen,
Clipboard, öffentliche Linux-/Hyper-V-Pfade, Consumer und der operative
Renewal-/Recovery-/Trustlebenszyklus bleiben eigene TLS-001-Scopes.
Wire bleibt `NOT_OBSERVED`; die gesamte TLS-001-Matrix bleibt `partial`.
Die erforderlichen PR-Gates bleiben Integrationsbedingung.
