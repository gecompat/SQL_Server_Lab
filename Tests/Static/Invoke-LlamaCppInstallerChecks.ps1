#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root=Join-Path $parent ('sql-lab-installer-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
 & $module {
  param($Root,$Repo)
  $script:checks=0
  function Assert-Installer($Condition,$Name){if(-not $Condition){throw "ASSERT: $Name"};$script:checks++}
  function Rejected([scriptblock]$Body,[string]$Code){try{& $Body|Out-Null;return $false}catch{if($Code -and $_.Exception.Message -ne $Code){Write-Host ("Fixture expected "+$Code+"; actual "+$_.Exception.Message)};return -not $Code -or $_.Exception.Message -eq $Code}}
  $realCatalog=Get-LabLlamaInstallerCatalog
  Assert-Installer ((Get-Content (Join-Path $Repo 'Catalogs/llama-cpp-runtime-packages.json') -Raw|Test-Json -SchemaFile (Join-Path $Repo 'Schemas/llama-cpp-runtime-packages.schema.json'))) 'curated catalog schema'
  Assert-Installer ($realCatalog.Item.Files.Count -eq 51 -and $realCatalog.Item.Recommendation -eq 'UNASSESSED') 'curated full package and nonrecommendation'
  $null=[IO.Directory]::CreateDirectory($Root)
  $script:installerRoot=$Root
  function Get-LabMediaRootCandidates {[pscustomobject]@{Path=$script:installerRoot}}
  function Get-LabLlamaInstallerPrerequisite {'PRESENT_VERSION_COMPATIBILITY_UNKNOWN'}
  $roots=@(Get-LabLlamaInstallerRoots)
  Assert-Installer ($roots.Count -eq 1) 'registered existing root'
  $binding=@{CandidateId=$realCatalog.Item.Id;RootId=$roots[0].Id}
  $before=@(Get-ChildItem $Root -Force).Count
  $plan=Get-LabLlamaInstallerPlan @binding
  Assert-Installer ($plan.State -eq 'ABSENT' -and $plan.CanApply -and @(Get-ChildItem $Root -Force).Count -eq $before) 'preview never creates directories'
  $cancel=Invoke-LabLlamaInstaller @binding -ExpectedKey $plan.ExpectedKey
  Assert-Installer ($cancel.Status -eq 'CANCELLED' -and @(Get-ChildItem $Root -Force).Count -eq $before) 'cancel before transfer and mutation'
  Assert-Installer (Rejected {Invoke-LabLlamaInstaller @binding -ExpectedKey ('a'*64) -Confirmed} 'LLAMA_INSTALL_PREVIEW_STALE') 'stale before network'
  $script:installerRoot=$Root+[IO.Path]::DirectorySeparatorChar
  Assert-Installer ((Get-LabLlamaInstallerPlan @binding).ExpectedKey -ceq $plan.ExpectedKey) 'root separator alias same authority'
  $held=Enter-LabLlamaInstallerLock -Target $plan.Target
  $job=$null
  try {
   $job=Start-Job -ScriptBlock {
    param($Repository,$Target)
    $m=Import-Module (Join-Path $Repository 'SqlServerLab.psd1') -Force -PassThru
    & $m {param($Alias)try{$lock=Enter-LabLlamaInstallerLock -Target $Alias -TimeoutMilliseconds 100;try{'UNEXPECTED_ACQUIRED'}finally{$lock.ReleaseMutex();$lock.Dispose()}}catch{$_.Exception.Message}} ($Target+[IO.Path]::DirectorySeparatorChar)
   } -ArgumentList $Repo,$plan.Target
   $done=$job|Wait-Job -Timeout 30
   Assert-Installer ($done -and @($job|Receive-Job) -contains 'LLAMA_INSTALL_LOCK_TIMEOUT') 'real competing process separator alias shares bounded global mutex'
  } finally {if($job){$job|Stop-Job;$job|Remove-Job};$held.ReleaseMutex();$held.Dispose()}
  $aliasTarget=Join-Path $Root 'alias-target';$null=[IO.Directory]::CreateDirectory($aliasTarget)
  $alias=Join-Path $Root 'alias'
  try {
   if($IsWindows){$null=New-Item -ItemType Junction -Path $alias -Target $aliasTarget}else{$null=[IO.Directory]::CreateSymbolicLink($alias,$aliasTarget)}
   Assert-Installer (Rejected {Assert-LabLlamaInstallerPath (Join-Path $alias 'new/child')} 'LLAMA_INSTALL_PATH_ALIAS') 'real filesystem alias ancestor fails closed'
  }finally{if(Get-Item -LiteralPath $alias -Force -ErrorAction SilentlyContinue){[IO.Directory]::Delete($alias)}}
  $script:installerRoot=$Root
  foreach($bad in @('http://github.com/a','https://example.invalid/a','https://github.com:444/a','https://github.com/a#fragment')){Assert-Installer (Rejected {Assert-LabLlamaInstallerUri ([uri]$bad)}) 'untrusted transport endpoint blocked'}
  $credentialUri=[UriBuilder]::new('https://github.com/a');$credentialUri.UserName='synthetic-user'
  Assert-Installer (Rejected {Assert-LabLlamaInstallerUri $credentialUri.Uri}) 'URI credentials are rejected even on an allowed host'
  $script:responses=[Collections.Generic.Queue[object]]::new()
  function Send-LabLlamaInstallerHttp {param($Client,$Uri,$Token) if($Token.IsCancellationRequested){throw 'cancelled'};$script:responses.Dequeue()}
  function Response([int]$Status,[byte[]]$Data,[string]$Redirect=''){$r=[Net.Http.HttpResponseMessage]::new($Status);$r.Content=[Net.Http.ByteArrayContent]::new($Data);if($Redirect){$r.Headers.Location=[uri]$Redirect};$r}
  $script:responses.Enqueue((Response 302 @() 'https://example.invalid/secret'))
  Assert-Installer (Rejected {Receive-LabLlamaInstallerBytes -Uri 'https://github.com/a' -MaximumBytes 8} 'LLAMA_INSTALL_HOST_REJECTED') 'actual transfer refuses redirect before second send'
  $script:responses.Enqueue((Response 200 ([byte[]](1..9))))
  Assert-Installer (Rejected {Receive-LabLlamaInstallerBytes -Uri 'https://github.com/a' -MaximumBytes 8} 'LLAMA_INSTALL_TRANSFER_LIMIT') 'actual transfer checks content length'
  $r=Response 200 ([byte[]](1..9));$r.Content.Headers.ContentLength=$null;$script:responses.Enqueue($r)
  Assert-Installer (Rejected {Receive-LabLlamaInstallerBytes -Uri 'https://github.com/a' -MaximumBytes 8} 'LLAMA_INSTALL_TRANSFER_LIMIT') 'actual transfer enforces streamed bytes'
  $script:responses.Enqueue((Response 200 ([byte[]](1,2,3))))
  Assert-Installer ((Receive-LabLlamaInstallerBytes -Uri 'https://github.com/a' -MaximumBytes 3).Length -eq 3) 'actual bounded transfer returns exact bytes'
  $item=$realCatalog.Item
  $metadata=@{id=$item.ReleaseId;tag_name=$item.Tag;target_commitish=$item.Commit;immutable=$false;assets=@(@{id=$item.AssetId;name=$item.AssetName;size=$item.Bytes;digest=('sha256:'+$item.Sha256);browser_download_url=('https://github.com/ggml-org/llama.cpp/releases/download/'+$item.Tag+'/'+$item.AssetName)})}
  $script:responses.Enqueue((Response 200 ([Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json -Depth 5)))))
  Assert-Installer ((Get-LabLlamaInstallerUpstream).Status -eq 'PIN_MATCHES_OFFICIAL_METADATA') 'real upstream revalidation binds all pin fields'
  $metadata.assets[0].digest='sha256:'+('a'*64)
  $script:responses.Enqueue((Response 200 ([Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json -Depth 5)))))
  Assert-Installer (Rejected {Get-LabLlamaInstallerUpstream} 'LLAMA_INSTALL_UPSTREAM_DRIFT') 'metadata hash drift does not choose new release'
  function New-FixtureArchive([string]$Name,[string[]]$EntryNames=@('llama-server.exe','LICENSE-LLVM-OpenMP'),[int]$Attributes=0){
   $path=Join-Path $Root $Name;$zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
   $files=@();try{foreach($entryName in $EntryNames){$entry=$zip.CreateEntry($entryName);$entry.ExternalAttributes=$Attributes;$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic non-executable fixture');$s=$entry.Open();try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()};$files += [pscustomobject]@{Name=$entryName;Bytes=$bytes.Length;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}}}finally{$zip.Dispose()}
   [pscustomobject]@{Path=$path;Catalog=[pscustomobject]@{Files=$files;Bytes=(Get-Item $path).Length;Sha256=(Get-FileHash $path).Hash.ToLowerInvariant()}}
  }
  $fixture=New-FixtureArchive 'valid.zip'
  $destination=Join-Path $Root 'expanded'
  Expand-LabLlamaInstallerArchive -ArchivePath $fixture.Path -Destination $destination -Catalog $fixture.Catalog
  Assert-Installer (@(Get-ChildItem $destination).Count -eq 2) 'real archive bounded extraction and exact hashes'
  [IO.File]::WriteAllText((Join-Path $destination 'extra.dll'),'extra')
  Assert-Installer (Rejected {Test-LabLlamaInstallerFiles -Path $destination -Catalog $fixture.Catalog} 'LLAMA_INSTALL_FILESET_MISMATCH') 'extra file invalidates receipt'
  $index=0
  foreach($names in @(@('../evil.exe'),@('/evil.exe'),@('C:evil.exe'),@('a/b.exe'),@('evil.exe','EVIL.exe'),@('CON.exe'),@('bad.exe '))){
   $bad=New-FixtureArchive ('bad'+$index+'.zip') $names;$dest=Join-Path $Root ('bad-dest'+$index);$index++
   Assert-Installer (Rejected {Expand-LabLlamaInstallerArchive -ArchivePath $bad.Path -Destination $dest -Catalog $bad.Catalog}) 'unsafe archive blocked'
   Assert-Installer (-not (Test-Path $dest)) 'all entry paths checked before destination creation'
  }
  $link=New-FixtureArchive 'symlink.zip' @('evil.dll') ([int]0xA0000000)
  Assert-Installer (Rejected {Expand-LabLlamaInstallerArchive -ArchivePath $link.Path -Destination (Join-Path $Root 'link-dest') -Catalog $link.Catalog} 'LLAMA_INSTALL_ARCHIVE_UNSAFE') 'unix symlink blocked'
  $script:fixtureCatalog=$realCatalog|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12
  $script:fixtureCatalog.Item.Files=$fixture.Catalog.Files;$script:fixtureCatalog.Item.Bytes=$fixture.Catalog.Bytes;$script:fixtureCatalog.Item.Sha256=$fixture.Catalog.Sha256
  function Get-LabLlamaInstallerCatalog {$script:fixtureCatalog}
  $script:network=0;$script:probe=0
  function Get-LabLlamaInstallerUpstream {$script:network++;[pscustomobject]@{Status='PIN_MATCHES_OFFICIAL_METADATA'}}
  $script:archiveBytes=[IO.File]::ReadAllBytes($fixture.Path)
  $script:realInstallerProbe=(Get-Command Invoke-LabLlamaInstallerProbe).ScriptBlock
  function Receive-LabLlamaInstallerBytes {param($Uri,$MaximumBytes) $script:network++;return ,$script:archiveBytes}
  function Invoke-LabLlamaInstallerProbe {param($Plan,$OperationId) $script:probe++}
  function Protect-LabLlamaCppOperationPath {param($Path) }
  $plan=Get-LabLlamaInstallerPlan @binding
  $result=Invoke-LabLlamaInstaller @binding -ExpectedKey $plan.ExpectedKey -Confirmed
  Assert-Installer ($result.Status -eq 'BINARY_PROBE_PASSED' -and $script:probe -eq 1 -and -not (Test-Path $plan.Operation)) 'real plan apply publish cleanup with synthetic boundary probe'
  $repeat=Get-LabLlamaInstallerPlan @binding;$network=$script:network
  $noop=Invoke-LabLlamaInstaller @binding -ExpectedKey $repeat.ExpectedKey -Confirmed
  Assert-Installer ($noop.Status -eq 'NO_CHANGE' -and $script:network -eq $network -and $script:probe -eq 1) 'verified no-op before transport/probe'
  [IO.File]::WriteAllText((Join-Path $repeat.Package 'llama-server.exe'),'drift')
  Assert-Installer ((Get-LabLlamaInstallerPlan @binding).State -eq 'DRIFT' -and (Rejected {Invoke-LabLlamaInstaller @binding -ExpectedKey $repeat.ExpectedKey -Confirmed} 'LLAMA_INSTALL_PREVIEW_STALE')) 'postinstall drift blocks stale apply'
  $null=[IO.Directory]::CreateDirectory($repeat.Operation)
  Assert-Installer ((Get-LabLlamaInstallerPlan @binding).State -eq 'RECOVERY_REQUIRED') 'existing operation blocks automatic replay'
  $previousRoot=$script:installerRoot
  $script:installerRoot=Join-Path $Root 'failed';$null=[IO.Directory]::CreateDirectory($script:installerRoot)
  $failedRoots=@(Get-LabLlamaInstallerRoots);$failedPlan=Get-LabLlamaInstallerPlan -CandidateId $binding.CandidateId -RootId $failedRoots[0].Id
  function Invoke-LabLlamaInstallerProbe {param($Plan,$OperationId) throw 'LLAMA_INSTALL_PROBE_FAILED'}
  Assert-Installer (Rejected {Invoke-LabLlamaInstaller -CandidateId $binding.CandidateId -RootId $failedRoots[0].Id -ExpectedKey $failedPlan.ExpectedKey -Confirmed} 'LLAMA_INSTALL_RECOVERY_REQUIRED') 'failed probe cannot publish'
  Assert-Installer (-not (Test-Path $failedPlan.Target) -and (Test-Path $failedPlan.Operation) -and (Test-Path $repeat.Operation)) 'failed probe retains own stage and earlier recovery'
  foreach($mode in @('RECOVERY_REQUIRED','MISSING_END')){
   $script:installerRoot=Join-Path $Root $mode;$null=[IO.Directory]::CreateDirectory($script:installerRoot)
   $uncertainRoot=@(Get-LabLlamaInstallerRoots)[0];$uncertainPlan=Get-LabLlamaInstallerPlan -CandidateId $binding.CandidateId -RootId $uncertainRoot.Id
   $script:receiptMode=$mode
   function Invoke-LabLlamaInstallerProbe {
    param($Plan,$OperationId)
    $probe=Join-Path $Plan.Operation 'probe';$null=[IO.Directory]::CreateDirectory($probe)
    $record=@{OperationId=$OperationId;Status='RECOVERY_REQUIRED';Code='LLAMA_TERMINATION_UNCONFIRMED';ChildTerminationConfirmed=$false}
    if($script:receiptMode -eq 'MISSING_END'){$record.Status='BINARY_PROBE_PASSED';$record.Code='COMPUTE_SQL_NOT_CHECKED';$record.Remove('ChildTerminationConfirmed')}
    $path=Join-Path $probe 'receipt.json';[IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress))
    $script:uncertainSnapshot=@(Get-ChildItem $Plan.Operation -Recurse -File|Sort-Object FullName|ForEach-Object{(Get-FileHash $_.FullName).Hash}) -join '|'
    $null=Read-LabLlamaInstallerProbeReceipt -Path $path -OperationId $OperationId
   }
   Assert-Installer (Rejected {Invoke-LabLlamaInstaller -CandidateId $binding.CandidateId -RootId $uncertainRoot.Id -ExpectedKey $uncertainPlan.ExpectedKey -Confirmed} 'LLAMA_INSTALL_RECOVERY_REQUIRED') 'actual receipt uncertainty reaches apply recovery'
   $after=@(Get-ChildItem $uncertainPlan.Operation -Recurse -File|Sort-Object FullName|ForEach-Object{(Get-FileHash $_.FullName).Hash}) -join '|'
   Assert-Installer ((Test-Path $uncertainPlan.Operation) -and -not (Test-Path $uncertainPlan.Target) -and $after -ceq $script:uncertainSnapshot) 'unconfirmed child end preserves exact stage and diagnostics'
  }
  $script:installerRoot=$previousRoot
  # Import the actual HTTP handler; it never accepts URLs, hashes or paths as authority.
  . (Join-Path $Repo 'Tools/WorkflowUiJsonBody.ps1')
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
  $handler=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-UiLlamaInstallerRequest'},$true)
  . ([scriptblock]::Create($handler.Extent.Text))
  function Request([object]$Body,[string]$Origin='http://127.0.0.1:12345'){$text=$Body|ConvertTo-Json -Compress;[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:12345/api/llama-installer';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text))}}
  Assert-Installer (Rejected {Invoke-UiLlamaInstallerRequest (Request @{action='preview';candidateId=$binding.CandidateId;rootId=$binding.RootId;url='https://example.invalid'})} 'LLAMA_INSTALL_REQUEST_INVALID') 'HTTP rejects client source authority'
  Assert-Installer (Rejected {Invoke-UiLlamaInstallerRequest (Request @{action='preview';candidateId=$binding.CandidateId;rootId=$binding.RootId} 'https://example.invalid')} 'LLAMA_INSTALL_ORIGIN_INVALID') 'HTTP rejects cross origin'
  Assert-Installer (Rejected {Invoke-UiLlamaInstallerRequest (Request @{action='apply';candidateId=$binding.CandidateId;rootId=$binding.RootId;expectedKey=$repeat.ExpectedKey;confirmed='true'})} 'LLAMA_INSTALL_CONFIRMATION_REQUIRED') 'HTTP requires typed explicit confirmation'
  $http=Invoke-UiLlamaInstallerRequest (Request @{action='preview';candidateId=$binding.CandidateId;rootId=$binding.RootId})
  Assert-Installer ($http.State -eq 'RECOVERY_REQUIRED' -and -not $http.CanApply -and -not $http.PSObject.Properties['Catalog']) 'real HTTP plan returns allowlisted blocked DTO'
  $script:installerRoot=Join-Path $Root 'cli';$null=[IO.Directory]::CreateDirectory($script:installerRoot)
  $script:realInstallerMenu=(Get-Command Invoke-LabConsoleMenu).ScriptBlock
  $script:keys=[Collections.Generic.Queue[string]]::new();$script:frames=[Collections.Generic.List[object]]::new()
  function Update-LabConsoleAttentionSnapshot {$null}
  function Wait-LabConsoleAcknowledgement {}
  function Read-LabConfirm {param($Prompt,$Default) $false}
  function Invoke-LabConsoleMenu {
   param($ScreenId,$Title,$Subtitle,$Items)
   if($script:installerFallback){return & $script:realInstallerMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null -ForceFallback -ReadInput {$script:keys.Dequeue()}}
   & $script:realInstallerMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null `
    -Capability ([pscustomobject]@{Supported=$true;Mode='CURSOR'}) -GetViewport {[pscustomobject]@{Width=140;Height=30}} `
    -SessionFactory {[pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'}} -SessionCompleter {} `
    -FrameWriter {param($s,$f)$script:frames.Add($f)} -ReadKey {
      switch($script:keys.Dequeue()) {
       refresh {[pscustomobject]@{Key='F5';KeyChar=[char]0;Modifiers=0}}
       select {[pscustomobject]@{Key='Enter';KeyChar=[char]13;Modifiers=0}}
       back {[pscustomobject]@{Key='Escape';KeyChar=[char]27;Modifiers=0}}
       installer {[pscustomobject]@{Key='D8';KeyChar=[char]56;Modifiers=0}}
      }
    }
  }
  $network=$script:network;$probe=$script:probe
  @('refresh','select','select','back')|ForEach-Object {$script:keys.Enqueue($_)}
  Show-LabLlamaInstallerInteractive 6>$null
  Assert-Installer ($script:keys.Count -eq 0 -and $script:network -eq $network -and $script:probe -eq $probe -and @(Get-ChildItem $script:installerRoot -Force).Count -eq 0) 'real CLI cursor F5 selection cancel back never downloads'
  Assert-Installer (@($script:frames|Where-Object {($_.Lines -join ' ') -match 'Windows / x64 / CPU'}).Count -gt 0) 'real cursor persists bounded lane'
  $script:installerFallback=$true;@('r','0')|ForEach-Object {$script:keys.Enqueue($_)}
  Show-LabLlamaInstallerInteractive 6>$null
  Assert-Installer ($script:keys.Count -eq 0 -and $script:network -eq $network) 'actual fallback refresh back performs no online refresh'
  function Get-LabWorkflowLifecycleFingerprint {'synthetic-unchanged'}
  function New-LabQueueStatusProvider {param($Height) $null}
  function Sync-LabConnectionCenterAfterLifecycle {throw 'UNEXPECTED_CONNECTION_SYNC'}
  $script:keys.Enqueue('0');Invoke-SqlServerLab -Action RuntimeInstaller 6>$null
  Assert-Installer ($script:keys.Count -eq 0 -and $script:network -eq $network) 'public direct action reaches real installer cancel without sync'
  $script:keys.Enqueue('8');$selected=Show-LabResourceMenu;$script:keys.Enqueue('0');Invoke-LabMenuAction -ActionName $selected 6>$null
  Assert-Installer ($selected -ceq 'RuntimeInstaller' -and $script:keys.Count -eq 0 -and $script:network -eq $network) 'real resources fallback shortcut 8 dispatches installer cancel'
  $script:installerFallback=$false;$script:keys.Enqueue('installer');$selected=Show-LabResourceMenu;$script:keys.Enqueue('back');Invoke-LabMenuAction -ActionName $selected 6>$null
  Assert-Installer ($selected -ceq 'RuntimeInstaller' -and $script:keys.Count -eq 0 -and $script:network -eq $network) 'real resources cursor shortcut 8 dispatches installer cancel'
  # Execute the worker's actual cumulative copy implementation and environment branch,
  # with memory streams and ProcessStartInfo only. No native process is started.
  $workerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),[ref]$tokens,[ref]$errors)
  foreach($name in @('Write-Receipt','Confirm-LabLlamaWorkerChildTermination')){
   $fn=$workerAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
   . ([scriptblock]::Create($fn.Extent.Text))
  }
  $workerTry=$workerAst.Find({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains('Confirm-LabLlamaWorkerChildTermination')},$true)
  $finallyBody=$workerTry.Finally.Extent.Text.Trim();$finallyBody=$finallyBody.Substring(1,$finallyBody.Length-2)
  $catchBody=$workerTry.CatchClauses[0].Body.Extent.Text.Trim();$catchBody=$catchBody.Substring(1,$catchBody.Length-2)
  $script:workerCatchBody=$catchBody;$script:workerFinallyBody=$finallyBody
  $operationRoot=Join-Path $Root 'finally-receipt';$null=[IO.Directory]::CreateDirectory($operationRoot)
  $receiptPath=Join-Path $operationRoot 'receipt.json';$request=[pscustomobject]@{OperationId=[guid]::NewGuid().ToString('D')}
  $child=[pscustomobject]@{HasExited=$false;Id=123;StartTime=[DateTime]::UtcNow}
  $child|Add-Member ScriptMethod Kill {param($Tree)};$child|Add-Member ScriptMethod WaitForExit {param($Milliseconds) $false};$child|Add-Member ScriptMethod Dispose {}
  $launchAttempted=$true;$childTerminationConfirmed=$false;$outTask=$null;$errTask=$null;$outStream=$null;$errStream=$null;$finalStatus='FAILED';$finalCode='LLAMA_WORKER_FAILED'
  . ([scriptblock]::Create($finallyBody))
  $endReceipt=Get-Content $receiptPath -Raw|ConvertFrom-Json
  Assert-Installer ($endReceipt.Status -ceq 'RECOVERY_REQUIRED' -and -not $endReceipt.ChildTerminationConfirmed -and (Rejected {Read-LabLlamaInstallerProbeReceipt -Path $receiptPath -OperationId $request.OperationId} 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED')) 'actual worker finally false wait emits recovery and real parent classifier blocks cleanup'
  $child|Add-Member ScriptMethod WaitForExit {param($Milliseconds) throw 'SYNTHETIC_WAIT_FAILURE'} -Force
  . ([scriptblock]::Create($finallyBody))
  Assert-Installer ((Get-Content $receiptPath -Raw|ConvertFrom-Json).Status -ceq 'RECOVERY_REQUIRED') 'actual worker finally exception preserves unconfirmed termination'
  foreach($case in @(
   @{Message='LLAMA_INSTALL_FILES_MISSING';Expected='LLAMA_INSTALL_PROBE_PACKAGE_FAILED';Started=$false;Attempted=$false},
   @{Message='LLAMA_INSTALL_PLATFORM_UNSUPPORTED';Expected='LLAMA_INSTALL_PROBE_SETUP_FAILED';Started=$false;Attempted=$false},
   @{Message='synthetic private setup detail';Expected='LLAMA_INSTALL_PROBE_SETUP_FAILED';Started=$false;Attempted=$false},
   @{Message='synthetic private start detail';Expected='LLAMA_INSTALL_PROBE_START_FAILED';Started=$false;Attempted=$true},
   @{Message='LLAMA_INSTALL_PROBE_OUTPUT_LIMIT';Expected='LLAMA_INSTALL_PROBE_OUTPUT_LIMIT';Started=$true;Attempted=$true},
   @{Message='LLAMA_INSTALL_PROBE_TIMEOUT';Expected='LLAMA_INSTALL_PROBE_TIMEOUT';Started=$true;Attempted=$true},
   @{Message='LLAMA_INSTALL_PROBE_OWNER_CLOSED';Expected='LLAMA_INSTALL_PROBE_OWNER_CLOSED';Started=$true;Attempted=$true},
   @{Message='LLAMA_INSTALL_PROBE_NONZERO_EXIT';Expected='LLAMA_INSTALL_PROBE_NONZERO_EXIT';Started=$true;Attempted=$true},
   @{Message='LLAMA_INSTALL_PROBE_VERSION_MISMATCH';Expected='LLAMA_INSTALL_PROBE_VERSION_MISMATCH';Started=$true;Attempted=$true},
   @{Message='synthetic private unexpected detail';Expected='LLAMA_INSTALL_PROBE_FAILED';Started=$true;Attempted=$true}
  )){
   $installerProbe=$true;$launchAttempted=$case.Attempted;$child=$null
   if($case.Started){$child=[pscustomobject]@{HasExited=$true;Id=123;StartTime=[DateTime]::UtcNow;ExitCode=17};$child|Add-Member ScriptMethod WaitForExit {param($Milliseconds)$true};$child|Add-Member ScriptMethod Dispose {}}
   try{throw $case.Message}catch{. ([scriptblock]::Create($catchBody))}
   Assert-Installer ($finalCode -ceq $case.Expected) 'actual worker catch emits fixed failure class only'
   . ([scriptblock]::Create($finallyBody))
   $r=Get-Content $receiptPath -Raw|ConvertFrom-Json
   Assert-Installer ($r.ProbeStarted -eq $case.Started -and $r.LaunchAttempted -eq $case.Attempted -and ($case.Started -or $null -eq $r.ExitCode)) 'actual receipt separates attempted started and nullable exit'
   if($case.Attempted -and -not $case.Started){Assert-Installer ($r.Status -ceq 'RECOVERY_REQUIRED' -and (Rejected {Read-LabLlamaInstallerProbeReceipt -Path $receiptPath -OperationId $request.OperationId} 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED')) 'failed launch with unknown end remains recovery'}
   else{Assert-Installer (Rejected {Assert-LabLlamaInstallerProbeResult -Receipt (Read-LabLlamaInstallerProbeReceipt -Path $receiptPath -OperationId $request.OperationId)} $case.Expected) 'real receipt reader and parent classifier retain fixed failure reason'}
  }
  # The actual Apply path receives actual catch/finally/receipt classification.
  $script:installerRoot=Join-Path $Root 'diagnostic-preservation';$null=[IO.Directory]::CreateDirectory($script:installerRoot)
  $diagnosticRoot=@(Get-LabLlamaInstallerRoots)[0];$diagnosticPlan=Get-LabLlamaInstallerPlan -CandidateId $binding.CandidateId -RootId $diagnosticRoot.Id
  function Invoke-LabLlamaInstallerProbe {
   param($Plan,$OperationId)
   $operationRoot=Join-Path $Plan.Operation 'probe';$null=[IO.Directory]::CreateDirectory($operationRoot)
   $receiptPath=Join-Path $operationRoot 'receipt.json';$request=[pscustomobject]@{OperationId=$OperationId}
   $installerProbe=$true;$launchAttempted=$true;$childTerminationConfirmed=$false
   $child=[pscustomobject]@{HasExited=$true;Id=123;StartTime=[DateTime]::UtcNow;ExitCode=17};$child|Add-Member ScriptMethod WaitForExit {param($Milliseconds)$true};$child|Add-Member ScriptMethod Dispose {}
   $outTask=$null;$errTask=$null;$outStream=$null;$errStream=$null
   [IO.File]::WriteAllText((Join-Path $operationRoot 'stderr.log'),'synthetic bounded failure')
   try{throw 'LLAMA_INSTALL_PROBE_NONZERO_EXIT'}catch{. ([scriptblock]::Create($script:workerCatchBody))}
   . ([scriptblock]::Create($script:workerFinallyBody))
   $script:diagnosticSnapshot=@(Get-ChildItem $Plan.Operation -Recurse -File|Sort-Object FullName|ForEach-Object{(Get-FileHash $_.FullName).Hash}) -join '|'
   Assert-LabLlamaInstallerProbeResult -Receipt (Read-LabLlamaInstallerProbeReceipt -Path $receiptPath -OperationId $OperationId)
  }
  $recoveryError=$null
  try{Invoke-LabLlamaInstaller -CandidateId $binding.CandidateId -RootId $diagnosticRoot.Id -ExpectedKey $diagnosticPlan.ExpectedKey -Confirmed|Out-Null}catch{$recoveryError=$_.Exception}
  Assert-Installer ($recoveryError.Message -ceq 'LLAMA_INSTALL_RECOVERY_REQUIRED' -and $recoveryError.Data['FailureCode'] -ceq 'LLAMA_INSTALL_PROBE_NONZERO_EXIT' -and $recoveryError.Data['ChildTerminationConfirmed'] -eq $true) 'apply retains reason and confirmed end without implying running process'
  $after=@(Get-ChildItem $diagnosticPlan.Operation -Recurse -File|Sort-Object FullName|ForEach-Object{(Get-FileHash $_.FullName).Hash}) -join '|'
  Assert-Installer ($after -ceq $script:diagnosticSnapshot -and -not (Test-Path $diagnosticPlan.Target) -and (Get-LabLlamaInstallerPlan -CandidateId $binding.CandidateId -RootId $diagnosticRoot.Id).State -ceq 'RECOVERY_REQUIRED') 'failed confirmed probe preserves exact diagnostic bytes and blocks replay'
  $script:installerRoot=Join-Path $Root 'download-failure';$null=[IO.Directory]::CreateDirectory($script:installerRoot)
  $downloadRoot=@(Get-LabLlamaInstallerRoots)[0];$downloadPlan=Get-LabLlamaInstallerPlan -CandidateId $binding.CandidateId -RootId $downloadRoot.Id
  function Receive-LabLlamaInstallerBytes {param($Uri,$MaximumBytes)throw 'LLAMA_INSTALL_TRANSFER_FAILED'}
  Assert-Installer (Rejected {Invoke-LabLlamaInstaller -CandidateId $binding.CandidateId -RootId $downloadRoot.Id -ExpectedKey $downloadPlan.ExpectedKey -Confirmed} 'LLAMA_INSTALL_TRANSFER_FAILED') 'preprobe download failure retains prior classification'
  Assert-Installer (-not (Test-Path $downloadPlan.Operation) -and -not (Test-Path $downloadPlan.Target)) 'preprobe failed download still cleans only own staging'
  $script:installerRoot=$previousRoot
  # Execute the real post-exit output/identity/hash branch with real file handles.
  # Windows ReadAllText cannot read while an existing writer still holds the file.
  $postExit=$workerAst.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($installerProbe)') -and $n.Extent.Text.Contains("throw 'LLAMA_INSTALL_PROBE_VERSION_MISMATCH'")},$true)
  $operationRoot=Join-Path $Root 'post-exit-reader';$null=[IO.Directory]::CreateDirectory($operationRoot)
  $outStream=[IO.FileStream]::new((Join-Path $operationRoot 'stdout.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
  $errStream=[IO.FileStream]::new((Join-Path $operationRoot 'stderr.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
  $versionBytes=[Text.Encoding]::UTF8.GetBytes("version: synthetic (build 11247, commit 0bc845d35)`n")
  $errStream.Write($versionBytes,0,$versionBytes.Length)
  $installerProbe=$true;$outTask=[Threading.Tasks.Task]::FromResult($true);$errTask=[Threading.Tasks.Task]::FromResult($true)
  $reason='PROCESS_EXITED';$child=[pscustomobject]@{ExitCode=0};$catalog=$diagnosticPlan.Catalog;$package=Join-Path $diagnosticPlan.Operation ('stage/'+$diagnosticPlan.PackageLeaf)
  try{. ([scriptblock]::Create($postExit.Extent.Text));Assert-Installer ($finalStatus -ceq 'BINARY_PROBE_PASSED' -and $null -eq $outStream -and $null -eq $errStream) 'real post-exit branch closes writers before reading exact version and package hashes'}finally{if($outStream){$outStream.Dispose()};if($errStream){$errStream.Dispose()}}
  $definition=$workerAst.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class SqlLabLlamaJob')},$true)
  if(-not $definition){$definition=$workerAst.Find({param($n)$n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Value.Contains('public static class SqlLabLlamaJob')},$true)}
  Add-Type -TypeDefinition $definition.Value
  $first=[IO.MemoryStream]::new([byte[]]::new(40000));$second=[IO.MemoryStream]::new([byte[]]::new(30000));$out=[IO.MemoryStream]::new()
  try{$a=[SqlLabLlamaJob]::CopyProbeBounded($first,$out).GetAwaiter().GetResult();$b=[SqlLabLlamaJob]::CopyProbeBounded($second,$out).GetAwaiter().GetResult();Assert-Installer ($a -and -not $b -and $out.Length -le 65536) 'actual worker stdout stderr cumulative cap'}finally{$first.Dispose();$second.Dispose();$out.Dispose()}
  $environmentBranch=$workerAst.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($installerProbe)') -and $n.Extent.Text.Contains('$start.Environment.Clear()')},$true)
  if($IsWindows){
   $start=[Diagnostics.ProcessStartInfo]::new();$start.Environment['LLAMA_MODEL']='synthetic';$start.Environment['HTTPS_PROXY']='synthetic';$installerProbe=$true;$operationRoot=Join-Path $Root 'environment-probe'
   . ([scriptblock]::Create($environmentBranch.Extent.Text))
   Assert-Installer (-not $start.Environment.ContainsKey('LLAMA_MODEL') -and -not $start.Environment.ContainsKey('HTTPS_PROXY') -and $start.Environment['APPDATA'] -eq $start.WorkingDirectory -and $start.Environment['PROGRAMDATA'] -eq $start.WorkingDirectory -and @(Get-ChildItem $start.WorkingDirectory).Count -eq 0) 'actual Windows worker rebuilds private config environment'
  }
  $ownerGuard=$workerAst.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains("throw 'LLAMA_INSTALL_OWNER_CLOSED'")},$true)
  $installerProbe=$true;$stopSignal=[Threading.Tasks.Task]::FromResult(0)
  Assert-Installer (Rejected {. ([scriptblock]::Create($ownerGuard.Extent.Text))} 'LLAMA_INSTALL_OWNER_CLOSED') 'actual worker refuses launch after closed owner pipe'
  $workerRoot=Join-Path $Root ('worker/'+$realCatalog.Item.Tag+'-'+$realCatalog.Item.Sha256.Substring(0,12)+'.operation/probe')
  $null=[IO.Directory]::CreateDirectory($workerRoot)
  $requestPath=Join-Path $workerRoot 'request.json';$operationId=[guid]::NewGuid().ToString('D')
  $expectedNoLaunchCode=if($IsWindows){'LLAMA_INSTALL_PROBE_PACKAGE_FAILED'}else{'LLAMA_INSTALL_PROBE_SETUP_FAILED'}
  [IO.File]::WriteAllText($requestPath,(@{Contract='SqlServerLab.LlamaCppInstallerProbe/1.0';OperationId=$operationId;Invocation='untrusted.exe';Arguments=@('--help');StartTimeoutSeconds=1;LeaseSeconds=1}|ConvertTo-Json -Compress))
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application|Select-Object -First 1).Source)
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $Repo 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),'-RequestPath',$requestPath)){$start.ArgumentList.Add($arg)}
  $worker=[Diagnostics.Process]::Start($start)
  try{
   $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync();$done=$worker.WaitForExit(30000)
   if(-not $done){$worker.Kill($true);$null=$worker.WaitForExit(5000);throw 'FIXTURE_WORKER_TIMEOUT'}
   $null=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()
   $receipt=Get-Content (Join-Path $workerRoot 'receipt.json') -Raw|ConvertFrom-Json
   Assert-Installer ($receipt.OperationId -ceq $operationId -and $receipt.Status -ceq 'FAILED' -and $receipt.Code -ceq $expectedNoLaunchCode -and $null -eq $receipt.ProcessId -and $receipt.ChildTerminationConfirmed) 'real worker rejects unsupported platform or unverified package and confirms no native launch'
  }finally{if(-not $worker.HasExited){$worker.Kill($true);$null=$worker.WaitForExit(5000)};$worker.Dispose()}
  $parentProbePlan=[pscustomobject]@{Operation=(Join-Path $Root ('parent/'+$realCatalog.Item.Tag+'-'+$realCatalog.Item.Sha256.Substring(0,12)+'.operation'))}
  Assert-Installer (Rejected {& $script:realInstallerProbe -Plan $parentProbePlan -OperationId ([guid]::NewGuid().ToString('D'))} $expectedNoLaunchCode) 'real parent accepts confirmed no-launch end and preserves platform-specific failure phase'
  Write-Host "LLAMA INSTALLER: $script:checks PASS; synthetic only, native NOT_EXECUTED"
 } $root $repo
} finally {
 $resolved=[IO.Path]::GetFullPath($root)
 if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-installer-*'){throw 'TEST_CLEANUP_SCOPE'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
 Remove-Module $module -Force
}
