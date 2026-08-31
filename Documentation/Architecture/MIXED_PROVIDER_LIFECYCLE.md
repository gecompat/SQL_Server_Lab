# Gemischter Container-Provider-Lifecycle

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_CONTAINER_SCOPE` |
| Stand | 2026-07-30 |
| Geltungsbereich | Docker und Podman innerhalb eines gemeinsamen Runs |
| Nicht enthalten | Hyper-V, provideruebergreifende Netzwerke, IPAM, Reconcile |

## 1. Zweck und Abgrenzung

Ein Manifest darf mehrere SQL-Server-Instanzen enthalten, die Docker und Podman
verwenden. Der Run besitzt weiterhin genau eine `RunId` und eine `ScopeId`.
Jeder verwendete Containerprovider bildet darin jedoch einen eigenen
`ProviderSubRun`.

Dies ist ein Container-Lifecycle-Vertrag. Die Instanzen sind über ihre
Host-Endpunkte erreichbar, aber es wird noch keine gemeinsame Netzwerk- oder
Cluster-Topologie zwischen Docker und Podman erzeugt. Hyper-V bleibt
`NOT_IMPLEMENTED`.

## 2. Persistenter Vertrag

`run-state.json` enthält für jeden verwendeten Provider einen `ProviderSubRun`:

```json
{
  "id": "provider-docker",
  "provider": "docker",
  "instanceIds": ["docker-primary"],
  "state": "RUNNING"
}
```

Ein ProviderSubRun besitzt eine eigene State-History. Der globale Run-State
bleibt die zusammenfassende Bedienoberfläche. `connection-info.json` führt die
providergebundenen Connection-Informationen weiterhin je Instanz.

`cleanup-plan.json` enthält ebenfalls ProviderSubRuns. Jeder Cleanup-Step
referenziert den passenden Teilrun; die eigentliche Kompensation wird weiterhin
in umgekehrter Abhängigkeitsreihenfolge ausgeführt.

Bestehende Single-Provider-Run-States ohne `providerSubRuns` bleiben lesbar.
Sie erhalten keine nachträgliche Mutation allein durch Statusabfragen.

## 3. Lifecycle-Regeln

### Provisionierung

`New-SqlServerLab` prüft vor jeder Mutation alle im Manifest verwendeten
Containerprovider. RAM, Storage und Portkapazität werden einmal runweit
bewertet. Jede Instanz wird durch ihren Provider erzeugt; anschließend werden
die globalen und providergebundenen States gemeinsam fortgeschrieben.

Scheitert die Provisionierung, wird der Cleanup-Plan für alle bereits erzeugten
Providerressourcen ausgeführt. Ein Teilfehler eines Providers wird nicht über
eine andere Runtime kaschiert.

### Windows-Hoststart

Ein `autostart=on`-Container erhält weiterhin den providergebundenen
`unless-stopped`- und Label-Vertrag. Die benutzergebundenen Windows-Aufträge
erkennen zusätzlich, ob Docker Desktop und Podman Desktop gemeinsam vorhanden
sind. Ein verwalteter Podman-Auftrag wartet in diesem Fall zuerst auf Docker,
bevor er die Podman Machine und anschließend Podman Desktop startet. Damit ist
die Reihenfolge deterministisch, obwohl Windows Login-Einträge untereinander
keine Reihenfolge zusagen.

Der Koordinator übernimmt ausschließlich den bekannten Podman-Desktop-Eintrag
`io.podman_desktop.PodmanDesktop`. Dessen Originalwert liegt als lokales
Recovery-Receipt außerhalb des Repository. Das Entfernen des letzten
Podman-Autostart-Containers stellt den Wert wieder her; fremde oder während der
Verwaltung geänderte Werte werden nicht überschrieben. Ist nur eine Runtime
installiert, enthält das generierte Skript keine Abhängigkeit zur anderen.

### Status

`Get-SqlServerLab` fragt Docker und Podman getrennt ab. Mit `-Detailed` enthält
das Ergebnis zusätzlich die gespeicherten `ProviderSubRuns`. Eine fehlende
Runtime wird pro Provider als Runtime-Hinweis gemeldet; sie führt nicht zu
einer Abfrage über einen anderen Provider.

### Start

`Start-SqlServerLab` startet alle ProviderSubRuns. Der globale State wechselt
nur dann zu `RUNNING`, wenn jeder Teilrun erfolgreich gestartet wurde.

Kann ein Teilrun nicht starten, werden bereits gestartete Teilruns wieder
gestoppt. Ist dieser Rollback unvollständig, wird der globale Run auf
`CLEANUP_PENDING` gesetzt, damit ausschließlich `Remove-SqlServerLab` den
registrierten Cleanup-Pfad fortsetzt.

### Stop

`Stop-SqlServerLab` stoppt alle ProviderSubRuns getrennt. Nur ein vollständig
erfolgreicher Stop setzt den globalen Run auf `STOPPED`. Bei einem Teilfehler
bleibt der globale State `RUNNING`, damit ein erneuter Stop oder ein
scope-gebundener Remove möglich bleibt; die Ergebnisse je ProviderSubRun werden
zurückgegeben.

### Remove und Recovery

`Remove-SqlServerLab` und der automatische Fehler-Cleanup verwenden die
Providerinformationen der einzelnen Cleanup-Steps. Ein erfolgreicher Teilrun
wird als `CLEANED_UP` markiert. Fehlerhafte Teilruns bleiben als
`RECOVERY_REQUIRED` nachvollziehbar, während der globale State ebenfalls die
notwendige Recovery anzeigt.

## 4. Nicht zugesagte Funktionen

- kein gemeinsames Docker-/Podman-Netzwerk und keine direkte Container-zu-
  Container-Kommunikation über Providergrenzen;
- keine verteilte Transaktion, kein Failover und keine Clustersemantik;
- kein Hyper-V-SubRun;
- keine Providerneutralisierung von Drives, Network Intents, Software oder
  Reconcile; diese folgen den weiteren Wellen des
  [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrags](HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).

## 5. Nachweis

Der statische Vertrag wird mit folgendem Befehl geprüft:

```powershell
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
```

Der Runtime-Nachweis benötigt einen Runner mit den Labels `SQL_Lab`, `Docker`
und `Podman`:

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

Das Beispielmanifest [`example-mixed-provider-lab.json`](../../Schemas/example-mixed-provider-lab.json)
verwendet zwei kompakte SQL-Server-2022-Instanzen und ausschließlich
synthetische Testwerte.
