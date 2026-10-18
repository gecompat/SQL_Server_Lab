#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/SqlReadiness.ps1')
. (Join-Path $repo 'Private/SqlConnectionSettings.ps1')
. (Join-Path $repo 'Public/Invoke-SqlServerLab.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$cases=@(
    @{Name='neuer Standard aus echtem Erzeuger';Text=(New-SqlConnectionString -Port 14333);Encrypt=$true;Trust=$true},
    @{Name='strikte angegebene Optionen';Text='Server=localhost;Encrypt=True;TrustServerCertificate=False;';Encrypt=$true;Trust=$false},
    @{Name='gespeicherte explizite False-Werte';Text='Server=localhost;Encrypt=False;TrustServerCertificate=False;';Encrypt=$false;Trust=$false},
    @{Name='fehlendes Encrypt ohne erfundenen Default';Text='Server=localhost;TrustServerCertificate=True;';Encrypt=$null;Trust=$true},
    @{Name='fehlender Trust ohne erfundenen Default';Text='Server=localhost;Encrypt=True;';Encrypt=$true;Trust=$null},
    @{Name='keine angegebenen TLS-Werte';Text='Server=localhost;';Encrypt=$null;Trust=$null},
    @{Name='Gross-/Kleinschreibung und Leerzeichen';Text='Server=localhost; encrypt = true ; trustservercertificate = false ;';Encrypt=$true;Trust=$false},
    @{Name='Semikolons im doppelten Passwortquote';Text='Server=localhost;Password="x;Encrypt=False;TrustServerCertificate=False;y";Encrypt=True;TrustServerCertificate=True;';Encrypt=$true;Trust=$true},
    @{Name='Semikolons im einfachen Passwortquote';Text="Server=localhost;Password='x;Encrypt=False;TrustServerCertificate=False;y';Encrypt=True;TrustServerCertificate=True;";Encrypt=$true;Trust=$true},
    @{Name='verdoppelte Passwortquotes';Text='Server=localhost;Password="x"";TrustServerCertificate=False;y";Encrypt=True;TrustServerCertificate=True;';Encrypt=$true;Trust=$true},
    @{Name='native Last-wins-Semantik';Text='Server=localhost;Encrypt=False;Encrypt=True;TrustServerCertificate=True;TrustServerCertificate=False;';Encrypt=$true;Trust=$false}
)
foreach($case in $cases){
    $settings=Get-LabSqlConnectionSettings $case.Text
    Add-CheckResult ('TLS-Anzeige '+$case.Name) ($settings.Encrypt -ceq $case.Encrypt -and $settings.TrustServerCertificate -ceq $case.Trust -and
        $settings.Status -ceq 'CONFIGURED_CONNECTION_STRING' -and @($settings.PSObject.Properties).Count -eq 3)
    $formatted=Format-LabSqlConnectionSettings $case.Text
    Add-CheckResult 'TLS-Anzeige enthaelt keine Zugangsdaten oder Endpunkte' ($formatted -notmatch 'localhost|Password|User ID|Server=|x;' -and
        $formatted -cmatch '\AEncrypt=(?:True|False|nicht angegeben);TrustServerCertificate=(?:True|False|nicht angegeben)\z')
}
foreach($invalid in @('Server=localhost;Encrypt=perhaps;Password=TLS_PRIVATE_CANARY;',
    'Unknown=TLS_PRIVATE_CANARY;Encrypt=True;',('x'*65537),@{},17)){
    $all=@(Get-LabSqlConnectionSettings $invalid *>&1)
    Add-CheckResult 'TLS-Anzeige unlesbar ohne Rohdiagnose oder Teilwerte' ($all.Count -eq 1 -and $null -eq $all[0].Encrypt -and
        $null -eq $all[0].TrustServerCertificate -and $all[0].Status -ceq 'UNREADABLE' -and ($all|ConvertTo-Json -Compress) -notmatch 'TLS_PRIVATE_CANARY')
    Add-CheckResult 'TLS-Anzeige unlesbar sichtbar formatiert' ((Format-LabSqlConnectionSettings $invalid) -ceq 'Encrypt=nicht lesbar;TrustServerCertificate=nicht lesbar')
}
foreach($empty in @($null,'',' ')){
    $settings=Get-LabSqlConnectionSettings $empty
    Add-CheckResult 'TLS-Anzeige fehlende Werte bleiben fehlend' ($null -eq $settings.Encrypt -and $null -eq $settings.TrustServerCertificate -and $settings.Status -ceq 'NOT_SPECIFIED')
}
$script:foreignCalls=0
$foreign=[pscustomobject]@{};$foreign|Add-Member ScriptMethod ToString {$script:foreignCalls++;throw 'TLS_PRIVATE_CANARY'} -Force
$null=Get-LabSqlConnectionSettings $foreign
$decorated=('Server=localhost;Encrypt=True;TrustServerCertificate=True;'|Add-Member ScriptProperty Length {$script:foreignCalls++;throw 'TLS_PRIVATE_CANARY'} -Force -PassThru)
$settings=Get-LabSqlConnectionSettings $decorated
Add-CheckResult 'TLS-Anzeige keine fremden Casts oder ETS-Getter' ($script:foreignCalls -eq 0 -and $settings.Encrypt -eq $true -and $settings.TrustServerCertificate -eq $true)
& {
    # Der echte CLI-Renderer laeuft mit festen Workflowantworten. Kein State,
    # Provider, Secretprovider oder SQL wird dafuer verwendet.
    $script:rows=[Collections.Generic.List[object]]::new()
    function Get-SqlServerLab {param($RunId,[switch]$Detailed) return [pscustomobject]@{State='RUNNING';RuntimeState='RUNNING'}}
    function Get-LabRunConnectionStrings {param($RunId,$StateRoot)
        return @([pscustomobject]@{Provider='docker';InstanceId='primary';Value=(New-SqlConnectionString -Port 14333)},
            [pscustomobject]@{Provider='hyperv';InstanceId='named';Value='Server=localhost;Encrypt=True;TrustServerCertificate=False;'},
            [pscustomobject]@{Provider='podman';InstanceId='legacy';Value='Server=localhost;TrustServerCertificate=True;'})
    }
    function Get-SqlServerLabGeneratedSqlAccess {param($RunId,$StateRoot) return $null}
    function Get-LabAutomaticallyGeneratedRunSaPassword {param($RunId,$StateRoot) return $null}
    function Write-LabStatus {param($Label,$Value,$Color) $script:rows.Add([pscustomobject]@{Label=$Label;Value=$Value})}
    Show-LabEnvironmentStatusInteractive -RunId '11111111-1111-4111-8111-111111111111' -StateRoot (Join-Path ([IO.Path]::GetTempPath()) 'sql-lab-missing-tls-fixture')
    $tlsRows=@($script:rows|Where-Object {$_.Label -like 'Connection Settings*'})
    Add-CheckResult 'CLI zeigt Standard, strikte und fehlende Optionen instanzgebunden' ($tlsRows.Count -eq 3 -and
        $tlsRows[0].Label -ceq 'Connection Settings (docker/primary)' -and $tlsRows[0].Value -ceq 'Encrypt=True;TrustServerCertificate=True' -and
        $tlsRows[1].Label -ceq 'Connection Settings (hyperv/named)' -and $tlsRows[1].Value -ceq 'Encrypt=True;TrustServerCertificate=False' -and
        $tlsRows[2].Value -ceq 'Encrypt=nicht angegeben;TrustServerCertificate=True')
}
Write-Host "SQL Connection Settings: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){throw 'SQL_CONNECTION_SETTINGS_CHECKS_FAILED'}
