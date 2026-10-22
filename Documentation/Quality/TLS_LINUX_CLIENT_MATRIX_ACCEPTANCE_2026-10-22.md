# Native Linux-TLS-Clientmatrix vom 2026-10-22 (UTC)

## Ergebnis und Geltungsbereich

Die sechs getrennten Kryptozellen für Docker und Podman mit SQL Server 2019
CU32, 2022 CU27 und 2025 CU9 bestanden jeweils neun Fälle mit zwei echten
Linux-Clientstacks. Das ergibt 54 Fälle und 108 Clientergebnisse: 96 mit
`TrustServerCertificate=False` und zwölf ausdrücklich getrennte positive
Bypasskontrollen mit `TrustServerCertificate=True`.

Der Controller lief unter Windows. Die Clients liefen als Benutzer `10001:0`
in eigenen eingeschränkten Linux-Containern im Netzwerk-Namespace desselben
neuen eigenen SQL-Runs. Das ist keine Abnahme eines nativen Linux-Hosts,
öffentlicher Linux-Registry-/Exportpfade oder eines Linux-Toolbelt-Consumers.
Die [Windows-V2-Consumer-Abnahme](TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
bleibt ein getrennter Nachweis.

| Provider | SQL-Profil | Tatsächlich geprüfter Build | Fälle | Clientergebnisse | Davon strikt / Bypass | Ergebnis |
|---|---|---|---|---|---|---|
| Docker | 2019 CU32 | `15.0.4430.1` | 9 | 18 | 16 / 2 | PASS |
| Podman | 2019 CU32 | `15.0.4430.1` | 9 | 18 | 16 / 2 | PASS |
| Docker | 2022 CU27 | `16.0.4295.3` | 9 | 18 | 16 / 2 | PASS |
| Podman | 2022 CU27 | `16.0.4295.3` | 9 | 18 | 16 / 2 | PASS |
| Docker | 2025 CU9 | `17.0.5005.3` | 9 | 18 | 16 / 2 | PASS |
| Podman | 2025 CU9 | `17.0.5005.3` | 9 | 18 | 16 / 2 | PASS |

Jede Zelle bestätigte vollständigen eigenen Cleanup, den jeweiligen
Bestandsvergleich, terminales Workerende und null verbleibende Prozesse im
gebundenen Windows-Job. Keine Zelle benötigte einen Hardstop.

## Tatsächlich ausgeführte Fälle

Beide Stacks sind `System.Data.SqlClient` und das tatsächliche `sqlcmd` mit
geladenem Microsoft-ODBC-Treiber. Alle sechs Zellen verwendeten PowerShell
`7.6.6` und `.NET 10.0.12` im Linuxclient. Positive Proben fragten den SQL-Build und
`encrypt_option` der eigenen Sitzung ab. Jede Probe verwendete einen frischen
Clientprozess. Negative Proben mussten als Zertifikatsablehnung enden;
Namensauflösungs-, Netzwerk-, Login- oder unklassifizierte Fehler gelten nicht
als erfolgreiche TLS-Negativfälle.

| Fall | Modus und erwartetes Ergebnis beider Stacks |
|---|---|
| `STRICT_TRUSTED` | Prozesslokaler CA-Trust, False, echte verschlüsselte SQL-Verbindung |
| `DEFAULT_TRUE` | Kein übergebener CA-Trust, True, echte verschlüsselte SQL-Verbindung |
| `UNTRUSTED` | Trust entzogen, False, Zertifikat vor fachlicher SQL-Arbeit abgewiesen |
| `TRUST_RESTORED` | Derselbe Trust wiederhergestellt, False, positive Kontrolle |
| `WRONG_SAN` | Isoliertes Zertifikat mit falschem SAN, False, Identitätsablehnung |
| `NAME_CONTROL_RESTORED` | Passendes Zertifikat wiederhergestellt, False, positive Kontrolle |
| `PRE_EXPIRY_CONTROL` | Noch gültiges kurzlebiges Zertifikat, False, positive Kontrolle |
| `EXPIRED` | Tatsächlichen Ablauf abgewartet, False, Ablehnung ohne SQL-Neustart |
| `NEW_KEY_RENEWAL` | Neues eigenes Leaf mit anderem Schlüssel, False, positive Kontrolle |

Der Ablauf wurde mit realer Zeit und unveränderter SQL-Prozessepoche geprüft;
keine Uhr wurde verstellt. Der neue Schlüssel gehörte ausschließlich zur
jeweiligen frischen Fixture. Diese Kryptokontrolle ist kein öffentlicher
operativer Renewal-, Resume- oder Rollbackworkflow.

`DEFAULT_TRUE` belegt die Clientoption am bereits mit einem eigenen
Fixturezertifikat eingerichteten Server. Der Prozess erhielt dabei keinen
CA-Trust; das frische Fixture-CA-Zertifikat konnte nicht vorinstalliert sein.
Dieser Fall ersetzt keinen getrennten öffentlichen Linux-Erstellungsnachweis
ohne vorherige eigene CA-/Leafvorbereitung.

## Quellen und Korrekturgrenzen

Der [ausdrückliche Acceptance-Harness](../../Tests/Integration/Invoke-AuthenticatedTlsLinuxAcceptance.ps1)
verwendet die [gebundene Clientfixture](../Architecture/OWNED_HOST_CI_ISOLATION.md).
Die sechs erfolgreichen Zellen stammen aus vier geschützten lokalen
Quellframes: Docker/2019 aus Frame 11, Docker/2022 aus Frame 12, Docker/2025
aus Frame 13; alle drei Podman-Zellen aus Frame 26. Die ursprünglichen Quellen,
vollständigen Logs und Laufzeitbindungen bleiben lokal außerhalb Git.

Die späteren Diagnose- und Podman-Korrekturen machen daraus keinen erneut
ausgeführten Docker-Linux-Nachweis am finalen Integrationshead. Unveränderte
grüne Docker-Zellen wurden nicht wiederholt. Der Schlussstand benötigt seine
eigenen betroffenen statischen und erforderlichen CI-Gates.

Die reproduzierten Quellfehler wurden begrenzt korrigiert: kanonische
Connection-String-Schlüssel, kulturunabhängige RFC3339-Auswertung und die
SQL-2022-/SQL-2025-Accountgruppe bei unveränderter UID; bei Podman dessen
tmpfs-Eigentümerschaft, tatsächliche Capabilitydarstellung und der eigene
auflösbare UTS-Hostname. Der SQL-Zielname und Zertifikats-SAN bleiben
`localhost`. Die gemeinsame Hostsdatei wird nicht nachträglich bearbeitet.

Die ursprüngliche Podman-ODBC-Anmeldezeitüberschreitung enthielt den numerischen
Host-not-found-Code. Geschlossene NSS-Beobachtungen zeigten später einen nicht
auflösbaren eigenen Hostnamen bei auflösbarem `localhost`. Im erfolgreichen
Stand stimmen eigener Hostname und Intentname überein; beide NSS-Abfragen
bestanden in allen fünf Clientphasen jeder Podman-Zelle. Welche Resolverparameter
der ursprüngliche ODBC-Aufruf verwendete, wurde nicht beobachtet.

Die neue NSS-Shellgrenze besitzt zusätzlich eine echte CRLF-Quellfixture:
vier Helperfälle schlugen vor der LF-Normalisierung fehl. Nur der feste
Linux-Shelltext wird normalisiert, keine Argumente oder Zugangsdaten.
Ein separater nativer NSS-Aufruf mit Exitcode 2 bleibt unverändert
FAIL/UNCLASSIFIED; die ursprüngliche Fehlermeldung wurde nicht als Text
gespeichert. Lokale Git-sh-Syntaxproben tolerierten CRLF und gelten ausdrücklich
nicht als Reproduktion des Linux-Shellfehlers.

Vor den sechs erfolgreichen Zellen stehen 16 erhaltene fehlgeschlagene
Reservierungen: sechs Docker-/2019-Versuche, ein Docker-/2022-Versuch und neun
Podman-/2019-Versuche. Die erste endete vor SQL-Arrange. Drei frühere
Bestandsvergleiche bleiben wegen nicht zugeordneter zusätzlicher Container
fehlgeschlagen; ergänzende rein lesende Nachweise bestätigten eigenen Cleanup
und Erhalt des ursprünglichen Bestands. Fremde Ressourcen wurden nicht
übernommen oder entfernt. Diese Ergänzungen ändern keinen ursprünglichen FAIL
und keinen damaligen globalen Bestandsvergleich in PASS.

## Validierung und verbleibende Schritte

Die fokussierte Suite bestand abschließend mit 364 PASS und 0 FAIL. Die
22 ausgewählten lokalen Integrationssuites sowie das spätere vierteilige
Korrekturdelta einschließlich vollständigem Analyzer bestanden. Produkt,
Diagnosegrenzen und feste native Zulassungen wurden unabhängig ohne offene
Findings geprüft. Die unveränderten ursprünglichen FAIL-/Rotbelege bleiben
erhalten. Finale PR-Pflichtgates sind eine getrennte Integrationsbedingung.

Offen bleiben insbesondere:

- öffentliche Linux-Moduswahl, Registry, qualifizierter Export und tatsächliche
  Linux-Verbraucher einschließlich Toolbelt;
- öffentliche Hyper-V-False-Erstellung und V2-Export sowie die übrigen
  Windows-/Linux-Clientzellen für Windows-SQL-Ziele;
- operative Zertifikatserneuerung mit erneuter Qualifikation, Fehlern,
  Abbruch/Resume, Recovery und Rollback;
- weitere CA-/Trustkontexte, deren Retirement und weitere Consumer-Cutover;
- vollständige Browser-Erstellung, aktuelle Livequalifikationsaktion und
  Clipboardpfade aller Exportformen;
- zusätzlicher Wire-Zertifikatsfingerprint (`NOT_OBSERVED`).

Andere SQL-/Patchstände werden nicht mitqualifiziert. Bestehende Host-Truststores,
ursprüngliche CA-/Keydateien und Hyper-V-Ressourcen wurden für diese Fixture
nicht verändert. Die gesamte TLS-001-Matrix und SC-2026-045 sind dadurch nicht
abgeschlossen. Der [kanonische TLS-001-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md)
bleibt für die weiteren Teilaufgaben maßgeblich.
