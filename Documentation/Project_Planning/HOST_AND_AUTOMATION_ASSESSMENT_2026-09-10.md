# Bewertung von Hostverwaltung, Mehrbenutzerbetrieb, API und Cluster

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung; keine neue Remote- oder Clusterausführung) |
| Stand | 2026-09-10 |
| Quellstand | `b6d693f` |
| Auftrag | Vier Bewertungszeilen des [Arbeitsplans](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Entscheidung und Scope

Der lokale Einzeloperator und die öffentliche PowerShell-API bleiben Standard.
Für den aktuellen Auftrag ist kein konkreter zweiter Operator, entfernter
Testhost oder Infrastruktur-HA-Zielstand gebunden. Deshalb werden hier weder
ein Dienst geöffnet noch Remoting, Domänen, Rollen oder Cluster eingerichtet.
Die vier Erweiterungen erhalten nachvollziehbare Eintrittskriterien und einen
begrenzten nächsten Schritt. Ihre Bewertung autorisiert keine fremden Hosts
oder produktive Infrastruktur.

Der [Hyper-V-Provider](../../Providers/HyperV/HyperVProvider.ps1) besitzt lokale
Hostoperationen und getrennte Gastkommunikation. Gast-WinRM oder Legacy-WMI
belegt keine Remote-Host-Steuerung. Der
[State-Vertrag](../../Private/StateMachine.ps1) und die bestehenden
Scope-/Ownership-Grenzen ersetzen keine Autorisierung zwischen mehreren
Benutzern. In den untersuchten Produkt-, Tool- und Schemapfaden wurde kein
eigenständiger Remote-Host-, Cluster- oder IaC-Executor gefunden. Maßgeblich
bleiben der [Plattformbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md),
der [Remote-Backlog](HYPERV_REMOTE_HOST_BACKLOG.md) und die öffentliche
[Befehlsreferenz](../../Public/README.md).

Der Aufwand ist relativ: **M** bezeichnet einen begrenzten lokalen Vertrag,
**L** mehrere gekoppelte Identitäts-, Infrastruktur- und Recovery-Verträge.
Konkrete Laufzeiten benötigen einen gebundenen Zielhost und Ressourcenplan.

## Remote Hyper-V

Der Nutzen ist die Ausführung eines SQL-Labs auf einem ausdrücklich zugeordneten
Windows-Testhost, wenn der lokale Client keine geeignete Hyper-V-Runtime besitzt.
Die Entscheidung lautet: zuerst read-only Hostregistrierung und Inventur,
Mutation erst nach deren Abnahme und einer eigenen Autorisierungsentscheidung.
Der erste gesamte mutierende Slice umfasst später genau einen SQL-Referenzrun
auf genau einem registrierten Host; automatische Ersatzplatzierung entfällt.

| Grenze | Risiko und nächster abnehmbarer Schritt |
|---|---|
| Hostbindung | Stabile Hostidentität und aktueller Endpoint bleiben getrennt. Zertifikats-/Identitätswechsel muss vor State- oder Providerzugriff blockieren; ein gleicher Anzeigename genügt nicht. Read-only Negativtests für falschen Host, fehlendes Vertrauen und nicht erreichbaren Endpoint zuerst ausführen. |
| State und Berechtigung | Hostlokale Run-/Scope-/Storage-Grenzen verwenden; Controller speichert nur gebundene Referenzen. Rechte auf dem ausführenden Host prüfen. Ein Token oder ein erfolgreiches Netzwerkgespräch erteilt keine Löschautorität. Aufwand L. |
| Unterbrochene Verbindung | Operations-ID, erwartete Revision und hostseitiges Journal vor Mutation; nach verlorener Antwort tatsächlichen Hostzustand ermitteln. Unbekannter Ausgang bleibt Recoverybedarf, ohne Neuanlage auf einem anderen Host. Abbruch nach VM-Erstellung und vor Antwort gezielt prüfen. |
| Medien und Secrets | Lokale Pfade nicht als entfernte Pfade interpretieren. Transfer benötigt eigenen Digest-/Lizenz-/Ownership-Vertrag; Credentials lokal neu binden. Keine automatische CredSSP-, TrustedHosts- oder Firewalländerung. |

## Mehrbenutzerbetrieb

Der Nutzen wäre ein gemeinsamer, nachvollziehbarer SQL-Labbestand. Mangels
gebundener gemeinsamer Nutzung wird zunächst nur eine getrennt autorisierte
read-only Sicht empfohlen. Ein zentraler mutierender Controller wird für den
gegenwärtigen Scope nicht eingeführt. Der erste spätere Schritt verwendet zwei
synthetische Operatoridentitäten mit disjunkten Runs: Beide sehen ausschließlich
die erlaubten Ressourcen; fremde Secret-, Host- und Recoverydaten bleiben verborgen.

Vor Mutation werden Lesen, Planen, Ausführen und Löschen getrennte Rechte.
Ressourcenidentität, Eigentümer und ausführender Operator dürfen nicht
gleichgesetzt werden. Ein angezeigter Plan ist keine aktuelle Freigabe; Revision,
Ressourcenbindung und Berechtigung werden bei Ausführung erneut geprüft.
Konkurrierende Änderungen benötigen Locks beziehungsweise Revision Guards,
Quoten und ein gegen Operatoränderung geschütztes Audit. Notfallzugriff braucht
eine gesonderte nachvollziehbare Grenze. Negativtests umfassen Rechteentzug
zwischen Plan und Ausführung, fremde Run-ID, konkurrierendes Cleanup und
abgebrochene Operationen. Gesamtaufwand L; lokale Dateiberechtigungen allein
belegen diesen Vertrag nicht.

## Automation-API und IaC

Die vorhandenen PowerShell-Befehle decken die aktuelle lokale Automatisierung ab.
Ein zusätzlicher dauerhaft erreichbarer HTTP-Dienst bringt derzeit keinen
belegten Nutzen. Als nächster begrenzter Schritt wird ein versionierter lokaler
read-only Plan-/Result-Vertrag empfohlen, der bestehende Funktionen aufruft und
ohne Netzwerklistener nutzbar bleibt. Aufwand M; ein entfernter Action-Dienst
mit Authentisierung, Autorisierung, Audit und Betrieb wäre zusätzlich L.

Der Vertrag muss unbekannte Versionen zurückweisen und Planrevision, Status,
sanitisierte Fehler und fehlende Nachweise eindeutig ausgeben. Für spätere
Aktionen sind Idempotenzschlüssel, Long-Running Operations, Abbruch, Resume und
unbekannter Ausgang erforderlich. Ein Retry darf keine zweite Mutation erzeugen.
Die Abnahme beginnt mit identischem Plan bei identischem Input, ungültiger
Version, Drift und unverändertem State bei read-only Aufrufen.

Terraform, Ansible, DSC und Pulumi bleiben Alternativen hinter dieser Grenze.
Erst ein konkretes konsumierendes Projekt bestimmt einen einzelnen Pilotadapter.
Dieser darf keine zweite Providerlogik oder abweichende Cleanupregeln enthalten.
Exit bedeutet Rückkehr zur gleichen PowerShell-API mit weiterhin lesbarem State;
kein Adapter erhält eine eigene parallele Ressourcenregistrierung.

## Cluster, HA und DR

Der [Clusterbacklog](SQL_SSIS_SSAS_CLUSTER_BACKLOG.md) bleibt fachlich sinnvoll
für SQL-Failover- und Recovery-Schulungen. Seine Umsetzung startet erst mit einem
konkreten Szenario, isolierter Domänen-/Netzwerk-/Storage-Bindung und bestätigtem
Ressourcenbudget. Ein lokaler Einzelhost kann funktionalen Gastfailover prüfen;
er kann seinen eigenen physischen Ausfall nicht als überlebt nachweisen.

| Fähigkeit / Nutzen | Entscheidung, Abhängigkeit und nächster Schritt |
|---|---|
| SQL Availability Group | Erster Clusterkandidat: zwei eigene Windows-SQL-Replikate, synthetische Transaktionsfolge, Listener und klarer Quorumvertrag. Geplanten Wechsel und einen kontrollierten Gastfehler prüfen; Rollen, bestätigte Transaktionen, Reconnect, Rejoin und Cleanup belegen. Aufwand L; Ergebnisse nur für den getesteten Commit-/Fault-Scope. |
| SQL FCI | Separater späterer Slice mit eigener Shared-Storage-Freigabe. Instanz-, Systemdatenbank- und Jobwirkung nach Knotenwechsel prüfen. Eine erfolgreiche AG ersetzt diesen Nachweis nicht. Aufwand L. |
| SSISDB-HA | Erst nach SQL-AG und eigenständiger SSIS-Abnahme. Schlüsselwiederherstellung, lokale Runtime, Jobs und Credentials getrennt binden. Abbruch vor/nach Ziel-Commit und erneute Package-Ausführung müssen fachlich idempotent bleiben. Aufwand L. |
| SSIS Scale Out | Erst bei belegtem parallelem Packagebedarf; zwei begrenzte Worker mit Versions-/Zertifikatsbindung. Workerabbruch und Wiederzuweisung prüfen. Kein Exactly-once- oder SSISDB-HA-Claim aus bloßem Workerbetrieb. Aufwand L. |
| SSAS WSFC | Erst nach Tabular-Einzelabnahme und bestätigtem SQL-2025-/Domain-Servicekonto-Vertrag. Failover bei Query und Processing, Entschlüsselung, Rollen und DAX-Ergebnisse prüfen. Aufwand L; keine Übertragung auf ältere SSAS-Stände. |
| SSAS Query Scale-out | Erst bei gemessenem Querybedarf; gemeinsame Modellrevision auf zwei eigenen Queryknoten erzwingen. Unterschiedliche Generationen blockieren Freigabe. Knotenverlust, Client-Retry und Aktualisierung prüfen. Aufwand L. |
| Gemeinsame BI / mehrere Hosts | Erst nach allen verwendeten Einzelverträgen. Fachliche Quell-/Warehouse-/DAX-Konsistenz unter Fault belegen. Physische HA benötigt mehrere gebundene Hosts samt unabhängigem Infrastrukturfehler; RPO/RTO bleiben Messwerte des konkreten Laufs. Aufwand L zusätzlich zu den Einzelabnahmen. |

## Quellen und Abnahmegrenze

Diese Bewertung hat keine Konten, Hosts, Dienste oder Cluster verändert. Die
Code-/Backlog-Inventur und folgende am 2026-09-10 gelesene Primärquellen stützen
die Trennung der Verträge; Priorisierung und Eintrittskriterien sind eigene
Projektentscheidungen.

- Microsoft unterscheidet [FCI und Availability Groups](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/failover-clustering-and-always-on-availability-groups-sql-server?view=sql-server-ver17) und ihre Rollen im Windows-Cluster.
- Für [SSAS 2025 im WSFC mit erweiterter Verschlüsselung](https://learn.microsoft.com/en-us/analysis-services/instances/encryption-upgrade?view=sql-analysis-services-2025) verlangt Microsoft dasselbe Active-Directory-Domänenbenutzerkonto als Dienstkonto auf den beteiligten Instanzen; lokale Konten ersetzen diese Voraussetzung nicht.
