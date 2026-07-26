# Fortsetzungshinweise

## Vor jeder Änderung

- Prüfen Sie repositoryweit die case-sensitive Namenskonsistenz.
- Aktualisieren Sie ein Einzelobjekt und alle daraus generierten Installer gemeinsam.
- Führen Sie keine konkrete Installationsdatenbank in Code oder Dokumentation ein.
- Das Repository-Liefergate darf Resultsets, OUTPUT-Parameter sowie RAW-, CONSOLE-, TABLE- und JSON-Ausgaben nicht anonymisieren oder fachlich reduzieren.
- Reale Benutzer-, Kunden-, Firmen-, Organisations-, Umgebungs- oder Fachwerte und proprietäre interne Strukturen dürfen niemals aus Screenshots, Hardcopys, Chats, Uploads, Skripten, Logs oder Diagnoseausgaben in Repository-, GitHub-, Dokumentations-, Test- oder Downloadartefakte übernommen werden.
- Beispiele und gespeicherte Testergebnisse verwenden ausschließlich eindeutig synthetische, generische Werte und bilden keine reale interne Struktur nach.
- Halten Sie bei einem uneindeutigen Artefaktwert vor dem Schreiben an und fragen Sie nach einer nicht sensitiven Alternative; eine Zustimmung hebt das Repositoryverbot nicht auf.

## Nach jeder Änderung

- Führen Sie den statischen API-, Portabilitäts- und Quellenaudit aus.
- Führen Sie `python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root . --self-test` und anschließend `python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root .` aus.
- Führen Sie vor einer ZIP-Auslieferung zusätzlich `python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root . --archive-path <ZIP>` gegen den vollständigen Lieferumfang aus; gefundene Inhalte werden niemals in der Prüfausgabe wiedergegeben.
- Legen Sie den Lieferweg vor dem Commit fest und führen Sie `python3 Code/Tests/Static/930_Validate_Commit_Message.py --repository-root . --self-test` lokal aus.
- Stellen Sie bei manueller Repositorypflege über ein downloadbares ZIP eine nicht leere, exakt einzeilige Commit Message ohne Zeilenumbruch bereit und prüfen Sie den neuen Commit mit `--delivery-mode MANUAL_ZIP`.
- Bei einem direkten Commit und Push durch die KI darf die Commit Message aus Betreff und optionalem mehrzeiligem Body bestehen; prüfen Sie den neuen Commit mit `--delivery-mode DIRECT_GIT` und lassen Sie ihn anschließend durch das Actions-Gate validieren.
- eine automatisch erzeugte mehrzeilige Squash-Message ist im direkten Git-Weg zulässig und erfordert weder leeren Korrekturcommit noch History-Rewrite;
- Erzeugen Sie die Installer aus den kanonischen Einzeldateien neu.
- Aktualisieren Sie Beispielaufrufe und Referenz.
- Kompilieren Sie auf SQL Server 2019, 2022 und 2025 und führen Sie die Smoke-Tests aus.
- Aktualisieren Sie `AI_Metadata/Internal_Documentation/Quality/Migration_Audit_History.json` beziehungsweise einen neuen Release-Audit.

- Regenerieren Sie kein SHA- oder Dateimanifest; Git und die maschinenlesbaren Fachinventare sind maßgeblich.

## Maßgeblicher Ausgangsstand

Der aktuelle Architekturstand ergänzt den frameworkweiten Datenbank-, CONSOLE- und benannten TABLE-Vertrag. `187_Table_Output_Runtime_Contract.sql`, `188_Framework_Output_Pilot_Runtime.sql` und `189_Framework_Output_Runtime_Contract.sql` prüfen den Mehrfach-Export, die Pilotmodule sowie die öffentliche Frameworkgrenze im 34-Suite-Gate auf SQL Server 2019, 2022 und 2025. P3 bleibt getrennt: SC-023 benötigt ausdrückliche Persistenzentscheidungen, SC-024 eine externe Komponente und SC-025 eine autorisierte isolierte Restore-/Hostausführung.

Die priorisierte Ausbauplanung steht in `AI_Metadata/Internal_Documentation/Research/Special_Case_Gap_Analysis.md`; der maschinenlesbare Backlog steht in `Metadata/Quality/Special_Case_Gap_Backlog.csv`.

## Änderungen 2026-07-25

### Collation-Architektur

- `Code/00_Setup/000_Preflight_und_Schema.sql` (v2.1.0): Collation-Prüfung von THROW auf RAISERROR severity 10 geändert. Installation wird bei abweichender Collation nicht mehr blockiert, sondern warnt.
- Das Framework verwendet durchgängig explizite `COLLATE SQL_Latin1_General_CP1_CS_AS`-Klauseln und funktioniert grundsätzlich auf beliebigen Collations. Getestet und garantiert bleibt ausschließlich `SQL_Latin1_General_CP1_CS_AS`.
- Dokumentation angepasst: `README.md`, `Documentation/Reference/Installation.md`, `AI_Metadata/PROJECT_CONTEXT.md`.

### Neue CI-Lanes

- `.github/workflows/collation-portability-validation.yml`: SQL Server 2022 mit `Latin1_General_CI_AS` auf GitHub-hosted Ubuntu. Testet Installation (mit erwarteten Warnungen), Smoke Test, Filter-TVFs und Analysis Navigator.
- `windows-self-hosted-validation.yml`: Neuer Job `sql-runtime` ergänzt:
  - Automatische SQL-Server-Erkennung (sqlcmd + Version + Collation)
  - Windows Authentication, isolierte Testdatenbank mit CS_AS + Query Store
  - Smoke Test + versionsspezifisches Release Gate (2019/2022/2025)
  - Evidenzfähige Summary. Graceful Skip wenn kein SQL Server vorhanden.

### Neue Procedure

- `Code/09_VersionAdaptive/500_USP_FrameworkUsageFromQueryStore.sql` (v1.0.0): Liest aus dem Query Store der Installationsdatenbank welche `monitor.*`-Procedures mit welcher Häufigkeit aufgerufen wurden. Zero-Footprint, read-only.
- In `Install_All.sql` aufgenommen (nach `100_USP_ClrAnalysis.sql`).
- `VW_AnalysisCatalog` v1.3.0: VERSION_ADAPTIVE/ENTRY mit Query-Store-Abhängigkeit.
- `VW_AnalysisSearchTerm`: 3 Suchbegriffe (de/en) für Navigator.
- `Call_Catalog.md`: Stand 98 Procedures mit Aufrufbeispielen.
- Vollständige Procedure-Seite: `Documentation/Analysis_Guides/Procedures/USP_FrameworkUsageFromQueryStore.md`.

### Neue Dokumentation

- `Documentation/Reference/Scope_and_Limitations.md`: Aggregierte Übersicht was das Framework tut und ausdrücklich nicht tut.
- `Metadata/Inventory/Module_Maturity.csv`: Maschinenlesbare Reifegrad-Matrix aller Module.
- `Lab/Scenarios/LEARNING_PATH.md`: Pädagogische Lesereihenfolge für alle 39 Lab-Szenarien in 5 Stufen.
- `README.md`: Inventar 98 Procedures/166 Objekte, Links auf Scope und Lernpfad.

### Bereinigung

- Stale Branches gelöscht: `agent/windows-runner-readiness`, `windows-validation/repository-portability` (identisch mit main).
- `private_Note/erkannte_Probleme.md`: Status-Nachtrag der erledigten Punkte.

### Offene Folgeaufgaben (Status 2026-07-26)

- Erste Laufzeitevidenz der Collation-Portability-Lane und des Windows-Runner `sql-runtime`-Jobs auswerten.
- `Module_Maturity.csv` bei neuen Modulen oder geänderten Evidenznachweisen aktualisieren.
- ~~`Procedure_Reference.md`: Technische Signatur der neuen Procedure ergänzen.~~ ERLEDIGT (2026-07-25)
- ~~`VW_AnalysisRelation`: Neue Procedure mit verwandten Modulen verknüpfen.~~ ERLEDIGT (2026-07-25, 4 Relationen)

## Änderungen 2026-07-26

### Repository-Umstrukturierung (extern)

- Produkt-/CI-Trennung: CI-Workflows nach `ci-ops` Branch verschoben.
- Entfernt aus `main`: `windows-self-hosted-validation.yml`, `collation-portability-validation.yml`, `sqlserver-2019-linux-release-gate.yml`, `sqlserver-2025-linux-release-gate.yml`.
- Neu in `main`: `collect-statistics-release-evidence.yml`, `repository-privacy-validation.yml`, `commit-message-validation.yml`, `lab-contract-validation.yml`, `documentation-validation.yml`, `quickstart-docker-validation.yml`, `sqlserver-compatibility-matrix-manual.yml`.
- Docker-QuickStart (`QuickStart/Docker/`) komplett hinzugefügt (extern).
- `AI_Metadata/Internal_Documentation/Architecture/Repository_Branching_and_Boundaries.md` und `Branch_Separation_Execution_Plan.md` dokumentieren die Trennung.

### Hyper-V QuickStart: Dual-OS-Architektur (3 Commits)

**Commit 1:** `feat: Hyper-V QuickStart – Dual-OS-Architektur und Netzwerksimulation`

- `AI_Metadata/Internal_Documentation/Architecture/HyperV_QuickStart_Design_Decisions.md`: Vollständiges Design-Dokument mit Windows- und Linux-VM-Support, Netzwerk-/IO-Simulation, Base-Image-Strategie, Ressourcenprofile.
- `QuickStart/HyperV/Setup.ps1`: Dual-OS fähig (VmIpMap Win+Linux, NetworkProfiles, IoProfiles, lädt NetworkSimulation.ps1).
- `QuickStart/HyperV/Internal/NetworkSimulation.ps1` (NEU): SSH-basierte Steuerung der Linux-VMs, tc/netem (Latenz, Bandbreite, Paketverlust), cgroups v2 io.max (IOPS, Durchsatz), Laufzeitänderung ohne VM-Neustart.

**Commit 2:** `feat: Hyper-V QuickStart – Linux-VM-Support und Dual-OS-Betrieb`

- `Configuration.ps1`: OS-Modus-Abfrage (Windows/Linux/Gemischt), Linux Base-Image (lokal oder Ubuntu Cloud-Image Auto-Download), Netzwerk-/IO-Profil-Auswahl, SSH-Key-Generierung (ed25519), Dual-OS Initialize-VmEnvironment.
- `VmProvisioning.ps1` (168→368 Zeilen): `Get-LinuxCloudImage` (Ubuntu 24.04 VHDX), `New-LabDataDisk`, `New-CloudInitIso` (via oscdimg), `New-LabLinuxVm` (Gen2 + Data/Log Disks + cloud-init DVD).
- `SqlInstall.ps1` (167→327 Zeilen): `Install-SqlServerOnLinux` (APT, mssql-conf, dedizierte Partitionen), `Install-FrameworkOnLinux` (SCP + sqlcmd).
- `Runtime.ps1` (neu geschrieben): Dual-OS VM-Verwaltung, SSH-Bereitschaftsprüfung, SimulationStatus-Integration.
- `Lifecycle.ps1` (neu geschrieben): Dual-OS Remove, SSH-Key-Bereinigung, ReadOnly-Flag für beide Base-Images.
- `README.md` (neu geschrieben, 172 Zeilen): Betriebsmodi-Tabelle, Netzwerk-/IO-Profiltabellen, Architektur mit Data/Log-Disks.
- `QuickStart/README.md`: Hyper-V-Beschreibung aktualisiert.

### Hyper-V QuickStart – Architekturübersicht

```text
QuickStart/HyperV/
├── Setup.ps1              (Haupteinstieg, Dual-OS)
├── Uninstall.ps1          (Wrapper → Remove)
├── README.md              (Vollständige Anleitung)
├── .env.example           (Synthetische Platzhalter)
└── Internal/
    ├── Common.ps1         (Write-Section, Read-YesNo, Read-MenuChoice)
    ├── PathSafety.ps1     (Pfadvalidierung, Scope-Marker)
    ├── Configuration.ps1  (Setup-Dialog, OS-Modus, Initialize)
    ├── VmProvisioning.ps1 (Switch/NAT, Disks, Win+Linux VMs)
    ├── SqlInstall.ps1     (Unattended Win + APT Linux)
    ├── NetworkSimulation.ps1 (tc/netem + cgroups v2)
    ├── Runtime.ps1        (Start/Stop/Status)
    └── Lifecycle.ps1      (Remove/Uninstall)
```

Netzwerk: Interner Switch `SQL_Server_Analyze_Lab` + NAT (172.30.0.0/24). Windows: .19/.22/.25, Linux: .119/.122/.125.

### Offene Folgeaufgaben

- Hyper-V QuickStart auf realem Windows-Host testen (erster End-to-End-Lauf).
- Windows ADK-Abhängigkeit für cloud-init ISO evaluieren (Alternative: PowerShell-native ISO-Erstellung).
- Download-Modus für Windows Base-Image implementieren (ISO → VHDX Konvertierung).
- `Module_Maturity.csv` mit Hyper-V QuickStart ergänzen.
- Collation-Portability-Evidenz auswerten (wenn CI-Lane läuft).
- `CONTINUATION_GUIDE.md` nach nächsten Änderungen fortschreiben.
