# Bekannte Grenzen

| Merkmal | Wert |
|---|---|
| Status | `BINDING_LIMITATIONS` |
| Stand | 2026-07-27 |

Dieses Dokument beschreibt bekannte Grenzen des aktuell implementierten Runtimepfads. Es ist Teil des öffentlichen Projektvertrags. Ein Feld im JSON-Schema oder ein Planungsdokument gilt nicht automatisch als Implementierungsnachweis.

## Provider

### Docker und Podman

Docker und Podman sind implementiert. Start, Stop und Live-Status verwenden den Provider, der in `connection-info.json` für den Run gespeichert wurde.

### Gemischte Provider in einem Run

Ein Manifest kann strukturell mehrere Provider enthalten. Der gemeinsame Lifecycle für einen einzelnen Run mit gemischten Providern ist jedoch noch nicht implementiert. `Get-SqlServerLab`, `Start-SqlServerLab` und `Stop-SqlServerLab` melden diese Situation ausdrücklich.

### Hyper-V

Hyper-V ist geplant, aber nicht implementiert. Manifeste mit Windows-Betriebssystem oder GUI-Software können bei der Provider-Auflösung zu `hyperv` führen; die Provisionierung bricht anschließend mit einer klaren Meldung ab.

## Manifest und Schema

### Schema ist kein Runtime-Nachweis

`Schemas/lab-manifest.schema.json` enthält neben ausführbaren Feldern auch teilweise vorbereitete Erweiterungsfelder. Direkte `serverConfig`-Eigenschaften sind mit `x-runtimeStatus` als `executable`, `reserved` oder `partially-executable` klassifiziert. Für die tatsächliche Ausführung sind zusätzlich `Private/ManifestParser.ps1` und die zuständige Runtimefunktion maßgeblich.

### Ausgeführte `serverConfig`-Bereiche

Aktuell werden ausgeführt:

- `memory`
- `tempdb`
- `maxDop`
- `costThreshold`
- `traceFlags`
- `spConfigure`
- `externalScripts` einschließlich Resource-Governor-Teilkonfiguration

### Noch nicht zuverlässig angewendete `serverConfig`-Felder

Folgende Schemafelder sind noch kein stabiler Runtimevertrag:

- `collation` innerhalb von `serverConfig`
- `defaultPaths`
- `sqlAgent` als steuerbarer Schalter
- `clrEnabled`
- `filestream`
- `containedDatabases`
- `authMode`
- `errorLogRetention`
- `instantFileInit`
- `externalScripts.customImage`
- `externalScripts.installMethod = pre-built`

Ausführbare Beispiele verwenden diese Felder daher nicht.

## Collation

Die Instanzdefinition enthält eine Collation, die als Default für neu angelegte Datenbanken verwendet wird. Eine abweichende SQL-Server-Instanzcollation wird bei der Containererstellung derzeit nicht gesetzt.

## Datenbankdateien und Volumes

`New-SqlServerLabDatabase` berücksichtigt `path` für Data- und Log-Files. Der angegebene Containerpfad muss vorher über `drives` beziehungsweise einen Volume-Mount bereitgestellt worden sein.

Das Feld `sizeLimitGB` bei Drives ist derzeit Metadatum; Docker- oder Podman-Volumes werden dadurch nicht physisch auf diese Größe begrenzt.

## Restore

Unterstützt werden direkte `.bak`-Dateien aus lokalen Pfaden oder HTTP(S)-URLs.

Nicht automatisch unterstützt werden:

- `.7z`-, `.zip`- oder andere Archive
- Attach-Szenarien mit vorhandenen MDF/LDF-Dateien
- Differential- oder Log-Backup-Ketten
- verschlüsselte Backups mit externen Zertifikaten
- komplexe Mehrfach-Backup-Sets

Bei manuellen Restores ist `-RunId` mit optionaler `-InstanceId` die bevorzugte Identitaet. Provider, Container, Host und Port werden dabei aus der gespeicherten `connection-info.json` aufgeloest. Der direkte Modus mit `-Port` bleibt fuer externe Aufrufer erhalten; ohne `-ContainerName` verwendet er die portbasierte Containererkennung.

## Sample-Datenbanken

`sample`-Referenzen werden auf den Katalog `Catalogs/sample-databases.json` aufgelöst.

Automatisch ausführbar sind nur Varianten mit einer direkten `.bak`-URL,
`runtimeStatus: executable` und hinterlegtem SHA-256. Katalogeinträge ohne
verifizierte Prüfsumme sowie Eintraege fuer SQL-Skripte, Archive oder
Attach-Verfahren bleiben als `descriptive` sichtbar und werden mit einer
erklärenden Fehlermeldung abgewiesen.

Die im Katalog enthaltenen Prüfsummen können bei beschreibenden Varianten
`null` sein. Solche Varianten gelten nicht als produktiv ausführbar.

## SQL Server Builds und CUs

Der Versionskatalog enthält ausdrücklich versionierte Buildmetadaten. Diese Daten sind nicht automatisch aktuell. Ein vorhandener Katalogeintrag bedeutet nicht, dass er das neueste verfügbare CU darstellt.

Kurzbezeichner wie `2022-CU16` werden nur akzeptiert, wenn der Build im Katalog vorhanden ist. Unbekannte CU-Bezeichner werden nicht mehr durch eine vermutete Image-Tag-Konvention ersetzt.

## External Languages

Die Installation von R, Python oder Java ist von den Paketquellen und der Linux-Distribution im verwendeten SQL-Server-Image abhängig. Paketnamen oder Installationswege können sich ändern.

`customImage` wird derzeit nicht in die Provider-Imageauswahl übernommen. Java-JARs werden nicht automatisch registriert.

## Tests

Der Integration-Smoke-Test benötigt eine laufende lokale Runtime und `sqlcmd`.

`-Provider auto` wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Das Resource Assessment prüft zusätzlich alle erkannten Provider.

Die statische Konsistenzprüfung ersetzt keinen echten Docker- oder Podman-End-to-End-Test.

## Lokale State- und Secret-Daten

State, Secrets, Connection Information, konkrete Hostpfade und Cache-Dateien liegen außerhalb des Git-Checkouts. Sie dürfen nicht in Issues, Pull Requests oder versionierte Diagnoseartefakte kopiert werden.

## Priorisierte nächste technische Schritte

1. Providerübergreifenden Lifecycle für gemischte Runs definieren.
2. Hyper-V-Provider erst nach einem eigenständigen Implementierungs- und Testvertrag ergänzen.
3. Katalogaktualität und Prüfsummen kontrolliert pflegen.
