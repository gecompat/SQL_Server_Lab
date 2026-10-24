# Ressourcenprofile der TLS-Browsererstellung – Abnahme vom 2026-10-24

## Umfang und Ergebnis

Die zusätzliche Windows-Abnahme schließt `standard` und `performance` für
beide Erstellungsmodi, Docker und Podman sowie SQL 2019 CU32, SQL 2022 CU27
und SQL 2025 CU9. `standard` setzt 4 CPU und 4096 MiB, `performance` 8 CPU
und 8192 MiB. Alle Zellen verwendeten Instanz `primary`, ausgeschalteten
Autostart, keine persistenten Stores und keine zusätzlichen SQL-Features.
Die authentifizierten Zellen benötigten die bereits eingerichtete CA,
Clientbindung und den passenden CurrentUser-Trust.

Die [Anleitung](../HowTo/WORKFLOW_UI.md#container-lab-erstellen) beschreibt
die einfache Erstellung; der [authentifizierte Dialog](../HowTo/WORKFLOW_UI.md#authentifiziertes-container-lab-erstellen)
verwendet die bestehende [Sitzungs- und Allokationsbindung](../Architecture/AUTHENTICATED_TLS_UI_CREATION.md).
Die früheren kompakten Abnahmen bleiben an ihre getrennten Quellen gebunden.

| Modus | SQL-Profil / tatsächlicher Build | Provider | Ressourcenprofil | Ursprünglicher Controller | Nachweisabschluss |
|---|---|---|---|---|---|
| Default | 2019 CU32 / `15.0.4430.1` | Docker | standard | FAIL, Dateirechte des Browserbelegs | vollständige Laufzeitbelege, separat passiv abgeschlossen |
| Default | 2019 CU32 / `15.0.4430.1` | Docker | performance | PASS | eigenes Lab entfernt |
| Default | 2019 CU32 / `15.0.4430.1` | Podman | standard | PASS | eigenes Lab entfernt |
| Default | 2019 CU32 / `15.0.4430.1` | Podman | performance | PASS | eigenes Lab entfernt |
| Default | 2022 CU27 / `16.0.4295.3` | Docker | standard | PASS | eigenes Lab entfernt |
| Default | 2022 CU27 / `16.0.4295.3` | Docker | performance | PASS | eigenes Lab entfernt |
| Default | 2022 CU27 / `16.0.4295.3` | Podman | standard | PASS | eigenes Lab entfernt |
| Default | 2022 CU27 / `16.0.4295.3` | Podman | performance | PASS | eigenes Lab entfernt |
| Default | 2025 CU9 / `17.0.5005.3` | Docker | standard | PASS | eigenes Lab entfernt |
| Default | 2025 CU9 / `17.0.5005.3` | Docker | performance | PASS | eigenes Lab entfernt |
| Default | 2025 CU9 / `17.0.5005.3` | Podman | standard | PASS | eigenes Lab entfernt |
| Default | 2025 CU9 / `17.0.5005.3` | Podman | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2019 CU32 / `15.0.4430.1` | Docker | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2019 CU32 / `15.0.4430.1` | Docker | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2019 CU32 / `15.0.4430.1` | Podman | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2019 CU32 / `15.0.4430.1` | Podman | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2022 CU27 / `16.0.4295.3` | Docker | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2022 CU27 / `16.0.4295.3` | Docker | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2022 CU27 / `16.0.4295.3` | Podman | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2022 CU27 / `16.0.4295.3` | Podman | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2025 CU9 / `17.0.5005.3` | Docker | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2025 CU9 / `17.0.5005.3` | Docker | performance | PASS | eigenes Lab entfernt |
| Authentifiziert | 2025 CU9 / `17.0.5005.3` | Podman | standard | PASS | eigenes Lab entfernt |
| Authentifiziert | 2025 CU9 / `17.0.5005.3` | Podman | performance | PASS | eigenes Lab entfernt |

Insgesamt liegen für 24 Zellen 204 erfolgreiche Einzelfälle vor, darin
120 Browserfälle. Die zwölf Defaultzellen enthalten je sieben Fälle,
vier davon im Browser, und zwei True/True-Clientresultate: insgesamt 24.
Die zwölf authentifizierten Zellen enthalten je zehn Fälle, sechs davon
im Browser, vier strikte UI- und zwei zusätzliche Arrange-Clientresultate:
insgesamt 48 strikte UI- und 24 Arrange-Resultate. System.Data.SqlClient
und ODBC/sqlcmd sind getrennt vertreten. Je authentifizierter Zelle wurden
zwei positive sichtbare Liveprüfungen beider Clients erfasst; interne
Creator-/Rebind-Probes werden nicht zusätzlich gezählt.

Alle 24 reservierten Labs wurden tatsächlich erstellt und entfernt.
23 ursprüngliche Controllerabschlüsse sind PASS. Der erste bleibt FAIL;
sein vollständiger Laufzeitbeleg und sein späterer passiver Nachweisabschluss
sind getrennt ausgewiesen. Es gab keine erneute native Ausführung dieser Zelle.

## Tatsächlich geprüfte Ressourcen und Abläufe

Der echte Produktserver und ein frischer Browserkontext führten jede
Erstellung aus. Die gewählte Profilkennung blieb an den tatsächlichen
Browserrequest gebunden. Ein unabhängiges Oracle prüfte die CPU- und
Speichergrenzen aus genau einem frischen Inspectobjekt des eigenen,
ursprünglich gebundenen Containers. Gespeicherte Ressourcenwerte waren
kein Ersatz für Inspect. CPU-Quota/-Period beziehungsweise NanoCPU und
die Speichergrenze mussten genau zum gewählten Katalogprofil passen.

Im Defaultmodus bestanden die sichtbaren True/True-Einstellungen, genau
eine tatsächliche Erstellung, beide SQL-Clients am erwarteten Build und
der tatsächliche UI-Remove. True/True prüft das Serverzertifikat nicht.
Im authentifizierten Modus kamen Allokations-/Policy-/Runbindung, eine
zusätzliche strikte API-Prüfung, zwei positive sichtbare Liveprüfungen,
Stop/Start mit Ablehnung vor neuen Clients, ausdrückliche Wiederbindung
und Refreshverfall hinzu. Die Ressourcen wurden nach dem Neustart erneut
am tatsächlichen Container geprüft.

Alle ganzen Windows-Jobs waren am Ende leer. Der übergeordnete Cleanup
bestätigte jeweils den bereits abgeschlossenen UI-Remove, die Abwesenheit
des eigenen Containers und Volumes am ursprünglichen Pin sowie den
Bestandsvergleich. Bestehende CA/Trust, ursprüngliche Schlüssel, fremde
Worktrees und Stashes sowie die vorherigen geschützten Archive blieben
erhalten. Die kanonischen entfernten Runstates wurden beibehalten.

## Ursprünglicher Controllerfehler und passiver Abschluss

Der Worker der ersten Docker-/SQL-2019-Standardzelle bestand alle sieben
Fälle, beide SQL-Clients und UI-Remove. Nach bestätigter ganzer Jobleere
lehnte ihr Parent den Browserbeleg wegen geerbter statt explizit
geschützter Dateirechte ab. Tatsächlich erlaubten dessen Regeln nur den
eigenen Benutzer und SYSTEM. Sein nachfolgender Cleanup bestätigte die
Entfernung, Ressourcenabwesenheit und den Bestandsvergleich.
Originaldatei, ursprünglicher Gesamt-FAIL
und ursprünglicher Admissionstatus blieben unverändert.

Der gesonderte passive Abschluss band alle 26 Originaldateien, Run,
Nonce und Quellframe. Er prüfte die vorhandenen Laufzeit-/Cleanupbelege
und versiegelte den begrenzten Browserbeleg unter gehaltenem Lesehandle
atomar privat. Dabei entstanden weder Provideraktionen noch neue Labs.
Die unabhängige Prüfung bestätigte die vollständigen Laufzeitbelege;
der enge Folgeguard erkennt ausschließlich diesen exakt gebundenen
Ausnahmefall. Alle anderen Vorgänger benötigen ihren ursprünglichen PASS.

Für folgende Zellen versiegelt der Worker den Browserbeleg nach dem
bestätigten Nodeende. Objektform, doppelte JSON-Properties, skalare Typen,
erlaubte Felder und einzelne Casestrings werden geschlossen geprüft;
die Ausgabe enthält eine feste Projektion. Der allgemeine private Reader
wurde nicht gelockert. Der dafür tatsächlich ausgeführte frühere Sealer,
sein Ergebnis und der passive Abschluss bleiben getrennt vom später
gehärteten Sealerstand erhalten.

## Quellen, lokale Prüfungen und Grenzen

Alle 24 Zellen verwendeten denselben unveränderten Produktstand
`c0ac64a61a7829cce685ddcb57d7c96de6cbd256`, Tree
`70f41e7aa5dfcb5f216efcc2b755f783a072ea42`. Nativer Frame:
`B7E86968E56BDED8769EA0BF31ECD5C44DD51121AD60869C064C6CFC18C0490D`;
vollständige Baseline:
`F508030E5C38EA55A606950A8662C2E64D4D0F614A433BB60D9370D388B3F7AB`.
1614 Dateien einschließlich Git-Zuordnung und 28 An-/Abwesenheiten der
AGENTS-Kette waren gebunden. Die private Steuerung wurde nach dem ersten
Controllerfehler korrigiert; der Produktcode blieb unverändert.

Die neuen Offlineprüfungen bestanden getrennt: 92 Ressourcenoracles,
102 Zulassungsfälle, 449 Browserrequest-Grenzen, 14 Kapazitätsentscheidungen
und 17 Cleanupguards. Das Korrekturdelta bestand 18 Postcondition-/Guardfälle
und anschließend 38 JSON-Formprüfungen. Diese unterschiedlichen Quellbindungen
sind kein gemeinsamer neuer Gesamtlauf. Ein zuvor unabhängig gefundener
inkonsistenter privater Repopfad sowie die offene JSON-Formgrenze sind
korrigiert und unabhängig geschlossen. Frühere private Fokus-/Abschlussfehler
und ein rein lesender Kapazitäts-Timeout bleiben erhalten; sie erzeugten
keine weiteren Labs. Unveränderte grüne Produktprüfungen wurden über den
exakten vorherigen Tree gebunden und nicht erneut ausgeführt.

Der lokale Deltalauf der fünf ausgewählten statischen Suites beendete vier
Suites erfolgreich. Die Workflow-Suite enthielt 78 PASS und zwei
HTTP-Fixture-Timeouts bei 90 beziehungsweise 120 Sekunden. Ihre isolierte
Diagnose mit unveränderten Quellen beendete alle 87 beziehungsweise
107 Assertions nach 49,6 beziehungsweise 61,3 Sekunden, jeweils innerhalb
des ursprünglichen Budgets und ohne Provider-Mutation. Der Timeout war
isoliert nicht reproduzierbar; seine ursprüngliche Ursache bleibt unbekannt.
Originaler Suite-FAIL und beide Ergänzungsbelege bleiben erhalten. Die
übrigen 78 grünen Fixtureabschlüsse wurden nicht wiederholt; daraus entsteht
kein neuer gemeinsamer Workflow-Suite-PASS. Die zusätzliche enge Korrektur
einer veralteten Ressourcenprofilgrenze im Connection-Settings-Vertrag
gehört zum nachfolgenden Dokumentationsdelta.

Die Abnahme prüft Ressourcenlimits und TLS-/UI-Verhalten, keine Auslastung
oder Benchmarkleistung. Zusätzliche Ressourcenprofile der separaten
Liveaktion bestehender Labkarten sind damit nicht abgenommen.
Andere Erstellungsoptionen, Patch-, Client- und
Plattformkontexte, Clipboard, öffentliche Linux-Registry-/Export-/Consumerpfade,
öffentliche Hyper-V-False-/Exportpfade und der operative Renewal-/Recovery-/
Trustlebenszyklus bleiben getrennte TLS-001-Scopes. Wire bleibt
`NOT_OBSERVED`; die gesamte TLS-001-Matrix bleibt `partial`.
Die erforderlichen finalen PR-Gates bleiben Integrationsbedingung.
