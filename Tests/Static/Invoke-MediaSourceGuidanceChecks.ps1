#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($file in @('Private/LabPreferences.ps1','Private/ArtifactResolver.ps1','Private/MediaSourceGuidance.ps1','Private/MediaSourceCatalog.ps1','Public/Save-SqlServerLabMediaSource.ps1','Public/Invoke-SqlServerLabWorkflowAction.ps1','Private/ConsoleUi.ps1')) { . (Join-Path $repoRoot $file) }
function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
function Get-LabExecutableSampleVariant { @() }
function Get-LabProgressFileHash { param($LiteralPath,$Algorithm); Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm }
$script:SignatureStatus='Valid'
$script:SignatureSubject='O=Microsoft Corporation'
function Get-AuthenticodeSignature { param($FilePath); [pscustomobject]@{Status=$script:SignatureStatus;SignerCertificate=[pscustomobject]@{Subject=$script:SignatureSubject}} }
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$leaf='sql-lab-media-guidance-'+[guid]::NewGuid().ToString('N')
$fixture=Join-Path $tempParent $leaf
$null=New-Item -ItemType Directory -Path $fixture
$script:PreferenceTestPath=Join-Path $fixture 'preferences.json'
$script:CatalogsPath=Join-Path $fixture 'Catalogs'
$null=New-Item -ItemType Directory -Path $script:CatalogsPath
function Get-LabProjectPreferencesPath { $script:PreferenceTestPath }
$count=0
function Assert-Media($Condition,$Name) { if (-not $Condition) { throw "ASSERT: $Name" }; $script:count++ }
function Test-Rejected([scriptblock]$Action) { try { & $Action | Out-Null; return $false } catch { return $true } }
$catalog=Get-Content (Join-Path $repoRoot 'Catalogs/sql-server-media-sources.json') -Raw|ConvertFrom-Json
$catalog.entries=@($catalog.entries|Where-Object id -In (Get-LabMediaOverrideIds))
$payload=[Text.Encoding]::UTF8.GetBytes('synthetic-bootstrapper')
foreach($entry in $catalog.entries){$entry.expectedBytes=$payload.Length;$entry.expectedSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()}
$catalogPath=Join-Path $script:CatalogsPath 'sql-server-media-sources.json'
$catalog|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $catalogPath
$id=(Get-LabMediaOverrideIds)[0]
$url='https://download.microsoft.com/download/synthetic/SQL2025-SSEI-EntDev.exe'
$script:Downloads=[Collections.Generic.List[object]]::new()
function Save-LabProgressDownload { param($Uri,$OutFile,$MaximumRedirection=5);$script:Downloads.Add(@{Uri=$Uri;MaximumRedirection=$MaximumRedirection});[IO.File]::WriteAllBytes($OutFile,$payload);if($IsWindows){[IO.File]::SetAttributes($OutFile,[IO.FileAttributes]::Hidden)} }
try {
    $view=(Invoke-SqlServerLabWorkflowAction -Action GetMediaOverrideState).Result
    Assert-Media ($view.Status -eq 'READY' -and $view.Items.Count -eq 3 -and -not(Test-Path $script:PreferenceTestPath)) 'read without persistence'
    $plan=New-LabMediaOverridePlan -Id $id -Url $url
    Assert-Media (-not(Test-Path $script:PreferenceTestPath) -and $script:Downloads.Count -eq 0) 'preview without mutation or download'
    Assert-Media (Test-Rejected {Invoke-SqlServerLabWorkflowAction -Action ApplyMediaOverride -MediaSourcePlan $plan}) 'explicit confirmation'
    $null=Invoke-LabMediaOverridePlan -Plan $plan -WhatIf
    Assert-Media (-not(Test-Path $script:PreferenceTestPath)) 'WhatIf without persistence'
    $null=Invoke-SqlServerLabWorkflowAction -Action ApplyMediaOverride -MediaSourcePlan $plan -ConfirmMediaSource
    $view=Get-LabMediaOverrideState
    Assert-Media ($view.Items[0].EffectiveUrl -ceq $url -and $view.Items[0].Provenance -eq 'LOCAL_OVERRIDE') 'persistent effective provenance'
    $hash=(Get-FileHash $script:PreferenceTestPath).Hash
    $null=Invoke-LabMediaOverridePlan -Plan (New-LabMediaOverridePlan -Id $id -Url $url) -Confirm:$false
    Assert-Media ((Get-FileHash $script:PreferenceTestPath).Hash -eq $hash) 'noop byte stable'
    $stale=New-LabMediaOverridePlan -Id $id -Operation Reset
    Set-LabProjectPreferenceValue -Name unrelated -Value preserve
    Assert-Media (Test-Rejected {Invoke-LabMediaOverridePlan -Plan $stale -Confirm:$false}) 'stale preferences rejected'
    $stale=New-LabMediaOverridePlan -Id $id -Operation Reset
    $catalog.entries[0].note='synthetic catalog revision';$catalog|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $catalogPath
    Assert-Media (Test-Rejected {Invoke-LabMediaOverridePlan -Plan $stale -Confirm:$false}) 'stale catalog rejected'
    foreach($bad in @('http://download.microsoft.com/download/synthetic/SQL2025-SSEI-EntDev.exe','https://download.microsoft.com./download/synthetic/SQL2025-SSEI-EntDev.exe','https://download.microsoft.com:444/download/synthetic/SQL2025-SSEI-EntDev.exe',($url.Replace('https://', 'https://synthetic' + [char]64)),'https://example.invalid/download/SQL2025-SSEI-EntDev.exe',($url+'?x=1'),($url+'#x'),$url.Replace('/synthetic/','//'),$url.Replace('/synthetic/','/../'),$url.Replace('/synthetic/','/%2f/'),$url.Replace('/synthetic/','\synthetic\'),$url.Replace('EntDev','StdDev'),$url.Replace('SQL2025','sql2025'),($url+"`n"))) {
        Assert-Media (Test-Rejected {New-LabMediaOverridePlan -Id $id -Url $bad}) 'ambiguous or unapproved URL rejected'
    }
    Assert-Media (Test-Rejected {New-LabMediaOverridePlan -Id 'sql-server-2022-developer-bootstrapper' -Url $url}) 'other family rejected'
    $media=Join-Path $fixture 'Media';$null=New-Item -ItemType Directory -Path $media
    $result=Save-SqlServerLabMediaSource -Id $id -MediaRoot $media -Confirm:$false
    Assert-Media ([IO.File]::Exists($result.TargetPath)) 'hidden partial bytes verified and published'
    Assert-Media ($result.SignatureStatus -eq 'Valid') 'new bootstrapper is actually signature checked'
    Assert-Media ($result.Status -eq 'READY' -and $script:Downloads[-1].MaximumRedirection -eq 0 -and $script:Downloads[-1].Uri -ceq $url) 'real Save binds effective URL and zero redirects'
    if($IsWindows){[IO.File]::SetAttributes($result.TargetPath,[IO.FileAttributes]::Normal)}
    $drift=[byte[]]$payload.Clone();$drift[0]=0
    [IO.File]::WriteAllBytes($result.TargetPath,$drift)
    $downloadCount=$script:Downloads.Count
    $hashMismatch=try {Save-SqlServerLabMediaSource -Id $id -MediaRoot $media -Confirm:$false|Out-Null;$false}catch{$_.Exception.Message -like 'SQL_MEDIA_SOURCE_HASH_MISMATCH:*'}
    Assert-Media $hashMismatch 'existing same-size hash drift rejected'
    Assert-Media ($script:Downloads.Count -eq $downloadCount) 'hash drift does not redownload'
    $map=[ordered]@{};$map[$id]='https://example.invalid/invalid';$map['unknown']='preserve'
    Set-LabPreferencesEntry -Name mediaSourceOverrides -Value $map
    Assert-Media ((Get-LabMediaOverrideState).Status -eq 'INVALID') 'stored invalid map visible'
    Assert-Media (Test-Rejected {Save-SqlServerLabMediaSource -Id $id -MediaRoot $media -WhatIf}) 'stored invalid map Save failclosed'
    $null=Invoke-LabMediaOverridePlan -Plan (New-LabMediaOverridePlan -Id $id -Operation Reset) -Confirm:$false
    $snapshot=Get-LabPreferencesSnapshot
    Assert-Media (-not $snapshot.Document.mediaSourceOverrides.Contains($id) -and $snapshot.Document.mediaSourceOverrides.unknown -eq 'preserve' -and $snapshot.Document.unrelated -eq 'preserve') 'reset removes only selected mapping'
    Set-LabPreferencesEntry -Name mediaSourceOverrides -Value ([ordered]@{})
    Assert-Media ((Get-LabMediaOverrideState).Items[0].Provenance -eq 'REPOSITORY_DEFAULT' -and $script:Downloads.Count -eq $downloadCount) 'reset repository default without download'
    $null=Save-SqlServerLabMediaSource -Id (Get-LabMediaOverrideIds)[1] -MediaRoot $media -Confirm:$false
    Assert-Media ($script:Downloads[-1].MaximumRedirection -eq 5) 'default download contract preserved'
    $signatureRoot=Join-Path $fixture 'SignatureMedia';$null=New-Item -ItemType Directory -Path $signatureRoot
    foreach($signatureCase in @('NotSigned','WrongPublisher')) {
        $script:SignatureStatus=if($signatureCase -eq 'NotSigned'){'NotSigned'}else{'Valid'}
        $script:SignatureSubject=if($signatureCase -eq 'WrongPublisher'){'O=Synthetic Untrusted Publisher'}else{'O=Microsoft Corporation'}
        $signatureRejected=try{Save-SqlServerLabMediaSource -Id $id -MediaRoot $signatureRoot -Confirm:$false|Out-Null;$false}catch{$_.Exception.Message -like 'SQL_MEDIA_SOURCE_SIGNATURE_INVALID:*'}
        Assert-Media ($signatureRejected -and @(Get-ChildItem $signatureRoot -Recurse -File -Force).Count -eq 0) 'invalid staged EXE signature cannot publish file or sidecar'
    }
    $script:SignatureStatus='Valid';$script:SignatureSubject='O=Microsoft Corporation'
    # Real transport, only the destination boundary is replaced with an owned loopback fixture.
    . (Join-Path $repoRoot 'Private/ActionProgress.ps1')
    $realDownload=${function:Save-LabProgressDownload}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $server=[powershell]::Create()
    $requests=[Collections.Concurrent.ConcurrentBag[string]]::new()
    $null=Invoke-LabMediaOverridePlan -Plan (New-LabMediaOverridePlan -Id $id -Url $url) -Confirm:$false
    $redirectRoot=Join-Path $fixture 'RedirectMedia';$null=New-Item -ItemType Directory -Path $redirectRoot
    try {
        $listener.Start();$port=$listener.LocalEndpoint.Port
        $null=$server.AddScript({param($Listener,$Requests)
            while($true){
                if(-not $Listener.Pending()){Start-Sleep -Milliseconds 10;continue}
                $connection=$Listener.AcceptTcpClient()
                try{
                    $stream=$connection.GetStream();$reader=[IO.StreamReader]::new($stream)
                    $request=$reader.ReadLine();$Requests.Add($request);while($reader.ReadLine()){}
                    $status=if($request -match ' /(301|302|303|307|308) '){$Matches[1]}else{'200'}
                    $response=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Fixture`r`nLocation: /payload`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($response,0,$response.Length)
                }finally{$connection.Dispose()}
            }
        }).AddArgument($listener).AddArgument($requests)
        $serverRun=$server.BeginInvoke()
        foreach($status in @(301,302,303,307,308)){
            function Save-LabProgressDownload {
                param($Uri,$OutFile,$MaximumRedirection=5)
                Assert-Media ($Uri -ceq $url -and $MaximumRedirection -eq 0) 'Save transport parameters'
                & $realDownload -Uri "http://127.0.0.1:$port/$status" -OutFile $OutFile -MaximumRedirection $MaximumRedirection -TimeoutSec 5
            }
            Assert-Media (Test-Rejected {Save-SqlServerLabMediaSource -Id $id -MediaRoot $redirectRoot -Confirm:$false}) 'real 3xx rejects before payload'
        }
        Assert-Media ($requests.Count -eq 5 -and @($requests|Where-Object {$_ -match '/payload'}).Count -eq 0 -and @(Get-ChildItem $redirectRoot -Recurse -File).Count -eq 0) 'no redirect follow or payload publication'
    }finally{$listener.Stop();$server.Stop();$server.Dispose()}
    # Real guided CLI uses the same Core; cancel and reset cannot download.
    $script:MenuCalls=0;$script:ConfirmChoice=$false
    $realMenu=${function:Invoke-LabConsoleMenu}
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        $script:MenuCalls++
        if($script:MenuCalls -eq 1){return & $realMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -ForceFallback -ReadInput {'1'}}
        if($script:MenuCalls -eq 2){return [pscustomobject]@{Status='Selected';SelectedItem=($Items|Where-Object Id -eq Reset)}}
        [pscustomobject]@{Status='Cancelled'}
    }
    function Wait-LabConsoleAcknowledgement {}
    function Read-LabConfirm {param($Prompt,$Default);$script:ConfirmChoice}
    function Write-LabWarning {param($Message);throw 'UNEXPECTED_CLI_FAILURE'}
    function Write-LabInfo {param($Message)}
    $before=[IO.File]::ReadAllText($script:PreferenceTestPath)
    Show-LabMediaOverrideInteractive *> $null
    Assert-Media ([IO.File]::ReadAllText($script:PreferenceTestPath) -ceq $before) 'real fallback selection cancel byte stable'
    $script:MenuCalls=0;$script:ConfirmChoice=$true
    Show-LabMediaOverrideInteractive *> $null
    Assert-Media ((Get-LabMediaOverrideState).Items[0].Provenance -eq 'REPOSITORY_DEFAULT') 'CLI confirmed reset through real WorkflowAction'
    $uiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $handler=$uiAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiMediaOverrideRequest'},$true)
    . ([scriptblock]::Create($handler.Extent.Text))
    function New-UiMediaFixture($Body,$Origin='http://127.0.0.1:12345') {
        [pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:12345/api/media-overrides';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))}
    }
    $body=@{action='PlanMediaOverride';parameters=@{MediaSourceId=$id;MediaSourceOperation='Edit';MediaSourceUrl=$url}}|ConvertTo-Json -Depth 5
    $httpPlan=(Invoke-UiMediaOverrideRequest -Request (New-UiMediaFixture $body)).Result
    Assert-Media ($httpPlan.Id -ceq $id -and $httpPlan.EffectiveUrl -ceq $url) 'real HTTP handler reaches common plan'
    Assert-Media (Test-Rejected {Invoke-UiMediaOverrideRequest -Request (New-UiMediaFixture $body 'https://example.invalid')}) 'HTTP foreign origin blocked'
    Assert-Media (Test-Rejected {Invoke-UiMediaOverrideRequest -Request (New-UiMediaFixture '{"action":"ApplyMediaOverride","parameters":{"ConfirmMediaSource":"true"}}')}) 'HTTP typed confirmation required'
    Assert-Media (Test-Rejected {Invoke-UiMediaOverrideRequest -Request (New-UiMediaFixture '{"action":"PlanMediaOverride","parameters":{"MediaRoot":"unexpected"}}')}) 'HTTP unknown parameter blocked'
    Assert-Media (Test-Rejected {Invoke-UiMediaOverrideRequest -Request (New-UiMediaFixture ('x'*16385))}) 'HTTP bounded payload'
    & {
        $pending=New-LabMediaOverridePlan -Id $id -Operation Reset
        $realLock=${function:Invoke-WithLabPreferencesLock}
        function Invoke-WithLabPreferencesLock {
            param($Path,$Body)
            $interleaved=Get-LabPreferencesSnapshot
            $interleaved.Document['parallelPreference']='preserve'
            Write-LabArtifactJsonAtomic -Path $interleaved.Path -InputObject $interleaved.Document
            & $realLock -Path $Path -Body $Body
        }
        Assert-Media (Test-Rejected {Invoke-LabMediaOverridePlan -Plan $pending -Confirm:$false}) 'noop revalidates after waiting for writerlock'
        Assert-Media ((Get-LabPreferencesSnapshot).Document.parallelPreference -eq 'preserve') 'interleaved unrelated preference preserved'
    }
    Set-Content -LiteralPath $script:PreferenceTestPath -Value '{malformed'
    Assert-Media ((Get-LabMediaOverrideState).Status -eq 'INVALID' -and @(Get-LabMediaSourceCatalog|Where-Object SourceProvenance -eq INVALID).Count -eq 3) 'malformed preferences visible without default fallback'
    Assert-Media (Test-Rejected {New-LabMediaOverridePlan -Id $id -Url $url}) 'malformed preferences failclosed'
    Assert-Media ((Get-Content $script:PreferenceTestPath -Raw).Trim() -eq '{malformed') 'malformed unchanged'
}
finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixture).ProviderPath)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not [IO.Path]::GetDirectoryName($resolved).Equals($tempParent,$comparison) -or (Split-Path -Leaf $resolved) -cne $leaf -or $leaf -cnotmatch '^sql-lab-media-guidance-[a-f0-9]{32}$' -or ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
    $items=@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
    foreach($item in $items){if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.FullName.StartsWith($resolved+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'FIXTURE_CLEANUP_CONTENT_INVALID'}}
    foreach($item in @($items|Where-Object {-not $_.PSIsContainer})){Remove-Item -LiteralPath $item.FullName -Force}
    foreach($item in @($items|Where-Object PSIsContainer|Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force}
    Remove-Item -LiteralPath $resolved -Force
}
Write-Host "MEDIA SOURCE GUIDANCE: $count PASS"
