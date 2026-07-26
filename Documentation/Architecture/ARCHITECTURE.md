# SQL_Server_Lab – Architektur

**Stand:** 2026-07-26
**Status:** Entwurf (vor Implementierung)

---

## 1. Zweck und Abgrenzung

SQL_Server_Lab stellt isolierte, reproduzierbare SQL-Server-Testumgebungen bereit. Die Umgebungen dienen ausschliesslich der lokalen Entwicklung, Diagnose und Schulung.

Das Repository verwaltet:

- Erzeugung und Lifecycle von SQL-Server-Instanzen (Container und VMs)
- Provider-Abstraktion (Docker, Podman, Hyper-V)
- Ressourcenpruefung und -profile
- Datenbank-Layout-Provisionierung (Filegroups, Files, Collation)
- Software-Provisioning auf VMs (winget, apt, PowerShell-Module)
- State-, Scope- und Cleanup-Management
- Deklarative Manifeste fuer wiederholbare Umgebungen

Das Repository verwaltet NICHT:

- Fachliche T-SQL-Logik (gehoert dem Konsumenten)
- Testdaten-Generierung (gehoert dem Konsumenten)
- Analyse-Szenarien, Findings, Probes (gehoert SQL_Server_Analyze)
- Demo-Harness, Praesentationen (gehoert SQL_PerformanceSchulung)

---

## 2. Konsumenten und Adapter-Vertrag

### 2.1 Primaerkonsumenten

| Repository | Verwendungszweck |
| --- | --- |
| SQL_Server_Analyze | Framework-Installation, Diagnose-Szenarien, Validierung |
| SQL_PerformanceSchulung | Demo-Umgebungen, Multi-Session, Baseline/Observation |

### 2.2 Konsumierung

Der Konsument importiert SQL_Server_Lab als PowerShell-Modul:

```powershell
Import-Module $env:SQL_SERVER_LAB_PATH\SqlServerLab.psd1
```

Auto-Discovery-Reihenfolge:

1. Umgebungsvariable `$env:SQL_SERVER_LAB_PATH` (explizit)
2. Geschwisterverzeichnis `../SQL_Server_Lab` (relativ zum Konsumenten)
3. Registrierter Pfad in `~/.sql-server-lab/config.json`

### 2.3 Oeffentliche API (Cmdlets)

```text
# Lifecycle
Invoke-SqlServerLab                    # Menue oder Manifest-Einstieg
New-SqlServerLab                       # Neue Umgebung
Get-SqlServerLab                       # Status
Start-SqlServerLab                     # Starten
Stop-SqlServerLab                      # Stoppen
Restart-SqlServerLab                   # Neustart
Remove-SqlServerLab                    # Entfernen

# Datenbank und Skripte
New-LabDatabase                        # Datenbank anlegen (mit File-Layout)
Invoke-LabScript                       # T-SQL-Skript ausfuehren

# Erweiterungen
Install-LabSoftware                    # Software auf VM installieren
Test-LabResources                      # Ressourcenpruefung (read-only)
Invoke-LabCleanup                      # Scope-gebundener Cleanup
Invoke-LabRecovery                     # Wiederaufnahme nach Fehler
```

### 2.4 Rueckgabe-Objekt

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider Docker

$lab.RunId                    # GUID
$lab.ScopeId                  # Scope-Marker
$lab.State                    # Running | Stopped | Failed | Removed
$lab.Instances[0].Id          # Logische ID
$lab.Instances[0].Host        # z.B. 127.0.0.1
$lab.Instances[0].Port        # z.B. 14330
$lab.Instances[0].Version     # 2025
$lab.Instances[0].Provider    # docker
$lab.Instances[0].ConnectionString
$lab.Instances[0].Databases   # Array der erstellten DBs
```

---

## 3. Deklaratives Manifest

### 3.1 Zweck

Ein Manifest beschreibt eine Umgebung deklarativ. Der Konsument definiert WAS; das Lab entscheidet WIE.

### 3.2 Schema (Kurzform)

```json
{
  "name": "szenarioname",
  "instances": [
    {
      "id": "logische-id",
      "version": "2025",
      "provider": "docker|podman|hyperv (optional)",
      "os": "windows|linux (optional)",
      "profile": "compact|standard|performance (optional)",
      "collation": "SQL_Latin1_General_CP1_CS_AS (optional)",
      "databases": [
        {
          "name": "DatabaseA",
          "options": { "queryStore": true, "compatibility": 160 },
          "files": {
            "data": [{ "name": "D1", "sizeMB": 200 }],
            "log": [{ "name": "L1", "sizeMB": 100 }]
          }
        }
      ],
      "software": [
        { "id": "ssms", "source": "winget", "package": "Microsoft.SQLServerManagementStudio" }
      ],
      "postProvision": ["scripts/setup.sql"]
    }
  ]
}
```

### 3.3 Beispiel: SQL_Server_Analyze I/O-Szenario

```json
{
  "name": "analyze-io-bottleneck",
  "instances": [{
    "id": "primary",
    "version": "2025",
    "provider": "docker",
    "databases": [
      {
        "name": "AnalyzeTarget",
        "files": {
          "data": [
            { "name": "AT_Data1", "sizeMB": 200 },
            { "name": "AT_Data2", "sizeMB": 200 },
            { "name": "AT_Data3", "sizeMB": 200 },
            { "name": "AT_Data4", "sizeMB": 200 },
            { "name": "AT_Data5", "sizeMB": 200 }
          ],
          "log": [{ "name": "AT_Log", "sizeMB": 100 }]
        }
      },
      {
        "name": "AuditDB",
        "files": {
          "data": [{ "name": "Audit_Data", "sizeMB": 50 }],
          "log": [
            { "name": "Audit_Log1", "sizeMB": 30 },
            { "name": "Audit_Log2", "sizeMB": 30 }
          ]
        }
      }
    ],
    "postProvision": ["Install_All.sql"]
  }]
}
```

### 3.4 Beispiel: Gemischte Umgebung mit Software

```json
{
  "name": "cross-version-dev",
  "instances": [
    {
      "id": "primary-2025",
      "version": "2025",
      "provider": "hyperv",
      "os": "windows",
      "software": [
        { "id": "ssms", "source": "winget", "package": "Microsoft.SQLServerManagementStudio" },
        { "id": "vscode", "source": "winget", "package": "Microsoft.VisualStudioCode" }
      ],
      "databases": [{ "name": "DevDB" }]
    },
    {
      "id": "secondary-2019",
      "version": "2019",
      "provider": "podman"
    }
  ]
}
```

### 3.5 Beispiel: Performance-Schulung

```json
{
  "name": "perf-demo-deadlocks",
  "instances": [{
    "id": "demo",
    "version": "2022",
    "provider": "docker",
    "profile": "standard",
    "databases": [{
      "name": "PerfDemo",
      "files": {
        "data": [{ "name": "PerfDemo_Data", "sizeMB": 500 }],
        "log": [{ "name": "PerfDemo_Log", "sizeMB": 200 }]
      }
    }],
    "postProvision": ["Setup.sql", "GenerateData.sql"]
  }]
}
```

---

## 4. Provider-Abstraktion

### 4.1 Provider-Interface

Jeder Provider implementiert:

```text
Test-ProviderAvailable       -> bool
New-ProviderInstance          -> InstanceInfo
Start-ProviderInstance       -> void
Stop-ProviderInstance        -> void
Remove-ProviderInstance      -> void
Get-ProviderInstanceStatus   -> StatusReport
Wait-ProviderSqlReady        -> ConnectionInfo
```

### 4.2 Auto-Select-Logik

1. `software` mit GUI-Apps → Hyper-V
2. `os: windows` → Hyper-V
3. Sonst → Docker (schnellster Start)

### 4.3 Neue Provider

Registrierung via `Providers/<Name>/provider.json`. Oeffentliche API aendert sich nicht.

---

## 5. SQL-Server-Versionskatalog

Erweiterbare JSON-Datei (`Catalogs/sql-server-versions.json`). Keine Enums im Code.

```json
{
  "versions": [
    { "id": "2019", "major": 15, "status": "SUPPORTED", "docker": { "image": "mcr.microsoft.com/mssql/server:2019-latest" } },
    { "id": "2022", "major": 16, "status": "SUPPORTED", "docker": { "image": "mcr.microsoft.com/mssql/server:2022-latest" } },
    { "id": "2025", "major": 17, "status": "SUPPORTED", "docker": { "image": "mcr.microsoft.com/mssql/server:2025-latest" } }
  ],
  "statusValues": ["SUPPORTED", "DEPRECATED", "RETIRED", "BLOCKED", "PREVIEW"]
}
```

---

## 6. State-Management

### 6.1 State-Verzeichnis

Ausserhalb des Git-Checkouts:

- Windows: `$env:LOCALAPPDATA\SqlServerLab\`
- Linux: `~/.sql-server-lab/`
- Explizit: `$env:SQL_SERVER_LAB_STATE` oder Parameter `-StateRoot`

### 6.2 Struktur

```text
<StateRoot>/
  config.json
  runs/<RunId>/
    run-state.json
    manifest.resolved.json
    cleanup-plan.json
    connection-info.json
    secrets.json (verschluesselt)
  scope-markers/<ScopeId>.json
```

### 6.3 State-Machine

```text
INITIALIZING -> PROVISIONING -> SQL_READY -> DATABASES_CREATED -> POST_PROVISIONED -> RUNNING
                     |                                                                    |
                PROVISION_FAILED                                                       STOPPED
                     |                                                                    |
                CLEANUP_PENDING -> CLEANUP_RUNNING -> CLEANED_UP                      REMOVED
```

---

## 7. Resource Assessment

Vor jeder Mutation: read-only Pruefung. Das Assessment veraendert keine Ressourcen.

| Kategorie | Pruefpunkte |
| --- | --- |
| CPU | Logische Kerne verfuegbar vs. angefordert |
| RAM | Freier physischer Speicher vs. Summe MaxMemory |
| Storage | Freier Platz vs. Data + Log + TempDB + Image-Overhead |
| Ports | Angeforderte Ports frei und nicht durch andere Labs belegt |
| Provider | Docker/Podman/Hyper-V installiert und funktional |
| Pfade | Sicher (nicht System, nicht Repository, nicht fremd) |
| Rechte | Schreibrechte auf State und Datenpfade |

Ergebnis-Status:

| Status | Bedeutung |
| --- | --- |
| RESOURCE_OK | Alle Anforderungen erfuellt |
| RESOURCE_WARNING | Knapp (<20% Reserve) |
| RESOURCE_INSUFFICIENT_OVERRIDABLE | Unterversorgt, Override moeglich |
| RESOURCE_HARD_BLOCK | Nicht uebersteuerbar |

Nicht uebersteuerbar: unsichere Pfade, fehlender Provider, fehlende Rechte, Mutation fremder Ressourcen.

---

## 8. Cleanup und Recovery

Maschinenlesbarer Cleanup-Plan vor erster Mutation. Automatischer Cleanup bei Fehler in umgekehrter Reihenfolge. Nur eigene Ressourcen (RunId/ScopeId/Labels).

Ergebnis: `CLEANUP_SUCCEEDED | CLEANUP_PARTIAL | RECOVERY_REQUIRED | CLEANUP_BLOCKED`

---

## 9. Software-Provisioning

### 9.1 Anwendbarkeit

Software-Installation ist primaer auf VMs (Hyper-V) relevant. Container erhalten Software ueber das Basis-Image oder Dockerfile-Layer.

### 9.2 Quellen

| Source | Plattform | Beispiel |
| --- | --- | --- |
| winget | Windows | `Microsoft.SQLServerManagementStudio` |
| choco | Windows | `sql-server-management-studio` |
| apt | Linux | `htop`, `sysstat` |
| snap | Linux | `code --classic` |
| url | Beide | Download + Silent-Install (msi/exe) |
| pwsh | Beide | `Install-Module dbatools -Force` |

### 9.3 Verhalten

- Optional (Default): Fehlgeschlagene Software blockiert nicht SQL-Bereitschaft
- Idempotent: Bereits installiert wird uebersprungen
- Timeout: 10 Minuten pro Paket (konfigurierbar)
- Status je Paket: `[OK]`, `[SKIPPED]`, `[FAILED]`, `[NOT_APPLICABLE]`

---

## 10. Sicherheitsvertraege

### 10.1 Pfadsicherheit

- Keine Systempfade (Windows, Program Files, ProgramData)
- Keine Repositorypfade
- Keine fremden Verzeichnisse (nur eigene Scope-Marker)
- Keine unkontrollierten Symlinks oder Junctions
- Keine Wildcard-Loeschung

### 10.2 Container-/VM-Sicherheit

- Keine Entfernung fremder Container, Volumes, Netzwerke oder VMs
- Identifikation nur ueber Lab-eigene Labels, RunId und ScopeId
- Kein `docker system prune`
- Kein `Remove-VM` ohne vorherige Scope-Pruefung

### 10.3 Secrets

- SA-Passwort verschluesselt oder ACL-geschuetzt im State
- Verbindungsinfo-Ausgabe enthaelt KEIN Passwort
- Secrets werden bei Remove geloescht
- Keine Secrets in Git-Artefakten

### 10.4 Datenklassifikation

| Klasse | Zulaeassig |
| --- | --- |
| LAB_GENERATED | Ja |
| PUBLIC_SAMPLE | Ja |
| USER_PROVIDED_NON_PRODUCTION | Ja (mit Bestaetigung) |
| PRODUCTION_DATA | Blockiert |
| UNKNOWN | Blockiert |

---

## 11. Modulstruktur

```text
SQL_Server_Lab/
  SqlServerLab.psd1
  SqlServerLab.psm1
  Invoke-SqlServerLab.ps1
  Public/                  # Exportierte Cmdlets
  Private/                 # Interne Logik
  Providers/Docker/        # Docker-Provider
  Providers/Podman/        # Podman-Provider (spaeter)
  Providers/HyperV/        # Hyper-V-Provider (spaeter)
  Catalogs/                # Versionskatalog
  Schemas/                 # JSON-Schemas
  Documentation/
  _QuellRepo/              # UNVERAENDERLICH
  Tests/
```

---

## 12. Ausfuehrungsreihenfolge

1. Manifest einlesen und validieren
2. Versionskatalog pruefen
3. Provider-Auswahl und Capability-Check
4. Resource Assessment
5. Cleanup-Plan schreiben, Run-State initialisieren
6. Pro Instanz: Container/VM erzeugen -> SQL-Readiness -> Version verifizieren -> Datenbanken -> Software
7. Post-Provision-Skripte ausfuehren
8. Verbindungsinfo ausgeben
9. State -> RUNNING

Bei Fehler: Cleanup rueckwaerts ab fehlgeschlagenem Schritt.

---

## 13. Erweiterungspunkte (Breaking-Change-Vermeidung)

| Erweiterung | Mechanismus | API-Aenderung |
| --- | --- | --- |
| Neuer Provider | Ordner unter `Providers/` | Keine |
| Neue SQL-Version | Eintrag in Katalog-JSON | Keine |
| Neues Manifest-Feld | Optional, additiv | Keine (bestehende Manifeste weiter gueltig) |
| Neue Software-Quelle | Handler in SoftwareInstaller | Keine |
| Hooks (preSqlReady, postCreate) | Optionales Manifest-Feld | Keine |
| Multi-Host / Remote | Neuer Provider-Typ | Keine (gleiche API) |

---

## 14. Offene Entscheidungen

| ID | Frage | Status |
| --- | --- | --- |
| OE-01 | Parallele vs. sequenzielle Instanz-Erzeugung | Sequenziell Default |
| OE-02 | Secret-Verschluesselung (DPAPI vs. AES vs. ACL) | Offen |
| OE-03 | Podman-Rootless-Besonderheiten | Spaetere Phase |
| OE-04 | Multi-Host-Support | Nur lokal im ersten Slice |
| OE-05 | Backup/Restore-Integration | Spaetere Phase |

---

## 15. Implementierungsreihenfolge

### Phase 1: Docker Vertical Slice (Mindestumfang)

1. Modul-Grundstruktur (SqlServerLab.psd1, Loader)
2. Versionskatalog (sql-server-versions.json)
3. Docker-Provider (New, Start, Stop, Remove, Status)
4. SQL-Readiness (Wait + Version-Check)
5. Resource Assessment (Basis: RAM, Storage, Docker-Verfuegbarkeit)
6. State-Management (Run-State, Scope-Marker)
7. Cleanup-Engine (Plan + Execution)
8. `New-SqlServerLab` + `Remove-SqlServerLab` funktional
9. Manifest-Parser (Basis-Felder)
10. `New-LabDatabase` + `Invoke-LabScript`
11. Interaktiver Einstieg (`Invoke-SqlServerLab`)
12. Getting-Started-Dokumentation

### Phase 2: Adapter + Lifecycle

13. Alle Lifecycle-Cmdlets (Start, Stop, Restart, Get)
14. Analyze-Adapter (Manifest-Beispiel + Framework-Installation)
15. PerformanceSchulung-Adapter (Manifest-Beispiel + Demo-Setup)
16. Schema-Validierung (manifest.schema.json)
17. Test-Suite (Static + Integration)

### Phase 3: Hyper-V

18. Hyper-V-Provider (Windows + Linux VMs)
19. Software-Provisioning (winget, apt)
20. Netzwerk-/I/O-Simulation
21. Base-Image-Management

### Phase 4: Podman + Erweitert

22. Podman-Provider
23. Hook-System
24. Multi-Instanz-Topologien (Abhaengigkeiten zwischen Instanzen)
25. Backup/Restore-Integration
