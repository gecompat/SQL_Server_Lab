# SSIS ETL-, Data-Warehouse- und Recovery-Lab – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-08-30 |
| Primärzweck | reproduzierbare SQL-Server-Integration-Services-Szenarien |

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
beobachtet eine bereits laufende eigene Hyper-V-/Windows-/SQL-2025-Instanz.
Der interne Einstieg ist kein neuer öffentlicher Cmdletvertrag. Er verwendet
den bestehenden StateRoot, bindet Run, Instanz und tatsächliche VM-ID und
verweigert WinRM-Fallback. Der Gasttransport ist auf 10 bis 120 Sekunden,
die SQL-Abfrage auf höchstens 30 Sekunden begrenzt. Secrets bleiben flüchtig;
Ergebnisse und Diagnosen dürfen ausschließlich lokal verwendet werden.

Getrennte Beobachtungen sind tatsächlicher SQL-Major und Edition, zwei
SSIS-Komponentendateien mit Dateimajor 17 am dokumentierten Standardpfad sowie
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
Die native Voraussetzungenprüfung und alle folgenden ETL-Abnahmen sind
weiterhin **NOT_EXECUTED**. Der Gesamtbacklog bleibt offen.

Herstellergrundlagen: [Dateipfade und gemeinsame SSIS-Komponenten](https://learn.microsoft.com/sql/sql-server/install/file-locations-for-default-and-named-instances-of-sql-server?view=sql-server-ver17),
[SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17)
und [Sichtrechte für sys.databases](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17).

### Vollständige noch offene Folge

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
