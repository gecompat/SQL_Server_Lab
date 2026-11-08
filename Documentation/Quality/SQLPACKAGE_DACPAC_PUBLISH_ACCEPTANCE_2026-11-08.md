# SqlPackage DACPAC Publish: erste native Schema-Deployment-Lane

## Umfang und Quellbindung

Am 2026-11-08 wurde der vorhandene SqlPackage-Container-Akzeptanzlauf um
synthetisches DACPAC-Extract und Publish erweitert. Beide Provider liefen
getrennt mit einem eigenen SQL-Server-2022-Linux-Run und dem katalogisierten
SqlPackage `170.5.96.0`.

| Provider | Assertions | DACPAC Extract/Publish | Wiederholtes Publish | Eigener Run-/Image-Cleanup |
|---|---:|---|---|---|
| Docker | 36 | `PASS` | `PASS`, Zielzeile erhalten | `PASS` |
| Podman | 36 | `PASS` | `PASS`, Zielzeile erhalten | `PASS` |

Der native Lauf basiert auf `08fa2547c2d56e7eff6752fcbe5f74bccc7d644b` und
`Tests/Integration/Invoke-ContainerToolAcceptance.ps1` mit SHA-256
`60BF524E8961FB37139B3B10CE88E9B17CE6925AA8BF583E23CA584C9B42F25A` zum
Ausführungszeitpunkt. Die Datei im Pull-Request hat SHA-256
`AFC3331E8547490502A07C1474CD37C0FFE036B36EDD4ACAB0E0D2DA362B382B`; das
nachträgliche Delta betrifft nur Synopsis-/Beschreibungstext und die
Formatierung desselben DACPAC-Receipt-Objekts. Es ändert weder Befehle, SQL,
Assertions noch Cleanup. Die Quellbindung trennt damit die tatsächlich
ausgeführten Bytes vom später redaktionell angepassten Testskript.
Die vollständigen lokalen Logs und maschinenlesbaren Receipts bleiben außerhalb
des Repositories. Das Receipt enthält nur synthetische, bereinigte
Testresultate.

## Geprüfte Assertions

Der Lauf legt Quell- und Zieldatenbank ausschließlich in seinem eigenen
Container-Run an. Das katalogisierte SqlPackage extrahiert das synthetische
Schema in eine temporäre DACPAC-Datei im Run-Container. Die Datei wird in eine
zuvor explizit angelegte Testdatenbank publiziert. Danach prüft der Lauf das
Tabellenschema, fügt eine synthetische Zeile hinzu, publiziert dasselbe DACPAC
erneut und liest die Zeile wieder aus.

Für beide Publish-Aufrufe gelten explizit
`BlockOnPossibleDataLoss=True` und `DropObjectsNotInSource=False`. Das
temporäre DACPAC wird nach Erfolg entfernt; bei einem Fehler entfernt der
bestehende Acceptance-Cleanup es nur aus dem eigenen Run-Container. Der
registrierte Cleanup entfernte je Provider den Test-Run, sein Volume und das
ausschließlich von diesem Lauf erzeugte Derived-Image-Tag. Vorhandene Images
blieben erhalten.

## Grenzen und nächste Ausbaupunkte

Dieser Nachweis belegt eine einzelne synthetische Schema-Publikation und deren
Wiederholung auf SQL Server 2022 unter Docker und Podman. Er implementiert noch
keinen öffentlichen Deployment-Handler, keine Adapter-/Package-Integration,
keine Versionsfolge, keine Drift-Erkennung, keine Datenmigration und keine
kontrollierten fehlgeschlagenen Releases. SQL Server 2019/2025 und Hyper-V sind
nicht Teil dieses Nachweises. Diese Punkte bleiben getrennte Schritte im
[Schema-Deployment- und CI-Lab-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md).
