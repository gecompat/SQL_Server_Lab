# Docker-QuickStart: Architektur- und Sicherheitsentscheidungen

**Status:** verbindlich  
**Geltungsbereich:** `QuickStart/Docker/`

## Ziel

Der Docker-QuickStart stellt einen anwenderorientierten Einstieg für lokale SQL-Server-Testumgebungen bereit. Er bleibt fachlich und technisch vom erweiterten Framework unter `Lab/` getrennt.

Der primäre Einstiegspunkt ist:

```powershell
./QuickStart/Docker/Setup.ps1
```

Für die vollständige Entfernung der verwalteten Umgebung steht zusätzlich zur Remove-Aktion folgender Einstiegspunkt bereit:

```powershell
./QuickStart/Docker/Uninstall.ps1
```

Das Setup kann SQL Server 2019, 2022 und 2025 einzeln oder kombiniert bereitstellen und das Framework anschließend automatisch in der synthetischen Datenbank `LabAnalyze` installieren.

## Abgrenzung zum erweiterten Lab

Der QuickStart verwendet keine Lab-Run-IDs, Evidence-Gates, Lab-State-Dateien, Image-Locks oder Szenariokataloge aus `Lab/`.

Gemeinsam genutzt wird ausschließlich der kanonische Frameworkinstaller unter `Code/Install/`.

Der QuickStart gehört als nutzerorientierte Repro-Umgebung zur Produktlinie. Workflows, Contract-Validatoren und andere Qualitätssicherungsartefakte gehören in die Operations-/Validation-Linie.

## Interaktive Konfiguration

`Setup.ps1` fragt mindestens folgende Werte ab:

- gewünschte SQL-Server-Versionen;
- Ressourcenprofil;
- Speicherlayout;
- sichere und leere Zielpfade;
- Hostports;
- SA-Passwort für die ausschließlich synthetischen Testinstanzen;
- Aktivierung des SQL Server Agents;
- automatische Frameworkinstallation;
- optionales I/O-Profil, sofern die gewählte Laufzeit es belastbar unterstützt.

Die Auswahl genau einer SQL-Server-Version ist gleichwertig zur Mehrfachauswahl zu unterstützen.

## Lokale Secrets

Das Setup schreibt die lokale Konfiguration nach:

```text
QuickStart/Docker/.env
```

Die Datei darf ein lokales Testpasswort enthalten und ist durch `.gitignore` vom Repository ausgeschlossen. Veröffentlichte Beispieldateien enthalten ausschließlich eindeutig synthetische Platzhalter.

Die `.env` darf beim ausdrücklich gestarteten Setup ersetzt werden. Andere Repository- oder Zieldateien dürfen nicht stillschweigend überschrieben werden.

## Speicherlayouts

### Single Root

Für Systeme mit nur einem lokalen Datenträger werden Steuerungsdateien, Backups und die verwaltete Pfadstruktur unter einer gemeinsamen, dedizierten Lab-Wurzel abgelegt:

```text
<LabRoot>/
  control/
  data/
  log/
  backup/
```

### Getrennte Wurzeln

Auf Systemen mit mehreren lokalen Datenträgern können Lab-Steuerung, die verwaltete Datenpfadstruktur und die verwaltete Logpfadstruktur in getrennten Wurzeln abgelegt werden.

Die Wurzeln dürfen weder identisch sein noch ineinander liegen.

### Laufzeitabhängige Persistenz

Auf einer nativen Linux-Docker-Engine werden die ausgewählten Daten- und Logpfade als Bind-Mounts verwendet. Dadurch können Linux-native Tests gezielt einem dedizierten Blockgerät zugeordnet werden.

Docker Desktop auf Windows betreibt Linux-Container innerhalb einer Linux-VM. Pro SQL-Version wird genau ein projektgebundenes Docker-Volume auf `/var/opt/mssql` gemountet. Daten, Logs, Systemmetadaten und der SQL-Secrets-Bereich bleiben dadurch in einer gemeinsamen Persistenzeinheit. Direkte Windows-Bind-Mounts für aktive SQL-Dateien sind ausgeschlossen. Hostpfade bleiben für Scope-Marker, Steuerungsdateien, Installer und Backups zuständig.

Ein neues leeres Volume übernimmt beim ersten Mount den vorhandenen Inhalt und die Besitzinformationen des Image-Verzeichnisses. Die Container verwenden daher auch unter Docker Desktop den vom Microsoft-Image vorgesehenen Non-root-Benutzer. Ein Root-Kompatibilitätsmodus oder getrennte Data-/Log-Volumes sind für Docker Desktop nicht zulässig.

## Pfadsicherheit

Vor der ersten Mutation gelten folgende Regeln:

- Zielpfade müssen absolut und lokal sein;
- jeder Zielpfad muss fehlen oder vollständig leer sein;
- Laufwerks- und Dateisystemwurzeln sind unzulässig;
- Betriebssystem-, Programm- und Repositorypfade sind unzulässig;
- die Benutzerprofilwurzel ist unzulässig;
- Netzwerkpfade, Junctions und symbolische Links sind unzulässig;
- getrennte Speicherwurzeln dürfen sich nicht überlappen.

Das Setup legt in jeder verwalteten Wurzel einen Owner- und Scope-Marker an. Spätere Start-, Stop-, Remove- und Uninstall-Aktionen müssen diesen Marker vor jeder Mutation prüfen.

## Docker-Scope

Container, Netzwerke und Docker-Volumes werden über einen eindeutigen Compose-Projektnamen sowie Owner- und Scope-Labels isoliert.

SQL-Ports werden standardmäßig ausschließlich an die lokale Loopback-Schnittstelle gebunden. Bereits belegte oder mehrfach verwendete Ports werden abgelehnt.

Das projektgebundene Compose-Netzwerk verwendet einen normalen Bridge-Treiber. Die Erreichbarkeit bleibt durch die Hostbindung an die Loopback-Adresse lokal begrenzt.

Der Healthcheck verwendet eine explizite TCP-Verbindung zur internen Loopback-Adresse auf Port 1433 sowie definierte Login- und Abfragetimeouts. Nach dem Start werden sowohl die tatsächlich erzeugte Docker-Portbindung als auch die TCP-Erreichbarkeit vom Host geprüft. Ein Container gilt erst danach als für lokale Clients erreichbar.

Globale Bereinigungsbefehle sind ausgeschlossen. Insbesondere dürfen weder globale Docker-Prune-Operationen noch Wildcard-Löschungen oder die Entfernung fremder Container, Netzwerke, Volumes oder Images verwendet werden.

## Entfernen der Umgebung

`Remove` und `Uninstall.ps1` verwenden dieselbe sichere Logik:

1. Entfernen der eindeutig zugeordneten Container und des Projektnetzwerks nach Bestätigung;
2. optionales Entfernen aller Owner- und Scope-geprüften Docker-Volumes des Projekts, der markierten Datenpfade und der lokalen `.env` nach einer zweiten Bestätigung.

Die Volume-Ermittlung ist nicht auf die aktuell deklarierte Compose-Datei beschränkt. Dadurch können auch Volumes eines älteren QuickStart-Speichermodells sicher entfernt werden.

Vor dem Löschen eines Pfads muss geprüft werden, dass nur die erwarteten QuickStart-Einträge vorhanden sind. Unerwartete Inhalte verhindern die Löschung.

Docker-Images und andere Projekte bleiben außerhalb des Löschumfangs.

## Ressourcenprofile

Ressourcenprofile begrenzen CPU und Arbeitsspeicher je SQL-Server-Instanz. Bei mehreren gewählten Versionen muss das Setup die aufsummierte Hostbelastung berücksichtigen und bei einer unangemessenen Reservierung warnen oder eine zusätzliche Bestätigung verlangen.

Container werden sequenziell gestartet und jeweils bis zum erfolgreichen Healthcheck geprüft, bevor die nächste Instanz oder die Frameworkinstallation beginnt.

## Slow-I/O

Eine belastbare Block-I/O-Drosselung wird für Docker Desktop auf Windows nicht behauptet.

Slow-I/O ist nur zulässig, wenn der QuickStart direkt auf einer Linux-Docker-Engine ausgeführt wird und ein ausschließlich dem Lab zugeordnetes Blockgerät mit eigenem Mountpoint verwendet wird. Eine Linux-VM unter Hyper-V ist dafür eine unterstützte Bereitstellungsvariante.

Das Setup muss die Geräte- und Mountpoint-Zuordnung prüfen und eine ausdrückliche Bestätigung verlangen, bevor die Drosselung aktiviert wird.

## Unterstützte Laufzeitvarianten

Der gleiche Setup-Einstieg unterstützt:

- Docker Desktop mit Linux-Containern auf Windows;
- Docker Engine auf Linux;
- Docker Engine in einer Linux-VM unter Hyper-V.

Die Provisionierung einer Hyper-V-VM, Hostnetzwerkänderungen und Hostadministration bleiben bewusst außerhalb des QuickStart-Scope.

## Frameworkinstallation

Nach erfolgreichem Containerstart erzeugt der QuickStart den Standalone-Installer aus den kanonischen SQL-Dateien. Pro Instanz wird anschließend:

1. `LabAnalyze` mit der vorgesehenen Collation erstellt, sofern die Datenbank fehlt;
2. das Framework installiert oder aktualisiert;
3. das Schema `monitor` als `FRAMEWORK_READY` verifiziert.

Das SA-Passwort darf dabei nicht in Kommandozeilenargumente oder veröffentlichte Artefakte geschrieben werden.
