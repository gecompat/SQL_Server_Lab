# Projektintegrationsvertrag

| Merkmal | Wert |
|---|---|
| Status | `DRAFT_REQUIRED` |
| Vertragsversion | `0.1` |
| Stand | 2026-07-26 |
| Konsumenten | `SQL_Server_Analyze`, `SQL_PerformanceSchulung`, spätere kompatible Projekte |

## 1. Zweck

Dieser Vertrag definiert die technische und organisatorische Grenze zwischen `SQL_Server_Lab` und konsumierenden Projekten. Er verhindert, dass Provider-, Lifecycle- oder Fault-Injection-Logik erneut in jedem Repository separat entsteht.

## 2. Grundsatz

`SQL_Server_Lab` stellt die Umgebung her. Das konsumierende Projekt stellt den fachlichen Inhalt bereit.

```text
SQL_Server_Lab
  ├─ Host-Preflight
  ├─ Topologie
  ├─ Provider
  ├─ Lifecycle
  ├─ Ressourcen- und Fault-Profile
  ├─ State, Secrets und Cleanup-Grenzen
  └─ generische Evidenzhülle

Konsumierendes Projekt
  ├─ Installations-/Updateartefakte
  ├─ synthetische Fachdaten
  ├─ Demo- oder Analyseablauf
  ├─ Beobachtung
  ├─ fachliche Assertions
  ├─ Aussagegrenzen
  └─ projektspezifisches Cleanup
```

## 3. Aufrufmodelle

### 3.1 Lokaler Sibling-Checkout

Empfohlener Entwicklungsmodus:

```text
<Workspace>/
├── SQL_Server_Lab/
├── SQL_Server_Analyze/
└── SQL_PerformanceSchulung/
```

Der Aufrufer übergibt den lokalen Projektpfad explizit. Kein realer lokaler Pfad wird in ein versioniertes Manifest geschrieben.

### 3.2 Freigegebenes Projektpaket

Ein konsumierendes Projekt kann später ein privacy-geprüftes, versionsgebundenes Paket bereitstellen. Das Lab prüft Hash, Vertragsversion und erwartete Entrypoints, übernimmt aber nicht die Lizenzverantwortung des Pakets.

### 3.3 Git-Submodule

Git-Submodule sind nicht der Standard. Sie koppeln Releasezyklen und erschweren Einsteiger-Workflows. Ein Projekt darf sie lokal verwenden, sofern der öffentliche Adaptervertrag davon unabhängig bleibt.

## 4. Project Adapter

### 4.1 Pflichtfelder

```json
{
  "ContractVersion": "0.1",
  "ProjectId": "EXAMPLE_PROJECT",
  "DisplayName": "Example Project",
  "SupportedLabContractVersions": ["0.1"],
  "SupportedSqlVersions": [2019, 2022, 2025],
  "RequiredCapabilities": [],
  "Entrypoints": {
    "Preflight": "relative/path",
    "Install": "relative/path",
    "Update": "relative/path",
    "Observe": "relative/path",
    "Validate": "relative/path",
    "Cleanup": "relative/path"
  },
  "ScenarioCatalog": "relative/path",
  "SecretInputs": [],
  "ProducedLocalArtifacts": [],
  "DataClassification": "SYNTHETIC_ONLY",
  "PrivacyExportPolicy": "NO_AUTOMATIC_EXPORT",
  "KnownLimitations": []
}
```

Das Beispiel ist ein Vertragsentwurf, kein endgültiges Schema.

### 4.2 Pfadregeln

- Adapterpfade sind relativ zum explizit gebundenen Projektroot.
- `..`-Pfadtraversierung ist unzulässig.
- Symbolische Links oder Junctions außerhalb des gebundenen Projektroots werden abgelehnt.
- Entrypoints dürfen keine absoluten Hostpfade voraussetzen.
- Das Lab übergibt Runtimeinformationen über einen lokalen Run Context, nicht durch Änderungen am Projektmanifest.

### 4.3 Ausführungsregeln

- Entrypoints werden nur für den ausgewählten Adapter aufgerufen.
- `Preflight` muss read-only sein.
- `Install` und `Update` dürfen nur die registrierten Labinstanzen verändern.
- `Observe` darf technische Laufzeitwerte lokal ausgeben, aber nicht automatisch versionieren oder übertragen.
- `Validate` liefert strukturierte Statuscodes und keine unkontrollierten Freitextbehauptungen.
- `Cleanup` darf ausschließlich projektbezogene, markierte Objekte innerhalb des Labscopes entfernen.

## 5. Run Context

Das Lab stellt jedem Project Adapter einen lokalen, nicht versionierten Run Context bereit. Er enthält mindestens:

- `LabRunId`;
- Vertragsversionen;
- ausgewählte SQL-Server-Versionen;
- logische Instanzrollen;
- lokale Verbindungsendpunkte;
- Secret-Referenzen, niemals Secret-Werte in persistierter Ausgabe;
- Datenbank- und Markerpräfixe;
- Timeouts;
- Artefaktpfade innerhalb des lokalen Run-Scope;
- Capability-Vektor;
- Safety Class;
- Cleanup- und Abbruchsignale.

Der Adapter darf keine eigene konkurrierende Run-ID erzeugen. Projektspezifische Tokens werden von der Lab-Run-ID abgeleitet oder im Run Context registriert.

## 6. Szenariozuordnung

Ein Project Adapter kann:

1. einen eigenen Szenariokatalog bereitstellen;
2. ein generisches Lab-Szenario referenzieren und nur fachliche Entrypoints ergänzen;
3. ein Basisszenario über klar definierte Extension Points erweitern.

Direktes Überschreiben providerbezogener Schritte durch ein Projekt ist unzulässig.

## 7. Integration `SQL_Server_Analyze`

### 7.1 Eigentum des Analyze-Repositories

- Frameworkinstaller;
- Frameworkupdate;
- Analyzer-Aufrufe;
- erwartete Findings, Status- und Resultsetverträge;
- analyserspezifische Szenariodaten;
- Berechtigungs- und Versionsprüfungen;
- projektspezifische Dokumentation.

### 7.2 Eigentum des Lab-Repositories

- Container-/VM-Bereitstellung;
- SQL-Bereitschaft;
- Netzwerk-, I/O-, CPU- und Memory-Profile;
- Lifecycle und Cleanup;
- Secret- und State-Verwaltung;
- Host-Capability-Ermittlung;
- generische Scenario Engine.

### 7.3 Zieladapter

Vorgesehene Adapter-ID:

```text
SQL_SERVER_ANALYZE
```

Der Adapter soll mindestens folgende Entrypoints anbieten:

- `PreflightFramework`;
- `InstallFramework`;
- `UpdateFramework`;
- `ObserveAnalyzer`;
- `ValidateFindingContract`;
- `CleanupFrameworkArtifacts`.

`UpdateFramework` darf keine Container oder VMs starten, stoppen, ersetzen oder neu konfigurieren.

## 8. Integration `SQL_PerformanceSchulung`

### 8.1 Eigentum des Schulungsrepositories

- Demo-ID und Lernziel;
- synthetische Datenmodelle;
- Preflight der Demo;
- Setup, Baseline, Demonstration, Observation, Mitigation, Comparison und Cleanup;
- Multi-Session-Steuerung;
- erwartete Invarianten und Messrichtungen;
- didaktische und fachliche Dokumentation;
- Sicherheitsstufe Grün, Gelb oder Rot.

### 8.2 Eigentum des Lab-Repositories

- isolierte Instanz oder Topologie;
- Ressourcen- und Fault-Profile;
- Host- und Provider-Preflight;
- Lifecycle und Reset;
- Wegwerfbarriere für rote Demos;
- Laufzeitbudget und externe Abbruchsignale;
- lokale technische Evidenzhülle.

### 8.3 Zieladapter

Vorgesehene Adapter-ID:

```text
SQL_PERFORMANCE_SCHULUNG
```

Die Demo-Phasen werden auf die Scenario Engine abgebildet:

| Schulungsphase | Lab-Phase |
|---|---|
| Demo-Preflight | Adapter-Preflight innerhalb des bereits erfolgreichen Host-Preflights |
| Setup | `Arrange` |
| Baseline | `Observe` mit Baseline-Kennzeichnung |
| Demonstration | `Act` |
| Observation | `Observe` |
| Mitigation | optionaler zweiter `Act` |
| Comparison | `Assert` und Vergleichsevidenz |
| Cleanup | `Cleanup` |

## 9. Status- und Fehlervertrag

Project Adapter liefern strukturierte Codes. Mindestens:

```text
ADAPTER_READY
ADAPTER_UNSUPPORTED_CONTRACT
ADAPTER_PREFLIGHT_FAILED
ADAPTER_INSTALL_FAILED
ADAPTER_UPDATE_FAILED
ADAPTER_OBSERVE_FAILED
ADAPTER_VALIDATION_FAILED
ADAPTER_CLEANUP_FAILED
ADAPTER_ARTIFACT_SCOPE_VIOLATION
ADAPTER_SECRET_POLICY_VIOLATION
ADAPTER_PARTIAL_SUCCESS
```

Konsolentexte dürfen lokalisiert werden. Codes bleiben unverändert in englischer Großschreibung.

## 10. Safety-Class-Mapping

| Lab-Klasse | Bedeutung |
|---|---|
| `SAFE_READ_ONLY` | keine Mutation |
| `LAB_MUTATION` | lokale synthetische Daten oder Labobjekte werden verändert |
| `RESOURCE_PRESSURE` | kontrollierte CPU-, RAM-, I/O-, Log-, TempDB- oder Concurrency-Last |
| `INSTANCE_CHANGE` | Instanzkonfiguration, Cache, Dienst oder serverweiter Zustand wird verändert |
| `INFRASTRUCTURE_CHANGE` | VM, Netzwerk, Storage oder Providerzustand wird verändert |
| `DESTRUCTIVE_DISPOSABLE` | Datenverlust oder beschädigter Zustand ist beabsichtigt; wegwerfbarer Scope erforderlich |

Mapping der Schulungsstufen:

- Grün → `LAB_MUTATION` oder niedriger;
- Gelb → `RESOURCE_PRESSURE`;
- Rot → mindestens `INSTANCE_CHANGE`, häufig `INFRASTRUCTURE_CHANGE` oder `DESTRUCTIVE_DISPOSABLE`.

## 11. Datenschutzgrenze

- Project Adapter dürfen reale lokale Laufzeitwerte empfangen, wenn sie für die lokale Diagnose erforderlich sind.
- Diese Werte dürfen nicht automatisch in Repositoryartefakte, Issues, PRs, Screenshots, Tests oder exportierte Beispiele übernommen werden.
- Eine sanitisierte Summary wird getrennt erzeugt.
- Secret-Werte sind auch im lokalen technischen Evidence-JSON unzulässig.
- Das Lab darf keine fremden Projektdateien ungefragt ändern.

## 12. Vertragsversionierung

- `0.x`: Draftphase; Breaking Changes mit Migrationshinweis zulässig.
- `1.0`: erste stabile Version nach produktiver Abnahme beider Primäradapter.
- Adapter geben unterstützte Lab-Contract-Versionen explizit an.
- Unbekannte Major-Versionen werden abgelehnt.
- Neue optionale Felder sind minor-kompatibel.
- Semantische Änderungen bestehender Pflichtfelder erfordern eine neue Major-Version.

## 13. Abnahmekriterien

Der Integrationsvertrag ist umgesetzt, wenn:

1. beide Primärprojekte über Adapter ohne Providerwissen angebunden sind;
2. das Lab keine fachlichen Findings oder Schulungsaussagen besitzt;
3. die Projekte keine generische Provider- oder Lifecycle-Logik duplizieren;
4. Adapterpfade scope-sicher aufgelöst werden;
5. Statuscodes maschinenlesbar und sprachunabhängig sind;
6. lokale Runtimewerte und versionierbare Summaries getrennt sind;
7. ein Projektupdate keine Infrastrukturmutation auslöst;
8. ein Adapterfehler Cleanup nicht verhindert;
9. Vertragsversionen kontrolliert geprüft werden;
10. die Integration ohne Git-Submodule funktioniert.
