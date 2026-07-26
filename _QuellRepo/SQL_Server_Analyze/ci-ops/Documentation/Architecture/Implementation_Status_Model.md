# Implementierungsstatusmodell

Stand: 2026-07-25

Dieses Modell trennt Produktfunktion, automatisierte Repositoryevidenz, externe
Laufzeitnachweise und ausdrücklich optionale Erweiterungen. Ein offener
plattformabhängiger Nachweis darf eine vollständig implementierte
Current-State-Funktion nicht als unimplementiert erscheinen lassen. Umgekehrt
darf vorhandener Teilcode keinen vollständigen Produktvertrag vortäuschen.

## Kanonische Produktstatuswerte

| Status | Bedeutung | Zulässiger Einsatz |
|---|---|---|
| `IMPLEMENTED_ACTIONS_GATE` | Der definierte Produktumfang ist implementiert und durch die vorgesehene automatisierte Matrix nachgewiesen. | Code, Installer, Inventare, Dokumentation und verpflichtende Runtimeverträge stimmen überein. |
| `IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING` | Der portable Produktkern ist implementiert; ein ausdrücklich externer, plattformabhängiger Nachweis in einer Umgebung mit aktiviertem Feature steht noch aus. | Die fehlende Evidenz ist nicht Teil der portablen Kernfunktion und wird in `External_Evidence_Gates.csv` geführt. |
| `PARTIAL_PRODUCT_FUNCTION` | Nutzbare Bausteine sind vorhanden, der zugesagte öffentliche Gesamtvertrag ist aber noch nicht vollständig. | Der vorhandene und der offene Umfang müssen getrennt benannt werden. |
| `RESEARCHED_NOT_IMPLEMENTED` | Recherche oder Design liegen vor, jedoch kein auslieferbarer Produkt-Slice. | Capability-Erkennung allein gilt nicht als Implementierung der Analysefunktion. |
| `OPTIONAL_FUTURE` | Eine Erweiterung ist bewusst optional und blockiert keinen aktuellen Produktabschluss. | Sie darf nicht als fehlende Kernfunktion oder Releasefehler gezählt werden. |

Spezifische Evidence-Gate-Werte wie `IMPLEMENTED_AUTOMATED_GATE`,
`DESIGN_READY_EXTERNAL_COMPONENT_REQUIRED` oder
`RUNBOOK_READY_EXTERNAL_EXECUTION_REQUIRED` bleiben in ihren bestehenden
Qualitätsregistern gültig. Sie ersetzen den Produktstatus nicht.

## Bewertungsregeln

1. Der Status bezieht sich immer auf einen explizit abgegrenzten Umfang.
2. Ein Erweiterungsslice erhält eine eigene Zeile, wenn sein Status vom
   ausgelieferten Kern abweicht.
3. `IMPLEMENTED_ACTIONS_GATE` setzt keine reale Kundendaten- oder
   Produktionsumgebung voraus; Repositorytests verwenden ausschließlich
   synthetische Fixtures.
4. Externe Nachweise speichern keine Laufzeitlogs, Binärdateien, Identitäten,
   Pfade oder Umgebungswerte im Repository.
5. Ein Statuswechsel erfordert eine konsistente Änderung von Architekturvertrag,
   maschinenlesbarem Register, Tests und – falls betroffen – Installer und
   öffentlichem Resultsetinventar.

## Aktuelle Abgrenzung

Die kanonischen Zuordnungen stehen in
`Metadata/Quality/Implementation_Status.csv`. DIAG-003 bis DIAG-005 sowie SQL25-001 bis SQL25-004 sind mit
ihren kanonischen Zielresultsets, Inventaren und versionsübergreifenden
Runtimeverträgen abgeschlossen. SQL25-001 bis SQL25-004 verweisen zusätzlich
auf die öffentlichen Verträge
`Metadata/Quality/SQL25_Vector_Index_Public_Contract.json` und
`Metadata/Quality/SQL25_JSON_Index_Public_Contract.json` und
`Metadata/Quality/SQL25_TempDB_Resource_Governance_Public_Contract.json` und
`Metadata/Quality/SQL25_Readable_Secondary_Statistics_Public_Contract.json`.
Für SQL25-001 gilt
eine reine Capability-Inventur ausdrücklich nicht als Laufzeitimplementierung;
SQL25-002 ist bewusst als Erweiterung der vorhandenen Objekt- und
Capability-Inventare ohne eigene Procedure abgegrenzt. SQL25-003 erweitert
Resource-Governor-, TempDB- und Current-State-Pfade ohne neue öffentliche
Procedure und trennt Konfiguration, Wirksamkeit, Laufzeit- und Resetevidenz.
SQL25-004 erweitert die vorhandene Statistikprocedure ohne neue öffentliche
Procedure und trennt aktuelle Datenbankrolle, Quellenstatus, temporäre
Statistiken und Herkunft beziehungsweise letzte Aktualisierungsrolle.
RUNTIME-001 ist als implementierter portabler Kern mit ausstehenden
externen Feature-Nachweisen eingestuft. Bei SC-023 bleibt der bereits
abgenommene Performance-Counter-Slice implementiert; weitere Collector und
Rollups sind optionaler Ausbau.

LAB-001 ist als `PARTIAL_PRODUCT_FUNCTION` eingestuft. Welle 1 stellt den read-only Preflight und den begrenzten Orchestrator-Core bereit. Die Wellen 2 und 3 liefern die Single-Container-Baseline und die Core-Performance-Matrix. Welle 4 ergänzt die Multi-Container-Laufzeit und die begrenzte Log-Shipping-Aktion; 17 weitere Infrastrukturaktionen und der Network-Fault-Layer bleiben offen. Für Welle 5 ist die Image-Pipeline-Vertragsgrundlage vorhanden, die Runtime bleibt `NOT_EXECUTED`. Das Docker-/Podman-Quick-Testsystem besitzt einen vollständigen Lifecycle-Vertrag; seine nativen externen Nachweise stehen noch aus. Die Wellen 6 bis 10 bleiben geplant.
