function Resolve-LabWindowsActivationIntent {
    [CmdletBinding()]
    param([AllowNull()]$Intent,[switch]$Isolated,[switch]$LegacyRequired,[switch]$RequireExplicit)
    if($RequireExplicit -and $null -eq $Intent){throw 'WINDOWS_ACTIVATION_INTENT_REQUIRED'}
    $strategy='EvaluationOnline'
    $egress=if($Isolated){'Denied'}elseif($LegacyRequired){'AllowTemporary'}else{'ExistingOnly'}
    if($Intent -or $RequireExplicit){
        $keys=if($Intent -is [Collections.IDictionary]){@($Intent.Keys)}else{@($Intent.PSObject.Properties.Name)}
        if(@($keys | Where-Object {$_ -notin @('ContractVersion','Strategy','EgressPolicy')}).Count){throw 'WINDOWS_ACTIVATION_INTENT_FIELD_INVALID'}
        if([string]$Intent.ContractVersion -ne 'SqlServerLab.WindowsActivationIntent/1.0'){throw 'WINDOWS_ACTIVATION_CONTRACT_UNSUPPORTED'}
        if('Strategy' -notin $keys -or 'EgressPolicy' -notin $keys){throw 'WINDOWS_ACTIVATION_INTENT_INCOMPLETE'}
        $strategy=[string]$Intent.Strategy;$egress=[string]$Intent.EgressPolicy
    }
    $strategies=@('EvaluationOnline','VerifyOnly','NotRequested')
    $policies=@('Denied','ExistingOnly','AllowTemporary')
    if($strategy -notin $strategies){throw 'WINDOWS_ACTIVATION_STRATEGY_UNSUPPORTED'}
    if($egress -notin $policies){throw 'WINDOWS_ACTIVATION_EGRESS_UNSUPPORTED'}
    if($strategy -eq 'NotRequested' -and $egress -ne 'Denied'){throw 'WINDOWS_ACTIVATION_NOT_REQUESTED_EGRESS_MUST_BE_DENIED'}
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
    if($normalized.Strategy -eq 'NotRequested'){
        $action='NoOp';$code='WINDOWS_ACTIVATION_NOT_REQUESTED'
    }
    elseif([string]$License.State -in @('EVALUATION_ACTIVE','LICENSED')){
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
    param(
        [Parameter(Mandatory)][string]$RunId,
        [PSCredential]$Credential,
        [string]$StateRoot,
        [AllowNull()]$WindowsActivation,
        [ValidateScript({-not [string]::IsNullOrWhiteSpace($_)})][string]$ExternalSwitchName,
        [guid]$ExpectedVmId
    )
    $binding=@{}
    if($PSBoundParameters.ContainsKey('ExpectedVmId')){
        $binding.ExpectedVmId=$ExpectedVmId
        if($PSBoundParameters.ContainsKey('ExternalSwitchName')){throw 'HYPERV_STRICT_ACTIVATION_EXTERNAL_SWITCH_FORBIDDEN'}
    }
    $activationArguments=@{}
    if($PSBoundParameters.ContainsKey('WindowsActivation')){
        $activationArguments.WindowsActivation=Resolve-LabWindowsActivationIntent -Intent $WindowsActivation -RequireExplicit
        $activationArguments.ExplicitWindowsActivation=$true
    }
    if($PSBoundParameters.ContainsKey('ExternalSwitchName')){$activationArguments.ExternalSwitchName=$ExternalSwitchName}
    $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot @binding
    if(-not $activationArguments.ContainsKey('WindowsActivation')){
        $activationArguments.WindowsActivation=Resolve-LabWindowsActivationIntent -Intent $lab.Instance.windowsActivationIntent -Isolated:([string]$lab.Run.metadata.networkIntent -eq 'isolated')
    }
    if($binding.Count){
        # This selected lane verifies the retained policy; it never repairs an
        # activation journal, changes the intent, or requests another activation.
        $saved=Resolve-LabWindowsActivationIntent -Intent $lab.Instance.windowsActivationIntent -RequireExplicit
        foreach($intent in @($saved,$activationArguments.WindowsActivation)){
            if($intent.Strategy -ne 'VerifyOnly' -or $intent.EgressPolicy -ne 'Denied'){throw 'HYPERV_STRICT_ACTIVATION_VERIFY_ONLY_REQUIRED'}
        }
        $journalPath=Join-Path $lab.RunDirectory 'windows-activation-network.json'
        $journalFile=$null
        try{$journalFile=Get-Item -LiteralPath $journalPath -Force -ErrorAction Stop}
        catch [System.Management.Automation.ItemNotFoundException]{} # Only confirmed absence skips the journal read.
        catch{throw 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'}
        if($null -ne $journalFile){
            try{
                if($journalFile -isnot [IO.FileInfo] -or
                    ($journalFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $journalFile.Length -lt 1 -or $journalFile.Length -gt 1048576){throw 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'}
                $journal=Get-Content -LiteralPath $journalPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 20 -NoEnumerate -ErrorAction Stop
                if($journal -is [array] -or $journal -isnot [pscustomobject] -or $journal.ContractVersion -isnot [string] -or
                    $journal.RunId -isnot [string] -or $journal.ScopeId -isnot [string] -or $journal.VMId -isnot [string] -or $journal.Status -isnot [string] -or
                    $journal.ContractVersion -ne 'SqlServerLab.WindowsActivationNetwork/1.0' -or
                    [string]$journal.RunId -ne [string]$lab.Run.runId -or [string]$journal.ScopeId -ne [string]$lab.Run.scopeId -or
                    [string]$journal.VMId -ne $ExpectedVmId.ToString() -or $journal.Status -ne 'CLEANED'){
                    throw 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
                }
            }catch{throw 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'}
        }
        $current=Get-HyperVWindowsSlotLicenseStatus -RunId $RunId -Credential $Credential -Persist -StateRoot $lab.StateRoot @binding
        $decision=Get-LabWindowsActivationDecision -License $current -Intent $saved
        if($decision.Action -ne 'NoOp'){throw $decision.Code}
        return $current
    }
    Invoke-HyperVWindowsSlotActivation -RunId $RunId -Credential $Credential -StateRoot $lab.StateRoot @activationArguments
}

function Resume-LabWindowsSlotActivation {
    <#
    .SYNOPSIS
        Aktiviert einen nach manueller OOBE fortzusetzenden Windows-Slot.
    .DESCRIPTION
        Der Aufruf verwendet ausschliesslich das unmittelbar uebergebene
        Gast-Credential. Er ersetzt kein fehlendes DPAPI-Secret und speichert
        weder Kennwort noch Credential. War die VM vorher ausgeschaltet, wird
        sie nach der Aktivierung auch bei einem Aktivierungsfehler wieder
        gestoppt, ausser LeaveRunning ist angefordert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$LeaveRunning,
        [string]$StateRoot,
        [AllowNull()]$WindowsActivation,
        [ValidateScript({-not [string]::IsNullOrWhiteSpace($_)})][string]$ExternalSwitchName
    )

    # Validate an explicit override before reading the run or starting its VM.
    $activationArguments=@{}
    if($PSBoundParameters.ContainsKey('WindowsActivation')){
        $activationArguments.WindowsActivation=Resolve-LabWindowsActivationIntent -Intent $WindowsActivation -RequireExplicit
    }
    if($PSBoundParameters.ContainsKey('ExternalSwitchName')){$activationArguments.ExternalSwitchName=$ExternalSwitchName}
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $effectiveIntent=if($activationArguments.ContainsKey('WindowsActivation')){$activationArguments.WindowsActivation}else{
        Resolve-LabWindowsActivationIntent -Intent $lab.Instance.windowsActivationIntent -Isolated:([string]$lab.Run.metadata.networkIntent -eq 'isolated')
    }
    $synced = Sync-LabRunRuntimeState -Run $lab.Run -StateRoot $lab.StateRoot
    $runtimeState = [string]$synced.Runtime.State
    if ($runtimeState -notin @('RUNNING', 'STOPPED')) {
        throw "HYPERV_WINDOWS_ACTIVATION_RESUME_STATE_UNSUPPORTED: $runtimeState"
    }

    $startedByResume = $runtimeState -eq 'STOPPED'
    $stoppedByResume = $false
    $activation = $null
    $result = $null
    try {
        if ($startedByResume) {
            $null = Start-HyperVLabEnvironment -RunId $RunId -SkipWindowsActivationReconcile -StateRoot $lab.StateRoot
        }
        $activation = Invoke-LabWindowsSlotActivationReconcile -RunId $RunId -Credential $Credential -StateRoot $lab.StateRoot @activationArguments
        $result = [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.WindowsActivationResume/1.0'
            RunId = [string]$lab.Run.runId
            StartedByResume = $startedByResume
            StoppedByResume = $false
            ActivationIntent = $effectiveIntent
            Activation = $activation
        }
    }
    finally {
        if ($startedByResume -and -not $LeaveRunning) {
            $null = Stop-HyperVLabEnvironment -RunId $RunId -StateRoot $lab.StateRoot
            $stoppedByResume = $true
            if ($result) { $result.StoppedByResume = $stoppedByResume }
        }
    }
    return $result
}
