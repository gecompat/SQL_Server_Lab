# Repository-lokale KI-Skills – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Entscheidung | fachlich akzeptiert |
| Stand | 2026-09-05 |
| Geplanter Scope | `.agents/skills` im Repository |
| Reihenfolge | `Readiness` vor `Validation` und `Operate` |

## Entscheidung

Wiederverwendbare KI-Arbeitsabläufe für `SQL_Server_Lab` werden als
repository-lokale Skills unter `.agents/skills` geplant. Sie werden gemeinsam
mit Code, Tests und Dokumentation versioniert und reviewed. Eine ausschließlich
persönliche Installation außerhalb des Repositorys ist nicht der maßgebliche
Projektvertrag.

Ein Skill bildet einen fachlich zusammenhängenden Benutzer- oder
Entwicklungsablauf ab. Die derzeit exportierten PowerShell-Cmdlets erhalten
nicht jeweils einen eigenen Skill. Die Skills orchestrieren die vorhandenen
öffentlichen Einstiegspunkte und führen keine zweite Befehls-, Parameter- oder
Governance-Wahrheit ein.

## Geplante Struktur

```text
.agents/
└── skills/
    ├── sql-server-lab-readiness/
    │   └── SKILL.md
    ├── sql-server-lab-validation/
    │   └── SKILL.md
    └── sql-server-lab-operate/
        └── SKILL.md
```

Optionale `scripts/`, `references/`, `assets/` und `agents/openai.yaml` werden
nur angelegt, wenn der jeweilige Skill dafür einen nachweisbaren Bedarf besitzt.
Weitere Skills für Manifest-, Storage-/Recovery-, Hyper-V- oder
Release-Abläufe werden erst nach ausgewerteter Nutzung der ersten drei Skills
entschieden.

## Bootstrap- und Readiness-Grenze

Ein Skill kann nicht unabhängig nachweisen, dass der Client den
repository-lokalen Skill überhaupt entdeckt und geladen hat. Wenn der
Skill-Loader nicht arbeitet, kann auch ein Readiness-Skill nicht starten.
Deshalb besteht der geplante Readiness-Vertrag aus zwei getrennten Ebenen:

1. Ein eigenständig ausführbares, read-only PowerShell-Skript
   `Tools/Test-SqlServerLabClientReadiness.ps1` bildet die deterministische
   Projektwahrheit. Es darf weder einen Skill noch ein generatives KI-System
   voraussetzen.
2. Der Skill `sql-server-lab-readiness` ruft diesen Einstiegspunkt auf,
   erklärt das strukturierte Ergebnis und nennt den kleinsten konkreten
   nächsten Schritt.

Der eigenständige Check soll mindestens folgende Klassen getrennt beurteilen:

- unterstütztes Betriebssystem und PowerShell-Mindestversion;
- Repository-, Modulmanifest- und Modulimportstatus;
- erwartete exportierte öffentliche Cmdlets;
- prozesslokale Host-Tool-Auflösung über den bestehenden Resolver;
- Installation, Erreichbarkeit und Ausführungsberechtigung des gewählten
  Docker-, Podman- oder Hyper-V-Pfads;
- erforderliche Storage-Konfiguration;
- für die angeforderte Operation notwendige Rechte;
- strukturierte Felder für Status, fehlende Voraussetzung, Warnung und
  empfohlenen nächsten Schritt.

Der Check bleibt mutationsfrei. Setup, Runtime-Start, persistierende
Konfigurationsänderung und Rechteerhöhung sind getrennte, ausdrücklich
auszulösende Abläufe. Nach erfolgreichem Bootstrap kann der Skill für einen
gewählten Provider zusätzlich `Test-SqlServerLabPrerequisite` verwenden.

## Abgrenzung der Quellen der Wahrheit

- `AGENTS.md` und die darin erschlossenen Projektregeln definieren die immer
  geltende Governance.
- `SqlServerLab.psd1`, `Get-Command`, `Get-Help` und die öffentliche
  Implementierung definieren verfügbare Cmdlets, Parameter und Rückgabewerte.
- `.ai/repo_map.yaml` ordnet Verträge, Implementierungen, Dokumentation und
  Validierung maschinenlesbar zu.
- Die aktiven Architektur-, Benutzer- und Qualitätsdokumente beschreiben
  Verhalten, Grenzen und Nachweise.
- Ein Skill erkennt die Benutzerabsicht, wählt den passenden bestehenden
  Ablauf und wertet dessen strukturiertes Ergebnis aus.

Skill-Dateien kopieren keine vollständigen Parametersignaturen und keine
umfangreichen Abschnitte aus den autoritativen Projektquellen. Vor einer
Ausführung lösen sie die aktuelle Befehlsmetadaten und die für den Scope
relevanten Quellen erneut auf.

## Geplante Skills

### `sql-server-lab-readiness`

Prüft den Client und den angeforderten Providerpfad ohne Mutation. Dieser Skill
und sein eigenständiger PowerShell-Einstiegspunkt werden zuerst umgesetzt.

### `sql-server-lab-validation`

Bestimmt den Änderungsscope, wählt fokussierte und betroffene Prüfungen nach
der lokalen Validierungsstrategie aus und fasst ausschließlich tatsächlich
ausgeführte Nachweise zusammen. Provider-Smokes werden nur bei betroffenem
Runtimevertrag ausgewählt.

### `sql-server-lab-operate`

Orchestriert die häufigen Benutzerabläufe für Erstellen, Status, Verbindung,
Start, Stop und Entfernen. Read-only Preview, Mutation, Cleanup und Recovery
bleiben sichtbar getrennt; destruktive Ziele werden weiterhin durch die
bestehenden öffentlichen Verträge begrenzt.

## Optionale lokale REST-API

Eine versionierte REST-API wird als sinnvoller, optionaler Adapter für
repository-lokale Skills, CI-Systeme und externe Testwerkzeuge in das Backlog
aufgenommen. Sie ersetzt weder die PowerShell-Fachlogik noch die interaktiven
Windows-, OOBE- oder Rechteerhöhungsabläufe. Öffentliche Cmdlets und die
bestehenden Zustandsverträge bleiben die fachliche Quelle der Wahrheit.

Die API wird in drei Ausbaustufen geplant:

1. read-only Discovery mit Health, Readiness, Capabilities, Katalog und Status;
2. idempotente Plan- und asynchrone Operationsabfragen;
3. ausdrücklich autorisierte Mutationen für Erstellen, Start, Stop,
   Wiederaufnahme und vollständigen Gruppen-Cleanup.

Der minimale, noch nicht implementierte Ressourcenvertrag umfasst:

```text
GET  /v1/health
GET  /v1/readiness
GET  /v1/capabilities
GET  /v1/catalog/sql-versions
GET  /v1/test-environments
POST /v1/test-environments/plan
POST /v1/test-environments
GET  /v1/operations/{operationId}
POST /v1/operations/{operationId}/resume
POST /v1/test-environments/start
POST /v1/test-environments/stop
DELETE /v1/test-environments
```

`health` weist ausschließlich nach, dass der API-Prozess antwortet.
`readiness` bewertet zusätzlich Frameworkversion, Modulimport, Katalog,
Storage-Konfiguration, Providerzugriff und die für die angeforderte Operation
notwendigen Rechte. `capabilities` veröffentlicht maschinenlesbar, welche
Provider und Funktionen auf dem aktuellen Client tatsächlich verwendbar sind.
Die drei Verträge dürfen fehlende Installation, fehlende Erreichbarkeit,
fehlende Berechtigung und erforderliche Benutzeraktion nicht zusammenfassen.

Für länger laufende Operationen liefert die API eine stabile Operation-ID und
einen persistierten Status. Windows-OOBE, UAC und andere nicht delegierbare
Schritte werden als `USER_ACTION_REQUIRED` mit einem konkreten Resume-Vertrag
gemeldet; die API versucht keine stille Rechteerhöhung. Wiederholte Requests
verwenden Idempotency-Schlüssel und dürfen keine doppelten Runs oder
Testumgebungsschlüssel erzeugen.

Die Sicherheitsgrenze lautet:

- standardmäßig ausschließlich an Loopback binden;
- keine Endpunkte für beliebige PowerShell- oder Shell-Ausführung;
- versionierte Request-, Response- und Fehlerschemas;
- keine Kennwörter, Connection Strings oder Secret-Store-Inhalte in Discovery,
  Status, Fehlern oder Logs;
- mutierende Endpunkte mit Authentisierung, Autorisierung, Preview und klarer
  Scope-Bindung;
- Remote-Bindung nur als getrenntes, ausdrücklich konfiguriertes und
  transportverschlüsseltes Betriebsmodell;
- Cleanup bleibt gruppenbezogen, recoverbar soweit der bestehende Vertrag dies
  vorsieht, und nutzt dieselben Schutzregeln wie die PowerShell-Einstiege.

Repository-Skills prüfen zuerst den eigenständigen Client-Readiness-Vertrag.
Wenn eine kompatible lokale API bereitsteht, dürfen sie diese als Transport
verwenden; andernfalls bleiben die vorhandenen PowerShell-Einstiege der
Fallback. Der Skill enthält weder kopierte REST-Schemas noch eine zweite
Parameterwahrheit, sondern ermittelt API-Version und Capabilities zur Laufzeit.

Vor mutierenden Endpunkten muss der read-only Kern automatisiert geprüft sein.
Die Abnahmekriterien dafür sind mindestens Loopback-Bindung, deterministische
Health-/Readiness-Antworten, secretfreie Logs, versionierte JSON-Schemas,
negative Authentisierungs- und Autorisierungstests sowie eindeutige Ergebnisse
für `READY`, `UNAVAILABLE`, `ELEVATION_REQUIRED` und
`USER_ACTION_REQUIRED`.

## Statische und funktionale Prüfung

Die Umsetzung soll einen lokalen statischen Einstiegspunkt
`Tests/Static/Invoke-SkillChecks.ps1` ergänzen. Er prüft mindestens:

- gültiges `SKILL.md`-Frontmatter mit eindeutigem `name` und präziser
  `description`;
- eindeutige Skill-Namen im Repository;
- vorhandene referenzierte Skripte, Dateien und Ressourcen;
- ausschließlich tatsächlich exportierte oder vorhandene Befehlseinstiege;
- erkennbare Trennung von read-only Prüfung, Setup und Mutation;
- keine eingebetteten Secrets, individuellen Hostpfade oder Runtime-Daten;
- keine widersprüchliche Parallel-Governance zu `AGENTS.md`;
- passende positive und negative Trigger-Prompts für die Skill-Beschreibung.

Der PowerShell-Readiness-Einstiegspunkt wird zusätzlich ohne aktiven Skill
getestet. So bleibt die Clientdiagnose auch dann ausführbar, wenn die
Skill-Erkennung selbst gestört ist.

## Abnahmekriterien

- Ein frischer Checkout stellt die Skills aus der Repository-Wurzel ohne
  persönliche Kopie bereit.
- Die dokumentierte manuelle PowerShell-Readiness-Prüfung funktioniert ohne
  geladenen Skill und verändert weder Host noch Runtime.
- Der Readiness-Skill liefert für verfügbare, fehlende, nicht erreichbare und
  nicht berechtigte Werkzeuge unterscheidbare strukturierte Ergebnisse.
- `Validation` verwendet dieselbe impact-basierte Testauswahl wie der
  bestehende Projektvertrag und bezeichnet `SKIP` oder `NOT_EXECUTED` nicht als
  bestanden.
- `Operate` ermittelt aktuelle Cmdlet-Parameter aus dem Modul und besitzt keine
  kopierte, unabhängig driftende Parameterspezifikation.
- Der optionale REST-Adapter delegiert an dieselben öffentlichen Fachverträge,
  bleibt standardmäßig lokal und veröffentlicht keine Secrets über Discovery-
  oder Operationsantworten.
- Statische Dokumentations-, Privacy- und Skill-Prüfungen sind lokal
  ausführbar und Teil der betroffenen Check-Auswahl.

## Nichtziele und aktuelle Grenze

Dieses Dokument startet keine Implementierung und weist keinen Skill oder
Readiness-Check als vorhanden oder validiert aus. Es erweitert weder die
unterstützten SQL-Server-/Providerkombinationen noch die Autorisierung für
Host-, Runtime-, Cleanup- oder Recovery-Mutationen.

Die Einordnung in eine neue kanonische Entwicklungswelle erfolgt separat nach
dem abgeschlossenen Horizont N1 bis N5. Innerhalb einer später autorisierten
Skill-Welle bleibt die Reihenfolge `Readiness`, danach `Validation` und
`Operate` verbindlich.
