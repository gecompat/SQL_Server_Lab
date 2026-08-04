# Feste isolierte Labnetze

SQL_Server_Lab verwendet getrennte, langlebige Runtime-Netze. Sie werden nicht
beim Entfernen eines einzelnen Labs geloescht, damit parallele Runs dieselbe
Netzwerkgrundlage sicher teilen koennen.

| Runtime | Defaultname | Defaultsubnetz | Hostzugriff |
|---|---|---|---|
| Docker | `SQL_LAB_DOCKER` | `172.26.0.0/16` | veroeffentlichter Host-Port |
| Podman | `SQL_LAB_PODMAN` | `172.27.0.0/16` | veroeffentlichter Host-Port |
| Hyper-V | `SQL_LAB_HYPERV` | `172.28.0.0/24` | direkte Gast-IP, Host `172.28.0.1` |

Docker- und Podman-Netze werden als eigene Bridge angelegt. Sie erlauben
Kommunikation zwischen Containern derselben Runtime und den vorgesehenen
Host-Portzugriff. Der Container-Egress folgt dabei dem NAT-Verhalten der
jeweiligen Runtime. Hyper-V verwendet einen internen vSwitch. Nach OOBE erhält
ein SQL-Abnahmegast eine deterministische Lab-IP; TCP 1433 wird nur im
Gast-Labnetz freigegeben.

Für den ersten OOBE-Start eines Windows-SQL-Abnahmegasts richtet das Framework
die deterministische Gast-IP außerdem direkt per Unattend-Bootstrap ein. Es
aktiviert WinRM ausschließlich für die Hostadresse im Hyper-V-Labnetz. Der
Abnahmelauf bevorzugt weiterhin PowerShell Direct; ist die Gastintegration in
der OOBE noch nicht verfügbar, nutzt er vorübergehend diesen isolierten
Host-zu-Gast-Kanal. Der temporäre `TrustedHosts`-Eintrag auf dem Host wird nach
jedem Aufruf auf seinen vorherigen Wert zurückgesetzt.

## Kollisionsschutz

Vor der erstmaligen Anlage prüft die Runtime die IPv4-Hostrouten und die
vorhandenen Netze der jeweiligen Container-Runtime. Jede Ueberlappung beendet
den Vorgang mit `LAB_NETWORK_SUBNET_CONFLICT`; ein bestehendes Netz mit
abweichendem Subnetz oder einem abweichenden Netzwerkmodus endet mit
`LAB_NETWORK_CONTRACT_MISMATCH`.

## Konfiguration

Die Defaults lassen sich vor der ersten Anlage pro Prozess oder dauerhaft als
Umgebungsvariable überschreiben:

```powershell
$env:SQL_SERVER_LAB_DOCKER_SUBNET = '172.26.0.0/16'
$env:SQL_SERVER_LAB_PODMAN_SUBNET = '172.27.0.0/16'
$env:SQL_SERVER_LAB_HYPERV_SUBNET = '172.28.0.0/24'
```

Die zugehörigen Namen lassen sich mit `_NETWORK` überschreiben, zum Beispiel
`SQL_SERVER_LAB_HYPERV_NETWORK=SQL_LAB_HYPERV`. Ein bereits angelegtes Netz
wird nie stillschweigend umkonfiguriert; dafür muss zuerst bewusst ein neues,
kollisionsfreies Netz gewählt werden.

Runtime-übergreifende Kommunikation und kontrollierter Internet-Egress sind
absichtlich nicht Bestandteil dieses ersten Netzwerkvertrags.

## Hyper-V ohne manuelle Netzwerkbefehle

Die Hyper-V-Option im interaktiven Lab-Menü fordert bei Bedarf einmalig die
Windows-UAC-Bestätigung an und setzt die Aktion dann in einem erhöhten
PowerShell-Fenster fort. Dort legt das Framework den internen Switch und die
Hostadresse automatisch an. Ein Anwender muss deshalb keinen separaten
`New-NetIPAddress`-Befehl eingeben. Automatisierte Läufe benötigen denselben
Mechanismus nicht, wenn der Runner bereits erhöht läuft.
