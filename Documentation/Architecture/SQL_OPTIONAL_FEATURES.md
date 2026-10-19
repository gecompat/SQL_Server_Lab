# Optionale SQL-Funktionen: Volltext und FILESTREAM

## Auswahl und Plattformen

`instances[].sqlFeatures` enthält ausschließlich explizite boolesche Werte:

```json
"sqlFeatures": { "fullText": true, "fileStream": false }
```

Fehlende Felder bewahren das bisherige Verhalten. Docker und Podman verwenden
Linux; dort ist Volltext optional und FILESTREAM-Aktivierung wird vor Mutation
mit `SQL_FEATURE_FILESTREAM_WINDOWS_REQUIRED` abgewiesen. Hyper-V verwendet
Windows; dort sind Volltext und FILESTREAM-T-SQL-Zugriff auswählbar. Win32- und
Remote-Streaming sowie FileTable werden durch diese FILESTREAM-Auswahl nicht
freigegeben.

Die öffentliche Änderung eines bestehenden, laufenden Runs erfolgt mit
`Set-SqlServerLabFeature -RunId $run.RunId -InstanceId primary -Feature FullText
-Enabled $true`. `$false` entfernt Volltext beziehungsweise deaktiviert
FILESTREAM. `-WhatIf` liest den aktuellen Zustand, schreibt aber kein Journal.
AdHoc-Container akzeptieren zusätzlich `New-SqlServerLab -FullText $true` und
`-FileStream $false`. Manifeste gelten auch für Hyper-V. Die Konsolen-CLI stellt
die öffentliche Funktion im vollständigen Befehlszugang bereit. Die Browser-GUI
bietet **SQL-Funktionen** je laufender Instanz und die Auswahl bei Neuanlage.
Bei reinen Windows-Vorlagen sind die SQL-Funktionsfelder deaktiviert;
veraltete Auswahlen gelangen nicht in deren Bereitstellungsauftrag.

## Containerpfad

Der von SQL gelesene `ProductVersion` bindet das FTS-Paket an denselben Build.
Die Verwaltung ist für SQL Server 2019, 2022 und 2025 implementiert; native
Nachweise werden je tatsächlich geprüftem Stand separat geführt. Das Hinzufügen
unter Docker/Podman benötigt Zugriff auf das Microsoft-Paketrepository.
Die unterstützten Ubuntu-/SQL-Kombinationen sind im festen Installationsskript
aufgezählt. Repository- und Paketdownloads dürfen höchstens zweimal wiederholt
werden; Mutationen werden nicht automatisch wiederholt. Eine fehlende passende Paketversion oder ein fehlender Microsoft-
Repositoryschlüssel beendet die Operation. Das Skript verwendet einen eigenen
temporären Apt-Index und das signierte Microsoft-Produktrepository; es installiert
oder aktualisiert weder Engine noch Betriebssystempakete.

Aktuelle Standardimages enthalten keine `mssql-server`-Paketregistrierung.
Deshalb wird ausschließlich `opt/mssql/lib/sqlservr.fts.sfp` aus dem durch Apt
hashgeprüften, versionsgleichen `mssql-server-fts`-Paket extrahiert. Maintainer-
Skripte und die gesonderte semantische Suchdatenbank werden nicht installiert.
Ein privates Root-Receipt bindet Paketversion und Capsule-SHA-256. Entfernen
löscht nur diese unveränderte eigene Capsule. Fremde oder manipulierte
Installationen werden nicht übernommen. Der Engine-Capsule-Hash sowie der nach
SQL-Neustart gelesene Build müssen unverändert bleiben.

Stop/Start erhält die Capsule im Container. Ein laufender Container-Recreate
und External-Runtime-Refresh stellen den expliziten Featureintent vor der
Abnahme erneut her. Ein Recreate einer gestoppten Instanz mit aktivem Volltext
verlangt zunächst deren Start; eine ungeprüfte Featureentfernung ist gesperrt.

## Windowspfad

FULLTEXT-Änderungen verwenden ausschließlich ein lokal per SHA-256 verifiziertes
SQL-Medium und `/FEATURES=FULLTEXT` mit der gebundenen Standardinstanz. Die
Engine wird weder neu installiert noch aktualisiert. Ein eigens hinzugefügtes
DVD-Laufwerk wird nur nach bestätigtem Setup-Ende entfernt. Ein unklarer
Setupausgang erhält die Medienbindung zur Recovery. FILESTREAM verwendet die
instanzgebundene SQL-WMI-Konfiguration, SQL-Neustart und `filestream access
level=1` beziehungsweise `0`. Tatsächlicher effektiver Level und Build werden
anschließend gelesen. Verbleibende zuvor laufende abhängige Dienste werden wieder
gestartet; der mit FULLTEXT entfernte Launcher gehört nicht dazu.

Die WMI-Auswertung unterscheidet den erfolgreichen Service-Neustart-Status
`3011`/`0x80070BC3` von einem OS-Reboot. Nur der Service-Neustart wird im
bestehenden SQL-Neustartpfad abgeschlossen; andere oder unbekannte Rückgaben
bleiben Fehler mit Recoverybedarf. Die Unterscheidung folgt den
[Microsoft-Systemfehlercodes](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1700-3999-).

Der unveränderte Engine-Build belegt keinen identischen Patchstand sämtlicher
Windows-Komponenten. Beim Hinzufügen kann FULLTEXT den Stand des Mediums erhalten;
die Funktion installiert keine zusätzlichen CUs. Für bereits gepatchte Instanzen
müssen neue Komponenten auf denselben Update-Stand gebracht werden, wie von
[Microsoft für Featureergänzungen beschrieben](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/add-features-to-an-instance-of-sql-server-setup?view=sql-server-ver17).
Der native Windows-Referenztest verwendet SQL 2025 RTM; CU-Konstellationen sind
damit nicht qualifiziert.

## Daten, Ownership und Recovery

Vor einer Mutation werden Run-/Scope-/Instanzbindung und echte Container-ID
beziehungsweise VM-ID geprüft. Geschützte System-/Testgruppen bleiben gesperrt.
Eine Änderung benötigt eine eigene Run-Sperre. Vor Entfernung müssen sämtliche
Datenbanken mit Sysadminrechten sichtbar, online und zugänglich sein.
Volltextkataloge sowie FILESTREAM-Dateien oder -Spalten blockieren das Entfernen;
die API löscht keine abhängigen Daten. Benutzer räumen solche Objekte bewusst
selbst auf.

Das lokale Journal wird vor der Mutation geschrieben. Fehler ergeben
`RECOVERY_REQUIRED`; Setup wird nicht blind wiederholt. `-Resume` darf nur einen
bereits tatsächlich erreichten Zielzustand bestätigen und den State nachtragen.
Für einen noch nicht erreichten Zustand bleibt eine gezielte Diagnose nötig.
Der verifizierte Intent wird im lokalen Run-State und, falls vorhanden, im
Desired-State-Snapshot gespeichert. Das ursprüngliche Quelldokument wird durch
eine spätere Änderung am Run nicht überschrieben.

## Nachweise und Herstellerquellen

`Tests/Static/Invoke-SqlFeatureChecks.ps1` prüft Intent, Plattformablehnung und
statische Sicherheitsverträge. `Tests/Integration/Invoke-SqlFeatureAcceptance.ps1`
führt je Provider einen eigenen öffentlichen Create-/Remove-Lauf aus. Er
erstellt einen Volltextkatalog und -index, prüft `CONTAINS`, `FREETEXT`,
`CONTAINSTABLE`, Negativsuche, Neustart sowie Remove/Add. Hyper-V prüft zusätzlich
tatsächlich gespeicherte und aktualisierte FILESTREAM-BLOBs. Testimplementierung
und ausgeführte Abnahme werden getrennt ausgewiesen; aktuelle Ergebnisse stehen
in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).

- [Microsoft: Volltext unter Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-full-text-search?view=sql-server-ver17)
- [Microsoft: SQL-2025-Linux-Funktionsgrenzen](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-editions-and-components-2025?view=sql-server-ver17)
- [Microsoft: FILESTREAM konfigurieren](https://learn.microsoft.com/en-us/sql/relational-databases/blob/enable-and-configure-filestream?view=sql-server-ver17)
