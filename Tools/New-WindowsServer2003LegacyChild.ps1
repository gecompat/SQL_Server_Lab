#Requires -Version 7.2
<#
.SYNOPSIS
Erzeugt einen Windows-Server-2003-Evaluation-Child für das isolierte Legacy-Lab.

.DESCRIPTION
Das Skript prüft ein versiegeltes, schreibgeschütztes
`LEGACY_TEMPLATE_SEALED`-Parent und erzeugt daraus eine Differencing-VHDX sowie
eine Hyper-V-Generation-1-VM. Der Evaluation Product Key wird ausschließlich
zur Laufzeit aus `I386\UNATTEND.TXT` der hashgebundenen originalen
Evaluation-ISO gelesen und in `C:\Sysprep\sysprep.inf` des Childs geschrieben.

Der Key wird weder ausgegeben noch in das Repository, das Parent oder ein
Manifest übernommen. Deutsch (`0407:00000407`) wird in Sysprep festgelegt und
vom nachfolgenden Gast-WMI-Schritt für die Anmeldemaske verifiziert. Ein
angegebenes Administrator-Credential führt Mini-Setup auch ohne
Aktivierungsversuch vollständig unbeaufsichtigt aus.
Mit `ActivateOnline` versucht das Skript zusätzlich die offizielle
Evaluation-Aktivierung über eine temporäre Legacy-NIC und akzeptiert nur ein
verifiziert aktives Ergebnis.

.PARAMETER VmName
Eindeutiger Name der neuen Hyper-V-VM.

.PARAMETER VmRoot
Leeres oder noch nicht vorhandenes Zielverzeichnis für VM und Child-VHDX.

.PARAMETER ParentVhdPath
Pfad zur schreibgeschützten, versiegelten Windows-Server-2003-Parent-VHDX.

.PARAMETER EvaluationIsoPath
Pfad zur originalen Windows Server 2003 Enterprise Evaluation ISO.

.PARAMETER SwitchName
Name des bereits vorhandenen isolierten internen Hyper-V-Switches.

.PARAMETER IntegrationServicesIsoPath
Optionaler Pfad zur vorher verifizierten Hyper-V-Integrations-DVD. Sie wird
am neuen Child eingelegt und nach dem unbeaufsichtigten Mini-Setup über
`GuiRunOnce` installiert.

.PARAMETER ExpectedEvaluationIsoSha256
Erwarteter SHA-256 der originalen Evaluation-ISO.

.PARAMETER AdministratorCredential
Das bereits im versiegelten Parent gesetzte lokale Administrator-Credential.
Windows Server 2003 kann ein nicht leeres Parent-Kennwort über Sysprep nicht
ändern. Das Credential ermöglicht AutoLogon und wird nur vorübergehend im
Child-Antwortsatz verwendet.

.PARAMETER ActivateOnline
Führt Mini-Setup aus, versucht die Evaluation-Aktivierung über einen temporären
Internetadapter und verifiziert das Ergebnis fail-closed.

.PARAMETER ActivationSwitchName
Vorhandener nicht-privater Switch mit DHCP und Internet-Egress. Er wird nur
während der Aktivierung an eine temporäre Legacy-NIC gebunden.

.PARAMETER Start
Startet die VM nach erfolgreicher Erstellung.

.PARAMETER ShowHelp
Zeigt diese Hilfe und beendet das Skript ohne Mutation.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('h', 'help', '?')]
    [switch] $ShowHelp,

    [ValidateNotNullOrEmpty()]
    [string] $VmName,

    [ValidateNotNullOrEmpty()]
    [string] $VmRoot,

    [ValidateNotNullOrEmpty()]
    [string] $ParentVhdPath,

    [ValidateNotNullOrEmpty()]
    [string] $EvaluationIsoPath,

    [ValidateNotNullOrEmpty()]
    [string] $SwitchName,

    [string] $IntegrationServicesIsoPath,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $ExpectedEvaluationIsoSha256 = '42c32c7f21609865c61d4b1e34f3fccf28e6f6d76fb3902bea7f50f98d25eed4',

    [ValidateRange(1, 4)]
    [int] $ProcessorCount = 1,

    [ValidateRange(536870912, 4294967296)]
    [UInt64] $MemoryStartupBytes = 2GB,

    [PSCredential] $AdministratorCredential,

    [switch] $ActivateOnline,

    [ValidateNotNullOrEmpty()]
    [string] $ActivationSwitchName = 'Default Switch',

    [switch] $Start,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $RemainingArgs
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$requiredArguments = [ordered]@{
    VmName = $VmName
    VmRoot = $VmRoot
    ParentVhdPath = $ParentVhdPath
    EvaluationIsoPath = $EvaluationIsoPath
    SwitchName = $SwitchName
}
$missingArguments = @($requiredArguments.GetEnumerator() | Where-Object {
    [string]::IsNullOrWhiteSpace([string] $_.Value)
} | ForEach-Object Key)
if ($missingArguments.Count -gt 0) {
    throw "WS2003_CHILD_ARGUMENT_REQUIRED: $($missingArguments -join ', ')"
}
if ($ActivateOnline -and -not $AdministratorCredential) {
    throw 'WS2003_CHILD_ADMINISTRATOR_CREDENTIAL_REQUIRED'
}
if ($AdministratorCredential -and
    [string] $AdministratorCredential.GetNetworkCredential().UserName -ne 'Administrator') {
    throw 'WS2003_CHILD_ADMINISTRATOR_REQUIRED: Erwartet wird das lokale Administrator-Credential.'
}

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$resolvedParentVhd = (Resolve-Path -LiteralPath $ParentVhdPath).Path
$resolvedEvaluationIso = (Resolve-Path -LiteralPath $EvaluationIsoPath).Path
$resolvedIntegrationServicesIso = if ([string]::IsNullOrWhiteSpace($IntegrationServicesIsoPath)) {
    $null
}
else {
    (Resolve-Path -LiteralPath $IntegrationServicesIsoPath).Path
}
$resolvedVmRoot = [IO.Path]::GetFullPath($VmRoot).TrimEnd('\')
$childVhdPath = Join-Path $resolvedVmRoot 'os.vhdx'
$parentManifestPath = "$resolvedParentVhd.manifest.json"

if ((Split-Path -Leaf $resolvedVmRoot) -ne $VmName) {
    throw 'WS2003_CHILD_ROOT_SCOPE_INVALID: Der letzte Bestandteil von VmRoot muss exakt VmName entsprechen.'
}

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "WS2003_CHILD_VM_EXISTS: $VmName"
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "WS2003_CHILD_SWITCH_NOT_FOUND: $SwitchName"
}
if ($ActivateOnline) {
    $activationSwitch = Get-VMSwitch -Name $ActivationSwitchName -ErrorAction SilentlyContinue
    if (-not $activationSwitch) {
        throw "WS2003_CHILD_ACTIVATION_SWITCH_NOT_FOUND: $ActivationSwitchName"
    }
    if ([string] $activationSwitch.SwitchType -eq 'Private') {
        throw 'WS2003_CHILD_ACTIVATION_SWITCH_PRIVATE: Aktivierung benötigt DHCP und Internet-Egress.'
    }
}
if (Test-Path -LiteralPath $resolvedVmRoot) {
    if (-not (Test-Path -LiteralPath $resolvedVmRoot -PathType Container)) {
        throw "WS2003_CHILD_ROOT_NOT_DIRECTORY: $resolvedVmRoot"
    }
    if (@(Get-ChildItem -LiteralPath $resolvedVmRoot -Force).Count -gt 0) {
        throw "WS2003_CHILD_ROOT_NOT_EMPTY: $resolvedVmRoot"
    }
}
if (-not (Test-Path -LiteralPath $parentManifestPath -PathType Leaf)) {
    throw "WS2003_CHILD_PARENT_MANIFEST_MISSING: $parentManifestPath"
}

$parentManifest = Get-Content -LiteralPath $parentManifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 20
if ([string] $parentManifest.state -ne 'LEGACY_TEMPLATE_SEALED' -or
    -not [bool] $parentManifest.vhd.immutable -or
    [int] $parentManifest.hyperV.generation -ne 1 -or
    [string] $parentManifest.operatingSystem.architecture -ne 'x86') {
    throw 'WS2003_CHILD_PARENT_MANIFEST_INVALID: Parent ist keine versiegelte x86-/Generation-1-Legacy-Vorlage.'
}
if (-not (Get-Item -LiteralPath $resolvedParentVhd).IsReadOnly) {
    throw "WS2003_CHILD_PARENT_NOT_READ_ONLY: $resolvedParentVhd"
}

$expectedParentSha256 = ([string] $parentManifest.vhd.sha256).ToLowerInvariant()
if ($expectedParentSha256 -notmatch '^[a-f0-9]{64}$') {
    throw 'WS2003_CHILD_PARENT_HASH_MISSING: Im Parent-Manifest fehlt ein gültiger SHA-256.'
}
$actualParentSha256 = (Get-FileHash -LiteralPath $resolvedParentVhd -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualParentSha256 -ne $expectedParentSha256) {
    throw "WS2003_CHILD_PARENT_HASH_MISMATCH: erwartet $expectedParentSha256, erhalten $actualParentSha256"
}
$actualEvaluationIsoSha256 = (Get-FileHash -LiteralPath $resolvedEvaluationIso -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualEvaluationIsoSha256 -ne $ExpectedEvaluationIsoSha256.ToLowerInvariant()) {
    throw "WS2003_CHILD_EVALUATION_ISO_HASH_MISMATCH: erwartet $($ExpectedEvaluationIsoSha256.ToLowerInvariant()), erhalten $actualEvaluationIsoSha256"
}
if ($resolvedIntegrationServicesIso) {
    $integrationMediaVerifier = Join-Path $PSScriptRoot 'Test-WindowsServer2003HyperVIntegrationMedia.ps1'
    $null = & $integrationMediaVerifier -IsoPath $resolvedIntegrationServicesIso
}

if (-not $PSCmdlet.ShouldProcess($VmName, "Windows-Server-2003-Legacy-Child unter $resolvedVmRoot erzeugen")) {
    return [pscustomobject]@{
        Status = 'PLANNED'
        VmName = $VmName
        VmRoot = $resolvedVmRoot
        ChildVhdPath = $childVhdPath
        ParentVhdPath = $resolvedParentVhd
        EvaluationProductKeyWillBeInjected = $true
        IntegrationServicesIsoPath = $resolvedIntegrationServicesIso
        InputLocale = '0407:00000407'
        LogonKeyboardLayout = '00000407'
        MiniSetupUnattended = [bool] $AdministratorCredential
        ActivationWillBePerformed = $ActivateOnline.IsPresent
        ActivationSwitchName = if ($ActivateOnline) { $ActivationSwitchName } else { $null }
    }
}

$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = [Security.Principal.WindowsPrincipal]::new($windowsIdentity)
if (-not $windowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'WS2003_CHILD_REQUIRES_ELEVATED_RUNNER: Das lokale Schreiben der sysprep.inf benötigt Mount-VHD in einer erhöhten PowerShell-Sitzung.'
}

$evaluationProductKey = $null
$evaluationIsoMountedByThisRun = $false
$evaluationDiskImage = $null
$childVhdMounted = $false
$childDiskNumber = $null
$childPartitionNumber = $null
$temporaryMountPath = $null
$vmCreated = $false
$rootCreatedByThisRun = $false
$administratorPasswordPointer = [IntPtr]::Zero
$administratorPlainPassword = $null
$activationResult = $null
try {
    $evaluationDiskImage = Get-DiskImage -ImagePath $resolvedEvaluationIso -ErrorAction SilentlyContinue
    if (-not $evaluationDiskImage -or -not $evaluationDiskImage.Attached) {
        $evaluationDiskImage = Mount-DiskImage -ImagePath $resolvedEvaluationIso -PassThru
        $evaluationIsoMountedByThisRun = $true
    }
    $evaluationVolume = $evaluationDiskImage | Get-Volume | Select-Object -First 1
    if (-not $evaluationVolume.DriveLetter -or $evaluationVolume.FileSystemLabel -ne 'NRMEEVL_EN') {
        throw 'WS2003_CHILD_EVALUATION_ISO_VOLUME_INVALID: Volume NRMEEVL_EN wurde nicht gefunden.'
    }
    $unattendPath = Join-Path "$($evaluationVolume.DriveLetter):\" 'I386\UNATTEND.TXT'
    if (-not (Test-Path -LiteralPath $unattendPath -PathType Leaf)) {
        throw 'WS2003_CHILD_EVALUATION_UNATTEND_MISSING: I386\UNATTEND.TXT fehlt.'
    }
    $unattendText = Get-Content -LiteralPath $unattendPath -Raw -Encoding Default
    $keyMatches = [regex]::Matches(
        $unattendText,
        '(?im)^\s*ProductKey\s*=\s*["'']?([A-Z0-9]{5}(?:-[A-Z0-9]{5}){4})["'']?\s*$')
    if ($keyMatches.Count -ne 1) {
        throw "WS2003_CHILD_EVALUATION_KEY_INVALID: erwartet genau einen gültigen ProductKey-Eintrag, gefunden $($keyMatches.Count)."
    }
    $evaluationProductKey = $keyMatches[0].Groups[1].Value
    $unattendText = $null
    $keyMatches = $null

    if ($AdministratorCredential) {
        $administratorPasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $AdministratorCredential.Password)
        $administratorPlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $administratorPasswordPointer)
        if ([string]::IsNullOrEmpty($administratorPlainPassword)) {
            throw 'WS2003_CHILD_ADMINISTRATOR_PASSWORD_EMPTY'
        }
        if ($administratorPlainPassword.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) {
            throw 'WS2003_CHILD_ADMINISTRATOR_PASSWORD_UNATTEND_UNSAFE: Anführungszeichen und Zeilenumbrüche werden nicht unterstützt.'
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedVmRoot -PathType Container)) {
        New-Item -Path $resolvedVmRoot -ItemType Directory -Force | Out-Null
        $rootCreatedByThisRun = $true
    }
    New-VHD -Path $childVhdPath -ParentPath $resolvedParentVhd -Differencing | Out-Null

    $mountedChild = Mount-VHD -Path $childVhdPath -NoDriveLetter -Passthru
    $childVhdMounted = $true
    $childDisk = $mountedChild | Get-Disk
    $childDiskNumber = $childDisk.Number
    $childPartition = Get-Partition -DiskNumber $childDiskNumber |
        Where-Object { $_.Size -ge 1GB -and $_.Type -ne 'Reserved' } |
        Sort-Object Size -Descending |
        Select-Object -First 1
    if (-not $childPartition) {
        throw 'WS2003_CHILD_SYSTEM_PARTITION_NOT_FOUND: Keine beschreibbare Systempartition im Child gefunden.'
    }
    $childPartitionNumber = $childPartition.PartitionNumber
    $temporaryMountPath = Join-Path ([IO.Path]::GetTempPath()) `
        ('SqlServerLab-VhdMount-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $temporaryMountPath -ItemType Directory -Force | Out-Null
    $temporaryMountPath = $temporaryMountPath.TrimEnd('\') + '\'
    Add-PartitionAccessPath `
        -DiskNumber $childDiskNumber `
        -PartitionNumber $childPartitionNumber `
        -AccessPath $temporaryMountPath | Out-Null

    $childWindowsDirectory = Join-Path $temporaryMountPath 'Windows'
    if (-not (Test-Path -LiteralPath $childWindowsDirectory -PathType Container)) {
        throw 'WS2003_CHILD_WINDOWS_DIRECTORY_MISSING: Windows-Verzeichnis wurde im Child nicht gefunden.'
    }
    $childSysprepDirectory = Join-Path $temporaryMountPath 'Sysprep'
    if (-not (Test-Path -LiteralPath $childSysprepDirectory -PathType Container)) {
        New-Item -Path $childSysprepDirectory -ItemType Directory -Force | Out-Null
    }
    $firstBootDirectory = Join-Path $temporaryMountPath 'SQLServerLab'
    if (-not (Test-Path -LiteralPath $firstBootDirectory -PathType Container)) {
        New-Item -Path $firstBootDirectory -ItemType Directory -Force | Out-Null
    }
    $firstBootCommand = @'
@echo off
setlocal EnableExtensions
netsh.exe firewall set opmode disable >nul 2>&1
set HOTFIX_EXIT=0
set MSI_EXIT=0
if exist D:\support\x86\WindowsServer2003-KB943295-x86-ENU.exe D:\support\x86\WindowsServer2003-KB943295-x86-ENU.exe /quiet /norestart
if exist D:\support\x86\WindowsServer2003-KB943295-x86-ENU.exe set HOTFIX_EXIT=%ERRORLEVEL%
if exist D:\support\x86\Windows5.x-HyperVIntegrationServices-x86.msi msiexec.exe /i D:\support\x86\Windows5.x-HyperVIntegrationServices-x86.msi /qn /norestart
if exist D:\support\x86\Windows5.x-HyperVIntegrationServices-x86.msi set MSI_EXIT=%ERRORLEVEL%
>C:\SQLServerLab\first-boot.ini echo status=COMPLETED
>>C:\SQLServerLab\first-boot.ini echo hotfixExitCode=%HOTFIX_EXIT%
>>C:\SQLServerLab\first-boot.ini echo integrationServicesExitCode=%MSI_EXIT%
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $firstBootDirectory 'FirstBoot.cmd') `
        -Value $firstBootCommand -Encoding ascii -NoNewline
    $guiUnattended = @(
        'OEMSkipRegional=1'
        'OemSkipWelcome=1'
        'TimeZone=110'
    )
    if ($AdministratorCredential) {
        $guiUnattended += @(
            "AdminPassword=`"$administratorPlainPassword`""
            'EncryptedAdminPassword=No'
            'AutoLogon=Yes'
            'AutoLogonCount=1'
        )
    }
    $sysprepLines = @(
        '[Unattended]'
        'OemSkipEula=Yes'
        ''
        '[GuiUnattended]'
    ) + $guiUnattended + @(
        ''
        '[RegionalSettings]'
        'LanguageGroup=1'
        'InputLocale=0407:00000407'
        'SystemLocale=00000407'
        'UserLocale=00000407'
        ''
    )
    $sysprepLines += @(
        '[LicenseFilePrintData]'
        'AutoMode=PerServer'
        'AutoUsers=5'
        ''
        '[UserData]'
        "ProductKey=$evaluationProductKey"
        'FullName="SQL Server Lab"'
        'OrgName="SQL Server Lab"'
        'ComputerName=*'
        ''
        '[Identification]'
        'JoinWorkgroup=WORKGROUP'
        ''
        '[Networking]'
        'InstallDefaultComponents=Yes'
        ''
        '[GuiRunOnce]'
        'Command0="C:\SQLServerLab\FirstBoot.cmd"'
    )
    $sysprepInf = $sysprepLines -join "`r`n"
    Set-Content `
        -LiteralPath (Join-Path $childSysprepDirectory 'sysprep.inf') `
        -Value $sysprepInf `
        -Encoding ascii `
        -NoNewline
    $sysprepInf = $null
    $sysprepLines = $null
    $guiUnattended = $null
    $administratorPlainPassword = $null
    if ($administratorPasswordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($administratorPasswordPointer)
        $administratorPasswordPointer = [IntPtr]::Zero
    }

    if ($temporaryMountPath) {
        Remove-PartitionAccessPath `
            -DiskNumber $childDiskNumber `
            -PartitionNumber $childPartitionNumber `
            -AccessPath $temporaryMountPath | Out-Null
        Remove-Item -LiteralPath $temporaryMountPath.TrimEnd('\') -Force -ErrorAction SilentlyContinue
        $temporaryMountPath = $null
    }
    Dismount-VHD -Path $childVhdPath
    $childVhdMounted = $false

    New-VM `
        -Name $VmName `
        -Path $resolvedVmRoot `
        -Generation 1 `
        -MemoryStartupBytes $MemoryStartupBytes `
        -VHDPath $childVhdPath | Out-Null
    $vmCreated = $true
    if ($resolvedIntegrationServicesIso) {
        Set-VMDvdDrive -VMName $VmName -Path $resolvedIntegrationServicesIso
    }
    Set-VM `
        -Name $VmName `
        -StaticMemory `
        -MemoryStartupBytes $MemoryStartupBytes `
        -AutomaticCheckpointsEnabled $false `
        -CheckpointType Standard `
        -Notes 'SQL Server Lab: isolated Windows Server 2003 Evaluation legacy child.'
    Set-VMProcessor -VMName $VmName -Count $ProcessorCount
    Get-VMNetworkAdapter -VMName $VmName | Remove-VMNetworkAdapter
    Add-VMNetworkAdapter -VMName $VmName -IsLegacy $true -SwitchName $SwitchName

    Set-VMBios -VMName $VmName -StartupOrder @(
        [Microsoft.HyperV.PowerShell.BootDevice]::IDE
        [Microsoft.HyperV.PowerShell.BootDevice]::CD
        [Microsoft.HyperV.PowerShell.BootDevice]::LegacyNetworkAdapter
        [Microsoft.HyperV.PowerShell.BootDevice]::Floppy
    )

    if ($ActivateOnline) {
        $activationTool = Join-Path $PSScriptRoot 'Invoke-WindowsServer2003LegacyActivation.ps1'
        $activationResult = & $activationTool `
            -VmName $VmName `
            -ChildVhdPath $childVhdPath `
            -AdministratorCredential $AdministratorCredential `
            -ActivationSwitchName $ActivationSwitchName
        if ([string] $activationResult.Status -ne 'EVALUATION_ACTIVE') {
            throw 'WS2003_CHILD_ACTIVATION_POSTCONDITION_FAILED'
        }
    }

    if ($Start) {
        Start-VM -Name $VmName | Out-Null
    }

    $finalParentSha256 = (Get-FileHash -LiteralPath $resolvedParentVhd -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($finalParentSha256 -ne $expectedParentSha256) {
        throw 'WS2003_CHILD_PARENT_CHANGED: Parent-Hash hat sich während der Child-Erzeugung geändert.'
    }

    [pscustomobject]@{
        Status = if ($Start) { 'STARTED' } else { 'CREATED' }
        VmName = $VmName
        VmRoot = $resolvedVmRoot
        ChildVhdPath = $childVhdPath
        ParentVhdPath = $resolvedParentVhd
        ParentSha256 = $finalParentSha256
        EvaluationIsoSha256 = $actualEvaluationIsoSha256
        EvaluationProductKeyInjected = $true
        EvaluationProductKeyDisclosed = $false
        IntegrationServicesIsoPath = $resolvedIntegrationServicesIso
        InputLocale = '0407:00000407'
        LogonKeyboardLayout = '00000407'
        MiniSetupUnattended = [bool] $AdministratorCredential
        FirstBootBootstrap = [bool] $AdministratorCredential
        ActivationPerformed = $ActivateOnline.IsPresent
        EvaluationDaysRemaining = if ($activationResult) {
            [int] $activationResult.EvaluationDaysRemaining
        }
        else { $null }
        ActivationSwitchName = if ($ActivateOnline) { $ActivationSwitchName } else { $null }
        Generation = 1
        ProcessorCount = $ProcessorCount
        MemoryStartupBytes = $MemoryStartupBytes
        NetworkAdapter = 'Legacy Network Adapter'
        SwitchName = $SwitchName
    }
}
catch {
    if ($vmCreated -and (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
    }
    if ($childVhdMounted) {
        if ($temporaryMountPath -and $null -ne $childDiskNumber -and $null -ne $childPartitionNumber) {
            Remove-PartitionAccessPath `
                -DiskNumber $childDiskNumber `
                -PartitionNumber $childPartitionNumber `
                -AccessPath $temporaryMountPath `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $temporaryMountPath.TrimEnd('\') -Force -ErrorAction SilentlyContinue
            $temporaryMountPath = $null
        }
        Dismount-VHD -Path $childVhdPath -ErrorAction SilentlyContinue
        $childVhdMounted = $false
    }
    if (Test-Path -LiteralPath $childVhdPath -PathType Leaf) {
        Remove-Item -LiteralPath $childVhdPath -Force -ErrorAction SilentlyContinue
    }
    if ($rootCreatedByThisRun -and (Test-Path -LiteralPath $resolvedVmRoot -PathType Container) -and
        (Split-Path -Leaf $resolvedVmRoot) -eq $VmName) {
        [IO.Directory]::Delete($resolvedVmRoot, $true)
    }
    throw
}
finally {
    if ($temporaryMountPath -and $null -ne $childDiskNumber -and $null -ne $childPartitionNumber) {
        Remove-PartitionAccessPath `
            -DiskNumber $childDiskNumber `
            -PartitionNumber $childPartitionNumber `
            -AccessPath $temporaryMountPath `
            -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -LiteralPath $temporaryMountPath.TrimEnd('\') -Force -ErrorAction SilentlyContinue
    }
    if ($childVhdMounted) {
        Dismount-VHD -Path $childVhdPath -ErrorAction SilentlyContinue
    }
    if ($evaluationIsoMountedByThisRun -and $evaluationDiskImage) {
        Dismount-DiskImage -ImagePath $resolvedEvaluationIso -ErrorAction SilentlyContinue | Out-Null
    }
    $evaluationProductKey = $null
    $administratorPlainPassword = $null
    if ($administratorPasswordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($administratorPasswordPointer)
    }
}
