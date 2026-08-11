# AutomatedLab Provider Evaluation

## Entscheidung

| Merkmal | Wert |
|---|---|
| Status | `candidate` |
| Integration | optionaler Adapter innerhalb von `SQL_Server_Lab` |
| Führendes Projekt | `SQL_Server_Lab` |
| Externe Runtime | [AutomatedLab](https://github.com/AutomatedLab/AutomatedLab) |
| Produktdokumentation | [automatedlab.org](https://automatedlab.org/en/stable/) |
| Aktuelle Abhängigkeit | keine |

AutomatedLab besitzt potenziell nützliche Windows-/Hyper-V-Bausteine. Ob diese
Bausteine den nativen Hyper-V-Strang von `SQL_Server_Lab` tatsächlich
vereinfachen, ist nicht bewiesen. Deshalb wird AutomatedLab weder als
strategischer Standard noch als eigenes Companion-Projekt vorausgesetzt.

## Gewünschtes Abhängigkeitsverhältnis

```text
SQL_Server_Lab
  Blueprint
  Resource Assessment
  Run State und Journal
  Cleanup und Recovery
       |
       v
AutomatedLabProvider Adapter
       |
       v
AutomatedLab
       |
       v
Hyper-V / Windows
```

`SQL_Server_Lab` ruft den Adapter auf. Die Gesamtumgebung wird nicht als
AutomatedLab-Plugin oder ausschließlich als AutomatedLab-Custom-Role
modelliert. Custom Roles dürfen später ein internes Ausführungsmittel sein,
aber weder Blueprint, Run-State noch Cleanup-Eigentum übernehmen.

## Potenzieller Nutzen

Die Evaluation konzentriert sich auf Bereiche, in denen AutomatedLab einen
messbaren Vorteil gegenüber dem bestehenden nativen Provider liefern könnte:

- Bereitstellung mehrerer Windows-VMs auf Hyper-V;
- wiederverwendbare Basisimages und Differencing Disks;
- unbeaufsichtigte Windows-Konfiguration;
- Domain Controller und Domänenbeitritt;
- Windows Failover Cluster;
- SQL-Server-Rollen und mehrknotige SQL-Topologien;
- wiederholbarer Aufbau und Abbau kompletter Windows-Labs.

Der erwartete Nutzen liegt damit vor allem bei mehrknotigen Windows-Szenarien.
Für Docker, Podman, providerneutrale Blueprints, Artifact Trust, Slot-Hinweise,
Scenario-Steuerung und den gemeinsamen Cleanup-Core ist AutomatedLab kein
Ersatz.

## Hauptrisiken

| Risiko | Zu prüfende Wirkung |
|---|---|
| zweites Desired-State-Modell | widersprüchliche Planung und unklare Fehlerzustände |
| eigener AutomatedLab-State | Ressourcen sind nach Abbruch nicht über den Framework-State auffindbar |
| eigener Lifecycle | Start, Stop, Remove oder Cleanup umgehen Framework-Regeln |
| Medienautomatisierung | unerwünschte Downloads statt benutzerbereitgestellter ISO-/EXE-Artefakte |
| Windows-/Hyper-V-Fokus | keine Entlastung für Docker und Podman |
| Custom-Role-Kopplung | `SQL_Server_Lab` wird faktisch Plugin einer fremden Plattform |
| Versionskopplung | AutomatedLab-Updates erzwingen parallele Adapterpflege |
| versteckte Prompts | normaler Provisionierungspfad ist nicht Zero-Touch |
| breite Berechtigungen | Adapter verändert Ressourcen außerhalb seines Run-Scopes |
| Diagnoseabstraktion | konkrete Hyper-V-/Windows-Fehler gehen in generischen Meldungen verloren |

## Nichtziele des Spikes

- keine Ablösung des gesamten nativen Hyper-V-Providers;
- keine Änderung an Docker oder Podman;
- keine eigene AutomatedLab-Produktlinie;
- kein automatischer Download von Windows- oder SQL-Medien;
- keine Übernahme des kanonischen State durch AutomatedLab;
- keine allgemeine Nicht-SQL-Labplattform;
- kein Produktionsversprechen vor realer lokaler Abnahme.

## Vorgehen

1. Bestehenden nativen Hyper-V-Pfad als Vergleichsbasis erfassen.
2. Einen minimalen read-only Capability- und Planadapter entwerfen.
3. Genau eine Windows-/SQL-Umgebung mit festen Ressourcen abbilden.
4. Nur ausdrücklich vom Benutzer freigegebene lokale Medien verwenden.
5. Ressourcen-IDs und externe Handles in den Run-State zurückgeben.
6. Start, Stop, Inspect und Destroy über den Framework-Scope ausführen.
7. Fehler, Abbruch, Wiederaufnahme und vollständiges Cleanup prüfen.
8. Danach erst Domain-, Cluster-, AG- oder FCI-Funktionen untersuchen.
9. Ergebnisse gegen die Kriterien in
   [ACCEPTANCE_CRITERIA.md](ACCEPTANCE_CRITERIA.md) bewerten.
10. Entscheidung in [RESULTS.md](RESULTS.md) als `rejected`,
    `accepted-monorepo` oder `extraction-candidate` festhalten.

## Entwicklungsmodell

Während der Evaluation gelten Versionierung, Branches, Tests und Releases von
`SQL_Server_Lab`. Es gibt keine parallele Roadmap und keinen Anspruch, jede
AutomatedLab-Version unabhängig vom Bedarf des Frameworks zu unterstützen.

Ein später akzeptierter Adapter bleibt standardmäßig im Monorepo. Eine
Auskopplung wird nur geprüft, wenn sie nachweislich weniger Wartungsaufwand als
die gemeinsame Entwicklung verursacht.
