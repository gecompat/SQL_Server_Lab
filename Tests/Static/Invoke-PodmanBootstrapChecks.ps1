#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft das Verhalten des Podman-Runtime-Bootstraps ohne echte Runtime.
.DESCRIPTION
    Fuehrt Initialize-PodmanRuntime.ps1 in isolierten PowerShell-Prozessen mit
    einer simulierten podman-Funktion aus. Geprueft werden Ready-, Start-,
    Fehler-, Timeout- und Parallelpfade.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$targetPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\Integration')).Path 'Initialize-PodmanRuntime.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-podman-bootstrap-check-$([guid]::NewGuid().ToString('N'))"
$harnessPath = Join-Path $temporaryRoot 'Invoke-SyntheticPodman.ps1'
$pwshCommand = Get-Command pwsh -ErrorAction Stop
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

function Invoke-SyntheticScenario {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [int]$TimeoutSeconds = 2
    )

    $statePath = Join-Path $temporaryRoot $Scenario
    New-Item -Path $statePath -ItemType Directory -Force | Out-Null
    $output = @(& $pwshCommand.Source `
        -NoLogo `
        -NoProfile `
        -File $harnessPath `
        -TargetPath $targetPath `
        -Scenario $Scenario `
        -StatePath $statePath `
        -TimeoutSeconds $TimeoutSeconds 2>&1)

    return [pscustomobject]@{
        ExitCode  = $LASTEXITCODE
        Output    = ($output | ForEach-Object { [string]$_ }) -join "`n"
        StatePath = $statePath
    }
}

Write-Host ''
Write-Host 'SQL_Server_Lab - Podman Bootstrap Checks' -ForegroundColor Cyan

try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    @'
#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Scenario,
    [Parameter(Mandatory)][string]$StatePath,
    [int]$TimeoutSeconds = 2
)

$ErrorActionPreference = 'Stop'
$readyMarker = Join-Path $StatePath 'ready.marker'
$startLog = Join-Path $StatePath 'starts.log'

function global:podman {
    $verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $subverb = if ($args.Count -gt 1) { [string]$args[1] } else { '' }

    if ($verb -eq 'info') {
        $ready = $Scenario -eq 'ready' -or (Test-Path -LiteralPath $readyMarker -PathType Leaf)
        $global:LASTEXITCODE = if ($ready) { 0 } else { 1 }
        return
    }

    if ($verb -eq 'machine' -and $subverb -eq 'list') {
        $global:LASTEXITCODE = 0
        switch ($Scenario) {
            'noMachine' { '[]'; return }
            'ambiguous' { '[{"Name":"machine-a"},{"Name":"machine-b"}]'; return }
            'soleCustom' { '[{"Name":"custom-machine"}]'; return }
            default { '[{"Name":"podman-machine-default"}]'; return }
        }
    }

    if ($verb -eq 'machine' -and $subverb -eq 'start') {
        $machineName = [string]$args[2]
        [System.IO.File]::AppendAllText($startLog, "$machineName`n")
        if ($Scenario -eq 'startFailure') {
            'SYNTHETIC_START_FAILURE'
            $global:LASTEXITCODE = 17
            return
        }

        if ($Scenario -eq 'concurrent') {
            Start-Sleep -Milliseconds 400
        }
        if ($Scenario -ne 'timeout') {
            Set-Content -LiteralPath $readyMarker -Value 'ready' -Encoding ascii
        }
        $global:LASTEXITCODE = 0
        return
    }

    throw "Unerwarteter synthetischer podman-Aufruf: $($args -join ' ')"
}

try {
    $result = & $TargetPath -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds 1
    $result | ConvertTo-Json -Compress
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@ | Set-Content -LiteralPath $harnessPath -Encoding utf8

    $ready = Invoke-SyntheticScenario -Scenario ready
    Add-CheckResult `
        -Name 'Erreichbare Runtime startet keine Machine' `
        -Success ($ready.ExitCode -eq 0 -and -not (Test-Path (Join-Path $ready.StatePath 'starts.log')))

    $default = Invoke-SyntheticScenario -Scenario stoppedDefault
    $defaultStarts = @(if (Test-Path (Join-Path $default.StatePath 'starts.log')) {
        Get-Content (Join-Path $default.StatePath 'starts.log')
    })
    Add-CheckResult `
        -Name 'Gestoppte Default-Machine wird gestartet' `
        -Success ($default.ExitCode -eq 0 -and $defaultStarts.Count -eq 1 -and $defaultStarts[0] -eq 'podman-machine-default') `
        -Message $default.Output

    $custom = Invoke-SyntheticScenario -Scenario soleCustom
    $customStarts = @(if (Test-Path (Join-Path $custom.StatePath 'starts.log')) {
        Get-Content (Join-Path $custom.StatePath 'starts.log')
    })
    Add-CheckResult `
        -Name 'Einzige benutzerdefinierte Machine ist ein eindeutiges Ziel' `
        -Success ($custom.ExitCode -eq 0 -and $customStarts.Count -eq 1 -and $customStarts[0] -eq 'custom-machine') `
        -Message $custom.Output

    $noMachine = Invoke-SyntheticScenario -Scenario noMachine
    Add-CheckResult `
        -Name 'Fehlende Machine bricht mit klarer Meldung ab' `
        -Success ($noMachine.ExitCode -ne 0 -and $noMachine.Output -match 'existiert keine Machine') `
        -Message $noMachine.Output

    $ambiguous = Invoke-SyntheticScenario -Scenario ambiguous
    Add-CheckResult `
        -Name 'Mehrdeutige Machine-Auswahl wird nicht geraten' `
        -Success ($ambiguous.ExitCode -ne 0 -and $ambiguous.Output -match 'nicht eindeutig') `
        -Message $ambiguous.Output

    $startFailure = Invoke-SyntheticScenario -Scenario startFailure
    Add-CheckResult `
        -Name 'Startfehler bleibt als Fehler sichtbar' `
        -Success ($startFailure.ExitCode -ne 0 -and $startFailure.Output -match 'SYNTHETIC_START_FAILURE') `
        -Message $startFailure.Output

    $timeout = Invoke-SyntheticScenario -Scenario timeout -TimeoutSeconds 1
    Add-CheckResult `
        -Name 'Nicht erreichbare gestartete Machine endet am Timeout' `
        -Success ($timeout.ExitCode -ne 0 -and $timeout.Output -match 'nach 1 Sekunden nicht erreichbar') `
        -Message $timeout.Output

    $concurrentState = Join-Path $temporaryRoot 'concurrent'
    New-Item -Path $concurrentState -ItemType Directory -Force | Out-Null
    $jobs = @(
        1..2 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($PwshPath, $Harness, $Target, $State)
                $output = @(& $PwshPath `
                    -NoLogo `
                    -NoProfile `
                    -File $Harness `
                    -TargetPath $Target `
                    -Scenario concurrent `
                    -StatePath $State `
                    -TimeoutSeconds 5 2>&1)
                [pscustomobject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = ($output | ForEach-Object { [string]$_ }) -join "`n"
                }
            } -ArgumentList $pwshCommand.Source, $harnessPath, $targetPath, $concurrentState
        }
    )
    try {
        $concurrentResults = @($jobs | Wait-Job | Receive-Job)
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    $concurrentStarts = @(if (Test-Path (Join-Path $concurrentState 'starts.log')) {
        Get-Content (Join-Path $concurrentState 'starts.log')
    })
    Add-CheckResult `
        -Name 'Hostweiter Lock verhindert doppelten parallelen Start' `
        -Success (@($concurrentResults | Where-Object { $_.ExitCode -eq 0 }).Count -eq 2 -and $concurrentStarts.Count -eq 1) `
        -Message (($concurrentResults.Output) -join "`n")
}
catch {
    Add-CheckResult -Name 'Podman-Bootstrap-Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
