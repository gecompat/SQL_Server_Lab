# Speicherfreigabe nach Lab-Stop

Ein gestoppter Container belegt keinen laufenden SQL-Prozessspeicher mehr.
Das bestätigt noch keine RAM-Rückgabe des gemeinsam verwendeten WSL2-Kernels
an Windows. Dateicache aus Builds, Downloads und Tests kann dort verbleiben.
`VmmemWSL` und Hyper-V-VM-Zuweisungen sind getrennt zu betrachten; WSL-Werte
aus mehreren Distributionen dürfen nicht als getrennte Speicherpools addiert werden.

## Begrenzte automatische Wartung

Nach einem erfolgreichen `Stop-SqlServerLab` prüft der Windows-Containerpfad
die verfügbare Hostreserve. Unter 25 Prozent freiem RAM wird ein eindeutig
zugeordneter, bereits laufender lokaler WSL2-Backend gesucht. Unterstützt sind
Docker Desktop mit lokalem Named-Pipe-Endpunkt und WSL2-Kernel sowie die aktive
lokale Podman-WSL-Machine. Remote-Verbindungen, Umgebungsvariablen zur
Endpunktübersteuerung, mehrdeutige Bindungen und gestoppte Distributionen
erhalten keine Mutation.

Sind mindestens 4096 MiB Dateicache/Puffer ohne Shared Memory vorhanden,
folgt einmal `sync && echo 1 > /proc/sys/vm/drop_caches` als Gast-root.
Dies ist eine eng begrenzte Ausnahme vom allgemeinen `REPORT_ONLY`-Vertrag
geteilter Runtime-Backends: nur flüchtiger Dateicache, keine Runtimeverwaltung.
Die Freigabe betrifft den gemeinsamen Linux-Kernel und kann den nächsten
Dateizugriff anderer Anwendungen verlangsamen. Sie beendet keine Container,
Distributionen oder VMs und löscht keine Images, Volumes oder Dateien.
WSL-Konfiguration, Speicherschwellen der Provisionierung und aktive
Runtimeauswahl bleiben unverändert. Ein Neustart von WSL ist kein Fallback.

Eine lokale Mutex-Sperre verhindert gleichzeitige Wartung. Native Aufrufe
sind auf jeweils 20 Sekunden begrenzt. Die Backendbindung wird direkt vor
der Freigabe nochmals gelesen. Eine externe, gleichzeitig erfolgende
Runtimeumschaltung bleibt eine Race-Grenze; der Stop ist kein exklusiver
Besitz des WSL-Hosts. Die Backendadministration sollte nicht parallel erfolgen.

Die Gruppe `Stop-SqlServerLabAutomatedTestEnvironment` führt die Prüfung
einmal nach vollständigem Gruppenstopp aus. Bei Teilerfolg, `WhatIf`,
abgelehnter Bestätigung oder bereits gestopptem Einzelrun erfolgt keine
Wartung. `Restart-SqlServerLab` erhält den warmen Cache.
`-SkipHostMemoryRelease` an Einzel- oder Gruppenstop deaktiviert die Prüfung.
Hyper-V-VMs werden über ihren bestehenden gebundenen Lifecycle gestoppt;
die neue Wartung schaltet keine zusätzlichen VMs ab.

## Nachweis statt Freigabeversprechen

Das zusätzliche Ergebnisfeld `HostMemory` trennt Labzustand und Hostspeicher:

| Status | Bedeutung |
|---|---|
| `NOT_APPLICABLE` | Kein Windows-Containerpfad |
| `NOT_REQUIRED` | Genügend Hostreserve oder weniger als 4096 MiB Cache |
| `DISABLED` | Explizit deaktiviert |
| `GROUP_DEFERRED` | Einzellauf innerhalb des Gruppenstopps |
| `STOP_INCOMPLETE` | Gruppenstopp nicht vollständig erfolgreich |
| `UNSUPPORTED_BACKEND` | Kein eindeutig gebundener lokaler WSL2-Backend |
| `BACKEND_CHANGED` | Bindung vor Mutation verändert |
| `DEFERRED` | Andere Speicherwartung aktiv |
| `HOST_RETURN_OBSERVED` | Cache kleiner und mindestens 64 MiB mehr Host-RAM beobachtet |
| `RETURN_PENDING` | Cacheanforderung erfolgreich, Host-Rückgabe noch nicht bestätigt |
| `CHECK_FAILED` | Messung oder begrenzter Aufruf fehlgeschlagen |

Vorher-/Nachherwerte sind MiB und bleiben lokale Runtime-Evidence. Die
Hostdifferenz ist keine exakte kausale Zuordnung: andere Prozesse arbeiten
parallel. Bis zu fünf Sekunden wird auf eine erste Rückgabe gewartet;
WSL kann länger benötigen. Pending-, Binding- und Fehlerzustände werden
zusätzlich als Warnung ausgegeben. Sie ändern einen erfolgreichen Lab-Stop
nicht nachträglich in einen fehlgeschlagenen Providerzustand.

Dieser Mechanismus verhindert keinen beliebigen zukünftigen Speicherbedarf.
Aktiver SQL-/Modellspeicher und dauerhaft eingeschaltete eigene VMs benötigen
weiterhin passende Limits beziehungsweise einen ausdrücklich gebundenen Stop.

## Technische Referenzen

Die [Linux-Kernel-Dokumentation](https://kernel.org/doc/html/latest/admin-guide/sysctl/vm.html#drop-caches)
beschreibt `drop_caches` als Freigabe sauberer Caches, nicht als Begrenzung
künftigen Cachewachstums. Deshalb erfolgt hier kein periodisches Leeren,
sondern nur die beschriebene Stop-Nachprüfung bei Hostdruck.
[Microsofts WSL-Konfiguration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
beschreibt die getrennte automatische Speicherrückgabe. Ihre lokale
Konfiguration wird durch den Lab-Stop nicht verändert.
