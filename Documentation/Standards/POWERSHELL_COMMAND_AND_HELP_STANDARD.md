# PowerShell Command and Help Standard

## Zweck

Diese Norm definiert Benennung, Auffindbarkeit und Hilfe der oeffentlichen
PowerShell-API von SQL_Server_Lab.

## Verbindliche Regeln

Jede oeffentlich exportierte Funktion muss:

1. das Muster `Verb-SingularNoun` verwenden;
2. ein von `Get-Verb` geliefertes Verb verwenden;
3. ein spezifisches, PascalCase geschriebenes Nomen besitzen;
4. ueber `SqlServerLab.psd1` explizit exportiert werden;
5. vollstaendige Comment-based Help mit `SYNOPSIS`, `DESCRIPTION`, allen
   Parametern, mindestens einem `EXAMPLE` und `OUTPUTS` bereitstellen;
6. nach Modulimport ueber `Get-Help <Name> -Full` auffindbar sein;
7. im konzeptionellen Thema `Get-Help about_SqlServerLab` aufgefuehrt sein;
8. durch `Tests/Static/Invoke-DocumentationChecks.ps1` geprueft werden.

Parameterdefaults werden in der Parameterbeschreibung genannt, wenn sie fuer
das Benutzerverhalten relevant sind. Help darf keine Schema- oder
Runtimeunterstuetzung behaupten, die nicht durch Code und Tests belegt ist.

## Auffindbarkeit

PowerShell ordnet Commands nicht allein anhand ihres Namens einem Projekt zu.
Die autoritative Zuordnung liefern `ModuleName` und `Source`:

```powershell
Get-Command -Module SqlServerLab | Sort-Object Name
Get-Command New-SqlServerLabDatabase | Select-Object Name, ModuleName, Source
```

Bei Namenskonflikten ist ein modulqualifizierter Aufruf eindeutig:

```powershell
SqlServerLab\New-SqlServerLabDatabase -Port 14330 -SaPassword $pw -DatabaseName AppDB
```

Die zentrale Benutzerhilfe ist:

```powershell
Get-Help about_SqlServerLab
Get-Help New-SqlServerLab -Full
Get-Help Test-SqlServerLabManifest -Parameter Path
```

Es wird kein projektspezifischer Ersatz fuer das eingebaute `Get-Help` oder
`Get-Command` eingefuehrt.

## Namensentscheidung

Alle oeffentlichen Nomen beginnen mit `SqlServerLab`. Das gilt fuer Umgebung
und Lifecycle ebenso wie fuer Manifeste, Datenbanken, Skripte und
Ressourcenpruefungen. Dadurch bleiben die Commands auch bei gemeinsam
installierten Labmodulen fachlich zuordenbar und kollisionsarm.

`DefaultCommandPrefix` wird nicht verwendet. Ein globaler Prefix wuerde bereits
spezifische Namen wie `New-SqlServerLab` unlesbar doppeln. Benutzer koennen bei
lokalem Bedarf `Import-Module -Prefix` oder modulqualifizierte Namen verwenden.

## Migration bestehender Namen

Die generischen `Lab*`-Namen wurden vor Version 1.0 unmittelbar ersetzt. Es
gibt keine Kompatibilitaetsaliasse und keinen Deprecation-Zeitraum. Die drei
bekannten konsumierenden Repositories `SQL_Server_Analyze`,
`SQL_PerformanceSchulung` und `SQL_Server_Toolbelt` werden bei Bedarf im selben
Aenderungszug angepasst.

| Bisheriger Name | Kanonischer Name |
|---|---|
| `New-LabManifest` | `New-SqlServerLabManifest` |
| `Test-LabManifest` | `Test-SqlServerLabManifest` |
| `New-LabDatabase` | `New-SqlServerLabDatabase` |
| `Restore-LabDatabase` | `Restore-SqlServerLabDatabase` |
| `Invoke-LabScript` | `Invoke-SqlServerLabScript` |
| `Test-LabResources` | `Test-SqlServerLabPrerequisite` |

Interne zusammengesetzte Helfernamen wie `Test-LabManifestSchema` sind keine
oeffentliche API und bleiben von dieser Umbenennung unberuehrt.

## Modulhilfe

`about_SqlServerLab` listet alle oeffentlichen Commands mit Kurzbeschreibung
und typischen Arbeitsablaeufen. Lokalisierte Themen liegen unter
`de-DE/about_SqlServerLab.help.txt` und
`en-US/about_SqlServerLab.help.txt`.

Die Exportliste in `SqlServerLab.psd1` bleibt autoritativ. Eine neue Funktion
ist erst fertig, wenn Exportliste, Command-Hilfe, About-Thema, Dokumentation und
statische Pruefung gemeinsam aktualisiert wurden.
