# SQL-, SSIS- und SSAS-Cluster – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-08-30 |
| Primärzweck | funktionale HA-, Failover- und Scale-out-Szenarien für SQL-zentrierte Labs |

## Ziel und Begriffsgrenze

Das Lab soll reproduzierbare Mehrknotenumgebungen für SQL Server, Integration
Services und Analysis Services bereitstellen. Drei Ziele bleiben getrennt:

1. **High Availability und Failover** halten einen Dienst nach einem
   Komponentenfehler erreichbar;
2. **Scale Out** verteilt Ausführungen oder Abfragen auf mehrere Worker;
3. **Disaster Recovery** erhält Daten und stellt einen definierten Zustand an
   einem getrennten Ziel wieder her.

Ein Cluster-Symbol oder erfolgreicher Setup-Lauf ist kein Nachweis für diese
Eigenschaften. Jedes Szenario benötigt einen realen Fault, beobachteten
Rollenwechsel, fachliche Postconditions, Recovery und Cleanup.

## Workstream 1 – SQL Server Cluster und HADR

### Availability Group

- zwei SQL-Replikate auf getrennten Windows-VMs;
- WSFC, Quorum, optionaler File-Share-Witness, DNS und Listener;
- synchrone und spätere asynchrone Commit-Lane;
- geplanter manueller und kontrollierter automatischer Failover;
- Readable Secondary und Read-only Routing;
- Backuppräferenz und Job-/Login-/Serverobjekt-Drift;
- Netzwerkunterbrechung, Replica-Suspend, Aufholen und Rejoin;
- Rolling Patch und Side-by-side-Upgrade als spätere Lanes.

### Failover Cluster Instance

- SQL-Instanz als WSFC-Rolle mit virtuellem Namen und IP;
- Shared Storage über eine ausdrücklich katalogisierte Lab-Variante;
- Dienst-, Knoten-, Netzwerk- und Storage-Failover;
- SQL Agent, Systemdatenbanken und Instanzkonfiguration nach Rollenwechsel;
- Recovery, Quorum und Fremdobjektschutz;
- FCI und AG als getrennte Lanes, später optional kombiniert.

AG schützt Datenbanken mit getrenntem Storage. FCI schützt eine Instanz und
benötigt Shared Storage. Beide werden weder in Manifest noch Evidence als
gleichwertige Implementierung derselben Capability dargestellt.

## Workstream 2 – SSIS High Availability und Scale Out

### SSISDB High Availability

- Integration Services auf allen vorgesehenen Windows-Knoten;
- SSISDB in einer SQL Availability Group;
- explizit aktivierte SSIS-Unterstützung für Always On auf allen Replikaten;
- gesicherter und wiederherstellbarer Database Master Key;
- SSISDB-Folder, Projekte, Environments, Parameter und Execution History;
- SQL-Agent-Jobs, lokale Runtimekomponenten und Service Accounts als getrennt
  reconciliierte Ressourcen;
- Failover vor, während und nach einer Package-Ausführung;
- idempotenter fachlicher Resume statt unbelegter Exactly-once-Behauptung.

### SSIS Scale Out

- Scale Out Master und mindestens zwei katalogisierte Worker;
- parallele Package-Ausführung und begrenzte Queue;
- Worker-Capability-, Zertifikats- und Versionsbindung;
- Worker-Ausfall und kontrollierte Wiederzuweisung;
- Drift, Worker-Rejoin und Rolling Maintenance;
- Kombination mit hochverfügbarer SSISDB erst nach getrennten Einzelbelegen.

SSISDB-HA und SSIS Scale Out sind unterschiedliche Capabilities. Ein
funktionsfähiger Workerpool beweist keinen SSISDB-Failover; eine SSISDB-AG
beweist keine parallele oder ausfallsichere Package-Ausführung.

## Workstream 3 – SSAS High Availability und Query Scale-out

### SSAS Failover Cluster

- SQL Server 2025 Analysis Services unter WSFC;
- Tabular als erste Lane, Multidimensional später getrennt;
- identisches Active-Directory-Domain-Servicekonto auf allen Knoten zur
  Entschlüsselung des Server Encryption Key;
- virtueller Name, Firewall, TLS und Client-Reconnect;
- Failover bei Idle, Query und Processing;
- Modell-, Rollen-, Partitions- und Datenquellenkonsistenz;
- Backup/Restore, Key-/Service-Account-Rotation und Recovery.

### SSAS Query Scale-out

- Processing-Knoten und mehrere read-only Query-Knoten;
- reproduzierbare Modellsynchronisation beziehungsweise Deploymentwelle;
- Load Balancer als Supporting Component;
- Query-Verteilung, Knotenausfall und Client-Retry;
- Cold-/Warm-Cache und versionsgleiche Modelldatenbanken;
- Rolling Deployment ohne Mischung inkompatibler Modellversionen.

SSAS läuft nicht in einer SQL Availability Group. Es darf jedoch relationale
Daten aus einer SQL-AG beziehen. WSFC liefert SSAS-HA ohne Query-Skalierung;
mehrere read-only Instanzen hinter einem Load Balancer liefern Query Scale-out
und können zusätzlich Ausfälle einzelner Query-Knoten abfangen.

## Workstream 4 – Clustered End-to-End BI

Die spätere vollständige Topologie verbindet:

```text
Domain Controller/DNS/Witness
  -> SQL-Quell-AG
  -> SSIS Runtime mit SSISDB-AG oder Scale-Out-Workern
  -> Data-Warehouse-AG
  -> SSAS-WSFC oder SSAS-Query-Farm
  -> DAX-/MDX-Testclient
```

Mögliche End-to-End-Faults:

- SQL-Primary-Failover während eines Delta Loads;
- SSISDB-Failover zwischen Package-Erstellung und Ausführung;
- Worker-Ausfall nach Staging und vor Fakt-Commit;
- Warehouse-Failover vor SSAS-Processing;
- SSAS-Knotenverlust während einer Querylast;
- DNS-, Listener-, Zertifikats- oder Service-Account-Fehler;
- kombinierter Restart mit nachfolgender Daten-, Package-, Modell- und
  Query-Konsistenzprüfung.

## Provider-, Host- und Netzwerkvertrag

- Hyper-V/Windows ist der Referenzprovider für WSFC, Domain Controller, DNS,
  SQL-FCI, vollständiges SSIS und SSAS.
- Docker und Podman dürfen SQL-Quellen, Clients, Load Generatoren,
  Observability-, Fault- und ausgewählte Datenkomponenten bereitstellen.
- Clusterknoten erhalten getrennte VM-, Netzwerk-, Storage- und State-
  Identitäten. Keine Ressource wird allein über einen Anzeigenamen bereinigt.
- Domain-, Service-, Cluster- und virtuelle Computerkonten werden
  scopegebunden erstellt und eigentumsgebunden entfernt.
- DNS, Zeit, SPNs, Ports, TLS, Quorum und Witness werden vor SQL-/SSIS-/SSAS-
  Mutation live geprüft.
- Eine External NIC, die Teil der dauerhaften Client-, Domain-, Listener-,
  Aktivierungs- oder Updatekonnektivität ist, wird nach Aktivierung nicht
  automatisch entfernt. Egress und Exposition bleiben explizite Policies.
- Sämtliche VHDX, VM-Konfigurationen, Smart Paging, Checkpoints und Cluster-
  Artefakte verwenden registrierte `Lab_Data`-Roots.

## Aussagegrenze eines Einzelhosts

Mehrere Cluster-VMs auf einem einzelnen Hyper-V-Host erlauben funktionale
Tests von Gastknoten-, Dienst-, Netzwerk- und Rollenfailover. Sie beweisen
nicht die Verfügbarkeit beim Ausfall des physischen Hosts, dessen Storage,
Netzwerk oder Hypervisors.

Ein echter Infrastruktur-HA-Nachweis benötigt mehrere physische Hyper-V-Hosts
und baut auf dem Remote-Hyper-V-Backlog sowie einem eigenen Host-, Netzwerk-,
Storage- und Cleanup-Vertrag auf. Beide Evidence-Klassen werden getrennt als
`FUNCTIONAL_GUEST_CLUSTER` und `MULTI_HOST_INFRASTRUCTURE_HA` berichtet.

## Empfohlene Lieferreihenfolge

1. Zwei-Knoten-SQL-AG mit DC/DNS, Listener und File-Share-Witness;
2. FCI als getrennte Shared-Storage-Lane;
3. SSISDB in der validierten SQL-AG;
4. SSIS Scale Out mit zwei Workern;
5. SSAS-2025-Tabular-WSFC;
6. SSAS Query Scale-out mit zwei Query-Knoten;
7. Clustered End-to-End BI;
8. echter Multi-Host-Hyper-V-Nachweis.

## Gemeinsame Fault- und Abnahmematrix

- sauberer Rollenwechsel und ungeplanter Prozess-/VM-Abbruch;
- gerichtete Netzwerkpartition, Latenz und Paketverlust;
- Quorum- beziehungsweise Witness-Verlust;
- DNS-, Listener-, SPN-, TLS- und Credential-Fehler;
- Storage-Latenz und begrenztes Disk Full nur auf explizitem Fault Target;
- Restart und Recovery nach Hostneustart;
- wiederholtes Provision, Resume, Repair und Cleanup;
- keine Split-Brain-, Doppelverarbeitungs- oder Doppel-Primary-Behauptung ohne
  live bestätigte Rollen- und Datenpostconditions;
- RPO und RTO werden als Messwerte des konkreten Laufs, nicht als allgemeine
  Produkteigenschaft berichtet;
- Cleanup entfernt ausschließlich run-eigene Clusterrollen, Konten, DNS-
  Einträge, Zertifikate, Listener, VMs, Disks und Supporting Components.

## Nicht Teil des ersten Vertical Slice

- produktive Hochverfügbarkeit oder ein SLA-Versprechen;
- Stretched Cluster, mehrere Rechenzentren oder Cloud Witness;
- Storage Spaces Direct, SAN- oder produktive SMB-Infrastruktur;
- Kubernetes als allgemeiner Clusterprovider;
- Multi-Host-HA auf Basis nur eines physischen Hosts;
- gleichzeitige Implementierung aller vier Workstreams;
- automatische Lizenzierung produktiver SQL-Editionen.

## Verwandte Backlogs

- [End-to-End-BI-Pipeline](END_TO_END_BI_PIPELINE_BACKLOG.md);
- [SSIS ETL-, Data-Warehouse- und Recovery-Lab](SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md);
- [SSAS Analytics- und Semantic-Model-Lab](SSAS_ANALYTICS_SEMANTIC_MODEL_BACKLOG.md);
- [Remote-Hyper-V-Host](HYPERV_REMOTE_HOST_BACKLOG.md);
- [Windows-Slot-Aktivierung](WINDOWS_SLOT_ACTIVATION_BACKLOG.md);
- [Hyper-V-`Lab_Data`-Bugfix](HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md).

## Bei Umsetzung erneut zu prüfende Herstellerquellen

- [WSFC mit SQL Server](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/windows-server-failover-clustering-wsfc-with-sql-server?view=sql-server-ver17);
- [FCI und Availability Groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/failover-clustering-and-always-on-availability-groups-sql-server?view=sql-server-ver17);
- [SSISDB mit Always On](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17);
- [SSIS Scale Out](https://learn.microsoft.com/sql/integration-services/scale-out/integration-services-ssis-scale-out?view=sql-server-ver17);
- [SSAS High Availability und Scalability](https://learn.microsoft.com/analysis-services/instances/high-availability-and-scalability-in-analysis-services?view=sql-analysis-services-2025);
- [SSAS-2025-Failover-Cluster und Encryption](https://learn.microsoft.com/analysis-services/instances/encryption-upgrade?view=sql-analysis-services-2025).
