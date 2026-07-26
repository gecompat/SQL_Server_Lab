# Manifest- und Schnittstellenarchitektur

| Merkmal | Wert |
|---|---|
| Status | `DRAFT_REQUIRED` |
| Vertragsfamilie | `SQL_SERVER_LAB_CONTRACTS` |
| Zielversion | `0.1` |
| Stand | 2026-07-26 |

## 1. Ziel

Dieses Dokument legt fest, welche maschinenlesbaren Verträge das Lab benötigt und wie sie zusammenspielen. Die endgültigen JSON-Schemas werden in Welle 1 aus diesem Dokument abgeleitet.

## 2. Prinzipien

1. **Logisch vor providerbezogen:** Szenarien und Topologien beschreiben Anforderungen, nicht konkrete Docker- oder Hyper-V-Befehle.
2. **Keine Secrets in Manifesten:** Manifeste enthalten nur Secret-Namen oder Providerreferenzen.
3. **Keine realen Hostdaten:** Pfade, Hostnamen, IP-Adressen und Gerätekennungen werden lokal gebunden.
4. **Strikte Schemas:** `additionalProperties` ist standardmäßig `false`.
5. **Explizite Versionierung:** Jedes Manifest enthält `ContractVersion`.
6. **Stabile Codes:** IDs, Status- und Capability-Codes bleiben englisch und werden nicht übersetzt.
7. **Synthetische Defaults:** Beispielmanifeste verwenden ausschließlich generische, nicht produktive Werte.
8. **Plan vor Mutation:** Aus jedem gültigen Run Request muss ein read-only Mutationsplan erzeugbar sein.

## 3. Vertragsfamilie

### 3.1 `lab-request.schema.json`

Beschreibt einen konkreten Lauf.

Pflichtfelder:

- `ContractVersion`;
- `RequestId`;
- `Mode`;
- `ProviderPreference`;
- `SqlVersions`;
- `ResourceProfileId`;
- `PersistenceMode`;
- `ProjectAdapterRef` optional;
- `ScenarioRefs` optional;
- `TopologyRef` optional;
- `AllowedOverrides`;
- `SafetyAcknowledgement`;
- `OutputPolicy`.

`RequestId` ist synthetisch und darf nicht aus Benutzer-, Host- oder Firmennamen abgeleitet werden.

### 3.2 `project-adapter.schema.json`

Beschreibt die Kopplung zu einem konsumierenden Projekt. Details stehen im Projektintegrationsvertrag.

### 3.3 `scenario.schema.json`

Beschreibt fachliche Phasen und Erwartungen.

Pflichtfelder:

- `ScenarioId`;
- `Title`;
- `Purpose`;
- `EvidenceClass`;
- `SupportedSqlVersions`;
- `RequiredCapabilities`;
- `TopologyRef`;
- `ResourceProfileRef`;
- `FaultProfileRefs`;
- `SafetyClass`;
- `Arrange`;
- `Act`;
- `Observe`;
- `Assert`;
- `Cleanup`;
- `Timeouts`;
- `AlternativeEvidence`;
- `DataClassification`;
- `KnownLimitations`.

### 3.4 `topology.schema.json`

Beschreibt logische Ressourcen.

Pflichtfelder:

- `TopologyId`;
- `Nodes`;
- `Networks`;
- `StorageRoles`;
- `Relations`;
- `RequiredCapabilities`;
- `DefaultProviderMappings`;
- `CleanupBoundary`.

Ein Node enthält Rollen, Betriebssystemfamilie, SQL-Version, Editionanforderung, Agentanforderung, Authentication-Capabilities und Ressourcenreferenzen. Er enthält keine reale IP-Adresse.

### 3.5 `resource-profile.schema.json`

Trennt Host- und SQL-Ressourcen:

- Hostreserve;
- Container- oder VM-CPU;
- Container- oder VM-RAM;
- SQL `max server memory`;
- Storage-Budgets;
- Parallelitätsgrenze;
- Startreihenfolge;
- Warn- und Ablehnungsgrenzen.

### 3.6 `fault-profile.schema.json`

Beschreibt einen reversiblen Fault:

- `FaultProfileId`;
- `FaultClass`;
- `TargetRole`;
- `RequiredCapabilities`;
- `Parameters`;
- `MaximumDurationSeconds`;
- `HardLimits`;
- `ActivationSignal`;
- `RollbackAction`;
- `RollbackVerification`;
- `SafetyClass`.

### 3.7 `capability.schema.json`

Normalisiert Host- und Providerfähigkeiten:

- `CapabilityCode`;
- `Status`: `AVAILABLE`, `UNAVAILABLE`, `UNKNOWN`, `BLOCKED`;
- `Scope`;
- `Provider`;
- `EvidenceSource` lokal;
- `StatementBoundary`;
- `Sanitizable`.

### 3.8 `evidence.schema.json`

Trennt lokale technische Evidenz und sanitisierte Summary.

Gemeinsame Felder:

- Vertragsversionen;
- Run-ID;
- Scenario-ID;
- Providerklasse;
- SQL-Server-Major-Version;
- Start- und Endzeit;
- Statuscodes;
- Phasenstatus;
- aggregierte Messwerte;
- Assertionsergebnisse;
- Aussagegrenzen;
- Cleanupstatus.

Unzulässig:

- Secrets;
- vollständige Connection Strings;
- reale Hostnamen, Benutzer, E-Mail-Adressen oder lokale Pfade in einer exportierbaren Summary;
- ungeprüfte Querytexte, Pläne, Logs oder Event-Payloads.

## 4. IDs und Namensräume

### 4.1 Projekt-IDs

```text
SQL_SERVER_LAB
SQL_SERVER_ANALYZE
SQL_PERFORMANCE_SCHULUNG
```

### 4.2 Szenario-IDs

Empfohlenes Schema:

```text
<OWNER>-<DOMAIN>-<NUMBER>
```

Beispiele:

```text
LAB-CORE-001
LAB-INFRA-001
ANALYZE-CONC-001
SQLPERF-OPT-002
```

Bestehende stabile IDs der konsumierenden Projekte werden nicht ohne fachlichen Grund umbenannt.

### 4.3 Topologie-IDs

```text
TOPO-CTR-SINGLE
TOPO-CTR-MULTIVERSION
TOPO-HV-WIN-SINGLE
TOPO-HV-LINUX-SINGLE
TOPO-HV-WSFC-THREENODE
TOPO-DIST-WIN-LINUX
```

### 4.4 Capability-Codes

Beispiele:

```text
CONTAINER_DOCKER
CONTAINER_PODMAN
COMPOSE_AVAILABLE
HYPERV_AVAILABLE
WINDOWS_GUEST_SUPPORTED
LINUX_GUEST_SUPPORTED
SQL2019_IMAGE_AVAILABLE
SQL2022_IMAGE_AVAILABLE
SQL2025_IMAGE_AVAILABLE
NETWORK_NETEM
BLOCK_IO_THROTTLE
DEDICATED_FAULT_VOLUME
POWERSHELL_DIRECT
WINDOWS_AUTHENTICATION
SQL_AGENT_FULL
WSFC_SUPPORTED
```

Codes beschreiben Fähigkeit, nicht Produktqualität.

## 5. Auflösungsreihenfolge

Der Planner arbeitet in folgender Reihenfolge:

1. Schema und Vertragsversion des Run Requests prüfen;
2. Project Adapter auflösen;
3. Szenarien und Abhängigkeiten auflösen;
4. Topologie bestimmen;
5. Ressourcen- und Fault-Profile auflösen;
6. Host-Capabilities read-only ermitteln;
7. Providerkandidaten bewerten;
8. fehlende Capabilities und Alternativ-Evidenz bestimmen;
9. Scope-, Pfad-, Port-, Medien- und Secret-Bindings lokal prüfen;
10. Mutationsplan erzeugen;
11. Safety- und Lizenzbestätigungen prüfen;
12. erst danach Mutation zulassen.

## 6. Override-Regeln

Overrides werden klassifiziert:

| Klasse | Beispiel | Regel |
|---|---|---|
| `SAFE_RUNTIME` | Port, lokaler Zielroot | lokal zulässig, nicht versioniert |
| `RESOURCE_WITHIN_BOUNDS` | CPU/RAM innerhalb Szenariogrenzen | Planner prüft Hostreserve |
| `SEMANTIC` | andere SQL-Version | nur wenn Szenario dies unterstützt |
| `SAFETY_RELEVANT` | längere Stressdauer, größere Fault-Grenze | explizite Bestätigung und Szenariolimit |
| `FORBIDDEN` | Systempfad, fremdes Netzwerk, produktiver Endpoint | immer ablehnen |

Ein Override darf keine Capability vortäuschen.

## 7. Planformat

Ein read-only Plan soll mindestens enthalten:

- ausgewählter Provider;
- aufgelöste Vertragsversionen;
- logische und konkrete Ressourcenanzahl;
- geschätztes CPU-, RAM- und Storage-Budget;
- Hostreserve nach dem Plan;
- Ports und Bindungsart ohne Secret;
- lokale Zielrollen, ohne exportierbare reale Pfade;
- Images oder lokale Medienreferenzen;
- Project Adapter und Entrypoints;
- Szenariophase und Timeouts;
- Faults, Dauer und Rücknahme;
- destruktive Aktionen;
- Cleanupgrenze;
- Warnungen, `NOT_EXECUTED`-Teile und Aussagegrenzen.

Der Plan besitzt eine lokale technische Form und eine sanitisierte Anzeigeform.

## 8. Provider-Mapping

Provider-Mappings dürfen nur technische Umsetzung enthalten.

Beispiel:

```text
Logical Node: SQL_PRIMARY
  Docker  -> Container + Volume + Bridge Network
  Podman  -> Container + Volume + Podman Network
  Hyper-V -> VM + VHDX Roles + Virtual Switch
```

Das Szenario darf nicht direkt `docker run`, `podman run` oder `New-VM` enthalten.

## 9. Phasenvertrag

Jede Phase beschreibt:

- `Entrypoint` oder generische `Action`;
- `CompletionSignal`;
- `TimeoutSeconds`;
- `FailurePolicy`;
- `CanRetry`;
- `ProducesArtifacts`;
- `RequiresCleanup`.

### 9.1 `Arrange`

Stellt synthetische Daten, Konfiguration und Startzustand her.

### 9.2 `Act`

Erzeugt den kontrollierten Effekt. Ressourcenlast benötigt positive Dauer- und Abbruchgrenzen.

### 9.3 `Observe`

Erfasst Evidenz im kleinstmöglichen Scope. Eine Beobachtung verändert den Fachzustand nicht, außer dies ist explizit als Teil des Messverfahrens dokumentiert.

### 9.4 `Assert`

Prüft Status, Invarianten, Richtungen, Verhältnisse, Findings oder zulässige Alternativen. Hardwareabhängige absolute Zeitwerte sind nicht der Standard.

### 9.5 `Cleanup`

Wird nach begonnenem `Arrange` unabhängig vom Ergebnis versucht. Cleanupfehler haben höhere Priorität als ein vorheriger fachlicher Erfolg.

## 10. Ergebnispriorität

Vorgeschlagene Priorität:

```text
RECOVERY_REQUIRED
FAIL
NOT_EXECUTED_REQUIRED
WARN
SKIP_OPTIONAL
PASS
```

Ein `PASS` ist nur zulässig, wenn erforderliches Cleanup erfolgreich war.

## 11. Lokalisierung

- JSON-Feldnamen, IDs, Status- und Capability-Codes bleiben englisch.
- Benutzertexte dürfen lokalisiert werden.
- Die kanonische technische Dokumentation ist Deutsch.
- Code, T-SQL-Identifier, PowerShell-Parameter und externe Produktbegriffe werden nicht übersetzt.
- Die Lizenz besitzt eine englische Masterfassung; Übersetzungen sind informativ.

## 12. Abnahmekriterien für Welle 1

1. Alle Schemas sind Draft 2020-12 oder eine bewusst dokumentierte spätere Version.
2. Beispiele validieren gegen die Schemas.
3. `additionalProperties` ist standardmäßig `false`.
4. Kein Beispiel enthält ein funktionsfähiges Secret.
5. Ein Run Request kann vollständig bis zum read-only Plan aufgelöst werden.
6. Ein fehlender Provider erzeugt einen strukturierten Status.
7. Ein unbekannter Major-Vertrag wird abgelehnt.
8. Overrides können keine Capability- oder Safety-Grenzen umgehen.
9. lokale und exportierbare Evidenz sind getrennt.
10. beide Primäradapter lassen sich ohne Providerwissen modellieren.
