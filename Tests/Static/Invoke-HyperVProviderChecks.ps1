#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den statischen Vertrag der Hyper-V-Lifecycle-Grundlage.
.DESCRIPTION
    Validiert Metadaten, Funktionsoberflaeche, Parent-Integritaet, Generation 2,
    Secure Boot, zusätzliche VHDX, scopegebundenen Cleanup und die ausdrueckliche
    Grenze zur noch nicht implementierten SQL-Provisionierung ohne Hyper-V-
    Ressourcen zu aendern.
#>
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
        -Name 'SQL-Prepared-Image-Klonpfad ist getrennt vom allgemeinen Gastnachweis ausgewiesen' `
        -Success ($metadata.runtimeStatus -eq 'windows-specialization-sql-readiness-orchestration' -and $metadata.sqlProvisioning -eq $false -and $metadata.sqlProvisioningScope -eq 'prepared-image-clone-only' -and $metadata.limitations -contains 'no-real-windows-sql-e2e-evidence' -and $metadata.limitations -notcontains 'no-sql-complete-image-runtime')
    Add-CheckResult `
        -Name 'Runner-Labels sind capability-spezifisch' `
        -Success ((@($metadata.requirements.runnerLabels) -join ',') -eq 'self-hosted,SQL_Lab,Hyper-V')

    foreach ($functionName in @(
        'Test-HyperVAvailable',
        'Resolve-HyperVAdditionalDrivePlan',
        'New-HyperVInstance',
        'Get-HyperVInstanceStatus',
        'Start-HyperVInstance',
        'Stop-HyperVInstance',
        'Initialize-HyperVLabWinRmClient',
        'Invoke-HyperVWinRmFallback',
        'Invoke-HyperVPowerShellDirect',
        'Wait-HyperVPowerShellDirect',
        'Set-HyperVWindowsGuestSpecialization',
        'Wait-HyperVGuestSqlReady',
        'Initialize-HyperVWindowsGuestDrives',
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
        -Name 'Normale Lab-VMs deaktivieren automatische Hyper-V-Checkpoints' `
        -Text $provider `
        -Pattern 'Set-VM[^\r\n]+AutomaticCheckpointsEnabled\s+\$false'
    Add-TextContract `
        -Name 'Normale Lab-VMs erhalten einen begrenzten dynamischen Speicherbereich' `
        -Text $provider `
        -Pattern 'Math\]::Max\(\[double\]512MB,\s*\[double\]\$MemoryStartupBytes\s*/\s*2\)[\s\S]+Math\]::Min\(\[double\]1TB,\s*\[double\]\$MemoryStartupBytes\s*\*\s*2\)[\s\S]+Set-VMMemory[\s\S]+MaximumBytes\s+\$memoryMaximumBytes'
    Add-TextContract `
        -Name 'Reguläre Hyper-V-Labs verwenden den Projektnamen mit eindeutiger Run-ID' `
        -Text $provider `
        -Pattern 'LabName[\s\S]+\$vmName\s*=\s*if\s*\(\$LabName\)'
    Add-TextContract `
        -Name 'Zusatz-VHDX werden explizit per SCSI angebunden' `
        -Text $provider `
        -Pattern 'Add-VMHardDiskDrive[\s\S]+ControllerType\s+SCSI[\s\S]+ControllerNumber\s+0'
    Add-TextContract `
        -Name 'Zusatz-VHDX erhalten Cleanup vor ihrer Erstellung' `
        -Text $provider `
        -Pattern 'foreach\s*\(\$drive in \$additionalDrivePlan\)[\s\S]+Add-CleanupStep[\s\S]+foreach\s*\(\$drive in \$additionalDrivePlan\)[\s\S]+New-VHD'
    Add-TextContract `
        -Name 'Gast-Disk wird ueber VHD-Identifier statt Groesse zugeordnet' `
        -Text $provider `
        -Pattern 'Get-VHD[\s\S]+DiskIdentifier[\s\S]+Get-Disk[\s\S]+UniqueId'
    Add-TextContract `
        -Name 'Gastinitialisierung verwendet GPT, NTFS und explizite Allocation Unit' `
        -Text $provider `
        -Pattern 'Initialize-Disk[\s\S]+PartitionStyle\s+GPT[\s\S]+New-Partition[\s\S]+Format-Volume[\s\S]+FileSystem\s+NTFS[\s\S]+AllocationUnitSize'
    Add-TextContract `
        -Name 'Bestehende Volumes werden nur verifiziert und nicht neu formatiert' `
        -Text $provider `
        -Pattern "PartitionStyle\s+-eq\s+'RAW'[\s\S]+else\s*\{[\s\S]+GUEST_DRIVE_PARTITION_NOT_IDEMPOTENT"
    Add-TextContract `
        -Name 'Windows-Specialization benennt den Gast um und wartet nach Reboot auf Reconnect' `
        -Text $provider `
        -Pattern 'Rename-Computer[\s\S]+REBOOT_REQUIRED[\s\S]+shutdown\.exe[\s\S]+Wait-HyperVPowerShellDirect'
    Add-TextContract `
        -Name 'Readiness kann den Labnetz-Bootstrap idempotent ueber PowerShell Direct nachholen' `
        -Text $provider `
        -Pattern 'GuestInitializationScript[\s\S]+guestInitializationComplete[\s\S]+ScriptBlock \(\[scriptblock\]::Create\(\$GuestInitializationScript\)\)'
    Add-TextContract `
        -Name 'Gastremoting faellt nur auf eine temporaere Lab-WinRM-Vertrauensbeziehung zurueck' `
        -Text $provider `
        -Pattern 'TrustedHosts[\s\S]+Invoke-Command\s+-ComputerName[\s\S]+finally[\s\S]+originalTrustedHosts'
    Add-TextContract `
        -Name 'WinRM-Fallback startet nur den Host-Client und erstellt keinen Host-Listener' `
        -Text $provider `
        -Pattern 'Start-Service\s+-Name\s+WinRM[\s\S]+HYPERV_LAB_WINRM_CLIENT_CONFIGURATION_UNAVAILABLE'
    Add-TextContract `
        -Name 'SQL-Readiness prueft Dienst, Version und alle Systemdatenbanken im Gast' `
        -Text $provider `
        -Pattern 'System\.Data\.SqlClient[\s\S]+Get-Service[\s\S]+ProductMajorVersion[\s\S]+OnlineSystemDatabases[\s\S]+SQL_READY_RUN'
    Add-TextContract `
        -Name 'Status trennt historische SQL-Evidenz von aktueller Live-Bereitschaft' `
        -Text $provider `
        -Pattern 'LastSqlReadinessStatus[\s\S]+LastSqlReadinessAt[\s\S]+SqlReady\s*=\s*\$false'
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
        $additionalPath = Join-Path ([System.IO.Path]::GetTempPath()) 'synthetic-data.vhdx'
        $notes = ConvertTo-HyperVLabNotes `
            -RunId '00000000-0000-0000-0000-000000000001' `
            -ScopeId '00000000-0000-0000-0000-000000000002' `
            -InstanceId 'static-check' `
            -ChildVhdxPath (Join-Path ([System.IO.Path]::GetTempPath()) 'synthetic.vhdx') `
            -AdditionalDrives @(
                [PSCustomObject]@{
                    Id = 'data'; Role = 'sqlData'; SizeBytes = 64MB; VhdType = 'dynamic'
                    Path = $additionalPath; DiskIdentifier = '11111111-1111-1111-1111-111111111111'
                    GuestPath = 'D:\SqlData'; DriveLetter = 'D'; FileSystem = 'NTFS'
                    AllocationUnitKB = 64; VolumeLabel = 'SQLLAB_DATA'
                }
            )
        ConvertFrom-HyperVLabNotes -Notes $notes
    }
    Add-CheckResult `
        -Name 'VM-Notizen bewahren Run-, Scope- und Instanzidentitaet' `
        -Success (
            $roundTrip.runId -eq '00000000-0000-0000-0000-000000000001' -and
            $roundTrip.scopeId -eq '00000000-0000-0000-0000-000000000002' -and
            $roundTrip.instanceId -eq 'static-check' -and
            @($roundTrip.additionalVhdxPaths).Count -eq 1 -and
            $roundTrip.additionalDrives[0].guestPath -eq 'D:\SqlData'
        )

    $driveContract = & $module {
        $runDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'sql-lab-hyperv-drive-static-run'
        $resourceRoot = Join-Path (Join-Path $runDirectory 'resources') 'hyperv'
        $plan = Resolve-HyperVAdditionalDrivePlan -RunDirectory $runDirectory `
            -ResourceRoot $resourceRoot -VMName 'sql-lab-static' -AdditionalDrives @(
                [PSCustomObject]@{ id = 'data'; role = 'sqlData'; sizeBytes = 64MB; vhdType = 'dynamic'; guestPath = 'D:\SqlData' },
                [PSCustomObject]@{ id = 'log'; role = 'sqlLog'; sizeBytes = 32MB; vhdType = 'fixed'; guestPath = 'L:\SqlLog' }
            )
        $duplicateRejected = $false
        try {
            $null = Resolve-HyperVAdditionalDrivePlan -RunDirectory $runDirectory `
                -ResourceRoot $resourceRoot -VMName 'sql-lab-static' -AdditionalDrives @(
                    [PSCustomObject]@{ id = 'data'; role = 'sqlData'; sizeBytes = 32MB },
                    [PSCustomObject]@{ id = 'DATA'; role = 'sqlLog'; sizeBytes = 32MB }
                )
        }
        catch { $duplicateRejected = $_.Exception.Message -like 'HYPERV_ADDITIONAL_DRIVE_ID_DUPLICATE*' }
        [PSCustomObject]@{ Plan = $plan; DuplicateRejected = $duplicateRejected }
    }
    Add-CheckResult `
        -Name 'Drive-Plan validiert Rollen, Typen und IDs vor Mutation' `
        -Success (
            @($driveContract.Plan).Count -eq 2 -and
            $driveContract.Plan[0].Role -eq 'sqlData' -and
            $driveContract.Plan[0].DriveLetter -eq 'D' -and
            $driveContract.Plan[0].AllocationUnitKB -eq 64 -and
            $driveContract.Plan[1].VhdType -eq 'fixed' -and
            $driveContract.DuplicateRejected
        )

    $testUser = 'sql-lab-guest-drive-test'
    $testPassword = 'NotPersisted_2!'
    $testCredential = [PSCredential]::new(
        $testUser,
        (ConvertTo-SecureString $testPassword -AsPlainText -Force)
    )
    $guestContract = & $module {
        param($Credential)
        $identity = [PSCustomObject]@{
            contractVersion = '0.3'; provider = 'hyperv'; runId = 'run-static'; scopeId = 'scope-static'
            instanceId = 'static'; childVhdxPath = 'C:\synthetic\os.vhdx'
            additionalVhdxPaths = @('C:\synthetic\data.vhdx')
            additionalDrives = @([PSCustomObject]@{
                id = 'data'; role = 'sqlData'; sizeBytes = 64MB; vhdType = 'dynamic'
                path = 'C:\synthetic\data.vhdx'; diskIdentifier = '22222222-2222-2222-2222-222222222222'
                guestPath = 'D:\SqlData'; driveLetter = 'D'; fileSystem = 'NTFS'
                allocationUnitKB = 64; volumeLabel = 'SQLLAB_DATA'
            })
        }
        $vm = [PSCustomObject]@{ State = 'Running'; Notes = '' }
        $script:CapturedGuestDriveNotes = ''
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = $vm; Identity = $identity } }
        function Invoke-HyperVPowerShellDirect {
            [PSCustomObject]@{
                id = 'data'; diskIdentifier = '22222222-2222-2222-2222-222222222222'
                diskNumber = 1; guestPath = 'D:\SqlData'; driveLetter = 'D'; fileSystem = 'NTFS'
                allocationUnitSize = 65536; volumeLabel = 'SQLLAB_DATA'; status = 'INITIALIZED'
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        function Set-VM { param($VM,$Notes,$AutomaticCheckpointsEnabled,$ErrorAction); $script:CapturedGuestDriveNotes = $Notes }
        $result = Initialize-HyperVWindowsGuestDrives -VMName 'sql-lab-static' `
            -ExpectedRunId 'run-static' -ExpectedScopeId 'scope-static' -Credential $Credential
        [PSCustomObject]@{ Result = $result; Notes = $script:CapturedGuestDriveNotes }
    } $testCredential
    Add-CheckResult `
        -Name 'PowerShell-Direct-Receipt persistiert GUEST_DRIVES_READY ohne Credentials' `
        -Success (
            $guestContract.Result.Status -eq 'GUEST_DRIVES_READY' -and
            $guestContract.Result.Drives[0].guestPath -eq 'D:\SqlData' -and
            $guestContract.Notes -match 'guestDriveInitialization' -and
            $guestContract.Notes -notmatch [regex]::Escape($testUser) -and
            $guestContract.Notes -notmatch [regex]::Escape($testPassword)
        )
    Add-CheckResult `
        -Name 'Daten-VHDX-Initialisierung bleibt mit Windows PowerShell 5.1 im Gast kompatibel' `
        -Success (
            $provider.Contains('$DrivePlanJson | ConvertFrom-Json)') -and
            -not $provider.Contains('$DrivePlanJson | ConvertFrom-Json -Depth')
        )
    Add-CheckResult `
        -Name 'Frische Daten-VHDX nutzt nur bei genau einer RAW-Nicht-Systemdisk einen sicheren Fallback' `
        -Success (
            $provider -match '\$matchingMethod = ''single-raw-disk-fallback''' -and
            $provider -match '\$rawCandidates\.Count -eq 1' -and
            $provider -match '\[string\]\$_.PartitionStyle -eq ''RAW''' -and
            $provider -match 'GUEST_DISK_IDENTIFIER_MATCH_COUNT'
        )
    Add-CheckResult `
        -Name 'Gast-Datendisk verwendet bei belegtem Wunschbuchstaben einen freien Buchstaben und persistiert ihn' `
        -Success (
            $provider -match "@\('S','T','U','V','W','X','Y','Z'" -and
            $provider -match 'GUEST_DRIVE_LETTER_NO_FREE_DATA_LETTER' -and
            $provider -match 'NotePropertyName guestPath' -and
            $provider -match 'Der Buchstabe eines Host-Data-Roots hat keinerlei'
        )
    Add-CheckResult `
        -Name 'Hyper-V-Cleanup bewahrt externe Data-Root-VHDX und entfernt nur run-lokale VHDX' `
        -Success (
            $provider -match 'HYPERV_EXTERNAL_VHDX_REQUIRES_PRESERVE' -and
            $provider -match 'Eine optionale Data-Root-VHDX gehört absichtlich nicht zum Run-Verzeichnis' -and
            $provider -match '\$childVhdxPath = \[string\]\$managed\.Identity\.childVhdxPath'
        )

    $specializationUser = 'sql-lab-specialization-test'
    $specializationPassword = 'NotPersisted_Specialization_3!'
    $specializationCredential = [PSCredential]::new(
        $specializationUser,
        (ConvertTo-SecureString $specializationPassword -AsPlainText -Force)
    )
    $specializationContract = & $module {
        param($Credential)
        $identity = [PSCustomObject]@{
            contractVersion = '0.4'; provider = 'hyperv'; runId = 'run-specialize'; scopeId = 'scope-specialize'
            instanceId = 'specialize'; childVhdxPath = 'C:\synthetic\os.vhdx'
            additionalVhdxPaths = @(); additionalDrives = @()
        }
        $vm = [PSCustomObject]@{ State = 'Running'; Notes = '' }
        $script:CapturedSpecializationNotes = ''
        $script:SpecializationDirectCall = 0
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = $vm; Identity = $identity } }
        function Invoke-HyperVPowerShellDirect {
            $script:SpecializationDirectCall++
            switch ($script:SpecializationDirectCall) {
                1 { [PSCustomObject]@{ computerName = 'TEMPLATE'; pendingComputerName = 'TEMPLATE'; imageState = 'IMAGE_STATE_COMPLETE' } }
                2 { 'RENAME_APPLIED' }
                3 { 'RESTART_REQUESTED' }
                default { [PSCustomObject]@{ computerName = 'SQLLAB01'; imageState = 'IMAGE_STATE_COMPLETE'; windowsVersion = '10.0.26100.0' } }
            }
        }
        function Wait-HyperVPowerShellDirect {
            [PSCustomObject]@{ Ready = $true; ComputerName = 'SQLLAB01'; ImageState = 'IMAGE_STATE_COMPLETE' }
        }
        function Set-VM { param($VM,$Notes,$AutomaticCheckpointsEnabled,$ErrorAction); $script:CapturedSpecializationNotes = $Notes }
        $result = Set-HyperVWindowsGuestSpecialization `
            -VMName 'sql-lab-specialize' `
            -ExpectedRunId 'run-specialize' `
            -ExpectedScopeId 'scope-specialize' `
            -Credential $Credential `
            -ComputerName 'sqllab01'
        [PSCustomObject]@{ Result = $result; Notes = $script:CapturedSpecializationNotes }
    } $specializationCredential
    Add-CheckResult `
        -Name 'Windows-Specialization persistiert nur sanitierte Reboot- und Postcondition-Evidenz' `
        -Success (
            $specializationContract.Result.Status -eq 'WINDOWS_SPECIALIZED' -and
            $specializationContract.Result.ComputerName -eq 'SQLLAB01' -and
            $specializationContract.Result.Rebooted -and
            $specializationContract.Notes -match 'WINDOWS_SPECIALIZED' -and
            $specializationContract.Notes -notmatch [regex]::Escape($specializationUser) -and
            $specializationContract.Notes -notmatch [regex]::Escape($specializationPassword)
        )

    $idempotentSpecialization = & $module {
        param($Credential)
        $identity = [PSCustomObject]@{
            contractVersion = '0.5'; provider = 'hyperv'; runId = 'run-specialize'; scopeId = 'scope-specialize'
            instanceId = 'specialize'; childVhdxPath = 'C:\synthetic\os.vhdx'
            additionalVhdxPaths = @(); additionalDrives = @()
            windowsSpecialization = [PSCustomObject]@{ status = 'WINDOWS_SPECIALIZED'; computerName = 'SQLLAB01' }
        }
        $vm = [PSCustomObject]@{ State = 'Running'; Notes = '' }
        $script:IdempotentDirectCall = 0
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = $vm; Identity = $identity } }
        function Invoke-HyperVPowerShellDirect {
            $script:IdempotentDirectCall++
            if ($script:IdempotentDirectCall -eq 1) {
                [PSCustomObject]@{ computerName = 'SQLLAB01'; pendingComputerName = 'SQLLAB01'; imageState = 'IMAGE_STATE_COMPLETE' }
            }
            else {
                [PSCustomObject]@{ computerName = 'SQLLAB01'; imageState = 'IMAGE_STATE_COMPLETE'; windowsVersion = '10.0.26100.0' }
            }
        }
        function Wait-HyperVPowerShellDirect { throw 'Reconnect darf im idempotenten Pfad nicht aufgerufen werden.' }
        function Set-VM { param($VM,$Notes,$AutomaticCheckpointsEnabled,$ErrorAction) }
        Set-HyperVWindowsGuestSpecialization `
            -VMName 'sql-lab-specialize' `
            -ExpectedRunId 'run-specialize' `
            -ExpectedScopeId 'scope-specialize' `
            -Credential $Credential `
            -ComputerName 'SQLLAB01'
    } $specializationCredential
    Add-CheckResult `
        -Name 'Bereits spezialisierter Windows-Gast wird ohne weiteren Reboot verifiziert' `
        -Success (
            $idempotentSpecialization.Status -eq 'WINDOWS_SPECIALIZED' -and
            -not $idempotentSpecialization.Rebooted
        )

    $sqlSaPasswordText = 'NotPersisted_SqlReadiness_4!'
    $sqlSaPassword = ConvertTo-SecureString $sqlSaPasswordText -AsPlainText -Force
    $sqlReadinessContract = & $module {
        param($Credential, $SaPassword)
        $identity = [PSCustomObject]@{
            contractVersion = '0.5'; provider = 'hyperv'; runId = 'run-sql'; scopeId = 'scope-sql'
            instanceId = 'sql'; childVhdxPath = 'C:\synthetic\os.vhdx'
            additionalVhdxPaths = @(); additionalDrives = @()
            windowsSpecialization = [PSCustomObject]@{ status = 'WINDOWS_SPECIALIZED'; computerName = 'SQLLAB01' }
        }
        $vm = [PSCustomObject]@{ State = 'Running'; Notes = '' }
        $script:CapturedSqlReadinessNotes = ''
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = $vm; Identity = $identity } }
        function Invoke-HyperVPowerShellDirect {
            [PSCustomObject]@{
                status = 'SQL_READY_RUN'; instanceName = 'MSSQLSERVER'; serviceName = 'MSSQLSERVER'
                majorVersion = 16; productVersion = '16.0.1000.6'; edition = 'Developer Edition'
                machineName = 'SQLLAB01'; sqlServiceName = 'MSSQLSERVER'; onlineSystemDatabases = 4
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        function Set-VM { param($VM,$Notes,$AutomaticCheckpointsEnabled,$ErrorAction); $script:CapturedSqlReadinessNotes = $Notes }
        $result = Wait-HyperVGuestSqlReady `
            -VMName 'sql-lab-sql' `
            -ExpectedRunId 'run-sql' `
            -ExpectedScopeId 'scope-sql' `
            -Credential $Credential `
            -SaPassword $SaPassword `
            -ExpectedMajorVersion 16
        [PSCustomObject]@{ Result = $result; Notes = $script:CapturedSqlReadinessNotes }
    } $specializationCredential $sqlSaPassword
    Add-CheckResult `
        -Name 'SQL-Readiness persistiert Versionsevidenz, aber weder Gast- noch SA-Credentials' `
        -Success (
            $sqlReadinessContract.Result.Ready -and
            $sqlReadinessContract.Result.Status -eq 'SQL_READY_RUN' -and
            $sqlReadinessContract.Result.MajorVersion -eq 16 -and
            $sqlReadinessContract.Notes -match 'SQL_READY_RUN' -and
            $sqlReadinessContract.Notes -notmatch [regex]::Escape($specializationPassword) -and
            $sqlReadinessContract.Notes -notmatch [regex]::Escape($sqlSaPasswordText)
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



