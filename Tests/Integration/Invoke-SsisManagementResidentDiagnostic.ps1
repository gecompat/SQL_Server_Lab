#Requires -Version 7.2
<#
.SYNOPSIS
    Isoliert die zusätzliche Managementassembly-Ladung auf einem vorhandenen eigenen SQL-/SSIS-Run.
.DESCRIPTION
    Diagnose, keine Produktabnahme. Die bestehende Fixture-Receipt bleibt bytegleich.
    Genau ein zusätzlicher synthetischer Projektlauf wird über den produktiven
    Gastkörper mit RetainFolder=false erzeugt und dort wieder bereinigt.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
& $module {param($Root,$Repo) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repo} $StateRoot $repoRoot
$operation='ssis-install-'+[guid]::NewGuid().ToString('N')
$record=[ordered]@{Contract='SqlServerLab.SsisManagementResidentDiagnostic/1.0';Status='STARTED';RunId=$RunId.ToString();OperationId=$operation;OriginalReceipt='NOT_CHECKED';Cleanup='NOT_CHECKED'}
$diagnostics=Join-Path $StateRoot 'diagnostics';$null=New-Item -ItemType Directory -Path $diagnostics -Force
$recordPath=Join-Path $diagnostics ($operation+'-management-resident.json')
$privateLog=Join-Path $diagnostics ($operation+'-management-resident.private.log')
$record|ConvertTo-Json|Set-Content -LiteralPath $recordPath
$originalPath=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId.ToString()) 'ssis-fixture-receipt.json'
$originalHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256 -ErrorAction Stop).Hash
try {
    $result=@(& $module {
        param($Id,$Root,$Operation)
        $context=Get-LabSsisPrerequisiteContext -RunId $Id -InstanceId primary -StateRoot $Root
        $guest=$null;$lease=$null
        try {
            $leasePath=Join-Path $context.Directory 'ssis-fixture-operation.lock'
            if((Test-Path -LiteralPath $leasePath) -and ((Get-Item -LiteralPath $leasePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'SSIS_DIAGNOSTIC_STATE_LOCK_INVALID'}
            $lease=[IO.FileStream]::new($leasePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
            if(-not $guest){throw 'SSIS_DIAGNOSTIC_GUEST_CREDENTIAL_REQUIRED'}
            $source=(Get-LabSsisCatalogFixtureGuestProbe).ToString()
            $marker='if(-not $catalogExists){'
            if([regex]::Matches($source,[regex]::Escape($marker)).Count -ne 1){throw 'SSIS_DIAGNOSTIC_SOURCE_BINDING_INVALID'}
            $insertion=@'
            if(-not $catalogExists){throw 'SSIS_DIAGNOSTIC_EXISTING_CATALOG_REQUIRED'}
            $beforeMemory=[GC]::GetTotalMemory($false)
            $managementTypes=Get-SsisInstalledCatalogManagementTypes -BinnDirectory (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn')
            [pscustomobject]@{Kind='MANAGEMENT_RESIDENT_MEMORY';ManagedBytesBefore=$beforeMemory;ManagedBytesAfter=[GC]::GetTotalMemory($false);PrivateBytes=[Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64;AvailableMemoryKB=(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory}
            if(-not $catalogExists){
'@
            $probe=[scriptblock]::Create($source.Replace($marker,$insertion))
            Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $Id.ToString() `
                -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
                -Credential ([PSCredential]::new('Administrator',$guest)) -ScriptBlock $probe `
                -ArgumentList @($Operation,$false,(Get-LabSsisFixtureCleanupSql)) -TimeoutSeconds 600 -ErrorAction Stop
        } finally {if($guest){$guest.Dispose()};if($lease){$lease.Dispose()}}
    } $RunId $StateRoot $operation)
    $fixture=@($result|Where-Object {$_.PSObject.Properties['Status'] -and $_.Status -eq 'SSISDB_FIXTURE_ACCEPTED'})
    if($fixture.Count -ne 1){throw 'SSIS_DIAGNOSTIC_FIXTURE_RESULT_INVALID'}
    $record.Status='PASSED_DIAGNOSTIC_ONLY';$record.Cleanup='GUEST_TARGETED_CLEANUP_COMPLETED'
    $record.ExecutionIds=$fixture[0].ExecutionIds;$record.ExecutionStatus=$fixture[0].ExecutionStatus
    $record.Memory=@($result|Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -eq 'MANAGEMENT_RESIDENT_MEMORY'}|Select-Object ManagedBytesBefore,ManagedBytesAfter,PrivateBytes,AvailableMemoryKB)
} catch {
    $record.Status='FAILED_DIAGNOSTIC_ONLY'
    $_|Out-String|Add-Content -LiteralPath $privateLog
    throw 'SSIS_MANAGEMENT_RESIDENT_DIAGNOSTIC_FAILED: private diagnostics retained; original source must be preserved.'
} finally {
    $record.OriginalReceipt=if((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -ceq $originalHash){'UNCHANGED'}else{'CHANGED'}
    $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $recordPath
    if($env:GITHUB_STEP_SUMMARY){$record|ConvertTo-Json -Depth 8|Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY}
    if($record.OriginalReceipt -ne 'UNCHANGED'){throw 'SSIS_DIAGNOSTIC_ORIGINAL_RECEIPT_CHANGED'}
}
$record|ConvertTo-Json -Depth 8
