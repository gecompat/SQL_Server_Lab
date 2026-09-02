#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den Runtime-Scope-Vertrag read-only gegen Docker und Podman.
.DESCRIPTION
    Erzeugt, startet, stoppt oder entfernt keine Runtime-Ressource. Vor und nach
    der Scope-Inspektion werden Container-, Volume-, Context-/Connection- und
    Machine-Bindings verglichen.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

if ($ShowHelp -or @($RemainingArgs) -match '^(-h|--help|/\?|-\?)$') { Get-Help -Full -Name $PSCommandPath | Out-Host; return }
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$schemaPath=Join-Path $repoRoot 'Schemas/container-runtime-scope.schema.json'
$failures=[Collections.Generic.List[string]]::new();$passed=0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
$mutexName=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
$runtimeMutex=[Threading.Mutex]::new($false,$mutexName);$mutexAcquired=$false

function Get-RuntimeResourceFingerprint {
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    $lines=[Collections.Generic.List[string]]::new()
    $runtimeInvocation=& $module {param($p)Get-LabHostToolInvocation -Name $p} $Provider
    if($Provider -eq 'docker'){
        $lines.Add("context=$((& $runtimeInvocation context show 2>$null).Trim())")
        @(& $runtimeInvocation ps -aq --no-trunc 2>$null|Sort-Object)|ForEach-Object{$lines.Add("container=$_")}
        @(& $runtimeInvocation volume ls -q 2>$null|Sort-Object)|ForEach-Object{$lines.Add("volume=$_")}
    }else{
        @(& $runtimeInvocation ps -aq --no-trunc 2>$null|Sort-Object)|ForEach-Object{$lines.Add("container=$_")}
        @(& $runtimeInvocation volume ls -q 2>$null|Sort-Object)|ForEach-Object{$lines.Add("volume=$_")}
        $machines=@(& $runtimeInvocation machine list --format json 2>$null|ConvertFrom-Json)
        @($machines|Sort-Object Name)|ForEach-Object{$lines.Add("machine=$($_.Name)|$($_.Running)|$($_.Default)|$($_.VMType)")}
        $connections=@(& $runtimeInvocation system connection list --format json 2>$null|ConvertFrom-Json)
        @($connections|Sort-Object Name)|ForEach-Object{$lines.Add("connection=$($_.Name)|$($_.Default)|$($_.IsMachine)|$($_.ReadWrite)")}
    }
    return ($lines -join "`n")
}

Write-Host '';Write-Host 'SQL_Server_Lab - Container Runtime Scope Acceptance' -ForegroundColor Cyan
try{
    $mutexAcquired=$runtimeMutex.WaitOne([TimeSpan]::FromMinutes(10))
    if(-not $mutexAcquired){throw 'CONTAINER_RUNTIME_SCOPE_MUTEX_TIMEOUT'}
    foreach($provider in @('docker','podman')){
        $resolution=& $module {param($p)Resolve-LabHostTool -Name $p} $provider
        if(-not $resolution.Available){Add-CheckResult -Name "$provider CLI zentral aufloesbar" -Success $false;continue}
        $before=Get-RuntimeResourceFingerprint -Provider $provider
        $scope=& $module {param($p)Get-LabContainerRuntimeScope -Provider $p} $provider
        $backing=& $module {param($s)Get-LabContainerRuntimeHostBackingEvidence -Scope $s} $scope
        $usage=@(& $module {param($p)Get-LabRuntimeStorageUsage -Provider $p} $provider)
        $managedImages=@(& $module {param($p)Get-LabManagedRuntimeImageInventory -Provider $p} $provider)
        $after=Get-RuntimeResourceFingerprint -Provider $provider
        $json=$scope|ConvertTo-Json -Depth 20
        Add-CheckResult -Name "$provider Runtime-Scope ist real eindeutig und schemawahr" -Success (
            $scope.Status -eq 'AVAILABLE' -and $scope.RuntimeId -match '^runtime-scope-[a-f0-9]{24}$' -and
            $scope.Binding.EndpointKind -ne 'UNKNOWN' -and $scope.Binding.BackendKind -ne 'UNKNOWN' -and
            ($json|Test-Json -SchemaFile $schemaPath))
        Add-CheckResult -Name "$provider Shared-Runtime ist gegen Management geschuetzt" -Success (
            $scope.Ownership.Status -eq 'SHARED_EXTERNAL' -and $scope.Ownership.MutationPolicy -eq 'REPORT_ONLY' -and
            -not $scope.Summary.CanManageRuntime -and 'REMOVE_RUNTIME' -in @($scope.BlockedActions))
        Add-CheckResult -Name "$provider Evidence ist pfad- und endpunktsanitisiert" -Success (
            $json -notmatch '(?i)(npipe:|ssh://|tcp://|identitypath|dockerrootdir|graphroot|[a-z]:\\\\|/var/lib/)')
        $localBackingValid = if ($scope.Binding.HostMode -in @('WINDOWS_WSL2','WINDOWS_VM','MACOS_VM')) {
            $backing.Status -eq 'VERIFIED' -and @($backing.Items | Where-Object Kind -eq 'BACKING_STORE').Count -gt 0 -and
            @($backing.Items | Where-Object { $_.Kind -eq 'BACKING_STORE' -and (-not (Test-Path -LiteralPath $_.Path) -or [long]$_.Bytes -le 0) }).Count -eq 0
        }
        elseif ($scope.Binding.HostMode -eq 'LINUX_NATIVE') {
            $backing.Status -eq 'VERIFIED' -and @($backing.Items | Where-Object { $_.Kind -eq 'BACKING_STORE' -and (Test-Path -LiteralPath $_.Path) }).Count -gt 0
        }
        else { $backing.Status -eq 'REMOTE_EXTERNAL' }
        Add-CheckResult -Name "$provider physisches Host-Backing ist real und read-only aufgeloest" -Success (
            $localBackingValid -and $scope.PhysicalBacking.HostBackingStatus -eq $backing.Status -and
            $scope.PhysicalBacking.BackingStoreCount -eq @($backing.Items | Where-Object Kind -eq 'BACKING_STORE').Count)
        Add-CheckResult -Name "$provider Images, Container, Volumes und Build-Cache sind normalisiert inventarisiert" -Success (
            @($usage).Count -eq 4 -and @($usage.Category | Sort-Object -Unique).Count -eq 4 -and
            @($usage | Where-Object Status -eq 'UNVERIFIABLE').Count -eq 0 -and
            @($managedImages | Where-Object { $_.ImageKey -notmatch '^[a-f0-9]{64}$' }).Count -eq 0)
        Add-CheckResult -Name "$provider Inspektion veraendert keine Runtime-Ressource oder Auswahl" -Success ($before -ceq $after)
    }
}finally{
    if($mutexAcquired){$runtimeMutex.ReleaseMutex();$mutexAcquired=$false}
    $runtimeMutex.Dispose()
}
Write-Host '';Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1};exit 0
