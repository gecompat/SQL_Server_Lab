#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den öffentlichen hashgebundenen Container-Paketexport.
.DESCRIPTION
    Erstellt einen isolierten Docker- oder Podman-Run, veröffentlicht eine
    Benutzerdatenbank ausschließlich über Run-, Instanz- und Datenbank-ID und
    prüft WhatIf, Quell-Recovery nach injiziertem Kopierfehler,
    Offline-Postcondition, stabile Paket-/Storage-IDs, vollständige
    Integritätsprüfung und Cleanup. Es werden keine Hostpfade oder Secrets als
    Acceptance-Evidence persistiert.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Nur zufaellig erzeugte synthetische Credentials fuer den eigenen isolierten Test-Run.')]
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
$module=$null;$lab=$null;$completed=$false;$mutex=$null;$mutexAcquired=$false;$cleanupFailed=$false
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
    $assessment=Test-SqlServerLabPrerequisite -Provider $Provider
    Assert-ContainerPackageExport ($assessment.Status -eq 'RESOURCE_OK') 'Ressourcenpruefung erlaubt den isolierten Test-Run'
    & $module {param($Root)$null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false} $dataRoot

    $token=[Guid]::NewGuid().ToString('N').Substring(0,16)
    $password=ConvertTo-SecureString "Psr009_${token}!Aa7" -AsPlainText -Force
    $lab=New-SqlServerLab -Version $Version -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName "psr009-export-$Provider-$($token.Substring(0,8))" -DataRoot $dataRoot -StateRoot $stateRoot -SaPassword $password -SkipAssessment
    Assert-ContainerPackageExport ($lab.State -eq 'Running') 'Isolierter Container-Run wurde provisioniert'
    $instance=$lab.Instances[0]
    $null=New-SqlServerLabDatabase -HostName ([string]$instance.Host) -Port ([int]$instance.Port) -SaPassword $password -DatabaseName $databaseName

    $preview=Export-SqlServerLabDatabasePackage -RunId $lab.RunId -InstanceId primary -DatabaseName $databaseName -DataRoot $dataRoot -StateRoot $stateRoot -WhatIf
    Assert-ContainerPackageExport ($preview.Status -eq 'PLANNED' -and -not $preview.DatabasePackageId -and $preview.Provider -eq $Provider) 'WhatIf plant ohne Paket- oder Storage-ID-Mutation'
    $recovery=& $module {
        param($Run,$State,$Root,$Name)
        $originalNative=(Get-Command Invoke-LabProgressNativeCommand -CommandType Function).ScriptBlock
        $script:packageNativeCopyFault=$false
        function Invoke-LabProgressNativeCommand {
            [CmdletBinding()]
            param([string]$FilePath,[string[]]$ArgumentList,[string]$Phase='ImageBuild',[int]$TimeoutSeconds=3600,$Progress)
            if($ArgumentList[0] -eq 'cp'){$script:packageNativeCopyFault=$true;return [pscustomobject]@{ExitCode=1;Output=@()}}
            & $originalNative @PSBoundParameters
        }
        $failed=$false
        try{$null=Export-SqlServerLabDatabasePackage -RunId $Run -InstanceId primary -DatabaseName $Name -DataRoot $Root -StateRoot $State -Confirm:$false}
        catch{$failed=$_.Exception.Message -match 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED'}
        $context=Get-LabContainerReconcileContext -RunId $Run -InstanceId primary -StateRoot $State
        $secret=Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
        $plain=ConvertFrom-LabSecureString -SecureString $secret
        try{$observed=Get-LabContainerPackageDatabaseState -Context $context -DatabaseName $Name -SaPlain $plain}
        finally{$plain=$null}
        $journals=@(Get-ChildItem -LiteralPath (Join-Path $context.RunDirectory 'database-package-export') -Recurse -Filter source-journal.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
        [pscustomobject]@{FaultInjected=$script:packageNativeCopyFault;Failed=$failed;State=$observed.State;Access=$observed.Access;RolledBack=(@($journals | Where-Object {$_.Status -eq 'ROLLED_BACK' -and $_.SourceRecovery -eq 'RESTORED'}).Count -eq 1)}
    } $lab.RunId $stateRoot $dataRoot $databaseName
    Assert-ContainerPackageExport ($recovery.FaultInjected -and $recovery.Failed -and $recovery.State -eq 'ONLINE' -and $recovery.Access -eq 'MULTI_USER' -and $recovery.RolledBack) 'Kontrollierter Kopierfehler stellt den echten SQL-Zustand wieder her und journalisiert den Rollback'
    $cleanupRecovery=& $module {
        param($Run,$State,$Root,$Name)
        function Remove-LabContainerPackageExportPayload {throw 'SYNTHETIC_PAYLOAD_CLEANUP_FAILURE'}
        $failed=$false
        try{$null=Export-SqlServerLabDatabasePackage -RunId $Run -InstanceId primary -DatabaseName $Name -DataRoot $Root -StateRoot $State -Confirm:$false}
        catch{$failed=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_PAYLOAD_CLEANUP_FAILED'}
        $context=Get-LabContainerReconcileContext -RunId $Run -InstanceId primary -StateRoot $State
        $journals=@(Get-ChildItem -LiteralPath (Join-Path $context.RunDirectory 'database-package-export') -Recurse -Filter source-journal.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json} | Where-Object {$_.PublishedResult})
        [pscustomobject]@{Failed=$failed;JournalCount=$journals.Count;Result=if($journals.Count -eq 1){$journals[0].PublishedResult}else{$null}}
    } $lab.RunId $stateRoot $dataRoot $databaseName
    Assert-ContainerPackageExport ($cleanupRecovery.Failed -and $cleanupRecovery.JournalCount -eq 1 -and $cleanupRecovery.Result.DatabasePackageId) 'Cleanup-Fehler nach echter Publikation bewahrt die stabilen Ergebnis-IDs'
    $published=Export-SqlServerLabDatabasePackage -RunId $lab.RunId -InstanceId primary -DatabaseName $databaseName -DataRoot $dataRoot -StateRoot $stateRoot -Confirm:$false
    Assert-ContainerPackageExport ($published.DatabasePackageId -eq $cleanupRecovery.Result.DatabasePackageId -and $published.PersistentStorageId -eq $cleanupRecovery.Result.PersistentStorageId -and @(Get-SqlServerLabDatabasePackage -DataRoot $dataRoot).Count -eq 1) 'Cleanup-Resume revalidiert das vorhandene Paket ohne doppelte Publikation'
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
    try {if($lab){$cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false;if($cleanup.Status -ne 'REMOVED'){throw 'CONTAINER_PACKAGE_TEST_CLEANUP_FAILED'}}}catch{$cleanupFailed=$true;Write-Warning 'Container-Cleanup fehlgeschlagen; Test-State bleibt fuer Recovery erhalten.'}
    $env:SQL_SERVER_LAB_STATE=$previousStateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot;$env:SQL_SERVER_LAB_TEST_DATA_ROOT=$previousTestDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutex){if($mutexAcquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
    if($cleanupFailed -or ($KeepOnFailure -and -not $completed)){Write-Warning 'Acceptance-Arbeitsbereich bleibt fuer Recovery erhalten.'}
    elseif(Test-Path -LiteralPath $testRoot){
        $resolved=[IO.Path]::GetFullPath($testRoot)
        $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-package-export-*'){throw 'CONTAINER_PACKAGE_TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed){throw 'CONTAINER_PACKAGE_TEST_CLEANUP_FAILED'}
if(-not $completed){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_ACCEPTANCE_INCOMPLETE'}
Write-Host "Öffentliche Container-DATABASE_PACKAGE-Export-Acceptance erfolgreich: $Provider" -ForegroundColor Green
