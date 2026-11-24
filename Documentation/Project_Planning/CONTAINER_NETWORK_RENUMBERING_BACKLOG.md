# Container-Netzwerkverschiebung bei IP-Konflikt – Backlog

| Merkmal | Wert |
|---|---|
| Status | `IN_PROGRESS` · geführte Migration integriert, Recovery-Ausführung offen |
| Stand | 2026-11-22 |
| Zweck | sichere, explizit ausgeloeste Renummerierung vollstaendig verwalteter Docker- und Podman-Labnetze |
| Autoritaet | Planung und Priorisierung; keine Runtime-, Netzwerk-, Container- oder State-Mutationsautoritaet |

## Ausgangslage

`SQL_Server_Lab` prueft vor der erstmaligen Anlage eines Labnetzes aktive
IPv4-Hostrouten und vorhandene Runtime-Netze. Die lokale Reservierung
`SQL_SERVER_LAB_RESERVED_SUBNETS` ergaenzt diese Pruefung um bekannte VPN-
Praefixe, die bei getrennter VPN-Verbindung nicht live sichtbar sind.

Ein bestehendes Docker- oder Podman-Netz kann sein Subnetz nicht live ändern.
Der integrierte Ablauf ersetzt das verwaltete Netz. Die gebundenen Container
werden dafür über ein getrenntes Übergangsnetz geführt und mit ihren
bestehenden IDs wieder angeschlossen. Ein Konflikt erzeugt zunächst eine
Vorschau für den Betreiber.

## Umsetzungsstand

CLI und Browser bieten die gebundene Vorschau mit optionalem IPv4-Zielsubnetz
und eine eigene Bestätigung für `Move-SqlServerLabContainerNetwork`. Der lokale
Executor prüft Netz, Registry, Mitgliedschaften und Provider-Endpunkt erneut.
Bei einer unterbrochenen Migration sperrt das Journal eine weitere Ausführung.
Die Vorschau zeigt die letzte gespeicherte Phase sowie den bekannten Fehlercode.
[Bedienablauf](../HowTo/LAB_NETWORKS.md)

Der Stand `27a67f4f` wurde am 22.11.2026 je einmal mit einer eigenen
SQL-2025-CU9-Instanz unter Docker und Podman ausgeführt. Beide Netzwechsel
erhielten die synthetischen SQL-Daten. Podman bestand den automatischen
Cleanup. Docker benötigte nach Abbruch der Cleanup-Bestätigung eine gezielte
Bereinigung desselben Runs und Netzes. CLI- und Browser-Dispatch sind separat
synthetisch geprüft. [Abnahmedetails](../Quality/CLI_GUI_FUNCTION_COVERAGE.md)

Als Nächstes benötigt die Recovery eine eindeutige Journalbindung für jeden
Container einschließlich Scope und Instanz. Der vorhandene Planfingerabdruck
schließt diese Werte ein. Die gespeicherte Mitgliedsliste enthält derzeit ID,
Run-ID, Name, alte Laufbereitschaft und Aliasse. Erst ein typisiertes Journal
mit frischer Prüfung von Provider-Endpunkt, Netz- und Mitgliedsidentitäten
kann eine Fortsetzung oder Rückführung zulassen. Die bisherige Phase bleibt
ein Diagnosebefund. Bereits vorhandene Journale müssen lesbar und auswertbar
bleiben. Synthetische Fehlerfälle und getrennte native Docker- und
Podman-Nachweise sind für die Recovery-Abnahme erforderlich.

## Ziel und Grenzen

Der erste Vertrag umfasst ausschliesslich Docker und Podman. Er soll einen
read-only Migrationsplan und eine erst nach expliziter Operatorfreigabe
ausfuehrbare Action bereitstellen. Eine erwartete kurze SQL-Nichterreichbarkeit
ist vor der Action sichtbar auszuweisen.

Nicht Bestandteil dieses Backlogs sind:

- automatische Umadressierung ohne explizite Action;
- Aenderungen an VPN-, Hostroute- oder Unternehmensnetzkonfigurationen;
- Uebernahme, Umadressierung oder Loeschung fremder oder geteilter externer
  Container und Netze;
- Hyper-V-vSwitch-, WinNAT-, IPAM-, LAN- oder Gastnetz-Migrationen.

Hyper-V benoetigt wegen seiner eigenen vSwitch-, WinNAT- und IPAM-Semantik
einen getrennten Zielvertrag und wird durch einen Container-Nachweis nicht
abgedeckt.

## Zielvertrag

### Konfliktinventar und sichtbarer Handlungsbedarf

Eine read-only Funktion inventarisiert je Provider das verwaltete Netz, sein
Istsubnetz, den kollidierenden CIDR und dessen Quelle. Quellen sind aktive
Hostrouten, Docker-/Podman-Netze und lokale Reservierungen. Der Plan zeigt
eindeutig einen der folgenden Zustaende:

- `NO_CONFLICT` fuer ein konfliktfreies Netz;
- `MIGRATION_ELIGIBLE` fuer ein vollstaendig verwaltetes Netz mit pruefbarem
  Zielsubnetz;
- `BLOCKED` bei fehlender Ownership, laufender ungebundener Abhaengigkeit,
  Zielkollision oder nicht erreichbarer Runtime;
- `MANUAL_REQUIRED` bei nicht beweisbarer Recovery oder einem nicht vom
  Framework steuerbaren Objekt.

Ein Konflikt muss im Workflow und im Reconcile-Plan sofort als
Handlungsbedarf sichtbar sein. Neue Provisionierungen bleiben mit
`LAB_NETWORK_SUBNET_CONFLICT` blockiert. Bestehende Ressourcen bleiben bis zu
einer expliziten Action unveraendert.

### Ownership und Preflight

Vor jeder Mutation revalidiert der Executor:

- Provider, Runtime-ID, Netzname und aktuelles Subnetz;
- das Netzlabel `sql-server-lab.network=managed`;
- Run-, Scope- und Instanzlabels jedes betroffenen Containers;
- persistente Mount- und Volume-Fingerprints, Image, Portbindung,
  Ressourcenwerte, Autostart und SQL-Runtimevertrag;
- den aktuellen `connection-info.json`- und Run-State-Vertrag;
- das Zielsubnetz gegen aktive und reservierte Praefixe sowie vorhandene
  Runtime-Netze.

Eine fehlende oder abweichende Bedingung blockiert vor der ersten Mutation.
Fremde, unvollstaendige oder als `SHARED_EXTERNAL` erkennbare Ressourcen
werden nicht in einen Aktionsplan aufgenommen.

### Journal, Action und Recovery

Die Umsetzung benoetigt ein eigenes, atomar schema-validiertes und
geheimnisfreies Journal `SqlServerLab.ContainerNetworkMigrationJournal/1.0`.
Es bindet mindestens OperationId, Provider, Ursache, altes und neues Netz,
betroffene Containeridentitaeten, Vorzustand, Ersatzidentitaeten,
State-Revision, Status und Recovery-Informationen.

Der Executor arbeitet pro Provider in deterministischer Reihenfolge:

1. Zielnetz nach erneutem Konflikt- und Ownership-Preflight erstellen und
   inspizieren.
2. Jeden berechtigten Container geordnet stoppen und unter einem
   scopegebundenen temporaren Namen als Rollbackquelle erhalten.
3. Den Ersatzcontainer mit unveraendertem Image, Umgebung, Mounts, Volumes,
   Loopback-Port, Ressourcen, Autostart und SQL-Konfiguration am Zielnetz
   erstellen.
4. Runtime-Inspektion, SQL-Readiness und den gespeicherten Endpunkt pruefen.
5. Erst nach erfolgreicher Gesamtnachbedingung die betroffenen
   `connection-info.json`-Netzbindungen atomar fortschreiben und das alte Netz
   entfernen.

Vor dem Entfernen des Altnetzes rollt ein Fehler bereits migrierte Container
deterministisch auf die gebundenen Ausgangsressourcen zurueck. Nicht eindeutig
feststellbare Runtime- oder Statezustaende enden als `RECOVERY_REQUIRED`,
erhalten das Journal und blockieren jede weitere Mutation. Resume verwendet
ausschliesslich die im Journal gebundene Operation und ermittelt weder Ziele
neu noch uebernimmt es fremde Ressourcen.

Docker und Podman erhalten getrennte Providerexecutoren und Nachweise. Die
bestehende Podman-3.4.4-CNI-Kompatibilitaetskorrektur bleibt eng auf ihren
bekannten Vertrag beschraenkt; unbekannte CNI- oder Netavark-Dateien duerfen
nicht durch die Migration veraendert werden.

## Ursprüngliche Umsetzungsreihenfolge

1. Netz- und Konfliktinventar in `Private/LabNetwork.ps1` erweitern und einen
   rein lesenden Plan einschliesslich eindeutiger Workflowprojektion erzeugen.
2. Eigenes Journal und Schema vor jedem mutierenden Executor einfuehren.
3. Docker-Vertical-Slice mit einem synthetischen SQL-Server-2025-Container,
   persistentem Mount, Autostart, Readiness, Rollback und Cleanup belegen.
4. Den gleichwertigen Podman-Vertical-Slice einschliesslich dessen
   Netzinspektionsvertrag belegen.
5. Erst danach eine explizite `-WhatIf`-faehige oeffentliche Action mit
   Zielnetzfreigabe und Downtime-Bestaetigung anbieten.

## Validierung und Definition of Done

Vor einer Implementierung sind mindestens erforderlich:

- fokussierte statische Pruefungen fuer aktive und reservierte
  Konfliktursachen, Ziel-CIDRs, Eligibility, Blocker, Journal-Schema,
  Rollback und Resume;
- getrennte Docker- und Podman-Acceptances mit synthetischen SQL-Server-2025-
  Instanzen, persistenten Daten, Loopback-Readiness, Autostart, Migration und
  vollstaendigem Cleanup;
- negative Nachweise, dass fremde, unvollstaendige und geteilt-externe
  Ressourcen unveraendert bleiben.

Der Backlog ist erst abgeschlossen, wenn der read-only Plan den
Handlungsbedarf mit Ursache sichtbar macht, die explizite Action ausschliesslich
vollstaendig verwaltete Ressourcen verschiebt, Daten und Runtimeeigenschaften
nachweislich erhalten bleiben und Docker sowie Podman getrennt erfolgreich
validiert sind.

## Abhaengigkeiten

- [Feste isolierte Labnetze](../HowTo/LAB_NETWORKS.md)
- [Gemischter Container-Provider-Lifecycle](../Architecture/MIXED_PROVIDER_LIFECYCLE.md)
- [Container-Reconcile-Vertrag](../../Private/ContainerReconcile.ps1)
- [Querschnittliche Plattformfaehigkeiten](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)

Dieser Backlog autorisiert keine oeffentliche API, keine externe Verbindung
und keine Mutation.
