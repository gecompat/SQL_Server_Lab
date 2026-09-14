#Requires -Version 7.2
<#
.SYNOPSIS
    Entfernt eine ausgeschaltete, verwaiste Hyper-V-Test-VM mit ihren explizit gebundenen eigenen Datenträgern.

.DESCRIPTION
    Dieses Werkzeug ist für den Ausnahmefall bestimmt, dass der SQL_Server_Lab-
    Run-State nicht mehr vorhanden ist und der normale scopegebundene Cleanup
    deshalb fail-closed bleibt.

    Der VM-Name ist die einzige Zielangabe. Vor jeder Mutation ermittelt und
    prüft das Skript VM-ID, VM-Zustand, Konfigurationsverzeichnis, beide
    angeschlossenen VHDX-Dateien und den Parent der Differencing-VHDX erneut.
    Der Parent wird ausschließlich geprüft, niemals gelöscht.

    Die zusätzliche Daten-VHDX außerhalb des Run-Verzeichnisses wird nur mit
    -DeleteAdditionalVhdx entfernt. Das zugehörige Cleanup-Verzeichnis darf
    keine weiteren Dateien oder Reparse-Points enthalten.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', PositionalBinding = $false)]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')][string]$VMName,
    [switch]$DeleteAdditionalVhdx
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RemainingArgs -contains '--help') {
    $ShowHelp = $true
    $RemainingArgs = @($RemainingArgs | Where-Object { $_ -ne '--help' })
}
if ($ShowHelp) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}
if ($RemainingArgs.Count -gt 0) {
    throw "UNKNOWN_ARGUMENTS: $($RemainingArgs -join ', ')"
}
if ([string]::IsNullOrWhiteSpace($VMName)) {
    throw 'VMName ist erforderlich.'
}

function Resolve-ExactPath {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-ExclusiveDirectory {
    param([Parameter(Mandatory)][string]$Root,[AllowEmptyCollection()][string[]]$AllowedFiles = @(),[switch]$AllowAnyFiles)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Erwartetes Verzeichnis fehlt: $Root" }
    $entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw "Reparse-Point im Löschumfang: $Root" }
    if (-not $AllowAnyFiles) {
        $unexpectedFiles = @($entries | Where-Object { -not $_.PSIsContainer -and (Resolve-ExactPath -Path $_.FullName) -notin $AllowedFiles })
        if ($unexpectedFiles.Count -gt 0) { throw "Unerwartete Datei im exklusiv erwarteten Löschumfang: $Root" }
    }
}

if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V ist in diesem Prozess nicht verfügbar.' }
if (-not $DeleteAdditionalVhdx) { throw 'Die zusätzliche Daten-VHDX erfordert die explizite Freigabe -DeleteAdditionalVhdx.' }

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw 'Die VM muss vor dem Löschen ausgeschaltet sein.' }
if (@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count -gt 0) { throw 'Die VM besitzt Checkpoints. Diese müssen vor diesem Cleanup kontrolliert zusammengeführt werden.' }

$configurationRoot = Resolve-ExactPath -Path ([string]$vm.ConfigurationLocation)
$attachedVhdx = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | ForEach-Object {
    $path = Resolve-ExactPath -Path ([string]$_.Path)
    [pscustomobject]@{ Path = $path; Vhd = Get-VHD -Path $path -ErrorAction Stop }
})
if ($attachedVhdx.Count -ne 2) { throw 'Die VM besitzt nicht exakt zwei angeschlossene VHDX-Dateien; Löschumfang ist nicht eindeutig.' }
$childCandidates = @($attachedVhdx | Where-Object { [string]$_.Vhd.VhdType -eq 'Differencing' -and [string]$_.Vhd.ParentPath })
$additionalCandidates = @($attachedVhdx | Where-Object { -not [string]$_.Vhd.ParentPath })
if ($childCandidates.Count -ne 1 -or $additionalCandidates.Count -ne 1) { throw 'Child- und zusätzliche Daten-VHDX sind nicht eindeutig ableitbar.' }
$childVhdxPath = [string]$childCandidates[0].Path
$sharedParentVhdxPath = Resolve-ExactPath -Path ([string]$childCandidates[0].Vhd.ParentPath)
$additionalVhdxPath = [string]$additionalCandidates[0].Path
$additionalStorageRoot = Resolve-ExactPath -Path (Split-Path -Parent $additionalVhdxPath)
if ($childVhdxPath -eq $sharedParentVhdxPath -or $additionalVhdxPath -eq $sharedParentVhdxPath) { throw 'Der geprüfte Shared Parent darf nicht zum Löschumfang gehören.' }

$otherVmDiskBindings = @(Get-VM -ErrorAction Stop | Where-Object { [string]$_.Id -ne [string]$vm.Id } | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Where-Object { (Resolve-ExactPath -Path ([string]$_.Path)) -in @($childVhdxPath, $additionalVhdxPath) })
if ($otherVmDiskBindings.Count -gt 0) { throw 'Mindestens eine zu löschende VHDX ist noch an eine andere VM gebunden.' }
Assert-ExclusiveDirectory -Root $configurationRoot -AllowedFiles @() -AllowAnyFiles
Assert-ExclusiveDirectory -Root $additionalStorageRoot -AllowedFiles @($additionalVhdxPath)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Verwaiste Hyper-V-VM und explizit gebundene Datenträger endgültig entfernen')) {
    return [pscustomobject]@{ Status = 'WHATIF'; VMName = $VMName; VMId = [string]$vm.Id; DeletedPaths = @($configurationRoot, $childVhdxPath, $additionalVhdxPath, $additionalStorageRoot); PreservedPaths = @($sharedParentVhdxPath) }
}

Remove-VM -VM $vm -Force -ErrorAction Stop
foreach ($path in @($childVhdxPath, $additionalVhdxPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
foreach ($root in @($configurationRoot, $additionalStorageRoot)) { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } }
$remaining = @($(if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 'VM' }); foreach ($path in @($configurationRoot, $childVhdxPath, $additionalVhdxPath, $additionalStorageRoot)) { if (Test-Path -LiteralPath $path) { $path } })
if ($remaining.Count -gt 0) { throw "Cleanup unvollständig: $($remaining -join ', ')" }
[pscustomobject]@{ Status = 'REMOVED'; VMName = $VMName; VMId = [string]$vm.Id; DeletedPaths = @($configurationRoot, $childVhdxPath, $additionalVhdxPath, $additionalStorageRoot); PreservedPaths = @($sharedParentVhdxPath) }
