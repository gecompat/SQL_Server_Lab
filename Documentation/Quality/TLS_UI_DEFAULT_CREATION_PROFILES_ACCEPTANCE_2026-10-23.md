# Default-Erstellung weiterer SQL-Profile – Abnahme vom 2026-10-23 (UTC)

Die spätere [Ressourcenprofilabnahme](TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
ergänzt Standard und Performance in beiden Erstellungsmodi. Dieser frühere
Nachweis bleibt an seinen beschriebenen Umfang und Quellstand gebunden.

## Umfang und Ergebnis

Diese Abnahme ergänzt die [frühere SQL-2025-Abnahme](TLS_UI_DEFAULT_CREATION_ACCEPTANCE_2026-10-23.md)
um die kompakte, nicht persistente Browser-Erstellung unter Windows mit
Docker und Podman für SQL 2019 CU32 und 2022 CU27. Autostart, Volltextsuche
und FileStream waren ausgeschaltet. Der einfache Standard
`Encrypt=True;TrustServerCertificate=True` verschlüsselt die Verbindung,
prüft aber das Serverzertifikat nicht. Die [Bedienungsanleitung](../HowTo/WORKFLOW_UI.md#container-lab-erstellen)
führt durch Vorbereitung, katalogisierte CU-Auswahl, Zielkontrolle und Entfernen.

| Provider | SQL-Profil / tatsächlicher Build | Ergebnis | Fälle | Darin Browserfälle | Default-Clientresultate |
|---|---|---|---:|---:|---:|
| Docker | 2019 CU32 / `15.0.4430.1` | PASS, eigenes Lab entfernt | 8 | 4 | 2 |
| Podman | 2019 CU32 / `15.0.4430.1` | PASS, eigenes Lab entfernt | 8 | 4 | 2 |
| Docker | 2022 CU27 / `16.0.4295.3` | PASS, eigenes Lab entfernt | 8 | 4 | 2 |
| Podman | 2022 CU27 / `16.0.4295.3` | PASS, eigenes Lab entfernt | 8 | 4 | 2 |

Insgesamt bestanden 32 Fälle, darin 16 Browserfälle, und acht echte
Default-Clientresultate. Die Stacks waren System.Data.SqlClient mit
`Encrypt=True;TrustServerCertificate=True` und ODBC/sqlcmd mit `-N -C`.
Beide bestätigten den erwarteten Build und serverseitige Verschlüsselung.
**Null strikte False-Clientresultate** werden aus dieser Abnahme abgeleitet;
der Wire-Fingerprint bleibt `NOT_OBSERVED`.

## Tatsächlich geprüfter Ablauf

Je positiver Zelle bestanden beide SQL-Clients, der sichtbare True/True-Standard
im echten Erstellungsdialog, genau ein tatsächlicher Erstellungsauftrag mit
erfolgreichem Abschluss, die genaue neue Lab-/Instanz-/Provider-/Host-/Portbindung
mit beiden gespeicherten True-Werten und das ausdrücklich abgeschlossene
Entfernen über die Produktoberfläche. Die letzten vier Schritte sind die
vier Browserfälle innerhalb der acht Fälle. Zusätzlich bestanden ganze
Windows-Jobleere, Same-Pin-Container-/Volumeabwesenheit sowie Cleanup und
Bestandsvergleich. Alle vier tatsächlich erstellten Labs sind entfernt.

Die Steuerung verwendete den echten Produktserver, Produktassets, Browser,
Operatorzugang und Requests. Eine vorgelagerte Requestgrenze erlaubte nur
die eine eigene Erstellung und das eine eigene Entfernen. Produktantworten
oder erfolgreiche DOM-Ergebnisse wurden nicht injiziert. Auftragsannahme
allein wurde nicht als Abschluss gewertet.

## Ursprünglicher Fehler und Produktkorrektur

Ein zusätzlicher erster Docker-/SQL-2019-Versuch scheiterte beim Laden vor
jedem Erstellungs- oder Remove-Request. Es wurden kein SQL-Lab und kein
Container erstellt; Clientresultate und bestandene Fälle waren null.
Der originale FAIL und seine geschützten Nachweise bleiben unverändert.
Die genaue ursprüngliche Browserassertion wurde nicht aufgezeichnet.
Die Quellprüfung und eine tatsächliche rote Projektionsprüfung belegten
separat die fehlenden katalogisierten SQL-2019-/SQL-2022-Auswahlwerte.

Die Workflowantwort ergänzt nun eine begrenzte katalogisierte
`ContainerPinnedBuilds`-Projektion für 2019, 2022 und 2025. Der echte Renderer
prüft skalare Typen und passende Major-/CU-Zuordnung, begrenzt die Eingabe,
entfernt Duplikate und erhält die gültige aktuelle Auswahl. Gleitende
Jahreseinträge und die bisherige SQL-2025-Projektion bleiben verfügbar;
ältere Workflowantworten behalten ihren SQL-2025-Fallback.
Vier Projektions- und 13 Rendererfälle bestanden nach der roten Reproduktion.
Ein unabhängiges Finding zur isolierten Selektierbarkeit der neuen Fixture
wurde durch deren Einordnung in den vorhandenen Workflow-UI-Prüfpfad geschlossen.

Das Budget zählt fünf konservative Labreservierungen, davon einen Fehler
vor der Erstellung und vier tatsächlich erstellte und entfernte Labs.
Der anfängliche FAIL wird weder überschrieben noch nachträglich aufgewertet.

## Quell- und Nachweisgrenzen

Alle vier positiven Zellen liefen auf demselben unveränderten korrigierten
Produktframe. Der ursprüngliche FAIL belegt seinen früheren Frame. Die
SQL-2025-Abnahme wurde nicht wiederholt und bleibt auf ihrem eigenen
Quellstand; aus der neuen Katalogprojektion entsteht kein neuer nativer
SQL-2025-Nachweis.

Vor den positiven Zellen bestanden 13 betroffene statische Suites mit
vollständigem Analyzer und anschließend sieben betroffene Suites für das
Selektordelta ebenfalls mit effektiv vollständigem Analyzer. Unveränderte
grüne Basisprüfungen wurden nicht erneut ausgeführt. Die Ausführung im
Developmentmodus ändert die konservative globale Analyzerauswahl bei
betroffenen Testdateien nicht. Produkt und private Zulassungs-/Browsersteuerung
wurden unabhängig ohne offene Findings geschlossen. Die abschließenden
Dokumentationsänderungen werden getrennt von diesen nativen Ergebnissen geführt.

Rohdaten, Originalfehler, Requests, Quellenbindungen, Prozess-/Cleanupbelege
und Bestandsnachweise bleiben geschützt außerhalb Git. Die ältere
SQL-2025-Dokumentation nennt nach einer reinen Faktkorrektur ebenfalls den
tatsächlich verwendeten Stack System.Data.SqlClient; ihre Resultate bleiben unverändert.

## Offene Grenzen und Fortsetzung

Diese Abnahme schließt keine authentifizierte Browser-Erstellung mit
`TrustServerCertificate=False`, andere Erstellungsprofile, Clipboard,
Linux-/Hyper-V-Erstellung, weitere Patch-/Clientkontexte, öffentliche
Registry-/Exportpfade, Renewal, Recovery, Rollback oder Retirement ab.
Die [bekannten Grenzen](KNOWN_LIMITATIONS.md) und der
[TLS-001-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
führen die Fortsetzung. TLS-001 bleibt `partial`.
