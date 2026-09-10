function Resolve-LabWindowsActivationIntent {
    [CmdletBinding()]
    param([AllowNull()]$Intent,[switch]$Isolated,[switch]$LegacyRequired)
    $strategy='EvaluationOnline'
    $egress=if($Isolated){'Denied'}elseif($LegacyRequired){'AllowTemporary'}else{'ExistingOnly'}
    if($Intent){
        $keys=if($Intent -is [Collections.IDictionary]){@($Intent.Keys)}else{@($Intent.PSObject.Properties.Name)}
        if(@($keys | Where-Object {$_ -notin @('ContractVersion','Strategy','EgressPolicy')}).Count){throw 'WINDOWS_ACTIVATION_INTENT_FIELD_INVALID'}
        if([string]$Intent.ContractVersion -ne 'SqlServerLab.WindowsActivationIntent/1.0'){throw 'WINDOWS_ACTIVATION_CONTRACT_UNSUPPORTED'}
        if('Strategy' -notin $keys -or 'EgressPolicy' -notin $keys){throw 'WINDOWS_ACTIVATION_INTENT_INCOMPLETE'}
        $strategy=[string]$Intent.Strategy;$egress=[string]$Intent.EgressPolicy
    }
    $strategies=@('EvaluationOnline','VerifyOnly')
    $policies=@('Denied','ExistingOnly','AllowTemporary')
    if($strategy -notin $strategies){throw 'WINDOWS_ACTIVATION_STRATEGY_UNSUPPORTED'}
    if($egress -notin $policies){throw 'WINDOWS_ACTIVATION_EGRESS_UNSUPPORTED'}
    [pscustomobject]@{
        ContractVersion='SqlServerLab.WindowsActivationIntent/1.0'
        Strategy=@($strategies | Where-Object {$_ -eq $strategy})[0]
        EgressPolicy=@($policies | Where-Object {$_ -eq $egress})[0]
    }
}

function Get-LabWindowsActivationDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$License,[Parameter(Mandatory)]$Intent)
    $normalized=Resolve-LabWindowsActivationIntent -Intent $Intent
    $action='Block';$code='WINDOWS_ACTIVATION_REQUIRED'
    if([string]$License.State -in @('EVALUATION_ACTIVE','LICENSED')){
        if([int]$License.LicenseStatus -ne 1 -or ([string]$License.State -eq 'EVALUATION_ACTIVE' -and [int]$License.EvaluationMinutesRemaining -le 0)){throw 'WINDOWS_ACTIVATION_LICENSE_EVIDENCE_INVALID'}
        $action='NoOp';$code='WINDOWS_ACTIVATION_ALREADY_ACTIVE'
    }
    elseif([string]$License.State -eq 'EVALUATION_EXPIRED'){$code='WINDOWS_EVALUATION_EXPIRED'}
    elseif([string]$License.Edition -notmatch '(?i)eval'){$code='WINDOWS_ACTIVATION_FULL_VERSION_STRATEGY_REQUIRED'}
    elseif($normalized.Strategy -eq 'VerifyOnly'){$code='WINDOWS_ACTIVATION_VERIFY_ONLY'}
    elseif($normalized.EgressPolicy -eq 'Denied'){$code='WINDOWS_ACTIVATION_EGRESS_DENIED'}
    else {$action='ActivateEvaluation';$code='WINDOWS_ACTIVATION_NETWORK_PLAN_REQUIRED'}
    [pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationDecision/1.0';Intent=$normalized;Action=$action;Code=$code;NetworkMutationAllowed=$false}
}

function New-LabWindowsPermanentAdapterBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Adapters,[Parameter(Mandatory)][string]$SwitchId)
    if(-not $VM.Id -or $Adapters.Count -ne 1 -or -not $Adapters[0].Id -or
        [string]$Adapters[0].VMId -ne [string]$VM.Id -or [string]$Adapters[0].SwitchId -ne $SwitchId -or
        [string]::IsNullOrWhiteSpace($SwitchId) -or $SwitchId -eq [string][guid]::Empty){throw 'WINDOWS_PERMANENT_ADAPTER_BINDING_INVALID'}
    [pscustomobject]@{ContractVersion='SqlServerLab.WindowsPermanentAdapterBinding/1.0';VMId=[string]$VM.Id;AdapterId=[string]$Adapters[0].Id;SwitchId=$SwitchId}
}

function Get-LabWindowsActivationPermanentAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab,[Parameter(Mandatory)]$Managed)
    if([string]$Lab.Instance.labNetwork.intent -notin @('lan','nat')){return $null}
    $binding=$Lab.Instance.labNetwork.adapterBinding
    $owned=$Managed.Identity.networkBinding
    if(-not $binding -or -not $owned){return $null}
    if($binding.ContractVersion -ne 'SqlServerLab.WindowsPermanentAdapterBinding/1.0' -or $owned.ContractVersion -ne $binding.ContractVersion){throw 'WINDOWS_ACTIVATION_PERMANENT_BINDING_INVALID'}
    foreach($field in @('VMId','AdapterId','SwitchId')){
        if(-not $binding.$field -or [string]$binding.$field -ne [string]$owned.$field){throw 'WINDOWS_ACTIVATION_PERMANENT_BINDING_INVALID'}
    }
    if([string]$binding.VMId -ne [string]$Managed.VM.Id){throw 'WINDOWS_ACTIVATION_PERMANENT_BINDING_INVALID'}
    $adapters=@(Get-VMNetworkAdapter -VM $Managed.VM -ErrorAction Stop | Where-Object {[string]$_.Id -eq [string]$binding.AdapterId})
    if($adapters.Count -ne 1 -or [string]$adapters[0].VMId -ne [string]$binding.VMId -or [string]$adapters[0].SwitchId -ne [string]$binding.SwitchId){throw 'WINDOWS_ACTIVATION_PERMANENT_BINDING_DRIFT'}
    return $adapters[0]
}

function Test-LabWindowsActivationAdapterConnectivity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab,[Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)][PSCredential]$Credential,[int]$TimeoutSeconds=60)
    $mac=([string]$Adapter.MacAddress -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
    if($mac -notmatch '^[0-9A-F]{12}$' -or $mac -eq '000000000000'){return $false}
    $result=Invoke-HyperVPowerShellDirect -VMName $Lab.Instance.vmName -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId `
        -Credential $Credential -FallbackAddress $Lab.Instance.oobeAutomation.labAddress -TimeoutSeconds $TimeoutSeconds -ArgumentList @($mac) -ScriptBlock {
            param($MacAddress)
            $adapters=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {([string]$_.MacAddress -replace '[^0-9A-Fa-f]','').ToUpperInvariant() -eq $MacAddress})
            if($adapters.Count -ne 1){return [pscustomobject]@{Available=$false}}
            $address=@(Get-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'})
            $route=@(Get-NetRoute -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            [pscustomobject]@{Available=($address.Count -gt 0 -and $route.Count -gt 0)}
        }
    return (@($result).Count -eq 1 -and @($result)[0].Available -eq $true)
}

function Set-LabWindowsTestEnvironmentActivationIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)
    $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if($lab.Instance.windowsActivationIntent -and [string]$lab.Instance.windowsActivationIntentSource -ne 'compatibility-defaults'){return}
    $intent=Resolve-LabWindowsActivationIntent -LegacyRequired -Isolated:([string]$lab.Run.metadata.networkIntent -eq 'isolated')
    $lab.Instance | Add-Member -NotePropertyName windowsActivationIntent -NotePropertyValue $intent -Force
    $lab.Instance | Add-Member -NotePropertyName windowsActivationIntentSource -NotePropertyValue 'legacy-test-environment' -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
}

function Invoke-LabWindowsSlotActivationReconcile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[PSCredential]$Credential,[string]$StateRoot)
    $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $intent=Resolve-LabWindowsActivationIntent -Intent $lab.Instance.windowsActivationIntent -Isolated:([string]$lab.Run.metadata.networkIntent -eq 'isolated')
    Invoke-HyperVWindowsSlotActivation -RunId $RunId -WindowsActivation $intent -Credential $Credential -StateRoot $lab.StateRoot
}
