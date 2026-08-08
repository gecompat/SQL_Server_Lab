# Zukunftsplan: Menüführung für bestehende Umgebungen (Hyper-V + Container)

| Merkmal | Wert |
|---|---|
| Projekt | `gecompat/SQL_Server_Lab` |
| Bereich | Menüführung, Reconcile-Intent, Zukunfts-Scope |
| Status | `PLANNING_DRAFT` |
| Stand | 2026-08-08 |
| Priorität | Mittel bis hoch – Bedienbarkeit und Nachrüstbarkeit |
| Geltung | Zukunftsplanung für CLI- und UI-Oberfläche (nicht Runtime-Nachweis) |

## 1) Abgleich mit bestehenden Plänen

Es existieren bereits verwandte Planungsdokumente:

- [SQL_Server_Lab_HyperV_Workflow_2026-08-08_1108Z_Zero_Touch_Plan.md](../../private_Note/SQL_Server_Lab_HyperV_Workflow_2026-08-08_1108Z_Zero_Touch_Plan.md): Schwerpunkt Zero-Touch-Pipeline und Zero-Touch-First-Flow.
- [MASTER_IMPLEMENTATION_PLAN.md](MASTER_IMPLEMENTATION_PLAN.md): Gesamtumsetzung mit Wellen und Welle 8 (Reconcile/Manifest).
- [HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md): Contract-Entscheidungen, insbesondere Änderungsklassen (`live`, `restart`, `recreate`, `reprovision`), Netzwerk-, Drive- und Reconcile-Regeln.

Aus diesen Plänen wird für die Menüführung abgeleitet:

1. Reconcile steht nicht neben der Runtime, sondern als zentrale Interaktionsstufe.
2. Hyper-V darf provider-spezifisch erweitert werden, ohne Docker/Podman zu blockieren.
3. Spezialkonfigurationen (z. B. Host-Folder-Mount) gehören in einen Advanced-Pfad.
4. Menütexte müssen die tatsächlichen Auswirkungspfade (Downtime, Klassifizierung) transparent machen.

## 2) Leitprinzipien für die Zukunftsmenüführung

### 2.1. Verhalten nach Provider

- **Container-Provider**: Fokus auf Container-Resource- und Volume-Lebenszyklus.
- **Hyper-V**: zusätzlicher Infrastrukturblock für `CPU/RAM`, `VM-Netz`, `Drives`, `Persistenz`.

### 2.2. Zwei Moduspfade in einem Menü

- **Schnellpfad**: „Was soll passieren?“ – wenige Schlüsselschritte, sichere Defaults.
- **Infrastrukturpfad**: „Was ändert sich bei laufender Umgebung?“ – explizite Änderungsart und Risikoanzeige.

### 2.3. Spezialkonfigurationen klar trennen

- Host-Folder-Mounts sind **immer Spezialkonfiguration**, nicht Basispfad.
- Spezialfunktionen erscheinen in einem dedizierten, deutlich markierten Unterpunkt.

## 3) Ist-Analyse der aktuellen Menüs (Ausgangssituation)

## 3.1 Aktuelle CLI-Main-Menu-Interaktion

`Public/Invoke-SqlServerLab.ps1` bietet heute:
- Neue Umgebung erstellen
- globales `Status`/`Start`/`Stop`/`Restart`/`Remove`/`Clear`
- Datenbank anlegen, SQL-Skript ausführen
- `Hyper-V Windows-Image verwalten`
- Manifest und Root-Konfigurationen
- Umbenennen

Für bestehende Hyper-V-Labs existiert bereits ein Untermenü (`Manage-LabHyperVEnvironmentInteractive`) mit:
- Start/Stop/Remove
- persistente Daten-VHDX anhängen/initialisieren
- SQL CompleteImage / Host-SSMS / Prüfung / WMI-Reparatur

Damit ist der Rahmen vorhanden, aber in der Zukunft fehlt:
- ein **strukturierter Reconciling-Flow** für bestehende Umgebung vor Änderung,
- einheitliche **Änderungsklassen-Darstellung** (`live`/`restart`/`recreate`/`reprovision`),
- ein klarer **Infrastructure-Submenu** mit getrennten Gruppen.

## 4) Zukunftsmenü (entworfen)

### 4.1 Top-Level (Hauptmenü)

1. Neue Umgebung erstellen
2. Umgebung verwalten
3. Status anzeigen
4. Umgebung starten
5. Umgebung stoppen
6. Umgebung neu starten
7. Umgebung entfernen
8. Alles aufräumen
9. Testdatenbank hinzufügen
0. Beenden

**Hinweis**: bestehende Top-Level-Labels bleiben größtenteils kompatibel; Fokus liegt auf besserer Unterteilung unter Punkt 2.

### 4.2 „Umgebung verwalten“ – Einstieg nach Provider

- Laufwerksauswahl: **Container-Lab** oder **Hyper-V-Lab**.
- Für beide Pfade:
  - Metadaten (`Name`, `RunId`, `Version`, `InstanceId`, `Status`)
  - geplanter `ActionPreview` (siehe unten)
  - aktuelle Änderungsklasse (falls in Bearbeitung)

#### A) Container-Submenü

- Starten / Stoppen / Neustarten / Entfernen
- SQL-Instanz prüfen
- Datenbank hinzufügen
- SQL-Skript ausführen
- Persistentes Volume verwalten (falls im Vertrag)

#### B) Hyper-V-Submenü (zentrale zukünftige Ergänzung)

1. **VM-Hardware**
   - RAM (Startup MB, Min/Max, Dynamic on/off)
   - vCPU
   - I/O-Intention (`standard`, `slow`, `high`) [Phase 2]
   - Vorschau der Änderungsklasse (live/restart)

2. **Netzwerk**
   - Intent (`isolated`, `hostOnly`, `nat`, `lan`)
   - IP-Plan (DHCP/Static, DNS-Set)
   - NIC-Zuordnung (Primary/Additional)
   - Externer Switch-Auswahlpfad (mit Warnhinweis)

3. **Storage**
   - bestehende persistente VHDX verwalten
   - zusätzliche VHDX nach Rolle anfügen (Data/Log/Tempdb/Backup)
   - bestehende zusätzliche VHDX abkoppeln/neu anlegen (nur bei Stop)
   - Volumen initialisieren + Label + Gastpfad

4. **SQL / Betriebsrolle**
   - SQL CompleteImage / Host-SSMS / Prüfpfade
   - SQL-Instanzen prüfen / WMI reparieren
   - Testdatenbanken installieren (bisherige Funktion)

5. **Reconcile-Lauf**
   - Ist-/Soll-Vergleich anzeigen
   - Auswirkungen (Downtime, Risiko, Datenpersistenz)
   - Bestätigung + Ausführung mit Plan-Preview

6. **Advanced – Spezialkonfigurationen**
   - Host-Folder-Mount (explizit als „Special“)  
   - manuelle/diagnostische Aktionen mit klarer Sicherheitskennzeichnung

## 5) Zukunfts-Aktionsmodell (CLI + UI konsistent)

### 5.1 Aktionstypen und erwartete Änderungsklasse

| UI-Eingriff | Runtime-Aktion (Ziel) | Typ | Mindestfluss |
|---|---|---:|---|
| Hyper-V RAM ändern | `UpdateHyperVLabResources` | `restart` | Validieren / Stoppen falls nötig / Anwenden / Starten / Check |
| Hyper-V vCPU ändern | `UpdateHyperVLabResources` | `restart` | gleich |
| Dynamic Memory toggeln | `UpdateHyperVLabResources` | `restart` | CPU- und Memory-Safe-Checks |
| NIC-Intent wechseln | `UpdateHyperVLabNetwork` | `restart` | Switch-Verfügbarkeit vor Änderung prüfen |
| Zusatz-VHDX hinzufügen | `UpdateHyperVLabStorage` | `recreate` | VM anhalten + Attach/Init + SQL-Integritätscheck |
| Host-SSMS aktivieren | `EnableHyperVLabHostSqlAccess` | `restart` | SQL/Network-Readiness + idempotent |
| Host-Folder-Mount aktivieren | `UpdateHyperVHostFolderMount` (Special) | `recreate` | nur im Advanced-Pfad |

### 5.2 Reconcile-Zielbild

Bei jeder Änderung an bestehender Umgebung:

- **Ist-Zustand lesen**
- **Soll-Zustand zeigen**
- **Klassen-Heatmap** (`grün` = in-place, `gelb` = Restart, `rot` = Recreate/Reprovision)
- **Kollisionscheck** (Netz, VHDX-Zugriffe, Datenpersistenz)
- **Ausführung mit Bestätigung**

## 6) Validierung und Preflight-Warnungen

Für jede Infrastrukturänderung gilt mindestens:

1. Host-Prüfung
   - verfügbare freie CPU/RAM
   - freie Storage-Kapazität im Data-/Run-Scope
   - verfügbare Hyper-V-Capabilities (Generation, PowerShell Direct, Switch-Status)

2. Laufzeitprüfung
   - Run-State (`running`/`stopped`)
   - Lock/Owner/RunId-Konsistenz
   - aktive SQL-Last bei SQL-Labs

3. Schutzprüfung
   - kein unbeabsichtigtes Überschreiben persistenter Daten
   - keine Änderung ohne bekannten Recovery-Pfad

4. Sicherheits-/Dokumentationshinweis
   - Jeder nicht-inplace Schritt zeigt präzise Warnung zu Reboot, Stop oder Datenwirkung.

## 7) Konkrete Antworten aus der fachlichen Anforderung

### 7.1 Speicher-/CPU-/Netzwerk-/IO-Änderung bei bestehender Umgebung

Über den neuen Hyper-V-Unterpunkt **VM-Hardware** und **Netzwerk** in der neuen „Umgebung verwalten“-Struktur.

### 7.2 Wo Host-Folder, VHDX, Volume einbinden?

- **VHDX (Standard)**: unter **Storage**.
- **Container-Volume**: im Container-Pfad.
- **Host-Folder**: im **Advanced – Spezialkonfiguration** Bereich, nicht im Standardpfad.

### 7.3 Sinnvolle Hyper-V-Hardware-Szenarien

**Erste Welle (sinnvoll und stabil):**

- vCPU und RAM (mit Startup-Dynamic)
- NIC-Intent, feste/auf Wunsch dynamische VM-Zuweisung
- Data/Log/Tempdb/Backup-VHDX als Rollen

**Zweite Welle (gezielt):**

- I/O-Intention (`slow`, `balanced`, `high`) mit klarer Auswirkungstransparenz
- zusätzliche Netzwerk- und Storage-Feinsteuerung, wo sicher nachweisbar.

**Nicht standardmäßig:** Host-Folder-Mount.

## 8) Doku-Delta (zeitnah zu implementieren)

Mit dem Start dieser Ausbaustufe müssen mindestens diese Dokumente synchron aktualisiert werden:

- `Documentation/HowTo/WORKFLOW_UI.md`
- `Documentation/Quality/KNOWN_LIMITATIONS.md`
- `Documentation/Quality/README.md`
- `README.md`
- `Documentation/User/Getting_Started.md`
- `Tests/Static/Invoke-DocumentationChecks.ps1` (falls Menüstruktur-Validierungen vorhanden)

## 9) PR-geeignete Taskliste

### Welle 1 – Plan & Navigation

- `PL-MENU-01`: Menüstruktur für bestehende Umgebung als Untermenü einführen, Provider-separat.
- `PL-MENU-02`: Reconcile-Preview vor jeder vorhandenen Hyper-V-Änderung anzeigen.
- `PL-MENU-03`: Advanced-Sektion als expliziten Sonderpfad dokumentieren.

### Welle 2 – Hyper-V-Infrastrukturmenü

- `PL-MENU-04`: Hyper-V-Submenü „VM-Hardware“ (RAM/CPU/Dynamic Memory).
- `PL-MENU-05`: Hyper-V-Submenü „Netzwerk“ mit Intent-/Switch-Auswahl und Preflight.
- `PL-MENU-06`: Hyper-V-Submenü „Storage“ mit Rollen-VHDX-Verwaltung.
- `PL-MENU-07`: Spezial-Mount-Pfad „Host-Folder-Mount“ als explizit Advanced/Expert markieren.

### Welle 3 – Konsistenz und Klassenmodell

- `PL-MENU-08`: CLI-Action-Namensschema auf Reconcile-Aktionen ausrichten.
- `PL-MENU-09`: Änderungsklassen (`live`/`restart`/`recreate`/`reprovision`) in UI-Text + Plan-Preview anzeigen.
- `PL-MENU-10`: Test- und Dokumentations-Sync gegen `Get-SqlServerLabWorkflow` ergänzen.

### Welle 4 – Abnahme

- `PL-MENU-11`: Laufzeitnahe Menütests (Smoke/Integration) vorbereiten und in Testplan aufnehmen.
- `PL-MENU-12`: Hyper-V-Workflows mit Hardware-/Netzwerk-/Storage-Änderungen dokumentiert validieren.
- `PL-MENU-13`: CHANGELOG-Eintrag mit „UI-Flow-Update (planned / staged)“.

## 10) Akzeptanzkriterien (erste umsetzbare Stufe)

- Bestehende Umgebung ändert sich über das neue strukturierte Untermenü, ohne Top-Level-Wechsel.
- Jede Änderung zeigt vor Ausführung einen Plan mit Änderungsklasse und Downtime-Hinweis.
- Host-Folder-Mount ist ausschließlich im Advanced-Pfad verfügbar und als Spezialkonfiguration gekennzeichnet.
- Storage-/Hardware-/Netzwerkpfade sind Provider-separiert (Hyper-V vs. Container).
- Mindestens ein Plan-Preview-View zeigt korrekt die Warnung bei Reboot/Stop-Pflicht.
- Dokumentation und bekannte Grenzen bleiben nach jeder Implementationswelle synchron.

## 11) Nächste Entscheidung

Die erste Implementierung entscheidet:

1. ob die neue Hyper-V-Verwaltung als dedizierte Top-Level-Gruppe eingeführt wird oder
2. ob sie als separater Zweig im bestehenden `Hyper-V Windows-Image verwalten`-Pfad bleibt.

Beide Wege sind möglich; die zweite Variante minimiert initiale UX-Risiken.
