#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$WorkerId,
    [ValidateSet('Race','Hold','Resume','Portable')][string]$Mode='Race',[string]$OperationId,[int]$ExpectedRevision=2)
$ErrorActionPreference='Stop'
if($Mode -ceq 'Portable'){
    function Add-Type {
        [CmdletBinding()]
        param([string]$TypeDefinition)
        if($TypeDefinition.Contains('class WindowsPoolRootProbe')){throw 'SYNTHETIC_PLATFORM_INTEROP_DENIED'}
        Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
    }
}
$module=Import-Module (Join-Path $RepositoryRoot SqlServerLab.psd1) -Force -PassThru
if($Mode -ceq 'Portable'){
    $result=& $module {
        param($directory)
        $ordinaryRoot=Join-Path $directory portable-non-pool-state
        $run=New-LabRunState -StateRoot $ordinaryRoot -Metadata @{name='synthetic-portable-non-pool';workflowKind='synthetic'}
        Set-LabRunState -RunId $run.RunId -StateRoot $ordinaryRoot -NewState PROVISIONING
        $blocked=$false;try{Assert-LabWindowsPoolRootSupport -StateRoot $ordinaryRoot}catch{$blocked=$_.Exception.Message -ceq 'WINDOWS_POOL_ROOT_LOCALITY_UNSUPPORTED'}
        if($blocked -and (Get-LabRunState -RunId $run.RunId -StateRoot $ordinaryRoot).state -ceq 'PROVISIONING'){
            [pscustomobject]@{Status='PORTABLE_NON_POOL_READY_POOL_BLOCKED'}
        }else{[pscustomobject]@{Status='PORTABLE_BOUNDARY_FAILED'}}
    } $Directory
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Directory ($WorkerId+'.result.json')) -Encoding utf8
    return
}
$result=& $module {
    param($StateRoot,$RunId,$PoolId,$Directory,$WorkerId,$Mode,$OperationId,$ExpectedRevision)
    if($Mode -ceq 'Race'){$operation=New-LabWindowsPoolOperationIntent -PoolId $PoolId -Purpose Claim -RunId $RunId -StateRoot $StateRoot;$OperationId=$operation.operationId}
    $context=[pscustomobject]@{StateRoot=(Resolve-LabWindowsPoolRoot $StateRoot);PoolId=$PoolId;OperationId=$OperationId;RunId=$RunId;Kind='Claim'}
    [IO.File]::WriteAllText((Join-Path $Directory ($WorkerId+'.ready')),'ready')
    $deadline=[datetime]::UtcNow.AddSeconds(30)
    if($Mode -ceq 'Race'){
        while(-not (Test-Path -LiteralPath (Join-Path $Directory go))){if([datetime]::UtcNow -ge $deadline){throw 'SYNTHETIC_BARRIER_TIMEOUT'};Start-Sleep -Milliseconds 25}
    }
    try {
        Invoke-WithLabWindowsPoolOperation -Context $context -Body {
            switch($Mode){
                Race {
                    $null=Set-LabWindowsPoolMemberState -RunId $RunId -StateRoot $StateRoot -ExpectedRevision $ExpectedRevision -Change {
                        param($member)
                        if($member.state -cne 'FREE' -or $member.claim){throw 'WINDOWS_POOL_MEMBER_UNAVAILABLE'}
                        $member.state='CLAIMED';$member.claim=[pscustomobject]@{claimId=[guid]::NewGuid().ToString();operationId=$OperationId;purpose='Claim';providerMutationStarted=$false}
                    }
                    [pscustomobject]@{Status='WON';OperationId=$OperationId}
                }
                Hold {
                    [IO.File]::WriteAllText((Join-Path $Directory ($WorkerId+'.holding')),'holding')
                    while(-not (Test-Path -LiteralPath (Join-Path $Directory ($WorkerId+'.release')))){if([datetime]::UtcNow -ge $deadline){throw 'SYNTHETIC_HOLD_TIMEOUT'};Start-Sleep -Milliseconds 25}
                    [pscustomobject]@{Status='HELD_AND_RELEASED';OperationId=$OperationId}
                }
                Resume {[pscustomobject]@{Status='RESUMED_SAME_OPERATION';OperationId=$OperationId}}
            }
        }
    } catch {[pscustomobject]@{Status=$_.Exception.Message;OperationId=$OperationId}}
} $StateRoot $RunId $PoolId $Directory $WorkerId $Mode $OperationId $ExpectedRevision
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory ($WorkerId+'.result.json')) -Encoding utf8
