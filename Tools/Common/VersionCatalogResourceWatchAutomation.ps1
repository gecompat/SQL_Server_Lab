# Pure public metadata projection and a bounded, repository-specific issue adapter.
function Get-LabResourceWatchDigest {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

function ConvertTo-LabResourceWatchUtcTime {
    param([Parameter(Mandatory)]$Value)
    $checked=[datetimeoffset]::MinValue
    if($Value -is [datetimeoffset] -or $Value -is [datetime]){$checked=[datetimeoffset]$Value}
    elseif(-not [datetimeoffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$checked)){throw 'RESOURCE_WATCH_REPORT_TIME_INVALID'}
    $checked.ToUniversalTime().ToString('o')
}

function ConvertTo-LabResourceWatchAutomationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string[]]$ExpectedId)
    if ($Result.Contract -cne 'SqlServerLab.ResourceWatch/1.0' -or $Result.Status -cnotin @('NEW','NO_CHANGE','UNCLEAR')) { throw 'RESOURCE_WATCH_REPORT_CONTRACT_INVALID' }
    $ids=@($ExpectedId | Sort-Object -Unique)
    if ($ids.Count -lt 2 -or $ids.Count -ne $ExpectedId.Count -or 'sqlpackage' -cnotin $ids -or @($ids | Where-Object {$_ -cmatch '^sql-cu-\d{4}$'}).Count -ne $ids.Count-1) { throw 'RESOURCE_WATCH_REPORT_SCOPE_INVALID' }
    $items=@($Result.Items)
    if ($items.Count -ne $ids.Count -or (@($items.Id | Sort-Object -Unique) -join '|') -cne ($ids -join '|')) { throw 'RESOURCE_WATCH_REPORT_INCOMPLETE' }
    $time=ConvertTo-LabResourceWatchUtcTime $Result.CheckedAtUtc
    $findings=@(foreach ($item in $items | Sort-Object Id) {
        $id=[string]$item.Id; $catalog=[string]$item.CatalogVersion; $observed=[string]$item.ObservedVersion
        $status=[string]$item.Status; $reason=[string]$item.ReasonCode
        $source=if ($id -ceq 'sqlpackage') {'https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17'} else {'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates'}
        if ($item.SourceUrl -cne $source -or $catalog -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or $status -cnotin @('NEW','NO_CHANGE','UNCLEAR')) { throw 'RESOURCE_WATCH_REPORT_ITEM_INVALID' }
        if ($reason -cnotin @('RESOURCE_WATCH_COMPLETED','RESOURCE_WATCH_TIMEOUT','RESOURCE_WATCH_RATE_LIMITED','RESOURCE_WATCH_REDIRECT_REJECTED','RESOURCE_WATCH_HTTP_ERROR','RESOURCE_WATCH_ENCODING_UNSUPPORTED','RESOURCE_WATCH_RESPONSE_TOO_LARGE','RESOURCE_WATCH_PARSE_ERROR','RESOURCE_WATCH_SOURCE_UNAVAILABLE','RESOURCE_WATCH_SOURCE_INVALID','RESOURCE_WATCH_SOURCE_BEHIND')) { throw 'RESOURCE_WATCH_REPORT_REASON_INVALID' }
        if ($status -eq 'UNCLEAR') {
            if ($observed -or $reason -eq 'RESOURCE_WATCH_COMPLETED') { throw 'RESOURCE_WATCH_REPORT_ITEM_INVALID' }
        } else {
            if ($observed -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or $reason -cne 'RESOURCE_WATCH_COMPLETED') { throw 'RESOURCE_WATCH_REPORT_ITEM_INVALID' }
            try {$comparison=([version]$observed).CompareTo([version]$catalog)} catch {throw 'RESOURCE_WATCH_REPORT_ITEM_INVALID'}
            if (($status -eq 'NEW' -and $comparison -le 0) -or ($status -eq 'NO_CHANGE' -and $comparison -ne 0)) { throw 'RESOURCE_WATCH_REPORT_ITEM_INVALID' }
        }
        $name=if ($id -eq 'sqlpackage') {'SqlPackage · SQL-2022-Linux-Katalog'} else {'SQL Server '+$id.Substring(7)+' CUs'}
        $capability=if ($id -eq 'sqlpackage') {'sql2022-sqlpackage170-linux-derived'} else {'SUPPORTED-CU-Katalog'}
        $action=switch ($status) {
            'NEW' {'Quelle, Integrität und Kompatibilität vor einer manuellen Katalogübernahme prüfen.'}
            'UNCLEAR' {'Prüflauf, Quelle und Katalog kontrollieren; keine Aktualitätsbestätigung.'}
            'NO_CHANGE' {'Keine neue Version im geprüften Scope.'}
        }
        $key=Get-LabResourceWatchDigest ($id+'|'+$source+'|'+$capability+'|'+$catalog+'|'+$observed+'|'+$status+'|'+$reason)
        $report="# $name`n`n- Status: **$status**`n- Geprüft am: $time`n- Quelle: $source`n- Katalog: $catalog`n- Beobachtet: $(if($observed){$observed}else{'unbekannt'})`n- Fehlercode: $reason`n- Betroffene Fähigkeit: $capability`n- Nächste Aktion: $action`n`nNur Metadatenvergleich; kein Download, keine Installation oder Supportfreigabe. Ein Issue startet keinen Agenten."
        [pscustomobject]@{ResourceId=$id;FindingKey=$key;Status=$status;ReasonCode=$reason;CheckedAtUtc=$time;CatalogVersion=$catalog;ObservedVersion=$(if($observed){$observed}else{$null});SourceUrl=$source;Report=$report}
    })
    $overall=if(@($findings | Where-Object Status -eq 'UNCLEAR').Count){'UNCLEAR'}elseif(@($findings | Where-Object Status -eq 'NEW').Count){'NEW'}else{'NO_CHANGE'}
    if ($overall -cne $Result.Status) {throw 'RESOURCE_WATCH_REPORT_STATUS_INVALID'}
    [pscustomobject]@{Contract='SqlServerLab.ResourceWatchAutomation/1.0';Status=$overall;CheckFailed=($overall -eq 'UNCLEAR');ReasonCode=$(if($overall -eq 'UNCLEAR'){'RESOURCE_WATCH_INCONCLUSIVE'}else{'RESOURCE_WATCH_COMPLETED'});CheckedAtUtc=$time;Findings=$findings;Report=($findings.Report -join "`n`n---`n`n")}
}

function Invoke-LabResourceWatchAutomationEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Check)
    $ErrorActionPreference='Stop';$stage='CHECK'
    try {
        $outputs=@(& $Check 2>&1 3>$null 4>$null 5>$null 6>$null)
        if ($outputs.Count -ne 1 -or @($outputs | Where-Object {$_ -is [Management.Automation.ErrorRecord]}).Count) {throw 'RESOURCE_WATCH_CHECK_RESULT_INVALID'}
        $stage='REPORT'
        ConvertTo-LabResourceWatchAutomationReport -Result $outputs[0].Result -ExpectedId $outputs[0].ExpectedId
    } catch {
        $code=if($stage -eq 'CHECK'){'RESOURCE_WATCH_CHECK_FAILED'}else{'RESOURCE_WATCH_REPORT_FAILED'}
        $time=[datetimeoffset]::UtcNow.ToString('o')
        $report="# Resource Watch – Prüfung fehlgeschlagen`n`n- Status: **UNCLEAR**`n- Geprüft am: $time`n- Fehlercode: $code`n- Keine Aktualitätsbestätigung.`n- Nächste Aktion: Prüflauf, Quelle und Katalog kontrollieren. Keine Rohdiagnosen veröffentlicht."
        $key=Get-LabResourceWatchDigest ('watch-check|'+$code)
        [pscustomobject]@{Contract='SqlServerLab.ResourceWatchAutomation/1.0';Status='UNCLEAR';CheckFailed=$true;ReasonCode=$code;CheckedAtUtc=$time;Findings=@([pscustomobject]@{ResourceId='watch-check';FindingKey=$key;Status='UNCLEAR';ReasonCode=$code;CheckedAtUtc=$time;CatalogVersion=$null;ObservedVersion=$null;SourceUrl=$null;Report=$report});Report=$report}
    }
}

function New-LabResourceWatchIssueBody {
    param([Parameter(Mandatory)]$Finding,[ValidatePattern('^(catalog|own-[a-f0-9]{32})$')][string]$IssueScope='catalog')
    if($IssueScope -cnotmatch '^(catalog|own-[a-f0-9]{32})$'){throw 'RESOURCE_WATCH_ISSUE_SCOPE_INVALID'}
    if ($Finding.ResourceId -cnotmatch '^(sql-cu-\d{4}|sqlpackage|watch-check)$' -or $Finding.FindingKey -cnotmatch '^[A-F0-9]{64}$') {throw 'RESOURCE_WATCH_ISSUE_FINDING_INVALID'}
    $payload=[string]$Finding.Report
    $digest=Get-LabResourceWatchDigest $payload
    "<!-- SqlServerLab.ResourceWatch/1 scope=$IssueScope resource=$($Finding.ResourceId) finding=$($Finding.FindingKey) payload=$digest -->`n$payload"
}

function Get-LabResourceWatchIssueIdentity {
    param([Parameter(Mandatory)]$Issue)
    $body=[string]$Issue.body
    $match=[regex]::Match($body,'\A<!-- SqlServerLab\.ResourceWatch/1 scope=(?<scope>catalog|own-[a-f0-9]{32}) resource=(?<id>sql-cu-\d{4}|sqlpackage|watch-check) finding=(?<key>[A-F0-9]{64}) payload=(?<digest>[A-F0-9]{64}) -->\n(?<payload>[\s\S]*)\z')
    if (-not $match.Success -or (Get-LabResourceWatchDigest $match.Groups['payload'].Value) -cne $match.Groups['digest'].Value) {throw 'RESOURCE_WATCH_ISSUE_BODY_CHANGED'}
    $number=[string]$Issue.number
    if ($number -cnotmatch '^[1-9]\d{0,9}$' -or $Issue.html_url -cne ('https://github.com/gecompat/SQL_Server_Lab/issues/'+$number) -or $Issue.state -cnotin @('open','closed') -or $null -ne $Issue.pull_request) {throw 'RESOURCE_WATCH_ISSUE_IDENTITY_INVALID'}
    if(@($Issue.labels | Where-Object {[string]$_.name -ceq 'cu-watch'}).Count -ne 1){throw 'RESOURCE_WATCH_ISSUE_LABEL_CHANGED'}
    [pscustomobject]@{IssueScope=$match.Groups['scope'].Value;ResourceId=$match.Groups['id'].Value;FindingKey=$match.Groups['key'].Value;Number=[long]$number;Body=$body;State=[string]$Issue.state;Url=[string]$Issue.html_url}
}

function Get-LabResourceWatchGitHubUri {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cnotmatch '^repos/gecompat/SQL_Server_Lab/issues(?:\?state=all&per_page=100&page=[1-9]\d?|/[1-9]\d{0,9})?$') {throw 'RESOURCE_WATCH_ISSUE_TARGET_INVALID'}
    'https://api.github.com/'+$Path
}

function Invoke-LabResourceWatchGitHubApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GET','POST','PATCH')][string]$Method,[Parameter(Mandatory)][string]$Path,$Body,[Parameter(Mandatory)][Diagnostics.Stopwatch]$Clock,[ValidateRange(1,30000)][int]$TimeoutMilliseconds=30000)
    $uri=Get-LabResourceWatchGitHubUri -Path $Path
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {throw 'RESOURCE_WATCH_ISSUE_AUTH_UNAVAILABLE'}
    $remaining=[Math]::Min($TimeoutMilliseconds,180000-[int]$Clock.ElapsedMilliseconds)
    if ($remaining -le 0) {throw 'RESOURCE_WATCH_ISSUE_TIMEOUT'}
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseProxy=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $cancel=[Threading.CancellationTokenSource]::new($remaining);$response=$null;$stream=$null;$memory=[IO.MemoryStream]::new()
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$uri)
    try {
        $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN)
        $request.Headers.Add('Accept','application/vnd.github+json');$request.Headers.Add('X-GitHub-Api-Version','2022-11-28');$request.Headers.UserAgent.ParseAdd('SqlServerLab-ResourceWatch/1.0')
        if ($null -ne $Body) {$request.Content=[Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 8 -Compress),[Text.Encoding]::UTF8,'application/json')}
        $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {throw 'RESOURCE_WATCH_ISSUE_REDIRECT_REJECTED'}
        if (-not $response.IsSuccessStatusCode) {throw 'RESOURCE_WATCH_ISSUE_HTTP_ERROR'}
        if ($response.Content.Headers.ContentLength -gt 1048576 -or $response.Content.Headers.ContentEncoding.Count) {throw 'RESOURCE_WATCH_ISSUE_RESPONSE_INVALID'}
        $stream=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult();$buffer=[byte[]]::new(8192)
        while (($read=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($memory.Length+$read -gt 1048576) {throw 'RESOURCE_WATCH_ISSUE_RESPONSE_INVALID'}
            $memory.Write($buffer,0,$read)
        }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray())
        [pscustomobject]@{Data=(ConvertFrom-Json -InputObject $text -Depth 30 -NoEnumerate -ErrorAction Stop)}
    } catch {
        if ($_.Exception.Message -cmatch '^RESOURCE_WATCH_ISSUE_(TARGET_INVALID|AUTH_UNAVAILABLE|TIMEOUT|REDIRECT_REJECTED|HTTP_ERROR|RESPONSE_INVALID)$') {throw $_.Exception.Message}
        if ($cancel.IsCancellationRequested) {throw 'RESOURCE_WATCH_ISSUE_TIMEOUT'}
        throw 'RESOURCE_WATCH_ISSUE_REQUEST_FAILED'
    } finally {
        if($stream){$stream.Dispose()};if($response){$response.Dispose()};$request.Dispose();$memory.Dispose();$cancel.Dispose();$client.Dispose();$handler.Dispose()
    }
}

function Invoke-LabResourceWatchIssueProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evaluation,[scriptblock]$ApiAction,[switch]$WhatIf,[ValidatePattern('^(catalog|own-[a-f0-9]{32})$')][string]$IssueScope='catalog')
    $ErrorActionPreference='Stop'
    if($IssueScope -cnotmatch '^(catalog|own-[a-f0-9]{32})$'){throw 'RESOURCE_WATCH_ISSUE_SCOPE_INVALID'}
    if ($Evaluation.Contract -cne 'SqlServerLab.ResourceWatchAutomation/1.0' -or @($Evaluation.Findings).Count -eq 0) {throw 'RESOURCE_WATCH_ISSUE_EVALUATION_INVALID'}
    # Reconstruct the publication from validated fields; never trust caller-supplied Report text.
    if($Evaluation.ReasonCode -in @('RESOURCE_WATCH_COMPLETED','RESOURCE_WATCH_INCONCLUSIVE')){
        $result=[pscustomobject]@{Contract='SqlServerLab.ResourceWatch/1.0';Status=$Evaluation.Status;CheckedAtUtc=$Evaluation.CheckedAtUtc;Items=@(foreach($finding in $Evaluation.Findings){
            [pscustomobject]@{Id=$finding.ResourceId;CatalogVersion=$finding.CatalogVersion;ObservedVersion=$finding.ObservedVersion;SourceUrl=$finding.SourceUrl;Status=$finding.Status;ReasonCode=$finding.ReasonCode}
        })}
        $Evaluation=ConvertTo-LabResourceWatchAutomationReport -Result $result -ExpectedId @($Evaluation.Findings.ResourceId)
    }elseif($Evaluation.ReasonCode -in @('RESOURCE_WATCH_CHECK_FAILED','RESOURCE_WATCH_REPORT_FAILED') -and $Evaluation.CheckFailed -and $Evaluation.Status -eq 'UNCLEAR'){
        $code=[string]$Evaluation.ReasonCode
        try{$time=ConvertTo-LabResourceWatchUtcTime $Evaluation.CheckedAtUtc}catch{throw 'RESOURCE_WATCH_ISSUE_EVALUATION_INVALID'}
        $report="# Resource Watch – Prüfung fehlgeschlagen`n`n- Status: **UNCLEAR**`n- Geprüft am: $time`n- Fehlercode: $code`n- Keine Aktualitätsbestätigung.`n- Nächste Aktion: Prüflauf, Quelle und Katalog kontrollieren. Keine Rohdiagnosen veröffentlicht."
        $Evaluation=[pscustomobject]@{ReasonCode=$code;CheckedAtUtc=$time;CheckFailed=$true;Findings=@([pscustomobject]@{ResourceId='watch-check';FindingKey=(Get-LabResourceWatchDigest ('watch-check|'+$code));Status='UNCLEAR';Report=$report})}
    }else{throw 'RESOURCE_WATCH_ISSUE_EVALUATION_INVALID'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $request={param($Method,$Path,$Body)
        if($ApiAction){$output=@(& $ApiAction $Method $Path $Body 2>&1 3>$null 4>$null 5>$null 6>$null)}else{$output=@(Invoke-LabResourceWatchGitHubApi -Method $Method -Path $Path -Body $Body -Clock $clock)}
        if($output.Count -ne 1 -or @($output | Where-Object {$_ -is [Management.Automation.ErrorRecord]}).Count -or -not $output[0].PSObject.Properties['Data']){throw 'RESOURCE_WATCH_ISSUE_REQUEST_FAILED'}
        $output[0]
    }
    $receipts=[Collections.Generic.List[object]]::new();$notificationFailed=$false
    try {
        $existing=[Collections.Generic.List[object]]::new();$complete=$false
        for($page=1;$page -le 10;$page++){
            # Discover markers independently of mutable labels; an incomplete full scan blocks POST.
            $response=& $request 'GET' ('repos/gecompat/SQL_Server_Lab/issues?state=all&per_page=100&page='+$page) $null
            $entries=$response.Data
            # The adapter returns one JSON array, including an empty array.
            if($entries -isnot [array] -or $entries.Count -gt 100){throw 'RESOURCE_WATCH_ISSUE_LIST_INVALID'}
            foreach($issue in $entries){
                $prefix=if($IssueScope -eq 'catalog'){'[Resource Watch] '}else{'[Resource Watch '+$IssueScope+'] '}
                if(([string]$issue.body).StartsWith(('<!-- SqlServerLab.ResourceWatch/1 scope='+$IssueScope+' '),[StringComparison]::Ordinal) -or ([string]$issue.title).StartsWith($prefix,[StringComparison]::Ordinal)){
                    $identity=Get-LabResourceWatchIssueIdentity $issue
                    if($identity.IssueScope -cne $IssueScope){throw 'RESOURCE_WATCH_ISSUE_IDENTITY_INVALID'}
                    $existing.Add($identity)
                }
            }
            if($entries.Count -lt 100){$complete=$true;break}
        }
        if(-not $complete){throw 'RESOURCE_WATCH_ISSUE_LIST_INCOMPLETE'}
        if(@($existing | Group-Object ResourceId | Where-Object Count -gt 1).Count){throw 'RESOURCE_WATCH_ISSUE_AMBIGUOUS'}
        $findings=@($Evaluation.Findings)
        # A successful check also resolves a previous global check failure.
        if($Evaluation.ReasonCode -in @('RESOURCE_WATCH_COMPLETED','RESOURCE_WATCH_INCONCLUSIVE') -and @($existing | Where-Object ResourceId -eq 'watch-check').Count){
            $recoveryReport="# Resource Watch – Prüfung wieder auswertbar`n`n- Status: **NO_CHANGE**`n- Geprüft am: $($Evaluation.CheckedAtUtc)`n- Nächste Aktion: Einzelbefunde prüfen; ein gegebenenfalls unklarer Einzelbefund bleibt offen."
            $findings+=[pscustomobject]@{ResourceId='watch-check';FindingKey=(Get-LabResourceWatchDigest 'watch-check|RECOVERED');Status='NO_CHANGE';Report=$recoveryReport}
        }
        foreach($finding in $findings){
            $resource=[string]$finding.ResourceId;$key=[string]$finding.FindingKey;$mutationAttempted=$false
            try {
                $body=New-LabResourceWatchIssueBody $finding -IssueScope $IssueScope
                $matchedIssues=@($existing | Where-Object ResourceId -ceq $resource)
                if($matchedIssues.Count -gt 1){throw 'RESOURCE_WATCH_ISSUE_AMBIGUOUS'}
                $current=if($matchedIssues.Count){$matchedIssues[0]}else{$null}
                if($current){
                    $fresh=(& $request 'GET' ('repos/gecompat/SQL_Server_Lab/issues/'+$current.Number) $null).Data
                    if($null -eq $fresh -or $fresh -is [array]){throw 'RESOURCE_WATCH_ISSUE_IDENTITY_INVALID'}
                    $revalidated=Get-LabResourceWatchIssueIdentity $fresh
                    if($revalidated.Number -ne $current.Number -or $revalidated.Body -cne $current.Body -or $revalidated.State -cne $current.State){throw 'RESOURCE_WATCH_ISSUE_CHANGED'}
                    $current=$revalidated
                }
                $desired=if($finding.Status -eq 'NO_CHANGE'){'closed'}else{'open'}
                if(-not $current -and $desired -eq 'closed'){
                    $receipts.Add([pscustomobject]@{ResourceId=$resource;FindingKey=$key;Status='NO_NOTICE_NEEDED';IssueNumber=$null;IssueUrl=$null;Verified=$false;ReasonCode='RESOURCE_WATCH_ISSUE_NO_CHANGE'});continue
                }
                if($current -and $current.FindingKey -ceq $key -and ($desired -eq 'open' -or $current.State -eq 'closed')){
                    $receipts.Add([pscustomobject]@{ResourceId=$resource;FindingKey=$key;BodySha256=(Get-LabResourceWatchDigest $current.Body);Status='DEDUPLICATED';IssueNumber=$current.Number;IssueUrl=$current.Url;Verified=$true;ReasonCode='RESOURCE_WATCH_ISSUE_ALREADY_RECORDED'});continue
                }
                if($WhatIf){
                    $receipts.Add([pscustomobject]@{ResourceId=$resource;FindingKey=$key;Status='NOT_EXECUTED';IssueNumber=$(if($current){$current.Number}else{$null});IssueUrl=$null;Verified=$false;ReasonCode='RESOURCE_WATCH_ISSUE_WHATIF'});continue
                }
                $prefix=if($IssueScope -eq 'catalog'){'[Resource Watch] '}else{'[Resource Watch '+$IssueScope+'] '}
                $payload=@{title=($prefix+$resource+' ['+$finding.Status+']');body=$body}
                $mutationAttempted=$true
                if($current){$payload.state=$desired;$written=(& $request 'PATCH' ('repos/gecompat/SQL_Server_Lab/issues/'+$current.Number) $payload).Data}else{$payload.labels=@('cu-watch');$written=(& $request 'POST' 'repos/gecompat/SQL_Server_Lab/issues' $payload).Data}
                if($null -eq $written -or $written -is [array]){throw 'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}
                $identity=Get-LabResourceWatchIssueIdentity $written
                if($current -and $identity.Number -ne $current.Number){throw 'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}
                $verified=(& $request 'GET' ('repos/gecompat/SQL_Server_Lab/issues/'+$identity.Number) $null).Data
                if($null -eq $verified -or $verified -is [array]){throw 'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}
                $receipt=Get-LabResourceWatchIssueIdentity $verified
                if($receipt.Number -ne $identity.Number -or $receipt.IssueScope -cne $IssueScope -or $receipt.ResourceId -cne $resource -or $receipt.FindingKey -cne $key -or $receipt.Body -cne $body -or $receipt.State -cne $desired){throw 'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}
                $receipts.Add([pscustomobject]@{ResourceId=$resource;FindingKey=$key;BodySha256=(Get-LabResourceWatchDigest $receipt.Body);Status='PUBLISHED';IssueNumber=$receipt.Number;IssueUrl=$receipt.Url;Verified=$true;ReasonCode='RESOURCE_WATCH_ISSUE_VERIFIED'})
            }catch{
                $notificationFailed=$true
                $code=if($mutationAttempted){'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}elseif($_.Exception.Message -cmatch '^RESOURCE_WATCH_ISSUE_(BODY_CHANGED|IDENTITY_INVALID|LABEL_CHANGED|AMBIGUOUS|CHANGED|FINDING_INVALID|REQUEST_FAILED|HTTP_ERROR|TIMEOUT|AUTH_UNAVAILABLE|REDIRECT_REJECTED|RESPONSE_INVALID)$'){$_.Exception.Message}else{'RESOURCE_WATCH_ISSUE_REQUEST_FAILED'}
                $receipts.Add([pscustomobject]@{ResourceId=$resource;FindingKey=$key;Status=$(if($mutationAttempted){'RECOVERY_REQUIRED'}else{'FAILED'});IssueNumber=$null;IssueUrl=$null;Verified=$false;ReasonCode=$code})
            }
        }
    }catch{
        $notificationFailed=$true
        $code=if($_.Exception.Message -cmatch '^RESOURCE_WATCH_ISSUE_(BODY_CHANGED|IDENTITY_INVALID|LABEL_CHANGED|AMBIGUOUS|LIST_INVALID|LIST_INCOMPLETE|REQUEST_FAILED|HTTP_ERROR|TIMEOUT|AUTH_UNAVAILABLE|REDIRECT_REJECTED|RESPONSE_INVALID)$'){$_.Exception.Message}else{'RESOURCE_WATCH_ISSUE_REQUEST_FAILED'}
        $receipts.Add([pscustomobject]@{ResourceId='watch-check';FindingKey=$null;Status='FAILED';IssueNumber=$null;IssueUrl=$null;Verified=$false;ReasonCode=$code})
    }
    [pscustomobject]@{Contract='SqlServerLab.ResourceWatchIssueReceipt/1.0';Repository='gecompat/SQL_Server_Lab';IssueScope=$IssueScope;ApiBoundary=$(if($ApiAction){'SYNTHETIC_ADAPTER'}else{'GITHUB_API'});NotificationFailed=$notificationFailed;CheckFailed=[bool]$Evaluation.CheckFailed;Receipts=@($receipts)}
}

function Close-LabResourceWatchIssueFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][ValidatePattern('^own-[a-f0-9]{32}$')][string]$ExpectedIssueScope,[scriptblock]$ApiAction,[switch]$WhatIf)
    $ErrorActionPreference='Stop'
    if($ExpectedIssueScope -cnotmatch '^own-[a-f0-9]{32}$'){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
    if($Receipt.Contract -cne 'SqlServerLab.ResourceWatchIssueReceipt/1.0' -or $Receipt.Repository -cne 'gecompat/SQL_Server_Lab' -or $Receipt.IssueScope -cne $ExpectedIssueScope -or
        $Receipt.ApiBoundary -cnotin @('GITHUB_API','SYNTHETIC_ADAPTER') -or ($Receipt.ApiBoundary -eq 'SYNTHETIC_ADAPTER' -and -not $ApiAction) -or
        $Receipt.CheckFailed -isnot [bool] -or $Receipt.NotificationFailed -isnot [bool] -or $Receipt.Receipts -isnot [array] -or $Receipt.Receipts.Count -eq 0) {throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
    # Validate every status before choosing targets. Claimed publications can never vanish in a filter.
    foreach($row in $Receipt.Receipts){
        if($row.Status -isnot [string] -or $row.Verified -isnot [bool] -or $row.ResourceId -isnot [string] -or $row.ResourceId -cnotmatch '^(sql-cu-\d{4}|sqlpackage|watch-check)$' -or
            $row.Status -cnotin @('PUBLISHED','DEDUPLICATED','NO_NOTICE_NEEDED','RECOVERY_REQUIRED','FAILED','NOT_EXECUTED')){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
        $bound=$row.Status -in @('PUBLISHED','DEDUPLICATED')
        if($bound){
            $expectedReason=if($row.Status -eq 'PUBLISHED'){'RESOURCE_WATCH_ISSUE_VERIFIED'}else{'RESOURCE_WATCH_ISSUE_ALREADY_RECORDED'}
            if(-not $row.Verified -or ($row.IssueNumber -isnot [int] -and $row.IssueNumber -isnot [long]) -or [string]$row.IssueNumber -cnotmatch '^[1-9]\d{0,9}$' -or
                $row.IssueUrl -isnot [string] -or $row.IssueUrl -cne ('https://github.com/gecompat/SQL_Server_Lab/issues/'+$row.IssueNumber) -or
                $row.FindingKey -isnot [string] -or $row.FindingKey -cnotmatch '^[A-F0-9]{64}$' -or $row.BodySha256 -isnot [string] -or $row.BodySha256 -cnotmatch '^[A-F0-9]{64}$' -or $row.ReasonCode -cne $expectedReason){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
        }else{
            if($row.Verified -or $null -ne $row.IssueUrl -or $null -ne $row.BodySha256){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
            if($row.Status -ne 'NOT_EXECUTED' -and $null -ne $row.IssueNumber){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
            if($row.Status -eq 'NOT_EXECUTED' -and $null -ne $row.IssueNumber -and (($row.IssueNumber -isnot [int] -and $row.IssueNumber -isnot [long]) -or [string]$row.IssueNumber -cnotmatch '^[1-9]\d{0,9}$')){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
            if(($null -ne $row.FindingKey -and ($row.FindingKey -isnot [string] -or $row.FindingKey -cnotmatch '^[A-F0-9]{64}$')) -or ($null -eq $row.FindingKey -and $row.Status -ne 'FAILED')){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
            $reasonValid=switch($row.Status){
                'NO_NOTICE_NEEDED' {$row.ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_NO_CHANGE'}
                'NOT_EXECUTED' {$row.ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_WHATIF'}
                'RECOVERY_REQUIRED' {$row.ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_WRITE_UNCONFIRMED'}
                'FAILED' {$row.ReasonCode -cmatch '^RESOURCE_WATCH_ISSUE_(BODY_CHANGED|IDENTITY_INVALID|LABEL_CHANGED|AMBIGUOUS|CHANGED|FINDING_INVALID|LIST_INVALID|LIST_INCOMPLETE|REQUEST_FAILED|HTTP_ERROR|TIMEOUT|AUTH_UNAVAILABLE|REDIRECT_REJECTED|RESPONSE_INVALID)$'}
            }
            if(-not $reasonValid){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
        }
    }
    $targets=@($Receipt.Receipts | Where-Object {$_.Verified -and $null -ne $_.IssueNumber})
    if(@($targets.IssueNumber | Sort-Object -Unique).Count -ne $targets.Count) {throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
    $clock=[Diagnostics.Stopwatch]::StartNew();$cleanup=[Collections.Generic.List[object]]::new()
    $request={param($Method,$Path,$Body)
        if($ApiAction){$output=@(& $ApiAction $Method $Path $Body 2>&1 3>$null 4>$null 5>$null 6>$null)}else{$output=@(Invoke-LabResourceWatchGitHubApi -Method $Method -Path $Path -Body $Body -Clock $clock)}
        if($output.Count -ne 1 -or @($output | Where-Object {$_ -is [Management.Automation.ErrorRecord]}).Count -or -not $output[0].PSObject.Properties['Data']){throw 'RESOURCE_WATCH_FIXTURE_REQUEST_FAILED'}
        $output[0].Data
    }
    foreach($target in $targets){
        try{
            $path='repos/gecompat/SQL_Server_Lab/issues/'+$target.IssueNumber
            $current=Get-LabResourceWatchIssueIdentity (& $request 'GET' $path $null)
            if($current.Number -ne $target.IssueNumber -or $current.IssueScope -cne $ExpectedIssueScope -or $current.ResourceId -cne $target.ResourceId -or $current.FindingKey -cne $target.FindingKey -or (Get-LabResourceWatchDigest $current.Body) -cne $target.BodySha256){throw 'RESOURCE_WATCH_FIXTURE_BINDING_CHANGED'}
            $status=if($current.State -eq 'closed'){'NO_OP'}elseif($WhatIf){'NOT_EXECUTED'}else{
                $null=& $request 'PATCH' $path @{state='closed'}
                $verified=Get-LabResourceWatchIssueIdentity (& $request 'GET' $path $null)
                if($verified.Number -ne $current.Number -or $verified.State -cne 'closed' -or $verified.Body -cne $current.Body){throw 'RESOURCE_WATCH_FIXTURE_CLOSE_UNCONFIRMED'}
                'CLOSED'
            }
            $cleanup.Add([pscustomobject]@{IssueNumber=$target.IssueNumber;ResourceId=$target.ResourceId;FindingKey=$target.FindingKey;Status=$status;Verified=($status -ne 'NOT_EXECUTED');ReasonCode='RESOURCE_WATCH_FIXTURE_REVALIDATED'})
        }catch{
            $cleanup.Add([pscustomobject]@{IssueNumber=$target.IssueNumber;ResourceId=$target.ResourceId;FindingKey=$target.FindingKey;Status='RECOVERY_REQUIRED';Verified=$false;ReasonCode='RESOURCE_WATCH_FIXTURE_CLOSE_UNCONFIRMED'})
        }
    }
    $unresolved=@($Receipt.Receipts | Where-Object {$_.Status -in @('RECOVERY_REQUIRED','FAILED','NOT_EXECUTED')}).Count -gt 0
    [pscustomobject]@{Contract='SqlServerLab.ResourceWatchFixtureCleanup/1.0';Repository='gecompat/SQL_Server_Lab';IssueScope=$ExpectedIssueScope;RecoveryRequired=($unresolved -or @($cleanup | Where-Object Status -eq 'RECOVERY_REQUIRED').Count -gt 0);CheckFailed=[bool]$Receipt.CheckFailed;NotificationFailed=[bool]$Receipt.NotificationFailed;Cleanup=@($cleanup)}
}
