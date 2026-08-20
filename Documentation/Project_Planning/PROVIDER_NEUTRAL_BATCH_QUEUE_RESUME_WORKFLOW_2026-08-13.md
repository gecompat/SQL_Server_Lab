# Providerneutraler Batch-, Queue- und Resume-Workflow

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_WITH_OPEN_RUNTIME_ACCEPTANCE` |
| Stand | 2026-08-20 |
| Priorität | `P0` für Vorgangskern, Resume, User-Gates und verständliche Menüführung |
| Implementierungsstatus | persistenter Kern und Adapter implementiert; reale Provider-/Slot-Abnahme und Restmigration offen |
| Geltung | PowerShell-Konsole, öffentliche Cmdlets, Manifeste, lokale Workflow-Oberfläche und alle Provider |
| Ziel | providerneutrale, mengenfähige und nach Abbruch sicher fortsetzbare Erstellung von SQL- und Windows-Umgebungen |

## 1. Verbindliche Entscheidung

Jede Erstellung wird mengenfähig. Eine einzelne Umgebung ist technisch ein
Batch mit genau einer Position. Derselbe persistente Batch- und Vorgangskern
wird von Konsole, Cmdlets, Manifesten und Browseroberfläche verwendet.

```text
Batch planen
-> eine oder mehrere Positionen erfassen
-> gemeinsame Werte und individuelle Abweichungen prüfen
-> Provider und Abhängigkeiten je Position auflösen
-> gesamten Plan bestätigen
-> Kindvorgänge in die Queue stellen
-> begrenzt parallel verarbeiten
-> User-Gates beobachten und bestätigen lassen
-> unabhängig abschließen oder bereinigen
```

Diese Entscheidung ergänzt den
[Konsolen-, Lifecycle- und Storage-Konsolidierungsplan](CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md),
den [Console-UI-Vertrag](CONSOLE_UI_FRAMEWORK_PLAN.md) und den
[Storage-Vertrag](STORAGE_CONTRACT_PLAN.md). Bei Überschneidungen gilt dieses
Dokument für Batch-, Queue-, Resume- und User-Gate-Verhalten. Bestehende
Sicherheits-, Besitz- und Cleanup-Grenzen bleiben erhalten.

Hyper-V ist nur für providergebundene Infrastruktur ein eigener sichtbarer
Pfad, beispielsweise für OS-Vorlagen, ISO-Medien, Slots und Builder. Das
Erstellen einer Umgebung ist grundsätzlich providerneutral. Eine explizite
Providerwahl bleibt möglich, liegt aber unter `Erweitert` und ist nicht der
Standard.

## 2. Aktueller Ausgangsstand und Wiedereinstieg

Dieses Dokument hält Zielbild und Statusabgleich fest. Code und passende Tests
bleiben der Implementierungsnachweis; die folgende Tabelle ordnet diesen
Nachweis ein.

Stand 2026-08-20 gilt:

| Bereich | Status |
|---|---|
| Vollständige Batch-/Operation-Verträge | `VERIFIED` durch synthetischen lokalen Contract-Test |
| Persistente Queue und Scheduler-Lease | `VERIFIED` durch Resume-, Worker-, Lease- und Fehlerisolationstest |
| User-Gates mit Read-only-Probes | `VERIFIED` für synthetischen Probe-/Bestätigungsvertrag |
| Mengenfähiger Composer | `IMPLEMENTED_UNVERIFIED`; Console-Vertrag statisch geprüft, reale Bulk-Abnahme offen |
| Providerneutrale Erstellung | `IN_PROGRESS`; Docker-/Podman-Bulk sowie Hyper-V-Slot-Bulk, Scheduler-Resume und Cleanup real verifiziert; Prozessabbruch und User-Gates offen |
| Batch-Manifest | `VERIFIED` für Schema und deterministische Expansion |
| Browseradapter für persistente Vorgänge | `IMPLEMENTED_UNVERIFIED`; Queue-Anzeige und persistente Übergabe vorhanden |
| Neue konsolidierte Menüstruktur | `IMPLEMENTED_UNVERIFIED`; zentrale UI-Checks grün, Restmigration bleibt offen |

Der persistente Kern wurde mit PR #68, die providerneutrale
Konsolenkonsolidierung mit PR #70 und die reale Provider-Matrix mit PR #73 nach
`main` übernommen. Die lokalen fokussierten Nachweise vom 2026-08-20 sind:

```powershell
.\Tests\Static\Invoke-BatchWorkflowChecks.ps1
.\Tests\Static\Invoke-ConsoleUiChecks.ps1
.\Tests\Static\Invoke-EnvironmentResourceChecks.ps1
.\Tests\Static\Invoke-ModuleLoadContractChecks.ps1
.\Tests\Static\Invoke-TestEnvironmentChecks.ps1
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider hyperv -ArtifactId '<OS_SEALED-ID>'
```

Die statischen Prüfungen belegen Verträge, persistente Testzustände und
UI-Bindings. Die Runtime-Smokes haben je zwei reale SQL-Server-2025-Umgebungen
für Docker und Podman sowie zwei Windows-Server-2025-Slots aus einem immutable
`OS_SEALED`-Parent für Hyper-V nachgewiesen. Geprüft wurden eindeutige RunIds,
idempotentes Resume, das einzelne `HyperVHeavy`-Limit und vollständiger
scopegebundener Cleanup. Offen bleiben echter Prozessabbruch/Resume,
Manifest-Rerun und das interaktive Windows-User-Gate.

### Verbindlicher Wiedereinstieg für eine spätere Sitzung

1. Dieses Dokument vollständig lesen.
2. `git status`, aktuellen Branch, offene PRs und vorhandene lokale Änderungen erfassen.
3. Bestehenden Code und Tests als Ist-Nachweis behandeln; Plantexte nicht als Implementierungsnachweis verwenden.
4. Bei der ersten noch nicht vollständig abgenommenen Welle fortsetzen; aktuell
   sind dies die reale Providerabnahme in Welle 5 sowie die Restmigrationen aus
   Welle 6 und 7.
5. Nach jeder Welle Status und Abnahmen in Abschnitt 16 aktualisieren.
6. Keine Provider-Sonderlogik direkt in Console- oder Browserdialoge einbauen; alle Adapter müssen den gemeinsamen Vorgangskern verwenden.
7. Reale Slots und Umgebungen nach Tests scopegebunden bereinigen.
8. Erst nach lokaler Konsistenz, grünen Checks und dokumentierter Abnahme PR erstellen beziehungsweise aktualisieren und nach `origin/main` mergen.

## 3. Batch- und Vorgangsmodell

### 3.1 Batch-Vertrag

`SqlServerLab.Batch/1.0` enthält:

- `BatchId`, Name, Priorität und Erstellungszeitpunkt;
- gemeinsame Defaults;
- explizit expandierte Positionen mit stabiler `ItemId`;
- zugeordnete Kindvorgänge;
- gemeinsame Infrastrukturabhängigkeiten;
- zusammengefassten Fortschritt und Fehlerstatus;
- einen scopegebundenen Batch-Cleanup-Plan.

Batch-Zustände:

```text
Draft
Validated
Queued
Running
Waiting
Completed
CompletedWithErrors
CleanupQueued
Cancelled
```

### 3.2 Kindvorgänge

Jede expandierte Position wird ein eigenständiger
`SqlServerLab.Operation/1.0`-Vorgang. Jede Position besitzt:

- eigenen Status und Fortschritt;
- eigene Priorität und Queue-Position;
- eigene, nach Queue-Start unveränderliche Providerentscheidung;
- eigene Schritte, Receipts und User-Gates;
- eigene Wiederaufnahmeinformation;
- eigenen Cleanup-Scope.

Ein Fehler stoppt nur die betroffene Position. Nicht betroffene Positionen und
unabhängige Batches laufen weiter. Ein gemischtes Batchergebnis endet als
`CompletedWithErrors`.

### 3.3 Gemeinsame Abhängigkeiten

Gleiche Voraussetzungen werden nicht mehrfach erzeugt:

- Benötigen fünf Slots dieselbe fehlende OS-Vorlage, entsteht genau ein Vorlagenvorgang.
- Alle fünf Slotvorgänge warten auf diese gemeinsame Abhängigkeit.
- Nach Veröffentlichung werden die Slotvorgänge automatisch freigegeben.
- Schlägt die Abhängigkeit fehl, bleiben nur ihre abhängigen Positionen blockiert.
- Bei endgültigem Abbruch zeigt das System alle betroffenen Positionen an.

Bestehende Vorlagen und Slots werden bevorzugt wiederverwendet, wenn ihre
Eigenschaften vollständig passen. Auswahl und Begründung werden im persistenten
Batchplan festgehalten.

## 4. Mengenfähiger Planungsdialog

Ein gemeinsamer Composer wird für Umgebungen, Slots, Vorlagen und Testmatrizen
verwendet. Er unterstützt:

- Position hinzufügen;
- Position duplizieren;
- Anzahl identischer Positionen festlegen;
- eine oder mehrere Positionen auswählen;
- gemeinsame Eigenschaften auf ausgewählte Positionen anwenden;
- einzelne Positionen abweichend konfigurieren;
- Positionen entfernen oder umsortieren;
- eine Testmatrix aus Betriebssystem, SQL-Version, CU und Plattform erzeugen;
- Batch speichern, verwerfen oder zur Review wechseln.

Gemeinsame Defaults können Betriebssystem, SQL-Version, Edition, Patchstand,
CPU, RAM, Autostart, Netzwerk, Isolation, Storage-Layout, Priorität und
Providerpräferenz enthalten. `ProviderPreference = Auto` ist der Standard.

Individuelle Überschreibungen bleiben pro Position sichtbar. Jeder Wert wird
als `gemeinsam` oder `abweichend` gekennzeichnet.

```text
Batch: Schulungs-Slots

[1] Windows 2025 Desktop | 4 CPU | 8 GB | 3 Stück
[2] Windows 2025 Core    | 4 CPU | 4 GB | 2 Stück
[3] SQL 2022 Developer   | Auto-Provider | 1 Stück
[4] SQL 2025 Developer   | Auto-Provider | 1 Stück
```

Vor dem Queue-Start wird eine Mengenangabe in stabile Kindpositionen
expandiert. Namen und IDs entstehen deterministisch mit laufender Nummer.

## 5. Batch-Review und Preflight

Vor jeder Mutation zeigt die Review:

- alle expandierten Positionen;
- Providerentscheidung und Begründung je Position;
- wiederverwendete Slots oder Vorlagen;
- neu zu erzeugende gemeinsame Abhängigkeiten;
- erwartete automatische Schritte;
- mögliche Benutzeraktionen;
- geschätzten CPU-, RAM- und Speicherbedarf;
- aktuelle Slot- und Vorlagenkapazität;
- Parallelitäts- und Lock-Einschränkungen;
- Cleanup-Auswirkung.

Folgende Konflikte blockieren:

- doppelte Namen oder IDs;
- nicht erfüllbare Provideranforderungen;
- fehlende oder unklare Storage-Ziele;
- nicht auflösbare Portkonflikte;
- überschrittene Vorlagenpool-Kapazität;
- unzureichender dauerhafter Speicher;
- unvereinbare OS-, SQL- oder Medienkombinationen.

Warnungen blockieren nicht automatisch, müssen aber sichtbar bestätigt werden.
Kein Kindvorgang startet, bevor der gesamte Batch persistent und als `Queued`
markiert wurde. Ein Abbruch während der Übergabe darf keinen halben,
unsichtbaren Batch hinterlassen.

## 6. Providerneutralität

Der normale Erstellungscomposer bietet:

- SQL-Umgebung;
- reine Windows-Umgebung;
- eine oder mehrere Positionen.

Docker, Podman oder Hyper-V können nur unter `Erweitert` explizit gewählt
werden. Je Position gelten folgende Regeln:

- SQL unter Linux wird bevorzugt über Docker oder Podman bereitgestellt.
- Windows-Anforderungen lösen Hyper-V aus.
- Windows-SQL, spezielle Editionen, Isolation, VHDX oder physische Storage-Platzierung können Hyper-V erzwingen.
- Eine explizit unpassende Providerwahl wird mit nachvollziehbaren Gründen blockiert.
- Nach dem Queue-Start wird der gewählte Provider nicht stillschweigend gewechselt.

Hyper-V bleibt ein eigener Menübereich für:

- OS-Vorlagen;
- SQL-Prepared-Vorlagen;
- ISO-Erkennung und Download;
- Slot-Pool;
- Bulk-Slot-Bereitstellung;
- Builder, Recovery und Infrastruktur-Cleanup.

## 7. Scheduler, Parallelität und Locks

Standardregeln:

- maximal zwei automatische Kindvorgänge gleichzeitig;
- maximal ein schwerer Hyper-V-Build oder Provisioning-Lauf gleichzeitig;
- unabhängige leichte Container- oder Lifecycle-Aktionen dürfen daneben laufen;
- `WaitingForUser`, `Paused` und `WaitingForDependency` belegen keinen Worker;
- Mutationen derselben Umgebung oder desselben Slots sind exklusiv;
- Storage-Migrationen und Katalogänderungen erhalten eigene exklusive Locks;
- pro `StateRoot` existiert genau eine aktive Scheduler-Lease.

| Ressourcenklasse | Beispiele | Parallelität |
|---|---|---:|
| `HyperVHeavy` | OS-Build, SQL-Image-Build, Slot-Provisioning | maximal 1 |
| `RuntimeNormal` | Container erstellen, SQL konfigurieren | innerhalb Gesamtlimit |
| `LifecycleLight` | Start, Stopp, Name, CPU/RAM | innerhalb Gesamtlimit |
| `ProbeReadOnly` | User-Gate beobachten | separater Probe-Slot |
| `ExclusiveStorage` | Storage-Migration | exklusiv |

Laufende atomare Schritte werden durch eine neue Priorität nicht gewaltsam
unterbrochen. Eine neue Reihenfolge gilt für noch nicht gestartete oder wieder
freigegebene Schritte.

## 8. Priorisierung und Umreihung

Prioritäten sind `High`, `Normal` und `Low`. Innerhalb einer Priorität gilt die
sichtbare Reihenfolge.

Der Benutzer kann:

- einen vollständigen Batch priorisieren;
- einzelne Kindvorgänge abweichend priorisieren;
- wartende Positionen nach oben oder unten verschieben;
- Positionen pausieren und wieder freigeben;
- einen Kindvorgang stoppen und aufräumen;
- einen gesamten Batch stoppen und aufräumen.

Eine Änderung der Batchpriorität wird auf alle noch nicht individuell
überschriebenen Kindvorgänge übertragen.

Bei ausgelasteter Parallelität zeigt die Queue laufende Vorgänge, belegte
Ressourcenklassen und Locks, den nächsten startbaren Vorgang, blockierte
Vorgänge samt Grund und alle umreihbaren Positionen.

## 9. Beobachtete Benutzeraktionen

Ein User-Gate zeigt bei jedem Öffnen erneut:

- betroffene VM oder Ressource;
- Grund der manuellen Tätigkeit;
- vollständige Arbeitsschritte;
- erwartetes Ergebnis;
- technische Verifikation.

Verfügbare Aktionen:

```text
Erledigt - prüfen und fortsetzen
Später fortsetzen
Priorität ändern
Ton für diesen Vorgang ausschalten
Ruhemodus
Vorgang endgültig stoppen und aufräumen
VM-Konsole öffnen, falls passend
```

Das System wartet immer auf die ausdrückliche Bestätigung des Benutzers. Bei
`Später fortsetzen`, einem Prozessabbruch oder einem harten Hostabbruch bleibt
das Gate persistent. Beim nächsten Öffnen werden alle erforderlichen Schritte
erneut vollständig angezeigt.

### 9.1 Read-only-Probes

Während des Wartens prüft das System adaptiv und ausschließlich lesend:

- VM-Zustand;
- Neustart oder Shutdown;
- PowerShell-Direct-Verfügbarkeit;
- OOBE-, Setup- und Sysprep-Receipts;
- erwartete Dienste und Registry-Zustände;
- erkennbare Installationsfortschritte.

Rhythmus:

```text
anfangs ungefähr alle 30 Sekunden
später alle zwei bis fünf Minuten
nach einer Änderung kurzfristig wieder häufiger
bei Prüffehlern wachsender Backoff
global höchstens ein Probe gleichzeitig
```

Erkennt das System das Ziel vermutlich als erreicht, bleibt der Vorgang
`WaitingForUser` und wird als `CandidateSatisfied` hervorgehoben. Ohne
ausdrückliches Okay läuft nichts weiter.

### 9.2 Akustischer Hinweis

Bei `CandidateSatisfied` gilt folgender Backoff:

```text
5 s -> 15 s -> 30 s -> 1 min -> 2 min -> 5 min -> höchstens alle 10 min
```

Der Benutzer kann einen einzelnen Vorgang stummschalten oder global eine
Stunde, acht Stunden beziehungsweise bis zur manuellen Aufhebung Ruhemodus
aktivieren. Visuelle Hinweise und Ereignislog bleiben aktiv.

### 9.3 Bulk-Bestätigung

Die Queue zeigt alle vermutlich erledigten User-Gates eines Batches in einer
Mehrfachauswahl. Mit `Ausgewählte prüfen und fortsetzen` wird jeder gewählte
Slot einzeln technisch verifiziert.

- Bestandene Positionen werden wieder eingereiht.
- Nicht bestandene Positionen bleiben mit konkretem Fehler im User-Gate.
- Nicht ausgewählte Positionen bleiben unverändert.
- Ein Fehler verhindert nicht die Fortsetzung anderer ausgewählter Positionen.

## 10. Abbruch und Cleanup

Jeder Kindvorgang besitzt jederzeit die Aktion
`Vorgang endgültig stoppen und aufräumen`.

Der Ablauf:

1. keinen neuen Mutationsschritt starten;
2. einen laufenden atomaren Schritt bis zu einer sicheren Grenze beenden;
3. tatsächlichen Zustand erneut erfassen;
4. ausschließlich den scopegebundenen Cleanup-Plan ausführen;
5. Cleanup-Ergebnis und verbleibende Ressourcen anzeigen.

| Batchaktion | Wirkung |
|---|---|
| `Unfertige Positionen stoppen` | Stoppt und bereinigt nur noch nicht abgeschlossene Kindvorgänge |
| `Gesamten Batch zurückbauen` | Bereinigt ausdrücklich auch bereits durch diesen Batch fertiggestellte Umgebungen |

Der vollständige Rückbau benötigt eine zweite Review, die jede zu entfernende
Umgebung auflistet. Gemeinsame veröffentlichte Vorlagen, Medienbibliotheken und
geschützte persistente Daten werden nie implizit entfernt. Eine ausschließlich
für den Batch erzeugte, noch nicht veröffentlichte Abhängigkeit darf erst
bereinigt werden, wenn kein anderer Vorgang sie verwendet.

## 11. Menüstruktur

| Menüpunkt | Bedeutung |
|---|---|
| `1 Umgebungen planen und erstellen` | Eine oder mehrere SQL-/Windows-Umgebungen providerneutral planen |
| `2 Vorgänge, Queue und Benutzeraktionen` | Batches, Kindvorgänge, Priorität, Fortschritt und User-Gates |
| `3 Umgebungen verwalten` | Status, Start, Stopp, Neustart, Name, CPU, RAM und Entfernen |
| `4 Hyper-V-Infrastruktur` | Vorlagen, ISOs, Slots, Bulk-Bereitstellung, Builds und Recovery |
| `5 Medien, Testdaten und Speicher` | Lab_Base, Lab_Data, Testdatenbibliothek und Storage |
| `6 Datenbanken und Verbindungen` | Samples, Restore, Skripte, Endpunkte, SSMS und CMS |
| `7 Systemstatus und Einstellungen` | Provider, Scheduler, Parallelität, Ton, Ruhemodus und Audit |
| `0 Beenden` | Host kontrolliert beenden; Vorgänge später fortsetzen |

Die Kopfzeile zeigt Modulversion, Build-/Commit-Kennung, Modulpfad,
Console-Modus, laufende Worker, wartende User-Gates und Queue-Länge.

Alle bekannten Auswahllisten verwenden Cursor, `Enter`, `Escape`, `F5` und
sichtbare Shortcuts. Freie Texte, Zahlen, Pfade und Passwörter bleiben
Eingabefelder. Unteraktionen kehren in ihr Untermenü zurück. Globale
`[Enter] für Menü ...`-Pausen entfallen.

## 12. Öffentliche Verträge

Neue additive Schnittstellen:

```powershell
New-SqlServerLabBatch
Get-SqlServerLabBatch
Get-SqlServerLabQueue
Get-SqlServerLabOperation
Confirm-SqlServerLabOperationUserAction
Move-SqlServerLabOperation
Set-SqlServerLabOperationPriority
Suspend-SqlServerLabOperation
Resume-SqlServerLabOperation
Stop-SqlServerLabOperation -Cleanup
Stop-SqlServerLabBatch -Cleanup
```

Bestehende öffentliche Cmdlets und Action-Namen bleiben kompatibel. Eine
direkte Einzelaktion wird intern als Batch mit einer Kindposition behandelt,
ohne ihr bisheriges synchrones Rückgabeformat unnötig zu brechen.

Mutierende Lifecycle-Aktionen liefern intern
`SqlServerLab.ActionResult/1.0` mit:

- `Changed`;
- `NoChange`;
- `Cancelled`;
- `Failed`;
- `ConnectionCenterImpact`.

CMS und Connection Center werden nur bei einer erfolgreichen relevanten
Mutation genau einmal synchronisiert.

## 13. Manifest-Unterstützung

Bestehende Einzelmanifeste bleiben unverändert gültig. Zusätzlich entsteht
`SqlServerLab.BatchManifest/1.0`:

```text
name
priority
defaults
items[]
  id
  kind
  count
  intent oder manifest
  optionale Overrides
```

`count` wird vor der Ausführung in stabile Einzelpositionen expandiert. Der
erzeugte Lock enthält ausschließlich explizite Positionen und aufgelöste
Provider- sowie Artifact-IDs.

Manifestläufe:

- arbeiten ohne interaktive Installationsdialoge;
- verwenden denselben Batch- und Scheduler-Kern;
- setzen eindeutige offene Vorgänge fort;
- liefern Batch- und Operation-IDs zurück;
- bleiben bei erforderlichen User-Gates fail-closed;
- hinterlassen einen sichtbaren resumierbaren Vorgang.

## 14. Umsetzungswellen

### Welle 1: Persistenter Vorgangs- und Batch-Kern

Batch-, Operation-, Step-, Event-, Lock-, User-Gate- und Cleanup-Verträge.

### Welle 2: Scheduler und Ressourcensteuerung

Zwei Worker, Hyper-V-Limit, Leases, Prioritäten, Umreihung, Abhängigkeiten und
unabhängige Fehlerbehandlung.

### Welle 3: Mengenfähiger Konsolencomposer

Warenkorb, Anzahl, Duplizieren, Mehrfachauswahl, Bulk-Edit, Matrix und
Gesamt-Review.

### Welle 4: User-Gates und Benachrichtigungen

Read-only-Probes, Mehrfachbestätigung, Fortschritt, Ton-Backoff und Ruhemodi.

### Welle 5: Providerneutrale Erstellung und Slot-Bulk

SQL-/Windows-Batches, Providerauflösung, gemeinsame Vorlagenabhängigkeiten und
Slot-Pool.

### Welle 6: Vollständige Menükonsolidierung

Storage, CMS, Connection Center und Hyper-V-Auswahllisten auf Cursor/Fallback
umstellen.

### Welle 7: Browser- und Manifestadapter

Flüchtige Browserjobs ersetzen, Batch-Manifest ergänzen und dieselben
Operationen anzeigen.

### Welle 8: Reale Abnahme und Veröffentlichung

Lokale Tests mit verfügbaren Slots, Cleanup, PR, grüne GitHub-Checks und Merge
nach `origin/main`.

## 15. Test- und Abnahmeszenarien

- Eine einzelne Umgebung wird als Batch mit einer Position ausgeführt.
- Drei gleiche Slots werden korrekt in drei Kindvorgänge expandiert.
- Verschiedene Slotvarianten können gemeinsam geplant und editiert werden.
- Ein fehlendes gemeinsames OS-Image erzeugt nur einen Vorlagenvorgang.
- Slot 1 erreicht OOBE und gibt den Worker frei; Slot 2 startet anschließend.
- Mehrere Slots dürfen gleichzeitig auf Benutzeraktionen warten.
- Der Benutzer bestätigt mehrere erledigte Slots per Mehrfachauswahl.
- Jeder ausgewählte Slot wird unabhängig verifiziert.
- Ein fehlerhafter Slot stoppt keine anderen Positionen.
- Ein Kindvorgang kann separat priorisiert, pausiert oder bereinigt werden.
- Ein vollständiger Batch kann einschließlich bereits fertiger Batchumgebungen kontrolliert zurückgebaut werden.
- Zwei Worker und das einzelne Hyper-V-Heavy-Limit werden eingehalten.
- Queue-Umreihung verändert keine bereits laufende atomare Aktion.
- Prozessabbruch erzeugt keine doppelten VMs, Container oder Images.
- User-Gate-Probes verändern keine Runtime.
- Ohne Benutzerbestätigung setzt `CandidateSatisfied` nichts fort.
- Ton, Backoff, Mute und Ruhemodus funktionieren ohne Workflowmutation.
- Manifest-Reruns setzen eindeutige offene Batches fort.
- `Escape`, `NoChange` und Ablehnung lösen keine CMS-Synchronisation aus.
- Reale Tests geben temporäre Slots und Umgebungen wieder frei.

## 16. Umsetzungsstatus

Dieser Abschnitt ist bei jeder Implementierungswelle zu aktualisieren.

| Welle | Status | Nachweis | Offene Abnahme |
|---|---|---|---|
| 1 Persistenter Kern | `VERIFIED` | `Invoke-BatchWorkflowChecks.ps1`: Vertrag, Expansion, Persistenz | reale Provider-Receipts bleiben Teil von Welle 5 |
| 2 Scheduler | `VERIFIED` | zwei Worker, ein `HyperVHeavy`, Resume und Fehlerisolation synthetisch grün | Prozess-/Providerabbruch mit realen Ressourcen |
| 3 Console Composer | `IMPLEMENTED_UNVERIFIED` | Composer und Queue-Menü vorhanden; Console-UI-Checks grün | reale Bulk-Erfassung und Abbruchpfade |
| 4 User-Gates | `VERIFIED` | Probe, `CandidateSatisfied` und Bestätigung synthetisch grün | reale Hyper-V-Windows-Gates und Credential-Verifikation |
| 5 Providerneutrale Erstellung | `IN_PROGRESS` | Docker und Podman: je zwei SQL-2025-Runs; Hyper-V: zwei Windows-2025-Slots seriell; Resume und Cleanup mit `Invoke-BatchWorkflowSmokeTest.ps1` verifiziert | echter Prozessabbruch, Manifest-Rerun und fehlende Shared-Artifact-Abhängigkeit |
| 6 Menükonsolidierung | `IMPLEMENTED_UNVERIFIED` | providerneutrale Arbeitsbereiche und 54 Console-UI-Checks | `CUI-012` bis `CUI-019` und manuelle Navigation |
| 7 Browser und Manifest | `IMPLEMENTED_UNVERIFIED` | Batchschema, persistente Browserübergabe und Queue-Ansicht vorhanden | Browser-End-to-End, Manifest-Rerun und Cleanup |
| 8 Abnahme und Veröffentlichung | `IN_PROGRESS` | PR #68/#70/#73 gemergt; statische und GitHub-Gates sowie Docker-/Podman-/Hyper-V-Batch-Cleanup grün | Prozessabbruch, Manifest-Rerun, User-Gate und übrige manuelle Abnahme |

Statuswerte dürfen nur mit konkretem Nachweis geändert werden:

```text
PLANNED
IN_PROGRESS
IMPLEMENTED_UNVERIFIED
VERIFIED
BLOCKED
```

## 17. Festgelegte Defaults

- Mengenfähige Planung gilt für alle Erstellungspfade.
- Eine Einzelumgebung ist ein Batch mit einer Position.
- Fehlerhafte Positionen beeinflussen unabhängige Positionen nicht.
- User-Gates können per Mehrfachauswahl bestätigt werden, werden aber einzeln verifiziert.
- Providerwahl ist standardmäßig automatisch.
- Parallelität beträgt zwei Worker, davon höchstens ein schwerer Hyper-V-Vorgang.
- User-Gates und Probes belegen keinen normalen Worker.
- Nach erfolgreicher Bestätigung und Verifikation läuft der Kindvorgang automatisch weiter.
- Hintergrundarbeit läuft, solange ein Scheduler-Host aktiv ist, und wird nach einem Neustart sicher fortgesetzt.
- Menüführung darf neu strukturiert werden; öffentliche CLI- und Einzelmanifestverträge bleiben kompatibel.

## 18. Nicht verhandelbare Sicherheits- und Konsistenzregeln

1. Kein automatischer Folgeschritt nach einem User-Gate ohne ausdrückliche Benutzerbestätigung.
2. Probes sind ausschließlich lesend und verwenden keine versteckte Runtime-Mutation.
3. Persistierter Zustand wird vor sichtbarer Queue-Freigabe atomar geschrieben.
4. Provider, Artifact-IDs und Cleanup-Scope werden nach Queue-Start nicht stillschweigend geändert.
5. Cleanup entfernt nur nachweislich scopegebundene Ressourcen.
6. Gemeinsame veröffentlichte Artefakte und geschützte persistente Daten werden nie implizit gelöscht.
7. Secrets werden nicht in Batch-, Operation-, Event- oder Review-Artefakten persistiert.
8. Ein Prozessabbruch darf keine doppelte Provisionierung verursachen.
9. Navigation, Review, Ablehnung und `NoChange` lösen keine CMS- oder Connection-Center-Synchronisation aus.
10. Ein Plantext, Schema oder grüner statischer Test ersetzt keinen realen Provider- und Cleanup-Nachweis.
