# SSAS Analytics- und Semantic-Model-Lab – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-08-30 |
| Primärzweck | reproduzierbare SQL Server Analysis Services-Szenarien |

## Ziel

Das Lab soll Analysis Services unter Windows automatisiert installieren,
konfigurieren und mit einem kleinen, versionierten Semantic Model betreiben.
Modell-Deployment, Processing, DAX- beziehungsweise MDX-Abfragen, Security,
Performance, Upgrade, Backup, Recovery und Cleanup werden durch live geprüfte
Postconditions belegt.

SSAS Tabular ist der erste Referenzpfad. Multidimensional ist eine getrennte
spätere Lane, weil eine Analysis-Services-Instanz nur in genau einem Servermodus
läuft und beide Modi eigene Modelle, Tools, Clientverträge und Evidence benötigen.

## Anwendungsszenarien

### Tabular Semantic Model

- Tabellen, Beziehungen, Measures, KPIs, Hierarchien und Perspektiven;
- DAX-Berechnungskontext, Time Intelligence und Calculation Groups;
- Modellmetadaten und erwartete DAX-Ergebnisse;
- synthetisches Star Schema als relational gebundene Datenquelle;
- Excel-, PowerShell- oder katalogisierter Testclient über XMLA.

### Import und DirectQuery

- VertiPaq-Import als verpflichtende Baseline;
- DirectQuery als getrennte Capability gegen SQL Server;
- funktionaler Ergebnisvergleich beider Modi;
- Aktualität, SQL-Last, Cache, Speicherbedarf und Antwortzeit;
- Process Recalc bei DirectQuery-Modellen mit berechneten Objekten;
- keine absolute Performancebehauptung aus einem einzelnen Hostlauf.

### Processing und Partitionierung

- Full-, Data-, Recalc- und partitioniertes Processing;
- inkrementelle Aktualisierung einzelner Perioden;
- Parallel Processing und Resource Assessment;
- Processing-Abbruch und kontrollierte Wiederaufnahme;
- Datenänderung im Warehouse mit anschließender gezielter Modellaktualisierung;
- Nachweis, dass alte und neue Partitionen konsistent sichtbar sind.

### DAX, MDX und Kompatibilität

- DAX-Funktions-, Measure- und Query-Regressionen;
- Compatibility-Level- und Client-Library-Matrix;
- SQL Server 2019, 2022 und 2025 als getrennte Zielstände;
- Providerwechsel auf aktuelle SQL-Client-Bibliotheken;
- Multidimensional-Lane mit Cube, Dimension, Measure Group und MDX;
- keine automatische Umdeutung eines Tabular- in ein Multidimensional-Modell.

### Security und Identity

- Windows-/Domain-Servicekonto für SSAS;
- Administrator-, Process-, Read- und Read/Process-Rollen;
- Row-Level Security über DAX-Filter;
- Gruppenmitgliedschaft, Negativtests und Rollenwechsel;
- Kerberos-, SPN- und Double-Hop-Szenarien mit relationaler SQL-Quelle;
- TLS- und Firewallbindung für Clientzugriff;
- Secrets, Konten und Zertifikate nur über lokale typisierte Bindings.

### Deployment, Betrieb und Recovery

- Deployment über TMSL, XMLA oder TOM mit katalogisiertem Modellartefakt;
- idempotentes Create, Update, Process und Delete;
- Modell- und Datenbankbackup sowie Restore;
- kontrollierter Rollback auf eine vorherige Modellversion;
- Service-, VM- und SQL-Source-Restart;
- Drift-Erkennung für Modell, Rollen, Datenquelle und Compatibility Level;
- sanitisierte XEvent-, DMV- und Execution-Metrics-Evidence.

### Performance und Capacity

- VertiPaq-Kompression und Modellgröße;
- Formula- gegenüber Storage-Engine-Anteil;
- Cold- und Warm-Cache-Läufe;
- Parallelität konkurrierender DAX- beziehungsweise MDX-Clients;
- Import gegenüber DirectQuery;
- Partitionsgröße und Processing-Strategie;
- begrenzte CPU-/RAM-Profile mit klarer Aussagegrenze.

## Provider- und Topologievertrag

- Hyper-V/Windows ist der Referenzprovider für die SSAS-Runtime.
- Docker und Podman dürfen relationale SQL-Quellen, Warehouses,
  Testclients, Load Generatoren und Observability-Komponenten bereitstellen.
- Ein SSAS-Container- oder Linux-Pfad wird nicht behauptet. Jede spätere
  Erweiterung benötigt ausdrückliche Herstellerunterstützung und native Evidence.
- Tabular und Multidimensional verwenden getrennte Windows-Instanzen oder
  getrennte immutable Images.
- Ein Remote-Client erhält nur typisierte Endpoint-, Identity- und
  Certificate-Bindings; freie lokale Hostwerte bleiben außerhalb des Manifests.

## Artifact-, Editions- und Lizenzvertrag

- SQL-/SSAS-Medien, SSDT-/Analysis-Services-Projekterweiterung, Client Libraries
  und Modelldateien werden version-, digest-, quellen- und lizenzgebunden.
- Developer Editions bleiben auf Entwicklung und Test beschränkt.
- Standard-Developer- und Enterprise-Developer-Profile prüfen jeweils nur die
  Capabilities ihrer Ziel-Edition und werden nicht als austauschbar behandelt.
- Modellartefakte enthalten ausschließlich synthetische Datenquellen,
  generische Konten und lokale Secret-Referenzen.
- Drittanbieter-Tools wie alternative Modelleditoren benötigen vor Aufnahme ein
  eigenes Lizenz-, Security-, Maintenance- und Exit-Review.

## Erster Vertical Slice

1. Einen Windows-/Hyper-V-Slot mit SQL Server 2025 Analysis Services im Modus
   `TABULAR` bereitstellen.
2. Ein kleines Star Schema aus einer katalogisierten SQL-Testdatenbank binden.
3. Ein versioniertes Tabular-Modell unattended deployen.
4. Full Processing ausführen und Tabellen-, Partition- und Rollenstatus prüfen.
5. Definierte DAX-Abfragen mit exakten fachlichen Ergebnissen ausführen.
6. Eine Row-Level-Security-Rolle positiv und negativ verifizieren.
7. Eine Quelldatenänderung einspielen und gezielt erneut verarbeiten.
8. Stop, Start, VM-Restart, Backup/Restore und Cleanup bestätigen.

## Abnahmekriterien

- Installation, Konfiguration, Deployment und Processing sind resumierbar und
  erzeugen keine unkontrollierten Doppelobjekte.
- DAX-Ergebnisse, Modellmetadaten, Rollen und Processing-Status entsprechen den
  versionierten Assertions.
- Import und eine spätere DirectQuery-Lane werden getrennt ausgewiesen.
- Ein Modell-, Compatibility- oder Providerwechsel erzeugt einen expliziten
  Deployment- und Processing-Plan.
- Service- und VM-Restart erhalten ein konsistentes, erneut abfragbares Modell.
- Backup und Restore liefern dieselben fachlichen DAX-Postconditions.
- Cleanup entfernt ausschließlich run-eigene SSAS-Datenbanken, Bindings,
  Rollen, Artefakte, VMs und Testdaten.

## Nicht Teil des ersten Vertical Slice

- produktive Semantic Models oder reale Unternehmensdaten;
- allgemeine Power-BI-, Fabric- oder Azure-Analysis-Services-Orchestrierung;
- Multidimensional, Data Mining oder PowerPivot for SharePoint;
- WSFC-Failover und Query Scale-out; diese Pfade gehören zum Cluster-Backlog;
- ungeprüfte Drittanbieter-Modelleditoren;
- absolute Capacity- oder Sizing-Aussagen aus dem lokalen Einzelhost.

## Bei Umsetzung erneut zu prüfende Herstellerquellen

- [Analysis Services installieren](https://learn.microsoft.com/analysis-services/instances/install-windows/install-analysis-services?view=sql-analysis-services-2025);
- [Tabular Modeling](https://learn.microsoft.com/analysis-services/tabular-models/tabular-models-ssas?view=sql-analysis-services-2025);
- [DirectQuery](https://learn.microsoft.com/analysis-services/tabular-models/directquery-mode-ssas-tabular?view=sql-analysis-services-2025);
- [Tabular-Rollen und Row-Level Security](https://learn.microsoft.com/analysis-services/tabular-models/roles-ssas-tabular?view=sql-analysis-services-2025);
- [Neuerungen in SQL Server Analysis Services](https://learn.microsoft.com/analysis-services/what-s-new-in-sql-server-analysis-services?view=sql-analysis-services-2025).
