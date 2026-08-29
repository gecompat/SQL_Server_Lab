# External-Language-Containerkontexte

`Linux/Containerfile` ist der gemeinsame, providerneutrale Buildkontext für
Docker und Podman. Er akzeptiert ausschließlich einen per Digest gebundenen
SQL-Basisimage-Ref sowie ein versioniertes Microsoft-Extensibility-DEB mit
vorher geprüftem SHA-256. Manifestwerte werden niemals als Dockerfile- oder
Shelltext übernommen.

Der Launcher startet SQL Server und `launchpadd` als gemeinsam überwachte
Prozesse. Beendet sich einer der beiden Prozesse, wird der andere kontrolliert
terminiert; ein scheinbar laufender Container ohne Launchpad gilt damit nicht
als bereit.

`Linux/recipe.json` ist die kanonische Buildbeschreibung. Der Image-Key bindet
den MCR-Basisdigest, die SQL-Extensibility-Version, alle Runtimeartefakte und
die SHA-256-Werte der tatsächlich verwendeten Kontextdateien. Docker und
Podman verwenden denselben Key, führen Build und Native Acceptance aber
getrennt aus. Lokale Receipts werden providerbezogen im State Root gehalten;
das normale Run-Cleanup entfernt wiederverwendbare Images nicht.

Das Rezept besitzt feste Zielstages für Python, R und Java sowie jede
kanonische Kombination dieser drei Runtimes. Der R-Build verwendet ein per
linux/amd64-Manifestdigest gebundenes
Rocker-R-4.2.3-Image nur als Buildstage. Sechs exakt versionierte und
SHA-256-gebundene Archive installieren die SQL-Komponenten RevoScaleR und
CompatibilityAPI einschließlich ihrer R-Abhängigkeiten. In das SQL-Zielimage
gelangen nur die installierte R-Laufzeit, Pakete und die erforderlichen
ABI-Laufzeitbibliotheken; Compiler und Buildwerkzeuge bleiben im Buildstage.
Der Java-Build verwendet Microsoft OpenJDK 11.0.32 nur im Buildstage. Er baut
das Microsoft-SDK aus den drei SHA-256-gebundenen Quellen des Tags
`Java-v1.1.1`, erzeugt das versionierte SQL_Server_Lab-Probe-JAR und reduziert
die Laufzeit mit `jlink`. Das Ziel enthält weder `javac` noch `jmods`; Extension,
SDK, Probe und Lizenzen bleiben mit festen Hashes prüfbar. Die Python-, R- und
Java-Lockdateien sind getrennt und müssen jeweils exakt mit den Artefakten in
`Linux/recipe.json` übereinstimmen.

Java wird nach dem Datenbank-Create beziehungsweise Restore pro Zieldatenbank
registriert. Vorhandene Sprache und Libraries werden gegen Dateiname,
Umgebung, Plattform und Content-SHA-256 geprüft; Drift wird abgelehnt. Scheitert
der JAR-Datenroundtrip, werden ausschließlich die im aktuellen Versuch neu
angelegten Objekte wieder entfernt.

SQL Server 2019, 2022 und 2025 `launchpadd` benötigen im sicheren Namespace-Modus eine
cgroup-v1-Hierarchie und beim Containerstart `SYS_ADMIN`. Der Provider fügt
diese Capability ausschließlich für ein intern verifiziertes Image-Artefakt
mit einem versionsgebundenen Launchmodus (`sql2019-namespace-v1`,
`sql2022-namespace-v1` oder `sql2025-namespace-v1`) hinzu. Auf cgroup-v2-Hosts wird der Lauf
vor State und Mutation mit `DECLARED_UNSUPPORTED` abgelehnt. Der technisch
mögliche Modus ohne Namespace-Isolation und mit freiem Outbound-Zugriff ist
kein implementierter Fallback.

SQL Server 2019 verwendet die eigene Ubuntu-20.04-/OpenSSL-1.1-
Extensibility-Schicht und bietet derzeit nur Java. SQL Server 2022 und 2025
verwenden ihre jeweils versionsgebundenen Ubuntu-/Extensibility-Schichten und
bieten Python, R und Java. Docker und Podman lösen dieselben Varianten auf.

Der Kontext allein ist kein Supportnachweis. Erst ein katalogisierter
Buildplan, ein persistierter Image-Digest und die native Ausführung über
`sp_execute_external_script` dürfen eine Variante auf `SUPPORTED` heben.

`Windows/recipe.json` und `Windows/Install-ExternalRuntimes.ps1` bilden den
Hyper-V-Gastpfad. Der Host löst Python- und R-Artefakte ausschließlich über
Katalog-URL und SHA-256 in den Media-Root auf; der Gast erhält nur einen
deterministischen Plan und lokale Dateien. Der Installer verwendet keine
Paketquelle und kein Netzwerk, registriert die SQL-Runtimes, setzt die
Launchpad-Zugriffsrechte und gibt ein sanitisiertes Receipt zurück. Der
zugehörige Hyper-V-Acceptance-Runner prüft die External-Script-Roundtrips nach
Installation, Dienstneustart und Cold Start. Java verwendet das letzte
verfügbare Windows-Extension-Artefakt 1.1.0, das dazu passende Microsoft
OpenJDK 17.0.20.1, das im Extension-Archiv enthaltene hashgebundene SDK und
ein reproduzierbar erzeugtes Probe-JAR. Bis der native Lauf für alle drei Sprachen positiv belegt ist,
bleiben die Windows-Varianten `PREVIEW`.
