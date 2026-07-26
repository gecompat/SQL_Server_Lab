# Sprach-, Übersetzungs- und Schreibstandard

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-26 |
| Primärsprache | Deutsch |
| Technische Vertragssprache | Englisch für Feldnamen, IDs, Codes und API-Bezeichner |
| Lizenz-Master | Englisch in `LICENCE.md` |

## 1. Sprachziel

Dokumentation und Benutzerführung verwenden sachliche, präzise und technisch überprüfbare Sprache. SQL Server bleibt fachlicher Mittelpunkt. Zusätzliche Technologien werden immer über ihren SQL-Server-Zweck eingeordnet.

Projekt- und Dokumentationssprache ist Deutsch. Etablierte englische Fachbegriffe bleiben in ihrer üblichen Form erhalten. Ungebräuchliche wörtliche Übersetzungen werden vermieden.

Beispiele etablierter Begriffe:

- `SQL Server`;
- `Execution Plan`;
- `Query Store`;
- `Extended Events`;
- `Container`;
- `Provider`;
- `Component`;
- `Supporting Component`;
- `Action Handler`;
- `Runtime Binding`;
- `Workflow`;
- `Fault Injection`;
- `Healthcheck`;
- `Cleanup`;
- `State`;
- `Evidence`.

## 2. Aussageklassen

| Klasse | Bedeutung | Kennzeichnung |
|---|---|---|
| `DOKUMENTIERT` | durch Primärquelle oder verbindlichen Projektvertrag belegt | „Dokumentiert: …“ |
| `EMPIRISCH` | unter benannten Labbedingungen gemessen | „Empirisch im beschriebenen Laborszenario: …“ |
| `ENTSCHEIDUNG` | verbindliche Architektur- oder Projektfestlegung | „Entscheidung: …“ |
| `METHODE` | Diagnose-, Mess-, Planungs- oder Ausführungsablauf | „Methode: …“ |
| `INFERENZ` | aus mehreren belegten Fakten hergeleitet | „Inferenz: …“ |
| `VERMUTUNG` | noch nicht bestätigte Hypothese | „Vermutung: …; zu prüfen durch …“ |
| `BEISPIEL` | synthetische Veranschaulichung | „Beispiel: …“ |

Ein einzelner Messwert wird nicht als allgemeine SQL-Server-Produkteigenschaft oder universeller Schwellenwert dargestellt.

## 3. Technische Gültigkeitsangaben

Versionen und Voraussetzungen werden getrennt genannt:

- SQL-Server-Version;
- Betriebssystemfamilie;
- Provider;
- Edition;
- Compatibility Level;
- Required Capabilities;
- Ressourcenprofil;
- Fault- oder Netzwerkkonfiguration;
- Evidence Class.

Beispiel:

```text
SQL Server 2022; Linux-Container; Docker Engine; Compatibility Level 160; Resource Profile Standard.
```

## 4. Verbindliche Begriffe

### 4.1 Architektur

| Begriff | Bedeutung |
|---|---|
| `SQL Server Lab Package` | versionierter Verbund aus `SqlPurpose`, Environment, Content, DataSets und Workflow |
| `SqlPurpose` | fachlicher SQL-Server-Zweck eines Packages oder Runs |
| `Primary SQL Component` | SQL-Server-Instanz oder SQL-Topologie im Zentrum des Szenarios |
| `Supporting Component` | Hilfssystem mit dokumentiertem SQL-Bezug, beispielsweise Domain Controller oder Hadoop für PolyBase |
| `Environment Blueprint` | logischer gewünschter Aufbau ohne reale Hostbindings |
| `Component Type` | versionierter Typvertrag einer Component |
| `Composite Component` | Component, die in mehrere Components expandiert wird |
| `Action Type` | typisierte ausführbare Aktion |
| `Action Handler` | Implementierung eines Action Type |
| `Deployment Unit` | Installation oder Konfiguration innerhalb einer Component |
| `DataSet` | verifizierbarer Vertrag für synthetische Testdaten |
| `Workflow Step` | typisierte Aktion im Ausführungsgraphen |
| `Runtime Binding` | lokal erzeugte typisierte Verbindung zwischen Outputs und Inputs |
| `Bound Plan` | vollständig aufgelöster read-only Ausführungs- und Mutationsplan |
| `Run State` | lokaler Istzustand mit tatsächlichen Ressourcen-IDs |
| `Provider` | technische Bereitstellung über Hyper-V, Docker oder Podman |
| `Capability` | nachgewiesene Fähigkeit mit Scope und Aussagegrenze |
| `Control Plane` | serialisierbare Commands, Operations, Events und Results |

### 4.2 Lifecycle

| Begriff | Bedeutung |
|---|---|
| `Preflight` | read-only Prüfung vor Planung oder Mutation |
| `Plan` | read-only Auflösung geplanter Änderungen |
| `Up` | Bereitstellung geplanter Ressourcen |
| `Apply` | Installation oder Konfiguration von Package-Inhalten |
| `Run` | Ausführung eines SQL-Szenarios |
| `Observe` | Erhebung definierter Evidenz |
| `Validate` | Prüfung von Contracts und Assertions |
| `Stop` | Stoppen ohne Entfernung |
| `Start` | Start registrierter vorhandener Ressourcen |
| `Restart` | Stop und Start ohne Identitätswechsel |
| `Reset` | Wiederherstellung eines definierten synthetischen Zustands |
| `Down` | Entfernung von Runtime-Ressourcen bei erhaltener freigegebener Basis |
| `Destroy` | vollständige Entfernung des registrierten Labscopes |
| `Cleanup` | fachliche und technische Bereinigung |
| `Compensation` | Rücknahme einer registrierten Mutation |
| `Recovery` | Pfad nach unvollständiger Rücknahme |

Diese Begriffe werden nicht synonym verwendet.

### 4.3 Status

```text
PASS
WARN
SKIP_OPTIONAL
NOT_EXECUTED
UNSUPPORTED
FAIL
RECOVERY_REQUIRED
```

Statuscodes bleiben englisch und werden nicht übersetzt.

## 5. Schreibregeln

Ein technischer Abschnitt folgt nach Möglichkeit:

1. SQL-Zweck oder beobachtbarer Sachverhalt;
2. technischer Mechanismus;
3. Inputs und Voraussetzungen;
4. Outputs und Evidenz;
5. Safety-, Privacy- und Ressourcenwirkung;
6. Grenzen;
7. Cleanup oder nächste Prüfung;
8. Abnahmekriterien.

Weitere Regeln:

- vollständige Sätze;
- klare Abgrenzung zwischen implementiert, geplant und empirisch geprüft;
- Parameter, IDs, Pfade und Codebezeichner in Backticks;
- keine erfundenen Befehle als implementiert darstellen;
- Destruktivität und Rechte sichtbar nennen;
- Supporting Components immer über ihren SQL-Zweck erklären;
- keine allgemeine Produktbeschreibung für Hadoop, REST oder Active Directory ohne SQL-Bezug.

## 6. Unzulässige Pauschalformulierungen

Ohne Voraussetzungen und Evidenz unzulässig:

- „funktioniert überall“;
- „providerunabhängig“, wenn nur ein Provider geprüft wurde;
- „identische Performance“;
- „realistische Hardwareemulation“ ohne Capability-Nachweis;
- „sicher“ ohne Scope-, State- und Cleanup-Vertrag;
- „idempotent“ ohne Zustandsdefinition;
- „vollständig bereinigt“ ohne Prüfung registrierter Ressourcen;
- „REST-kompatibel“, wenn nur Konsolentext vorhanden ist;
- „Cluster unterstützt“, wenn nur einzelne Nodes modelliert wurden;
- „Open Source“ für dieses Repository.

## 7. Code-, Schema- und API-Sprache

Englisch bleiben:

- JSON-Feldnamen;
- Component-, Action-, Capability- und Statuscodes;
- PowerShell-Funktions- und Parameternamen;
- CLI-Commands;
- Event Types;
- API-Routen und Payloadfelder;
- T-SQL- und Produktbezeichner;
- maschinenlesbare Contract-Dateinamen.

Erklärende Dokumentation ist Deutsch.

## 8. Übersetzungsregeln

### 8.1 Maßgebliche Fassungen

- `LICENCE.md`: Englisch ist rechtlich maßgebliche Masterfassung.
- JSON-, API- und Codeverträge: englische Feldnamen und Codes sind maßgeblich.
- Projektdokumentation: deutsche Fassung ist kanonisch, sofern nicht anders angegeben.

### 8.2 Keine semantische Änderung

Eine Übersetzung darf nicht:

- Rechte, Pflichten oder Garantien verändern;
- Safety- oder Privacy-Grenzen abschwächen;
- Versionsbedingungen verändern;
- Statuscodes oder IDs übersetzen;
- aus einer Vermutung eine dokumentierte Aussage machen;
- aus einer geplanten Funktion eine implementierte Funktion machen.

### 8.3 Übersetzungsparität

Eine Übersetzung nennt:

- Quellpfad;
- Quellversion oder Hash;
- Übersetzungsstand;
- maßgebliche Sprache;
- bekannte nicht übersetzte Abschnitte.

Nach Änderung der Quelle gilt die Übersetzung bis zur Aktualisierung als `OUTDATED_TRANSLATION`.

### 8.4 Glossar

Wiederkehrende Begriffe werden später in einem zentralen Glossar gepflegt. Automatische Übersetzungen gelten ohne fachliche Prüfung nicht als abgenommen.

## 9. Dokumentationsstatus

```text
DRAFT
ARCHITECTURE_DECISION_DRAFT
REQUIRED
BINDING
IMPLEMENTED_PARTIAL
IMPLEMENTED
VALIDATED
DEPRECATED
RETIRED
OUTDATED_TRANSLATION
```

Ein Planungsdokument ist kein Runtime-Nachweis.

## 10. Quellenstandard

Bevorzugt werden Primärquellen:

- Microsoft Learn;
- offizielle Docker-, Podman-, PowerShell- und Hyper-V-Dokumentation;
- Standards und Spezifikationen;
- offizielle Release Notes;
- Originalrepositories und deren Dokumentation.

Projektinterne Entscheidungen verweisen auf das maßgebliche Dokument.

## 11. Abnahmekriterien

- Dokumentation ist deutsch und technisch präzise.
- etablierte englische Fachbegriffe bleiben erhalten.
- Codes, IDs und API-Felder werden nicht übersetzt.
- SQL Server bleibt in jeder fachlichen Erklärung zentral.
- Supporting Components werden nur über SQL-Zwecke beschrieben.
- Aussageklasse, Version, Provider und Grenzen sind erkennbar.
- Übersetzungen verändern keine Semantik.
