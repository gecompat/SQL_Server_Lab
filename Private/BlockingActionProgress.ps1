# Ein eigener lokaler Runspace rendert nur den bestehenden Reporter. Dadurch
# bleibt die Anzeige auch waehrend synchroner COM-/WMI-Aufrufe aktuell.
if(-not (Get-Variable -Name LabBlockingActionHandle -Scope Script -ErrorAction SilentlyContinue)){$script:LabBlockingActionHandle=$null}

function Start-LabBlockingActionProgress {
    [CmdletBinding()]
    param(
        [ValidateSet('GuestWait','Cleanup')][string]$Phase='GuestWait',
        [object]$Progress
    )
    if($script:LabBlockingActionHandle -and -not $script:LabBlockingActionHandle.Completed){
        return [pscustomobject]@{Borrowed=$true;Completed=$false;Progress=$script:LabBlockingActionHandle.Progress}
    }
    $ownsProgress=$null -eq $Progress
    if($ownsProgress){$Progress=Start-LabActionProgress -Phase $Phase}
    $handle=[pscustomobject]@{Borrowed=$false; Progress=$Progress; OwnsProgress=$ownsProgress; Signal=$null; Pipeline=$null; Pending=$null; Runspace=$null; Completed=$false}
    if(-not $Progress.Enabled){return $handle}
    try {
        $handle.Signal=[Threading.ManualResetEventSlim]::new($false)
        $handle.Runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host)
        $handle.Runspace.Open()
        $handle.Pipeline=[Management.Automation.PowerShell]::Create()
        $handle.Pipeline.Runspace=$handle.Runspace
        $worker={
            param($Directory,$Progress,$Signal,$OwnsProgress,$ProgressStream)
            . (Join-Path $Directory 'ConsoleUi.ps1')
            . (Join-Path $Directory 'ActionProgress.ps1')
            $ProgressPreference='Continue'
            try {
                while(-not $Signal.Wait(200)){
                    if($ProgressStream.Count -gt 32){$ProgressStream.Clear()}
                    Update-LabActionProgress -Progress $Progress
                }
            }
            finally {if($OwnsProgress){Stop-LabActionProgress -Progress $Progress}}
        }
        $null=$handle.Pipeline.AddScript($worker.ToString()).AddArgument($PSScriptRoot).AddArgument($Progress).AddArgument($handle.Signal).AddArgument($ownsProgress).AddArgument($handle.Pipeline.Streams.Progress)
        $handle.Pending=$handle.Pipeline.BeginInvoke()
        $script:LabBlockingActionHandle=$handle
        return $handle
    }
    catch {Stop-LabBlockingActionProgress -Handle $handle; throw}
}

function Stop-LabBlockingActionProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Handle)
    if($Handle.Completed){return}
    $Handle.Completed=$true
    if($Handle.Borrowed){return}
    try {
        if($Handle.Signal){$Handle.Signal.Set()}
        if($Handle.Pending){$null=$Handle.Pipeline.EndInvoke($Handle.Pending)}
    }
    finally {
        if([object]::ReferenceEquals($script:LabBlockingActionHandle,$Handle)){$script:LabBlockingActionHandle=$null}
        if($Handle.Pipeline){$Handle.Pipeline.Dispose()}
        if($Handle.Runspace){$Handle.Runspace.Dispose()}
        if($Handle.Signal){$Handle.Signal.Dispose()}
        if($Handle.OwnsProgress){Stop-LabActionProgress -Progress $Handle.Progress}
    }
}
