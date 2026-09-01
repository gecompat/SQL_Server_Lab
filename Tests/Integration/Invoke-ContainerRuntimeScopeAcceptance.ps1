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
    if($Provider -eq 'docker'){
        $lines.Add("context=$((& docker context show 2>$null).Trim())")
        @(& docker ps -aq --no-trunc 2>$null|Sort-Object)|ForEach-Object{$lines.Add("container=$_")}
        @(& docker volume ls -q 2>$null|Sort-Object)|ForEach-Object{$lines.Add("volume=$_")}
    }else{
        @(& podman ps -aq --no-trunc 2>$null|Sort-Object)|ForEach-Object{$lines.Add("container=$_")}
        @(& podman volume ls -q 2>$null|Sort-Object)|ForEach-Object{$lines.Add("volume=$_")}
        $machines=@(& podman machine list --format json 2>$null|ConvertFrom-Json)
        @($machines|Sort-Object Name)|ForEach-Object{$lines.Add("machine=$($_.Name)|$($_.Running)|$($_.Default)|$($_.VMType)")}
        $connections=@(& podman system connection list --format json 2>$null|ConvertFrom-Json)
        @($connections|Sort-Object Name)|ForEach-Object{$lines.Add("connection=$($_.Name)|$($_.Default)|$($_.IsMachine)|$($_.ReadWrite)")}
    }
    return ($lines -join "`n")
}

Write-Host '';Write-Host 'SQL_Server_Lab - Container Runtime Scope Acceptance' -ForegroundColor Cyan
try{
    $mutexAcquired=$runtimeMutex.WaitOne([TimeSpan]::FromMinutes(10))
    if(-not $mutexAcquired){throw 'CONTAINER_RUNTIME_SCOPE_MUTEX_TIMEOUT'}
    foreach($provider in @('docker','podman')){
        if(-not(Get-Command $provider -ErrorAction SilentlyContinue)){Add-CheckResult -Name "$provider CLI verfuegbar" -Success $false;continue}
        $before=Get-RuntimeResourceFingerprint -Provider $provider
        $scope=& $module {param($p)Get-LabContainerRuntimeScope -Provider $p} $provider
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
        Add-CheckResult -Name "$provider Inspektion veraendert keine Runtime-Ressource oder Auswahl" -Success ($before -ceq $after)
    }
}finally{
    if($mutexAcquired){$runtimeMutex.ReleaseMutex();$mutexAcquired=$false}
    $runtimeMutex.Dispose()
}
Write-Host '';Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1};exit 0
