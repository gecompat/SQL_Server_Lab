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
        -Success ($metadata.runtimeStatus -eq 'guest-drive-initialization-orchestration' -and $metadata.sqlProvisioning -eq $false)
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
        'Invoke-HyperVPowerShellDirect',
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
        function Set-VM { param($VM,$Notes,$ErrorAction); $script:CapturedGuestDriveNotes = $Notes }
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
