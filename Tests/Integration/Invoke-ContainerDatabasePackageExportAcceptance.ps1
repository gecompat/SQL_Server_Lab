#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den öffentlichen hashgebundenen Container-Paketexport.
.DESCRIPTION
    Erstellt einen isolierten Docker- oder Podman-Run, veröffentlicht eine
    Benutzerdatenbank ausschließlich über Run-, Instanz- und Datenbank-ID und
    prüft WhatIf, Offline-Postcondition, stabile Paket-/Storage-IDs, vollständige
    Integritätsprüfung und Cleanup. Es werden keine Hostpfade oder Secrets als
    Acceptance-Evidence persistiert.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [string]$Version='2022-CU18',
    [switch]$RuntimeMutexAlreadyHeld,
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-package-export-$Provider-$([Guid]::NewGuid().ToString('N'))"
$stateRoot=Join-Path $testRoot 'state';$dataRoot=Join-Path $testRoot 'Lab_Data';$testDataRoot=Join-Path $testRoot 'test-data'
$previousStateRoot=$env:SQL_SERVER_LAB_STATE;$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT;$previousTestDataRoot=$env:SQL_SERVER_LAB_TEST_DATA_ROOT
$module=$null;$lab=$null;$completed=$false;$mutex=$null;$mutexAcquired=$false
$databaseName='Psr009ExportEvidence'

function Assert-ContainerPackageExport {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description)
    if(-not $Condition){throw "CONTAINER_DATABASE_PACKAGE_EXPORT_ACCEPTANCE_FAILED: $Description"}
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    if(-not $RuntimeMutexAlreadyHeld){
        $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
        $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if(-not $mutexAcquired){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_ACCEPTANCE_LOCK_TIMEOUT'}
    }
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $env:SQL_SERVER_LAB_STATE=$stateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot;$env:SQL_SERVER_LAB_TEST_DATA_ROOT=$testDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    $runtimeResolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if($Provider -eq 'podman'){& (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')|Out-Host}
    Assert-ContainerPackageExport ([bool]$runtimeResolution.Available) "Runtime '$Provider' ist zentral auflösbar"
    & ([string]$runtimeResolution.Invocation) info 1>$null 2>$null
    Assert-ContainerPackageExport ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"
    & $module {param($Root)$null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false} $dataRoot

    $token=[Guid]::NewGuid().ToString('N').Substring(0,16)
    $password=ConvertTo-SecureString "Psr009_${token}!Aa7" -AsPlainText -Force
    $lab=New-SqlServerLab -Version $Version -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName "psr009-export-$Provider-$($token.Substring(0,8))" -DataRoot $dataRoot -StateRoot $stateRoot -SaPassword $password -SkipAssessment
    Assert-ContainerPackageExport ($lab.State -eq 'Running') 'Isolierter Container-Run wurde provisioniert'
    $instance=$lab.Instances[0]
    $null=New-SqlServerLabDatabase -HostName ([string]$instance.Host) -Port ([int]$instance.Port) -SaPassword $password -DatabaseName $databaseName

    $preview=Export-SqlServerLabDatabasePackage -RunId $lab.RunId -InstanceId primary -DatabaseName $databaseName -DataRoot $dataRoot -StateRoot $stateRoot -WhatIf
    Assert-ContainerPackageExport ($preview.Status -eq 'PLANNED' -and -not $preview.DatabasePackageId -and $preview.Provider -eq $Provider) 'WhatIf plant ohne Paket- oder Storage-ID-Mutation'
    $published=Export-SqlServerLabDatabasePackage -RunId $lab.RunId -InstanceId primary -DatabaseName $databaseName -DataRoot $dataRoot -StateRoot $stateRoot -Confirm:$false
    Assert-ContainerPackageExport ($published.Status -eq 'REUSABLE' -and $published.DatabasePackageId -match '^[0-9a-f-]{36}$' -and $published.PersistentStorageId -match '^[0-9a-f-]{36}$') 'Öffentlicher Export liefert stabile Paket- und Storage-ID'
    $selection=@(Get-SqlServerLabDatabasePackage -DatabasePackageId $published.DatabasePackageId -DataRoot $dataRoot -VerifyIntegrity)
    Assert-ContainerPackageExport ($selection.Count -eq 1 -and $selection[0].Availability -eq 'SELECTABLE' -and $selection[0].IntegrityValidation -eq 'VERIFIED') 'Veröffentlichtes Paket ist vollständig hashverifiziert selektierbar'
    $sourceState=& $module {
        param($Run,$Root,$State,$Name)
        $context=Get-LabContainerReconcileContext -RunId $Run -InstanceId primary -StateRoot $State
        $secret=Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
        $plain=ConvertFrom-LabSecureString -SecureString $secret
        try {@(Invoke-SqlQuery -HostName ([string]$context.Instance.host) -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -Query "SELECT state_desc FROM sys.databases WHERE name=N'$Name';"|ForEach-Object {[string]$_})}
        finally {$plain=$null}
    } $lab.RunId $dataRoot $stateRoot $databaseName
    Assert-ContainerPackageExport ($sourceState -contains 'OFFLINE') 'Quelle bleibt nach der Paketveröffentlichung exklusiv offline'
    $json=$published|ConvertTo-Json -Depth 10
    Assert-ContainerPackageExport ($json -notmatch [regex]::Escape($testRoot) -and $json -notmatch 'Sha256|Path|Password|Credential') 'Öffentliche Exportantwort bleibt pfad-, hash- und geheimnisfrei'
    $completed=$true
}
finally {
    try {if($lab){Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false|Out-Null}}catch{Write-Warning "Container-Cleanup fehlgeschlagen: $($_.Exception.Message)"}
    $env:SQL_SERVER_LAB_STATE=$previousStateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot;$env:SQL_SERVER_LAB_TEST_DATA_ROOT=$previousTestDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutex){if($mutexAcquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
    if($KeepOnFailure -and -not $completed){Write-Warning "Acceptance-Arbeitsbereich bleibt erhalten: $testRoot"}
    elseif(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
if(-not $completed){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_ACCEPTANCE_INCOMPLETE'}
Write-Host "Öffentliche Container-DATABASE_PACKAGE-Export-Acceptance erfolgreich: $Provider" -ForegroundColor Green
