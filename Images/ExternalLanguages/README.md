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

SQL Server 2022 `launchpadd` benötigt im sicheren Namespace-Modus eine
cgroup-v1-Hierarchie und beim Containerstart `SYS_ADMIN`. Der Provider fügt
diese Capability ausschließlich für ein intern verifiziertes Image-Artefakt
mit Launchmodus `sql2022-namespace-v1` hinzu. Auf cgroup-v2-Hosts wird der Lauf
vor State und Mutation mit `DECLARED_UNSUPPORTED` abgelehnt. Der technisch
mögliche Modus ohne Namespace-Isolation und mit freiem Outbound-Zugriff ist
kein implementierter Fallback.

Der Kontext allein ist kein Supportnachweis. Erst ein katalogisierter
Buildplan, ein persistierter Image-Digest und die native Ausführung über
`sp_execute_external_script` dürfen eine Variante auf `SUPPORTED` heben.
