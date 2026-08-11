# AutomatedLab Provider Spike - Abnahmekriterien

## Zweck

Diese Kriterien verhindern, dass eine technisch interessante Demo ohne
nachgewiesenen Framework-Nutzen zu einer dauerhaften zweiten
Orchestrierungsplattform wird.

Der Vergleich erfolgt gegen den zum Ausführungszeitpunkt aktuellen nativen
Hyper-V-Pfad von `SQL_Server_Lab`.

## Phase A - Minimaler Provider-Vertical-Slice

| ID | Kriterium | Nachweis |
|---|---|---|
| `AL-001` | exakt festgelegte vCPU- und RAM-Werte | Actual State entspricht dem Blueprint |
| `AL-002` | festgelegte Disk- und Netzwerkzuordnung | Hyper-V-Objekte und Gastzustand sind nachvollziehbar |
| `AL-003` | lokale, benutzerfreigegebene Windows-/SQL-Medien | kein impliziter Download und kein versteckter Lizenzentscheid |
| `AL-004` | festgelegte SQL-Version, Edition und CU | SQL-Readiness bestätigt den gewünschten Build |
| `AL-005` | vollständig unbeaufsichtigter normaler Lauf | keine Prompts nach erster Mutation |
| `AL-006` | stabile Ressourcenidentitäten | alle erzeugten Objekte sind über Run-ID und Scope auffindbar |
| `AL-007` | read-only Inspect | Actual State ist ohne Mutation erfassbar |
| `AL-008` | idempotenter Wiederholungsaufruf | kein Duplikat und keine unkontrollierte zweite Installation |
| `AL-009` | vollständiges Destroy | keine run-lokalen VMs, Disks, Switches oder temporären Dateien verbleiben |
| `AL-010` | Fremdobjektschutz | vorhandene, nicht zum Run gehörende Ressourcen bleiben unverändert |

Phase A ist Pflicht. Ohne vollständigen Nachweis wird keine Cluster- oder
Topologiephase begonnen.

## Phase B - Fehler und Recovery

| ID | Kriterium | Nachweis |
|---|---|---|
| `AL-101` | Abbruch nach VM-Erzeugung | Run endet sichtbar und Cleanup findet die VM |
| `AL-102` | Abbruch während Gastkonfiguration | Resume oder deterministisches Destroy ist möglich |
| `AL-103` | Reboot während Bereitstellung | keine doppelte Installation nach Wiederaufnahme |
| `AL-104` | AutomatedLab-State fehlt oder ist beschädigt | Framework erkennt den Zustand und verliert Ressourcenhandles nicht still |
| `AL-105` | Provider- oder Remotingfehler | strukturierte Diagnose erreicht Result und Evidence |
| `AL-106` | Cleanup nach Teilfehler | Ergebnis ist `PASS` oder sichtbar `RECOVERY_REQUIRED`, niemals still erfolgreich |

## Phase C - Mehrknotiger Nutzen

Phase C wird nur begonnen, wenn Phase A und B bestanden sind und der einfache
Vertical Slice keinen höheren Wartungsaufwand als der native Pfad zeigt.

| ID | Kriterium | Nachweis |
|---|---|---|
| `AL-201` | Domain Controller und DNS | reproduzierbarer Aufbau mit Framework-Owned Bindings |
| `AL-202` | mehrere SQL-Windows-Knoten | feste Ressourcen und eindeutige Identitäten |
| `AL-203` | WSFC-Grundlage | Clusterzustand ist read-only prüfbar und bereinigbar |
| `AL-204` | AG oder FCI | SQL-zentriertes Szenario erreicht definierte Readiness |
| `AL-205` | Topologie-Cleanup | alle Knoten und Hilfsressourcen werden scopegebunden entfernt |
| `AL-206` | Evidence | SQL-, Cluster- und Providerergebnisse werden normalisiert zurückgegeben |

## Vergleichsmetriken

Für nativen Provider und AutomatedLab-Adapter werden getrennt dokumentiert:

- Umfang neuen providerbezogenen Codes;
- Anzahl eigener Lifecycle- und Recovery-Sonderfälle;
- benötigte externe Module und Versionen;
- Time-to-Ready für Cold Path und Wiederholung;
- Anzahl manueller Schritte und Prompts;
- Verhalten bei Abbruch und Reboot;
- Diagnosequalität;
- Cleanup-Vollständigkeit;
- Offline- und Air-Gap-Tauglichkeit;
- laufender Wartungsaufwand bei Versionsupdates.

Eine schnellere Happy-Path-Demo genügt nicht, wenn State, Recovery, Cleanup
oder Wartung schlechter werden.

## Go-/No-Go-Regeln

`accepted-monorepo` ist nur zulässig, wenn:

- alle Kriterien aus Phase A und B bestanden sind;
- der Adapter relevante Hyper-V-Komplexität nachweislich reduziert;
- kein zweiter kanonischer State entsteht;
- Cleanup und Fremdobjektschutz mindestens dem nativen Provider entsprechen;
- der normale Pfad ohne Slots und ohne externe Downloads funktioniert;
- Diagnose und Recovery nicht hinter dem nativen Pfad zurückbleiben.

`rejected` ist zwingend, wenn:

- Ressourcen außerhalb des Run-Scopes verändert werden;
- Cleanup von nicht rekonstruierbarem Fremd-State abhängt;
- versteckte Prompts oder Downloads nicht sicher unterbunden werden können;
- exakte SQL-Version/CU oder Benutzerartefakte nicht kontrollierbar sind;
- AutomatedLab den führenden Blueprint oder Lifecycle übernehmen müsste;
- der Adapter dauerhaft mehr Doppelimplementierung als Entlastung erzeugt.

`extraction-candidate` wird erst nach `accepted-monorepo` geprüft und benötigt
zusätzlich:

- stabilen versionierten Adaptervertrag;
- sinnvolle Nutzung außerhalb eines einzelnen Core-Workflows;
- abweichenden Release- oder Abhängigkeitszyklus;
- eigenständig ausführbare Tests;
- nachweisbaren Wartungsvorteil durch die Trennung.
