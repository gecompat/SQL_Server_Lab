# Session-private references. No target is discovered from a browser path.
function New-UiTlsCreationStore {
    @{SessionId=[guid]::NewGuid().ToString('n');Tickets=@{};Requests=@{}}
}

function Test-UiTlsCreationBlocked {
    param([hashtable]$Store)
    foreach($ticket in $Store.Tickets.Values){
        if($ticket.SessionId -cne $Store.SessionId -or -not $ticket.Job -or
            [string]$ticket.Job.State -cne 'Completed' -or $ticket.Status -cnotin @('COMPLETE','REJECTED')){return $true}
    }
    return $false
}

function Get-UiTlsTargetRequest {
    param([string]$Body)
    try {
        if($Body.Length -gt 1024){throw 'INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $doc=[Text.Json.JsonDocument]::Parse($Body,$options)
        try {
            if($doc.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'INVALID'}
            $p=@{};$keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($item in $doc.RootElement.EnumerateObject()){
                if($item.Name -cnotin @('Ref','Action','RequestId') -or -not $keys.Add($item.Name) -or $item.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INVALID'}
                $p[$item.Name]=$item.Value.GetString()
            }
            if($p.Count -ne 3 -or $p.Ref -cnotmatch '\A[a-f0-9]{32}\z' -or $p.RequestId -cnotmatch '\A[a-f0-9]{32}\z' -or
                $p.Action -cnotin @('Live','Rebind','Start','Stop','Remove')){throw 'INVALID'}
            $p
        }finally{$doc.Dispose()}
    }catch{throw 'TLS_CREATION_REQUEST_REJECTED'}
}

function Get-UiTlsCreationView {
    param([hashtable]$Store,[string]$Id)
    if($Id -cnotmatch '\A[a-f0-9]{32}\z' -or -not $Store.Tickets.ContainsKey($Id)){throw 'TLS_CREATION_REQUEST_REJECTED'}
    $ticket=$Store.Tickets[$Id]
    if($ticket.SessionId -cne $Store.SessionId){throw 'TLS_CREATION_REQUEST_REJECTED'}
    $creating=$ticket.Job -and [string]$ticket.Job.State -cnotin @('Completed','Failed','Stopped')
    $acting=$ticket.ActionJob -and [string]$ticket.ActionJob.State -cnotin @('Completed','Failed','Stopped')
    $status=if($creating){'PENDING'}elseif(-not $ticket.Job -or $ticket.Job.State -cne 'Completed'){'UNCONFIRMED'}else{[string]$ticket.Status}
    $actionStatus=if($acting){'PENDING'}elseif($ticket.ActionJob -and $ticket.ActionJob.State -cne 'Completed'){'UNCONFIRMED'}else{[string]$ticket.ActionStatus}
    $result=$null
    if(-not $creating -and -not $acting -and $ticket.LiveResult -and [DateTimeOffset]::Parse($ticket.LiveResult.ExpiresAtUtc) -gt [DateTimeOffset]::UtcNow){$result=$ticket.LiveResult}
    [pscustomobject]@{Ref=$Id;Status=$status;Provider=[string]$ticket.Provider;Version='2025-CU9';LabName=[string]$ticket.LabName;
        RunId=if($status -ceq 'COMPLETE'){[string]$ticket.RunId}else{''};RunState=if($status -ceq 'COMPLETE'){[string]$ticket.RunState}else{'UNKNOWN'};
        Port=if($status -ceq 'COMPLETE'){[int]$ticket.Port}else{0};Encrypt=$true;TrustServerCertificate=$false;ActionStatus=$actionStatus;LiveResult=$result}
}

function Start-UiTlsCreationWork {
    param([hashtable]$Store,[hashtable]$Jobs,[hashtable]$PersistentJobs,[string]$ModulePath,[string]$Body,[switch]$TargetAction)
    if(-not (Test-UiTlsLiveQualificationAvailable)){throw 'TLS_CREATION_UNAVAILABLE'}
    if(($Jobs.Count+$PersistentJobs.Count) -ge 256 -or $Store.Requests.Count -ge 256){throw 'TLS_CREATION_CAPACITY'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Body)))
    $request=if($TargetAction){Get-UiTlsTargetRequest $Body}else{& (Get-Module SqlServerLab) {param($b)Get-LabTlsUiCreationRequest $b} $Body}
    # Exact duplicates return the original custody reference; never create again.
    if($Store.Requests.ContainsKey($request.RequestId)){
        $prior=$Store.Requests[$request.RequestId]
        if($prior.Hash -cne $hash -or $prior.Kind -cne [bool]$TargetAction){throw 'TLS_CREATION_REQUEST_REJECTED'}
        return [pscustomobject]@{Ref=$prior.Ref;Status='ACCEPTED'}
    }
    if(-not $TargetAction -and (Test-UiTlsCreationBlocked -Store $Store)){throw 'TLS_CREATION_PRIOR_OUTCOME_UNCONFIRMED'}
    foreach($record in $Jobs.Values){if([string]$record.Job.State -cnotin @('Completed','Failed','Stopped')){throw 'TLS_CREATION_BUSY'}}
    if($TargetAction){
        if(-not $Store.Tickets.ContainsKey($request.Ref)){throw 'TLS_CREATION_REQUEST_REJECTED'}
        $ticket=$Store.Tickets[$request.Ref]
        if($ticket.SessionId -cne $Store.SessionId -or $ticket.Status -cne 'COMPLETE' -or $ticket.RunState -ceq 'REMOVED'){throw 'TLS_CREATION_TARGET_UNCONFIRMED'}
        $ticket.LiveResult=$null;$ticket.ActionStatus='PENDING';$work=$request.Action
    }else{
        if($Store.Tickets.Count -ge 64){throw 'TLS_CREATION_CAPACITY'}
        $id=[guid]::NewGuid().ToString('n')
        $ticket=[hashtable]::Synchronized(@{Id=$id;SessionId=$Store.SessionId;RequestId=$request.RequestId;Status='ACCEPTED';
            Provider=$request.Provider;LabName=$request.LabName;StateRoot=$null;AuditId=$null;RunId=$null;RunState='UNKNOWN';
            Port=0;ActionJob=$null;ActionStatus='NONE';LiveResult=$null;Job=$null})
        $Store.Tickets[$id]=$ticket;$work='Create'
    }
    $Store.Requests[$request.RequestId]=@{Hash=$hash;Ref=$ticket.Id;Kind=[bool]$TargetAction}
    # Reserve the request before starting a worker. A dispatch failure stays
    # unconfirmed and is not converted to permission for another Create.
    $dataRoot=& (Get-Module SqlServerLab) {Get-LabDataRootDefault}
    $jobId=[guid]::NewGuid().ToString('n');$started=[DateTimeOffset]::UtcNow.ToString('o')
    try {
        $job=Start-ThreadJob -Name "sql-lab-ui-tls-create-$jobId" -ArgumentList $ModulePath,$request,$ticket,$dataRoot,$work -ScriptBlock {
            param($path,$request,$ticket,$dataRoot,$work)
            $ErrorActionPreference='Stop';$InformationPreference='SilentlyContinue';$WarningPreference='SilentlyContinue'
            try {
                Import-Module $path -Force 6>$null
                $global:SqlServerLabUiCaptureOutput=$true
                & (Get-Module SqlServerLab) {
                    param($p,$t,$root,$action)
                    if($action -ceq 'Create'){Invoke-LabTlsUiCreation -Parameters $p -Ticket $t -DataRoot $root;return}
                    $started=Get-LabTlsLiveQualificationUtcNow
                    $result=Invoke-LabTlsUiTargetAction -Ticket $t -Action $action
                    if($action -ceq 'Live'){
                        $target=[pscustomobject]@{RunId=$t.RunId;InstanceId='primary';Provider=$t.Provider}
                        $t.LiveResult=ConvertTo-LabTlsLiveQualificationHttpResult -Result $result -Target $target -Started $started
                    }
                    $t.ActionStatus='COMPLETE'
                } $request $ticket $dataRoot $work *> $null
            }catch{
                if($work -ceq 'Create'){$ticket.Status='UNCONFIRMED'}else{$ticket.ActionStatus='UNCONFIRMED';$ticket.RunState='UNKNOWN'}
            }finally{$request.SaPassword=$null;Remove-Variable SqlServerLabUiCaptureOutput -Scope Global -ErrorAction SilentlyContinue}
        }
        if($TargetAction){$ticket.ActionJob=$job}else{$ticket.Job=$job}
        $Jobs[$jobId]=[pscustomobject]@{Id=$jobId;Action="TLS $work";StartedAt=$started;LastActivityAt=$started;LastObservedLineCount=0;Job=$job}
    }catch{$ticket.Status='UNCONFIRMED';throw 'TLS_CREATION_DISPATCH_UNCONFIRMED'}
    [pscustomobject]@{Ref=$ticket.Id;Status='ACCEPTED'}
}
