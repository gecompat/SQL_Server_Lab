# Mehrinstanz- und Mehrversionsumgebungen – Backlog

## Status und Befund

`PARTIAL` – der Manifestvertrag besitzt bereits `instances[]`, versions- und
providerbezogene Instanz-IDs sowie eine instanzbezogene Datenbank-, Storage-,
Netzwerk- und Ressourcenbeschreibung. Der ausführbare Docker-/Podman-Pfad
iteriert über alle Manifestinstanzen. Er unterstützt damit mehrere Instanzen
gleicher oder unterschiedlicher SQL-Server-Versionen in einem Run; Docker und
Podman dürfen dabei gemischt sein.

Die Containerlaufzeiten vergeben pro Instanz einen eindeutigen, ausschließlich
an Loopback gebundenen Hostport im Bereich 14330–14399 oder weisen eine
ausdrückliche Kollision vor dem Start ab. Containername, Volumes, Labels,
Connection-Info, ProviderSubRun und Cleanup sind an Run, Scope und Instanz-ID
gebunden.

Hyper-V erfüllt diesen Vertrag nicht: `New-SqlServerLab` lehnt einen reinen
Hyper-V-Manifestlauf mit mehr als einer Instanz explizit mit
`HYPERV_MANIFEST_SINGLE_INSTANCE_REQUIRED` ab. Ein Run, der Hyper-V mit Docker
oder Podman kombiniert, erreicht ebenfalls keinen ausführbaren Pfad. Der
bestehende Hyper-V-Slot-Pool ist kein Ersatz, weil er keine atomare
Mehrinstanz-Manifestprovisionierung, gemeinsame Run-Topologie oder
Mehrversions-Abnahme bereitstellt.

Die vorhandene Integration `Invoke-MixedProviderSmokeTest.ps1` belegt zwei
Containerprovider, setzt jedoch dieselbe SQL-Version für beide Ziele. Es gibt
keinen zielgerichteten nativen Nachweis für zwei gleichversionige Instanzen,
für unterschiedliche SQL-Versionen in einem Run oder für mehrere Hyper-V-Ziele
in einem Manifestrun.

## Zielbild

Ein Manifest beschreibt eine Menge eindeutiger SQL-Ziele. Jede Position in
`instances[]` bleibt ein eigenständiges Ziel mit eigener Version, Provider-,
Ressourcen-, Netzwerk-, Storage- und SQL-Konfiguration. Gleichversionige und
versionsgemischte Topologien sind zulässig, sofern Versionkatalog,
Providerfähigkeit, Ressourcenassessment und Datenbank-Kompatibilität sie
akzeptieren.

Für Docker und Podman entspricht ein Ziel genau einem SQL-Server-Container.
Für Hyper-V entspricht ein Ziel in der ersten Ausbaustufe genau einer eigenen
run- und scopegebundenen Windows-VM aus einem verifizierten Prepared Image.
Die Ausbaustufe führt **keine** mehreren benannten SQL-Dienste in derselben
Windows-VM ein. Dieser andere Betriebsmodus benötigt getrennte Service-,
Firewall-, Upgrade- und Cleanup-Verträge und bleibt außerhalb dieses Backlogs.

Ein Run darf Docker-, Podman- und Hyper-V-Ziele enthalten, sofern keine
providerübergreifende Netz-, Cluster- oder Failoversemantik gefordert wird.
Jedes Ziel liefert eine eindeutige Connection-Bindung; alle Lebenszyklus- und
Cleanup-Aktionen bleiben provider- und eigentumsgebunden.

## Umsetzungsumfang

1. Den Hyper-V-Manifestpfad von der Einzelinstanz-Sonderbehandlung in einen
   instanzweisen Provisionierungsablauf überführen. Jeder Hyper-V-Eintrag
   durchläuft Imageauswahl, Windows-Specialization, SQL-Readiness,
   Konfigurations-/Storage-Reconcile und Ergebnisbindung unabhängig.
2. ProviderSubRuns, Run-State, Desired-State-Snapshot, `connection-info.json`,
   Status, Start, Stop, Remove, Resume und Recovery auf mehrere Hyper-V-Ziele
   und gemischte Provider erweitern. Teilfehler müssen den bereits erzeugten
   Scope-Objekten zuordenbar und wiederaufnehmbar bereinigbar sein.
3. Die Manifestfachvalidierung vor jeder Mutation um eine vollständige
   Topologieprüfung ergänzen: eindeutige Instanz-IDs, unterstützte
   Provider-/OS-Kombinationen, Version/Image-Kompatibilität, eindeutige
   Hyper-V-VM-Namen und -Artefaktbindungen, Ressourcenaggregation und
   verbindliche Fehlercodes für nicht ausführbare Mischungen.
4. Einen providerneutralen Endpunktvertrag präzisieren. Container behalten die
   atomare Loopback-Hostport-Allokation; Hyper-V verwendet den pro VM gebundenen
   Gastendpunkt und muss bei host- oder LAN-exponierten Bindungen Kollisionen
   sowie Firewall-Ownership vor der Mutation prüfen. Feste SQL-Ports innerhalb
   verschiedener isolierter Gäste sind zulässig; dieselbe veröffentlichte
   Hostbindung nicht.
5. Die Version- und Datenbankvalidierung pro Ziel beibehalten und für
   Quell-/Ziel-Szenarien explizit nutzbar machen. Ein Backup, Restore, Upgrade
   oder Vergleich wird nur ausgeführt, wenn dessen eigener Kompatibilitäts- und
   Datenklassifikationsvertrag erfüllt ist; die Mehrinstanzfähigkeit impliziert
   keinen Datenübertragungs-Executor.
6. Manifestbeispiele und die Nutzerdokumentation um eine gleichversionige und
   eine versionsgemischte Topologie ergänzen. Die Known Limitations müssen bis
   zum nativen Nachweis die genaue Hyper-V- und Mischprovider-Grenze nennen.

## Technische Randbedingungen

- SQL-Versionen bleiben kataloggebunden; nicht unterstützte oder deprecated
  Versionen werden wie bisher fail-closed behandelt.
- Secrets, reale Hostnamen, private IP-Adressen, Zugangsdaten, Product Keys,
  Medienpfade und Datenquellen gehören weder in Manifeste, Planungen, Tests,
  Logs noch Evidenzartefakte.
- Resource Assessment summiert CPU, RAM, Image-/VHDX-Overhead, Datenvolumes
  und reservierte Ports über alle Ziele. Ein bestätigter Ressourcen-Override
  umgeht weder Sicherheits-, Ownership- noch Netzwerkblocker.
- Für Hyper-V ist jede VM, Child-VHDX, Zusatz-VHDX, virtuelle NIC,
  Firewallregel und jeder Checkpoint- bzw. Cleanup-Schritt anhand stabiler
  Run-, Scope- und Instanzidentität zu binden. Gemeinsame oder fremde Objekte
  dürfen nicht entfernt werden.
- Kein gemeinsames Docker-/Podman-/Hyper-V-L2-Netz, keine AG-/FCI-, Cluster-,
  Replikations- oder Failover-Automatisierung in dieser Ausbaustufe. Solche
  Szenarien benötigen einen separaten Topologievertrag.
- Der Einzelfall „mehrere benannte SQL-Instanzen auf einem Windows-Gast“ ist
  ausdrücklich nicht abgedeckt; seine Ports, Dienstnamen und Deinstallations-
  bzw. Upgrade-Risiken dürfen nicht stillschweigend durch die VM-Topologie
  ersetzt werden.

## Akzeptanzkriterien

- Ein Docker-Manifest mit zwei SQL-2022-Zielen wird erfolgreich provisioniert;
  beide Ziele haben unterschiedliche Instanz-IDs, Containernamen, Volumes und
  Loopback-Ports und werden über eigene Connection-Bindungen erreicht.
- Ein Docker-/Podman-Manifest mit mindestens SQL Server 2019, 2022 und 2025
  wird nur mit katalogkompatiblen Images provisioniert. SQL-Readiness bestätigt
  je Ziel die erwartete Major-Version.
- Ein reiner Hyper-V-Manifestlauf mit mindestens zwei Windows-SQL-Zielen
  erzeugt zwei isoliert gebundene, eindeutig identifizierbare VMs und stellt
  beide bis SQL-Readiness bereit.
- Ein gemischter Run mit mindestens einem Container- und einem Hyper-V-Ziel
  speichert und verwaltet alle Ziele über denselben Run, aber getrennte
  ProviderSubRuns und ohne gemeinsames Netz anzunehmen.
- Ungültige doppelte Instanz-IDs, nicht unterstützte Image-/Versionspaare,
  widersprüchliche Endpoint-Exposures und Ressourcen-Hard-Blocks werden vor
  der ersten Provider- oder State-Mutation mit stabiler Fehlerklasse abgewiesen.
- Stop, Start, Status, Remove und ein nach Teilfehler fortgesetzter Cleanup
  behandeln jede erzeugte Ressource genau einmal. Nicht zum Run gehörende
  Container, VMs, VHDX, Netzwerke, Ports oder Firewallregeln bleiben unangetastet.
- Alle neuen öffentlichen Ergebnisse und Testartefakte bleiben frei von
  Secrets, Endpointwerten, privaten Host-/Pfadinformationen und Dateninhalten.

## Teststrategie

1. **Statisch/Unit:** Schema- und Fachvalidierung für doppelte IDs,
   Mehrversionskatalog, Provider-/OS-Matrix, Endpointkollisionen,
   Ressourcenaggregation, Hyper-V-Mehrziel-Plan, Ownership und
   Recovery-Reihenfolge.
2. **Container nativ:** Docker und Podman jeweils mit zwei gleichversionigen
   Zielen sowie mit mindestens zwei unterschiedlichen unterstützten Versionen;
   Portallokation, Readiness-Major-Version, Lifecycle und Cleanup prüfen.
3. **Gemischt nativ:** Docker plus Podman mit unterschiedlichen Versionen;
   anschließend ein Container- plus ein Hyper-V-Ziel, jeweils mit getrennten
   ProviderSubRuns und vollständigem Cleanup.
4. **Hyper-V nativ:** zwei SQL-Prepared-Images derselben Version und zwei
   unterschiedlichen unterstützten Versionen. VM-, Child-VHDX-, Drive-, NIC-,
   Endpoint-, SQL-Readiness- und Cleanup-Evidence je Instanz erfassen.
5. **Negativ/Recovery:** absichtlicher Fehler nach erfolgreicher erster
   Instanz, belegter veröffentlichter Port, fehlendes oder falsches Prepared
   Image, unzureichende Ressourcen und Resume. In jedem Fall Scope-gebundene
   Rücknahme nachweisen.
6. **Dokumentation:** Beispiele gegen das Schema validieren und Known
   Limitations, Provider- und Manifestdokumentation auf den realen
   Implementierungsumfang prüfen.

## Vorrang und Abgrenzung

Die Umsetzung priorisiert den bestehenden kanonischen Entwicklungs- und
Ausführungsplan. Sie erweitert keine Datenübertragung, Hochverfügbarkeit oder
Windows-In-Gast-Mehrfachinstanzen. Diese Themen werden erst nach einem
evidenzgebundenen Mehrziel-Lifecycle separat geplant.
