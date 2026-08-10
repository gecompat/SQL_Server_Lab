# Interaktiver Workflow

`Neue Umgebung erstellen` fragt zuerst den fachlichen Sollzustand ab. Der Provider
wird erst danach gewählt. Docker hat Vorrang vor Podman; Hyper-V wird verwendet,
wenn Windows, eine nicht containerfähige Edition, ein Pool-Slot, Isolation oder
VHDX-bezogene I/O-Limits erforderlich sind.

## SQL-Versionen und CUs

Die angebotenen Versionen und Patchstände stammen ausschließlich aus
`Catalogs/sql-server-versions.json`. Der monatliche Katalog-Agent aktualisiert
Build, CU, KB, Veröffentlichungsdatum, Container-Tag und Windows-Paketmetadaten.
Im Dialog ist keine maximale CU-Nummer fest verdrahtet.

Für Hyper-V wird der lokale Media Root mit `builds[].windows.relativePath`
abgeglichen. Fehlende Pakete werden mit Zielpfad und Microsoft-Artikel angezeigt.
Ein automatischer Download ist nur erlaubt, wenn der Agent sowohl eine direkte
HTTPS-URL als auch den erwarteten SHA-256 eingetragen hat. Ohne Hash bleibt die
Beschaffung bewusst manuell.

Empfohlenes Layout:

```text
<MediaRoot>/SQL/<Version>/Updates/<CU>/SQLServer<Version>-<KB>-x64.exe
```

## Ressourcen

Der Dialog erfasst CPU, RAM, Collation, SQL-Speicher, MAXDOP, Cost Threshold,
TempDB und optional getrennte Data-, Log-, TempDB- und Backup-Datenträger.
RAM oberhalb des physischen Host-RAM ist als Overcommit-Test zulässig, kann aber
zu Swap, OOM oder einem abgelehnten VM-Start führen.
