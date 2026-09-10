# Hostseitiger Fortschritt fuer genau den vom Aufrufer gestarteten Job.
function Receive-LabProgressJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Job]$Job,
        [ValidateSet('GuestWait','Transfer')][string]$Phase='GuestWait',
        [object]$Progress,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=86400
    )
    $ownsProgress=$null -eq $Progress
    if($ownsProgress){$Progress=Start-LabActionProgress -Phase $Phase}
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    try {
        while($Job.JobStateInfo.State -notin @('Completed','Failed','Stopped')) {
            Update-LabActionProgress -Progress $Progress -Phase $Phase
            if($elapsed.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'GUEST_JOB_OPERATION_TIMEOUT'}
            if($Job.JobStateInfo.State -eq 'Blocked'){throw 'GUEST_JOB_INTERACTIVE_INPUT_REQUIRED'}
            $null=$Job.Finished.WaitOne(200)
        }
        # Ergebnisse und ErrorRecords bleiben erhalten; verspätete rohe
        # Gast-ProgressRecords dürfen den erlaubten Hostreporter nicht ersetzen.
        $previousProgressPreference=$ProgressPreference
        try {
            $ProgressPreference='SilentlyContinue'
            Receive-Job -Job $Job -ErrorAction Stop
        }
        finally {$ProgressPreference=$previousProgressPreference}
        if($Job.JobStateInfo.State -eq 'Stopped'){throw 'GUEST_JOB_OPERATION_STOPPED'}
        if($Job.JobStateInfo.State -eq 'Failed'){
            if($Job.JobStateInfo.Reason){throw $Job.JobStateInfo.Reason}
            throw 'GUEST_JOB_OPERATION_FAILED'
        }
    }
    finally {
        try {
            if($Job.JobStateInfo.State -notin @('Completed','Failed','Stopped')){Stop-Job -Job $Job -ErrorAction Stop}
            Remove-Job -Job $Job -ErrorAction Stop
        }
        finally {if($ownsProgress){Stop-LabActionProgress -Progress $Progress}}
    }
}

function Wait-LabProgressDelay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Progress,
        [ValidateRange(0,60000)][int]$Milliseconds
    )
    $null=Wait-LabProgressTask -Task ([Threading.Tasks.Task]::Delay($Milliseconds)) -Progress $Progress
}
