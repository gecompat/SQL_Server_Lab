#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-hyperv-environment-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Lab Environment Checks' -ForegroundColor Cyan

try {
    $module = Import-Module $modulePath -Force -PassThru
    $created = & $module {
        param($Root)
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = 'mock' } }
        function Get-HyperVImageArtifact {
            [PSCustomObject]@{
                artifactId = 'sql-prepared-test'; artifactState = 'SQL_PREPARED_SEALED'
                sql = [PSCustomObject]@{ version = '2025'; edition = 'Enterprise' }
            }
        }
        function New-HyperVInstance {
            [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id' }
        }
        New-HyperVLabEnvironment -ArtifactId 'sql-prepared-test' -LabName 'Mock Lab' -InstanceId primary -StateRoot $Root
    } $temporaryRoot
    $state = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    $connection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
    Add-CheckResult -Name 'Reguläres Hyper-V-Lab bindet ausschließlich ein Prepared-Image und bleibt ausgeschaltet' -Success (
        $created.State -eq 'STOPPED' -and $state.state -eq 'STOPPED' -and
        $connection.instances.Count -eq 1 -and $connection.instances[0].provider -eq 'hyperv' -and
        $connection.instances[0].imageArtifactId -eq 'sql-prepared-test'
    )

    $existingVmCreated = & $module {
        param($Root)
        $script:sourceDisk = Join-Path $Root 'quick-create-windows11.vhdx'
        $null = New-Item -ItemType File -Path $script:sourceDisk -Force
        $script:convertedFrom = $null
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = 'mock' } }
        function Get-VM { [PSCustomObject]@{ Name = 'Windows 11 Dev Environment'; State = 'Off'; Generation = 2; MemoryStartup = 4GB; ProcessorCount = 4; Notes = '' } }
        function Get-VMHardDiskDrive { [PSCustomObject]@{ Path = $script:sourceDisk } }
        function Get-VHD { [PSCustomObject]@{ VhdType = 'Dynamic' } }
        function Convert-VHD {
            param($Path, $DestinationPath)
            $script:convertedFrom = $Path
            $null = New-Item -ItemType File -Path $DestinationPath -Force
        }
        function Get-FileHash { [PSCustomObject]@{ Hash = ('a' * 64) } }
        function New-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-existing'; VMId = 'existing-vm-id' } }
        $created = New-HyperVLabEnvironmentFromExistingVm -SourceVMName 'Windows 11 Dev Environment' -LabName 'Windows Dev Lab' -InstanceId primary -ConfirmSourceLicense -StateRoot $Root
        [PSCustomObject]@{ Created = $created; ConvertedFrom = $script:convertedFrom; Source = $script:sourceDisk }
    } $temporaryRoot
    $existingConnection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $existingVmCreated.Created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
    Add-CheckResult -Name 'Vorhandene Windows-VM wird nur als unveränderte Quelle in eine run-lokale Parent-Kopie übernommen' -Success (
        $existingVmCreated.Created.State -eq 'STOPPED' -and
        $existingVmCreated.ConvertedFrom -eq $existingVmCreated.Source -and
        $existingConnection.instances[0].baseKind -eq 'existing-vm' -and
        $existingConnection.instances[0].sourceVMName -eq 'Windows 11 Dev Environment' -and
        $existingConnection.instances[0].sourceParentCopyPath -like '*source-parent.vhdx'
    )

    $licenseRejected = & $module {
        param($Root)
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = 'mock' } }
        try { New-HyperVLabEnvironmentFromExistingVm -SourceVMName 'anything' -LabName 'Test' -InstanceId primary -StateRoot $Root; $false }
        catch { $_.Exception.Message -eq 'HYPERV_EXISTING_VM_LICENSE_CONFIRMATION_REQUIRED' }
    } $temporaryRoot
    Add-CheckResult -Name 'Schnellstart aus vorhandener VM verlangt eine ausdrückliche Lizenz- und Ablaufbestätigung' -Success $licenseRejected

    $started = & $module {
        param($RunId, $Root)
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Running'; Exists = $true } }
        Start-HyperVLabEnvironment -RunId $RunId -StateRoot $Root
    } $created.RunId $temporaryRoot
    $runningState = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Lab-Start setzt VM- und Run-State zustandsgeführt' -Success ($started.State -eq 'Running' -and $runningState.state -eq 'RUNNING')

    $stopped = & $module {
        param($RunId, $Root)
        function Stop-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Off'; Exists = $true } }
        Stop-HyperVLabEnvironment -RunId $RunId -StateRoot $Root
    } $created.RunId $temporaryRoot
    $stoppedState = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Lab-Stopp bewahrt den Run und setzt STOPPED' -Success ($stopped.State -eq 'Off' -and $stoppedState.state -eq 'STOPPED')

    $opened = & $module {
        param($RunId, $Root)
        function Get-HyperVInstanceStatus { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Off'; Exists = $true } }
        function Start-LabVmConnect { param($VMName) [PSCustomObject]@{ VMName = $VMName; Started = $true } }
        Open-HyperVLabEnvironmentConsole -RunId $RunId -StateRoot $Root
    } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Lab öffnet VMConnect nur für die verwaltete VM' -Success ($opened.VMName -eq 'sql-lab-primary-mock' -and $opened.Exists)
}
catch {
    Add-CheckResult -Name 'Hyper-V-Lab-Umgebung Testausführung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }
