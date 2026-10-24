# Default-Container-Erstellung im Browser – Abnahme vom 2026-10-23 (UTC)

Die spätere [Ressourcenprofilabnahme](TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
ergänzt Standard und Performance in beiden Erstellungsmodi. Dieser frühere
Nachweis bleibt an seinen beschriebenen Umfang und Quellstand gebunden.

## Umfang und Ergebnis

Die reale lokale Produktoberfläche erstellte und entfernte jeweils ein eigenes
Lab unter Windows mit Docker und Podman. Beide positiven Zellen bestanden
getrennt auf SQL 2025 CU9, Build `17.0.5005.3`, mit kompaktem Profil, ohne
Persistenz, Autostart, Volltextsuche oder FileStream. Der unveränderte
Verbindungsstandard ist `Encrypt=True;TrustServerCertificate=True`.
Dieser Modus verschlüsselt die Verbindung ohne Prüfung des Serverzertifikats.
Die [Bedienungsanleitung](../HowTo/WORKFLOW_UI.md#container-lab-erstellen)
erklärt Erstellung, Zielkontrolle und Entfernen.

| Provider | Ergebnis | Fälle | Davon Browserfälle | Echte Default-Clientresultate |
|---|---|---:|---:|---:|
| Docker | PASS, eigenes Lab entfernt | 8 | 4 | 2 |
| Podman | PASS, eigenes Lab entfernt | 8 | 4 | 2 |

Die beiden echten Stacks waren System.Data.SqlClient mit
`Encrypt=True;TrustServerCertificate=True` sowie ODBC/sqlcmd mit `-N -C`.
Beide bestätigten den erwarteten SQL-Build und serverseitige Verschlüsselung.
Das ergibt vier positive Default-Clientresultate und **null strikte
False-Clientresultate**. Wire-Fingerprint bleibt `NOT_OBSERVED`.

## Tatsächlich ausgeführte Fälle

Je positiver Zelle bestanden:

1. Beide realen Default-Clientstacks am neu erstellten SQL-Ziel.
2. Sichtbarer True/True-Standard im echten Erstellungsdialog.
3. Genau ein tatsächlicher Erstellungsauftrag mit erfolgreichem Abschluss.
4. Das genaue neue Lab mit passender Instanz, Provider, Host, Port und beiden
   gespeicherten True-Werten in der Verbindungsansicht.
5. Ausdrückliches Entfernen über die Produktoberfläche mit tatsächlich
   abgeschlossenem persistentem Auftrag und genau einer abgeschlossenen Operation.
6. Terminales Ende von eigenem Browser und Produktserver.
7. Tatsächlich leeres gesamtes eigenes Windows-Jobobjekt und vollständiger
   eigener Cleanup mit bestätigter Container-/Volumeabwesenheit.
8. Bestandsvergleich mit unveränderten fremden Ressourcen, vorhandenem Trust
   und ursprünglichen Schlüsseln.

Die Fälle 2–5 sind die vier Browserfälle; sie werden nicht zusätzlich zu den
acht Fällen gezählt. Die Browsersteuerung verwendete echte Produktassets,
Operatorzugang und Requests. Eine vorgelagerte Requestgrenze erlaubte nur die
eine eigene Erstellung und das eine eigene Entfernen. Native DOM-Antworten
oder erfolgreiche Resultate wurden nicht injiziert.

## Ursprüngliche Fehlversuche und Korrekturgrenze

Vor den positiven Zellen gab es zwei Docker-Fehlversuche. Beide bleiben FAIL;
alle insgesamt vier neuen Labs sind entfernt. Ihre Originalbelege werden
unverändert lokal geschützt aufbewahrt.

- Der erste Versuch endete bei der Zielkontrolle nach zwei partiellen
  Browserfällen und zwei bestandenen Default-Clientresultaten. Die genaue
  fehlgeschlagene Assertion wurde nicht aufgezeichnet. Eine falsche
  Kartenbindung und das fehlende Warten auf vollständig geladene eigene
  Metadaten wurden separat am tatsächlichen Renderer passiv reproduziert.
- Der zweite Versuch endete beim Entfernen nach drei partiellen Browserfällen
  und zwei bestandenen Default-Clientresultaten. Die private Steuerung erwartete
  fälschlich das ID-Format eines flüchtigen Auftrags statt des tatsächlichen
  persistenten Removeauftrags. Auch hier ist die genaue ursprüngliche
  Native-Assertion nicht aufgezeichnet. Die korrigierte Steuerung prüfte
  anschließend die echte Annahme und den terminalen persistenten Abschluss.

Beim zweiten Fehlversuch blieb ein eigener, noch nicht ausgeführter
Removeauftrag zurück, während das Lab bereits durch den übergeordneten
Cleanup entfernt war. Dieser Auftrag wurde anschließend über die kanonische
Batch-Abbruchfunktion separat beendet: Operation `Cancelled`, Batch
`CompletedWithErrors`. Dabei änderten sich nur die drei vorgesehenen eigenen
Batch-/Operations-/Ereignismetadaten, ohne Provideraktion. Die ursprüngliche
Native-Nachweiskopie bleibt erhalten; der spätere Metadatenabschluss ist
gesondert belegt und wertet den FAIL nicht nachträglich auf.

Die ausführbare Produktquelle war während aller vier Labs identisch.
Zwischen den Versuchen wurden ausschließlich private Steuerungsfehler behoben.
Der Native-Quellstand enthält sechs geänderte Produkt-/Test-/Dokumentationsdateien;
die anschließende Dokumentation des Ergebnisses ist ein eigener Deltastand,
keine erneute Native-Ausführung am späteren Integrationshead.

## Statische und unabhängige Prüfung

Der ursprüngliche echte Frontendrequest wurde an der geschlossenen
Passwort-JSON-Grenze abgewiesen, weil `FullText` und `FileStream` noch nicht
zugelassen waren. Die Korrektur akzeptiert ausschließlich echte JSON-Booleans;
String-, Zahlen-, Array- und null-Werte bleiben abgewiesen. Die vorhandenen
Authentifizierungs-, Provider- und StateRootgrenzen wurden dadurch nicht erweitert.

92 fokussierte Passwortprüfungen, neun HTTP-Fixtureprüfungen und alle elf
betroffenen statischen Suites einschließlich vollständigem Analyzer bestanden.
Produktänderung und native Steuerung wurden unabhängig geprüft, Findings vor
der jeweiligen Ausführung geschlossen. Separate Reproduktionen der privaten
Steuerung sind keine zusätzlichen SQL- oder Providerabnahmen.

## Offene TLS-001-Grenzen

Die spätere [Default-Profilabnahme](TLS_UI_DEFAULT_CREATION_PROFILES_ACCEPTANCE_2026-10-23.md)
ergänzt SQL 2019 CU32 und 2022 CU27 auf einem getrennten Quellstand.
Sie verändert die hier beschriebenen ursprünglichen Resultate nicht.

Diese Abnahme umfasst keine authentifizierte Browser-Erstellung mit
`TrustServerCertificate=False`, keine weiteren Erstellungsprofile, Clipboard,
Linux-/Hyper-V-Erstellung oder neue Patch-/Clientkombinationen. Sie belegt weder
CA-/Truständerungen noch Renewal, Requalifikation, Recovery, Rollback oder
Retirement. Die [bekannten Grenzen](KNOWN_LIMITATIONS.md) und der
[TLS-001-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
bleiben maßgeblich; TLS-001 ist insgesamt `partial`.
