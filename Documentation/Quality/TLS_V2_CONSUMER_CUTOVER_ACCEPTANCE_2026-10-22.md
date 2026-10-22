# Native Windows-Abnahme des V2-Consumers vom 2026-10-22

Der öffentliche [V2-Reader](../Architecture/AUTHENTICATED_TLS_V2_READER.md)
und der gekoppelte Toolbelt-Consumer bestanden sechs getrennte native
Matrixfälle. Der tatsächliche Clientkontext war Windows mit PowerShell 7.5+
und registriertem CurrentUser-/Client-/Trustkontext. Linux bezeichnet in
diesem Nachweis die SQL-Zielplattform.

| Provider | SQL-Profil | Beobachteter SQL-Build | Labfälle | Consumerfälle | Eigener Cleanup |
|---|---|---|---|---|---|
| Docker | 2019 CU32 | `15.0.4430.1` | 5 PASS | 3 PASS | PASS |
| Podman | 2019 CU32 | `15.0.4430.1` | 5 PASS | 3 PASS | PASS |
| Docker | 2022 CU27 | `16.0.4295.3` | 5 PASS | 3 PASS | PASS |
| Podman | 2022 CU27 | `16.0.4295.3` | 5 PASS | 3 PASS | PASS |
| Docker | 2025 CU9 | `17.0.5005.3` | 5 PASS | 3 PASS | PASS |
| Podman | 2025 CU9 | `17.0.5005.3` | 5 PASS | 3 PASS | PASS |

## Tatsächliche Ausführung

Jeder Fall verwendete ein neues eigenes öffentliches False-Lab. Die fünf
Labfälle prüften beide strikten Clientstacks, frischen qualifizierten Export,
echte Anmeldung mit exportierten Zugangsdaten, die serverseitige CLI-/
Workflowprojektion und die Ablehnung beziehungsweise Wiederherstellung
manipulierter oder veralteter Bindungen. Die bezeichneten strikten
Clientresultate bleiben von den gruppierten Fällen getrennt.

Die drei zusätzlichen Consumerfälle waren:

1. Öffentlicher Reader mit denselben Exportbytes und aktuellen Bindungen.
2. Tatsächlicher Toolbelt-Runner mit `TestPurpose=AuthenticatedTls`,
   System.Data.SqlClient-Preflight und echtem sqlcmd-/ODBC-Adapter. Beide
   Stacks prüften den exakten SQL-Build und verschlüsselten Transport bei
   `Encrypt=True;TrustServerCertificate=False`. Die SQL-Probe legte keine
   fachlichen SQL-Objekte an.
3. Tatsächlicher Runner mit gefälschter V2-Signatur: feste Ablehnung vor
   dem SQL-Preflight. Dieser Fall ist von TLS-Zertifikatsnegativfällen getrennt.

Die bisherigen Windows-Kryptoproben für unvertraute Kette, falschen Namen
und Ablauf bleiben eigenständige historische Nachweise. Sie wurden hier
nicht erneut ausgeführt oder als neue Consumerfälle gezählt.

Alle sechs erfolgreichen Labs endeten `REMOVED`. Same-pin Container-/
Volumeabwesenheit, ursprüngliche Runtime-Inkarnation vor und nach der
Abwesenheitsprüfung, unveränderter eigener Record, feste Exportentfernung
und Bestandsdateivergleich bestanden. Bestehende CA, Trust, Schlüssel,
Hyper-V-VMs und Disks blieben erhalten.

## Erhaltene Fehler und Korrekturen

Zwei frühere eigene Docker-/SQL-2019-Läufe bleiben FAIL:

- Der erste Lauf scheiterte nach vier Labfällen an einer Schemaablehnung,
  die der private Boolean-Prüfer als Exception statt als `false` lieferte.
  Die Korrektur erhielt den festen ablehnenden Fehler des öffentlichen Readers.
- Der zweite Lauf bestand fünf Labfälle und den öffentlichen Reader, scheiterte
  aber im echten Toolbelt-Adapter. Eine erneute PATH-Auflösung der
  Runtime-Inkarnationsprüfung fand dessen Docker-Shim. Der TLS-Aufrufer
  übergibt nun ausdrücklich den frisch validierten ursprünglichen Programmpfad;
  Leaf-, Reparse- und aktuelle Owned-Policypinprüfungen bleiben erhalten.

Beide fehlgeschlagenen Labs sind ebenfalls entfernt und ihre ursprünglichen
Belege unverändert erhalten. Insgesamt wurden acht eigene Labs ausgeführt;
die sechs PASS-Zeilen stammen aus getrennten korrigierten Ausführungen.

## Quellbindung und Grenzen

Die sechs erfolgreichen Ausführungen verwendeten einen gemeinsamen stabilen
Produktstand auf Lab-Basis `1095f5eedf721bdd887f6dc026652cfcf435e8c5`
und Toolbelt-Basis `2afeb16c852cb2441754d1ede5e5f08de7ef76b5`.
Lokale Quellinventare, exakte Dateihashes, unabhängige Reviews und terminale
Belege binden diesen Stand. Die danach ergänzte Maskierung sensibler
Bytearray-Eingaben und generischer CLI-/Browserausgaben betrifft die
Anzeigegrenze; die ausgeführten Reader-, Runtime- und Toolbelt-Transportquellen
bleiben davon unverändert. Anzeige-/Konvertierungsprüfungen sind eigene
synthetische Nachweise und kein zusätzlicher nativer TLS-Lauf.

Rohdaten, Zugangsdaten und private Belege bleiben lokal außerhalb Git.
Die CI-Abschlussgates werden in den zugehörigen Lab-/Toolbelt-PRs geführt.
Linux-Clientprozesse, öffentliche Hyper-V-False-/Exportlane, weitere Consumer,
operative Erneuerung, weitere Trustkontexte und die restlichen gerenderten
Browser-/Clipboardpfade bleiben offen. Dieser Nachweis schließt die gesamte
TLS-001-Matrix und SC-2026-045 nicht pauschal ab.
