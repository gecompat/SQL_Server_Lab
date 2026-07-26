# Installation

Für eine vollständige Schritt-für-Schritt-Installation in SSMS siehe
[`Documentation/Reference/Installation.md`](../../Documentation/Reference/Installation.md).

`Install_All.sql` ist ein schlanker SQLCMD-Installer und bindet die kanonischen Einzeldateien über `:r` ein.
Der vollständige SSMS-Ablauf einschließlich Arbeitskopie, Platzhalterersetzung,
Modusprüfung und Fehlerbehandlung ist in Abschnitt 12 der Installationsanleitung
beschrieben. `:ON ERROR EXIT` beendet den Include-Lauf beim ersten SQL-Fehler.

Ein eigenständiger, vollständig eingebetteter Installer wird mit folgendem Aufruf erzeugt:

```powershell
./Build-StandaloneInstaller.ps1
```

Die Quellen werden in exakt derselben, abhängigkeitssicheren Reihenfolge wie in
`Install_All.sql` eingebettet. Die erzeugte Datei `generated/Install_All.generated.sql` ist
ein Build-Artefakt und wird nicht versioniert. Für die SSMS-Erstinstallation ist
dies der empfohlene Weg: Der Datenbankplatzhalter muss nur einmal ersetzt werden,
und die generierte Datei benötigt keinen SQLCMD-Modus.

## Eigenständige Execution-Plan-Analyse

`Install_ExecutionPlanAnalysis.sql` installiert nur die für die direkte Plan- und Evidenzanalyse erforderlichen Objekte. Mit `Build-ExecutionPlanAnalysisInstaller.ps1` kann daraus das vollständig eingebettete SSMS-Artefakt `generated/Install_ExecutionPlanAnalysis.generated.sql` erzeugt werden. Der Teilinstaller installiert nicht die übrigen Analysebereiche und kann idempotent neben einer vollständigen Frameworkinstallation ausgeführt werden.

## Optionales Snapshot-/Baseline-Paket

SC-023 bleibt absichtlich außerhalb von `Install_All.sql`. Zuerst wird
`Install_SnapshotBaseline_Target.sql` im explizit gewählten Kontext einer
eigenen, beschreibbaren Nicht-Systemdatenbank ausgeführt. Danach installiert
`Install_SnapshotBaseline_Framework.sql` die Konfiguration und die drei Public
APIs in der Frameworkdatenbank. Das Paket erstellt keine Datenbank, Rechte oder
SQL-Agent-Objekte. Der vollständige Ablauf steht im
[Betriebsleitfaden](../../Documentation/Operations/Snapshot_Baseline_Operations.md).

Für eine Installation ohne SQLCMD-Modus erzeugt
`Build-SnapshotBaselineInstallers.ps1` zwei getrennte Artefakte:

- `generated/Install_SnapshotBaseline_Target.generated.sql` für die bereits
  ausdrücklich ausgewählte Snapshotdatenbank;
- `generated/Install_SnapshotBaseline_Framework.generated.sql` für die
  Frameworkdatenbank nach Anpassung von `[DeineDatenbank]`.

Die Trennung der Datenbankkontexte bleibt auch im Standalone-Weg erhalten.
