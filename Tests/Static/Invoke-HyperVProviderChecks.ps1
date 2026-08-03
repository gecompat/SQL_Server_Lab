#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den statischen Vertrag der Hyper-V-Lifecycle-Grundlage.
.DESCRIPTION
    Validiert Metadaten, Funktionsoberflaeche, Parent-Integritaet, Generation 2,
    Secure Boot, scopegebundenen Cleanup und die ausdrueckliche Grenze zur noch
    nicht implementierten SQL-Provisionierung ohne Hyper-V-Ressourcen zu aendern.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$providerPath = Join-Path $repoRoot 'Providers\HyperV\HyperVProvider.ps1'
$metadataPath = Join-Path $repoRoot 'Providers\HyperV\provider.json'
$cleanupPath = Join-Path $repoRoot 'Private\CleanupEngine.ps1'
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

function Add-TextContract {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )
    Add-CheckResult -Name $Name -Success ([bool]($Text -match $Pattern))
}

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Provider Checks' -ForegroundColor Cyan

try {
    $provider = Get-Content -LiteralPath $providerPath -Raw -Encoding utf8
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $cleanup = Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8

    Add-CheckResult -Name 'Metadaten registrieren hyperv' -Success ($metadata.name -eq 'hyperv')
    Add-CheckResult `
        -Name 'SQL-Provisionierung bleibt explizit deaktiviert' `
        -Success ($metadata.runtimeStatus -eq 'windows-image-builder-foundation' -and $metadata.sqlProvisioning -eq $false)
    Add-CheckResult `
        -Name 'Runner-Labels sind capability-spezifisch' `
        -Success ((@($metadata.requirements.runnerLabels) -join ',') -eq 'self-hosted,SQL_Lab,Hyper-V')

    foreach ($functionName in @(
        'Test-HyperVAvailable',
        'New-HyperVInstance',
        'Get-HyperVInstanceStatus',
        'Start-HyperVInstance',
        'Stop-HyperVInstance',
        'Invoke-HyperVPowerShellDirect',
        'Remove-HyperVInstance',
        'Get-HyperVLabVMs'
    )) {
        Add-TextContract `
            -Name "Providerfunktion vorhanden: $functionName" `
            -Text $provider `
            -Pattern ("function\s+" + [regex]::Escape($functionName) + "\b")
    }

    Add-TextContract `
        -Name 'Cleanup-Plan wird vor New-VHD erweitert' `
        -Text $provider `
        -Pattern 'Add-CleanupStep[\s\S]+ResourceType\s+''vhdx''[\s\S]+Add-CleanupStep[\s\S]+ResourceType\s+''vm''[\s\S]+New-VHD'
    Add-TextContract `
        -Name 'Parent-VHDX muss read-only sein' `
        -Text $provider `
        -Pattern '\$parentItem\.IsReadOnly'
    Add-TextContract `
        -Name 'Parent-VHDX wird per SHA-256 verifiziert' `
        -Text $provider `
        -Pattern 'Get-FileHash[\s\S]+SHA256[\s\S]+PARENT_VHDX_INTEGRITY_MISMATCH'
    Add-TextContract `
        -Name 'Generation 2 ist verbindlich' `
        -Text $provider `
        -Pattern 'Generation\s*=\s*2'
    Add-TextContract `
        -Name 'Secure Boot verwendet das Windows-Template' `
        -Text $provider `
        -Pattern 'EnableSecureBoot\s+On[\s\S]+SecureBootTemplate\s+MicrosoftWindows'
    Add-TextContract `
        -Name 'Lifecycle ohne Switch entfernt implizite Netzwerkadapter' `
        -Text $provider `
        -Pattern 'if\s*\(-not\s+\$SwitchName\)[\s\S]+Get-VMNetworkAdapter[\s\S]+Remove-VMNetworkAdapter'
    Add-TextContract `
        -Name 'Child-VHDX-Loeschung prueft die Run-Pfadgrenze' `
        -Text $provider `
        -Pattern 'Remove-HyperVVhdxForCleanup[\s\S]+Test-HyperVPathWithinRunDirectory'
    Add-TextContract `
        -Name 'Cleanup-Engine behandelt Hyper-V-VM und Child-VHDX getrennt' `
        -Text $cleanup `
        -Pattern "'vm'[\s\S]+Remove-LabHyperVResourceForCleanup[\s\S]+'vhdx'[\s\S]+Remove-LabHyperVResourceForCleanup"

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $roundTrip = & $module {
        $notes = ConvertTo-HyperVLabNotes `
            -RunId '00000000-0000-0000-0000-000000000001' `
            -ScopeId '00000000-0000-0000-0000-000000000002' `
            -InstanceId 'static-check' `
            -ChildVhdxPath (Join-Path ([System.IO.Path]::GetTempPath()) 'synthetic.vhdx')
        ConvertFrom-HyperVLabNotes -Notes $notes
    }
    Add-CheckResult `
        -Name 'VM-Notizen bewahren Run-, Scope- und Instanzidentitaet' `
        -Success (
            $roundTrip.runId -eq '00000000-0000-0000-0000-000000000001' -and
            $roundTrip.scopeId -eq '00000000-0000-0000-0000-000000000002' -and
            $roundTrip.instanceId -eq 'static-check'
        )

    $pathContract = & $module {
        $runDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'sql-lab-hyperv-static-run'
        $insidePath = Join-Path `
            (Join-Path (Join-Path $runDirectory 'resources') 'hyperv') `
            'child.vhdx'
        [PSCustomObject]@{
            Inside = Test-HyperVPathWithinRunDirectory `
                -Path $insidePath `
                -RunDirectory $runDirectory
            Outside = Test-HyperVPathWithinRunDirectory `
                -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'outside.vhdx') `
                -RunDirectory $runDirectory
        }
    }
    Add-CheckResult `
        -Name 'Run-Pfadgrenze akzeptiert nur resources/hyperv' `
        -Success ($pathContract.Inside -and -not $pathContract.Outside)
}
catch {
    Add-CheckResult -Name 'Hyper-V-Provider-Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
