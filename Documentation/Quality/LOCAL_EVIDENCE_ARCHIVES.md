# Lokale Evidenzarchive

Temporäre Testroots im System-Tempbereich sind keine Sicherungen. Der bestehende
`Tools/Invoke-SqlServerLabMaintenance.ps1` inventarisiert alte `sql-lab-*`-Objekte
und plant deren scopegebundene Bereinigung. Ohne `-Apply -Cleanup` bleibt er
lesend. Fremde Runtime-Ressourcen werden nur gemeldet und niemals allein wegen
Alter oder Namensähnlichkeit gelöscht. Ein Cleanup-Vorschlag ersetzt keine
Ownership- und Recovery-Prüfung.

Bewusst erhaltene lokale Evidenz liegt ignoriert unter
`.artifacts/orchestrator/preserved/<Archiv-ID>`. Sie gehört nicht zum
Produkt-Run-State und enthält potenziell private Diagnosen. Sie darf nicht
committet, in einen PR hochgeladen oder mit `Clear-SqlServerLab` verwechselt
werden. `Tools/Manage-LocalEvidenceArchive.ps1` verwaltet ausschließlich
diese lokalen Kopien im aktuellen Repository:

```powershell
./Tools/Manage-LocalEvidenceArchive.ps1 -Action List
./Tools/Manage-LocalEvidenceArchive.ps1 -Action Register -ArchiveId <id> -Purpose '<Zweck>' -RelatedPr 'https://github.com/gecompat/SQL_Server_Lab/pull/<nummer>' -SourceCommit <40-hex>
./Tools/Manage-LocalEvidenceArchive.ps1 -Action Verify -ArchiveId <id>
./Tools/Manage-LocalEvidenceArchive.ps1 -Action Restore -ArchiveId <id> -ExpectedManifestSha256 <64-hex>
./Tools/Manage-LocalEvidenceArchive.ps1 -Action ListRestores
./Tools/Manage-LocalEvidenceArchive.ps1 -Action RemoveRestore -RestoreId <id-aus-ListRestores> -ExpectedReceiptSha256 <64-hex>
./Tools/Manage-LocalEvidenceArchive.ps1 -Action Remove -ArchiveId <id> -ExpectedManifestSha256 <64-hex>
```

`Register` schreibt ein Manifest mit Zweck, Bezug, Dateilängen und SHA-256-
Hashes. `List` zeigt auch unregistrierte Verzeichnisse; sie sind keine expliziten
Sicherungen und können mit diesem Werkzeug weder wiederhergestellt noch
entfernt werden. `Verify` prüft alle Dateien und zusätzliche Dateien. Vor
`Restore` und `Remove` sind ein gültiges Archiv sowie der exakte aktuelle
Manifesthash erforderlich. `Restore` erzeugt nur eine geprüfte **Evidenzkopie**
unter `.artifacts/orchestrator/restored`; es startet keinen Container, lädt
keinen SQL-State und stellt keine Labumgebung wieder her. `ListRestores` zeigt
deren Receipt-Hashes; `RemoveRestore` entfernt genau eine receiptgebundene
Kopie. Die Löschaktionen verlangen eine Bestätigung und akzeptieren `-WhatIf`.

Der aktuelle Bestand alter, unregistrierter Kopien wird nicht nachträglich
pauschal als Sicherung anerkannt. Für jede Übernahme sind Herkunft, Zweck und
Integrität separat zu prüfen. Ein durch den Ausführungshost blockierter
Löschvorgang bleibt blockiert; der Maintenance- oder Archivbefehl ist keine
Umgehung dieser Grenze.
