# Optionale Lizenzprofile für Windows und SQL Server

Lizenzprofile sind eine **zusätzliche** lokale Möglichkeit. Alle bisherigen
schlüssellosen Wege bleiben erhalten:

- Windows- und SQL-Server-Evaluation verwenden keinen eigenen Product Key;
- SQL Server Developer und Express verwenden keinen Product Key;
- ohne `-SqlLicenseProfileId` wird niemals ein gespeicherter Key verwendet.

## Profil sicher anlegen

Den Key nicht in eine Skriptdatei, Manifestdatei, Shell-History oder
Kommandozeile schreiben. Er wird interaktiv als `SecureString` gelesen und im
lokalen State Root mit Windows DPAPI geschützt. Das Profil liegt außerhalb des
Repositorys und ist an das aktuelle Windows-Benutzerkonto beziehungsweise den
Host gebunden.

```powershell
$key = Read-Host 'SQL Server Product Key' -AsSecureString
Set-SqlServerLabLicenseProfile `
    -Id sql2016-standard-01 `
    -Product SqlServer `
    -Version 2016 `
    -Edition Standard `
    -Channel Volume `
    -Key $key
```

Unterstützte SQL-Editionen sind `Enterprise`, `EnterpriseCore`, `Standard` und
`Web`. Windows-Profile können für `Home`, `Pro`, `ProForWorkstations`,
`Enterprise`, `Education` und `IoTEnterprise` inventarisiert werden. Ein Profil
belegt weder Aktivierbarkeit noch Nutzungsrechte; Version, Edition,
Aktivierungskanal und Lizenzbedingungen müssen zum vorhandenen Key passen.

## Prüfen und verwenden

```powershell
Get-SqlServerLabLicenseProfile
Test-SqlServerLabLicenseProfile -Id sql2016-standard-01

Invoke-SqlServerLabWorkflowAction `
    -Action NewSqlBuild `
    -MediaRoot 'D:\Lab_Base' `
    -OperatingSystemId windows-server-2022 `
    -WindowsEdition standard-evaluation `
    -InstallationType desktop-experience `
    -WindowsMediaPath 'WindowsServer/2022/Eval/ISO/WindowsServer2022.iso' `
    -SqlVersion 2016 `
    -SqlEdition Standard `
    -SqlMediaPath 'SQL/2016/Standard/ISO/SQLServer2016.iso' `
    -SqlLicenseProfileId sql2016-standard-01
```

Im interaktiven Hyper-V-Image-Dialog erscheint für Enterprise und Standard
immer zuerst **Developer Edition (ohne Key)**. Ein passendes lokales Profil ist
nur eine weitere Auswahl. Evaluation bleibt automatisch schlüssellos.

Der SQL-Builder löst den Product Key erst unmittelbar vor `setup.exe` auf und
übergibt ihn als den von SQL Setup unterstützten `/PID`-Parameter. Build-State,
Receipts, Artifact-Metadaten und öffentliche Ausgaben enthalten nur die
Profil-ID und den Lizenztyp, niemals den Key oder Key-Fragmente. Das installierte
Prepared-Image ist wie jedes lizenzierte Installationsabbild entsprechend zu
schützen; das Framework behauptet keine Produktionsnutzungsrechte.

## Windows-Status

Windows-Profile werden bereits sicher und editionsgebunden inventarisiert.
Automatische Eingabe, Editionskonvertierung und Onlineaktivierung mit einem
Windows-Key sind noch nicht implementiert. Windows-Evaluation und die bestehende
digitale/OEM-Aktivierung eines Gasts bleiben davon unberührt. Insbesondere wird
ein Windows-10-Key nicht automatisch als Windows-11-Key angenommen.

## Profil entfernen

```powershell
Remove-SqlServerLabLicenseProfile -Id sql2016-standard-01
```

Das entfernt ausschließlich das exakt ausgewählte lokale Profil. Bereits damit
installierte Betriebssysteme oder SQL-Images werden dadurch nicht verändert.
