# Linux-Containerhost für SQL External Languages

Der lokale Docker-Desktop- oder Podman-Host kann cgroup v2 verwenden, während
der katalogisierte SQL-Launchpad-Namespace-Pfad cgroup v1 benötigt. Die
Hostprüfung bleibt aktiv. Sie wird weder durch `--privileged` noch durch einen
Start ohne Sprachisolation umgangen.

## Native Linux- und WSL-Hosts ohne Hyper-V-Verwaltung

`Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1` verwendet vorhandene
Docker-/Podman-Runtimes direkt. `Plan` prüft den gewählten Provider mit Timeout
und unterscheidet fehlendes Werkzeug, unerreichbare Runtime, falsche
cgroup-Version und rootless Betrieb. `COMPATIBLE` ist noch kein SQL-Sprachtest.
Unter Windows kann `Plan` auch den aktuellen Desktop-Provider prüfen.

Auf einem vorbereiteten Linux-System mit PowerShell 7.2+, sqlcmd und einem
lokalen rootful Provider mit cgroup v1:

```powershell
sudo env TEMP=/tmp pwsh
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Plan -Provider docker
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Initialize -Provider docker -DataRoot /srv/sql-lab/Lab_Data -MediaRoot /srv/sql-lab/Lab_Base
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Test -Provider docker
# Podman wird separat eingerichtet/geprüft; dieselben Storage-Roots verwenden.
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Initialize -Provider podman -DataRoot /srv/sql-lab/Lab_Data -MediaRoot /srv/sql-lab/Lab_Base
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Test -Provider podman
```

`Initialize` registriert fehlende Storage-Defaults und prüft Create-Readiness.
Bestehende Defaults, fremde Verzeichnisse, Pfadlinks und Remote-Provider werden
nicht stillschweigend übernommen. `-WhatIf` führt keine Einrichtung aus.
Ein gesperrtes lokales Setupjournal unter `.local/native-linux-container-host`
hält Teilfehler fest; Recovery erfolgt mit denselben Roots. Registrierung
und Daten werden bei einem Folgefehler nicht automatisch gelöscht.
Die Installation von OS-Paketen oder die Umstellung des Kernels ist kein
Seiteneffekt dieser Storage-Einrichtung. Fehlende Voraussetzungen blockieren.

Für eine ausdrücklich ausgewählte, bereits laufende WSL-Distribution:

```powershell
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Backend Wsl -Distribution Ubuntu -RepositoryRoot /opt/sql-server-lab -Action Plan -Provider podman
./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Backend Wsl -Distribution Ubuntu -RepositoryRoot /opt/sql-server-lab -Action Initialize -Provider podman -DataRoot /srv/sql-lab/Lab_Data -MediaRoot /srv/sql-lab/Lab_Base
```

Das Repository mit diesem Werkzeug und PowerShell müssen im Ziel vorhanden
sein. Aufrufe erfolgen als root in genau dieser Distribution; sie ändern
keinen WSL-Default und starten keine gestoppte Distribution. Vor dem
PowerShell-Aufruf erkennt die WSL-Prüfung einen explizit deaktivierten
`CONFIG_MEMCG_V1` als `KERNEL_MEMCG_V1_DISABLED`. Ein fehlendes lesbares
Kernelconfig wird nicht als positiver Kompatibilitätsnachweis gewertet;
die nachfolgende Providerprüfung bleibt maßgeblich.

Der ursprüngliche lokale WSL-Kernel hatte keinen v1-Speichercontroller.
Ein genehmigter Test mit Microsoft-Kernel 6.18.40.1 und passenden Modulen
aktivierte diesen Controller. Eine eigene Ubuntu-22.04-Distribution konnte
damit SQL 2025 unter Docker mit Python/R/Java vor und nach Restart ausführen;
der eigene Testlauf wurde anschließend entfernt. Der Test verwendete einen
externen Ressourcenpool mit `maxProcesses=128`; mit 32 scheiterte R beim
Starten eines Unterprozesses. Das ändert keinen Produktdefault.
Ein anderer Distributionsname allein behebt den gemeinsamen Kernel nicht. Kernel und
`kernelCommandLine` sind globale WSL2-Einstellungen; dieser Einstieg verändert
sie nicht. [Microsoft beschreibt diese Geltung](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).
Die cgroup-Hierarchie lässt sich über `automount.cgroups` in `wsl.conf` pro
Distribution wählen, sofern Kernel und WSL-Version dies erlauben. Das ersetzt
keinen fehlenden Kernelcontroller. Ein Kernelwechsel bleibt eine gemeinsame
Hoständerung mit WSL-Neustart; laufende Desktop-Container sind davon betroffen.
Die direkten Linux-Aufrufe für Docker und Podman bestanden dagegen getrennt
mit allen drei Sprachen, Restart und Cleanup; Details und Grenzen stehen im
[Validierungsstand](../Quality/LOCAL_VALIDATION_STRATEGY.md).

WSL-Distributionen teilen sich Kernelcontroller und können sich auch über
Netzwerkregeln beeinflussen. Die Startreihenfolge von v1- und v2-Distributionen
ist daher relevant. Der Einstieg prüft zusätzlich echte Memory-/Pids-Controller;
die Versionsangabe `1` allein genügt nicht. Gleichzeitiger Betrieb dieses
Kompatibilitätshosts mit Desktop-Runtimes ist nicht als zuverlässig belegt.
Der interne Bootstrap `Tools/Common/wsl-container-host-bootstrap.sh` ist auf
einen markierten, eigenen Ubuntu-22.04-WSL-Host begrenzt. Er installiert Pakete
und verwendet Legacy-iptables für das enthaltene Podman-CNI. Er erzeugt keine
Distribution und ändert weder den gemeinsamen Kernel noch Bootparameter.
Sein Einsatz benötigt ein Wartungsfenster für gemeinsam betroffene WSL-Runtimes.

## Optionaler automatischer Hyper-V-Aufbau

`Tools/Invoke-SqlServerLabLinuxContainerHost.ps1` richtet dafür eine separate,
persistente Hyper-V-VM ein. Im Gast laufen rootful Docker und rootful Podman;
Hyper-V ist lediglich der Infrastrukturhost. SQL-Labs werden anschließend
über dieselben öffentlichen PowerShell-Befehle **im Linux-Gast** verwaltet.
Das Windows-Menü inventarisiert diese Gast-Runs nicht. Es gibt weder einen
offenen Docker-TCP-Socket noch eine automatische Umschaltung des Desktop-Contexts.

**Der automatische VM-Aufbau benötigt Hyper-V auf Windows.** Ohne Hyper-V
bricht das Werkzeug vor dem VM-Aufbau ab; es installiert Hyper-V nicht und
wechselt nicht automatisch auf VMware, VirtualBox, WSL oder einen Remotehost.
`Plan` weist diese Backendanforderung ausdrücklich aus. Ein bereits vorhandener
passender Linux-Host kann den Lab-Core direkt mit Docker/Podman verwenden,
wird von diesem Windows-VM-Werkzeug aber nicht eingerichtet oder verwaltet.

Die lokale Untersuchung vom 2026-09-24 bestätigte für den vorhandenen
SQL-2025-Extensibility-Build `17.0.4065.4-1` unter Docker/cgroup v2 den
Launchpad-Abbruch `[RG] Failed to create new V1 cgroups: cgroups: cgroup
mountpoint does not exist`. Die isolierte Probe verwendete keinen Hostdaten-
oder cgroup-Schreibmount und wurde entfernt. Podman meldete ebenfalls v2;
ein eigener Launchpad-v2-Lauf unter Podman wurde dabei nicht ausgeführt.
Dies ist keine Aussage über alle zukünftigen Microsoft-Builds. Die vorhandene
Sprachisolation zu deaktivieren wurde nicht als Lösung übernommen.

## Voraussetzungen und Planung

- Windows mit Hyper-V und erhöhte PowerShell für VM-Mutationen;
- registriertes, controller-eigenes `Lab_Data` und konfiguriertes `Lab_Base`;
- bestehender interner Hyper-V-Switch mit DHCP/Internetzugang, standardmäßig
  `Default Switch`;
- SSH, SCP, ssh-keygen, tar und Git auf dem Windows-Host;
- standardmäßig 16 GiB verfügbarer VM-RAM, acht vCPUs und eine dynamische
  160-GiB-Disk; mindestens 40 GiB freier Platz bei Erstellung.

```powershell
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Plan
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Create -WhatIf
$hostResult = .\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Create
$hostId = $hostResult.HostId
```

Der Aufbau verwendet dasselbe SHA-256-gebundene Ubuntu-22.04-Cloudimage wie die
vorhandene External-Runtime-Abnahme. Nur die eigene Gastdisk wird auf cgroup
v1 konfiguriert. Ubuntu-Pakete stammen aus den signierten Distributionsquellen,
PowerShell und sqlcmd aus dem Microsoft-Repository. Installierte Paketversionen
können sich ändern; der Bootstrap ist kein vollständig eingefrorenes OS-Image.
Das Image bleibt im Mediencache, VM/Disk/Journal/Schlüssel unter
`Lab_Data/LinuxContainerHosts/<HostId>`.

Im Gast werden ein eigener registrierter `Lab_Data`-Root und ein `Lab_Base`
unter `/var/lib/sql-server-lab` eingerichtet. Vorhandene Gast-Defaults bleiben
bei Recovery erhalten. Die Linux-Bootstrap-Pointer werden über den bestehenden
Preferences-Writer gespeichert; frische CLI-Prozesse finden damit dieselben
Roots. `READY` verlangt zusätzlich die Create-Readiness beider Gastprovider.

Das Werkzeug überträgt nur `git archive HEAD`, keine uncommitteten Dateien,
Hostkonfiguration, lokalen Secrets oder Caches. Ein erfolgreicher Bootstrap
bestätigt cgroup v1, beide Provider, PowerShell und sqlcmd. Er beweist noch
keinen erfolgreichen SQL-Sprachaufruf.

Der Gast bleibt an diesen Repository-Commit gebunden. `SyncRepository` dient
der Wiederherstellung desselben Snapshots; einen Wechsel auf einen anderen
Commit lehnt es ab. Für eine neue Revision wird ein neuer Host erstellt.
Damit werden alte und neue Moduldateien nicht durch ein partielles Update
vermischt; eine Migration bestehender Gast-Labs ist ein eigener Vorgang.

## Bedienung und separate Nachweise

```powershell
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Status -HostId $hostId
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Connect -HostId $hostId
```

Im Gast:

```powershell
Import-Module /opt/sql-server-lab/SqlServerLab.psd1
Invoke-SqlServerLab
```

Alle Lab-Befehle und State-Dateien gehören zu diesem Gast. Für rootful Podman
muss auch die PowerShell dort als root laufen; `Connect` erledigt das über
den ausschließlich für diese VM erzeugten SSH-Zugang und `sudo`.
Der Einstieg setzt für den beibehaltenen Docker-Verfügbarkeitscheck des
Lab-Cores außerdem `TEMP=/tmp` im Gastprozess. Bei einem eigenen SSH-Einstieg
ist entsprechend `sudo env TEMP=/tmp pwsh` zu verwenden.

```powershell
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Test -HostId $hostId -Provider docker
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Test -HostId $hostId -Provider podman
```

Jeder Test überträgt den separaten, SHA-256-geprüften
`Invoke-LinuxContainerHostAcceptance.ps1`-Runner in ein temporäres Gastverzeichnis.
Er erzeugt eigene SQL-2025-Ressourcen, prüft echte Python-/R-/Java-Aufrufe vor
und nach Restart und anschließend Cleanup. Der eingefrorene Lab-Core bleibt
unverändert. Wiederverwendbare Images bleiben im Providercache.
Reconcile ist kein Bestandteil dieses Hostnachweises. Ein Provider-PASS
ersetzt den anderen nicht. Logs und Evidence bleiben lokal im Hostverzeichnis.
Ein Fehler oder Timeout ist kein erfolgreicher Cleanup-Nachweis; Gast-State
und Journale müssen dann geprüft werden, bevor der Test erneut gestartet wird.

Erste getrennte SQL-2025-Hostabnahmen für Docker und Podman bestanden am
2026-09-24 einschließlich aller drei Sprachen, Restart und Cleanup, zunächst
mit übersprungener Ressourcenbewertung. Nach Einrichtung der regulären
Create-Voraussetzungen bestand Podman auch mit aktiver Ressourcenbewertung.
Weitere Docker-Läufe scheiterten dagegen an Launchpad-/Java-Laufzeitfehlern
(SQL 39011 beziehungsweise 39128); der Docker-Sprachpfad ist damit noch nicht
als zuverlässig validiert. Der frühere Docker-PASS hebt diese Fehler nicht auf.
Der [Validierungsstand](../Quality/LOCAL_VALIDATION_STRATEGY.md) grenzt diese
Nachweise vom weiterhin offenen Reconcile-Nachweis ab.

## Lebenszyklus, Recovery und Grenzen

```powershell
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Stop -HostId $hostId
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Start -HostId $hostId
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action SyncRepository -HostId $hostId
.\Tools\Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Remove -HostId $hostId -WhatIf
```

Stopp betrifft alle Gast-Labs. `Remove` löscht die **gesamte eigene VM samt
allen Gastdaten**; die Host-ID und das terminale Journal bleiben als Tombstone
erhalten. Shared-Medien und fremde VMs bleiben erhalten. VM-ID, Ownership-Notes
und exakte Diskbindung werden vor Lifecycle-Aktionen erneut geprüft.

Bei Fehlern bleiben Ressourcen bewusst für Recovery erhalten. Ein bereits
fertig gebooteter Gast lässt sich mit `Start` erneut prüfen und mit
`SyncRepository` fertigstellen. Für einen gescheiterten frühen Bootstrap gibt
es keinen blinden Create-Retry auf demselben Host: erst den eigenen Zustand
prüfen und gegebenenfalls explizit entfernen. Eine vorhandene VM ohne
gespeicherte VM-ID wird nicht anhand ihres Namens adoptiert oder gelöscht.

SSH-Client und Gast-Hostschlüssel werden vor VMstart erzeugt, der Gastschlüssel
wird über NoCloud injiziert und über `HostKeyAlias` strikt geprüft. Schlüssel
und Seed-Dateien liegen in einem Windows-Verzeichnis mit beschränkter ACL.
Es werden keine Host-Truststores oder Firewallregeln verändert.

SSMS erreicht die SQL-Loopbackports im Gast nicht direkt. Für einen gewählten
Gastport ist ein bewusst gestarteter SSH-Tunnel erforderlich; automatische
Portweiterleitung und Integration in die Windows-Verbindungszentrale sind
nicht Teil dieses Werkzeugs. External Models benötigen zusätzlich ihren eigenen
erreichbaren HTTPS-Modellendpunkt; der Sprachhost richtet ihn nicht automatisch ein.

cgroup v1 ist ein Kompatibilitätspfad, keine langfristige Modernisierung.
Eine spätere cgroup-v2-Freigabe benötigt eigene Launchpad-/SQL- und
Isolationsnachweise und darf nicht allein die bestehende Vorprüfung entfernen.
