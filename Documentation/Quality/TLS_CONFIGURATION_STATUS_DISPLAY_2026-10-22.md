# Konfigurationsbasierter TLS-Prüfstatus vom 2026-10-22

## Abgenommener Teilscope

`TLS001-QUALIFICATION-DISPLAY-01` ergänzt je SQL-Ziel eine getrennte Anzeige
der gespeicherten Konfiguration und der fehlenden aktuellen Auswertung.
Der [Anzeigevertrag](../Architecture/SQL_CONNECTION_SETTINGS.md#getrennter-status-ohne-aktuelle-liveprüfung)
definiert die fünf geschlossenen Statuswerte. Keiner davon ist `QUALIFIED`.
Der bestehende dreifeldrige Reader für TLS-Booleans bleibt unverändert.

CLI, echte SQL-Zielkarte und Verbindungsübersicht zeigen den Status unmittelbar
am jeweiligen Ziel. Fehlende oder unbekannte Metadaten erhalten eine feste
Meldung. Runtime-READY, gespeichertes False und frühere Exporte werten den
Status nicht auf. Die Projektion liest keine Qualifikationsdatei, Secrets,
Zertifikate oder Truststores und öffnet keine SQL-Verbindung.

## Tatsächlich ausgeführte Nachweise

Der native Produktstand war Commit
`6dba08ceda03530124480fa343bb8b92788fd3a1`, Tree
`056b71af7d82810f75fd19df9ae45522d2da9d36`. Die abschließende
Nachweisdokumentation ist davon getrennt. Während beider Läufe blieben
Produktquellen, Gatebelege und die 15 gebundenen Eingabedateien unverändert.

| Provider | SQL-Profil / tatsächlicher Build | Native Fälle | Bezeichnete strikte Clientresultate | Abgeschlossener eigener Workflow-Snapshot | Eigener Cleanup |
|---|---|---:|---:|---:|---|
| Docker | SQL 2025 CU9 / `17.0.5005.3` | 5 PASS | 6 PASS | 1 | PASS, Run REMOVED |
| Podman | SQL 2025 CU9 / `17.0.5005.3` | 5 PASS | 6 PASS | 1 | PASS, Run REMOVED |

Jeder Provider verwendete einen eigenen neuen öffentlichen False-Run und
den unveränderten öffentlichen TLS-Abnahmeharness. Erstellung, Export und
exportierte Credentials wurden mit System.Data.SqlClient und dem tatsächlichen
ODBC-sqlcmd geprüft. Die übrigen Harnessfälle prüfen CLI-/Workflowflags und
die Ablehnung eigener veralteter beziehungsweise manipulierter Daten.
Die Zahlen bezeichnen diese sechs Clientresultate, keine Gesamtzahl von
Netzwerk-Handshakes. Die beobachtete Recordform war `0.2` ohne `SqlProfileId`.

Danach lief der vollständige Produktserver mit echten Assets, HTTP und
Hintergrundinventur an genau diesem eigenen StateRoot. Ein eigener
Headless-Browser prüfte `NOT_EVALUATED` im frischen abgeschlossenen
Workflow-Snapshot, die sichtbare Statuszeile an der Zielinstanz und unter
**Verbindungen und CMS**, den Endpoint, beide expliziten TLS-Werte und den
exakt angezeigten Connection String. Die Übersicht enthielt keine Credentials.
Es gab weder abgewiesene Browserrequests noch JavaScript-Seitenfehler.
Antworten und DOM wurden nicht durch synthetische Erfolgsantworten ersetzt.

Browserkontext und Browser wurden geschlossen; der UI-Server endete geordnet
mit seinen Hintergrundjobs und Operatorressourcen. Erst danach entfernte der
öffentliche Cleanup den eigenen Run. Container und Volumes waren über die
ursprüngliche Runtimebindung abwesend, der feste eigene Export entfernt.
Vorbestehende erfasste Dateien einschließlich CA-Ablage blieben bytegleich.
Vorhandene CA/Trust, ursprüngliche Schlüssel, Hyper-V-Ressourcen und fremde
Worktrees wurden nicht verändert. Rohdaten und Credentials bleiben lokal
und außerhalb Git.

## Lokale Regression und unabhängiger Review

- Die tatsächliche Rendererfixture reproduzierte die fehlenden vier
  Statuszeilen: sechs frühere Checks bestanden, der neue Fall scheiterte.
- Der Parser-/CLI-Fokus bestand mit 55/0. Er führt den echten CLI-Renderer
  mit festen synthetischen Run-/Verbindungsantworten aus; dies ist kein
  nativer Nachweis der neuen CLI-Statuszeile. Die erste UI-Erweiterung
  bestand mit 160/0.
- Die betroffene Auswahl mit 22 statischen Suites bestand einschließlich
  vollständigem Analyzer.
- Der unabhängige Review fand die fehlende Hyper-V-Fallbackzeile bei leerem
  Connection String. Ein tatsächlicher Rendererfall reproduzierte dies nach
  acht früheren erfolgreichen Checks. Der Fix erreichte 161/0 und schützt
  zusätzlich fehlende Metadaten sowie den Ausschluss reiner Windows-Karten.
- Das betroffene Korrekturdelta mit zehn statischen Suites bestand. Produkt,
  Oracle, Autoritätsbindung und konkreter Nativeadapter wurden unabhängig
  ohne offene Findings geschlossen. Die erforderlichen PR-Gates bleiben
  davon getrennte Integrationsbedingung.

## Verbleibende Grenzen

Die echten Browserläufe belegen ausschließlich die beschriebene Anzeige an
Windows-/Docker-/Podman-SQL-2025-CU9-Zielen. Andere Statuswerte und der
Hyper-V-Fallback wurden in den Parser-/Rendererfixtures geprüft; es gab keine
neue native Hyper-V-Aktion. Die [frühere Anzeigeabnahme](TLS_WINDOWS_RENDERED_CONNECTION_SETTINGS_2026-10-21.md)
bleibt ein eigener Nachweisstand.

`NOT_EVALUATED` bedeutet „hier nicht aktuell geprüft“ und bestreitet keine
frühere Qualifikation. Eine ausdrücklich ausgelöste aktuelle Liveprüfung mit
Client-/Ziel-/Frische-/Driftbindung, Browser-Erstellung und Zwischenablage
bleiben offen. Der Browser selbst qualifizierte keine neue Zertifikatskette.
Die übrigen Linux-, Hyper-V-, Lifecycle-, Trustkontext- und Consumeraufgaben
aus dem [TLS-001-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
bleiben erhalten; die Gesamtmatrix ist `partial`. Wire-Fingerprint bleibt
`NOT_OBSERVED`.
