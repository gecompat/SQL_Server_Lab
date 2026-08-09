#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

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
        function Resolve-LabHyperVNetwork { [PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' } }
        function Get-HyperVLabVMs { @() }
        function New-HyperVInstance {
            [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id' }
        }
        New-HyperVLabEnvironment -ArtifactId 'sql-prepared-test' -LabName 'Mock Lab' -InstanceId primary -StateRoot $Root
    } $temporaryRoot
    $state = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    $connection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
    Add-CheckResult -Name 'Reguläres SQL-Hyper-V-Lab bindet ein Prepared-Image und bleibt ausgeschaltet' -Success (
        $created.State -eq 'STOPPED' -and $state.state -eq 'STOPPED' -and
        $connection.instances.Count -eq 1 -and $connection.instances[0].provider -eq 'hyperv' -and
        $connection.instances[0].imageArtifactId -eq 'sql-prepared-test' -and $connection.instances[0].workload -eq 'sql'
    )
    $driveBound = & $module {
        param($Root)
        $script:driveTestRoot = $Root
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = 'mock' } }
        function Get-HyperVImageArtifact {
            [PSCustomObject]@{
                artifactId = 'sql-prepared-drive-test'; artifactState = 'SQL_PREPARED_SEALED'
                sql = [PSCustomObject]@{ version = '2025'; edition = 'Enterprise' }
            }
        }
        function Resolve-LabHyperVNetwork { [PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' } }
        function Get-HyperVLabVMs { @() }
        function New-HyperVInstance {
            param($AdditionalDrives)
            $script:capturedAdditionalDrives = @($AdditionalDrives)
            $provisionedDrives = @($AdditionalDrives | ForEach-Object {
                [PSCustomObject]@{
                    Id = $_.id; Role = $_.role; SizeBytes = $_.sizeBytes; VhdType = $_.vhdType
                    GuestPath = $_.guestPath; AllocationUnitKB = $_.allocationUnitKB
                    FileSystem = $_.fileSystem; VolumeLabel = $_.volumeLabel
                    Path = (Join-Path $script:driveTestRoot "host-only-$($_.id).vhdx")
                    DiskIdentifier = "disk-$($_.id)"
                }
            })
            [PSCustomObject]@{ VMName = 'sql-lab-drive-mock'; VMId = 'drive-vm-id'; AdditionalDrives = $provisionedDrives }
        }
        $drives = @([PSCustomObject]@{
            id = 'sql-data'; role = 'sqlData'; sizeBytes = [int64](10GB); vhdType = 'dynamic'
            guestPath = 'D:\SQLData'; allocationUnitKB = 64; fileSystem = 'NTFS'; volumeLabel = 'SQL_DATA'
        })
        $desiredState = [PSCustomObject]@{
            contract = 'SqlServerLab.InstanceIntent'; contractVersion = 1; instanceId = 'primary'
            drives = @([PSCustomObject]@{ id = 'sql-data'; role = 'sqlData'; guestPath = 'D:\SQLData' })
        }
        $created = New-HyperVLabEnvironment -ArtifactId 'sql-prepared-drive-test' -LabName 'Drive Mock' -InstanceId primary `
            -AdditionalDrives $drives -DesiredState $desiredState -StateRoot $Root
        $run = Get-LabRunState -RunId $created.RunId -StateRoot $Root
        $connectionPath = Join-Path (Join-Path (Join-Path $Root 'runs') $created.RunId) 'connection-info.json'
        $connection = Get-Content -LiteralPath $connectionPath -Raw | ConvertFrom-Json -Depth 10
        [PSCustomObject]@{
            CapturedDrives = @($script:capturedAdditionalDrives)
            PersistedDrives = @($connection.instances[0].additionalDrives)
            DesiredState = $run.metadata.desiredState
        }
    } $temporaryRoot
    Add-CheckResult -Name 'Manifest-Drives erreichen Hyper-V als VHDX-Intents ohne hostlokale Pfade in der Run-Evidenz' -Success (
        $driveBound.CapturedDrives.Count -eq 1 -and
        $driveBound.CapturedDrives[0].role -eq 'sqlData' -and
        $driveBound.CapturedDrives[0].guestPath -eq 'D:\SQLData' -and
        $driveBound.PersistedDrives.Count -eq 1 -and
        $driveBound.PersistedDrives[0].diskIdentifier -eq 'disk-sql-data' -and
        -not ($driveBound.PersistedDrives[0].PSObject.Properties.Name -contains 'Path') -and
        $driveBound.DesiredState.contract -eq 'SqlServerLab.InstanceIntent'
    )
    $windowsOnly = & $module {
        param($Root)
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = 'mock' } }
        function Get-HyperVImageArtifact {
            [PSCustomObject]@{ artifactId = 'windows-baseline-test'; artifactState = 'OS_SEALED'; sql = $null }
        }
        function Resolve-LabHyperVNetwork { [PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' } }
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'windows-primary-mock'; VMId = 'windows-vm-id'; State = 'Off' } }
        function New-HyperVInstance { [PSCustomObject]@{ VMName = 'windows-primary-mock'; VMId = 'windows-vm-id' } }
        $created = New-HyperVLabEnvironment -ArtifactId 'windows-baseline-test' -LabName 'Windows Mock' -InstanceId primary -StateRoot $Root
        $child = Join-Path $Root 'windows-only-child.vhdx'
        $null = New-Item -Path $child -ItemType File -Force
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Off' }; Identity = [PSCustomObject]@{ childVhdxPath = $child } } }
        function Set-HyperVSqlOfflineUnattend { param($VhdxPath, $MountRoot, $UnattendXml, $BootstrapScript) if ($VhdxPath -ne $child) { throw 'WINDOWS_UNATTEND_INJECTION_INVALID' } }
        function Start-HyperVLabEnvironment { [PSCustomObject]@{ State = 'Running' } }
        function Wait-HyperVPowerShellDirect { [PSCustomObject]@{ Ready = $true; Message = 'ready' } }
        function Invoke-HyperVPowerShellDirect {
            param($ArgumentList)
            [PSCustomObject]@{
                runId = $ArgumentList[0]; imageState = 'IMAGE_STATE_COMPLETE'; geoId = $ArgumentList[1]
                systemLocale = $ArgumentList[2]; uiLanguage = $ArgumentList[3]; inputLocale = $ArgumentList[4]
                timeZone = $ArgumentList[5]; observedAt = '2026-08-07T12:00:00.0000000Z'
            }
        }
        function Complete-HyperVLabSqlImage { throw 'SQL_MUST_NOT_RUN_FOR_WINDOWS_ONLY' }
        $password = ConvertTo-SecureString 'Windows_Administrator_42!' -AsPlainText -Force
        $result = Invoke-HyperVLabUnattendedProvision -RunId $created.RunId -AdministratorPassword $password -PasswordSource generated -StateRoot $Root
        $connection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $Root 'runs') $created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
        [PSCustomObject]@{ Created = $created; Result = $result; Connection = $connection }
    } $temporaryRoot
    Add-CheckResult -Name 'Windows-OS-Baseline erzeugt eine automatische reine Windows-VM ohne SQL-Aktionen' -Success (
        $windowsOnly.Created.Workload -eq 'windows' -and
        $windowsOnly.Connection.instances[0].workload -eq 'windows' -and
        $windowsOnly.Result.WindowsOnly -and
        $windowsOnly.Connection.instances[0].windowsProvisioning.state -eq 'COMPLETE' -and
        -not $windowsOnly.Connection.instances[0].sqlCompletion
    )
    $unattended = & $module {
        param($RunId, $Root)
        $child = Join-Path $Root 'unattended-child.vhdx'
        $null = New-Item -Path $child -ItemType File -Force
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Off' } }
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Off' }; Identity = [PSCustomObject]@{ childVhdxPath = $child } } }
        function Set-HyperVSqlOfflineUnattend { param($VhdxPath, $MountRoot, $UnattendXml, $BootstrapScript) if ($VhdxPath -ne $child -or $UnattendXml -notmatch 'AdministratorPassword' -or $UnattendXml -notmatch '<TimeZone>Central Europe Standard Time</TimeZone>' -or $BootstrapScript -notmatch 'Enable-PSRemoting') { throw 'UNATTEND_INJECTION_INVALID' } }
        function Start-HyperVLabEnvironment { [PSCustomObject]@{ State = 'Running' } }
        function Wait-HyperVPowerShellDirect { param($FallbackAddress) if (-not $FallbackAddress) { throw 'LAB_NETWORK_FALLBACK_INVALID' }; [PSCustomObject]@{ Ready = $true; Message = 'ready' } }
        function Invoke-HyperVPowerShellDirect {
            param($ArgumentList, $FallbackAddress)
            if (-not $FallbackAddress) { throw 'LAB_NETWORK_FALLBACK_INVALID' }
            [PSCustomObject]@{
                runId = $ArgumentList[0]; imageState = 'IMAGE_STATE_COMPLETE'; geoId = $ArgumentList[1]
                systemLocale = $ArgumentList[2]; uiLanguage = $ArgumentList[3]; inputLocale = $ArgumentList[4]
                timeZone = $ArgumentList[5]; observedAt = '2026-08-07T12:00:00.0000000Z'
            }
        }
        function Complete-HyperVLabSqlImage {
            param($RunId, $Credential, $SqlSaPassword)
            $script:capturedSqlSaPasswordLength = $SqlSaPassword.Length
            [PSCustomObject]@{
                state = 'COMPLETE'; serviceStatus = 'Running'
                hostSqlAccess = [PSCustomObject]@{ ConnectionString = 'Server=172.28.0.58,1433;Database=master;User ID=sa;Password=<separates-Sa-Passwort>;' }
            }
        }
        $password = ConvertTo-SecureString 'Generated_Administrator_42!' -AsPlainText -Force
        $saPassword = ConvertTo-SecureString 'Separate_SA_51!' -AsPlainText -Force
        $result = Invoke-HyperVLabUnattendedProvision -RunId $RunId -AdministratorPassword $password -SqlSaPassword $saPassword -PasswordSource generated `
            -Region 'de-AT' -SystemLocale 'de-AT' -UiLanguage 'de-DE' -InputLocale '0C07:00000407' -TimeZone 'Central Europe Standard Time' -StateRoot $Root
        [PSCustomObject]@{ Result = $result; SqlSaPasswordLength = $script:capturedSqlSaPasswordLength; ExpectedSaPasswordLength = $saPassword.Length }
    } $created.RunId $temporaryRoot
    $unattendedConnection = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $created.RunId) 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
    $unattendedSecret = Join-Path (Join-Path (Join-Path (Join-Path $temporaryRoot 'runs') $created.RunId) 'secrets') 'guest-administrator-password.secret'
    Add-CheckResult -Name 'Prepared-Image-Klon injiziert OOBE nur in die Child-VHDX und speichert das Gastpasswort DPAPI-geschützt' -Success (
        $unattended.Result.OobeState -eq 'COMPLETED' -and
        $unattended.SqlSaPasswordLength -eq $unattended.ExpectedSaPasswordLength -and
        $unattended.Result.HostSqlAccess.ConnectionString -match '172\.28\.0\.58,1433' -and
        $unattendedConnection.instances[0].oobeAutomation.passwordSource -eq 'generated' -and
        $unattendedConnection.instances[0].oobeAutomation.region -eq 'de-AT' -and
        $unattendedConnection.instances[0].oobeAutomation.systemLocale -eq 'de-AT' -and
        $unattendedConnection.instances[0].oobeAutomation.uiLanguage -eq 'de-DE' -and
        $unattendedConnection.instances[0].oobeAutomation.inputLocale -eq '0C07:00000407' -and
        $unattendedConnection.instances[0].oobeAutomation.timeZone -eq 'Central Europe Standard Time' -and
        $unattendedConnection.instances[0].oobeAutomation.answerMedia -eq 'guest-scrubbed' -and
        $unattendedConnection.instances[0].oobeAutomation.networkBootstrap -eq 'lab-winrm-v1' -and
        $unattendedConnection.instances[0].oobeAutomation.labAddress -match '^172\.28\.0\.' -and
        (Test-Path -LiteralPath $unattendedSecret) -and
        (Get-Content -LiteralPath $unattendedSecret -Raw) -notmatch 'Generated_Administrator_42!'
    )
    $transientSqlAccess = & $module {
        $password = ConvertTo-SecureString 'Generated_Temporary_SA_42!' -AsPlainText -Force
        New-HyperVTransientGeneratedSqlAccess `
            -HostSqlAccess ([PSCustomObject]@{
                ConnectionString = 'Server=172.28.0.58,1433;Database=master;User ID=sa;Password=<SQL-SA-Passwort>;Encrypt=True;TrustServerCertificate=True;'
            }) `
            -SqlSaPassword $password `
            -Generated
    }
    $explicitSqlAccess = & $module {
        $password = ConvertTo-SecureString 'Explicit_SA_42!' -AsPlainText -Force
        New-HyperVTransientGeneratedSqlAccess -HostSqlAccess $null -SqlSaPassword $password
    }
    Add-CheckResult -Name 'Generiertes SA-Passwort erscheint nur flüchtig als kopierfertige Connection' -Success (
        $transientSqlAccess.transient -and
        $transientSqlAccess.password -eq 'Generated_Temporary_SA_42!' -and
        $transientSqlAccess.connectionString -match 'Password="Generated_Temporary_SA_42!";' -and
        -not $explicitSqlAccess
    )
    $regionGeoIds = & $module {
        [PSCustomObject]@{
            Germany = Resolve-HyperVLocaleGeoId -Region 'DE'
            Austria = Resolve-HyperVLocaleGeoId -Region 'de-AT'
        }
    }
    Add-CheckResult -Name 'Regionsangaben unterstützen Länder- und Locale-Formate ohne Deutschland-Fallback' -Success (
        $regionGeoIds.Germany -eq ([System.Globalization.RegionInfo]::new('DE')).GeoId -and
        $regionGeoIds.Austria -eq ([System.Globalization.RegionInfo]::new('AT')).GeoId -and
        $regionGeoIds.Austria -ne $regionGeoIds.Germany
    )
    $environmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\HyperVLabEnvironment.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'SQL CompleteImage wertet den Gast-Exit-Code als Integer aus' -Success (
        $environmentText -match '\$exitCode = \[int\]\$process\.ExitCode' -and
        $environmentText -match '\$exitCode -ne 0 -and \$exitCode -ne 3010'
    )
    Add-CheckResult -Name 'Unattended Hyper-V-Provisionierung initialisiert freie Gast-Drives über den stabilen Providerpfad' -Success (
        $environmentText -match 'Initialize-HyperVWindowsGuestDrives' -and
        $environmentText -match 'additionalDrives'
    )
    $runtimeName = & $module { Get-HyperVLabRuntimeName -LabName 'Mein SQL Lab' -RunId '12345678-0000-0000-0000-000000000000' }
    Add-CheckResult -Name 'Hyper-V-Runtime-Name zeigt Projektnamen und eindeutiges Run-Präfix' -Success ($runtimeName -eq 'Mein SQL Lab-12345678')
    $reconciledVm = & $module {
        param($Root)
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Reconcile'; workflowKind = 'hyperv-lab' }
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{ instances = @([PSCustomObject]@{ id = 'primary'; provider = 'hyperv'; vmName = 'alter-name'; vmId = 'old-id' }) })
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'aktueller-name'; VMId = 'current-id'; State = 'Running' } }
        $lab = Get-HyperVLabWorkflowRun -RunId $run.RunId -StateRoot $Root
        [PSCustomObject]@{ VMName = $lab.Instance.vmName; VMId = $lab.Instance.vmId }
    } $temporaryRoot
    Add-CheckResult -Name 'Hyper-V löst veraltete VM-Namen über Run- und Scope-Identity auf' -Success ($reconciledVm.VMName -eq 'aktueller-name' -and $reconciledVm.VMId -eq 'current-id')
    $containerRename = & $module {
        param($Root)
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Alter Name' } -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $oldName = 'alter-name-primary-oldrunid'
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType container -ResourceId $oldName -Action remove -Provider docker -ProviderSubRunId provider-docker
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{ instances = @([PSCustomObject]@{ id = 'primary'; provider = 'docker'; containerId = 'mock-container-id'; containerName = $oldName }) })
        function docker { param($Verb, $ContainerId, $NewName) $global:LASTEXITCODE = 0 }
        $result = Rename-ContainerLabEnvironment -RunId $run.RunId -DisplayName 'Neuer Name' -StateRoot $Root
        $secondResult = Rename-ContainerLabEnvironment -RunId $run.RunId -DisplayName 'Noch Neuer' -StateRoot $Root
        $connection = Get-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Raw | ConvertFrom-Json -Depth 10
        $plan = Get-Content -LiteralPath (Join-Path $run.RunDir 'cleanup-plan.json') -Raw | ConvertFrom-Json -Depth 10
        $state = Get-LabRunState -RunId $run.RunId -StateRoot $Root
        [PSCustomObject]@{ Result = $result; SecondResult = $secondResult; Name = $connection.instances[0].containerName; CleanupName = $plan.steps[0].resourceId; NameHistory = @($state.metadata.nameHistory) }
    } $temporaryRoot
    Add-CheckResult -Name 'Container-Umbenennung aktualisiert Runtime, Verbindung und Cleanup-Plan gemeinsam' -Success (
        $containerRename.Result.RuntimeRenamed -and
        $containerRename.SecondResult.RuntimeRenamed -and
        $containerRename.Name -match '^noch-neuer-primary-[a-f0-9]{8}$' -and
        $containerRename.CleanupName -eq $containerRename.Name -and
        $containerRename.NameHistory.Count -eq 2
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
        function Resolve-LabHyperVNetwork { [PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' } }
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
        # Der Test verifiziert nur die Delegation. Er darf auf Linux nicht
        # durch die echte Hyper-V-Discovery (Get-VM) vom Host abhängen.
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Off' } }
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Running'; Exists = $true } }
        Start-HyperVLabEnvironment -RunId $RunId -StateRoot $Root
    } $created.RunId $temporaryRoot
    $runningState = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Lab-Start setzt VM- und Run-State zustandsgeführt' -Success ($started.State -eq 'Running' -and $runningState.state -eq 'RUNNING')

    $stopped = & $module {
        param($RunId, $Root)
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Running' } }
        function Stop-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Off'; Exists = $true } }
        Stop-HyperVLabEnvironment -RunId $RunId -StateRoot $Root
    } $created.RunId $temporaryRoot
    $stoppedState = & $module { param($RunId, $Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Hyper-V-Lab-Stopp bewahrt den Run und setzt STOPPED' -Success ($stopped.State -eq 'Off' -and $stoppedState.state -eq 'STOPPED')

    $genericStart = & $module {
        param($RunId, $Root)
        function Get-LabStateRoot { $Root }
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Off' } }
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Running'; Exists = $true } }
        Start-SqlServerLab -RunId $RunId
    } $created.RunId $temporaryRoot
    $genericStop = & $module {
        param($RunId, $Root)
        function Get-LabStateRoot { $Root }
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Running' } }
        function Stop-HyperVInstance { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; State = 'Off'; Exists = $true } }
        Stop-SqlServerLab -RunId $RunId -Force
    } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Generische Start- und Stoppaktionen delegieren Hyper-V-Labs niemals an Docker oder Podman' -Success (
        $genericStart.State -eq 'Running' -and $genericStop.State -eq 'Off'
    )

    $reconciledRuntimeState = & $module {
        param($RunId, $Root)
        function Get-LabRunRuntimeStatus { [PSCustomObject]@{ State = 'RUNNING'; Source = 'mock'; Instances = @() } }
        $run = Get-LabRunState -RunId $RunId -StateRoot $Root
        (Sync-LabRunRuntimeState -Run $run -StateRoot $Root).Run.state
    } $created.RunId $temporaryRoot
    Add-CheckResult -Name 'Live-Runtime-Status korrigiert einen abweichenden gespeicherten Workflow-Status' -Success ($reconciledRuntimeState -eq 'RUNNING')

    $inspected = & $module {
        param($RunId, $Root)
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Running' } }
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
        function Get-HyperVLabVMs { [PSCustomObject]@{ VMName = 'sql-lab-primary-mock'; VMId = 'mock-vm-id'; State = 'Off' } }
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



