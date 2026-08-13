[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ModulePath,

    [Parameter(Mandatory)]
    [string]$StateRoot,

    [ValidateRange(1, 300)]
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Continue'
Import-Module $ModulePath -Force
$module = Get-Module SqlServerLab
$leasePath = Join-Path $StateRoot 'scheduler\leases\host.json'
$stopPath = Join-Path $StateRoot 'scheduler\stop-host.request'

$leaseAcquired = & $module {
    param($Path, $Root, $ProcessId)
    Invoke-WithLabWorkflowLock -StateRoot $Root -ScriptBlock {
        $existing = Read-LabWorkflowJson -Path $Path
        if ($null -ne $existing -and [int]$existing.processId -ne $ProcessId -and -not [string]::IsNullOrWhiteSpace([string]$existing.updatedAt)) {
            $fresh = (([DateTime]::UtcNow - ([DateTime]$existing.updatedAt).ToUniversalTime()).TotalSeconds -lt 20)
            $alive = $fresh
            if ([string]$existing.host -eq [Environment]::MachineName) {
                try { $null = Get-Process -Id ([int]$existing.processId) -ErrorAction Stop; $alive = $true } catch { $alive = $false }
            }
            if ($alive) { return $false }
        }
        $lease = [pscustomobject]@{ contract = 'SqlServerLab.SchedulerLease/1.0'; host = [Environment]::MachineName; processId = $ProcessId; updatedAt = [DateTime]::UtcNow.ToString('o') }
        Write-LabArtifactJsonAtomic -Path $Path -InputObject $lease
        return $true
    }
} $leasePath $StateRoot $PID

if (-not $leaseAcquired) { return }

while (-not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
    $lease = [pscustomobject][ordered]@{
        contract = 'SqlServerLab.SchedulerLease/1.0'
        host = [Environment]::MachineName
        processId = $PID
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    & $module { param($Path, $Value) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Value } $leasePath $lease
    try {
        & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $StateRoot
        & $module { param($Root) Invoke-SqlServerLabOperationProbe -DueOnly -StateRoot $Root | Out-Null } $StateRoot
        & $module { param($Root) Invoke-LabCandidateSound -StateRoot $Root } $StateRoot
    }
    catch {
        $line = "{0} Hostfehler: {1}" -f [DateTime]::UtcNow.ToString('o'), $_.Exception.Message
        Add-Content -LiteralPath (Join-Path $StateRoot 'scheduler\logs\host.log') -Value $line -Encoding utf8
    }
    Start-Sleep -Seconds $PollSeconds
}

Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
$ownedLease = Get-Content -LiteralPath $leasePath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($ownedLease -and [int]$ownedLease.processId -eq $PID) {
    Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
}
