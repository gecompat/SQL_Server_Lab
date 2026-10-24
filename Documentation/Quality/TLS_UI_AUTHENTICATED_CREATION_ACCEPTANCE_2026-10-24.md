# Authentifizierte Browser-Erstellung – Abnahme vom 2026-10-24 (UTC)

## Umfang und Ergebnis

Geprüft wurde die ausdrückliche Erstellung eines kompakten, nicht persistenten
Windows-/SQL-2025-CU9-Labs mit `Encrypt=True;TrustServerCertificate=False`
im echten Browser. Docker und Podman liefen getrennt. Instanz `primary`,
ausgeschalteter Autostart und keine zusätzlichen SQL-Features waren fest.
Die [Workflow-Anleitung](../HowTo/WORKFLOW_UI.md#authentifiziertes-container-lab-erstellen)
erklärt Bedienung und Voraussetzungen; der
[Fachvertrag](../Architecture/AUTHENTICATED_TLS_UI_CREATION.md) beschreibt
Allokation, Sitzungsbindung und Fehlergrenzen.

| Provider | Tatsächlicher Build | Ergebnis | Fälle | Darin Browserfälle | Strikte UI-Clientresultate | Zusätzliche Arrange-Resultate |
|---|---|---|---:|---:|---:|---:|
| Docker | `17.0.5005.3` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |
| Podman | `17.0.5005.3` | PASS, eigenes Lab entfernt | 8 | 6 | 4 | 2 |

Die positiven Zellen ergeben 16 Fälle, darin zwölf Browserfälle, acht strikte
UI-Clientresultate und vier zusätzliche Arrange-Resultate. Zwei erfolgreiche
sichtbare UI-Liveprüfungen je Zelle verwendeten jeweils System.Data.SqlClient
und ODBC/sqlcmd. Die zusätzliche öffentliche API-Prüfung diente der
unabhängigen Zielbindung. Interne Creator-/Rebind-Qualifikationen werden
nicht zusätzlich als separat erfasste Clientresultate gezählt. Wire bleibt
`NOT_OBSERVED`.

## Tatsächlich geprüfter Ablauf

Der echte Produktserver lieferte unveränderte Assets und Antworten an einen
frischen Browserkontext. Vor dem ersten Request ließ eine feste Requestgrenze
nur den eigenen Erstellungsauftrag und die sieben vorgesehenen Zielaktionen
zu; sie ersetzte keine Antworten. Operatorzugang, bestehende CA-/Client-/
Trustbindung, ursprüngliche Runtimeidentität und vollständige Quelle waren
frisch gebunden. Je positiver Zelle bestanden:

1. Die intern erzeugte Audit-/StateRoot-Allokation war vor der Policy-/Runanlage
   einem privaten Sitzungsticket zugeordnet. Policy, OwnBinding, Run und
   ursprünglicher Runtimepin passten zum genau einen neuen Lab.
2. Eine zusätzliche öffentliche strikte API-Prüfung bestätigte das genaue
   Ziel und beide Clientstacks.
3. Die False-Erstellung im echten Dialog erreichte `COMPLETE` und zeigte
   ausschließlich die serverseitig gebundene Zielreferenz.
4. Die erste sichtbare UI-Liveprüfung bestätigte beide strikten Clients.
5. Stop/Start invalidierte die Beobachtung. Die nächste UI-Prüfung blieb
   unbestätigt; der separat beobachtete kanonische Fehler
   `TLS_LAB_RESTART_REQUIRES_REBIND` trat vor weiteren Clients auf.
6. Ausdrückliche Wiederbindung und erneute UI-Liveprüfung lieferten ein
   frisches sichtbares Ergebnis beider Clients.
7. Die echte lesende Aktualisierung verwarf die frühere Beobachtung.
8. Genau ein UI-Remove erreichte `REMOVED` und `Aktion: COMPLETE`;
   der Remove-Knopf blieb danach dauerhaft deaktiviert.

Die letzten sechs Punkte sind die sechs Browserfälle. Jeder positive Lauf
enthält einen Create- und sieben Zielaktionsrequests, darunter drei Liveaufrufe
mit zwei Erfolgen und einer Neustartablehnung. Browser und Seite wurden
geschlossen; der ganze Windows-Job war tatsächlich leer. Der übergeordnete
Cleanup bestätigte den bereits durch die UI entfernten Run, Same-Pin-
Container-/Volumeabwesenheit und vollständigen Bestandsvergleich. CA, Trust,
ursprüngliche Schlüssel, fremde Worktrees, Stashes und geschützte Archive
blieben erhalten.

## Ursprüngliche Fehlversuche

Zwei frühere Dockerläufe bleiben unverändert FAIL; beide Labs sind entfernt.
Ganze Windows-Jobleere, Cleanup und Bestandsvergleich bestanden separat.

- Der erste Lauf erstellte das Lab erfolgreich. Die private Prüfsteuerung
  las danach den Namen am falschen Metadatenpfad `metadata.desiredState.name`
  statt `metadata.name`. Es gibt keinen abgeschlossenen Browser-Terminalbeleg
  und keine zusätzlich gezählten UI-/Arrange-Clientresultate dieser Steuerung.
- Der zweite Lauf erreichte fünf abgeschlossene Browserfälle, vier partielle
  strikte UI- und zwei Arrange-Resultate sowie den tatsächlichen UI-Remove.
  Sein privates Abschlussoracle wartete jedoch auf einen wieder aktivierten
  Remove-Knopf und endete mit Timeout. Das Produkt deaktiviert ihn nach
  `REMOVED` korrekt dauerhaft. Erfolgreicher Cleanup macht diesen FAIL nicht
  nachträglich zum PASS.

Nur die reproduzierbaren Fehler der privaten Prüfsteuerung wurden korrigiert
und unabhängig geprüft. Der ursprüngliche Helfer reproduzierte den
Remove-Fehler an synthetischem DOM; der korrigierte Helfer bestand mit seinen
Negativfällen sechs JS-Fälle. Vier weitere fokussierte Fälle prüften feste
Zulassung und unveränderte Fehlerhistorie. Diese zehn Fälle starteten keinen
Browser, HTTP-Request, Provider oder neue Labreservierung. Insgesamt wurden
vier neue Labs erstellt; alle vier sind entfernt.

## Quellen und statische Nachweise

Die vollständige native Produktquelle blieb bei allen vier Versuchen
unverändert: Frame
`9C5724143AE058786FA194348628C53FA7F29B929E2B86075E98C4D41BC743EC`,
vollständige Baseline
`A9E8F12C18855FAC7EA0D2DC36F3154B0210392720473013AC2A9B6410AEDA70`.
Das nachfolgende Dokumentationsdelta ist ein eigener Quellstand.

Die unabhängige Produktreview schloss drei Findings: weitere Erstellungen
bei unbestätigtem Ticket, als Erfolg behandelte strukturierte Lifecyclefehler
und nicht ausreichend geschlossene ClientCheck-Typen. Der korrigierte Fokus
bestand mit 43 PowerShell- und 16 JS-Fällen. 18 von 19 ausgewählten statischen
Suites bestanden zunächst. Nur der volle Analyzer scheiterte an einer neuen
Plaintextconversion neben unveränderten Baselinebefunden. Nach direkter
SecureString-Befüllung und den betroffenen Fokusprüfungen bestand der erneut
ausgeführte vollständige Analyzer. Unveränderte grüne Suites wurden nicht
wiederholt; daraus wird kein neuer gemeinsamer 19-Suite-Lauf abgeleitet.

Originale FAIL-Belege, feste Zulassungsmarker, Source-/Reviewbindungen,
kanonische eigene Runzustände und vollständige Cleanup-/Bestandsnachweise
bleiben lokal geschützt außerhalb Git. Hashes bezeichnen Nachweisstände
und erteilen keine Ausführungsautorität.

## Verbleibende Grenzen

Nicht abgenommen sind weitere Ressourcen-/SQL-Erstellungsprofile, Clipboard,
globale Auditroot-Discovery, Wiederaufnahme nach neuem UI-Start, Recovery-Apply,
Linux-/Hyper-V-Erstellung oder weitere Trustkontexte. Frühere API-, Default-,
Linux- und Hyper-V-Nachweise bleiben auf ihren jeweiligen Quellständen.
Die [TLS-001-Restschritte](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
bleiben `partial`; ein Wire-Zertifikatsfingerprint wurde nicht beobachtet.
