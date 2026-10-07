# Abschluss einer lokalen Release-Veröffentlichung

`Tools/Prepare-LocalRelease.ps1` exportiert einen festen sauberen Git-Commit.
Paketverzeichnis, optionale ZIP-Datei und optionaler Archivhash behalten ihre
bisherigen Namen. Die Veröffentlichung mehrerer Dateien ist keine atomare
Dateisystemtransaktion. Ein harter Prozessabbruch kann deshalb Staging und
bereits verschobene Teilartefakte hinterlassen.

## Intent und Abschlussquittung

Vor der Paketvorbereitung entsteht neben den Zielartefakten
`<ReleaseId>.publication.json` mit `SqlServerLab.ReleasePublication/1.0` und
`PENDING`. Der Datensatz bindet Release-ID, Quellcommit, relativen Stagingnamen
und die beiden gewählten Archiv-/Hashoptionen. Er enthält keine Hostpfade und
verleiht keine Lösch- oder Wiederaufnahmeautorität.

Erst nach Veröffentlichung und erneuter Inhaltsprüfung entsteht
`<ReleaseId>.completed.json` mit `COMPLETED`. Die Quittung bindet den SHA-256
des Intent, die vollständige relative Paketdateimenge einschließlich
Release-Metadaten und die exakt ausgewählten Archivdateien jeweils mit Größe
und SHA-256. Beide Datensätze werden im eigenen Staging geschrieben, geflusht
und ohne Überschreiben durch eine einzelne Dateiumbenennung veröffentlicht.
Der Paketinhalt und die ZIP-Datei werden dafür nicht nachträglich verändert.

Das strukturierte Erstellungsergebnis ergänzt `PublicationStatus` und
`PublicationReceipt`. Der bestehende Ausnahme-Cleanup entfernt weiterhin nur
die eigene Staging-/Publikationsmenge. Ein vollständiger Prozessabbruch führt
diesen Cleanup nicht aus. Auch nach Veröffentlichung der Abschlussquittung
kann ein Abbruch ein Stagingverzeichnis zurücklassen; die Quittung bestätigt
die Artefakte, nicht den Prozessabschluss oder das Cleanup.

## Rein lesende Prüfung

```powershell
.\Tools\Prepare-LocalRelease.ps1 -OutputRoot .artifacts/release `
    -InspectReleaseId <ReleaseId>
```

Der eigene Parametersatz liest genau diese Release-ID. Er benötigt weder
sauberen Git-Stand noch Readiness-Prüfung, importiert kein Produktmodul und
erstellt keine Dateien. `Mutation=false`, leere `Actions` und
`ProcessStatus=NOT_CHECKED` gelten in jedem Ergebnis.

| PublicationStatus | Bedeutung |
|---|---|
| `NOT_ATTESTED` | Es gibt kein Intent und keine Quittung. Vorhandene ältere Pakete werden nicht übernommen oder nachträglich quittiert. |
| `INCOMPLETE` | Ein gültiges Intent besitzt keine Abschlussquittung. Der Prozess kann noch laufen oder unterbrochen sein; vorhandene ZIP-/Hash-/Paketdateien allein ergeben keinen Abschluss. |
| `COMPLETED` | Intent und Quittung sind gültig gebunden und die aktuelle gesamte Paketdateimenge sowie alle gewählten Archivdateien stimmen in Größe und SHA-256 überein. |

`StagePresent` zeigt beim gebundenen Intent ausschließlich das Vorhandensein
des angegebenen Stagingpfades. Ein gültiger Abschluss kann noch
`StagePresent=true` haben. Diese Anzeige autorisiert keine Bereinigung.

Ungültige, zu große oder während der Prüfung geänderte Records sowie fehlende,
zusätzliche oder veränderte Paketdateien brechen mit einem Fehler ab. Relative
Dateipfade sind geschlossen, Datei-/Verzeichnislinks einschließlich leerer
umgeleiteter Verzeichnisse blockieren. Die Dateiinventur ist auf 10.000
Einträge und ein Record auf 4 MiB begrenzt; unbekannte Daten werden nicht
interpretiert oder repariert.

## Nachweisgrenzen und Recovery

Die Quittung ist eine lokale Inhaltsbindung, keine Signatur oder unabhängige
Attestierung des Herausgebers oder Git-Ursprungs. Die Prüfung attestiert den
gelesenen Stand, keine kontinuierliche Unveränderlichkeit. Stromausfall,
Datenträgerverlust und allgemeine Netzwerkdateisystem-Durabilität sind nicht
belegt. Eine Mehrdateitransaktion oder automatische Rücknahme bei Prozessabbruch
wird nicht behauptet.

Es gibt kein automatisches Resume, Replay, Adoption, Purge oder Cleanup eines
unterbrochenen Releases. Vor manueller Recovery müssen tatsächlicher
Prozessstatus, exakter eigener Scope und Evidence gesichert sein. Die
Inspektion verändert weder das unvollständige Release noch ältere Pakete.
Ein späterer Recovery-Executor benötigt einen eigenen Vertrag.

Die bestehende [Release-Artefakt-Suite](../../Tests/Static/Invoke-ReleaseArtifactChecks.ps1)
prüft Erstellung und Inhaltsdrift sowie harte Abbrüche eigener isolierter
PowerShell-Kindprozesse an Publikationsgrenzen. Das sind lokale
Dateisystem-/Prozessnachweise; SQL und Provider bleiben separat.
