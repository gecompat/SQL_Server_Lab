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
    $runtimeName = & $module { Get-HyperVLabRuntimeName -LabName 'Mein SQL Lab' -RunId '12345678-0000-0000-0000-000000000000' }
    Add-CheckResult -Name 'Hyper-V-Runtime-Name zeigt Projektnamen und eindeutiges Run-Präfix' -Success ($runtimeName -eq 'Mein SQL Lab-12345678')
    $containerRename = & $module {
        param($Root)
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Alter Name' } -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $oldName = 'alter-name-primary-oldrunid'
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType container -ResourceId $oldName -Action remove -Provider docker -ProviderSubRunId provider-docker
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{ instances = @([PSCustomObject]@{ id = 'primary'; provider = 'docker'; containerId = 'mock-container-id'; containerName = $oldName }) })
        function docker { param($Verb, $ContainerId, $NewName) $global:LASTEXITCODE = 0 }
        $result = Rename-ContainerLabEnvironment -RunId $run.RunId -DisplayName 'Neuer Name' -StateRoot $Root
        $connection = Get-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
        $plan = Get-Content -LiteralPath (Join-Path $run.RunDir 'cleanup-plan.json') -Raw | ConvertFrom-Json -Depth 10
        [PSCustomObject]@{ Result = $result; Name = $connection.instances[0].containerName; CleanupName = $plan.steps[0].resourceId }
    } $temporaryRoot
    Add-CheckResult -Name 'Container-Umbenennung aktualisiert Runtime, Verbindung und Cleanup-Plan gemeinsam' -Success (
        $containerRename.Result.RuntimeRenamed -and
        $containerRename.Name -match '^neuer-name-primary-[a-f0-9]{8}$' -and
        $containerRename.CleanupName -eq $containerRename.Name
    )
    $hyperVRename = & $module {
        param($Root)
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Alter HyperV Name'; workflowKind = 'hyperv-lab' } -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @('primary') })
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @('primary') })
        $oldName = 'alter-hyperv-name-legacy'
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType vm -ResourceId $oldName -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{ instances = @([PSCustomObject]@{ id = 'primary'; provider = 'hyperv'; vmName = $oldName }) })
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ Name = $oldName; State = 'Off' } } }
        function Get-VM { param($Name) $null }
        function Rename-VM { param($VM, $NewName) $script:renamedVm = $NewName }
        $result = Rename-HyperVLabEnvironment -RunId $run.RunId -DisplayName 'Neuer HyperV Name' -StateRoot $Root
        $connection = Get-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
        $plan = Get-Content -LiteralPath (Join-Path $run.RunDir 'cleanup-plan.json') -Raw | ConvertFrom-Json -Depth 10
        [PSCustomObject]@{ Result = $result; Name = $connection.instances[0].vmName; CleanupName = $plan.steps[0].resourceId; RenamedVm = $script:renamedVm }
    } $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Umbenennung aktualisiert VM, Verbindung und Cleanup-Plan gemeinsam' -Success (
        $hyperVRename.Result.VMRenamed -and
        $hyperVRename.Name -match '^Neuer HyperV Name-[a-f0-9]{8}$' -and
        $hyperVRename.CleanupName -eq $hyperVRename.Name -and
        $hyperVRename.RenamedVm -eq $hyperVRename.Name
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

    $inspected = & $module {
        param($RunId, $Root)
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Running' } } }
        function Invoke-HyperVPowerShellDirect {
            param($VMName, $ExpectedRunId, $ExpectedScopeId, $Credential, $ArgumentList, $ScriptBlock)
            [PSCustomObject]@{
                runId = $ArgumentList[0]; scopeId = $ArgumentList[1]; inspectedAt = '2026-08-06T12:00:00.0000000Z'
                instances = @(
                    [PSCustomObject]@{ name = 'MSSQLSERVER'; instanceId = 'MSSQL16.MSSQLSERVER'; isDefault = $true; serviceName = 'MSSQLSERVER'; serviceStatus = 'Running'; tcpPort = 1433 },
                    [PSCustomObject]@{ name = 'REPORTING'; instanceId = 'MSSQL16.REPORTING'; isDefault = $false; serviceName = 'MSSQL$REPORTING'; serviceStatus = 'Stopped'; tcpPort = 51433 }
                )
            }
        }
        $password = ConvertTo-SecureString 'NotARealPassword1!' -AsPlainText -Force
        Inspect-HyperVLabSqlInstances -RunId $RunId -Credential ([PSCredential]::new('Administrator', $password)) -StateRoot $Root
    } $created.RunId $temporaryRoot
    $inspectedConnection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
    Add-CheckResult -Name 'Hyper-V prüft mehrere SQL-Instanzen nur lesend und speichert sichere In-VM-Connection-Strings' -Success (
        @($inspected).Count -eq 2 -and
        $inspectedConnection.instances[0].sqlInstances.Count -eq 2 -and
        $inspectedConnection.instances[0].sqlInstances[0].ConnectionString -match 'Server=localhost,1433;' -and
        $inspectedConnection.instances[0].sqlInstances[1].ConnectionString -match 'Server=localhost,51433;' -and
        $inspectedConnection.instances[0].connectionString -match 'Integrated Security=True'
    )

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
