# Hyper-V-Ressourcen verbindlich in `Lab_Data` ablegen – P0-Bugfix-Backlog

## Status und Priorität

| Merkmal | Wert |
|---|---|
| Status | `CONFIRMED_BUG / BACKLOG` |
| Priorität | `P0` – vor regulärem Feature-Ausbau und vor Fortsetzung des realen N5-Hyper-V-Storage-Nachweises |
| Betroffen | reguläre Hyper-V-Slots, Windows-/SQL-Image-Builder, VM-Konfiguration, Smart Paging, Checkpoints und Hyper-V-Image-Store |
| Nicht betroffen | unveränderliche Quellmedien im `Lab_Base`; selectorgebundene SQL-Storage-Lanes behalten ihre explizite Location |

Die Priorität ist höher als bei einem gewöhnlichen Feature-Backlog. Reale,
beschreibbare Slot-VHDX wurden unter dem Legacy-State-Root
`%LOCALAPPDATA%\SqlServerLab` beobachtet, obwohl ein verwalteter `Lab_Data`-
Root konfiguriert war. Dadurch kann das Systemvolume unerwartet um viele
Gigabyte wachsen. Das Verhalten verletzt die erwartete physische
Storage-Grenze, ohne vor der Hyper-V-Mutation sichtbar oder blockierend zu
werden.

Es liegt derzeit kein Nachweis für Datenkorruption vor. Der Fehler ist dennoch
P0, weil neue Builds und Slots den falschen Datenträger weiter belegen können
und ein nachträgliches manuelles Verschieben gebundener VHDX-, VM- oder
Checkpoint-Dateien unsicher ist.

## Bestätigte Ursache

Der aktuelle Vertrag koppelt physische Hyper-V-Ressourcen an den allgemeinen
`StateRoot`:

1. ein Run-Verzeichnis entsteht unter `<StateRoot>/runs/<RunId>`;
2. der Hyper-V-Provider erzeugt Child- und run-lokale Zusatz-VHDX unter dem
   Run-Verzeichnis;
3. `New-VM -Path` verwendet denselben Ressourcenpfad, wodurch auch
   Konfiguration, Smart Paging und Checkpoints davon abhängen;
4. Image-Builder und Image-Registry leiten Build-, Staging- und Artifact-Pfade
   ebenfalls aus dem `StateRoot` ab;
5. die Windows-Root-Auflösung kann bei explizitem Override, fehlender
   Data-Root-Sichtbarkeit oder vorhandenem Legacy-Run weiterhin
   `%LOCALAPPDATA%\SqlServerLab` wählen.

Der Legacy-Fallback ist dabei klebrig: Ein alter Run kann die Root-Auswahl für
neue Runs auf dem Benutzerprofil halten, obwohl inzwischen ein gültiger
verwalteter `Lab_Data`-Root existiert. Ein Prozess- oder UAC-Grenzwechsel kann
zusätzlich dazu führen, dass nur prozesslokale Root-Informationen nicht mehr
verfügbar sind.

## Verbindliches Zielbild

State, Discovery und physische Ressourcen erhalten getrennte, aber gebundene
Verantwortlichkeiten:

- `StateRoot` enthält kleine Steuerungsdaten, Journale, Receipts und Secrets;
- `HyperVResourceRoot` liegt ausnahmslos unter einem registrierten,
  controller-eigenen `Lab_Data`-Root;
- neue Slot-VHDX, VM-Konfiguration, Smart Paging, Checkpoints, Builder-VHDX,
  Flattening-/Staging-Dateien und veröffentlichte Hyper-V-Images werden aus dem
  `HyperVResourceRoot` abgeleitet;
- selectorgebundene SQL-Data-, Log-, TempDB- und Backup-VHDX verbleiben auf den
  im Storage-Intent aufgelösten registrierten Locations und werden nicht
  unbemerkt auf den Default-Root zurückgezogen;
- `Lab_Base` bleibt der unveränderliche Medienroot und wird nicht zum
  beschreibbaren Runtime-Root;
- ein frei gewählter `-StateRoot` darf die physische Ressourcenplatzierung
  weder direkt noch indirekt ändern.

Der Root-Resolver liefert vor jeder Mutation eine normalisierte Bindung aus
`ControllerId`, `LocationId`, kanonischem `LabDataRoot`, kurzem
`HyperVResourceRoot` und zulässigen Ressourcenklassen. Der erhöhte Worker prüft
diese Bindung erneut gegen Marker, Volume-Identität und Registry. Er übernimmt
nicht still eine abweichende Prozessumgebung.

## Sofortschutz – erster Vertical Slice

Der erste Slice verhindert neue Fehlplatzierungen, bevor die vollständige
Migration implementiert ist:

1. jeder neue Hyper-V-Slot und Image-Build benötigt eine aufgelöste,
   registrierte `Lab_Data`-Ressourcenbindung;
2. Pfade außerhalb der erlaubten Roots blockieren vor `New-VHD`, `New-VM`,
   `Convert-VHD`, Checkpoint- oder Artifact-Mutation mit einem stabilen
   Fehlercode;
3. Preview und User-Gate zeigen Data Root, Location, erwartete Ressourcenklassen
   und freien Speicher vor UAC an;
4. der erhöhte Prozess erhält die aufgelöste Bindung explizit und validiert sie
   erneut;
5. Start, Stop, Readiness, Export und scopegebundener Cleanup vorhandener
   Legacy-Labs bleiben möglich; neue Ressourcen oder Rebuilds im Legacy-Root
   bleiben blockiert;
6. der reale N5-Hyper-V-Storage-Runner startet erst wieder, wenn dieser Schutz
   nachgewiesen ist.

## Kurze, Hyper-V-taugliche Pfade

Der Root-Vertrag darf nicht erneut an Hyper-V-Pfadlängen scheitern. Für
Konfiguration, Smart Paging und Builder werden kurze, deterministische Pfade
unterhalb von `Lab_Data` verwendet, beispielsweise:

```text
<LabDataRoot>/HyperV/Runs/<ShortRunKey>/
<LabDataRoot>/HyperV/Builds/<ShortBuildKey>/
<LabDataRoot>/HyperV/Images/<ArtifactKey>/
```

Der portable State speichert Keys und Location-Bindungen statt frei
zusammengesetzter Hostpfade. Vor der Mutation werden normalisierte Gesamtlänge,
Parent-Grenze, Reparse-Points und Volume-Identität geprüft. Verkürzung darf
keine Kollision oder unauflösbare Cleanup-Identität erzeugen.

## Legacy-Erkennung und Migration

Bestehende Labs dürfen weder vergessen noch automatisch verschoben werden.
Die Root-Auflösung unterscheidet deshalb künftig:

- **Create Root:** ausschließlich registriertes `Lab_Data` für neue
  Ressourcen;
- **Discovery Roots:** registrierte Roots plus read-only erkannte Legacy-Roots;
- **Mutation Root:** der im Run-/Artifact-Receipt gebundene Root, bis eine
  Migration erfolgreich abgeschlossen ist.

Eine Migration benötigt einen eigenen read-only Plan und einen journalisierten
Apply-/Resume-/Rollback-Ablauf:

1. Run, VM, VHDX-Kette, Checkpoints, Artifacts, Cleanup-Plan, Notes und
   Eigentumsmarker vollständig inventarisieren;
2. Ziel-Location, freien Speicher, Pfadlänge, Volume und Fremdbelegung prüfen;
3. VM kontrolliert stoppen; offene Merge-, Mount- oder Checkpoint-Zustände
   blockieren;
4. Dateien zunächst kopieren, Größe und SHA-256 beziehungsweise passende
   Hyper-V-Integrität prüfen und erst danach VM-/Disk-Bindungen umschalten;
5. `ConfigurationLocation`, `SmartPagingFilePath`,
   `SnapshotFileLocation`, angehängte VHDX, Run-State, Cleanup, Notes und
   Artifact-Registry konsistent aktualisieren;
6. VM starten und Windows-/SQL-Readiness sowie Restart-Persistenz prüfen;
7. Quelle erst nach erfolgreichem Commit und referenzsicherer Prüfung
   entfernen; bei Fehlern Ziel kompensieren oder `RECOVERY_REQUIRED` mit
   fortsetzbarem Journal hinterlassen.

Eine manuelle Explorer-, `Move-Item`- oder unjournalisierte Hyper-V-Verschiebung
ist kein unterstützter Migrationsweg.

## Arbeitspakete

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `HVR-001` | Root-Auflösung in Create-, Discovery- und Mutation-Root trennen | Legacy-Runs bleiben bedienbar, neue Ressourcen landen ausschließlich in registriertem `Lab_Data` |
| `HVR-002` | versionierte `HyperVResourceBinding` mit Controller-, Location-, Volume- und Root-Identität einführen | portable, vor UAC sichtbare und danach erneut prüfbare Bindung |
| `HVR-003` | alle Hyper-V-Mutationsstellen auf den Ressourcenroot umstellen | Slot-, Builder-, Config-, Paging-, Checkpoint-, Staging- und Artifact-Pfade besitzen dieselbe Schutzgrenze |
| `HVR-004` | fail-closed Preflight und Path-/Reparse-/Length-Postconditions ergänzen | keine Provider-Mutation außerhalb freigegebener Roots |
| `HVR-005` | Legacy-Inventar und journalisierte Migration implementieren | sichere Übernahme vorhandener Slots und Images ohne manuelles Verschieben |
| `HVR-006` | Cleanup, Repair, Reconcile und Storage-Migration an neue Pfadbindungen koppeln | keine verwaisten Dateien oder ungeschützten Fremdobjekte |
| `HVR-007` | UI, CLI, Preview, UAC-Handoff und Dokumentation angleichen | physischer Zielroot ist vor der Bestätigung sichtbar und reproduzierbar |
| `HVR-008` | statische, synthetische und reale Hyper-V-Akzeptanz erweitern | belegte Platzierung, Migration, Restart, Recovery und Cleanup |

## Abnahmekriterien

- Ein gültiger Default-Data-Root und vorhandene Legacy-Runs führen bei einem
  neuen Slot immer zu einer Create-Bindung unter `Lab_Data`; Legacy-Discovery
  bleibt erhalten.
- Fehlender, nicht registrierter, fremder oder nicht beschreibbarer
  Ressourcenroot blockiert vor der ersten Hyper-V-Mutation.
- In einer real erhöhten Hyper-V-Abnahme liegen VM-Konfiguration,
  `SmartPagingFilePath`, `SnapshotFileLocation`, OS-/Child-VHDX und
  buildlokale Dateien innerhalb der jeweils erlaubten registrierten Roots.
- Selector-VHDX für SQL Data, Log, TempDB und Backup liegen exakt auf ihren
  gebundenen Locations; der Default-Systemroot ersetzt diese Bindungen nicht.
- Ein UAC-/Prozesswechsel ändert die geplante Location nicht. Abweichende
  Marker-, Controller-, Volume- oder Root-Evidence blockiert fail-closed.
- Ein realer Legacy-Slot kann geplant, gestoppt, journalisiert migriert,
  gestartet und einschließlich SQL-Readiness sowie vollständigem Restart
  verifiziert werden.
- Prozessabbruch in jeder Migrationsphase ist idempotent fortsetzbar oder
  hinterlässt einen eindeutigen, sicheren Recovery-Pfad.
- Cleanup entfernt ausschließlich run-eigene Ressourcen am gebundenen Root;
  Parent-Images, fremde Dateien und registrierte Shared Artifacts bleiben
  unverändert.
- Statische Checks erfassen jede Verwendung von `New-VM`, `New-VHD`,
  `Convert-VHD`, Checkpoint- und Hyper-V-Artifact-Mutation ohne aufgelöste
  Ressourcenbindung.
- Der reale N5-Hyper-V-Mehrgeräte-Nachweis läuft erst danach grün und erzeugt
  keine neue Datei unter `%LOCALAPPDATA%\SqlServerLab`.

## Nicht Teil dieses Bugfixes

- freies Verschieben laufender VMs zwischen beliebigen Hostpfaden;
- Remote-Hyper-V-Host oder Cluster-Live-Migration;
- allgemeines Storage-Tiering oder automatische Kosten-/Performanceoptimierung;
- Änderung der bewusst getrennten `Lab_Base`-Medienstruktur;
- automatische Migration ohne Preview, Stop-, Integritäts-, Recovery- und
  Cleanup-Vertrag.
