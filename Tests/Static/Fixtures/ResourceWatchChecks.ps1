# Executed by VersionCatalogChecks; synthetic sources only.
$watchResults = & $module {
    $results=[Collections.Generic.List[object]]::new()
    function Check($name,$ok){$results.Add([pscustomobject]@{Name=$name;Success=[bool]$ok})}
    $script:ResourceWatchCache=$null
    $now=[datetimeoffset]'2026-09-29T00:00:00Z'
    $fixture=''
    foreach($v in Get-SqlServerVersions -Status SUPPORTED){
        $b=$v.docker.builds|Sort-Object {[version]$_.build} -Descending|Select-Object -First 1
        $fixture+="`n### SQL Server $($v.id)`n| $($b.build) | None | $($b.cu) | $($b.kb) | date |`n"
    }
    $state=@{Calls=0;Html='<li>Build number: 170.4.83.3</li>';Failure='';Cu=$fixture}
    $request={param($uri);$state.Calls++;if($state.Failure){throw $state.Failure};[pscustomobject]@{Content=$(if($uri -match 'sqlpackage'){$state.Html}else{$state.Cu})}}.GetNewClosure()
    Check 'Watch starts NOT_CHECKED without request' ((Get-LabResourceWatchState -Now $now).Status -eq 'NOT_CHECKED' -and $state.Calls -eq 0)
    $first=Invoke-LabResourceWatchRefresh -Now $now -WebRequestAction $request
    Check 'Real CU core and SqlPackage parse independent equal versions' ($first.Status -eq 'NO_CHANGE' -and $first.Items.Count -eq 4 -and $state.Calls -eq 2)
    $first.Items[0].Status='tampered'
    Check 'Watch snapshots are detached' ((Get-LabResourceWatchState -Now $now).Items[0].Status -eq 'NO_CHANGE')
    $cached=Get-LabResourceWatchState -Now $now.AddMinutes(14)
    Check 'Cache reads do not request sources' ($cached.Status -eq 'NO_CHANGE' -and $state.Calls -eq 2)
    Check 'TTL expiry is not a current all clear' ((Get-LabResourceWatchState -Now $now.AddMinutes(15)).Status -eq 'EXPIRED' -and $state.Calls -eq 2)
    $second=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(1) -WebRequestAction $request
    Check 'Repeated finding ignores check timestamp' (@($second.Items|Where-Object {-not $_.RepeatedFinding}).Count -eq 0)
    $state.Html='<p>irrelevant markup</p><li>Build number: 170.5.96.0</li>'
    $new=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(2) -WebRequestAction $request
    $pkg=$new.Items|Where-Object Id -eq sqlpackage
    Check 'New source version remains separate from pinned catalog and old observation' ($pkg.Status -eq 'NEW' -and $pkg.CatalogVersion -eq '170.4.83.3' -and $pkg.PreviousSuccessfulVersion -eq '170.4.83.3' -and -not $pkg.RepeatedFinding)
    $state.Html='<div>different harmless markup</div><li>Build number: 170.5.96.0</li>'
    $same=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(2).AddSeconds(1) -WebRequestAction $request
    Check 'Dedupe uses normalized finding instead of HTML bytes' (($same.Items|Where-Object Id -eq sqlpackage).RepeatedFinding)
    $guardCalls=@{Count=0}
    $guarded=Invoke-LabCuStatusCheck -CatalogPath (Join-Path $script:CatalogsPath 'sql-server-versions.json') -Sources (Get-LabCuStatusSourceConfiguration) -WebRequestAction $request -ParserBudget {$guardCalls.Count++;throw 'RESOURCE_WATCH_TIMEOUT'}
    Check 'CU parser budget is an opt-in failclosed boundary' ($guardCalls.Count -eq 1 -and $guarded.Status -eq 'UNCLEAR' -and $guarded.Reason -eq 'RESOURCE_WATCH_TIMEOUT')
    foreach($failure in @('RESOURCE_WATCH_RATE_LIMITED','RESOURCE_WATCH_TIMEOUT','SYNTHETIC_PRIVATE_EXCEPTION')){
        $state.Failure=$failure
        $failed=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(3) -WebRequestAction $request
        $pkg=$failed.Items|Where-Object Id -eq sqlpackage
        Check ('Failed attempt remains visible '+$failure) ($failed.Status -eq 'UNCLEAR' -and $pkg.LastSuccessfulVersion -eq '170.5.96.0' -and -not $pkg.ObservedVersion -and ($failed|ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE')
    }
    $state.Failure=''
    foreach($html in @('<h2>Preview</h2><li>Build number: 171.0.0.0</li>','<li>Build number: 170.1.1.1</li>','<p>preview 171.0.0.0</p>','<li>Build number: 170.5.96.0</li><li>Build number: 170.5.96.0</li>')){
        $state.Html=$html;$invalid=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(4) -WebRequestAction $request
        $pkg=$invalid.Items|Where-Object Id -eq sqlpackage
        Check 'Preview older missing or ambiguous build never reports current' ($pkg.Status -eq 'UNCLEAR' -and -not $pkg.ObservedVersion)
    }
    foreach($html in @('<h2>Preview</h2><h3>Build</h3><li>Build number: 171.0.0.0</li>',"## Preview`n### Build`n- Build number: 171.0.0.0",'<h2>Pre<em>view</em></h2><h3>Build</h3><li>Build number: 171.0.0.0</li>')){
        $rejected=$false;try{$null=ConvertFrom-LabSqlPackageWatchContent $html}catch{$rejected=$true}
        Check 'Real parser rejects active Preview ancestor' $rejected
        $state.Html=$html;$view=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(4) -WebRequestAction $request
        $pkg=$view.Items|Where-Object Id -eq sqlpackage
        Check 'Nested Preview refresh remains UNCLEAR with old success separate' ($pkg.Status -eq 'UNCLEAR' -and -not $pkg.ObservedVersion -and $pkg.LastSuccessfulVersion -eq '170.5.96.0')
    }
    foreach($html in @('<h2>Preview</h2><h3>Notes</h3><p>Future builds</p><h2>Stable</h2><li>Build number: 170.5.96.0</li>',"## Preview`n### Notes`nFuture builds`n## Stable`n- Build number: 170.5.96.0",'<h2>Preview</h2><h3>Notes</h3><h1>Stable</h1><li>Build number: 170.5.96.0</li>')){
        Check 'Stable sibling or ancestor ends Preview section in actual parser' ((ConvertFrom-LabSqlPackageWatchContent $html) -eq '170.5.96.0')
        $state.Html=$html;$view=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(4) -WebRequestAction $request
        Check 'Stable section refresh preserves valid NEW finding' (($view.Items|Where-Object Id -eq sqlpackage).Status -eq 'NEW')
    }
    foreach($html in @('<h1>Download and install SqlPackage</h1><ul><li><strong>Build number:</strong> 170.5.96.0</li></ul>',"# Download and install SqlPackage`n- **Build number:** 170.5.96.0")){
        Check 'Formatted explicit Build number label parses deterministically' ((ConvertFrom-LabSqlPackageWatchContent $html) -eq '170.5.96.0')
        $state.Html=$html;$view=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(4) -WebRequestAction $request
        Check 'Formatted label reaches valid NEW through complete refresh' (($view.Items|Where-Object Id -eq sqlpackage).Status -eq 'NEW')
    }
    foreach($html in @('<li><strong>Build number:</strong> 170.5.96.0</li><li>Build number: 170.4.83.3</li>','<li><strong>Build number: 170.5.96.0</li>','<h2>Preview</h2><h3>Build</h3><li><strong>Build number:</strong> 171.0.0.0</li>')){
        $rejected=$false;try{$null=ConvertFrom-LabSqlPackageWatchContent $html}catch{$rejected=$true}
        Check 'Formatted labels preserve ambiguity malformed and Preview rejection' $rejected
    }
    $state.Cu='<meta name="github_feedback_content_git_url" content="https://github.com/Other/repo/blob/main/download-and-install-latest-updates.md">'
    $before=$state.Calls
    $invalid=Invoke-LabResourceWatchRefresh -Now $now.AddMinutes(5) -WebRequestAction $request
    Check 'Direct Support source does not follow untrusted legacy metadata; missing tables remain unclear' ($state.Calls -eq $before+2 -and @($invalid.Items|Where-Object {$_.Id -like 'sql-cu-*' -and $_.ReasonCode -eq 'RESOURCE_WATCH_PARSE_ERROR'}).Count -eq 3)
    $state.Cu=$fixture
    foreach($uri in @('http://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17','https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver16','https://raw.githubusercontent.com/MicrosoftDocs/other/main/file.md')){
        $rejected=$false;try{Assert-LabResourceWatchUri $uri}catch{$rejected=$true};Check 'Unapproved source URI rejected' $rejected
    }
    $script:ResourceWatchCache=$null
    $results
}
foreach($check in $watchResults){Add-CheckResult -Name $check.Name -Success $check.Success}
# Run the real HTTP transport against a disposable loopback socket; only URI authority is replaced.
$transportResults = & $module {
    $results=[Collections.Generic.List[object]]::new()
    function Assert-LabResourceWatchUri { param($Uri); if(([uri]$Uri).Host -ne '127.0.0.1'){throw 'FIXTURE_AUTHORITY'} }
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $server=[powershell]::Create();$requests=[Collections.Concurrent.ConcurrentBag[string]]::new()
    try {
        $listener.Start();$port=$listener.LocalEndpoint.Port
        $null=$server.AddScript({param($Listener,$Requests)
            while($true){
                if(-not $Listener.Pending()){Start-Sleep -Milliseconds 5;continue}
                $client=$Listener.AcceptTcpClient()
                try{
                    $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream)
                    $line=$reader.ReadLine();$Requests.Add($line);while($reader.ReadLine()){}
                    $path=($line -split ' ')[1]
                    $status=if($path -match '^/(301|302|303|307|308|429|500)$'){$Matches[1]}else{'200'}
                    $body='synthetic';$headers=''
                    if($status -like '3*'){$headers="Location: /redirect-target`r`n"}
                    if($path -in @('/large','/stream-large')){$body='x'*524289}
                    if($path -eq '/slow'){Start-Sleep -Milliseconds 200}
                    if($path -eq '/encoded'){$headers="Content-Encoding: gzip`r`n"}
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $lengthHeader=if($path -eq '/stream-large'){''}else{"Content-Length: $($bytes.Length)`r`n"}
                    $head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Fixture`r`n${headers}${lengthHeader}Connection: close`r`n`r`n")
                    $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length)
                }catch{}finally{$client.Dispose()}
            }
        }).AddArgument($listener).AddArgument($requests)
        $run=$server.BeginInvoke()
        foreach($case in @(@('200','OK'),@('301','REDIRECT_REJECTED'),@('302','REDIRECT_REJECTED'),@('303','REDIRECT_REJECTED'),@('307','REDIRECT_REJECTED'),@('308','REDIRECT_REJECTED'),@('429','RATE_LIMITED'),@('500','HTTP_ERROR'),@('large','RESPONSE_TOO_LARGE'),@('stream-large','RESPONSE_TOO_LARGE'),@('encoded','ENCODING_UNSUPPORTED'))){
            $code='OK';try{$reply=Invoke-LabResourceWatchRequest -Uri "http://127.0.0.1:$port/$($case[0])" -Clock ([Diagnostics.Stopwatch]::StartNew())}catch{$code=$_.Exception.Message -replace '^RESOURCE_WATCH_',''}
            $results.Add([pscustomobject]@{Name=('Real bounded Watch transport '+$case[0]);Success=($code -ceq $case[1])})
        }
        $results.Add([pscustomobject]@{Name='Redirect response never requests payload target';Success=(@($requests|Where-Object {$_ -match '/redirect-target'}).Count -eq 0 -and $requests.Count -eq 11)})
        $code='';try{$null=Invoke-LabResourceWatchRequest -Uri "http://127.0.0.1:$port/slow" -Clock ([Diagnostics.Stopwatch]::StartNew()) -MaximumElapsedMilliseconds 50}catch{$code=$_.Exception.Message}
        $results.Add([pscustomobject]@{Name='Real transport deadline bounds delayed response';Success=($code -eq 'RESOURCE_WATCH_TIMEOUT')})
    }finally{$listener.Stop();$server.Stop();$server.Dispose()}
    $results
}
foreach($check in $transportResults){Add-CheckResult -Name $check.Name -Success $check.Success}
$entryResults = & $module {
    param($RepoRoot)
    $results=[Collections.Generic.List[object]]::new()
    $calls=@{Read=0;Refresh=0;Menu=0;Ack=0}
    function Get-LabResourceWatchState { $calls.Read++; [pscustomobject]@{Status='NOT_CHECKED';ReasonCode='RESOURCE_WATCH_NOT_CHECKED';Items=@();Notice='synthetic';CheckedAtUtc=$null} }
    function Invoke-LabResourceWatchRefresh { $calls.Refresh++; Get-LabResourceWatchState }
    $realMenu=${function:Invoke-LabConsoleMenu}
    $inputs=[Collections.Generic.Queue[string]]::new();foreach($value in @('2','1','0')){$inputs.Enqueue($value)}
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        $calls.Menu++
        if($calls.Menu -eq 1){return [pscustomobject]@{Status='Refresh'}}
        & $realMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot ([pscustomobject]@{AttentionItems=@()}) -ForceFallback -ReadInput {$inputs.Dequeue()}
    }
    function Wait-LabConsoleAcknowledgement {$calls.Ack++}
    function Write-LabWarning {throw 'UNEXPECTED_CLI_FAILURE'}
    Show-LabResourceWatchInteractive *> $null
    $results.Add([pscustomobject]@{Name='CLI Refresh status and real fallback Details Check Back only checks once';Success=($calls.Menu -eq 4 -and $calls.Refresh -eq 1 -and $calls.Ack -eq 2)})
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $handler=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-UiResourceWatchRequest'},$true)
    . ([scriptblock]::Create($handler.Extent.Text))
    function New-WatchRequest($Body,$Method='POST',$Origin='http://127.0.0.1:12345'){
        [pscustomobject]@{HttpMethod=$Method;ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:12345/api/resource-watch';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))}
    }
    $null=Invoke-UiResourceWatchRequest (New-WatchRequest '' 'GET')
    $results.Add([pscustomobject]@{Name='HTTP GET uses same process snapshot without refresh';Success=($calls.Refresh -eq 1)})
    $null=Invoke-UiResourceWatchRequest (New-WatchRequest '{"action":"RefreshResourceWatch","parameters":{}}')
    $results.Add([pscustomobject]@{Name='HTTP explicit refresh reaches common WorkflowAction synchronously';Success=($calls.Refresh -eq 2)})
    foreach($body in @('{"action":"RefreshResourceWatch","parameters":{"Uri":"https://example.invalid"}}','{"action":"RefreshResourceWatch","parameters":[]}','{"action":"RefreshResourceWatch","parameters":{},"other":1}','{"action":"Other","parameters":{}}',('x'*1025))){
        $rejected=$false;try{$null=Invoke-UiResourceWatchRequest (New-WatchRequest $body)}catch{$rejected=$true}
        $results.Add([pscustomobject]@{Name='HTTP rejects noncanonical payload without refresh';Success=($rejected -and $calls.Refresh -eq 2)})
    }
    $rejected=$false;try{$null=Invoke-UiResourceWatchRequest (New-WatchRequest '{"action":"RefreshResourceWatch","parameters":{}}' 'POST' 'https://example.invalid')}catch{$rejected=$true}
    $results.Add([pscustomobject]@{Name='HTTP rejects foreign origin before refresh';Success=($rejected -and $calls.Refresh -eq 2)})
    $results
} $repoRoot
foreach($check in $entryResults){Add-CheckResult -Name $check.Name -Success $check.Success}
$authorityResults=& $module {
    $results=[Collections.Generic.List[object]]::new()
    $savedCatalogs=$script:CatalogsPath;$savedCache=$script:ResourceWatchCache
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $leaf='sql-lab-watch-'+[guid]::NewGuid().ToString('N');$root=Join-Path $parent $leaf
    $null=New-Item -ItemType Directory -Path $root
    try {
        foreach($file in @('software.json','sql-server-versions.json','sql-server-cu-status-sources.json')){Copy-Item -LiteralPath (Join-Path $savedCatalogs $file) -Destination (Join-Path $root $file)}
        $script:CatalogsPath=$root;$script:ResourceWatchCache=$null
        $first=Get-LabResourceWatchConfiguration
        $script:ResourceWatchCache=[pscustomobject]@{Key=$first.Key;CheckedAt=[datetimeoffset]::UtcNow;Result=[pscustomobject]@{Status='NO_CHANGE';ReasonCode='RESOURCE_WATCH_COMPLETED';Items=@();Notice=''}}
        [IO.File]::AppendAllText((Join-Path $root 'software.json'),"`n")
        $results.Add([pscustomobject]@{Name='Actual catalog bytes invalidate cache on read without network';Success=((Get-LabResourceWatchState).Status -eq 'NOT_CHECKED')})
        $guard=@{Nested=$false;Calls=0}
        $request={param($uri)
            $guard.Calls++
            if($guard.Calls -eq 1){try{$null=Invoke-LabResourceWatchRefresh}catch{$guard.Nested=$_.Exception.Message -eq 'RESOURCE_WATCH_BUSY'}}
            if($uri -match 'sqlpackage'){
                [IO.File]::AppendAllText((Join-Path $script:CatalogsPath 'software.json'),"`n")
                return [pscustomobject]@{Content='<li>Build number: 170.4.83.3</li>'}
            }
            [pscustomobject]@{Content='invalid synthetic CU source'}
        }
        $drift=Invoke-LabResourceWatchRefresh -WebRequestAction $request
        $results.Add([pscustomobject]@{Name='Refresh rejects overlapping same-session refresh';Success=$guard.Nested})
        $results.Add([pscustomobject]@{Name='Catalog change during refresh discards old-source observation';Success=($drift.Status -eq 'UNCLEAR' -and $drift.ReasonCode -eq 'RESOURCE_WATCH_CATALOG_CHANGED' -and $drift.Items.Count -eq 0)})
        [IO.File]::WriteAllText((Join-Path $root 'software.json'),'{malformed')
        $results.Add([pscustomobject]@{Name='Malformed catalog returns sanitized UNCLEAR without repair';Success=((Get-LabResourceWatchState).Status -eq 'UNCLEAR' -and [IO.File]::ReadAllText((Join-Path $root 'software.json')) -ceq '{malformed')})
    } finally {
        $script:CatalogsPath=$savedCatalogs;$script:ResourceWatchCache=$savedCache
        $resolved=(Resolve-Path -LiteralPath $root).ProviderPath
        if([IO.Path]::GetDirectoryName($resolved) -cne $parent -or [IO.Path]::GetFileName($resolved) -cne $leaf -or ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'WATCH_FIXTURE_CLEANUP_SCOPE'}
        $files=@(Get-ChildItem -LiteralPath $resolved -Force)
        foreach($file in $files){if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.DirectoryName -cne $resolved){throw 'WATCH_FIXTURE_CLEANUP_SCOPE'}}
        foreach($file in $files){Remove-Item -LiteralPath $file.FullName -Force}
        Remove-Item -LiteralPath $resolved
    }
    $results
}
foreach($check in $authorityResults){Add-CheckResult -Name $check.Name -Success $check.Success}
