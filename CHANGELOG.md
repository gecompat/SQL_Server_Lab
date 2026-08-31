# Changelog

Dieses Changelog dokumentiert Änderungen am öffentlichen Verhalten, an maschinenlesbaren Verträgen und an der Bedienung von `SQL_Server_Lab`.

Das Repository verwendet derzeit keine formalen Releases. Einträge werden daher nach Datum geführt. Neue Einträge werden oben ergänzt.

## 2026-08-31

### Hinzugefügt

- `Get-SqlServerLabHyperVResourcePreview` zeigt die registrierte Location,
  den physischen `Lab_Data`-Root, freien Speicher und die deterministischen
  Run-/Build-/Image-/Staging-/Recovery-Roots ohne Hostmutation.

### Geändert

- Hyper-V-Menüaktionen zeigen ihren klassenbezogenen Zielvertrag vor der
  Bestätigung. Beim UAC-Wechsel wird die Vorschau explizit an den erhöhten
  Prozess übergeben und dort gegen Controller, Location, Volume und Root
  erneut geprüft; jede Abweichung blockiert fail-closed.

### Validiert

- Die fokussierten Resource-Binding- und Elevation-Suites belegen die
  öffentliche Preview, Klassenroot-Auflösung, Manipulationsabwehr und den
  serialisierten UAC-Handoff synthetisch. Die reale erhöhte End-to-End-Abnahme
  bleibt als `HVR-008` offen.

## 2026-08-30

### Hinzugefügt

- Die Grundlage für `HVR-001`/`HVR-002` trennt Hyper-V-Create-, Discovery-
  und Mutation-Roots. `SqlServerLab.HyperVResourceBinding/1.0` leitet kurze,
  deterministische Ressourcenpfade ausschließlich aus registrierten
  `Lab_Data`-Locations ab und revalidiert Controller, Location, Volume,
  Marker und Reparse-Grenze. Legacy-State-Roots bleiben read-only auffindbar.
- Der erste Run-Slice von `HVR-005` ergänzt einen schema-validen read-only Migrationsplan und ein
  persistentes Operationsjournal für vorhandene Hyper-V-Run-Ressourcen. Der
  resumierbare Ablauf verifiziert Quellen und Zielkopien, bindet VM-State und
  run-lokale VHDX um, erhält externe SQL-Lanes und löscht Quellen erst nach
  zwei erfolgreichen Start-/Readiness-Zyklen.
- Der Image-Staging-Slice von `HVR-005` inventarisiert Legacy-Artefakte samt
  Child-Graph, veröffentlicht sie hashidentisch im gebundenen Image-Store und
  hält referenzierte Quellen journalisiert in `WAITING_FOR_CONSUMERS`. Erst ein
  consumerfreier Resume entfernt die vollständig verifizierte Quelle.
- Der abschließende interne `HVR-005`-Slice koppelt Legacy-Run- und
  Image-Migration: Nur ein hashverifiziertes, gebundenes Ziel-Parent darf per
  vorjournalisiertem `Set-VHD` übernommen werden. Getrennte Child-Hashes machen
  Abbruch/Resume und späten Quell-Cleanup sicher; der Run-Abschluss setzt die
  wartende Image-Migration automatisch fort.

### Geändert

- `HVR-003`/`HVR-004` erzwingen die persistierte Ressourcenbindung nun im
  Hyper-V-Slot-Provider, in Windows-/SQL-Buildern, bei Existing-VM-Kopien sowie
  im Image- und Staging-Store. Neue VHDX, VM-Konfiguration, Smart Paging,
  Snapshots und Artefakte liegen unter registriertem `Lab_Data`; fail-closed
  Preflights und Datei-, VHDX- sowie VM-Pfad-Postconditions sichern die
  Mutationsgrenzen. Legacy-Ressourcen bleiben für bestehenden Lifecycle
  auffindbar; ihre öffentliche Migration und reale Abnahme folgen nach der nun
  implementierten internen HVR-005-Grundlage.

### Validiert

- Der physische N5-Storage-Nachweis ist abgeschlossen: Der reale Hyper-V-
  Referenzlauf verteilte vier TempDB-Datendateien 2/1/1 auf drei nachweislich
  getrennte lokale Geräte und
  band das TempDB-Log an eine eigene Lane. SQL-Dienstrestart, Defaultpfade,
  dateigenaues Create, synthetischer Backup/FILELISTONLY/Restore-Roundtrip,
  Datenpersistenz nach vollständigem VM-Restart sowie VM-, Child-VHDX- und
  externer VHDX-Cleanup waren erfolgreich. Das N5-Gesamtgate bleibt bis zum
  P0-Fix der Hyper-V-Ressourcenroot-Bindung `IN_PROGRESS / P0_FIX_FIRST`.
- Gate N3 ist geschlossen: Die drei realen Project-Adapter-Piloten für
  `SQL_PerformanceSchulung`, `SQL_Server_Analyze` und `SQL_Server_Toolbelt`
  sind in ihren autoritativen Partnerrepositories gemergt und jeweils auf SQL
  Server 2025 Linux getrennt unter Docker und Podman end-to-end validiert.
  Install/Update beziehungsweise Szenarioaufbau, fachliche Validierung,
  markergebundener Cleanup sowie Container- und Volume-Cleanup waren
  scopegebunden erfolgreich. Der Pilotabschluss schreibt den weiterhin als
  `0.1-draft` geführten Adaptervertrag nicht automatisch auf `1.0` fest.

## 2026-08-29

### Hinzugefügt

- Reservierte `serverConfig`-Felder werden jetzt anhand von
  `x-runtimeStatus` vor Manifestauflösung und Mutation mit
  `MANIFEST_RESERVED_RUNTIME_FIELD` abgelehnt. Wertabhängig reservierte
  `externalScripts.installMethod`-Varianten sind über
  `x-runtimeValueStatus` klassifiziert und enden mit
  `MANIFEST_RESERVED_RUNTIME_VALUE`; dadurch werden `custom-image` und
  `pre-built` nicht mehr nur gewarnt oder später verworfen.

- Die verbleibenden Konsolen-Auswahllisten für Storage, Connection Center/CMS,
  Testumgebungen, Containerprofile sowie Hyper-V-Builds, Medien, Vorlagen,
  Switches, Quell-VMs und Fortsetzung verwenden jetzt die gemeinsame
  Cursor-/Fallback-Schicht mit stabilen IDs und einheitlichem `Escape`. Ein
  AST-basiertes Testinventar verhindert neue direkte `Read-Host`-Auswahlmenüs;
  rohe globale Enter-Pausen wurden durch klar benannte Ergebnisrückwege ersetzt.

- Die CU-Auswahl umfasst jetzt die vollständige bei Microsoft verfügbare
  Historie für SQL Server 2019, 2022 und 2025: 65 explizite Linux-MCR-Tags und
  ebenso viele Windows-x64-Pakete mit offizieller Downloadquelle, Media-Root-
  Pfad und SHA-256. Das zurückgezogene SQL Server 2019 CU7 bleibt gesperrt.
  Das neue Cmdlet `Save-SqlServerLabCuResource` und der Storage-/Medien-
  Konsolenpunkt stellen jeden Eintrag ohne KI-Unterstützung bereit: Windows nur
  nach SHA-256- und Microsoft-Authenticode-Prüfung im Media Root, Linux über
  den exakten MCR-Tag im gewählten Docker-/Podman-Cache.

- Der schemaabgeleitete Manifest-Wizard unterstützt jetzt in allen
  Eingabeknoten Hilfe, schrittweise Zurücknavigation,
  Zwischenzusammenfassungen und Abbruch ohne partielle Manifestdatei. Die
  Planvorschau `SqlServerLab.ManifestPlanPreview/1.1` zeigt zusätzlich zu
  External Runtimes auch Sample-/Artifact-Quelle, Lizenz, Outputs, Größen,
  Integrität, Trust, Handler und Idempotenz.

- Der SQL-CU-Wächter begrenzt seinen Standardlauf jetzt auf die im
  Versionskatalog als `SUPPORTED` markierten SQL-Versionen. Veraltete
  Katalogeinträge erzeugen dadurch keine falschen `NEW`-Meldungen mehr, bleiben
  aber über den expliziten Parameter `-Version` prüfbar.

- External Languages sind im Containerpfad nun versionsbewusst für alle drei
  aktiven SQL-Versionen katalogisiert: Java für SQL Server 2019 sowie Python,
  R und Java für SQL Server 2022/2025, jeweils gleichwertig unter Docker und
  Podman. C#/.NET ist für SQL 2019–2025 auf Hyper-V/Windows sichtbar erfasst,
  bleibt mangels aktuellem veröffentlichtem Binärartefakt und nativer Evidence
  jedoch sicher `PREVIEW` und fail-closed.
- Die nativen Container-Abnahmen belegen Java auf SQL Server 2019 sowie Python,
  R und Java auf SQL Server 2025 jetzt getrennt unter Docker und Podman. Die
  SQL-2025-Abnahme umfasst außerdem atomaren Runtime-Refresh, Java-Removal,
  Datenpersistenz, Provider-Restart und registrierten Cleanup.
- Die Containerverwaltung bietet jetzt einen sichtbaren Menüpunkt, um External
  Languages über ein geprüftes Zielmanifest erstmals zu installieren oder zu
  ändern. SQL-2022-Docker-/Podman-Runs ohne bestehende Runtime erhalten einen
  journalisierten `InstallExternalRuntime`-Plan einschließlich neuer,
  cleanupgebundener External-Language-/Library-Volumes; Hyper-V zeigt den noch
  nicht atomaren Nachinstallationspfad begründet deaktiviert.
- Der journalisierte Container-Reconcile akzeptiert einen expliziten
  `AutoStart`-Sollwert, bindet Restart-Policy und Lab-Label gemeinsam an Plan,
  Journal, Postcondition und Recovery und kann dadurch auch ältere verwaltete
  CMS-Container sicher auf den aktuellen Autostartvertrag bringen.
- Der lokale Storage-Katalog führt stabile `LocationId`-Werte, Controller- und
  Volume-Bindung sowie getrennte Topologieangaben für logische Volumes und
  nachweisbare Backing Devices. Legacy-Kataloge werden abwärtslesbar übernommen
  und beim nächsten Schreibvorgang mit einem Receipt persistiert.
- Die Storage-Konsole verwendet das gemeinsame Untermenü, zeigt normalisierte
  Ziele vor der Bestätigung und bietet explizite Aktionen für Default-Wechsel,
  Topologieanzeige, geschützte Deregistrierung und Parent-Migration.
- `SqlServerLab.StorageIntent/1.0` kann im Manifest portable Selektoren für
  Default Data/Log, Backup, einzelne TempDB-Dateien, Datenbankdateien und
  Restore-Regeln beschreiben. Der lokale `StorageBoundPlan/1.0` löst sie ohne
  Mutation auf Locations, Topologie und Gastpfade auf; ein separater Runtime-
  Receipt-Vertrag hält die noch offene Anwendung ausdrücklich getrennt.
- Storage-Locations besitzen editierbare Anzeigenamen und registry-weit
  eindeutige portable Selektoren. Die Konsole zeigt jede geplante SQL-Datei und
  blockiert strikte Volume-/Geräteverteilung bei unzureichender, unbekannter
  oder überlappender Topologie.

### Behoben

- Die reale Hyper-V-Storage-Anwendung verwendet kanonische
  `SqlConnectionStringBuilder`-Indexer und providerneutrale Integer-
  Konvertierung für SQL-Metadaten. Der run-basierte Restore akzeptiert den
  aufgelösten Hyper-V-Provider, und der N5-Restart-Aufruf entspricht dem
  öffentlichen Cmdlet-Vertrag.
- Der N5-Runner materialisiert Location- und Backing-Device-Mengen vor deren
  Auswertung. Ein Bootstrap-Runner kann ein isoliertes N4-Prepared-Artifact für
  N5 zurückbehalten und entfernt es anschließend wieder streng scopegebunden.
- Projektkontext, Repo-Map und Known Limitations bilden den belegten
  Multi-Version-External-Runtime-, Batch-Recovery-, Hyper-V-SQL- und
  Container-Reconcile-Stand wieder widerspruchsfrei ab. Statische
  Dokumentationschecks blockieren die zuvor veralteten offenen Aussagen und
  binden N5 sowie die drei Adapterpiloten als nächste Gates.
- Escape und Enter schreiben in der cursorbasierten CLI wieder einen echten
  Zeilenumbruch; der Ausdruck `[Environment]::NewLine` erscheint nicht mehr
  kurzzeitig als sichtbarer Text.
- Registrierte automatisierte Testumgebungen konvergieren ihre nativen Docker-,
  Podman- und Hyper-V-Namen jetzt auf einen sprechenden, aus dem stabilen
  Registry-Schlüssel abgeleiteten Namen. Übernommene Windows-Pool-Slots werden
  bei der Belegung sicher umbenannt; freie Slots behalten ihre Poolbezeichnung.
- Der Container-Reconcile akzeptiert beim Mount-Fingerprint nun auch die gültige
  leere Mount-Liste und blockiert dadurch mountfreie ältere Container nicht mehr
  vor einer kontrollierten Reparatur oder Umbenennung.
- Der native Testgruppen-Lifecycle hinterlässt die persistenten Windows-
  Testumgebungen nach seiner Start-/Stop-Abnahme nicht mehr ausgeschaltet. Sein
  garantiertes Cleanup stellt alle registrierten Hyper-V-Mitglieder, den
  vollständigen `READY`-Export und die CMS-Sicht wieder her.
- Die gemeinsame Sechs-Ziele-Abnahme vergleicht SQL Server 2019, 2022 und 2025
  jetzt explizit mit den tatsächlich gelieferten Major-Versionen 15, 16 und 17,
  statt nur eine Jahreszahl in der allgemeinen Versionsausgabe zu suchen.
- Das Hinzufügen einer weiteren `Lab_Data`-Location ändert einen vorhandenen
  Default nicht mehr implizit. Laufwerksrelative Parents wie `D:` werden vor
  jeder Mutation blockiert; `D:\` wird als `D:\Lab_Data` angezeigt.
- Default- und noch referenzierte Storage-Locations können nicht deregistriert
  werden. Eine erlaubte registry-only Deregistrierung aktualisiert auch den
  Katalog am entfernten, weiterhin erhaltenen Root.
- Storage-Migrationsplan und -journal binden Parent-Wechsel an die stabile
  `LocationId`; ein Laufwerksbuchstabenwechsel verändert diese Identität nicht.

## 2026-08-28

### Hinzugefügt

- `Invoke-HyperVSqlPreparedImageAcceptance.ps1` führt den realen Windows-2025-/
  SQL-2025-Pfad jetzt vom frischen, hashverifizierten Build über
  `SQL_PREPARED_SEALED` bis zum normalen differenzierenden Manifest-Klon aus.
  Die Abnahme bindet Windows-Specialization, `CompleteImage`, SQL Major 17,
  vier Online-Systemdatenbanken, unveränderten Parent-Hash und vollständigen
  Builder-/Klon-Cleanup.
- `Invoke-HyperVWindowsGeneralizeAcceptance.ps1` installiert Windows Server
  2025 Standard Evaluation unbeaufsichtigt aus dem SHA-256-verifizierten ISO
  auf einer neuen Builder-VHDX und belegt real Installations-Receipt, Sysprep-
  Generalize, hashgebundene PowerShell-Direct-Evidence, testlokale immutable
  `OS_SEALED`-Publikation und vollständigen Cleanup.

- `Start-SqlServerLabAutomatedTestEnvironment` und
  `Stop-SqlServerLabAutomatedTestEnvironment` steuern die registrierten
  Docker-, Podman- und Hyper-V-Mitglieder der geschützten Testgruppe gemeinsam
  und idempotent. Unter **Umgebungen** erscheint zustandsabhängig genau eine
  Start- oder Stoppaktion. Der Start prüft SQL-Readiness und erwartete Major-
  Version und fordert einen live erzeugten `READY`-Export; der Stopp gibt
  Hostkapazität frei und erneuert den Export fail-closed, ohne Runs,
  Registrierungen, Secrets, Volumes oder VHDX-Dateien zu löschen.
- Die nachträgliche External-Languages-Auswahl behandelt Docker und Podman für
  die freigegebenen SQL-Server-2022-Varianten Python, R und Java gleichwertig.
  SQL Server 2025 bleibt wegen fehlender belegter Runtimekombination bewusst
  deaktiviert; rootless Podman beziehungsweise cgroup v2 erfüllen den sicheren
  `launchpadd`-Vertrag nicht.
- Der PowerShell-7-Einstieg akzeptiert `-ConsoleMode Auto|Fallback`. Damit ist
  der nummerierte Fallback im selben Terminal gezielt reproduzierbar; `0`
  beendet ihn kontrolliert.
- `SqlServerLab.ActionResult/1.0` normalisiert mutierende GUI-Aktionen als
  `Changed`, `NoChange`, `Cancelled` oder `Failed` und bindet den
  Connection-Center-/CMS-Sync an den konkreten Runtime-, Endpoint- oder
  Anzeigenamen-Impact. Nicht mutierende Ergebnisse bleiben synchronisationsfrei.
- Explizite SQL-Hostports erhalten einen read-only Review-Befund mit Besitzer
  und Grund. Docker und Podman wiederholen diese Prüfung unter dem hostweiten
  Port-Lock unmittelbar vor dem Container-Create.
- UI-Aktionen sind als `User`, `RuntimeAccess` oder `Administrator`
  klassifiziert. Die Hyper-V-Erhöhung erklärt Zweck und Umfang, ist
  standardmäßig abgelehnt und startet erst nach Zustimmung genau einen
  separaten Prozess.
- Der SQL-Versionskatalog ist gegen die offiziellen Microsoft-Buildtabellen auf
  SQL Server 2019 CU32, SQL Server 2022 CU26 und SQL Server 2025 CU8
  aktualisiert. Bestehende 2019-/2022-KB-, Build- und Release-Zuordnungen wurden
  berichtigt; der CU-Wächter meldet für alle drei unterstützten Versionen
  `NO CHANGE`.
- Der kanonische Ausführungsplan führt den tatsächlichen N1-Status und die
  Nightly-, Recovery- und Katalog-Evidence, statt alle fünf nächsten Wellen
  pauschal als nicht begonnen auszuweisen. Zwei aufeinanderfolgende vollständige
  Nightlies auf den Runs `33186781267` und `33187726632` schließen Gate N1 ab.
- `Get-SqlServerLabReconcilePlan` und `Invoke-SqlServerLabReconcileAction`
  unterstützen einen additiven, resolvergebundenen External-Runtime-Refresh für
  laufende SQL-Server-2022-Docker-/Podman-Runs. Ein neues Derived Image wird vor
  der Mutation gebaut; Scope-Prüfung, Journal, Ersatzcontainer, SQL-Readiness,
  echte Sprachpostconditions, atomarer State-Commit und Rollback schützen die
  Umschaltung. Alte Images bleiben gemäß Retention erhalten.
- Der persistierte Desired-State-Softwarevertrag enthält die portable
  `PlanKey`; eine fokussierte Suite bindet Drift-, Removal-, Leak-, `WhatIf`-,
  Recovery- und Umschaltgrenzen.

### Behoben

- Der reguläre Hyper-V-Prepared-Image-Manifestpfad persistiert nach
  `CompleteImage`, WMI und Hostzugriff nun einen echten `SQL_READY_RUN`-
  Receipt. Ein fehlender oder falscher Major-/Systemdatenbanknachweis beendet
  die Provisionierung fail-closed. Der reale Runner prüft außerdem
  Administratorrechte vor dem zeitintensiven Image-Build.
- Der initiale Hyper-V-DVD-Boot deckt das real beobachtete UEFI-Zeitfenster
  jetzt mit 30 einmaligen Tastenzustellungen über gut 22 Sekunden ab. Dadurch
  wird ein erfolgreicher WMI-Tastaturaufruf nicht mehr fälschlich als
  tatsächlich angenommener „Press any key“-Boot interpretiert.
- Windows-Generalize wartet begrenzt auf den finalen Microsoft-ImageState und
  liefert bei einem Fehler die relevanten begrenzten Panther-Zeilen. Der
  reale Nachweis trennt damit Produktfehler von unzulässigen erneuten Rearms
  bereits generalisierter Windows-Baselines.

- Persistente Hyper-V-Windows-User-Gates verwenden jetzt den tatsächlichen,
  rungebundenen VM-Namen aus `connection-info.json`, statt bei älterem State
  versehentlich die RunId als VM-Namen abzufragen. Der reale Acceptance-Test
  bindet `CandidateSatisfied` ohne Fortschritt, fail-closed Bestätigung, echte
  PowerShell-Direct-Credential-Verifikation, genau ein Receipt und vollständigen
  VM-/Child-VHDX-Cleanup.
- Die gemeinsame Console-UI reicht `Ctrl+C` jetzt aus Cursor-, Text-, Secret-
  und Bestätigungseingaben als `PipelineStoppedException` durch, statt das
  Signal zu ignorieren oder nach einem Menüfehler in den Fallback zu wechseln.
  Der reale PTY-Nachweis ist für Cursor- und erzwungenen Fallback-Modus grün.
- Der reale Batch-Smoke deckt jetzt den vollständigen Manifest-Rerun ab:
  offene identische Einreichungen werden dedupliziert; nach Abschluss und
  Cleanup erzeugt dasselbe Manifest einen neuen Batch mit neuen RunIds, ohne
  Scheduler-Duplikate oder zurückbleibende Ressourcen.
- Batch-Worker binden neu angelegte Runs jetzt persistent an ihre Operation.
  Nach einem harten Scheduler-Prozessabbruch wird ein vollständig persistierter
  Run wiederverwendet oder ein unvollständiger operationseigener Run vor dem
  Resume scopegebunden bereinigt. Der reale Docker-Abbruch-Smoke prüft
  `WorkerRecovered`, Duplikatfreiheit und vollständigen Cleanup.
- Die grafische Workflow-Oberfläche schließt den obersten Dialog jetzt
  zuverlässig mit `Escape`. Der gemeinsame Abbruchpfad verwirft ausstehende
  Löschbestätigungen und leert Passwortfelder ebenso wie die sichtbaren
  Abbrechen-/Schließen-Schaltflächen.
- Docker und Podman setzen neben dem cgroup-Limit jetzt ein um 20 Prozent
  niedrigeres `MSSQL_MEMORY_LIMIT_MB`; dadurch bleibt insbesondere SQL Server
  2019 auf cgroup-v2-Hosts unter der harten Containergrenze. Automatisierte
  Linux-Testziele verwenden fuer Projektvolltests 4 GB Container-RAM und 3 GB
  `max server memory`.
- Container-Healthchecks funktionieren mit ODBC Driver 18 und dem run-lokalen
  selbstsignierten Zertifikat. Der Testumgebungs-Export prüft den gebundenen
  Live-Container und meldet `UNHEALTHY` fail-closed als unvollständige Gruppe,
  statt gespeichertes `RUNNING` als `READY` zu veröffentlichen.
- `Repair-SqlServerLabAutomatedTestEnvironment` gleicht veraltete Linux-
  Mitglieder der geschützten Testgruppe einzeln und mit Rollback auf den neuen
  Ressourcen- und Health-Vertrag ab, ohne Windows-Runs, Ports, Volumes oder
  Kennwörter zu ersetzen.
- Python-only-Derived-Images enthalten jetzt die von `revoscalepy` benötigte
  `libgomp.so.1`. Das Ubuntu-22.04-`libgomp1`-Paket ist mit exakter Version und
  SHA-256 an Rezeptversion 5 gebunden; Python- und R-Zielstages übernehmen nur
  die Runtimebibliothek, keinen Compiler.

## 2026-08-27

### Hinzugefügt

- Ein providerneutraler Softwarekatalog und Capability Resolver normalisieren
  Python-, R- und Java-Anforderungen nach SQL-Version, Betriebssystem,
  Architektur und Provider. Unbelegte Varianten, freie External-Runtime-
  Commands, nicht gesperrte Pakete und der nicht reproduzierbare
  `post-start`-Pfad werden vor jeder Mutation abgelehnt und geheimnisfrei im
  Desired State ausgewiesen.
- Die AI Repository Foundation 1.7 ist als geschützte Mindest-Governance integriert
  und von den projektspezifischen Regeln aus `AGENTS.md` transitiv erreichbar.
- Getrennte GitHub-Rulesets schützen den unveränderlichen Kern von `main` und
  erlauben dem Repository-Owner ausschließlich bei bestätigtem Ausfall der
  CI-Infrastruktur einen PR-basierten, auditierbaren CI-Notfallweg. Der Ablauf,
  die Nachweispflichten und die nachzuholende Validierung sind im
  Repository-Continuity-Runbook verbindlich beschrieben.
- Eine ausführbare CLI-Akzeptanzmatrix prüft Docker und Podman mit einem
  repräsentativen SQL-Server-2022-CU18 sowie Hyper-V mit einer frischen
  Windows-/SQL-Server-2025-Installation. Chinook, getrennte Daten-/Log-/TempDB-
  Speicher, SQL- und Runtime-Ressourcen, Lifecycle, Persistenz und
  scopegebundener Cleanup sind für alle drei Provider real nachgewiesen.

### Behoben

- Der statische SQL-2025-Workflowvertrag berücksichtigt Restore- und
  Batch-Smokes je Containerprovider semantisch statt über einen veralteten
  globalen Trefferzähler.
- Der GitHub-gehostete Adapter-Smoke verwirft fehlerhafte Microsoft-
  Paketdownloads frühzeitig und wiederholt transiente HTTP-Fehler kontrolliert.
- Der Hyper-V-Workflow bietet einen gezielten erhöhten `slot-batch`-Modus, der
  zwei isolierte OS-Slots aus einem vorhandenen `OS_SEALED`-Artifact prüft und
  anschließend scopegebunden freigibt, ohne die gesamte Nightly-Matrix zu
  wiederholen.
- Container verwenden ein run-eigenes SQL-Systemvolume und initialisieren
  leere Named Volumes mit providergeeigneten Besitzrechten. Dadurch bleiben
  Systemdatenbanken, Testdaten und Storage-Bindungen über Reconcile und
  Stop/Start/Restart erhalten; Podman nutzt dafür die kontrollierte `:U`-
  Zuordnung.
- SQL-Readiness nach Container- und Hyper-V-Lifecycle-Aktionen ist an die
  tatsächlich betroffene Runtime gebunden. Dezimale Speichergrenzen, reine
  TCP-Reconcile-Pfade und Windows-PowerShell-5.1-SQL-Verbindungsstrings werden
  korrekt behandelt.
- Die Hyper-V-Gastinitialisierung bindet Zusatz-VHDX über stabile SCSI-Slots,
  persistiert die Windows-Specialization und führt große Mehrbatch-SQL-Skripte
  über eine UTF-8-Datei in derselben Verbindung aus.

### Geändert

- Teure Nightly-Runtime-Läufe werden nur ausgelöst, wenn sich der relevante
  Frameworkstand gegenüber dem letzten erfolgreichen Lauf geändert hat.
- Die Docker-/Podman-Workflowtitel benennen die tatsächlich gewählte Runtime-
  beziehungsweise CLI-Akzeptanz statt pauschal SQL Server 2025.

## 2026-08-13

### Hinzugefügt

- persistenter `SqlServerLab.Batch/1.0`- und `SqlServerLab.Operation/1.0`-Kern
  mit stabiler Mengenexpansion, gemeinsamer Abhängigkeitsauflösung,
  scopegebundenem Cleanup und manifestbasierter Wiederaufnahme;
- Scheduler mit zwei Workern, einem `HyperVHeavy`-Slot, Ressourcen-Locks,
  `StateRoot`-Lease, Prioritäten, Umreihung, Pause/Resume und Wiederfreigabe
  verlassener Schritte nach einem Prozessabbruch;
- persistente User-Gates mit vollständigen Anweisungen, read-only Probes,
  `CandidateSatisfied`, Einzel-/Mehrfachbestätigung, Ton-Backoff sowie lokalen
  und globalen Ruhemodi;
- providerneutraler Mengen-Composer für SQL-, Windows-, Slot- und Matrixplanung
  sowie Queue-/User-Gate-Ansichten in Konsole und lokaler Workflow-UI;
- `SqlServerLab.BatchManifest/1.0`, öffentliche Batch-/Queue-Cmdlets und
  `Invoke-BatchWorkflowChecks.ps1` für Expansion, Fehlerisolation,
  Parallelitätslimits, User-Gates und Resume.

### Geändert

- Pull Requests verwenden jetzt ein pfadabhängiges `PR Gate` statt der
  vollständigen Testmatrix. Redundante statische Volltests wurden aus allen
  Runtime-Workflows entfernt; veraltete PR-Läufe werden abgebrochen.
- Nach einem Merge auf `main` wird keine zweite Vollmatrix gestartet. Die
  vollständige plattform- und providerübergreifende Regression läuft täglich
  gebündelt und pflegt bei Fehlern ein GitHub-Tracking-Issue.
- Die sechs gemeinsam exportierten SQL-Testumgebungen werden nachts mit
  `SELECT @@VERSION`, `sys.databases`, einem Create/Drop-Schreibtest und einem
  Abgleich der realen CMS-Registrierungen geprüft. Eine frische Hyper-V-/SQL-
  Installation läuft zusätzlich wöchentlich oder manuell.
- Das Hauptmenü verwendet sieben eindeutig benannte Arbeitsbereiche. Die
  normale Erstellung ist providerneutral; explizite Providerwahl liegt unter
  Erweitert, während Hyper-V-Vorlagen, ISOs, Slots und Recovery separat bleiben.
- Browsermutationen ohne transiente Geheimnisse werden als persistente
  Operation eingereiht statt ausschließlich als flüchtiger ThreadJob gestartet.

## 2026-08-12

### Hinzugefügt

- Hyper-V-Lab-VMs unterstützen jetzt `autostart: "on"|"off"` in Manifesten,
  Konsole und Workflow-UI. `on` setzt Hyper-Vs `AutomaticStartAction=Start`,
  wird in Run-/Connection-State und Status sichtbar gemacht und startet die VM
  nach einem Hostneustart automatisch; `off` bleibt der kompatible Standard.
- `instances[].autostart` gilt jetzt providerübergreifend. Docker und Podman
  setzen `unless-stopped` und ein verwaltetes Label; Windows erhält je Runtime
  einen Benutzer-Anmeldeauftrag, natives Podman/Linux aktiviert
  `podman-restart.service` samt systemd-Linger; Docker/Linux prüft seinen
  bootfähigen Daemon. Der optionale lokale CMS wird immer mit Autostart
  erstellt. `hyperv.autostart` bleibt als konfliktgeprüfter Alias kompatibel.
- Die SQL-2025-Smokes für Docker und Podman prüfen Autostart-Label und wirksame
  Restart-Policy explizit.

### Behoben

- die Hyper-V-Storage-Migration ermittelt VHDX-Bindungen jetzt explizit je VM
  über `Get-VMHardDiskDrive -VMName`; das verhindert einen ungültigen
  parameterlosen Hyper-V-Aufruf;
- das Migrationsjournal enthält `CompletedAt` bereits beim Anlegen und kann den
  erfolgreichen Abschluss dadurch unter Strict Mode zuverlässig persistieren;
- PSScriptAnalyzer begrenzt seinen Quellscan jetzt segmentbasiert auf den
  versionierbaren Repositorybestand. Lokale Release-, State-, Cache- und
  Runtime-Kopien vervielfachen die projektspezifische Baseline dadurch nicht;
- der native Hyper-V-Smoke übergibt `Confirm` bei Reconcile-Aktionen als
  booleschen Switchwert; der erhöhte Runner kann den Start-/Stop-Nachweis damit
  ohne Parameterbindungsfehler ausführen;
- SQL-2025-Container mit expliziter Custom-Collation, die während der ersten
  Initialisierung im transienten
  Loginzustand 18456/115 hängen, werden früh erkannt und genau einmal
  scopegebunden neu erstellt. Andere Readiness-Fehler bleiben unverändert
  fail-closed.

### Geändert

- die aktiven Planungs-, Architektur- und Metadaten benennen die drei
  Konsumenten und ihre Rollen: `SQL_PerformanceSchulung` konstruiert Beispiele
  standardmäßig auf einer aktuellen Linux-Umgebung und kann szenariobezogen
  Windows oder andere Katalogversionen anfordern; `SQL_Server_Analyze` und
  `SQL_Server_Toolbelt` führen versionsabhängige Entwicklungs- und Abnahmetests
  auf Windows/Linux mit SQL Server 2019, 2022 und 2025 aus. Die eigene
  SQL-Lab-Runtime-Abnahme bleibt je Provider auf SQL Server 2025 konzentriert;
- neue Instanzen und Datenbanken verwenden ohne explizite Angabe die native
  SQL-Containercollation `SQL_Latin1_General_CP1_CI_AS`. Das vermeidet beim
  SQL-2025-Standardpfad einen unnötigen Umbau der Systemdatenbanken;
  abweichende Collations wie `SQL_Latin1_General_CP1_CS_AS` bleiben explizit
  unterstützt;
- die Runtime-Gates von SQL_Server_Lab verwenden für Docker, Podman, Hyper-V,
  Mixed Provider, Restore und den synthetischen Adapter einheitlich SQL Server
  2025. Mehrversions-Abnahmen sind den Partnerprojekten SQL Analyze und
  Toolbelt zugeordnet;
- der vollständige statische Prüfeinstieg bindet Cleanup-Audit-, Storage-
  Migration- und Versionskatalog-Verträge ein;
- die Versionskatalogprüfung bildet den zusammengeführten Katalogvertrag ab:
  SQL Server 2019, 2022 und 2025 sind unterstützte Containerlinien, SQL Server
  2017 bleibt als explizit veralteter, weiterhin auflösbarer Eintrag erhalten;
- der aktuelle lokale Validierungsstand für Docker und Podman einschließlich
  paralleler und gemischter Runs, Adapter und Restore ist in
  den Quality-Dokumenten festgehalten; der erhöhte Hyper-V-Lifecycle ist grün,
  während die echte SQL-2025-Acceptance wegen der fehlenden Eval-ISO im
  Media-Root blockiert bleibt.

## 2026-08-09

### Hinzugefügt

- realer Hyper-V-Windows-Baseline-Acceptance-Runner für veröffentlichte
  `OS_SEALED`-Images. Er prüft OOBE und regionale Einstellungen, Stop/Start
  über Reconcile, PowerShell Direct nach einem Cold Start, die Abwesenheit
  einer SQL-Instanz sowie scopegebundenen Cleanup und die unveränderte
  Parent-VHDX;
- konfigurierbare Region, System-Locale, UI-Sprache, Eingabemethode und
  Windows-Zeitzone für den Hyper-V-Klonpfad in Konsole, Workflow-UI und
  nicht interaktiver Workflow-Aktion.

### Geändert

- `Invoke-SqlServerLabReconcileAction` reicht einen expliziten `StateRoot`
  jetzt auch an die tatsächlichen Start-/Stop-Executors weiter. Damit stimmen
  Plan und Mutation bei isolierten oder benutzerdefinierten State-Roots überein.
- `New-SqlServerLab` akzeptiert für den deklarativen Hyper-V-Pfad jetzt sowohl
  `SQL_PREPARED_SEALED` als auch `OS_SEALED` als Image-Parent, sodass
  reine OS-Baseline-Manifest-Instanzen ohne SQL-kompatible Build-ID erstellt
  werden können.
- Hyper-V-Fokus-Workflow wurde dokumentiert und in der Slot-Verwaltung weiter
  gestrafft: OOBE-Übernahme (`o`) kann direkt zur SQL-Zielplanung und
  optionaler sofortiger Installation führen; `[a]` führt SQL-Plan und direkte
  Slot-Installation im selben Schritt aus; `[x]` teilt denselben Installationspfad.
- Neue How-to-Dokumentation eingeführt:
  `Documentation/HowTo/HYPERV_SLOT_SQL_WORKFLOW.md` plus Verlinkung im
  Dokumentationsindex.

## 2026-08-08

### Geändert

- `Invoke-SmokeTest.ps1` unterstützt `-Provider hyperv` direkt und startet dafür
  den dedizierten nativen Hyper-V-Smoke-Pfad. Der Aufruf dokumentiert dadurch
  denselben lokalen Nachweisweg für VM-/VHDX-/Image-Builder-Lifecycle wie den
  dedizierten `Invoke-HyperVSmokeTest.ps1`.
- `Tests/Integration/README.md` und `README.md` wurden erweitert, um den
  Hyper-V-Provider als expliziten Einzelprovider-Smoke-Zweig mit aktuellem
  Nachweisstatus (`PASS`) zu dokumentieren.

## 2026-08-07

### Hinzugefügt

- unbeaufsichtigter Manifest-Standard mit externen, eng benannten Prozess-
  Secret-Referenzen für SA-, Gast- und SQL-SA-Passwörter. Klartextsecrets werden
  vom Schema abgelehnt; Remote-Restores können ihre SHA-256 deklarieren und
  enden ohne bekannte Prüfsumme im Automationspfad sicher mit `TRUST_REQUIRED`;
- klarer Dreiklang aus immutable Hyper-V-Vorlagenpool (maximal 20
  `OS_SEALED`-/`SQL_PREPARED_SEALED`-Images), differenzierenden wegwerfbaren
  Labs und expliziten Expertenaktionen. Aktive Lab-Klone schützen ihr Parent-
  Image vor dem Entfernen; Workflow-Übersicht und UI zeigen die Poolbelegung;
- sichere Manifest-Host-Mounts: read-only als Default; schreibende beliebige
  Hostpfade brauchen sowohl `expertActions.hostWriteMounts` als auch
  `-AllowExpertHostWriteMounts`. Die zentrale verifizierte Testdatenbibliothek
  bleibt von den pro Lab getrennten Data-/Backup-Bereichen isoliert;
- sofortige, sichtbare Aktionsrückmeldung in der Workflow-UI: Formulardialoge
  schließen nach Annahme des Auftrags, Live-Log und Herzschlag erscheinen
  unmittelbar; die teurere Medien-/Image-Inventur läuft getrennt im
  Hintergrund statt jeden Sekunden-Poll zu blockieren;
- einheitliche Ressourcenverwaltung für Docker, Podman und Hyper-V. Die Werte
  werden aus der echten Runtime gelesen. Container-Limits werden direkt
  aktualisiert; ausgeschaltete Hyper-V-VMs erhalten vCPU sowie einen begrenzten
  dynamischen Speicherbereich statt unrealistischen 512 MB oder 1 TB;
- Konsolen-Hauptmenü mit einheitlichem Einstieg **Umgebung verwalten** und
  einheitlichen Aktionen für Start/Stopp, Umbenennen, CPU/Speicher und
  Entfernen; Hyper-V-spezifische Windows-/SQL-Schritte bleiben im
  Hyper-V-Zweig;
- die Dokumentation trennt die gemeinsame, verifizierte Testdaten-/Backup-
  Bibliothek im Media Root von den schreibbaren, isolierten Backup-
  Arbeitsbereichen je Lab. Hyper-V verwendet dafür die eigene Daten-VHDX
  (`S:\\SQLData\\Backups`), nicht einen fälschlich suggerierten Host-Mount.

- konfigurierbare sichtbare Testdaten-Bibliothek: Standard ist
  `<MediaRoot>\Testdaten`. Verifizierte Backups, Archive und T-SQL-Skripte
  werden nach Kategorie, Sample und Variante abgelegt und mit `artifact.json`
  dokumentiert; der technische SHA-256-Speicher liegt ebenfalls im Testdaten-
  Root, während State Root nur Staging, Trust und Quarantäne enthält.
- vorhandene, verifizierte Testdaten aus dem bisherigen lokalen State-Cache
  werden bei der nächsten Nutzung ohne erneuten Download in die sichtbare
  Bibliothek übernommen; der alte Cache bleibt unverändert erhalten.

- dynamische Windows-ISO-Erkennung für Windows Server und Windows-Client aus
  `install.wim`/`install.esd`, einschließlich lizenzierter und
  Evaluation-Editionen. Neue und entfernte Medien werden beim nächsten Scan
  automatisch berücksichtigt; der SQL-Prepared-Dialog zeigt nicht kompatible
  Medien sichtbar statt sie zu verbergen. Ältere Windows-Server-1709-Medien
  werden über DISM-Edition und ISO-Namen zuverlässig der 2016er-Familie
  zugeordnet; nicht lesbare ISO-Dateien liefern ihren Fehlergrund sichtbar;
- dynamische Medienauswahl gruppiert Windows Server und Windows Client nach
  Produktfamilie, Version und Lizenztyp; Evaluation-Medien erscheinen getrennt
  von regulären Medien in Konsole und Workflow-UI;
- der frische SQL-Prepared-Builder übernimmt Windows Server 2025 Standard und
  Datacenter aus regulären wie Evaluation-ISOs. Der Lizenztyp wird aus dem
  ausgewählten Medium abgeleitet; ein Evaluation-Ablaufdatum wird nur dafür
  verlangt.
- alle erkannten Windows-Server- und Windows-Client-Medien können im
  SQL-Prepared-Workflow ausgewählt werden. Nicht vorab getestete Kombinationen
  werden sichtbar gewarnt, aber nicht künstlich blockiert.
- optionale 7-Zip-Unterstützung für katalogisierte `.7z`-Archive mit exakt
  einer `.bak`-Payload. Fehlt 7-Zip, wird es nie automatisch nachinstalliert;
  die Konsole bietet dafür nach ausdrücklicher Bestätigung eine lokale
  `winget`-Aktion (`7zip.7zip`);
- typisierte Runtime-Handler für einzelne, SHA-256-verifizierte T-SQL-Skripte
  und sichere ZIP-Backups; ZIP-Payloads werden ausschließlich aus einem
  exakten Katalogpfad in ein temporäres Arbeitsverzeichnis entpackt und danach
  entfernt;
- katalogisierte, auf unveränderliche Upstream-Commits gepinnte Testdaten für
  Northwind und Chinook. Beide können über Konsole, Workflow-UI,
  `New-SqlServerLab -Sample` und Manifeste automatisch geladen werden;
- sichtbare Handler-Typen bei der Auswahl von Testdatenbanken in Konsole und
  Workflow-UI.

## 2026-08-05

### Hinzugefügt

- lokale Browser-Workflow-Oberfläche für den Loopback-Host mit Übersicht über
  Windows-Baselines, SQL-Prepared-Images, offene Build-Schritte,
  Hintergrundaktionen und Live-Log;
- öffentliche, nicht interaktive Workflow-Sicht und schmaler Aktionsadapter für
  die Oberfläche; Gastpasswörter bleiben flüchtig;
- Backlog für die spätere, explizit konfigurierte Steuerung eines entfernten
  Windows-Hyper-V-Hosts.

## 2026-08-03

### Hinzugefügt

- `Private/HyperVSqlImageBuilder.ps1` erzeugt aus einer vorhandenen
  Windows-Server-2025-`OS_SEALED`-Baseline getrennte, resumierbare Builder für
  SQL Server 2019, 2022 und 2025, führt `PrepareImage` und Windows-Sysprep über
  PowerShell Direct aus und veröffentlicht erst nach `Convert-VHD` eine
  eigenständige `SQL_PREPARED_SEALED`-VHDX;
- Windows- und SQL-Evaluation werden getrennt modelliert. Bei SQL SysPrep wird
  der 180-Tage-Zeitraum erst mit `CompleteImage` festgelegt; Developer-Medien
  bleiben als nicht produktionsberechtigt markiert;
- `Initialize-SqlServerLabDataRoot.ps1` erzeugt einen getrennten zentralen
  Daten-Root mit Backup-Übergabeebene und versionsgebundenen Data-/Log-/TempDb-
  Bereichen für SQL Server 2019, 2022 und 2025;
- das Image-Menü bietet den SQL-PrepareImage-Lifecycle einschließlich
  Medienhash, OOBE-Hinweis, Resume nach Setup-Neustart, Publikation und Cleanup;
- die Ubuntu-Installationsanleitung trennt Anwender- und Entwicklungsbedarf und
  beschreibt PowerShell, Docker Engine, Podman, `mssql-tools18`, State und
  Self-hosted Runner aus offiziellen Paketquellen;
- `Initialize-SqlServerLabMediaRoot.ps1` erzeugt aus einem verpflichtenden
  externen Root die kanonische ISO-/VHDX-/SQL-Struktur, sortiert vorhandene
  Medien optional überschreibungsfrei ein und kann SHA-256-Sidecars erzeugen;
- der Media-Root-Initializer erzeugt im Root und in allen Medienzielen
  geschützte lokale `README.md`-Anleitungen mit offiziellen Downloadquellen,
  Ablagepfaden, Auswahlkriterien und Verwendungshinweisen;
- die Image-Aktion im `Invoke-SqlServerLab`-Menü löst Windows-ISOs aus dem
  Media Root eindeutig auf, erzeugt auf Bestätigung ein einzelnes
  SHA-256-Sidecar und führt durch Builder, VMConnect, Sysprep, Publikation und
  scopegebundenen Cleanup;
- vor realem Sysprep verifiziert PowerShell Direct Produkt, Edition,
  Windows-Build und tatsächlichen Installationstyp; abweichende Core-/Desktop-
  Metadaten werden nur nach ausdrücklicher Bestätigung korrigiert;
- der Media-Root-Vertrag dokumentiert Windows-, Linux- und SQL-Medien,
  Pathgrenzen, Hashes und die noch interne Übergabe an den Hyper-V-Builder;
- getrennte Schritt-für-Schritt-Anleitungen richten die Windows-Umgebung für
  AnwenderInnen beziehungsweise für Entwicklung, Native-Tests und Self-hosted
  Runner ein und verlinken ausschließlich offizielle Bezugsquellen;
- die Podman-Dokumentation beschreibt Initialisierung, manuellen Start mit
  `podman machine start podman-machine-default`, automatischen Test-Bootstrap
  und die benutzergebundene Runner-Konfiguration;
- der GitHub-hosted Workflow `Static Contracts` führt die vollständige statische
  Suite auf Windows und Ubuntu aus und stellt stabile Pull-Request-Checks für
  die Branch-Protection bereit;
- `Providers/HyperV/HyperVProvider.ps1` implementiert die erste Hyper-V-
  Lifecycle-Grundlage mit verifizierter read-only Parent-VHDX, Differencing
  Child, Generation 2, Secure Boot, Status, Start, Stop, PowerShell Direct und
  scopegebundenem Cleanup;
- der getrennte Native-Smoke-Test `Invoke-HyperVSmokeTest.ps1` und der Workflow
  `Runtime Smoke - Hyper-V Lifecycle` prüfen VM-/VHDX-Erstellung und Cleanup
  ohne Betriebssystem-, Netzwerk- oder SQL-Provisionierung.
- `Private/HyperVImageRegistry.ps1` importiert operatorseitig bereitgestellte
  sealed VHDX immutable und inhaltsadressiert, prüft SHA-256 und Evidence,
  wählt kompatible Baselines deterministisch und bindet sie hostpfadfrei an das
  Manifest Lock;
- der Hyper-V-Native-Smoke erzeugt die VM aus einem registrierten Test-Artifact
  und beweist, dass Run-Cleanup das globale Parent erhält.
- `Private/HyperVImageBuilder.ps1` ergänzt verifizierte Windows-ISO-Build-Pläne,
  persistente Resume-States und einen Generation-2-/Secure-Boot-/DVD-Builder;
  nicht automatisierte Installation und Generalisierung bleiben explizit
  `MANUAL_ACTION_REQUIRED`.
- Die Image-Builder-Fortsetzung bindet Generalisierungsevidenz per SHA-256 an
  BuildId, ScopeId und Challenge, prüft VM-Auszustand, Identität sowie fehlende
  Checkpoints und veröffentlicht erst danach immutable Registry-Artefakte;
  synthetische CI-Builds bleiben zwingend `LIFECYCLE_TEST_ONLY`.
- Die Hyper-V-Image-Pipeline kann Windows-Sysprep mit `/generalize`, `/oobe`,
  `/mode:vm`, `/quit` und `/quiet` ueber PowerShell Direct ausfuehren. Sie
  validiert danach den Microsoft-ImageState, persistiert einen resumierbaren
  `REBOOT_REQUIRED`-State, beobachtet den Gast-Shutdown und erzeugt die
  buildgebundene Evidenz automatisch; Gast-Credentials werden nicht gespeichert.
- Der Hyper-V-Lifecycle erstellt bis zu 16 validierte run-lokale Zusatz-VHDX
  als `dynamic` oder `fixed`, bindet SQL-bezogene Rollen und SCSI-Attachments
  an die VM-Identität und entfernt alle Disks scope-sicher über den Cleanup-
  Plan. Gastinitialisierungs-E2E-Nachweis und Manifest-Binding bleiben
  ausdrücklich offen.
- Die Windows-Gast-Disk-Orchestrierung ordnet Zusatz-VHDX über ihren SCSI-VPD-
  DiskIdentifier eindeutig `Get-Disk` zu, initialisiert RAW-Disks idempotent als
  GPT/NTFS mit expliziter Allocation Unit und persistiert ausschließlich
  sanitierte Receipts. Ein echter Windows-Gast-CI-Nachweis und die Menü-/
  Manifest-Freigabe bleiben offen.
- Die Hyper-V-Gastspezialisierung setzt einen eindeutigen Windows-Computernamen,
  persistiert den Reboot-Zustand vor dem Neustart und wartet begrenzt auf den
  PowerShell-Direct-Reconnect. Die anschließende SQL-Readiness-Orchestrierung
  prüft SQL-Dienst, Major-Version und die vier Online-Systemdatenbanken und
  speichert ausschließlich sanitierte `SQL_READY_RUN`-Evidenz. Ohne reale
  sealed Baseline bleibt der End-to-End-Nachweis ausdrücklich offen.
- Image-Builder und reguläre Hyper-V-Lab-VMs deaktivieren automatische
  Checkpoints; dadurch bleibt die gebundene Basis-/Child-VHDX der tatsächlich
  angeschlossene Datenträger und es entstehen keine unbeobachteten AVHDX.

### Geändert

- GitHub Actions verwenden `actions/checkout@v7` und
  `actions/upload-artifact@v7` mit der Node-24-Runtime; der Self-hosted Runner
  `2.336.0` erfüllt die Mindestanforderung.

### Behoben

- das Hyper-V-Image-Menü öffnet VMConnect vor dem ersten VM-Start und wartet
  kurz, damit die Tastaturfreigabe zum Booten der Windows-ISO nicht verpasst
  wird;
- ISO-Zeitstempel aus `ConvertFrom-Json` werden typ- und kulturinvariant
  normalisiert; ein Datum wie `2026-08-03` kann dadurch nicht mehr als
  `2026-03-08` in die Sysprep-Evidenz gelangen;
- Evaluation-Ablaufdaten werden ohne fehlerhaften Zugriff auf `Nullable.Value`
  in Registry-Metadaten geschrieben und bei idempotenten Imports verglichen;
- die Image-Publikation erstellt und verifiziert die immutable Registry-Kopie
  vollständig, bevor Builder-VM oder Quell-VHDX entfernt werden. Ein leeres
  oder widersprüchliches Artifact kann den Build nicht mehr auf `OS_SEALED`
  setzen;
- der Legacy-Command-Dokumentationscheck normalisiert relative Pfade und wendet
  seine Allowlist dadurch unter Windows und Linux identisch an.

## 2026-08-02

### Hinzugefügt

- `Tests/Integration/Initialize-PodmanRuntime.ps1` startet eine vorhandene,
  gestoppte Podman-Machine vor Podman-/Mixed-Smoke-Tests automatisch und wartet
  mit hostweitem Lock begrenzt auf Erreichbarkeit;
- `Tests/Static/Invoke-AllChecks.ps1` führt statische Suites in getrennten
  PowerShell-Prozessen aus und erzwingt deren Exitcodes;
- `Tests/Integration/Invoke-RestoreSmokeTest.ps1` prueft einen echten
  synthetischen Backup-/Restore-Lifecycle samt SHA-256, `FILELISTONLY`,
  Providerbindung, Inhalt und Cleanup fuer Docker und Podman;
- neue deterministische Vertragspruefungen decken Cleanupfehler mit
  `RECOVERY_REQUIRED`, erfolgreichen Retry sowie Ready-, Start-, Fehler-,
  Timeout- und Parallelpfade des Podman-Bootstraps ab.

### Behoben

- der Readiness-Contract-Check erkennt den gehaerteten Single-Connection-Pfad
  mit temporaerer UTF-8-BOM-Datei (`-i $tempScriptPath`, `-X1 -x`);
- Runtime-Workflows maskieren fehlschlagende statische Suites und native
  Preflight-Fehler nicht mehr.

## 2026-08-01

### Hinzugefügt

- Project-Adapter-Vertrag `0.1-draft`: `Schemas/project-adapter.schema.json`,
  Resolver mit Pfadgrenzen des Adapter-Roots (keine Traversierung, keine
  Reparse Points) und Ablehnung unbekannter Major-Vertrags- und
  Core-Versionen (`ADAPTER_UNSUPPORTED_CONTRACT`,
  `PROJECT_ARTIFACT_SCOPE_VIOLATION`);
- neue Cmdlets `Test-SqlServerLabAdapter` (read-only Prüfung, optional gegen
  eine Run-Instanz) und `Install-SqlServerLabAdapter` (T-SQL-Entrypoints
  `install`/`update`/`validate`/`cleanup` ohne Lifecycle-Seiteneffekt);
- synthetischer Beispieladapter `Adapters/Examples/synthetic-demo/` und
  statischer Check `Tests/Static/Invoke-ProjectAdapterChecks.ps1`;
- Sample-Backup-Handler (`Private/SampleArtifactHandlers.ps1`): Acquisition und
  Integrität über den Artifact Resolver mit vollständiger Sample-Identität in
  Trust Store und Run Lock, Idempotenzregel `fail-if-exists` und
  ONLINE-Verification der erwarteten Datenbank (`DATASET_READY`);
- Mehrfachauswahl von Testdatenbanken: neuer Parameter
  `New-SqlServerLab -Sample 'id[:variante]'` sowie Menüschritt
  `Testdatenbanken` mit Größen-, Lizenz-, Trust- und Cache-Anzeige und
  Kollisionsprüfung (`SAMPLE_OUTPUT_CONFLICT`);
- Katalogauswahl für `sample`-Felder im Manifest-Wizard mit erwarteter
  Datenbank, Downloadgröße und Lizenz;
- Storage-Assessment berücksichtigt Download- und geschätzte
  Installationsgrößen aufgelöster Sample-/URL-Restores;
- statischer Check `Tests/Static/Invoke-SampleHandlerChecks.ps1` für
  Katalogfilterung, Sample-Auflösung, Idempotenz-/Trust-Vertrag und den nicht
  interaktiven `TRUST_REQUIRED`-Pfad.

### Geändert

- `Invoke-LabSqlScript -KeepConnection` führt das gesamte Skript in einem
  einzigen sqlcmd-Prozess aus (`-i`); `USE`, temporäre Objekte und
  SET-Optionen bleiben damit über `GO`-Batches hinweg erhalten. Betrifft
  Adapter-Entrypoints und postProvision-Skripte von `New-SqlServerLab`;
- `Install-SqlServerLabAdapter` führt den Entrypoint `install` im
  master-Kontext aus, wenn die deklarierte `targetDatabase` noch nicht
  existiert; das Skript darf sie selbst erzeugen. `update`/`validate`/
  `cleanup` setzen eine existierende `targetDatabase` voraus;
- Schema-Pattern für Adapter-Entrypoints prüft nur noch die Form (relativ,
  `.sql`); Pfadsicherheit erzwingt ausschließlich der Resolver
  (eine Quelle der Wahrheit statt divergierender Regeln);
- gemeinsamer Run-Resolver `Resolve-LabRunInstance` (`Private/RunResolution.ps1`)
  ersetzt die lokalen Kopien in `Restore-SqlServerLabDatabase` und dem
  Project-Adapter-Pfad;
- die statischen Checks `Invoke-ProjectAdapterChecks`, `Invoke-SampleHandlerChecks`
  und `Invoke-ManifestBuilderChecks` laufen jetzt im Static-contracts-Step der
  drei Runtime-Smoke-Workflows;
- direkte `.bak`-Backup-Varianten des Sample-Katalogs sind `executable`; die
  Integrität sichert eine Katalog-SHA-256 oder der Trust-Pfad
  `interactive-once` (nicht interaktiv: `TRUST_REQUIRED`);
- Sample-Restores verwenden nicht mehr `WITH REPLACE`; eine vorhandene
  Zieldatenbank blockiert die Installation gemäß `fail-if-exists`;
- Schema- und Doku-Checks koppeln `runtimeStatus: executable` an den
  Backup-Handler statt hart an eine Katalogprüfsumme.

### Behoben

- Adapter-Resolver: Verzeichnis-Junctions/-Symlinks innerhalb des Adapter-Roots
  umgingen die Pfadgrenze (Reparse-Prüfung nur auf der Zieldatei); jetzt wird
  jede Pfadkomponente geprüft (`Test-LabPathWithinRoot` in
  `Private/PathSafety.ps1`);
- Adapter-Resolver: fehlerhafte `adapterContractVersion` oder fehlende/
  fehlerhafte `supportedLabCoreVersions` führten zu einer unbehandelten
  Cast-Exception statt `ADAPTER_INVALID` mit strukturierten Fehlern;
- Adapter-Resolver: die Warnung zu reservierten Package-Feldern erschien
  fälschlich bei jedem Adapter ohne diese Felder;
- `Test-LabProjectAdapterRunCompatibility`: fehlende `requiredCapabilities`/
  `supportedSqlVersions` erzeugten irreführende Fehler (`Capability ''`);
- `Test-SqlServerLabAdapter -RunId`: unbekannte RunId/InstanceId wird als
  strukturierter Fehler (`ADAPTER_INVALID`) gemeldet statt als Exception;
- Adapter-Entrypoints (`Invoke-LabSqlScript -KeepConnection`) werden mit
  deaktivierter sqlcmd-Skriptebene (`-X1 -x`) ausgeführt: `:r`, `:!!` und
  `$(var)`-Substitution sind blockiert, damit ein Entrypoint keine Host-Shell
  aufrufen oder Dateien außerhalb des Adapter-Roots einbinden kann;
- Adapter-Entrypoints werden als UTF-8 mit BOM an sqlcmd übergeben; BOM-lose
  Skripte mit Umlauten werden nicht mehr in der ANSI-Codepage verstümmelt;
- `Install-SqlServerLabAdapter`: die Existenzprüfung der Zieldatenbank wartet
  zuerst auf Serverbereitschaft und bricht bei transienten Verbindungsfehlern
  nicht mehr mit einer rohen Exception ab; die Datenbankbereitschaft wird nur
  noch einmal geprüft (`-SkipDatabaseReadyCheck` statt doppelter Wartezyklen);
- `Test-SqlServerLabAdapter`: eine Ausnahme der Kompatibilitätsprüfung wird
  nicht mehr als „Run-Auflösung fehlgeschlagen“ fehlgemeldet; eine leere
  Instanzversion stuft einen validen Adapter nicht mehr auf `ADAPTER_INVALID`
  herab;
- Adapter-Resolver: eine schema-konforme, aber Int32-überlaufende
  `adapterContractVersion` wird jetzt mit einer Begründung abgelehnt statt mit
  leerer Fehlerliste;
- `Test-LabPathWithinRoot` prüft das Containment auf case-sensitiven
  Dateisystemen (Linux) case-sensitiv, sodass ein nur in der Groß-/
  Kleinschreibung abweichender Pfad nicht mehr als innerhalb des Roots gilt;
- Schema-Pattern für Adapter-Entrypoints lehnt `..`-Traversierung wieder bereits
  offline ab (Defense-in-Depth zusätzlich zum Resolver);
- Adapter-Smoke-Test: ein Fehler beim Lab-Cleanup im `finally` maskiert nicht
  mehr die Ergebnis-/Exit-Auswertung;
- Wizard-Kontextausgabe (`Get-LabManifestInputContextLines`) brach bei jedem
  optionalen Feld mit einem Laufzeitfehler ab (`(if ...)` statt `$(if ...)`).

### Dokumentiert

- Master-Umsetzungsplan um einen Statusabgleich der Wellen (Abschnitt 17a),
  die Klärung der Wellenzählungen und aktualisierte nächste Schritte ergänzt;
- neue Planungsentscheidung
  `Documentation/Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md`:
  Project Adapter (Wellen 6/7) werden vor Hyper-V (Welle 4) umgesetzt.

## 2026-07-30

### Hinzugefügt

- typisierter Sample-Artifact-Vertrag mit Artifact Type, Installation,
  erwarteten Outputs, Größenmetadaten sowie Integrity Origin und Trust Policy;
- `x-ui`-Pfadsemantik im Manifest-Schema und kontextreiche Wizard-Ausgabe mit
  Scope, Bezugsbasis und Vorschau relativer Hostpfade;
- statische Prüfungen für den Artifact-Vertrag und die vollständigen
  `x-ui`-Metadaten aller festgelegten Manifestpfade;
- gemischter Docker-/Podman-Lifecycle mit `ProviderSubRuns` im Run-State und Cleanup-Plan;
- statischer und nativer Smoke-Test für einen gemeinsamen Docker-/Podman-Run;
- ausführbares Beispielmanifest für zwei kompakte Containerinstanzen mit unterschiedlichen Providern;
- maschinenlesbare `x-runtimeStatus`-Klassifikation fuer `serverConfig`-Felder;
- vollstaendige Schema-Validierung der Kataloge und Beispielmanifeste im statischen Check;
- RunId-basierte Restore-Zielaufloesung mit optionaler Instanz-ID;
- SHA-256-Pruefung fuer freigegebene Sample-Downloads und lokale Backups.

### Geaendert

- Sample-Referenzen werden zuerst in den gemeinsamen Artifact-Vertrag
  aufgelöst; nur der bestehende ausführbare Backup-Handler bleibt aktiv;
- Resource Assessment prüft alle in einem Run verwendeten Containerprovider, während RAM, Storage und Ports runweit bewertet werden;
- Status, Start, Stop, Remove und automatischer Fehler-Cleanup arbeiten providergebunden; ein unvollständiger Start wird zurückgerollt oder in `CLEANUP_PENDING` überführt;
- unverifizierte Sample-Varianten sind explizit `descriptive` und werden nicht
  automatisch ausgefuehrt;
- statische Test- und Architektur-Dokumentation bildet den aktuellen Stand ab;
- Windows-Pfade und PowerShell-Testbefehle in `.ai/repo_map.yaml` sind als
  gültige YAML-Scalars quotiert.

### Dokumentiert

- verbindlicher, noch nicht implementierter Zielvertrag für mehrere auswählbare
  Testdatenbanken, typisierte Artifact Handler, einmalige Vertrauensfreigabe mit
  dauerhaftem SHA-256, Trust Store, Manifest Lock und inhaltsadressierten Cache;
- Zielvertrag für SQL-Skript-/Script-Bundle-Installationen, kontextreiche
  Manifest- und Pfadführung, `LAB_GENERATED`-Baselines sowie Hyper-V-Aufsetzpunkte;
- verbindlicher Zielvertrag für Hyper-V, sealed OS-/SQL-Images,
  `PrepareImage`/`CompleteImage`, Drives, Network Intents, providerneutrale
  Software und External Runtimes, Manual Resume, Reconcile sowie Artifact
  Refresh und Rebuild.

## 2026-07-28

### Hinzugefügt

- `New-SqlServerLabManifest` als schema-gesteuerter PowerShell-Konsolen-Wizard für alle Manifestfelder;
- `Test-SqlServerLabManifest` für struktur- und fachbezogene Prüfung ohne Provisionierung;
- Manifestaktion im interaktiven Hauptmenü;
- statischer Regressionstest für Builder, Schema, Kataloge und Runtime-Grenzen.

### Geändert

- der Manifestparser validiert vollständig gegen das JSON-Schema;
- nicht ausführbare Provider-, Versions-, Sample- und Datenbankkombinationen werden vor einer Ressourcenmutation abgelehnt;
- vorbereitete Runtimefelder und riskante SQL-Optionen werden als Warnungen ausgewiesen.
- alle öffentlichen Nomen sind auf den Präfix `SqlServerLab` vereinheitlicht;
	`New-LabManifest`, `Test-LabManifest`, `New-LabDatabase`,
	`Restore-LabDatabase`, `Invoke-LabScript` und `Test-LabResources` wurden ohne
	Kompatibilitätsaliasse oder Deprecation-Zeitraum durch die entsprechenden
	kanonischen `SqlServerLab*`-Commands ersetzt.

## 2026-07-27

### Behoben

- beschädigte PowerShell-Struktur in `Private/VersionCatalog.ps1` repariert;
- CU-Kurzbezeichner werden über den Versionskatalog aufgelöst und unbekannte Builds nicht mehr erraten;
- Restore- und Sample-Datenbanken werden nicht mehr vor dem Restore per `CREATE DATABASE` angelegt;
- Datenbankoptionen werden nach erfolgreichem Restore angewendet;
- Data- und Log-Dateipfade aus Manifesten werden bis zu `New-SqlServerLabDatabase` erhalten und verwendet;
- Start, Stop und Live-Status verwenden den für den Run gespeicherten Provider statt einer global bevorzugten Runtime;
- Docker-Provider-Metadatum von `DockerProvider.psm1` auf die tatsächlich geladene Datei `DockerProvider.ps1` korrigiert;
- nicht implementierte Exporte aus `SqlServerLab.psd1` entfernt;
- fehlerhafte Restore-Beispiele und individuelle lokale Pfade aus Getting Started entfernt;
- falsche Aussage korrigiert, der Auto-Smoke-Test provisioniere alle installierten Provider.

### Hinzugefügt

- JSON-Schema für den SQL-Version-Katalog;
- JSON-Schema für den Sample-Datenbank-Katalog;
- Auflösung direkter `.bak`-Sample-Varianten im Manifestparser;
- verbindliches Dokument der bekannten Runtimegrenzen;
- maschinenlesbare Repository-Landkarte `.ai/repo_map.yaml`;
- lokale statische Vertrags- und Dokumentationsprüfung;
- Beitrags-, Security- und GitHub-Governance-Artefakte.

### Geändert

- Root-README vom Planungsstatus auf den implementierten Container-Core und den tatsächlichen Benutzerfluss umgestellt;
- Dokumentationsindex, Getting Started, Katalog-, Schema-, Public- und Testdokumentation an den Codevertrag angeglichen;
- ausführbare Manifestbeispiele auf vorhandene Dateien und tatsächlich angewendete Felder reduziert;
- Sample- und Restore-Vertrag ausdrücklich voneinander und von `CREATE DATABASE` getrennt.

## Frühere Änderungen

Ältere Änderungen sind derzeit über die Git-Historie und die vorhandenen Projektplanungsdokumente nachvollziehbar. Sie werden nicht rückwirkend ohne belastbare Zuordnung in dieses Changelog übertragen.
