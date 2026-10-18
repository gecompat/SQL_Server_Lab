# SSIS ETL-, Data-Warehouse- und Recovery-Lab – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-10-18 |
| Primärzweck | reproduzierbare SQL-Server-Integration-Services-Szenarien |
| Planungsumfang | eigener SSIS-Server und ETL-Ausbau; vorhandene SSISDB-Referenz separat abgenommen |

## P1: Katalog-Runtime nach dem Consumervergleich vom 2026-10-18

**Rest offen, hohe Priorität; eigene Wiederherstellung belegt:** Der beauftragte
[Vergleich der ursprünglichen Consumerpakete](../Quality/LOCAL_VALIDATION_STRATEGY.md#ursprüngliche-consumerfehler-gast--und-katalogvergleich-vom-2026-10-18)
bestätigt deren fehlerfreies SDK-Laden, aber keine funktionsfähige
OLEDB-/SQL-LogProvider-Katalogpipeline. Die ursprünglichen unbekannten
Komponententypen wurden nicht erneut beobachtet; ihre historische Ursache
ist weiterhin unbekannt. Die aktuelle Katalogruntime meldet einen
Editions-/Installationsfehler trotz vorhandenem IS und Enterprise-Developer-
Engine. Eine Validierung meldete dabei Status `7` samt Fehlerereignis.

Die Administratorfreigabe wurde anschließend erteilt und der
[isolierte Reparaturvergleich](../Quality/LOCAL_VALIDATION_STRATEGY.md#isolierter-reparaturvergleich-mit-echten-verbindungen-vom-2026-10-18)
mit genau einer eigenen VM ausgeführt. Frische IS-Installation,
Instanzreparatur und CU9 beseitigten den beobachteten SQL-LogProvider-Fehler
nicht. `MSOLEDBSQL19` schrieb dabei erfolgreich über eine verschlüsselte
Windows-Verbindung; es entstanden jedoch keine `sysssislog`-Zeilen und die
Katalogausführung endete mit Status `4`. Der frühere Administratortoken-Blocker
ist geschlossen, die fachliche Behebung bleibt offen. Eigene VM und eigene
VHD wurden entfernt; die erhaltene Analyze-Quelle samt Fixture blieb unverändert.

Der anschließende [Registrierungsvergleich](../Quality/SSIS_CATALOG_REGISTRATION_RECOVERY_2026-10-18.md)
hat die fehlende IS-MSI-/Editionsregistrierung erkannt und mit unterstütztem
IS-only-Setup unter SYSTEM wiederhergestellt. Drei echte Basic-Katalogtests
bestanden, auch nach geordnetem Windows-Neustart, mit verschlüsseltem
Windows-SQL-Schreibzugriff und je zwölf SQL-LogProvider-Zeilen. Die tatsächlich
geladenen Katalogmodule sind erfasst. Das eigene Lab wurde entfernt; die
Analyze-Quelle blieb unverändert. Dieser aktuelle Editions-/Installations-
blocker ist im eigenen Lab behoben; die ursprünglichen Typfehler sind
historisch weiterhin nicht vollständig erklärt.

**Nächster P1-Nachweis:** einen vollständig frischen öffentlichen
Provisionierungslauf mit dem korrigierten Komponenteninstaller ausführen und
daran die begrenzte Basic-OLEDB-/SQL-LogProvider-Abnahme wiederholen. Der
produktive Registrierungsreader wurde bereits lesend nativ geprüft; die
erfolgreichen Pakettests stammen aus dem unabhängig geprüften isolierten
Diagnosecontroller. Weitere Consumerpakete und Analyzervergleich bleiben
eigene Abnahmen. Kein erneuter unveränderter Fehlversuch und keine manuelle
Änderung von Lizenz-/Editionsregistrierung; die bestehende Analyze-Quelle
bleibt geschützt.

Vor einem Installations- oder Reparaturschritt sind dessen Herstellerweg,
Ausgangszustand und Recovery zu prüfen. Danach sind Komponentenladung,
Katalog-Fehlerereignisse, echte SQL-Verbindung und tatsächlich geschriebene
`sysssislog`-Ereignisse gemeinsam nachzuweisen. Weder bloße Dateipräsenz noch
SQL-Engineedition, Setup-Exitcode, Validierungsstatus oder SDK-Laden allein
qualifizieren diesen Pfad. Ohne neue Evidence werden die unveränderten
fehlgeschlagenen Läufe nicht wiederholt. Die in SQL_Server_Analyze separat
abgeschlossene begrenzte Legacy-Providerabnahme wird nicht neu geöffnet.

Dieser Diagnosefolgeauftrag ist vom nachfolgenden allgemeinen SSIS-Server-
und ETL-Ausbau getrennt und erklärt dessen Arbeitspakete nicht zu geliefert.

## Machbarkeit und Integrationsentscheidung vom 2026-10-16

Ein eigener Server mit installierter SSIS-Runtime ist möglich und für das Lab
relevant. Er ermöglicht Paketdeployment, echte Datenflüsse, SQL-Agent-Betrieb
und Fehler-/Recoverytests unabhängig von den Ressourcen des Quellservers.
Der vorhandene Windows-/Hyper-V-Pfad wird dafür erweitert. Ein zusätzlicher
Provider oder ein zweites Provisionierungssystem ist nicht erforderlich.

Der nachfolgende Benutzerauftrag vom 2026-10-16 autorisiert die schrittweise
Umsetzung dieses Integrationsplans **nach Abschluss von TLS-001**. Zuerst
werden SSIS-LAB-001/002 als eigenständiges SSIS-Serverprofil ohne Pflichtfixture
geliefert; weitere Schritte folgen in der unten beschriebenen Reihenfolge.
Die Umsetzung muss innerhalb dieses Auftrags nicht erneut pauschal bestätigt
werden. Konkrete zusätzliche Lizenz-, Trust-, Kosten- oder geschützte
Mutationsgrenzen bleiben erhalten.

Die Startbedingung ist die dokumentierte vereinbarte positive/negative native
TLS-Lab-Abnahme einschließlich der erforderlichen finalen Gates und Integration.
Ein fertiger TLS-Entwurf, einzelne grüne Metadatensuites oder ein noch offener
TLS-Pull-Request erfüllen sie nicht. Bis dahin bleibt die SSIS-Implementierung
ausstehend. Der bestehende Lab-Orchestrator führt die Reihenfolge gemäß
[Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md#12-verbindlich-berücksichtigte-planungsquellen)
mit genau einem Implementierer je atomarem Scope fort. Die Arbeitspakete
bleiben `planned`, solange Code und erforderliche Nachweise fehlen; die
bestehende Fixtureabnahme schließt sie nicht ab.

Stand der Übernahme vom 2026-10-18: Der begrenzte operative Windows-/Docker-
TLS-Pfad ist inzwischen integriert und nativ abgenommen; die verbleibenden
TLS-001- und Consumergrenzen stehen im [TLS-Backlog](NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen).
Dieser Dokumentationsabgleich beginnt keine SSIS-Implementierung und erklärt
die nachfolgenden Arbeitspakete nicht zu implementierten Funktionen.

### Tatsächlicher Bestand und verbleibende Lücke

| Fähigkeit | Belegter Stand | Grenze |
|---|---|---|
| Eigene Windows-/Hyper-V-VM mit SQL 2025 und installierter SSIS-Komponente | `Install-SqlServerLabSsisComponent` ergänzt `IS` aus vorhandenen hashgebundenen Medien; die öffentliche Prepared-/Manifest-Neuerstellung ist nativ abgenommen | Additive Neuinstallation nur SQL 2025 Enterprise Developer; keine allgemeine Editions-/Versionsfreigabe |
| SSISDB mit tatsächlicher Paketausführung | Die [Windows-Abnahme](../Quality/SSISDB_WINDOWS_RUNTIME_ACCEPTANCE_2026-10-16.md) belegt SQL/IS `17.0.1000.7`, Erfolg, Fehler und ungestarteten Fall sowie Cleanup | Synthetische Packages mit erzwungenem Ergebnis, ohne Datenquelle oder Data Flow; kein ETL-Nachweis |
| Deklarative Neuerstellung | `instances[].ssisCatalogFixture` bindet Prepared-Slot, IS-Installation und Analysefixture | Genau eine Hyper-V-/Windows-/SQL-2025-Instanz; Serverbereitstellung und drei Analysefälle sind gekoppelt |
| Eigene Consumerprojekte | Der zusätzliche [Windows-Skriptzugang](../HowTo/SSIS_CONSUMER_WINDOWS_ACCESS.md) ist integriert; seine [native Abnahme](../Quality/WINDOWS_SQL_CONSUMER_ACCEPTANCE_2026-10-16.md) belegt Deployment, Paketstart und eigenen Cleanup | Kein allgemeiner Paketkatalog oder Deploymentworkflow; keine Abnahme beliebiger OLE-DB-Komponenten oder fachlicher ETL-Packages |
| Frische vollständige Installation von `SQLENGINE,IS` auf einem OS-Slot | Interner Installationsharness vorhanden | Eigenständige vollständige Installationskette weiterhin ohne native Abnahme; der grüne Prepared-Pfad ersetzt sie nicht |
| Frei konfigurierbares SSIS-Serverprofil und SQL-ETL | Geplant | Keine unabhängige deklarative Serverrolle, verwaltete Projektartefakte oder Full-/Delta-Load-Abnahme |

Die Bestandsermittlung umfasst die öffentlichen SSIS-Cmdlets,
`Private/SsisOwnedInstall.ps1`, `Private/SsisPrerequisite.ps1`,
`Private/ManifestParser.ps1`, `Public/New-SqlServerLab.ps1` und
`Schemas/lab-manifest.schema.json`. Maßgeblich für das vorhandene Verhalten
bleibt der [SSISDB-Vertrag](../Architecture/SSISDB_TEST_FIXTURE.md).
Die belegte Consumertransport-Abnahme ersetzt keine format-, komponenten- und
projektspezifische Deployment- oder ETL-Abnahme der folgenden Arbeitspakete.

### Herstellerabgleich und gewählte Topologie

Die folgenden Microsoft-Primärquellen wurden am 2026-10-16 geprüft und beim
Dokumentationsabgleich am 2026-10-18 erneut gelesen. Sie
belegen Produktmöglichkeiten; die Lab-Topologie und Lieferfolge sind die
daraus abgeleitete Planung.

| Produktgrenze | Konsequenz für das Lab |
|---|---|
| [SSIS lässt sich separat oder neben einer Engine installieren](https://learn.microsoft.com/en-us/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17); für einen dedizierten ETL-Server empfiehlt Microsoft eine lokale Engine | Eigene SSIS-VM mit lokaler SQL-Engine und SSISDB als Referenzprofil; Quell- und Warehouse-Server können später getrennt sein |
| Der [SSIS-Server ist die Engineinstanz mit SSISDB](https://learn.microsoft.com/en-us/sql/integration-services/catalog/integration-services-ssis-server-and-catalog?view=sql-server-ver17) | Ein entfernter Aufruf von `catalog.start_execution` verlagert die Ausführung nicht automatisch auf einen weiteren Rechner mit installierter SSIS-Komponente |
| Der [ältere SSIS-Windowsdienst](https://learn.microsoft.com/en-us/sql/integration-services/service/integration-services-service-ssis-service?view=sql-server-ver17) verwaltet Legacy-Pakete und ist für die Paketausführung nicht erforderlich | `MsDtsServer170` darf im bestehenden Katalogprofil deaktiviert bleiben; Dienststatus allein ist kein Runtime- oder ETL-Nachweis |
| [Scale Out](https://learn.microsoft.com/en-us/sql/integration-services/scale-out/integration-services-ssis-scale-out?view=sql-server-ver17) verteilt Ausführungen auf weitere Rechner | Getrennte Worker bei zentralem Katalog sind eine spätere Capability des [Cluster-Backlogs](SQL_SSIS_SSAS_CLUSTER_BACKLOG.md), kein Nebenprodukt der Serverrolle |
| [Linux-Grenzen](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-ssis-known-issues?view=sql-server-ver17) schließen SSISDB aus und nennen SSIS für SQL 2025 als nicht verfügbar; die [Linux-Installation](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-ssis?view=sql-server-ver17) ist keine qualifizierte Containerlane dieses Labs | Keine SSIS-Runtime auf Docker oder Podman einplanen; dort sind ausschließlich getrennt qualifizierte SQL-Quellen und -Ziele vorgesehen |

Die erste Lieferung stellt eine dedizierte Windows-Server-2025-/SQL-2025-
Enterprise-Developer-VM mit SSIS und lokaler SSISDB bereit. Eine kleine
SQL-Quelldatenbank und ein logisch getrenntes Warehouse liegen für die erste
ETL-Abnahme auf derselben VM. Damit kann der Datenfluss ohne neue
rechnerübergreifende Identitäts- und Netzwerkabhängigkeiten geprüft werden.

In einer zweiten Topologie bleiben Engine, SSISDB und SSIS auf der dedizierten
ETL-VM; Quelle und Warehouse wechseln auf weitere eigene SQL-VMs. Erst danach
folgen optionale Docker-/Podman-Quellen oder -Ziele mit getrenntem Nachweis.
Ein SSIS-Rechner ohne lokale Engine mit Dateipaketen und `dtexec` ist eine
gesonderte spätere Lane mit eigenem Deployment-, Scheduling- und
Ausführungsortvertrag. Ein entfernter SSISDB-Katalog allein weist ihm keine
Packages zur Ausführung zu.

SSMS sowie Visual Studio/SSDT sind optionale Verwaltungs- beziehungsweise
Entwicklungsclients. Ihre Installation ersetzt keine Serverruntime.
Die erste Lieferung verarbeitet vorhandene freigegebene Medien und ein
versioniertes synthetisches ISPAC. Neue Downloads, ein Builddienst und
Drittanbieterconnectoren gehören nicht dazu. Der Beschaffungscheckpoint G
bleibt unabhängig davon offen.

### Geplante Arbeitspakete

Alle IDs dieser Tabelle sind neue Planungskennungen. Sie bezeichnen keine
implementierten Commands oder aktuell akzeptierten Manifestfelder.

| ID | Umsetzung und betroffene Verträge | Abnahme / Voraussetzung |
|---|---|---|
| SSIS-LAB-001 | Serverbereitstellung von Analysefixture trennen: bestehenden IS-Installer und versionsgebundene Kataloganlage wiederverwenden, eigenständigen Katalogpfad ohne die drei Analysepackages herauslösen. `Private/SsisOwnedInstall.ps1`, öffentliche SSIS-Verträge und `SSISDB_TEST_FIXTURE.md` gemeinsam führen | Vorhandene Kataloge erhalten; erneute Installation/Anlage ohne Duplikate; bisherige Fixture mit unverändertem Rückgabe- und Cleanupvertrag. Komponentenbeobachtung, Katalogbereitschaft und Ausführung getrennt ausweisen |
| SSIS-LAB-002 | Deklaratives SSIS-Serverprofil additiv in Schema, Parser und `New-SqlServerLab` integrieren; eigener Opt-in für Komponente und Katalog, ohne Pflichtfixture. Bestehendes `ssisCatalogFixture` bleibt kompatibel; widersprüchliche Doppelangaben vor Mutation abweisen | Erst nach SSIS-LAB-001: passendes Beispielmanifest, Hilfen, CLI-/Browser-Manifestzugang und Capabilityentscheidung. Medien-/Edition-/Provider-/Ressourcenprüfung vor VM-Anlage; vorhandener Prepared-/CompleteImage-Pfad und registrierte `Lab_Data`-Roots |
| SSIS-LAB-003 | Digestgebundene, freigegebene ISPAC-Projekte über vorhandene Artefakt-/Ressourcenverträge anbinden: Runtimeziel, Projektname, Packageinventar, Quelle/Lizenz, Größe und erforderliche Treiber deklarieren; Installationsmedien davon trennen | Vor Deployment kompatibles Projektformat sowie Größen-/Archivgrenzen prüfen; keine ungeprüften Drittanbieter-Tasks. Gleicher Digest ergibt No-op, neue Revision einen expliziten Änderungsplan; keine unkontrollierte Versionsfolge |
| SSIS-LAB-004 | Gebundenen Deployment-/Ausführungspfad für eigene Folder, Projekte, Environments und Parameter ergänzen; gemeinsamen Windows-Gasttransport und geschützten Secretstore verwenden | Integrierter und nativ geprüfter Consumertransport oder gleichwertig qualifizierter vorhandener SSIS-Gastpfad erforderlich. Projekt-ID, Versions-LSN, Execution-ID und Eigentum quittieren; endliche Wartefrist, gezielter Abbruch und keine blinde Startwiederholung |
| SSIS-LAB-005 | Synthetischen SQL-zu-Warehouse-Durchstich mit Staging, einer Dimension und einer Faktentabelle nach Project-Deployment-Modell liefern; vorhandene Szenariometadaten und Abnahmeharness-Verträge verwenden | Nach SSIS-LAB-003/004 und betroffenen Szenariogates: Full Load, unveränderter Rerun und feste Insert-/Update-/Delete-Folge mit exakten Schlüsseln, Zeilen, Summen und Rejects. Tatsächliche Datenbewegung ohne `ForceExecutionResult`; Datenwirkung und Fortschritt gemeinsam committen |
| SSIS-LAB-006 | SQL-Agent-Scheduling und Betrieb ergänzen: nur eigene Jobs, freigegebene Ausführungsidentität, Retention/Logging innerhalb des eigenen Scopes, Stop/Start und Recovery | Nach erfolgreicher direkter Ausführung: manuell gestarteter eigener Agentjob, terminaler Paketstatus, VM-Neustart, Fehler vor/nach Zielcommit und Antwortverlust. Keine produktiven Zeitpläne; Objekt- und vollständiger Run-Cleanup mit Fremdobjektschutz |
| SSIS-LAB-007 | Geführtes SSIS-Serverprofil in CLI und Browser: vorhandene Medien/Prepared-Quelle wählen, Komponenten, Katalog, Projekte und letzte Ausführung getrennt anzeigen | Gemeinsamer öffentlicher Kern, identische Capabilitygrenzen, Preview/WhatIf/Abbruch ohne Mutation; generischer Exportzugang bleibt bis zur gerenderten Fachabnahme als solcher bezeichnet |
| SSIS-LAB-008 | Dedizierte ETL-VM mit entfernten SQL-Quellen/-Zielen in bestehende Mehrinstanz-/Topologieverträge einordnen | Erst nach Ein-VM-Abnahme und ausführbarem Topologie-/Ownershipvertrag: DNS, Ports, authentifiziertes TLS, Runtimeidentität und Rechte positiv/negativ prüfen. Windows-Authentifizierung benötigt einen eigenen Domänen-/Delegationsvertrag; der Host-Gastzugang delegiert kein Clientkonto. Docker/Podman und Mixed separat abnehmen |

Das API-/Manifestdesign von SSIS-LAB-001/002 ist vor Codeänderung im
Fachvertrag festzulegen; dieser Backlog führt bewusst kein ausführbares neues
Feld ein. Komponentenstatus, vorhandener Katalog, erfolgreiches Deployment,
laufende Ausführung und fachliches ETL-Ergebnis bleiben getrennte Aussagen.
Die erste Serverlieferung benötigt keinen neuen allgemeinen Workflowexecutor;
der vollständige ETL-/Resume-Pfad muss die betroffenen Szenariogates erfüllen
und darf keinen parallelen generischen Executor aufbauen.

### State, Sicherheit und Recovery des Zielvertrags

- Vor der ersten Mutation Operation, Run-/Scope-/VM-Bindung, erwartete
  Artefaktrevision und Cleanupplan lokal festhalten; verlorene Antworten
  anhand dieser Bindung prüfen. Ein Timeout bestätigt keinen Rollback.
- Installation/Katalogadministration und Paketidentität trennen. Vorhandene
  Sysadmin-Evidence ersetzt keine Least-Privilege-Abnahme; ein eigener
  Ausführungsnutzer muss erlaubte Aktionen ausführen und fremde ablehnen.
- Secretreferenzen und sensitive SSISDB-Parameter lokal auflösen; keine Werte
  in Manifest, Kommandozeile, Logs oder Receipt. Katalogschlüssel und
  Parameter sind bei Backup/Restore eigene Recoveryartefakte.
- Packages sind ausführbarer Code. Nur explizit freigegebene eigene oder
  lizenzierte synthetische Projekte verwenden; administrative Gastrechte
  begründen keine sichere Ausführung beliebiger fremder Packages.
- Aktive eigene Executions vor Projektentfernung identitätsgebunden beenden.
  Zusätzliche/fremde Projekte, Environments und Jobs blockieren übergreifenden
  Objektcleanup; vollständiger Run-Cleanup bleibt an die VM-Ownership gebunden.
  Die bewusst erhaltene Analyze-Quelle wird nicht für neue Versuche verwendet.
- CPU, RAM, VM-/Datenplatten und Medienbudget aus der bestehenden
  Ressourcenplanung beziehen. Ein VM-Deployment ohne Datenfluss ist keine
  Kapazitätsmessung; Speicher und Laufzeiten im ersten isolierten Lauf erfassen.

### Prüf- und Lieferfolge

1. SSIS-LAB-001/002 als begrenzte Serverlieferung: Offlinechecks für Provider,
   Edition, Medienhash, Katalogzustand, No-op, WhatIf, Identitätswechsel und
   Cleanup; betroffene Suites über `Invoke-ImpactedChecks.ps1` auswählen.
2. Genau einen eigenen Prepared-/Manifest-Run mit SSIS und SSISDB neu erzeugen,
   eine temporäre reale Paketausführung prüfen, deren Objekte gezielt entfernen,
   VM neu starten und vollständigen Run-Cleanup bestätigen. Bestehende
   Fixturefälle 7/4/1 und Fremdobjektschutz als betroffene Regression erhalten.
   Die frische OS-/`SQLENGINE,IS`-Kette bleibt ein getrennter Nachweis.
3. SSIS-LAB-003 bis -005 mit einem begrenzten synthetischen Projekt abnehmen:
   Deployment/No-op/Revision, Secret- und Rechtefehler, echter Full-/Delta-Load,
   terminaler SSISDB-Status und fachliche SQL-Assertions.
4. SSIS-LAB-006/007 ergänzen: Agent, Fehler/Resume, Restart, gezielter und
   vollständiger Cleanup sowie gerenderte Bedienabnahme. Fehler und
   Cleanupfehler getrennt ausweisen; nach unbestätigtem Start keine zweite
   Execution ohne Zustandsprüfung erzeugen.
5. SSIS-LAB-008 und danach Scale Out/HA als eigenständige Erweiterungen prüfen.
   Ein-VM-Evidence gilt weder für entfernte SQL-Ziele noch für mehrere Provider.

Die bestehende [BI-Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md) ordnet
den vollständigen ETL-Ausbau relativ als **L** ein. Der Serverausbau ist eine
begrenzte Teillieferung; eine belastbare Zeit-/Ressourcenschätzung folgt auf
das konkrete Vertragsdesign und Medieninventar. Diese Planung ändert keine
Workflowregeln und startet keine Runtime. Ihre Prüfung umfasst ausschließlich
Dokumentationskonsistenz und den ausgewählten statischen Gate.

## Ziel

Das Lab soll eine vollständig automatisierte SSIS-Testumgebung bereitstellen,
in der Packages entwickelt beziehungsweise als freigegebene Artefakte
eingespielt, nach SSISDB deployed, parametrisiert, ausgeführt, beobachtet,
gestört, wiederaufgenommen und entfernt werden können.

Der erste Referenzpfad verwendet SQL Server und Integration Services unter
Windows in einer Hyper-V-VM. SQL-Quellen, Staging- und Zielinstanzen dürfen je
nach Szenario zusätzlich unter Docker oder Podman laufen. SSIS bleibt die
primäre SQL-Komponente; Datei-, Object-Storage-, Client- und Monitoring-Dienste
sind ausschließlich Supporting Components.

## Anwendungsszenarien

### ETL-Grundlagen

- CSV-, JSON-, XML-, ODBC- und SQL-Quellen mit katalogisierten Beispieldaten;
- typisierte Konvertierung, Lookup, Merge, Aggregate und Conditional Split;
- getrennte Fehlerausgänge und nachvollziehbare Reject-Daten;
- Bulk- und Fast-Load-Verhalten;
- Data-Profiling und maschinenprüfbare Zeilen-, Hash- und Summen-Assertions.

### Data-Warehouse-Aufbau

- Staging-, Dimensions- und Faktentabellen;
- Surrogate Keys und referenzielle Integrität;
- Star Schema und kontrollierte Columnstore-Varianten;
- Slowly Changing Dimensions für feste, überschreibende und historische
  Attribute;
- initialer Full Load und wiederholbarer Delta Load.

### Inkrementelle Verarbeitung

- High-Water-Mark- und Change-Tracking-Lanes;
- SQL-CDC und SSIS-CDC-Komponenten als editionsgebundene Windows-Lane;
- Insert-, Update- und Delete-Verarbeitung;
- verspätete beziehungsweise doppelte Eingangsdaten;
- idempotenter Wiederanlauf ohne doppelte Fakt- oder Dimensionszeilen.

### Deployment und Betrieb

- Project- und Package-Deployment-Modell als getrennte Capabilities;
- SSISDB mit Foldern, Projekten, Packages, Parametern und Environments;
- lokale Secret-Referenzen statt persistierter Klartextwerte;
- Ausführung über SSISDB und katalogisierte SQL-Agent-Jobs;
- Logging, Execution Reports, Retention und sanitisierte Betriebs-Evidence;
- Package- und Project-Versionierung sowie kontrollierter Rollback.

### Migration und Kompatibilität

- Package-Ausführung gegen SQL Server 2019, 2022 und 2025;
- Side-by-side-Installation beziehungsweise getrennte Runtime-Images;
- Upgrade von Project- und Package-Format mit vorheriger Kopie;
- Treiber-, Provider-, Connection-Manager- und Compatibility-Prüfung;
- identische fachliche Assertions vor und nach Upgrade;
- Abweichungen zwischen Standard- und Enterprise-Capabilities.

### Fehler, Resume und Recovery

- Abbruch von Quelle, Ziel, SQL Agent oder SSIS Runtime;
- Netzwerkunterbrechung, Timeout und Credential-Rotation;
- fehlerhafte, unvollständige und schemaabweichende Eingabedaten;
- begrenztes Disk-Full-Ziel für Staging, Log oder SSISDB;
- Checkpoints, Transaktionsgrenzen und Compensation;
- Wiederholung nach Prozess-, VM- und SQL-Restart;
- Nachweis, dass weder Datenverlust noch unerkannte Duplikate entstehen.

### Performance und Scale Out

- Buffer-, Batch-, Commit- und Parallelism-Konfiguration;
- konkurrierende Packages und Resource-Contention;
- Fast Load gegenüber zeilenweiser Verarbeitung;
- SSIS Scale Out mit Master und katalogisierten Workern;
- Worker-Ausfall, Queue-Verhalten und erneute Zuweisung;
- Durchsatz- und Laufzeitvergleich ohne absolute Aussage aus einem Einzelhost.

## Provider- und Plattformvertrag

- Hyper-V/Windows ist der verpflichtende vollständige Referenzpfad für SSIS,
  SSISDB, SQL Agent, Windows Authentication, CDC und Scale Out.
- Docker und Podman dürfen SQL-Quellen, Staging-, Warehouse-, Ziel-, Client-
  oder Fault-Komponenten bereitstellen und benötigen getrennte Runtime-Evidence.
- SSIS unter Linux ist nur eine optionale, versionsgebundene reduzierte Lane.
  SSISDB, SQL-Agent-Scheduling, Windows Authentication, CDC, Scale Out,
  Drittanbieterkomponenten und weitere Features sind dort nicht verfügbar.
- SSIS ist laut aktuellem Herstellerstand nicht für SQL Server 2025 unter
  Linux verfügbar. Daraus folgt kein Container- oder Linux-2025-Versprechen.
- Ein frei gebautes SSIS-Containerimage gilt nicht ohne Herstellerfreigabe,
  katalogisierte Recipe und reale Evidence als unterstützt.

## Artifact-, Lizenz- und Security-Vertrag

- SQL-/SSIS-Installationsmedien, SSDT-Erweiterungen, Treiber und Packages
  erhalten Version, Quelle, Digest, Lizenz und Capability Record.
- Developer Editions werden ausschließlich für Entwicklung und Test verwendet;
  Standard- und Enterprise-Zielprofile bleiben getrennt.
- Packages, Konfigurationsdateien und Connection Manager enthalten keine
  Secrets oder realen Infrastrukturwerte.
- Drittanbieter-Tasks und -Connectoren benötigen ein eigenes Lizenz-,
  Security-, Maintenance- und Exit-Review.
- Testdaten sind synthetisch oder ausdrücklich redistributierbar.

## Erster Vertical Slice

### Begrenzter Diagnoseeinstieg zu Schritt 1

`Tools/Test-SqlServerLabSsisPrerequisite.ps1 -RunId $runId -InstanceId primary`
beobachtet eine bereits laufende eigene Hyper-V-/Windows-/SQL-2019-, -2022-
oder -2025-Instanz. Der öffentliche, ebenfalls rein lesende Vertrag
`Get-SqlServerLabSsisCatalogCapability` projiziert dieselbe gebundene
Voraussetzung ohne Secrets, Endpunkte oder lokale Pfade. Der interne Einstieg verwendet
den bestehenden StateRoot, bindet Run, Instanz und tatsächliche VM-ID und
verweigert WinRM-Fallback. Der Gasttransport ist auf 10 bis 120 Sekunden,
die SQL-Abfrage auf höchstens 30 Sekunden begrenzt. Secrets bleiben flüchtig;
Ergebnisse und Diagnosen dürfen ausschließlich lokal verwendet werden.

Getrennte Beobachtungen sind tatsächlicher SQL-Major und Edition, zwei
SSIS-Komponentendateien mit dem zur beobachteten Engine passenden Dateimajor
(15, 16 oder 17) am dokumentierten Standardpfad sowie
SSISDB-Zustand und Vorhandensein der Katalogsicht `catalog.catalog_properties`.
`DefaultPathComponents=NOT_OBSERVED` bedeutet nur fehlende Dateien dort.
Konfigurierbare andere Installationsorte werden nicht durchsucht; fehlende
Standarddateien beweisen keine fehlende SSIS-Installation. Zugriffsfehler,
Reparse-Dateien und unpassende Dateiversionen liefern `UNKNOWN`.
Der SQL-Check wertet SSISDB-Abwesenheit ausschließlich mit beobachteten
Sysadmin-Sichtrechten aus, damit unsichtbare oder offline Datenbanken nicht
als fehlend ausgegeben werden. Eine gewöhnliche Datenbank namens SSISDB ohne
Katalogsicht bleibt `ONLINE_UNVERIFIED`.

`OBSERVED` beschreibt Beobachtungen, keine erfüllten Voraussetzungen oder
Ausführungsfreigabe. `InstallationVerified=false` und
`ExecutionStatus=NOT_EXECUTED` bleiben immer erhalten. Editionserkennung beweist
keine SSIS-Featureberechtigung. Es gibt keine Installation, SSISDB-Erstellung,
Packageausführung, VM-Start, Zustandsänderung oder automatische Reparatur.
Bindungsänderungen während der Probe verwerfen das Ergebnis. SQL- und
Transportfehler bleiben sanitisiert und von fehlenden Komponenten getrennt.

Die Offline-Suite `Invoke-SsisPrerequisiteChecks.ps1` prüft tatsächliche
Entscheidungs-, Kontext- und Gastlesefunktionen mit synthetischen Ergebnissen,
Identitätsabweichungen, Sichtrechten, Fehlern, Timeout und Secretentsorgung.
Die Offline-Suite allein belegt keine native Voraussetzungenprüfung oder
ETL-Abnahme. Die inzwischen ausgeführte enge Windows-/SSISDB-Abnahme ist
unten und im aktuellen Bestandsabschnitt getrennt belegt. Der vollständige
ETL-Backlog bleibt offen.

Herstellergrundlagen: [Dateipfade und gemeinsame SSIS-Komponenten](https://learn.microsoft.com/sql/sql-server/install/file-locations-for-default-and-named-instances-of-sql-server?view=sql-server-ver17),
[SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17)
und [Sichtrechte für sys.databases](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17).

### Vollständige noch offene Folge

Der interne IS-only-Einstieg
`Tests/Integration/Invoke-SsisOwnedInstallAcceptance.ps1` implementiert den
Installationsanteil von Schritt 1 auf einem frischen eigenen Hyper-V-Slot.
Er verlangt ein explizites Windows-Server-2025-`OS_SEALED`-Artifact, einen
expliziten Medienroot, den relativen ISO-Pfad und einen unabhängig
freigegebenen SHA-256. Der vorhandene Sidecar und der tatsächlich gelesene
ISO-Inhalt müssen beide dazu passen; der offene Lesehandle verhindert während
der Installation auf Windows Änderungen oder Austausch der Datei.

Nur SQL 2025 mit Enterprise-Developer-Ziel und `SQLENGINE,IS` ist vorgesehen.
Der bestehende direkte Slotinstaller bindet diesen Opt-in an Operation und
VM-ID, verweigert vorhandene SQL-Pläne und erhält alle bisherigen Defaults.
Setup verwendet den integrierten SSIS-Dienstaccount und deaktiviert automatische
SQL-/Microsoft-Updates. Windows-Aktivierung verwendet für diesen expliziten, eigenen Akzeptanzlauf den bestehenden
EvaluationOnline-/AllowTemporary-Mechanismus. Der temporäre Egress dient ausschließlich der Windows-
Evaluation-Aktivierung, wird an Run, Scope und VM gebunden und beim Cleanup entfernt; SQL-Setup aktualisiert
oder beschafft keine Software. Setup ist auf
5400 Sekunden und der Setuptransport auf weitere 360 Sekunden begrenzt;
SQL-Neustartbereitschaft einschließlich des äußeren PowerShell-Direct-Transports
auf 600 Sekunden, die getrennten Gastproben auf 90.

Die erste Komponentenprobe verlangt tatsächlichen SQL-Major 17 und Developer-Edition,
vorhandene IS-170-Dienst-/Serverdateien, weiterhin fehlendes SSISDB und dieselben
Postconditions nach VM-Neustart. Der ältere Paketverwaltungsdienst muss nicht
laufen. Danach verwendet dieser interne Installationsketten-Test denselben
Katalog-/Fixture-Gastkörper wie der Prepared-Pfad. Eigener Run-State und
Cleanupplan entstehen vor Provideränderungen. Auch bei verlorener
Erstellungsantwort wird ausschließlich der eindeutig operationseigene Run
bereinigt; VM-ID und dateigenaue VHDX-Reste werden kontrolliert. Primär- und
Cleanupfehler bleiben getrennt. Bei hartem Abbruch des gesamten aufrufenden
Prozesses ist die gespeicherte Operation manuell besitzgebunden zu prüfen;
es gibt keinen automatischen erneuten Installationsversuch. Reale Ausgaben
bleiben ausschließlich unter dem lokalen StateRoot, außerhalb des Checkouts.
Sie dürfen nicht als CI-Artefakte hochgeladen werden.
`local.log` ist derzeit nicht größenbegrenzt; der Einstieg enthält keinen
begrenzten Logcollector. Freier lokaler Speicher ist daher vor einer nativen
Abnahme zu prüfen. Ein Diagnose-Schreibfehler verdrängt weder den ursprünglichen
Installationsfehler noch einen getrennten Cleanupfehler.

Die synthetische Suite `Invoke-SsisOwnedInstallChecks.ps1` prüft Freigabe-,
Medien-, Argument-, Plan- und Teilfehlerverträge. Echte Installation, Neustart
und eigenes Runtime-Cleanup sind bis zur separaten nativen Abnahme
**NOT_EXECUTED** für diese getrennte vollständige Installationskette. Die enge
öffentliche Prepared-/Existing-Run-Abnahme wird nachfolgend separat belegt;
ETL und weitere Provider-/Editionsfreigaben werden daraus nicht abgeleitet.

**Kataloganlage nach Microsofts Verfahren:** Der gebundene SQL-2025-/IS-170-Pfad
verwendet seit dem 2026-10-16 `Catalog.Create()` aus der bereits installierten,
versionsgebundenen `Microsoft.SqlServer.Management.IntegrationServices`-Assembly.
Ihr Vorhandensein im eigenen IS-2025-Gast wurde beobachtet. Der vorherige manuelle
Template-Restore entfällt. Es gibt keinen Download, SSMS- oder SDK-Installationsschritt;
das nur gastlokale Katalogkennwort erfüllt die Komplexitätsrichtlinie. Ein
vollständiges synthetisches ISPAC mit Projektmanifest und OPC-Content-Types
wurde vorab mit Microsofts `Project.OpenProject()` gelesen; beide gestarteten
Pakete lieferten lokal das erwartete Success-/Failure-Ergebnis ohne Datenquelle.
Die [reale Windows-/SSISDB-Abnahme](../Quality/SSISDB_WINDOWS_RUNTIME_ACCEPTANCE_2026-10-16.md)
belegt die enge synthetische Analyze-Quelle mit Erfolg-, Fehler- und ungestartetem
Fall auf SQL/IS `17.0.1000.7` sowie gezieltem Cleanup und Fremdobjektschutz.
Die nachfolgenden ETL-, Datenquellen- und Beschaffungsszenarien bleiben getrennte
offene Scopes. Quellen: [SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17),
[Setupfeature IS und SDK-Grenze](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17),
[SSIS-Installation](https://learn.microsoft.com/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17).

### Beschaffungscheckpoint G: weiterhin offen

Der vollständige Beschaffungsscope unter `SFT-711`/`SFT-712` und
`AIX-001`/`AIX-008` bleibt offen. Dokumentenrecherche und begrenzte statische
Inventur ergeben keinen validierten Paket-, Installations- oder Funktionsvertrag.
Eine Bootstrappervorstufe ersetzt weder Vollmedien noch transitive Abhängigkeiten.

Der dokumentierte Herstellerweg ist eine SSMS-Komponenteninstallation mit
`Microsoft.SSMS.Component.IS`, auch aus einem selektierten Offline-Layout:
[Komponenten](https://learn.microsoft.com/en-us/ssms/install/workload-component-ids),
[Offline-Layout und Installation](https://learn.microsoft.com/en-us/ssms/install/create-offline).
Dies belegt keine eigenständige Beschaffung durch Kopieren einzelner IS-/SMO-DLLs.
Die vorgesehene Windows-/Hyper-V-IS-Installation und ihre native Abnahme bleiben
von der Bereitstellung des Managementclients getrennt.

Für einen eigenen Windows-x64-/WindowsPowerShell-5.1-/.NET-Framework-Host fehlen
noch ein exakter Bindingvertrag und eine isolierte Offline-Ladeprobe. Der
[PowerShell-Quickstart](https://learn.microsoft.com/en-us/sql/integration-services/ssis-quickstart-deploy-powershell?view=sql-server-ver17)
zeigt den API-Nutzungsweg, definiert aber keine vollständige versionsgebundene
SSMS-Assemblyauflösung für diesen Host. Sein Modulpin ist kein pauschaler Beleg
für eine zusätzlich erforderliche Abhängigkeit jedes SSMS-Bestands. Diese offene
Engineering-/Validierungsgrenze ist kein generelles Nutzungsverbot; SSMS-
Hostredirects dürfen nicht ungeprüft übernommen und .NET-Framework-/coreclr-
Bestände nicht vermischt werden.

Davon getrennt bleiben die Rechte zur Redistribution eines selbst
zusammengestellten Standalonepakets, dessen genaue Noticezuordnung und der
exakte Beschaffungs-/Integritätsvertrag ungeklärt. Die
[SSMS-22-Lizenz](https://learn.microsoft.com/en-us/legal/sql/ssms/sql-server-management-studio-22-license-terms)
verweist auf konkrete Distributable-Rechte; die verlinkte
[Distributable-/Utilities-Liste](https://learn.microsoft.com/en-us/legal/sql/ssms/ssms-redistribution-utilities)
bezeichnet beim Quellencheck weiterhin SSMS 21. Die
[Notice-Anleitung](https://learn.microsoft.com/en-us/legal/sql/ssms/ssms-third-party-notices)
ersetzt keine versionsgenaue Lizenzzuordnung. Lokale Nutzung einer vorhandenen
Installation und Weitergabe eines Pakets sind unterschiedliche Fragen.
Widersprüchliche Payloadgrößen sind vor einer exakten Katalogfreigabe zu klären;
ein Hashmatch rechtfertigt keine Größenanpassung und beweist allein keinen
Herstellertrust. Eine Größenabweichung allein beweist keine beschädigte DLL.

Begrenzte Wiederaufnahmeoptionen innerhalb derselben Aufgaben sind ein
herstellergeführter Layout-/Komponentenvertrag oder ein rechtlich geklärter
eigener Hostvertrag mit ausdrücklich begrenzter Supportaussage und separater
Offlineprobe. Erst daraus ergibt sich die noch zu schließende Abhängigkeitsmenge.
Keine weitere serielle Suche, Beschaffung oder Ladeprobe ist aus diesem
Checkpoint freigegeben. Die autonome Produktumsetzung von G endet hier;
unabhängige kanonische Slices können weitergehen. Registriert, herunterladbar,
lokal geprüft, installiert, konfiguriert und funktional bleiben getrennt.
Die vollständige Beschaffung und ihre Offlineclosure bleiben offen. Das hebt
die separat abgenommene SSISDB-Referenz mit vorhandenen installierten
IS-Managementdateien nicht auf; ein späteres Profil mit zusätzlichen
Client-/Buildwerkzeugen muss deren eigene Closure vor Verwendung belegen.
Die vollständigen ETL-Abnahmen bleiben offen; C# bleibt `USER_DEFERRED`.

### Reihenfolge der vollständigen Umsetzung

1. Einen Windows-/Hyper-V-Slot mit SQL Server, SSIS und SSISDB bereitstellen.
2. Eine kleine synthetische SQL-Quelle und ein getrenntes Warehouse erzeugen.
3. Ein katalogisiertes SSIS-Projekt mit Staging-, Dimensions- und Fakt-Package
   nach SSISDB deployen.
4. Environment und Parameter ohne Secretpersistenz binden.
5. Full Load, wiederholten No-op und einen Delta Load ausführen.
6. Zeilenzahlen, Schlüssel, Summen, Rejects und SSISDB-Status prüfen.
7. Einen kontrollierten Zielabbruch auslösen und den Lauf idempotent fortsetzen.
8. Stop, Start, VM-Restart, erneute Ausführung und Cleanup bestätigen.

## Abnahmekriterien

- Provision, Deployment und Ausführung erfolgen unattended und sind resumierbar.
- Wiederholtes Deployment erzeugt weder doppelte Projekte noch unkontrollierte
  SSISDB-Versionen oder Environments.
- Full Load, Delta Load und SCD liefern exakt erwartete synthetische Ergebnisse.
- Fehlerpfade bleiben sichtbar, sanitisiert und nach Behebung fortsetzbar.
- Kein Secret erscheint in Manifest, Plan, Command Line, State, Log oder Receipt.
- Hyper-V-Ressourcen, SSISDB-Objekte, Jobs, Testdaten und lokale Artefakte werden
  ausschließlich nach nachgewiesenem Eigentum entfernt.
- Docker- und Podman-Komponenten gelten nur nach getrennten realen Läufen als
  validiert; ihr Erfolg ersetzt keinen Windows-/SSIS-Nachweis.

## Nicht Teil des ersten Vertical Slice

- produktive ETL-Ausführung oder Übernahme produktiver Packages und Daten;
- allgemeine Azure-SSIS-IR- oder Cloud-Orchestrierung;
- frei installierte Drittanbieterconnectoren;
- SAP-, Oracle-, Teradata- oder Mainframe-Integration ohne eigenes Szenario;
- Behauptung vollständiger Linux-Parität;
- hochverfügbares SSISDB oder SSIS Scale Out; diese Pfade gehören zum
  Cluster-Backlog.

## Bei Umsetzung erneut zu prüfende Herstellerquellen

- [Integration Services installieren](https://learn.microsoft.com/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17);
- [SSIS Catalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17);
- [SSIS unter Linux: Features und Einschränkungen](https://learn.microsoft.com/sql/linux/sql-server-linux-ssis-known-issues?view=sql-server-ver17);
- [SSIS Scale Out](https://learn.microsoft.com/sql/integration-services/scale-out/integration-services-ssis-scale-out?view=sql-server-ver17);
- [SSIS-Features nach Edition](https://learn.microsoft.com/sql/integration-services/integration-services-features-supported-by-the-editions-of-sql-server?view=sql-server-ver17).
