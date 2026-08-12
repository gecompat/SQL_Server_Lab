#Requires -Version 7.2
<#
.SYNOPSIS
    Provider- und Parallelitaets-Smoke-Test fuer die SQL-2025-Referenzversion.
.DESCRIPTION
    Ermittelt standardmaessig alle implementierten und lokal erreichbaren Provider,
    fuehrt fuer jeden Provider einen vollstaendigen Lifecycle-Test mit der
    Referenzversion aus und prueft optional mehrere parallele Labs derselben
    Referenzversion. Nicht erreichbare Provider werden als SKIPPED ausgewiesen;
    ein erreichbarer, aber fehlerhafter Provider ergibt FAILED.
.PARAMETER Provider
    all, docker oder podman. Default: all.
.PARAMETER ReferenceVersion
    Version fuer den vollstaendigen Lifecycle pro Provider. Default: 2025.
.PARAMETER IncludeParallel
    Fuehrt einen Parallelitaetstest mit bis zu vier gleichzeitig laufenden Labs
    derselben Referenzversion aus.
.PARAMETER KeepOnFailure
    Laesst fehlgeschlagene Labs zur Diagnose bestehen.
.EXAMPLE
    .\Invoke-SmokeMatrix.ps1
.EXAMPLE
    .\Invoke-SmokeMatrix.ps1 -Provider podman -IncludeParallel
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [ValidateSet('all', 'docker', 'podman')]
    [string]$Provider = 'all',
    [string]$ReferenceVersion = '2025',
    [switch]$IncludeParallel,
    [switch]$KeepOnFailure,
    [SecureString]$SaPassword
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}


$ErrorActionPreference = 'Stop'
$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SqlServerLab.psd1')).Path
$providersRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Providers')).Path
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:StartedAt = Get-Date
$requestedMode = $Provider

function Add-Result {
    param(
        [string]$Category,
        [string]$Provider,
        [string]$Version,
        [ValidateSet('PASS','FAIL','SKIP')][string]$Status,
        [string]$Message = ''
    )
    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Provider = $Provider
        Version  = $Version
        Status   = $Status
        Message  = $Message
    })
    $color = switch ($Status) { 'PASS' { 'Green' } 'SKIP' { 'Yellow' } default { 'Red' } }
    Write-Host ("    {0}: {1}/{2} {3}" -f $Status, $Provider, $Version, $Message) -ForegroundColor $color
}

function Test-RuntimeAvailable {
    param([string]$Name)

    if ($Name -eq 'hyperv') {
        try {
            $assessment = Test-SqlServerLabPrerequisite -Provider $Name
            $providerMessage = $assessment.Details | Where-Object { $_.Category -eq 'Provider' } | Select-Object -First 1
            return [PSCustomObject]@{
                Available = $assessment.Status -ne 'RESOURCE_HARD_BLOCK'
                Message   = if ($providerMessage) { $providerMessage.Message } else { 'Hyper-V-Lifecycle nicht erreichbar.' }
            }
        }
        catch {
            return [PSCustomObject]@{
                Available = $false
                Message   = $_.Exception.Message
            }
        }
    }

    try {
        $assessment = Test-SqlServerLabPrerequisite -Provider $Name
        if ($assessment.Details) {
            $providerMessage = $assessment.Details | Where-Object { $_.Category -eq 'Provider' } | Select-Object -First 1
            return [PSCustomObject]@{
                Available = $assessment.Status -ne 'RESOURCE_HARD_BLOCK'
                Message   = if ($providerMessage) { $providerMessage.Message } else { "$Name Runtime erreichbar." }
            }
        }
        return [PSCustomObject]@{
            Available = $false
            Message   = "$Name liefert keine Assessment-Daten."
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Message   = $_.Exception.Message
        }
    }
}

function ConvertFrom-TestSecureString {
    param([SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Wait-TestDatabaseReady {
    param(
        [string]$HostName,
        [int]$Port,
        [SecureString]$Password,
        [string]$Database,
        [int]$TimeoutSeconds = 60
    )

    $plain = ConvertFrom-TestSecureString $Password
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = ''
    try {
        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $result = & sqlcmd -S "${HostName},${Port}" -U sa -P $plain -C -b -l 2 -h -1 -W -d $Database -Q 'SET NOCOUNT ON; SELECT 1;' 2>&1
            $exitCode = $LASTEXITCODE
            $resultText = ($result | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' '

            if ($exitCode -eq 0 -and $resultText -match '(^|\s)1(\s|$)') {
                return
            }

            $lastError = if ($resultText) { $resultText } else { "sqlcmd Exitcode $exitCode" }
            Start-Sleep -Milliseconds 500
        }

        throw "Datenbank '$Database' wurde nach ${TimeoutSeconds}s nicht bereit. Letzter Fehler: $lastError"
    }
    finally {
        $plain = $null
    }
}

function Remove-TestLabSafely {
    param($Lab)
    if (-not $Lab -or -not $Lab.RunId) { return }
    try { Remove-SqlServerLab -RunId $Lab.RunId -Force -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Cleanup fuer Run $($Lab.RunId) fehlgeschlagen: $($_.Exception.Message)" }
}

function Invoke-FullLifecycle {
    param([string]$ProviderName, [string]$VersionName)
    $lab = $null
    $sqlPath = Join-Path $env:TEMP "SqlServerLab-Smoke-$ProviderName-$VersionName-$PID.sql"
    try {
        $lab = New-SqlServerLab -Version $VersionName -Provider $ProviderName -Profile compact -SaPassword $SaPassword -SkipAssessment
        $instance = $lab.Instances | Select-Object -First 1
        $dbName = "Smoke_${ProviderName}_${VersionName}" -replace '[^A-Za-z0-9_]', '_'
        $db = New-SqlServerLabDatabase -HostName $instance.Host -Port $instance.Port -SaPassword $SaPassword -DatabaseName $dbName
        if (-not $db.Success) { throw 'Datenbankerstellung meldet Success=False.' }

        @"
CREATE TABLE dbo.SmokeEvidence(Id int NOT NULL PRIMARY KEY, Marker nvarchar(128) NOT NULL);
GO
INSERT dbo.SmokeEvidence(Id, Marker) VALUES (1, N'$ProviderName-$VersionName');
GO
"@ | Set-Content -LiteralPath $sqlPath -Encoding utf8

        $scriptResult = Invoke-SqlServerLabScript -RunId $lab.RunId -ScriptPath $sqlPath -Database $dbName -SaPassword $SaPassword
        if (-not $scriptResult.Success) { throw $scriptResult.Message }

        $restart = Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 60 -Force
        if ($restart.Status -ne 'RUNNING' -or $restart.Errors -ne 0) { throw 'Restart fehlgeschlagen.' }

        Wait-TestDatabaseReady `
            -HostName $instance.Host `
            -Port $instance.Port `
            -Password $SaPassword `
            -Database $dbName `
            -TimeoutSeconds 60

        $plain = ConvertFrom-TestSecureString $SaPassword
        try {
            $marker = & sqlcmd -S "$($instance.Host),$($instance.Port)" -U sa -P $plain -C -b -h -1 -W -d $dbName -Q 'SET NOCOUNT ON; SELECT Marker FROM dbo.SmokeEvidence WHERE Id=1;' 2>&1
            if ($LASTEXITCODE -ne 0) { throw (($marker | Out-String).Trim()) }
        }
        finally { $plain = $null }

        $stop = Stop-SqlServerLab -RunId $lab.RunId -Force
        if ($stop.Status -ne 'STOPPED') { throw 'Stop fehlgeschlagen.' }
        $start = Start-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 60
        if ($start.Status -ne 'RUNNING' -or $start.Errors -ne 0) { throw 'Start fehlgeschlagen.' }

        $remove = Remove-SqlServerLab -RunId $lab.RunId -Force
        if ($remove.Cleanup -ne 'CLEANUP_SUCCEEDED' -or $remove.Errors -ne 0) { throw 'Cleanup fehlgeschlagen.' }
        $lab = $null
        Add-Result -Category 'Lifecycle' -Provider $ProviderName -Version $VersionName -Status PASS -Message 'Create/DB/Script/Restart/Persistenz/Stop/Start/Cleanup'
    }
    catch {
        Add-Result -Category 'Lifecycle' -Provider $ProviderName -Version $VersionName -Status FAIL -Message $_.Exception.Message
        if (-not $KeepOnFailure) { Remove-TestLabSafely $lab }
    }
    finally { Remove-Item -LiteralPath $sqlPath -Force -ErrorAction SilentlyContinue }
}

function Invoke-ParallelProbe {
    param([string[]]$ProviderNames, [string]$VersionName)
    $scenarios = [System.Collections.Generic.List[object]]::new()
    if ('docker' -in $ProviderNames) {
        $scenarios.Add([pscustomobject]@{ Provider='docker'; Version=$VersionName })
        $scenarios.Add([pscustomobject]@{ Provider='docker'; Version=$VersionName })
    }
    if ('podman' -in $ProviderNames) {
        $scenarios.Add([pscustomobject]@{ Provider='podman'; Version=$VersionName })
        $scenarios.Add([pscustomobject]@{ Provider='podman'; Version=$VersionName })
    }
    if ($scenarios.Count -lt 2) {
        Add-Result -Category 'Parallel' -Provider ($ProviderNames -join ',') -Version '-' -Status SKIP -Message 'Weniger als zwei geeignete Szenarien.'
        return
    }

    $jobs = @()
    $labs = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($scenario in $scenarios) {
            $jobs += Start-ThreadJob -ArgumentList $modulePath,$scenario.Provider,$scenario.Version,$SaPassword -ScriptBlock {
                param($ModulePath,$ProviderName,$VersionName,$Password)
                Import-Module $ModulePath -Force
                New-SqlServerLab -Version $VersionName -Provider $ProviderName -Profile compact -SaPassword $Password -SkipAssessment
            }
        }
        $jobResults = @($jobs | Wait-Job | Receive-Job -ErrorAction Stop)
        foreach ($item in $jobResults) {
            if ($item.RunId) { $labs.Add($item) }
        }
        if ($labs.Count -ne $scenarios.Count) { throw "Nur $($labs.Count) von $($scenarios.Count) Labs erstellt." }

        $runIds = @($labs.RunId | Sort-Object -Unique)
        $scopeIds = @($labs.ScopeId | Sort-Object -Unique)
        $ports = @($labs | ForEach-Object { $_.Instances[0].Port } | Sort-Object -Unique)
        if ($runIds.Count -ne $labs.Count) { throw 'RunIds sind nicht eindeutig.' }
        if ($scopeIds.Count -ne $labs.Count) { throw 'ScopeIds sind nicht eindeutig.' }
        if ($ports.Count -ne $labs.Count) { throw 'Ports sind nicht eindeutig.' }

        $victim = $labs[0]
        Remove-SqlServerLab -RunId $victim.RunId -Force | Out-Null
        for ($i = 1; $i -lt $labs.Count; $i++) {
            $status = Get-SqlServerLab -RunId $labs[$i].RunId
            if ($status.State -ne 'RUNNING' -or -not $status.Instances[0].ContainerUp) {
                throw "Isolierter Cleanup beeintraechtigte Run $($labs[$i].RunId)."
            }
        }
        for ($i = 1; $i -lt $labs.Count; $i++) { Remove-SqlServerLab -RunId $labs[$i].RunId -Force | Out-Null }
        $labs.Clear()
        Add-Result -Category 'Parallel' -Provider ($ProviderNames -join ',') -Version $VersionName -Status PASS -Message "$($scenarios.Count) Runs, eindeutige Ports/States, isolierter Cleanup"
    }
    catch {
        Add-Result -Category 'Parallel' -Provider ($ProviderNames -join ',') -Version $VersionName -Status FAIL -Message $_.Exception.Message
        if (-not $KeepOnFailure) { foreach ($lab in $labs) { Remove-TestLabSafely $lab } }
    }
    finally { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n===================================================================="
Write-Host ' SQL_Server_Lab Smoke Matrix'
Write-Host '===================================================================='

$podmanBootstrapPath = Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1'
if ($Provider -eq 'podman') {
    $null = & $podmanBootstrapPath
}
elseif ($Provider -eq 'all' -and (Get-Command podman -ErrorAction SilentlyContinue)) {
    try {
        $null = & $podmanBootstrapPath
    }
    catch {
        Write-Warning "Installierte Podman-Runtime konnte nicht automatisch gestartet werden: $($_.Exception.Message)"
    }
}

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force
if (-not $SaPassword) { $SaPassword = ConvertTo-SecureString 'SmokeTest_Pwd1!' -AsPlainText -Force }

$implemented = @()
foreach ($directory in Get-ChildItem -LiteralPath $providersRoot -Directory) {
    $definitionPath = Join-Path $directory.FullName 'provider.json'
    if (-not (Test-Path $definitionPath)) { continue }
    $definition = Get-Content $definitionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($definition.module -and (Test-Path (Join-Path $directory.FullName $definition.module))) { $implemented += [string]$definition.name }
}
$implemented = @($implemented | Sort-Object -Unique)
$requested = if ($Provider -eq 'all') { $implemented } else { @($Provider) }
$available = @()
foreach ($name in $requested) {
    if ($name -notin $implemented) { Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status FAIL -Message 'Provider nicht implementiert'; continue }
    if ($name -eq 'hyperv') {
        try {
            $assessment = Test-SqlServerLabPrerequisite -Provider $name
            if ($assessment.Status -ne 'RESOURCE_HARD_BLOCK') {
                Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status PASS -Message 'Verfuegbar; Lifecycle in dieser Matrix nicht ausgefuehrt (verwende .\Tests\Integration\Invoke-HyperVSmokeTest.ps1).'
            }
            else {
                $detail = if ($assessment.Details -and $assessment.Details.Count -gt 0) {
                    $assessment.Details[0].Message
                } else { 'Hyper-V ist nicht erreichbar/konfiguriert.' }
                Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status SKIP -Message $detail
            }
        }
        catch {
            Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status SKIP -Message $_.Exception.Message
        }
        continue
    }
    $runtime = Test-RuntimeAvailable $name
    if ($runtime.Available) {
        $available += $name
        Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status PASS -Message $runtime.Message
    }
    else { Add-Result -Category 'Discovery' -Provider $name -Version '-' -Status SKIP -Message $runtime.Message }
}
if ($available.Count -eq 0 -and $requestedMode -eq 'all') {
    $elapsed = (Get-Date) - $script:StartedAt
    Write-Host "`n===================================================================="
    Write-Host ' ERGEBNIS'
    Write-Host '===================================================================='
    $script:Results | Format-Table Category,Provider,Version,Status,Message -AutoSize
    $failures = @($script:Results | Where-Object Status -eq 'FAIL')
    $skipped = @($script:Results | Where-Object Status -eq 'SKIP')
    Write-Host ("PASS={0} FAIL={1} SKIP={2} Dauer={3:N1}s" -f @($script:Results | Where-Object Status -eq 'PASS').Count,$failures.Count,$skipped.Count,$elapsed.TotalSeconds)
    if ($failures.Count -gt 0) { exit 1 }
    exit 0
}

if ($available.Count -eq 0) { throw 'Kein angeforderter Provider ist erreichbar.' }

foreach ($name in $available) { Invoke-FullLifecycle -ProviderName $name -VersionName $ReferenceVersion }
if ($IncludeParallel) { Invoke-ParallelProbe -ProviderNames $available -VersionName $ReferenceVersion }

$elapsed = (Get-Date) - $script:StartedAt
Write-Host "`n===================================================================="
Write-Host ' ERGEBNIS'
Write-Host '===================================================================='
$script:Results | Format-Table Category,Provider,Version,Status,Message -AutoSize
$failures = @($script:Results | Where-Object Status -eq 'FAIL')
$skipped = @($script:Results | Where-Object Status -eq 'SKIP')
Write-Host ("PASS={0} FAIL={1} SKIP={2} Dauer={3:N1}s" -f @($script:Results | Where-Object Status -eq 'PASS').Count,$failures.Count,$skipped.Count,$elapsed.TotalSeconds)
if ($failures.Count -gt 0) { exit 1 }
exit 0


