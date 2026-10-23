# Session-local bounded read-only jobs. Polls never dispatch or retry SQL work.
function Test-UiTlsLiveQualificationAvailable {
    return ($IsWindows -and $PSVersionTable.PSVersion -ge [version]'7.5')
}

function Start-UiTlsLiveQualificationJob {
    param([hashtable]$Records,[hashtable]$Jobs,[string]$ModulePath,[string]$Body,[hashtable]$PersistentJobs=@{})
    if(-not (Test-UiTlsLiveQualificationAvailable)){throw 'TLS_LIVE_UI_UNAVAILABLE'}
    if($Records.Count -ge 64 -or ($Jobs.Count+$PersistentJobs.Count) -ge 256){throw 'TLS_LIVE_UI_CAPACITY'}
    foreach($record in $Records.Values){
        if([string]$record.Job.State -cnotin @('Completed','Failed','Stopped')){throw 'TLS_LIVE_UI_BUSY'}
    }
    $target=& (Get-Module SqlServerLab) {param($b) Get-LabTlsLiveQualificationHttpSelection -Body $b} $Body
    $id=[guid]::NewGuid().ToString('n');$started=[DateTimeOffset]::UtcNow.ToString('o')
    $job=Start-ThreadJob -Name "sql-lab-ui-tls-$id" -ArgumentList $ModulePath,$Body -ScriptBlock {
        param($path,$body)
        $ErrorActionPreference='Stop';$InformationPreference='SilentlyContinue';$WarningPreference='SilentlyContinue'
        try {
            Import-Module $path -Force 6>$null
            & (Get-Module SqlServerLab) {param($b) Invoke-LabTlsLiveQualificationHttpRequest -Body $b} $body
        }catch{throw 'TLS_LIVE_HTTP_REJECTED'}
    }
    $record=[pscustomobject]@{Id=$id;Action='TLS-Liveprüfung';StartedAt=$started;LastActivityAt=$started;LastObservedLineCount=0;Job=$job;Target=$target}
    # Keep custody in the existing UI shutdown path before returning acceptance.
    $Jobs[$id]=$record;$Records[$id]=$record
    [pscustomobject]@{Status='ACCEPTED';Id=$id}
}

function Get-UiTlsLiveQualificationJob {
    param([hashtable]$Records,[string]$Id)
    if($Id -cnotmatch '^[a-f0-9]{32}$' -or -not $Records.ContainsKey($Id)){throw 'TLS_LIVE_HTTP_REJECTED'}
    $record=$Records[$Id]
    if([string]$record.Job.State -cin @('Running','NotStarted')){return [pscustomobject]@{Status='PENDING';Id=$Id}}
    if([string]$record.Job.State -cne 'Completed'){throw 'TLS_LIVE_HTTP_REJECTED'}
    $output=@(Receive-Job -Job $record.Job -Keep -ErrorAction Stop)
    if($output.Count -ne 1){throw 'TLS_LIVE_HTTP_REJECTED'}
    $result=& (Get-Module SqlServerLab) {
        param($value,$target,$started)
        ConvertTo-LabTlsLiveQualificationHttpResult -Result $value -Target $target -Started ([DateTimeOffset]::Parse($started))
    } $output[0] $record.Target $record.StartedAt
    if([DateTimeOffset]::Parse($result.ExpiresAtUtc) -le [DateTimeOffset]::UtcNow){throw 'TLS_LIVE_HTTP_REJECTED'}
    [pscustomobject]@{Status='COMPLETE';Id=$Id;Result=$result}
}
