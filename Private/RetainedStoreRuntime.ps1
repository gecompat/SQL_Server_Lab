# Bounded, read-only observation and one non-forced volume removal. All commands
# after discovery are pinned to the observed context/connection; raw CLI output
# remains inside this boundary and never becomes a public error message.
function Invoke-LabRetainedStoreNative {
    [CmdletBinding()]
    param([ValidateSet('docker','podman')][string]$Provider, [string[]]$Arguments,
        [ValidateRange(1,120)][int]$TimeoutSeconds=20)
    try {
        $cli=Get-LabHostToolInvocation -Name $Provider
        Invoke-LabProgressNativeCommand -FilePath $cli -ArgumentList $Arguments `
            -Phase Cleanup -TimeoutSeconds $TimeoutSeconds
    }
    catch { throw 'RETAINED_STORE_RUNTIME_COMMAND_UNVERIFIABLE' }
}

function Get-LabRetainedStoreRuntimeContext {
    [CmdletBinding()]
    param([ValidateSet('docker','podman')][string]$Provider)
    function Read-ContextJson {
        param([string[]]$Arguments)
        $result=Invoke-LabRetainedStoreNative -Provider $Provider -Arguments $Arguments
        if ($result.ExitCode -ne 0) { throw 'RETAINED_STORE_RUNTIME_UNAVAILABLE' }
        try { ($result.Output -join "`n") | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
        catch { throw 'RETAINED_STORE_RUNTIME_UNVERIFIABLE' }
    }
    $evidence=[ordered]@{
        Provider=$Provider; Available=$true
        HostPlatform=if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'}
    }
    if ($Provider -ceq 'docker') {
        $evidence.Contexts=@(Read-ContextJson @('context','inspect'))
        $evidence.Info=Read-ContextJson @('info','--format','{{json .}}')
    }
    else {
        $evidence.Info=Read-ContextJson @('info','--format','json')
        $evidence.Machines=@(Read-ContextJson @('machine','list','--format','json'))
        $evidence.Connections=@(Read-ContextJson @('system','connection','list','--format','json'))
    }
    $scope=ConvertTo-LabContainerRuntimeScope -Evidence ([pscustomobject]$evidence)
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$' -or
        $scope.Binding.HostMode -cin @('REMOTE','UNKNOWN')) { throw 'RETAINED_STORE_RUNTIME_SCOPE_UNVERIFIABLE' }
    [pscustomobject]@{Provider=$Provider; RuntimeScopeId=$scope.RuntimeId; Arguments=@(
        $(if($Provider -ceq 'docker'){'--context'}else{'--connection'}), [string]$scope.Binding.DisplayName)}
}

function Get-LabRetainedStoreVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName)
    $result=Invoke-LabRetainedStoreNative -Provider $Context.Provider `
        -Arguments (@($Context.Arguments)+@('volume','inspect',$VolumeName))
    if ($result.ExitCode -ne 0) {
        $listing=Invoke-LabRetainedStoreNative -Provider $Context.Provider `
            -Arguments (@($Context.Arguments)+@('volume','ls','--format','{{.Name}}'))
        $names=@($listing.Output | ForEach-Object {$_.Trim()} | Where-Object {$_})
        if ($listing.ExitCode -ne 0 -or $VolumeName -cin $names -or
            @($names | Where-Object {$_ -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$'}).Count -gt 0) {
            throw 'RETAINED_STORE_ABSENCE_UNVERIFIABLE'
        }
        return [pscustomobject]@{Status='MISSING'; VolumeName=$VolumeName}
    }
    try { $items=@(($result.Output -join "`n") | ConvertFrom-Json -Depth 40 -ErrorAction Stop) }
    catch { throw 'RETAINED_STORE_VOLUME_UNVERIFIABLE' }
    if ($items.Count -ne 1 -or [string]$items[0].Name -cne $VolumeName) { throw 'RETAINED_STORE_VOLUME_UNVERIFIABLE' }
    $volume=$items[0]
    $attached=Invoke-LabRetainedStoreNative -Provider $Context.Provider `
        -Arguments (@($Context.Arguments)+@('ps','-a','-q','--filter',"volume=$VolumeName"))
    if ($attached.ExitCode -ne 0) { throw 'RETAINED_STORE_ATTACHMENTS_UNVERIFIABLE' }
    [pscustomobject]@{
        Status='AVAILABLE'; VolumeName=$VolumeName; Labels=$volume.Labels
        CreatedAt=if($volume.CreatedAt -is [datetime]){$volume.CreatedAt.ToUniversalTime().ToString('o')}else{[string]$volume.CreatedAt}
        Driver=[string]$volume.Driver
        Options=$volume.Options; AttachedContainers=@($attached.Output | Where-Object {$_ -match '\S'})
    }
}

function Remove-LabRetainedStoreVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName)
    # No force: a last-moment attachment must also be rejected by the engine.
    $result=Invoke-LabRetainedStoreNative -Provider $Context.Provider `
        -Arguments (@($Context.Arguments)+@('volume','rm',$VolumeName)) -TimeoutSeconds 60
    if ($result.ExitCode -ne 0) { throw 'RETAINED_STORE_DELETE_NOT_CONFIRMED' }
}
