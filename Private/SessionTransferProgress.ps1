# Der Aufrufer besitzt die Session; nur die lokale Kopierpipeline gehoert uns.
function Invoke-LabProgressPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PowerShell]$Pipeline,
        [object]$Progress,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=3600
    )
    $ownsProgress=$null -eq $Progress
    if($ownsProgress){$Progress=Start-LabActionProgress -Phase Transfer}
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    try {
        $pending=$Pipeline.BeginInvoke()
        while(-not $pending.IsCompleted){
            Update-LabActionProgress -Progress $Progress -Phase Transfer
            # Rohe Remoting-ProgressRecords enthalten potentiell Gastpfade.
            $Pipeline.Streams.Progress.Clear()
            if($elapsed.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'SESSION_TRANSFER_OPERATION_TIMEOUT'}
            $null=$pending.AsyncWaitHandle.WaitOne(200)
        }
        try {$Pipeline.EndInvoke($pending)}
        catch {
            if($Pipeline.Streams.Error.Count -gt 0){$PSCmdlet.ThrowTerminatingError($Pipeline.Streams.Error[0])}
            if($Pipeline.InvocationStateInfo.Reason -is [System.Management.Automation.RuntimeException]){
                $PSCmdlet.ThrowTerminatingError($Pipeline.InvocationStateInfo.Reason.ErrorRecord)
            }
            throw
        }
        if($Pipeline.HadErrors -and $Pipeline.Streams.Error.Count -gt 0){$PSCmdlet.ThrowTerminatingError($Pipeline.Streams.Error[0])}
    }
    finally {
        try {
            if($Pipeline.InvocationStateInfo.State -in @('Running','Stopping')){$Pipeline.Stop()}
            $Pipeline.Dispose()
        }
        finally {if($ownsProgress){Stop-LabActionProgress -Progress $Progress}}
    }
}

function Copy-LabProgressSessionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [ValidateSet('ToSession','FromSession')][string]$Direction='ToSession',
        [object]$Progress
    )
    $pipeline=[System.Management.Automation.PowerShell]::Create()
    try {
        $null=$pipeline.AddCommand('Microsoft.PowerShell.Management\Copy-Item').AddParameter('LiteralPath',$SourcePath).AddParameter('Destination',$DestinationPath).AddParameter($Direction,$Session).AddParameter('Force',$true).AddParameter('ErrorAction','Stop')
    }
    catch {$pipeline.Dispose();throw}
    Invoke-LabProgressPipeline -Pipeline $pipeline -Progress $Progress
}
