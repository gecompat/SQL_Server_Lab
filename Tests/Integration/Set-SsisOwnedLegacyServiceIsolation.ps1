#Requires -Version 7.2
<#
.SYNOPSIS
    Isoliert den nachweislich vom Lab installierten Legacydienst für eine fokussierte Diagnose.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
if(-not $PSCmdlet.ShouldProcess($RunId.ToString(),'Disable the Lab-installed stopped legacy SSIS service')){return}
& $module {
    param($Id,$Root,$Repo)
    Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repo
    $context=Get-LabSsisPrerequisiteContext -RunId $Id -InstanceId primary -StateRoot $Root
    $receipt=Read-LabDiagnosticJson -Path (Join-Path $context.Directory 'ssis-component-receipt.json')
    if($receipt.RunId -cne $Id.ToString() -or $receipt.InstanceId -cne 'primary' -or $receipt.Status -cne 'INSTALLED_AND_RESTART_VERIFIED' -or $receipt.OperationId -cnotmatch '^ssis-component-[a-f0-9]{32}$'){throw 'SSIS_ISOLATION_OWN_INSTALL_RECEIPT_REQUIRED'}
    $guest=$null;$lease=$null
    try {
        $lockPath=Join-Path $context.Directory 'ssis-fixture-operation.lock'
        if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'SSIS_ISOLATION_LOCK_INVALID'}
        $lease=[IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $journal=Join-Path $context.Directory 'ssis-legacy-service-isolation.json'
        Write-LabArtifactJsonAtomic -Path $journal -InputObject @{RunId=$Id.ToString();OperationId=$receipt.OperationId;Status='PREPARED';RequestedStartup='Disabled';Cleanup='REMOVE_EXACT_OWNED_RUN'}
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if(-not $guest){throw 'SSIS_ISOLATION_GUEST_CREDENTIAL_REQUIRED'}
        $result=@(Invoke-HyperVPowerShellDirect -VMName $context.Instance.vmName -ExpectedRunId $Id.ToString() -ExpectedScopeId $context.Run.scopeId -ExpectedVmId ([guid]$context.Instance.vmId) -Credential ([PSCredential]::new('Administrator',$guest)) -TimeoutSeconds 90 -ScriptBlock {
            $connection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=SSISDB;Integrated Security=SSPI;Connect Timeout=10;Encrypt=False;Pooling=False')
            try {$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=10;$command.CommandText='SELECT COUNT(*) FROM catalog.executions WHERE status IN(2,5,8)';if([int]$command.ExecuteScalar() -ne 0){throw 'SSIS_ISOLATION_ACTIVE_EXECUTION_RETAINED'}}finally{$connection.Dispose()}
            $service=Get-Service -Name MsDtsServer170 -ErrorAction Stop
            if($service.Status -ne 'Stopped'){throw 'SSIS_ISOLATION_STOPPED_SERVICE_REQUIRED'}
            Set-Service -Name MsDtsServer170 -StartupType Disabled -ErrorAction Stop
            if((Get-Service -Name MsDtsServer170).StartType -ne 'Disabled'){throw 'SSIS_ISOLATION_POSTCONDITION_FAILED'}
            [pscustomobject]@{Status='OWN_LEGACY_SERVICE_DISABLED';FixtureMutations=0}
        })
        if($result.Count -ne 1 -or $result[0].Status -cne 'OWN_LEGACY_SERVICE_DISABLED'){throw 'SSIS_ISOLATION_RESULT_INVALID'}
        Write-LabArtifactJsonAtomic -Path $journal -InputObject @{RunId=$Id.ToString();OperationId=$receipt.OperationId;Status=$result[0].Status;RequestedStartup='Disabled';Cleanup='REMOVE_EXACT_OWNED_RUN'}
        $result[0]
    } finally {if($guest){$guest.Dispose()};if($lease){$lease.Dispose()}}
} $RunId $StateRoot $repoRoot
