# Ressourcenprofile der separaten TLS-Liveaktion – Abnahme vom 2026-10-25

## Umfang und Ergebnis

Die Läufe vom 24./25. Oktober schließen die ausdrückliche Aktion
**TLS jetzt prüfen** auf bestehenden eigenen Labkarten für Windows,
Docker/Podman und die drei operativen SQL-Profile mit `standard` und
`performance`. Standard setzt 4 CPU und 4096 MiB, Performance 8 CPU und
8192 MiB. Instanz `primary`, ausgeschalteter Autostart, nicht persistente
Stores und keine zusätzlichen SQL-Features begrenzen alle Zellen.
Bestehende CA-/Clientbindung und CurrentUser-Trust waren Voraussetzung.

Die [Bedienanleitung](../HowTo/WORKFLOW_UI.md#tls-jetzt-prüfen) führt vom
eigenen operativen Lab zum passenden serverseitigen Run-StateRoot und zur
sichtbaren Prüfung. Der [API-Vertrag](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md)
erklärt Ergebnis und Frische. Die frühere
[Ressourcenabnahme der Browser-Erstellung](TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
prüft einen anderen Pfad mit privaten ResultRefs. Hier erzeugte der kanonische
Creator nur das eigene Arrange-Lab; der Browser führte keine Erstellung aus.

| Provider | SQL-Profil / tatsächlicher Build | Ressourcenprofil | Fälle einschließlich Cleanup | strikte UI / Arrange / Rebind | Ergebnis |
|---|---|---|---|---|---|
| Docker | 2019 CU32 / `15.0.4430.1` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Docker | 2019 CU32 / `15.0.4430.1` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2019 CU32 / `15.0.4430.1` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2019 CU32 / `15.0.4430.1` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Docker | 2022 CU27 / `16.0.4295.3` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Docker | 2022 CU27 / `16.0.4295.3` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2022 CU27 / `16.0.4295.3` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2022 CU27 / `16.0.4295.3` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Docker | 2025 CU9 / `17.0.5005.3` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Docker | 2025 CU9 / `17.0.5005.3` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2025 CU9 / `17.0.5005.3` | standard | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |
| Podman | 2025 CU9 / `17.0.5005.3` | performance | 10 | 4 / 2 / 2 | PASS, eigenes Lab entfernt |

Die zwölf positiven Zellen enthalten 108 Workerfälle und zwölf eigene
Cleanupfälle, insgesamt 120. Je zwei sichtbare positive Prüfungen liefern
vier strikte UI-Clientresultate. Je zwei zusätzliche Arrange- und
Rebindresultate bleiben getrennt: insgesamt 48 UI-, 24 Arrange- und 24
Rebindresultate mit System.Data.SqlClient und ODBC/sqlcmd. Interne zusätzliche
Creatorprüfungen werden nicht erneut gezählt. Drei ursprüngliche FAILs
bleiben daneben erhalten; alle 15 tatsächlich angelegten Labs sind entfernt.

## Tatsächlich geprüfter Ablauf

Der Creator band Auditroot und Ticket vor eigenen Policy-, Run- und
Providereffekten. Der echte Produktserver verwendete genau diesen Root.
Ein frischer Browser lud echte Assets, wählte das konkrete eigene Ziel und
führte drei echte POSTs aus: zwei positive vollständige Liveprüfungen und
eine sichtbare Ablehnung nach dem Neustart. Nach ausdrücklicher Wiederbindung
entstand ein neues Ergebnis; Refresh verwarf es wieder. Es gab keine
simulierte positive HTTP- oder SQL-Antwort.

Ein unabhängiges Oracle prüfte genau ein frisches Inspectobjekt des
ursprünglichen eigenen Containers nach Erstellung und nach Neustart:
24 originale Antworten mit exakten CPU- und Speicherlimits. Gespeicherte
Profilwerte waren kein Ersatz. Die kanonische Neustartablehnung wurde
zusätzlich mit `TLS_LAB_RESTART_REQUIRES_REBIND`, null neuen Clientprüfungen
und einer tatsächlich neueren Start-Epoche gebunden.

Jeder ganze Windows-Job war vor dem übergeordneten Remove leer. Der Cleanup
bestätigte kanonischen Status `REMOVED`, Container- und Volumeabwesenheit am
ursprünglichen Pin und den Bestandsvergleich. Vorhandene CA/Trust,
ursprüngliche Schlüssel, fremde Worktrees und Stashes sowie die vorherigen
geschützten Archive blieben erhalten. Kein weiterer eigener Abnahmerun
lief parallel.

## Erhaltene ursprüngliche FAILs

Der erste Docker-/SQL-2019-Standardlauf endete vor Browserbereitschaft mit
zwei Arrange- und null UI-Resultaten. Die genaue ursprüngliche
Serverausnahme wurde nicht aufgezeichnet. Eine getrennte Charakterisierung
reproduzierte die ungeeignete Script-Scope-Bindung des privaten Serverhooks;
der korrigierte Hook hält seinen Zustand nur im eigenen Serverprozess.
Die ursprünglichen temporären Operatorpfade wurden ebenfalls nicht erfasst;
für sie wird keine Dateiabwesenheit behauptet. Daraus wurde keine Befugnis
zur Suche oder Bereinigung fremder Tempdaten abgeleitet.

Der zweite Dockerversuch bleibt FAIL nach sechs Workerfällen, vier
partiellen UI-, zwei Arrange- und zwei Rebindresultaten. Die Browsergrenze
verzeichnete einen abgewiesenen Request; seine ursprüngliche URL wurde
nicht aufgezeichnet. Eine getrennte Charakterisierung des tatsächlichen
Produktmoduls belegte den regulären Startup-GET auf `/api/tls-created-targets`.
Die korrigierte Steuerung erlaubt genau diesen lesenden Aufruf und prüft
genau einmal die leere Creationliste. Erstellungs-POSTs bleiben gesperrt.
Der ursprüngliche FAIL erhält keinen nachträglichen Refresh-PASS.

Der erste Podman-/SQL-2019-Standardlauf endete nach dem Creator und vor dem
ersten Workerfall mit `RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE`.
An zwei privaten Budget-Aufrufstellen im Quelltext fehlte `-Record`.
Der ursprüngliche Lauf scheiterte bereits in der ersten Bindungsprüfung;
die danach folgende Ressourcenprüfung erreichte er nicht. Die tatsächlichen
kanonischen Funktionskörper reproduzierten die Policyprojektion ohne
ursprüngliche Podman-Maschinenbindung offline. Beide fehlerhaften
Quell-Aufrufstellen reichen nun die frische OwnBinding.Record weiter.
Es gab keine Policyänderung, synthetische Maschinenbindung oder VM-Mutation.
Null UI-Resultate und null Workerfälle bleiben ausgewiesen; aus dem bloßen
Creatorerfolg werden keine separat erfassten Clientresultate abgeleitet.

Alle drei ursprünglichen FAILs hatten bestätigte ganze Jobleere,
eigenen Cleanup, Ressourcenabwesenheit und Bestandsvergleich. Ihre Originale,
Quellkopien und Status bleiben unverändert. Nachläufe erhielten jeweils eine
neue begrenzte Zulassung; bestehende positive Zellen wurden nicht wiederholt.

## Quellen, Belegbindung und verbleibender Scope

Alle Läufe verwendeten unverändert den Produktstand
`01a2c3013228a0d8ea0c669e590f874af2ca56c7`, Tree
`229543740001c99ad36dccd01ef221d905c7e588`. Die beiden positiven
Docker-/SQL-2019-Zellen belegen die private Steuerung vor der Recordkorrektur;
die zehn weiteren Zellen belegen die korrigierte Übergabe. Es gibt keinen
gemeinsamen neuen Lauf aller zwölf Zellen auf einem einzigen Controllerstand.
Der Produktcode wurde in dieser Welle nicht verändert.

Die fokussierten Offlineprüfungen und unabhängigen Quellenreviews der
privaten Steuerung bleiben an ihre jeweiligen Stände gebunden. Die spätere
passive Sammlung prüfte Originalhashes, Browserseals, Ticket-/Run-/Nonce-
und Profilbindungen sowie alle 24 Inspectantworten. Der unabhängig geprüfte
Kopieplan umfasste 15 eindeutige eigene entfernte Auditroots und 372 Dateien.
Neue private Kopien entstanden unter gehaltenen Originalhandles; tatsächliche
Metadatenbytes und Source-/Copy-Shapes blieben gleich. Diese Sammlung führte
keine Provideraktionen aus und erzeugte keinen zusätzlichen Runtime-PASS.
Der lokale Deltalauf vor der letzten Textpräzisierung bestand alle fünf
ausgewählten Suites: ConsoleUi, Documentation, Privacy, PublicCommandConsole
und WorkflowUi. Die unveränderten grünen Suites werden für die reine
Präzisierung der Fehlerbeschreibung nicht wiederholt; das betroffene
Dokumentations-/Privacydelta und die erforderlichen finalen CI-Gates bleiben
Voraussetzung der regulären Integration.

Die Abnahme belegt Ressourcenlimits und TLS-/UI-Verhalten, keine
Benchmarkleistung, Stress-, Custom- oder Ressourcen-Reconcile-Aktion.
Clipboard, andere Erstellungsoptionen, weitere Patch-/Client-/Plattformkontexte,
öffentliche Linux-Registry-/Export-/Consumerpfade, öffentliche
Hyper-V-False-/Exportpfade und operatives Renewal/Requalifikation/Recovery/
Rollback sowie weitere Trustkontexte und Retirement bleiben eigene Scopes.
Weitere Toolbelt-Entwicklung bleibt pausiert. Wire bleibt `NOT_OBSERVED`;
TLS-001 bleibt insgesamt `partial`.
