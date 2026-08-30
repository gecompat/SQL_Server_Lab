# End-to-End-BI-Pipeline mit SSIS und SSAS – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-08-30 |
| Primärzweck | vollständige SQL-zentrierte BI- und Data-Warehouse-Testumgebung |

## Ziel

Ein Manifest oder Package soll eine kleine, vollständig automatisierte
BI-Pipeline erzeugen:

```text
OLTP-Quelle -> SSIS -> Staging/Data Warehouse -> SSAS Tabular -> Testclient
```

Das Szenario verbindet die eigenständigen SSIS- und SSAS-Verträge, dupliziert
deren Implementierung aber nicht. Es prüft den fachlichen Datenfluss vom
synthetischen Quellereignis bis zum DAX-Ergebnis einschließlich Deployment,
inkrementeller Aktualisierung, Fehlerbehandlung, Restart, Recovery und Cleanup.

## Anwendungsszenarien

### Mini-Data-Warehouse

- synthetische OLTP-Quelle mit Kunden-, Produkt-, Zeit- und Auftragsdaten;
- SSIS Full Load in Staging, Dimensionen und Faktentabelle;
- Surrogate Keys, SCD und referenzielle Integrität;
- SSAS-Tabular-Modell mit Beziehungen, Measures, Hierarchien und KPIs;
- DAX-Assertions für Umsatz, Menge, Zeitvergleich und Dimensionsfilter.

### Inkrementelle BI-Pipeline

- kontrollierte Inserts, Updates und Deletes in der Quelle;
- Delta-Ermittlung über Watermark, Change Tracking oder CDC-Capability;
- idempotenter Warehouse-Load;
- gezieltes Processing betroffener SSAS-Partitionen;
- Nachweis, dass unveränderte Perioden stabil und Änderungen exakt sichtbar sind.

### Fehler und Wiederanlauf

- Ausfall von Quelle, SSIS Runtime, Warehouse, SSAS oder Netzwerk;
- Abbruch zwischen Staging-, Dimension-, Fakt- und Processing-Phase;
- Wiederanlauf ohne doppelte Fakten oder übersprungene Änderungen;
- sichtbarer Unterschied zwischen ursprünglichem Fehler und Cleanupfehler;
- fachliche End-to-End-Assertion erst nach vollständiger Recovery.

### Upgrade- und Kompatibilitätszertifizierung

- SQL-, SSIS- und SSAS-Versionen 2019, 2022 und 2025 als katalogisierte Matrix;
- identisches Dataset, Package, Modell und Query-Set vor und nach Upgrade;
- Treiber-, Package-, Model-Compatibility- und Client-Library-Prüfung;
- Side-by-side-Vergleich vor späteren In-place-Lanes;
- Query-, ETL- und DAX-Regressionen getrennt berichten.

### Security-End-to-End

- Domain-Servicekonten für SQL, SSIS und SSAS;
- Windows Authentication, SPNs und Kerberos über alle Hops;
- SSISDB-Environments mit lokalen Secret-Referenzen;
- SSAS-Rollen und Row-Level Security;
- positive und negative Benutzergruppen-Assertions;
- TLS- und Zertifikatsrotation ohne Secretpersistenz.

### Performance- und Schulungsszenario

- Batchgröße, SSIS-Parallelität und Warehouse-Indexierung;
- Rowstore gegenüber Columnstore;
- SSAS Import gegenüber DirectQuery;
- Full gegenüber inkrementellem Processing;
- Cold-/Warm-Cache und konkurrierende Clients;
- vergleichbare Messungen mit festem Resource- und Workload-Profil, jedoch ohne
  allgemeine Sizing-Aussage aus einem Einzelhost.

## Topologie- und Providervertrag

- SSIS und SSAS laufen im vollständigen Referenzpfad unter Hyper-V/Windows.
- SQL-Quelle und Warehouse dürfen im ersten kleinen Slice in derselben
  Windows-VM liegen, müssen logisch getrennte Datenbanken und Storage-Rollen
  besitzen.
- Der bevorzugte Ausbau verwendet getrennte SQL-Quell- und Warehouse-Instanzen.
- Docker und Podman eignen sich für SQL-Quellen, SQL-Ziele, Clients, Load
  Generatoren und Fault-Komponenten; beide benötigen getrennte Evidence.
- Gemischte Providerplatzierung verlangt explizite Netzwerk-, DNS-, TLS-,
  Endpoint-, State- und Cleanup-Bindings. Es gibt kein stilles Fallback.

## Workflow und State

Der Workflow führt mindestens aus:

1. Versionen, Editionen, Medien, Ressourcen, Storage, Netzwerk und Secrets
   mutationsfrei auflösen;
2. SQL-Quelle, Warehouse, SSIS/SSISDB und SSAS bereitstellen;
3. synthetisches Quelldataset und erwartete fachliche Ergebnisse binden;
4. Warehouse-Schema, SSIS-Projekt und SSAS-Modell deployen;
5. Full Load, Processing und DAX-Baseline ausführen;
6. definierte Delta-Änderungen einspielen;
7. Delta Load und partielle Modellaktualisierung ausführen;
8. fachliche Vorher-/Nachher-Assertions prüfen;
9. Restart, Resume, Repair und Cleanup eigentumsgebunden ausführen.

Portable State- und Receipt-Daten enthalten nur Identitäten, Versionen,
Digests, Schritte, Status und sanitisierte Ergebnisse. Verbindungsgeheimnisse,
reale Hostwerte, Package-Payloads und fachliche Rohdaten bleiben außerhalb.

## Erster Vertical Slice

- eine Windows-Server-2025-/SQL-Server-2025-Developer-VM unter Hyper-V;
- Database Engine, SSIS, SSISDB und SSAS Tabular;
- eine kleine OLTP-, Staging- und Warehouse-Datenbank;
- ein katalogisiertes SSIS-Projekt für Full und Delta Load;
- ein katalogisiertes Tabular-Modell mit einer Zeitpartition und definierten
  Measures;
- DAX-Testclient mit exakten Assertions;
- ein kontrollierter Abbruch vor dem Fakt-Commit und erfolgreicher Resume;
- vollständiger VM-Restart, erneute Query-Evidence und Cleanup.

## Abnahmekriterien

- Ein einzelner deklarativer Run erzeugt die gesamte Pipeline unattended.
- Full Load, No-op-Rerun und Delta Load liefern erwartete Warehouse- und
  Semantic-Model-Ergebnisse.
- Jede Datenänderung ist über Quellschlüssel, Warehousezeile, Modellpartition
  und DAX-Ergebnis nachvollziehbar, ohne reale Daten zu persistieren.
- Fehler zwischen beliebigen Phasen führen nicht zu stiller Teilbereitschaft.
- Resume erzeugt keine Duplikate und überspringt keine Änderungen.
- Stop, Start und VM-Restart erhalten Pipeline-State und erneute Readiness.
- Cleanup entfernt ausschließlich run-eigene SQL-, SSIS-, SSAS-, Storage-,
  Netzwerk- und Testdatenressourcen.

## Nicht Teil des ersten Vertical Slice

- produktiver BI-Betrieb oder produktive Datenmigration;
- Power BI Report Server, Fabric oder allgemeine Reporting-Orchestrierung;
- SSAS Multidimensional;
- mehrere SSIS-Worker, SQL-/SSIS-/SSAS-Cluster oder Query-Farm;
- Cloud-Data-Warehouse oder Azure-SSIS-IR;
- freie Auswahl unbekannter Packages, Modelle oder Connectoren.

## Verwandte Backlogs

- [SSIS ETL-, Data-Warehouse- und Recovery-Lab](SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md);
- [SSAS Analytics- und Semantic-Model-Lab](SSAS_ANALYTICS_SEMANTIC_MODEL_BACKLOG.md);
- [SQL-/SSIS-/SSAS-Cluster](SQL_SSIS_SSAS_CLUSTER_BACKLOG.md);
- [Neue SQL-Server-Lab-Anwendungsmöglichkeiten](NEW_SQL_LAB_USE_CASES_BACKLOG.md).
