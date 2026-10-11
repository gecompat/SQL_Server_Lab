# Kontrollierte Labidentitäten und plattformübergreifende Dateisystem-Fixtures – Backlog

| Merkmal | Wert |
|---|---|
| Status | `PLANNED` |
| Stand | 2026-10-11 |
| Zweck | synthetische OS-/SQL-Identitäten für automatisierte Tests, manuelle Schulungen und Rekonstruktionsszenarien; optional kombinierbare Dateisystem-Fixtures auf ausgewählten SQL-Labzielen |
| Nächster Schritt | [FSF-01-Architekturentwurf](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md) abstimmen; danach Capability-Modell, Fixture-Handle, Ownership/Cleanup, Sicherheitsmodell und Teststrategie einzeln ausarbeiten und abstimmen |
| Implementierungsfreigabe | `PENDING`; erst nach ausdrücklicher Einzelfreigabe aller sechs Entwurfsbereiche |
| Autorität | Backlogaufnahme; keine Implementierungs-, Provider-, Identitäts-, Dateisystem- oder Löschfreigabe |

## Ausgangslage und Ziel

Konsumierende Projekte und Operatoren benötigen reproduzierbare synthetische
Identitäten für automatisierte Tests sowie manuelle SQL-Schulungen,
Demonstrationen und Rekonstruktionsszenarien mit unterschiedlichen Benutzern.
`SQL_PerformanceSchulung` ist ausdrücklich als Bedarfsträger benannt.
Dateisystemstrukturen werden je nach Szenario zusätzlich benötigt. Das Lab soll
deren kontrollierte Bereitstellung und sicheren Rückbau übernehmen, damit
jedes Projekt keine eigenen Betreiber-Skripte, VM-Admin-Zugänge oder
Container-Root-Zugänge verwalten muss.

Die geplante Fixture-Schnittstelle bereitet ausschließlich innerhalb bereits
laufender, ausdrücklich ausgewählter `READY`-Testziele synthetische Ressourcen
vor. Sie dokumentiert deren Eigentümerzustand und begrenzten Lebenszyklus und
entfernt ausschließlich nachweislich selbst erzeugte Ressourcen.

Die Benutzeranlage soll auch eigenständig ohne Dateisystem-Fixture,
Testexecutor oder `SQL_Server_Toolbelt` möglich sein. Der am 2026-10-11
präzisierte Benutzerscope umfasst ausdrücklich beides mit getrennten Verträgen:
lokale Windows-/Linux-OS-Identitäten sowie SQL-Logins und Datenbankbenutzer.
Eine OS-Identität erteilt nicht automatisch SQL-Zugang. SQL-Identitäten werden
an die ausgewählte Instanz und gegebenenfalls ausdrücklich ausgewählte
bestehende Labdatenbanken gebunden; keine automatische Datenbankanlage.

Mehrere eigene Benutzer mit unterschiedlichen ausdrücklich gewählten,
nicht privilegierten Berechtigungsprofilen können zu einem Szenario gehören.
Manuelle Nutzung benötigt eine sichere lokale Anmeldung und bewusst gewählte
Aufbewahrung bis zum vereinbarten Nutzungsende innerhalb des Lab-Runs.
Testende oder Dateisystem-Cleanup entfernt aufbewahrte Identitäten nicht
automatisch. Owner, Journal, Lebensdauer, Driftprüfung und eigener Rückbau
gelten auch für eigenständige Benutzeranlagen. Konkrete Profile,
Authentisierungsarten, Secretübergabe und Cleanupabhängigkeiten bleiben in
FSF-02 bis FSF-06 abzustimmen; es gibt keine Implementierungsfreigabe.

Dieser Backlog erweitert weder die laufende parallele Entwicklungswelle noch
deren Freigaben oder Reihenfolge. Der dortige Implementierungsstand bleibt
getrennt. Dieser Eintrag legt Anforderungen und offene Entwurfsaufgaben fest;
er ist kein abgeschlossener Architekturvertrag oder Runtime-Nachweis.

## Zielauswahl und Autorisierung

- Aktionen benötigen ein ausdrücklich ausgewähltes, bereits laufendes
  `READY`-SQL-Labziel und eine explizite Identitäts-/Fixture-Freigabe. Test,
  Schulung, Demonstration und Rekonstruktion sind zulässige SQL-Zwecke.
- Keine automatische Provider- oder Plattformauswahl; Produktionssysteme
  sind ausgeschlossen.
- Plattform und Runtime stammen aus dem validierten Lab-Vertrag. Vor jeder
  Mutation sind aktuelle Zielidentität, Providerbindung, Readiness und
  Freigabescope erneut zu prüfen.
- Jede Fixture besitzt einen eindeutigen Owner, eine Run-ID, einen Zielbezug
  und einen begrenzten Lebenszyklus. Ein Handle allein ersetzt keine
  Autorisierung oder Ownership-Prüfung.
- Die Fixture-Funktion startet, repariert oder löscht keine VM-, Docker- oder
  Podman-Infrastruktur. Fehlende Voraussetzungen ergeben einen Blocker.

## Geplante Fähigkeiten je Plattform

Alle Tabellenzeilen sind Anforderungen an das spätere Capability-Modell,
keine Aussage über implementierte oder geprüfte Unterstützung.

| Fähigkeit | Windows / Hyper-V | Linux / Docker | Linux / Podman |
|---|---|---|---|
| Temporäre Identität | nicht privilegierter lokaler Testbenutzer | nicht privilegierter Testbenutzer oder gezielt erzeugte UID/GID-Konstellation | eigener gleichwertiger Vertrag mit separatem Nachweis |
| Dateisystem | synthetischer Fixture-Root und Arbeitsverzeichnisse im ausgewählten Gast | synthetischer Fixture-Root und Arbeitsverzeichnisse im ausgewählten Container | synthetischer Fixture-Root und Arbeitsverzeichnisse im ausgewählten Container |
| Berechtigungen | präzise NTFS-ACLs für Testbenutzer und SQL-Server-Dienstidentität, SID-gebunden | gezielte Unix-Mode-Bits, Besitzer und Gruppen | gezielte Unix-Mode-Bits, Besitzer und Gruppen |
| Optionaler Escape-Testfall | Junction-/Reparse-Point-Fall | Symlink-Fall | Symlink-Fall |
| Optionaler Outside-Sentinel | eigenes synthetisches Verzeichnis außerhalb des inneren Testroots | eigenes synthetisches Verzeichnis außerhalb des inneren Testroots | eigenes synthetisches Verzeichnis außerhalb des inneren Testroots |
| Besondere Grenze | Gast- versus Hostdateisystem; Reparse-Ziel und SQL-Dienstidentität | Container-, Host-, bind-mount- und Volume-Grenzen; UID/GID-Mapping | eigene Runtime-, Namespace-, UID/GID-, bind-mount- und Volume-Grenzen |

Fähigkeiten werden pro Plattform und Runtime ausdrücklich ausgewiesen.
Fehlende oder nicht beweisbare Semantik wird nicht still emuliert. Docker,
Podman und Hyper-V benötigen jeweils eigene Nachweise.

## Sichere temporäre Identitäten

Die OS-Identitätsanforderungen unten werden um einen getrennten SQL-Vertrag
ergänzt: neue eigene SQL-Logins und Datenbankbenutzer, ausdrücklich gebundene
Zuordnungen, Rechteprofile und Erzeugungs-/Cleanupnachweise. Bestehende
SQL-Logins, Benutzer, Dienstidentitäten und Authentisierungsmodi werden nicht
verändert oder übernommen. Ihre Erstellung und spätere Entfernung sind keine
Dateisystemoperation; ein Dateisystemroot ist dafür keine Voraussetzung.

- Ausschließlich nicht privilegierte Identitäten erzeugen; keine Aufnahme in
  administrative oder anderweitig privilegierte Gruppen.
- Windows: begrenzte Namen und SIDs für ACLs verwenden; keine Abhängigkeit von
  sprachabhängigen Kontonamen.
- Linux: UID/GID eindeutig und kollisionssicher wählen. Vorhandene Benutzer
  oder Gruppen weder übernehmen noch verändern; Kollisionen müssen vor
  Mutation blockieren.
- Bestehende Identitäten niemals löschen oder verändern; Gleichheit eines
  Namens oder einer UID/GID allein belegt keine Fixture-Ownership.
- Secrets möglichst vermeiden. Unvermeidliche Secrets nur lokal verschlüsselt
  beziehungsweise kurzlebig behandeln; niemals in Logs, Exports, Handles,
  öffentlichen Ergebnissen oder Repository-Dateien ausgeben.
- Der Architekturentwurf muss klären, wie notwendige Betreiberrechte intern
  eng begrenzt genutzt werden, ohne privilegierte Testidentitäten oder vom
  konsumierenden Projekt verwaltete Admin-/Root-Zugänge einzuführen.

## Sicheres Dateisystemmodell

Reguläre Fixture-Pfade werden ausschließlich innerhalb eines eindeutig neu
erzeugten Fixture-Roots angelegt. Berechtigungen und Ownership dürfen nur auf
selbst angelegten Ressourcen verändert werden. Vorbestehende ACLs,
Unix-Accounts, SQL-Logins und Mounts bleiben unverändert; globale
Sicherheitsrichtlinien und Host-Härtung werden nicht angepasst.

Der optionale Outside-Sentinel ist ein ausdrücklich beantragter synthetischer
Negativtest. Sein Entwurf muss die Ausnahme vom inneren Root klären: eigene
Erzeugung, begrenzter separater Scope, unabhängige Ownership und sichere
Entfernung. Er erlaubt keinen Zugriff auf beliebige bestehende Außenpfade.
Diese Grenze ist vor Implementierung ausdrücklich abzustimmen.

Windows muss NTFS-ACLs, Junctions und Reparse Points kontrolliert behandeln.
Linux muss Ownership, Mode-Bits, Gruppen, Symlinks, bind mounts und
Volume-Grenzen kontrolliert behandeln. Linkziele dürfen niemals unkontrolliert
außerhalb des Fixture-Scopes verändert oder gelöscht werden. Ein vorhandener
Mount erteilt keine Schreib- oder Löschautorität für Host- oder Volume-Inhalte.
Nicht eindeutig prüfbare Grenzen blockieren die Operation.

## Ownership, Journal und Cleanup

- Vor der ersten Änderung einen lokalen, geschützten, nicht versionierten
  Eigentums- und Wiederherstellungsdatensatz sowie einen Cleanup-Plan anlegen.
- Erzeugung und Eigentum jeder Ressource eindeutig nachweisen. Private
  Ressourcenidentitäten, Pfad- und Zielbindungen bleiben im lokalen Datensatz.
- Das Fixture-Handle enthält nur minimale, nicht geheime Metadaten. Schema,
  Versionsbindung, lokale Auflösung und Manipulationsschutz sind offen.
- Cleanup entfernt ausschließlich nachweislich durch diese Fixture erzeugte
  und weiterhin eindeutig gebundene Ressourcen.
- Drift, unklare Ownership, abweichende Besitzer oder geänderte Mount-/
  Reparse-/Symlink-Ziele führen zum Abbruch ohne Löschung der betroffenen
  Ressourcen; Recoverybedarf bleibt sichtbar.
- Cleanup muss idempotent sein, Teilfehler nachvollziehbar erhalten und
  Fehlerursache von Cleanupstatus trennen. Bereits bestätigte Entfernung ist
  von unbekannter Abwesenheit zu unterscheiden.
- Wiederholung, verlorene Antwort, Abbruch zwischen Erzeugung und
  Journalbestätigung sowie konkurrierende Operationen benötigen ausdrückliche
  Entwurfsregeln. Namen oder Pfadpräfixe allein rechtfertigen keine Löschung.
- Fremde Container, VMs, Identitäten und Dateisystemressourcen bleiben
  unverändert. Runtime-Remove oder Infrastruktur-Reparatur ist kein
  Fixture-Cleanup-Fallback.

## Einheitliche Schnittstelle und Ergebnisvertrag

Die folgenden Namen sind Beispiele aus der Anforderung, keine vorhandenen
Cmdlets, Exports oder zugesagten endgültigen API-Namen:

- `New-LabFilesystemFixture`
- `Get-LabFixtureStatus`
- `Remove-LabFilesystemFixture`

Diese Beispiele decken nur das Dateisystemprofil ab. Getrennte direkte
Anlage-/Status-/Entfernungsverträge für OS- und SQL-Identitäten sowie ihre
Konsolenbedienung und sichere manuelle Nutzung sind in FSF-02/FSF-03 zu
entwerfen. Keine Benutzeranlage darf eine Testautomatisierung voraussetzen.

Der Schnittstellenentwurf berücksichtigt mindestens ausgewähltes Ziel,
Owner/Run-ID, gewünschte Identitätsart, Berechtigungsprofil,
Reparse-/Symlink-Fall und optionales Outside-Sentinel. Capability-Prüfung,
Freigabe, mutierende Parameter und Statusabfrage sind gemeinsam zu entwerfen.

Ergebnisse sind strukturiert und datenschutzkonform, mit begrenzten
Metadaten und ohne Credentials oder private Endpoints. Reale
Infrastrukturdetails, Pfade, Hostnamen, IP-Adressen, Nutzer und rohe
Runtime-Ausgaben dürfen nicht in öffentliche Evidenz, Exports oder das
Repository gelangen. Öffentliche DTOs und der private Recoverydatensatz
benötigen getrennte Feld- und Aufbewahrungsregeln.

## Sicherheitsmodell und Teststrategie als Entwurfsaufgaben

Das Bedrohungsmodell muss mindestens Windows-Junction-/Reparse-Point-Escape,
Linux-Symlink-, bind-mount- und Volume-Escape, UID/GID-Kollisionen,
Container-/Host-Dateisystemgrenzen und unbeabsichtigte Löschung außerhalb des
Fixture-Roots behandeln. Prüf-/Mutationsrennen, Zielwechsel und manipulierte
Ownershipdaten sind in die Schutz- und Recoveryregeln einzubeziehen.

| Testgruppe | Geforderter späterer Nachweis |
|---|---|
| Autorisierung und Ziel | nicht ausgewählte, nicht laufende, nicht `READY`, produktive, gewechselte oder nicht eindeutig gebundene Ziele vor Mutation ablehnen; keine automatische Providerauswahl |
| Erfolg und Wiederholung | gewünschte synthetische Identitäten, Verzeichnisse und Rechte; reproduzierbare Profile; definierte Wiederholung ohne Übernahme fremder Ressourcen |
| Identitäten | keine privilegierten Konten; SID-Bindung und Namensgrenzen; UID/GID-Kollisionen und bestehende Identitäten unverändert |
| Eigenständige und manuelle Nutzung | OS-Anlage ohne Dateisystem-Fixture; SQL-Login-/Datenbankbenutzeranlage ohne OS-Adminzugang; mehrere Szenariobenutzer, sichere Anmeldung, ausdrückliche Aufbewahrung und getrenntes Cleanup; kein Executor nötig |
| Teilfehler und Recovery | Abbruch und verlorene Antworten an Mutations-/Journalgrenzen; nachvollziehbares eigenes Cleanup und sichtbarer Recoverybedarf |
| Drift und Idempotenz | Besitzer-, Ziel-, Mount-, Link- und Journaldrift verhindert unsichere Löschung; wiederholtes Cleanup entfernt nichts Fremdes |
| Scope-Escape | Junctions/Reparse Points, Symlinks, bind mounts und Volumes; unverändertes Outside-Sentinel sowie unveränderte fremde Außenressourcen |
| Privacy und Nebenwirkungen | keine Secrets, privaten Endpoints oder Rohdaten in öffentlichen Ergebnissen; keine Änderung von Hostpolicies, fremden ACLs/Accounts/SQL-Logins/Mounts oder Infrastruktur |
| SQL-Bezug | die ausgewählte SQL-Server-Dienstidentität erhält exakt das vereinbarte Profil; erlaubte und verweigerte Dateizugriffe fachlich nachweisen |

Die spätere Strategie trennt synthetische Offline-Vertragsprüfungen von
nativen Windows-/Hyper-V-, Linux-/Docker- und Linux-/Podman-Abnahmen.
Mocks und grüne Dokumentationschecks ersetzen keine plattformspezifischen
Dateisystem-, Berechtigungs- oder Cleanup-Nachweise. Sämtliche Fixture-
Implementierungs- und Runtime-Nachweise sind für diesen Backlog offen.

## Einzelfreigaben vor Implementierung

| ID | Einzeln auszuarbeitender und abzustimmender Bereich | Erwartetes reviewbares Ergebnis | Freigabe |
|---|---|---|---|
| `FSF-01` | Architektur | [Entwurf zur Abstimmung](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md): SQL-Bezug, Ziel-/Readinessbindung, interne Betreibergrenze, Abläufe und ausgeschlossene Infrastrukturaktionen | `PENDING` |
| `FSF-02` | Capability-Modell je Plattform | getrennte OS-/SQL-Identitätsarten und optionale Dateisystemprofile für automatisierte und manuelle Szenarien; explizite Windows-/Hyper-V-, Linux-/Docker- und Linux-/Podman-Matrix einschließlich Namespace-/Mountgrenzen und Blockern | `PENDING` |
| `FSF-03` | Fixture-Handle | minimaler versionierter Ergebnisvertrag, private lokale Auflösung, Ziel-/Owner-/Runbindung und Manipulationsschutz | `PENDING` |
| `FSF-04` | Ownership und Cleanup | Vorabjournal, Erzeugungsnachweis, begrenzter Outside-Sentinel, Drift-Vetos, Idempotenz, Teilfehler und Recovery | `PENDING` |
| `FSF-05` | Sicherheitsmodell | Bedrohungsmodell, Least Privilege, Secrets/Privacy, Escape-/Kollisionsschutz und prüfbare Sicherheitsgrenzen | `PENDING` |
| `FSF-06` | Teststrategie | konkrete positive/negative Testmatrix, getrennte Providerbelege, SQL-Assertions, Schutz fremder Ressourcen und Cleanup-Abnahme | `PENDING` |

Die Backlogaufnahme ist keine Freigabe dieser Entwürfe. Erst wenn alle sechs
Punkte einzeln abgestimmt und ausdrücklich freigegeben sind, darf eine
Implementierung beginnen. Danach ist der konkrete Implementierungsscope mit
der dann aktuellen Entwicklungsplanung und parallelen Arbeiten abzugleichen.
Es entsteht keine automatische Wellenzuordnung oder Prioritätsänderung.

## Gekoppelte Quellen für die spätere Ausarbeitung

- [Arbeits-, Privacy-, State- und Cleanup-Regeln](../../.ai/WORKING_RULES.md)
- [Repository-Vertragslandkarte](../../.ai/repo_map.yaml)
- [Scenario-Metadaten und begrenzter synthetischer Executor](SCENARIO_CONTRACT_BACKLOG.md)
- [Persistenter Speicher und Labdaten](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md)
- [Isolierte eigene CI-Ressourcen auf dem Host](../Architecture/OWNED_HOST_CI_ISOLATION.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)
- [Lokale Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md)

Vor der Ausarbeitung sind die dann betroffenen Implementierungen, Aufrufer,
Fixtures und Providerverträge gemeinsam anhand der aktuellen Repo-Map zu
erschließen. Die genannten Nachbarverträge erteilen keine Fixture-Freigabe.
