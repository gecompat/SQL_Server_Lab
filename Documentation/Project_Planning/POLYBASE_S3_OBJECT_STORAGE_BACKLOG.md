# PolyBase mit S3-kompatiblem Object Store – Backlog

## Status

`BACKLOG` – der allgemeine Architekturvertrag sieht SQL-bezogene Supporting
Components vor, ein ausführbarer S3-Object-Store- und PolyBase-Lifecycle ist
noch nicht implementiert. Reihenfolge und Priorität richten sich nach dem
kanonischen Entwicklungs- und Ausführungsplan.

## Ausgangslage

SQL Server 2022 und 2025 können Dateien in einem S3-kompatiblen Object Store
über External Data Sources abfragen und je nach Capability auch schreiben.
SQL_Server_Lab besitzt bereits getrennte Docker-, Podman- und Hyper-V-Provider,
aber noch keinen typisierten Vertrag zum Erstellen, Binden, Prüfen,
Wiederaufnehmen und Entfernen eines solchen SQL-Supporting-Systems.

Der direkte PolyBase-Hadoop-Connector endet mit SQL Server 2019 und ist kein
Ziel dieses modernen Pfads. Ein Hadoop- oder anderer Datenverarbeitungsdienst
kann später denselben Object Store verwenden; SQL Server greift in diesem
Szenario jedoch über die S3-API und nicht direkt über HDFS zu.

## Ziel

Ein Manifest oder Package soll zu einer vollständig automatisierten lokalen
SQL-Server-Integrationsumgebung aufgelöst werden können, die mindestens
folgende Komponenten besitzt:

- eine SQL-Server-2022- oder -2025-Instanz;
- einen kleinen S3-kompatiblen Object Store als Supporting Component;
- einen run-gebundenen Bucket, Benutzer beziehungsweise Access Key und eine
  Least-Privilege-Policy;
- synthetische, integritätsgeprüfte CSV- und Parquet-Testdaten;
- SQL-seitige Credentials, External Data Source, File Format und External
  Table;
- Live-Abfragen, optionalen Schreibnachweis sowie gemeinsamen Lifecycle,
  Resume, Repair und Cleanup.

Der Object Store bleibt ausschließlich Hilfssystem eines dokumentierten
SQL-Server-Szenarios. Das Vorhaben erzeugt keine allgemeine Object-Storage-
Plattform.

## Provider- und Topologievertrag

- Docker ist der erste Referenzpfad: SQL Server und Object Store laufen in
  einem run-eigenen, isolierten Netzwerk mit stabilen DNS-Aliasen.
- Podman verwendet denselben logischen Vertrag, benötigt jedoch einen eigenen
  nativen Runtime-Nachweis. Eine erfolgreiche Docker-Abnahme ist kein
  Podman-Nachweis.
- Hyper-V stellt den Object Store bevorzugt in einer kleinen Linux-VM bereit,
  direkt als Dienst oder über einen dort gebundenen Container-Lifecycle. Dieser
  Pfad hängt vom allgemeinen Hyper-V-Linux-Vertical-Slice ab und wird nicht
  durch eine implizite verschachtelte Containerplattform vorgetäuscht.
- Ein Single-Node-/Single-Volume-Store ist der verpflichtende kleine
  Entwicklungs- und Testfall. Verteilung, Replikation und mehrere Storage-
  Nodes sind optionale spätere Capabilities und keine Voraussetzung für den
  ersten vertikalen Slice.
- Gemischte Platzierungen, etwa SQL unter Hyper-V und der Store unter Docker
  oder Podman, sind nur mit explizitem Teilhost-, Netzwerk-, DNS-, TLS- und
  Cleanup-Vertrag zulässig. Es gibt keine automatische Ersatzplatzierung.

## Produkt-, Artifact- und Lizenzvertrag

Der logische Component Type darf nicht auf einen frei eingegebenen Image-Namen
oder ein bestimmtes Produkt fest verdrahtet werden. Ein ausführbarer Resolver
wählt ausschließlich katalogisierte Varianten mit:

- exaktem Image-Digest beziehungsweise überprüfter Installationsquelle;
- dokumentierter Version, Plattform und S3-Capability;
- dokumentierter Lizenz und zulässiger lokaler Testverwendung;
- definiertem Upgrade-, Cache- und Artifact-Ownership;
- nachgewiesener Kompatibilität mit den tatsächlich verwendeten SQL-Server-
  Versionen und Operationen.

MinIO ist ein geeigneter Kandidat für den ersten kleinen Container-Vertical-
Slice, sofern Lizenz-, Bezugs- und Integritätsprüfung erfüllt sind. Andere
Implementierungen wie Garage, SeaweedFS oder Ceph RGW benötigen denselben
Vertrag und eigene Evidence; die Bezeichnung „S3-kompatibel“ allein ist kein
Kompatibilitätsnachweis.

## Netzwerk-, TLS- und Secret-Vertrag

- SQL Server greift ausschließlich über HTTPS auf den S3-Endpunkt zu. Ein
  entwicklungsbezogenes HTTP-Fallback darf nicht als erfolgreiche Abnahme
  gelten.
- Die ausstellende CA beziehungsweise das Endpunktzertifikat wird
  reproduzierbar und scopegebunden in den Trust Store des SQL-Hosts oder
  SQL-Containers eingebracht und beim Cleanup nur bei nachgewiesenem
  Run-Eigentum entfernt.
- DNS-Name, API-Port und URL-Stil sind stabil. Path Style ist der portable
  Referenzfall; Virtual Hosted Style ist eine getrennte Capability.
- Access Key, Secret Key, private Schlüssel und Zertifikats-Secrets werden nur
  über den bestehenden lokalen Secret-Vertrag injiziert. Manifest, Plan,
  Run-State, Logs und Receipts bleiben geheimnisfrei.
- Der Resolver erzwingt die von SQL Server benötigte Credential-Syntax,
  insbesondere zulässige Zeichen und Längen, bevor eine Mutation beginnt.
- Die initiale Policy erlaubt nur die für den gebundenen Bucket erforderlichen
  Operationen wie Location-, List-, Read- und bei einem Schreibszenario
  Write-Zugriff. Administrative Root-Credentials werden nicht in SQL Server
  gebunden.
- Ein isolierter Run erhält keinen stillen externen Internetzugriff. Downloads
  und Artifact-Builds folgen dem vorhandenen Trust-, Cache- und Egress-Vertrag.

## Storage-, State- und Cleanup-Eigentum

- Bucket, Benutzer, Policy, Netzwerk, Container beziehungsweise VM und Volume
  erhalten stabile run- und scopegebundene Identitäten.
- Ein run-eigenes persistentes Volume überlebt Stop, Start, Restart und Repair,
  wird aber bei ausdrücklich angefordertem Run-Cleanup vollständig entfernt.
- Ein als extern oder gemeinsam klassifizierter Store beziehungsweise Bucket
  wird niemals vom normalen Run-Cleanup gelöscht. In diesem Fall werden nur
  nachweislich run-eigene Objekte, SQL-Metadaten und Credentials kompensiert.
- Testdaten besitzen synthetische Herkunft, Content Hash, erwartete Zeilen- und
  Dateiformat-Evidence. Reale Kunden-, Backup- oder Diagnosedaten sind
  ausgeschlossen.
- Der portable State speichert nur Identitäten, Digests, Capability-Resultate
  und sanitisierte Receipts, keine Hostpfade oder Secrets.

## Lifecycle und Readiness

Der gemeinsame Workflow führt in idempotenter Reihenfolge mindestens aus:

1. Capabilities, Ressourcen, Ports, Artifact-Verfügbarkeit, Lizenz und Egress
   mutationsfrei prüfen;
2. Netzwerk, persistentes Storage und Object Store scopegebunden erstellen;
3. Prozess-, HTTPS-, Zertifikats- und S3-API-Readiness live bestätigen;
4. Bucket, Least-Privilege-Identität und Policy erstellen oder reconciliieren;
5. synthetische Testobjekte hochladen und per Hash beziehungsweise Inhalt
   verifizieren;
6. SQL-Capability auflösen, erforderliche Features aktivieren und einen
   kontrollierten Restart nur bei tatsächlichem Bedarf durchführen;
7. Database Master Key, Database Scoped Credential, External Data Source,
   File Format und External Table idempotent binden;
8. reale Lese- und konfigurierte Schreib-Postconditions prüfen und erst danach
   `READY` veröffentlichen.

Resume und Repair beginnen mit Live-Probes. Bereits erfüllte Schritte sind
No-ops; Drift wird geplant reconciliiert oder fail-closed gemeldet. Gespeicherte
Receipts ersetzen keine Live-Readiness.

SQL Server 2025 kann bestimmte Dateioperationen nativ ohne laufenden PolyBase-
Query-Service ausführen. Der Resolver entscheidet deshalb anhand von SQL-
Version, Dateiformat und gewünschter Operation über die tatsächlich benötigte
Feature- und Service-Capability, statt PolyBase-Dienste pauschal zu erzwingen.

## Erwarteter Umsetzungsumfang

1. Einen typisierten S3-Object-Store-Component-, Binding- und Capability-
   Vertrag in Package, Manifestauflösung und Runtime-Plan integrieren.
2. Katalog, Recipe, Digest-/Lizenzprüfung und Derived-Artifact-Receipts für den
   ersten freigegebenen Object Store ergänzen.
3. Gemeinsame Handler für Provision, Observe, Start, Stop, Restart, Resume,
   Repair und Cleanup bereitstellen; Docker und Podman nur über ihre
   Provideradapter mutieren.
4. TLS-/CA-, Bucket-, Identity-, Policy-, Dataset- und SQL-External-Object-
   Bindings implementieren, ohne Secrets oder Hostdetails zu persistieren.
5. Ressourcen- und Portbewertung sowie die providerneutrale Batch-/Queue-
   Planung um die Supporting Component erweitern.
6. Hyper-V-Linux erst nach dessen eigenem validierten Vertical-Slice anbinden.
7. Benutzerreferenz, Known Limitations, Architektur-, Netzwerk-, Storage- und
   Secret-Verträge sowie Beispiele gemeinsam aktualisieren.

## Abnahmekriterien

- Ein deklarierter SQL-2022-/2025-Run erstellt unattended einen kleinen Store,
  Bucket, Policy, synthetische CSV-/Parquet-Daten und die erforderlichen SQL-
  External Objects.
- SQL Server liest die erwarteten Daten live über HTTPS und S3-API; ein
  aktiviertes Schreibszenario schreibt ein Objekt, dessen Inhalt anschließend
  unabhängig über die S3-API bestätigt wird.
- Falsches Zertifikat, nicht vertrauenswürdige CA, falsches Credential,
  unzureichende Policy, nicht unterstützter URL-Stil und inkompatible
  S3-Operation führen jeweils fail-closed zu einem sanitisierten Befund.
- Stop, Start, vollständiger Restart und Resume erhalten run-eigene Daten und
  liefern danach erneut erfolgreiche SQL- und S3-Live-Probes.
- Wiederholtes Provisionieren und Repair erzeugen keine zusätzlichen Buckets,
  Identitäten, Policies, External Objects oder Credential-Leaks.
- Cleanup entfernt ausschließlich run-eigene SQL-Objekte, Trust-Artefakte,
  Bucket-Inhalte, Identitäten, Netzwerkressourcen und Volumes. Externe oder
  fremde Ressourcen bleiben unverändert.
- Docker und Podman bestehen getrennte reale End-to-End-Läufe einschließlich
  negativer TLS-/Credential-Probe, Persistenz, Resume und Cleanup.
- Der Hyper-V-Pfad gilt erst nach einem realen Linux-VM-Nachweis mit
  persistenter virtueller Disk, HTTPS-Vertrauen, SQL-Zugriff und Cleanup als
  validiert.
- Image-Digest, Lizenz, Testdaten-Hashes und sanitisierte Runtime-Evidence sind
  nachvollziehbar; ein Planungsdokument allein wird nie als Runtime-Nachweis
  ausgewiesen.

## Nicht Teil des ersten Vertical Slice

- allgemeiner S3-Hosting-Service ohne SQL-Server-Bezug;
- produktiver Multi-Tenant-Betrieb;
- Hochverfügbarkeit, Erasure Coding, Geo-Replikation oder Object Lock;
- automatische Migration fremder Buckets oder Bestandsdaten;
- direkte HDFS-/Hadoop-Konnektivität unter der Bezeichnung dieses S3-Pfads;
- Cloud-Provisionierung oder automatisch erzeugte öffentliche Endpunkte.
