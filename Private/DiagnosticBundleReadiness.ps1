function Invoke-LabDiagnosticReadinessProcess {
    param([string]$Provider,[string]$Operation,[int]$TimeoutSeconds=45)
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID -ErrorAction Stop).Path)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',
        (Join-Path $script:ModuleRoot 'Tools/Read-SqlServerLabDiagnosticReadiness.ps1'),'-Provider',$Provider,'-Operation',$Operation)) {
        $start.ArgumentList.Add($argument)
    }
    Invoke-LabDiagnosticBoundedProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds
}

function Invoke-LabDiagnosticBoundedProcess {
    # No temporary output files; both pipes are drained with a shared byte limit.
    param([Diagnostics.ProcessStartInfo]$StartInfo,[int]$TimeoutSeconds=45,[int]$MaximumBytes=65536)
    $process=$null;$memory=[IO.MemoryStream]::new();$reason='DIAGNOSTIC_READINESS_FAILED'
    $confirmed=$true;$success=$false;$total=0;$timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $process=[Diagnostics.Process]::Start($StartInfo);$confirmed=$false
        $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
        $buffers=@([byte[]]::new(4096),[byte[]]::new(4096));$done=@($false,$false)
        $tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096))
        while ($true) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $reason='DIAGNOSTIC_READINESS_TIMEOUT';break }
            for ($index=0;$index -lt 2;$index++) {
                if (-not $done[$index] -and $tasks[$index].IsCompleted) {
                    $count=$tasks[$index].GetAwaiter().GetResult()
                    if ($count -eq 0) { $done[$index]=$true;continue }
                    $total+=$count
                    if ($total -gt $MaximumBytes) { $reason='DIAGNOSTIC_READINESS_OUTPUT_LIMIT';throw 'OUTPUT_LIMIT' }
                    if ($index -eq 0) { $memory.Write($buffers[$index],0,$count) }
                    $tasks[$index]=$pipes[$index].ReadAsync($buffers[$index],0,4096)
                }
            }
            if ($process.HasExited -and $done[0] -and $done[1]) {
                $confirmed=$true;$success=$process.ExitCode -eq 0;break
            }
            Start-Sleep -Milliseconds 10
        }
    }
    catch { $success=$false }
    finally {
        if ($process -and -not $confirmed) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $confirmed=$process.WaitForExit(5000)
                }
                else {
                    # A descendant can retain a pipe after the direct child exits.
                    # Do not equate that parent's exit with confirmed tree cleanup.
                    $confirmed=$done[0] -and $done[1]
                }
            }
            catch { $confirmed=$false }
        }
        if (-not $confirmed) { $reason='DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED';$success=$false }
        if ($process) { $process.Dispose() }
    }
    try {
        if (-not $success) { return [pscustomobject]@{Success=$false;Reason=$reason;Value=$null} }
        $value=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray()) | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        return [pscustomobject]@{Success=$true;Reason='NONE';Value=$value}
    }
    catch { return [pscustomobject]@{Success=$false;Reason='DIAGNOSTIC_READINESS_RESPONSE_INVALID';Value=$null} }
    finally { $memory.Dispose() }
}

function Get-LabDiagnosticReadiness {
    param([string]$Provider,[string]$Operation,[switch]$Skip)
    $result=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';Reason='DIAGNOSTIC_READINESS_NOT_REQUESTED';Status='UNKNOWN';Checks=@()}
    if ($Skip) { return $result }
    try {
        $response=Invoke-LabDiagnosticReadinessProcess -Provider $Provider -Operation $Operation
        if (-not $response.Success) {
            $result.EvidenceStatus='UNAVAILABLE'
            $allowed=@('DIAGNOSTIC_READINESS_FAILED','DIAGNOSTIC_READINESS_TIMEOUT','DIAGNOSTIC_READINESS_OUTPUT_LIMIT','DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED','DIAGNOSTIC_READINESS_RESPONSE_INVALID')
            $result.Reason=if($response.Reason -cin $allowed){$response.Reason}else{'DIAGNOSTIC_READINESS_FAILED'}
            return $result
        }
        $value=$response.Value
        if ($value.ContractVersion -cne 'SqlServerLab.DiagnosticProviderReadiness/1.0' -or $value.Provider -cne $Provider -or
            $value.Operation -cne $Operation -or $value.Status -cnotin @('READY','READY_WITH_WARNINGS','NOT_READY') -or
            @($value.Checks).Count -lt 1 -or @($value.Checks).Count -gt 24) { throw 'INVALID_READINESS' }
        $codes=@('OS_SUPPORTED','OS_UNSUPPORTED','POWERSHELL_SUPPORTED','POWERSHELL_7_2_REQUIRED',
            'REPOSITORY_PRESENT','REPOSITORY_INCOMPLETE','MANIFEST_VALID','MANIFEST_INVALID','MODULE_IMPORTED','MODULE_IMPORT_FAILED',
            'MODULE_EXPORTS_PRESENT','MODULE_EXPORTS_MISSING','PROVIDER_OS_UNSUPPORTED','PROVIDER_NOT_INSTALLED',
            'PROVIDER_ACCESS_DENIED','PROVIDER_UNREACHABLE','PROVIDER_INSTALLATION_INCOMPLETE','PROVIDER_REACHABLE',
            'TOOL_RESOLUTION_FAILED','TOOL_NOT_INSTALLED','TOOL_NATIVE_PATH_REQUIRED','TOOL_EXECUTION_DENIED',
            'PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID','STORAGE_CONFIGURED',
            'STORAGE_CONFIGURATION_REQUIRED','STORAGE_CONFIGURATION_INVALID','OPERATION_PROVIDER_UNSUPPORTED',
            'ELEVATION_PRESENT','ELEVATION_REQUIRED','TARGET_AUTHORIZATION_REQUIRED','READ_ONLY_PROBE_COMPLETED','BOOTSTRAP_REQUIRED')
        $categories=@('OperatingSystem','PowerShell','Repository','Manifest','ModuleImport','Exports','Provider',
            'Installation','Permission','Reachability','Storage','OperationRights')
        $checks=@(foreach ($check in $value.Checks) {
            if ($check.Category -isnot [string] -or $check.Category -cnotin $categories -or
                $check.Code -isnot [string] -or $check.Code -cnotin $codes -or $check.Status -isnot [string] -or
                $check.Status -cnotin @('PASS','BLOCKED','WARNING','NOT_CHECKED')) { throw 'INVALID_READINESS' }
            [pscustomobject]@{Category=$check.Category;Code=$check.Code;Status=$check.Status}
        })
        $expected=if(@($checks | Where-Object Status -CEQ 'BLOCKED').Count){'NOT_READY'}elseif(@($checks | Where-Object { $_.Status -cin @('WARNING','NOT_CHECKED') }).Count){'READY_WITH_WARNINGS'}else{'READY'}
        if ($value.Status -cne $expected) { throw 'INVALID_READINESS' }
        $result.EvidenceStatus='OBSERVED';$result.Reason='NONE';$result.Status=$value.Status;$result.Checks=$checks
    }
    catch { $result.EvidenceStatus='UNAVAILABLE';$result.Reason='DIAGNOSTIC_READINESS_RESPONSE_INVALID' }
    return $result
}
