# Verbindungstext kopieren – Abnahme vom 2026-10-25

## Umfang und Ergebnis

Die ausdrückliche Kopieraktion an einer bestehenden eigenen Labkarte wurde
unter Windows mit Docker und Podman auf SQL 2025 CU9, Build `17.0.5005.3`,
geprüft. Alle Labs verwendeten `compact`, Instanz `primary`, ausgeschalteten
Autostart und nicht persistente Stores ohne zusätzliche SQL-Features.
Default und authentifizierter TLS-Modus sind getrennte Zellen. Der Browser
erstellte kein Lab; die kanonischen Creator legten ausschließlich das eigene
Arrange-Lab an. Die Voraussetzung für den strikten Modus war die bereits
qualifizierte CA-/Clientbindung mit vorhandenem CurrentUser-Trust.

Der [Bedienungspfad](../HowTo/WORKFLOW_UI.md#angezeigte-verbindung-kopieren)
erklärt Auswahl, Passwortplatzhalter und Browserfreigabe. Der
[Vertrag](../Architecture/SQL_CONNECTION_SETTINGS.md#angezeigten-connection-string-kopieren)
trennt Kopiererfolg, gespeicherte Flags und aktuelle SQL-Qualifikation.

| Provider | Modus / gespeicherte Flags | Browserfälle | kopierte SQL-Clientresultate | Ergebnis |
|---|---|---|---|---|
| Docker | Default / True, True | 6 | 2 | PASS, eigenes Lab entfernt |
| Docker | authentifiziert / True, False | 6 | 2 | PASS, eigenes Lab entfernt |
| Podman | Default / True, True | 6 | 2 | PASS, eigenes Lab entfernt |
| Podman | authentifiziert / True, False, korrigierter Nachlauf | 6 | 2 | PASS, eigenes Lab entfernt |

Die vier positiven Zellen enthalten insgesamt 24 Browserfälle und acht
Clientresultate mit System.Data.SqlClient und ODBC/sqlcmd. Vier Resultate
verwenden den einfachen True/True-Modus ohne Serverzertifikatsprüfung, vier
den strikten True/False-Modus. Zusätzliche interne Creatorprüfungen werden
nicht als separat erfasste Arrange-Resultate hinzugezählt. Der ursprüngliche
Podman-Fehlerlauf bleibt mit zwei partiellen Browserfällen und zwei
erfolgreichen strikten Clientresultaten daneben erhalten. Alle fünf
tatsächlich angelegten Labs sind entfernt.

## Tatsächlich geprüfter Ablauf

Ein frischer isolierter Headless-Browser lud den echten Produktserver und
die echten Assets. Er wählte die eigene Instanz und prüfte die sichtbaren
TLS-Werte. Nach dem ausdrücklichen Klick las ausschließlich der private
Abnahmeadapter die tatsächliche Browserzwischenablage: Ihr Inhalt entsprach
zeichengetreu dem sichtbaren Connection String samt Passwortplatzhalter.
Die Produktkomponente selbst verwendet nur `writeText`, keinen Readzugriff.

Beide frischen SQL-Clientstacks verwendeten anschließend genau diesen
kopierten Text. Ausschließlich der private Testadapter setzte das eigene
generierte Passwort ein; Endpoint und TLS-Optionen wurden nicht umgeschrieben.
Vor jeder Verwendung band er den Endpoint an den frischen eigenen
Loopback-/Inspect-Port und prüfte OwnBinding, Policy, Zertifikats-, Runtime-
und gespeicherte Textbindung vor und nach jedem Stack. Beide Stacks bestätigten
den erwarteten Build und die verschlüsselte Verbindung.

Der Browser prüfte außerdem eine echte verweigerte Schreibberechtigung,
die feste Fehlermeldung und den unveränderten eigenen Clipboardinhalt. Ein
echter Workflowrefresh verwarf die frühere Kopierrückmeldung. Die begrenzte
HTTP-Allowlist ließ ausschließlich die benötigten Lesezugriffe zu; es gab
keine Erstellungs- oder andere mutierende Browseranforderung. Der leere
Creationstore, geschlossene Browserkontexte und ganze Windows-Jobleere sind
separat erfasst. Danach entfernte der Parent jeweils das genaue eigene Lab
kanonisch und bestätigte Container-/Volumeabwesenheit sowie Bestandsvergleich.

## Erhaltener Fehler und begrenzte Korrektur

Der erste authentifizierte Podman-Lauf kopierte den richtigen Text, endete
aber im Browser mit `CLIPBOARD_SQL_CLIENT_ACK_TIMEOUT`: Die feste
120-Sekunden-Wartefrist lief vor der Clientrückmeldung nach 168,041 Sekunden
ab. Beide strikten SQL-Clients bestanden trotzdem. Dieser ursprüngliche Lauf
bleibt insgesamt FAIL; seine zwei partiellen Browserfälle sind kein
vollständiger Browser-PASS. Jobleere und eigener Cleanup bestanden.

Die private Prüfsteuerung wartet nun höchstens 300 Sekunden auf diese
Rückmeldung und bleibt zusätzlich an ihre feste StopAt-Grenze gebunden.
SQL-Query- und Prozessgrenzen wurden nicht erhöht. Neun fokussierte
Zeitgrenzenfälle und elf Zulassungsfälle bestanden ohne Provideraktion.
Nach unabhängigem Review erhielt ausschließlich diese fehlgeschlagene Zelle
eine neue Einzellabzulassung. Die drei bereits grünen Zellen wurden nicht
wiederholt; ihre ursprüngliche 120-Sekunden-Steuerung bleibt ausgewiesen.
Produktcode und Produktquellframe waren in allen fünf Läufen identisch.

Zwei frühere reine Browser-Preflights bleiben getrennte FAILs: Der erste
scheiterte vor Browserstart an der privaten Pfadverarbeitung, der zweite
nach Browserstart an der Commandline-Metadatenprüfung und vor Clipboardzugriff.
Beide hatten null SQL-Labs. Der korrigierte isolierte Preflight bestand drei
echte Clipboard-API-Assertions mit geschlossenem Browser und leerem Job.
Er ersetzt keine der SQL-Zellen.

## Offlineprüfungen und Nachweisgrenzen

Die echte Produktkomponente bestand 16 fokussierte Offlinefälle; die
tatsächliche Rendererfixture bestand separat 162 Fälle einschließlich beider
Mountaufrufe. Ein ursprünglicher betroffener Lauf scheiterte an einer zu
breiten Transportannahme für die neue reine Clipboarddatei. Die präzise
Ausnahme verlangt weiterhin deren fehlenden Netzwerkzugriff. Nach Korrektur
bestanden acht betroffene Suites einschließlich vollem Analyzer. Zusammen
mit sechs unveränderten zuvor erfolgreichen Suites sind 14 verschiedene
Suites belegt; es gab keinen neuen gemeinsamen Lauf aller 14. Der ursprüngliche
FAIL bleibt erhalten. Ein finales Dokumentationsdelta und das erforderliche
PR-Gate sind davon getrennte Integrationsprüfungen.

Die Laufzeitbelege gehören zum vor dem Dokumentationsabschluss eingefrorenen
Produktframe. Originalterminals, Rohantworten, private Quellstände, Nonce-/
Runbindungen und entfernte kanonische States bleiben lokale Nachweise.
Der unabhängige Kopieplan prüfte fünf eindeutige eigene entfernte Stateroots
und 89 Dateien. Die Kopie erfolgte unter gehaltenen Originalhandles mit
identischen Pfaden, Typen, Bytes und Hashes vor und nach dem Kopieren.

Der Nachweis betrifft die Zwischenablage des isolierten Headless-Browsers,
nicht die vorhandene Windows-Benutzerzwischenablage. Hyper-V-Renderer sind
offline gekoppelt; eine native Hyper-V-Clipboardabnahme fehlt weiterhin.
SQL 2019/2022, andere Patch-/Ressourcenprofile, Linux, weitere Browser-/
Client-/Trustkontexte und andere Erstellungsoptionen bleiben getrennt offen.
Kopieren erzeugt keine neue TLS-Livequalifikation. Der Wire-Fingerprint bleibt
`NOT_OBSERVED`; TLS-001 ist insgesamt weiterhin nur teilweise abgeschlossen.
