# Test-only real-browser transport orchestration. Core/Console defaults and product
# functions remain unchanged. UI background inventory is denied before server work.
function Write-AutoStartBrowserAcceptanceFile {
    param([string]$EvidenceRoot,[string]$Name,[string]$Text)
    if($Name -cnotmatch '^[a-z][a-z0-9-]*\.(?:private\.json|private\.ps1|cjs|log)$'){throw 'AUTOSTART_BROWSER_EVIDENCE_NAME'}
    $root=[IO.Path]::GetFullPath($EvidenceRoot)
    if([IO.Path]::GetFileName($root) -cnotmatch '^port-preview-[a-f0-9]{32}$' -or
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($root)) -cne 'test-runs'){throw 'AUTOSTART_BROWSER_EVIDENCE_SCOPE'}
    $p=$root
    while($p){$item=Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AUTOSTART_BROWSER_EVIDENCE_SCOPE'}
        $p=[IO.Path]::GetDirectoryName($p)}
    $path=Join-Path $root $Name;$bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text)
    if($bytes.Length -gt 131072){throw 'AUTOSTART_BROWSER_EVIDENCE_SIZE'}
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    return [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash;Bytes=$bytes.Length}
}

function Assert-AutoStartBrowserRuntimeMetadata {
    param($Module,[string]$Path)
    $metadata=& $Module {param($Path) Read-LabOwnedHostRecord -Path $Path} $Path
    $names=@('Contract','Node','PlaywrightPackage','Browser','ListenerPort')
    if($metadata -isnot [pscustomobject] -or @($metadata.PSObject.Properties).Count -ne $names.Count -or
        @($metadata.PSObject.Properties.Name|Where-Object{$_ -cnotin $names}).Count -or
        $metadata.Contract -isnot [string] -or $metadata.Contract -cne 'SqlServerLab.AutoStartBrowserRuntime/1.0' -or
        ($metadata.ListenerPort -isnot [int] -and $metadata.ListenerPort -isnot [long]) -or $metadata.ListenerPort -lt 1025 -or $metadata.ListenerPort -gt 65535 -or $metadata.ListenerPort -eq 14336){throw 'AUTOSTART_BROWSER_TOOLS_INVALID'}
    foreach($name in @('Node','PlaywrightPackage','Browser')){
        $b=$metadata.$name
        if($b -isnot [pscustomobject] -or @($b.PSObject.Properties).Count -ne 3 -or
            @($b.PSObject.Properties.Name|Where-Object{$_ -cnotin @('Path','Sha256','Bytes')}).Count -or
            $b.Path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($b.Path) -or
            $b.Sha256 -isnot [string] -or $b.Sha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or
            $b.Bytes -isnot [int] -and $b.Bytes -isnot [long]){throw 'AUTOSTART_BROWSER_TOOLS_INVALID'}
        & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $b.Path
        $item=Get-Item -LiteralPath $b.Path -Force -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -ne $b.Bytes -or (Get-FileHash -LiteralPath $b.Path).Hash -ine $b.Sha256){throw 'AUTOSTART_BROWSER_TOOLS_DRIFT'}
    }
    if([IO.Path]::GetFileName($metadata.Node.Path) -cne 'node.exe' -or
        [IO.Path]::GetFileName($metadata.PlaywrightPackage.Path) -cne 'package.json' -or
        [IO.Path]::GetFileName($metadata.Browser.Path) -cnotin @('msedge.exe','chrome.exe')){throw 'AUTOSTART_BROWSER_TOOLS_INVALID'}
    $package=Get-Content -LiteralPath $metadata.PlaywrightPackage.Path -Raw|ConvertFrom-Json
    if($package.name -isnot [string] -or $package.license -isnot [string] -or $package.name -cne 'playwright' -or $package.license -cne 'Apache-2.0'){throw 'AUTOSTART_BROWSER_DEPENDENCY_INVALID'}
    return $metadata
}

function New-AutoStartBrowserServerStartInfo {
    param([string]$PowerShell,[string]$Script,[string]$Config,$Scope)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$PowerShell
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-File',$Script,'-ConfigPath',$Config)){$start.ArgumentList.Add($arg)}
    # Both process variables are needed: State discovery otherwise prefers legacy.
    $start.Environment['SQL_SERVER_LAB_DATA_ROOT']=$Scope.DataRoot
    $start.Environment['SQL_SERVER_LAB_STATE']=$Scope.StateRoot
    return $start
}

function Stop-AutoStartBrowserOwnedProcess {
    param($Process,[string]$ExpectedInvocation,[datetime]$ExpectedStartTime)
    if(-not $Process){return}
    if(-not $Process.HasExited){
        if($Process.StartTime.ToUniversalTime() -ne $ExpectedStartTime -or
            [IO.Path]::GetFullPath($Process.MainModule.FileName) -ine [IO.Path]::GetFullPath($ExpectedInvocation)){throw 'AUTOSTART_BROWSER_PROCESS_CUSTODY'}
        # Only this actual returned handle/tree; never enumerate foreign processes.
        $Process.Kill($true)
        if(-not $Process.WaitForExit(10000)){throw 'AUTOSTART_BROWSER_PROCESS_RETAINED'}
    }
}

function New-AutoStartBrowserPipeCapture {
    param($Process)
    $pipes=@($Process.StandardOutput.BaseStream,$Process.StandardError.BaseStream)
    $buffers=@([byte[]]::new(4096),[byte[]]::new(4096))
    [pscustomobject]@{Pipes=$pipes;Buffers=$buffers;Tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096));
        Streams=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());Done=@($false,$false);Total=0}
}

function Read-AutoStartBrowserPipeCapture {
    param($Capture)
    for($i=0;$i -lt 2;$i++){
        if(-not $Capture.Done[$i] -and $Capture.Tasks[$i].IsCompleted){
            $n=$Capture.Tasks[$i].GetAwaiter().GetResult()
            if($n -eq 0){$Capture.Done[$i]=$true;continue}
            $Capture.Total+=$n
            if($Capture.Total -gt 65536){throw 'AUTOSTART_BROWSER_OUTPUT_LIMIT'}
            $Capture.Streams[$i].Write($Capture.Buffers[$i],0,$n)
            $Capture.Tasks[$i]=$Capture.Pipes[$i].ReadAsync($Capture.Buffers[$i],0,4096)
        }
    }
}

function Get-AutoStartBrowserServerSource {
    # Kept as a single executed child source; fixtures extract this exact source.
    return @'
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$module=Import-Module (Join-Path $c.RepositoryRoot SqlServerLab.psd1) -PassThru
. (Join-Path $c.RepositoryRoot Tests/Common/ContainerPortPreviewAcceptance.ps1)
. (Join-Path $c.RepositoryRoot Tests/Common/ContainerAutoStartPreviewAcceptance.ps1)
. (Join-Path $c.RepositoryRoot Tests/Common/ContainerAutoStartPreviewBrowserAcceptance.ps1)
$null=Write-AutoStartBrowserAcceptanceFile $c.EvidenceRoot 'browser-phase-loaded.private.json' '{"Phase":"LOADED"}'
$scope=$c.Scope
$resolution=@(& (Join-Path $c.RepositoryRoot Tools/Initialize-SqlServerLabHostTools.ps1) -Name $c.Provider)[0]
if(-not $resolution.Available){throw 'AUTOSTART_BROWSER_TOOL_UNAVAILABLE'}
# Policy, ACL, immutable origin, stored pin and registered metadata must agree
# BEFORE HttpListener starts. Process environment is a locator, never authority.
& $module {
 param($c,$resolution)
 if($env:SQL_SERVER_LAB_STATE -cne $c.Scope.StateRoot -or $env:SQL_SERVER_LAB_DATA_ROOT -cne $c.Scope.DataRoot){throw 'AUTOSTART_BROWSER_ROOT'}
 $parent=Get-LabOwnedHostPolicy -StateRoot $c.Scope.DataRoot -Required
 $run=Get-LabOwnedHostRunPolicy -StateRoot $c.Scope.StateRoot -RunId $c.RunId
 if($parent.ParentOperationId -cne $c.Scope.ParentOperationId -or $run.ParentOperationId -cne $c.Scope.ParentOperationId -or
    (Get-FileHash (Join-Path $c.Scope.DataRoot owned-host-policy.json)).Hash -cne $c.Scope.ParentPolicyHash -or
    (Get-FileHash (Join-Path $c.Scope.StateRoot owned-host-policy.json)).Hash -cne $c.Scope.StatePolicyHash -or
    (Get-LabDataRootDefault) -cne $c.Scope.DataRoot -or (Get-LabStateRoot) -cne $c.Scope.StateRoot){throw 'AUTOSTART_BROWSER_ROOT'}
 $pin=@($run.RuntimePins|Where-Object Provider -ceq $c.Provider)
 if($pin.Count -ne 1 -or $pin[0].Invocation -cne $resolution.Invocation){throw 'AUTOSTART_BROWSER_PIN'}
 $targets=@(Get-LabContainerPortConsoleTargets -DataRoot $c.Scope.DataRoot)
 if($targets.Count -ne 1 -or $targets[0].RunId -cne $c.RunId -or $targets[0].InstanceId -cne 'primary' -or
    $targets[0].Provider -cne $c.Provider -or $targets[0].StateRoot -cne $c.Scope.StateRoot){throw 'AUTOSTART_BROWSER_TARGET'}
} $c $resolution
$null=Write-AutoStartBrowserAcceptanceFile $c.EvidenceRoot 'browser-phase-bound.private.json' '{"Phase":"BOUND"}'
$restore=& $module {
 param($c,$writer,$files,$writePrivate)
 $script:browserAcceptanceConfig=$c;$script:browserAcceptanceWriter=$writer;$script:browserAcceptanceFiles=$files;$script:browserAcceptanceWrite=$writePrivate
 $script:browserAcceptancePublicCount=0;$script:browserAcceptanceNativeCount=0;$script:browserAcceptanceRequestCount=0
 $script:browserAcceptancePlans=[Collections.Generic.List[object]]::new()
 $saved=@{};foreach($name in @('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Invoke-LabContainerAutoStartPreviewHttpRequest')){$saved[$name]=(Get-Item ('Function:'+ $name)).ScriptBlock}
 $script:browserAcceptanceOriginalPublic=$saved['Get-SqlServerLabReconcilePlan'];$script:browserAcceptanceOriginalNative=$saved['Invoke-LabOwnedHostNativeProcess'];$script:browserAcceptanceOriginalHttp=$saved['Invoke-LabContainerAutoStartPreviewHttpRequest']
 function script:Get-SqlServerLabReconcilePlan {
  param($RunId,$InstanceId,$StateRoot,[switch]$ContainerAutoStartPreview,[string]$AutoStart)
  $c=$script:browserAcceptanceConfig
  if($RunId -cne $c.RunId -or $InstanceId -cne 'primary' -or $StateRoot -cne $c.Scope.StateRoot -or -not $ContainerAutoStartPreview){throw 'AUTOSTART_BROWSER_PUBLIC_SCOPE'}
  $script:browserAcceptancePublicCount++
  $plan=& $script:browserAcceptanceOriginalPublic @PSBoundParameters
  $null=& $script:browserAcceptanceWriter -Plan $plan -Provider $c.Provider -Ordinal $script:browserAcceptancePublicCount -EvidenceRoot $c.EvidenceRoot -RepositoryRoot $c.RepositoryRoot -Scope $c.Scope
  if($plan.Status -cne 'PLAN_ONLY' -or $plan.Actual.AutoStart -cne 'OFF'){throw 'AUTOSTART_BROWSER_MEASURED_OFF_REQUIRED'}
  $script:browserAcceptancePlans.Add($plan)
  return $plan
 }
 function script:Invoke-LabOwnedHostNativeProcess {param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
  $script:browserAcceptanceNativeCount++;& $script:browserAcceptanceOriginalNative @PSBoundParameters
 }
 function script:Invoke-LabContainerAutoStartPreviewHttpRequest {
  param($Request,[int]$ListenerPort)
  $c=$script:browserAcceptanceConfig;$script:browserAcceptanceRequestCount++
  $before=@(& $script:browserAcceptanceFiles -DataRoot $c.Scope.DataRoot)
  $public=$script:browserAcceptancePublicCount;$native=$script:browserAcceptanceNativeCount;$status='REJECTED';$response=$null;$primary=$null
  try{$response=& $script:browserAcceptanceOriginalHttp @PSBoundParameters;$status='ACCEPTED'}catch{$primary=$_}
  $after=@(& $script:browserAcceptanceFiles -DataRoot $c.Scope.DataRoot)
  $equal=($before|ConvertTo-Json -Depth 5 -Compress) -ceq ($after|ConvertTo-Json -Depth 5 -Compress)
  $delta=$script:browserAcceptancePublicCount-$public;$reads=$script:browserAcceptanceNativeCount-$native
  $repeat=$null;$different=$null
  if($script:browserAcceptancePlans.Count -eq 3){$repeat=$script:browserAcceptancePlans[0].ObservationKey -ceq $script:browserAcceptancePlans[2].ObservationKey;$different=$script:browserAcceptancePlans[0].ObservationKey -cne $script:browserAcceptancePlans[1].ObservationKey}
  $record=[ordered]@{Contract='SqlServerLab.AutoStartBrowserRequestEvidence/1.0';Ordinal=$script:browserAcceptanceRequestCount;Status=$status;PublicCalls=$delta;OwnershipNativeReads=$reads;StateBytesEqual=$equal;RepeatContentEqual=$repeat;DesiredOnlyDifference=$different}
  $null=& $script:browserAcceptanceWrite -EvidenceRoot $c.EvidenceRoot -Name ('browser-request-{0:D2}.private.json' -f $script:browserAcceptanceRequestCount) -Text ($record|ConvertTo-Json -Compress)
  if(-not $equal -or $delta -gt 1 -or ($delta -eq 0 -and $reads -ne 0)){throw 'AUTOSTART_BROWSER_REQUEST_EFFECT'}
  if($primary){throw $primary};return $response
 }
 return $saved
} $c ${function:Write-AutoStartPreviewAcceptanceObservation} ${function:Get-PortPreviewAcceptanceFileBinding} ${function:Write-AutoStartBrowserAcceptanceFile}
$hostFunction=Get-Item Function:Write-Host -ErrorAction SilentlyContinue
$savedHost=if($hostFunction){$hostFunction.ScriptBlock}else{$null}
$global:browserServerConfig=$c;$global:browserServerControl=$null;$global:browserServerControlHandle=$null
function Write-Host {
 param([Parameter(Position=0,ValueFromRemainingArguments)][object[]]$Object,[ConsoleColor]$ForegroundColor='Gray',[switch]$NoNewline,[string]$Separator=' ')
 if($Object.Count -eq 1 -and $Object[0] -ceq ('SQL_Server_Lab Workflow UI: http://127.0.0.1:'+$global:browserServerConfig.ListenerPort+'/')){
  $listener=Get-Variable -Name listener -Scope 1 -ValueOnly -ErrorAction Stop
  if($listener -isnot [Net.HttpListener] -or -not $listener.IsListening -or @($listener.Prefixes).Count -ne 1 -or
     @($listener.Prefixes)[0] -cne ('http://127.0.0.1:'+$global:browserServerConfig.ListenerPort+'/')){throw 'AUTOSTART_BROWSER_LISTENER_BINDING'}
  $null=Write-AutoStartBrowserAcceptanceFile $global:browserServerConfig.EvidenceRoot 'browser-listener-ready.private.json' '{"ListenerStarted":true}'
  $global:browserServerControl=[powershell]::Create()
  $null=$global:browserServerControl.AddScript({param($listener,$stop)
   $deadline=[datetime]::UtcNow.AddMinutes(4)
   while($listener.IsListening -and -not (Test-Path -LiteralPath $stop) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
   if($listener.IsListening){$listener.Stop()}
  }).AddArgument($listener).AddArgument((Join-Path $global:browserServerConfig.EvidenceRoot 'browser-stop.private.json'))
  $global:browserServerControlHandle=$global:browserServerControl.BeginInvoke()
 }
 Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}
$serverPrimary=$null
$null=Write-AutoStartBrowserAcceptanceFile $c.EvidenceRoot 'browser-phase-ui-start.private.json' '{"Phase":"UI_START"}'
try{& (Join-Path $c.RepositoryRoot Tools/Start-SqlServerLabUi.ps1) -NoBrowser -Port ([string]$c.ListenerPort)}
catch{$serverPrimary=$_}
finally{
 $restorationErrors=[Collections.Generic.List[object]]::new()
 try{& $module {param($saved)
   $errors=[Collections.Generic.List[object]]::new()
   foreach($name in $saved.Keys){try{Set-Item ('Function:script:'+$name) $saved[$name] -ErrorAction Stop}catch{$errors.Add($_)}}
   foreach($v in @(Get-Variable -Scope Script -Name 'browserAcceptance*'|ForEach-Object Name)){try{Remove-Variable -Scope Script -Name $v -ErrorAction Stop}catch{$errors.Add($_)}}
   if($errors.Count){throw 'AUTOSTART_BROWSER_RESTORATION_REQUIRED'}
  } $restore}catch{$restorationErrors.Add($_)}
  try{if($global:browserServerControl){try{$null=$global:browserServerControl.EndInvoke($global:browserServerControlHandle)}finally{$global:browserServerControl.Dispose()}}}catch{$restorationErrors.Add($_)}
 try{if($savedHost){Set-Item Function:Write-Host $savedHost -ErrorAction Stop}else{Remove-Item Function:Write-Host -ErrorAction Stop}}catch{$restorationErrors.Add($_)}
  foreach($name in @('browserServerConfig','browserServerControl','browserServerControlHandle')){try{Remove-Variable -Name $name -Scope Global -ErrorAction Stop}catch{$restorationErrors.Add($_)}}
 try{Remove-Module $module -Force -ErrorAction Stop}catch{$restorationErrors.Add($_)}
 if(-not $restorationErrors.Count){$null=Write-AutoStartBrowserAcceptanceFile $c.EvidenceRoot 'browser-functions-restored.private.json' '{"OriginalFunctionsRestored":true}'}
}
if($serverPrimary){if($restorationErrors.Count){$serverPrimary.Exception.Data['BrowserRestorationFailed']=$true};throw $serverPrimary}
if($restorationErrors.Count){throw 'AUTOSTART_BROWSER_RESTORATION_REQUIRED'}
'@
}

function Get-AutoStartBrowserDriverSource {
    return @'
'use strict';
const fs=require('node:fs');
const c=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {chromium}=require(c.PlaywrightDirectory);
const base='http://127.0.0.1:'+c.ListenerPort;
const assert=(v)=>{if(!v)throw Error('AUTOSTART_BROWSER_ASSERTION');};
let stage='INIT';
(async()=>{
 let browser;let blocked=0;let previewRequests=0;let readRequests=0;let delayed=false;let completeDelayed;
 const delayedComplete=new Promise(resolve=>{completeDelayed=resolve;});
 try{
   stage='LAUNCH';browser=await chromium.launch({executablePath:c.BrowserExecutable,headless:true,timeout:30000});
  const context=await browser.newContext({serviceWorkers:'block'});
  const page=await context.newPage();page.setDefaultTimeout(15000);
  await page.route('**/*',async route=>{
   const request=route.request();const u=new URL(request.url());
   if(u.origin!==base){blocked++;return route.abort();}
   if(u.pathname==='/api/container-autostart-preview'){
    const p=JSON.parse(request.postData()||'{}');
    if(p.Action==='Preview')previewRequests++;else if(p.Action==='Read')readRequests++;
    if(p.Action==='Preview' && !delayed){delayed=true;const response=await route.fetch();await page.locator('#autostart-preview-close').click();await route.fulfill({response});completeDelayed();return;}
    return route.continue();
   }
   const staticPath=u.pathname==='/' || /^\/[a-z][a-z0-9-]*\.(?:js|css|svg|png|ico)$/.test(u.pathname);
   if(staticPath && request.method()==='GET' && !u.search)return route.continue();
   // No unrelated inventory/jobs/catalog work is sent to the real server.
   blocked++;return route.abort();
  });
   stage='LOAD_PAGE';await page.goto(base+'/',{waitUntil:'domcontentloaded',timeout:30000});
  const open=page.locator('#autostart-preview-open');const dialog=page.locator('#autostart-preview-dialog');
  const policy=page.locator('#autostart-preview-policy');const target=page.locator('#autostart-preview-target');
  const plan=page.locator('#autostart-preview-plan');const result=page.locator('#autostart-preview-result');
   stage='READ_TARGETS';await open.click();await target.locator('option').first().waitFor({state:'attached'});
  assert(await target.locator('option').count()===1);
   stage='EARLY_VETO';await plan.click();assert(previewRequests===0);
  await policy.selectOption('on');await policy.dispatchEvent('input');await target.dispatchEvent('change');
  assert(previewRequests===0);await page.locator('#autostart-preview-close').click();assert(previewRequests===0);
   stage='LATE_VETO';await open.click();await target.locator('option').first().waitFor({state:'attached'});await policy.selectOption('on');await policy.dispatchEvent('input');
  await plan.click();await page.waitForFunction(()=>!document.querySelector('#autostart-preview-dialog').open);
  await delayedComplete;assert(await result.textContent()==='');
   stage='OFF_PREVIEW';await open.click();await target.locator('option').first().waitFor({state:'attached'});await policy.selectOption('off');await policy.dispatchEvent('input');await plan.click();
  await page.waitForFunction(()=>document.querySelector('#autostart-preview-result').textContent.includes('SAME_POLICY'));
  assert((await result.textContent()).includes('CanApply=false'));
   stage='ON_PREVIEW';await policy.selectOption('on');await policy.dispatchEvent('input');await plan.click();
  await page.waitForFunction(()=>document.querySelector('#autostart-preview-result').textContent.includes('DIFFERENT_POLICY'));
  const text=await result.textContent();assert(text.includes('Mounts:')&&text.includes('NOT_CHECKED')&&!text.includes(c.RunId));
  assert(previewRequests===3);
  // Raw invalid requests use the genuine listener; none should call Public.
   stage='INVALID_REQUESTS';for(const body of ['{"Action":["Read"]}','{"Action":"Read","Action":"Read"}','{"Action":"Read","Unknown":true}',
   '{"Action":"Preview","RunId":"00000000-0000-0000-0000-000000000000","InstanceId":"primary","AutoStart":"on"}',
   JSON.stringify({Action:'Preview',RunId:c.RunId,InstanceId:'primary',AutoStart:'invalid'}),
   '{"Action":"Read","StateRoot":"FORGED_AUTHORITY"}','x'.repeat(2049)]){
   const response=await context.request.post(base+'/api/container-autostart-preview',{headers:{Origin:base,'Content-Type':'application/json'},data:body});assert(response.status()===400);
  }
  const invalidMethod=await context.request.get(base+'/api/container-autostart-preview',{headers:{Origin:base}});assert(invalidMethod.status()>=400);
  const badOrigin=await context.request.post(base+'/api/container-autostart-preview',{headers:{Origin:'http://127.0.0.1:1','Content-Type':'application/json'},data:'{"Action":"Read"}'});assert(badOrigin.status()===400);
   stage='WRITE_REPORT';const report={Contract:'SqlServerLab.AutoStartRenderedBrowserEvidence/1.0',Status:'PASS',PublicPreviewRequests:3,MetadataRequests:readRequests,EarlyCancelInvalidPreviewRequests:0,LateRealResponseDisplayVeto:true,RenderedCategories:true,DeniedUnrelatedRequests:blocked,PreviewResponsesStubbed:false};
  fs.writeFileSync(c.ResultPath,JSON.stringify(report),{flag:'wx'});
 }finally{if(browser)await browser.close();}
})().catch(()=>{process.stderr.write('AUTOSTART_BROWSER_DRIVER_FAILED:'+stage+'\n');process.exitCode=1;});
'@
}

function Assert-AutoStartBrowserRenderedRecord {
    param($Record)
    $fields=@('Contract','Status','PublicPreviewRequests','MetadataRequests','EarlyCancelInvalidPreviewRequests','LateRealResponseDisplayVeto','RenderedCategories','DeniedUnrelatedRequests','PreviewResponsesStubbed')
    if($Record -isnot [pscustomobject] -or @($Record.PSObject.Properties).Count -ne $fields.Count -or
        @($Record.PSObject.Properties.Name|Where-Object{$_ -cnotin $fields}).Count -or
        $Record.Contract -isnot [string] -or $Record.Contract -cne 'SqlServerLab.AutoStartRenderedBrowserEvidence/1.0' -or
        $Record.Status -isnot [string] -or $Record.Status -cne 'PASS'){throw 'AUTOSTART_BROWSER_RENDERED_RECORD'}
    foreach($name in @('PublicPreviewRequests','MetadataRequests','EarlyCancelInvalidPreviewRequests','DeniedUnrelatedRequests')){
        if($Record.$name -isnot [int] -and $Record.$name -isnot [long] -or $Record.$name -lt 0 -or $Record.$name -gt 4096){throw 'AUTOSTART_BROWSER_RENDERED_RECORD'}
    }
    foreach($name in @('LateRealResponseDisplayVeto','RenderedCategories','PreviewResponsesStubbed')){if($Record.$name -isnot [bool]){throw 'AUTOSTART_BROWSER_RENDERED_RECORD'}}
    if($Record.PublicPreviewRequests -ne 3 -or $Record.EarlyCancelInvalidPreviewRequests -ne 0 -or
        $Record.MetadataRequests -ne 3 -or -not $Record.LateRealResponseDisplayVeto -or -not $Record.RenderedCategories -or
        $Record.PreviewResponsesStubbed -or $Record.DeniedUnrelatedRequests -lt 1){throw 'AUTOSTART_BROWSER_RENDERED_RECORD'}
}

function Invoke-AutoStartBrowserAcceptanceObservations {
    param($Module,$Scope,[string]$RunId,[string]$Provider,[string]$RepositoryRoot,[string]$EvidenceRoot,[string]$RuntimeMetadataPath)
    $runtime=Assert-AutoStartBrowserRuntimeMetadata -Module $Module -Path $RuntimeMetadataPath
    & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $EvidenceRoot
    $expected=[IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.artifacts/test-runs'))
    $actual=[IO.Path]::GetFullPath($EvidenceRoot)
    $runtimeRoot=[IO.Path]::GetFullPath($Scope.DataRoot).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($actual) -ine $expected -or $actual -ieq $runtimeRoot -or
        $actual.StartsWith($runtimeRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'AUTOSTART_BROWSER_EVIDENCE_SCOPE'}
    $before=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    $config=[ordered]@{RepositoryRoot=$RepositoryRoot;Scope=$Scope;RunId=$RunId;Provider=$Provider;EvidenceRoot=$EvidenceRoot;
        ListenerPort=$runtime.ListenerPort;BrowserExecutable=$runtime.Browser.Path;PlaywrightDirectory=[IO.Path]::GetDirectoryName($runtime.PlaywrightPackage.Path);ResultPath=(Join-Path $EvidenceRoot browser-rendered-result.private.json)}
    $configFile=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-config.private.json' ($config|ConvertTo-Json -Depth 10)
    $serverScript=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-server.private.ps1' (Get-AutoStartBrowserServerSource)
    $driverScript=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-driver.cjs' (Get-AutoStartBrowserDriverSource)
    $server=$null;$driver=$null;$serverCapture=$null;$driverCapture=$null;$serverTime=[datetime]::MinValue;$driverTime=[datetime]::MinValue;$primary=$null;$cleanupErrors=[Collections.Generic.List[object]]::new()
    $result=$null;$serverExit=-1
    try{
        $server=[Diagnostics.Process]::new();$server.StartInfo=New-AutoStartBrowserServerStartInfo (Get-Process -Id $PID).Path $serverScript.Path $configFile.Path $Scope
        if(-not $server.Start()){throw 'AUTOSTART_BROWSER_SERVER_START'};$serverTime=$server.StartTime.ToUniversalTime()
        $null=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-server-custody.private.json' ([ordered]@{ProcessId=$server.Id;Invocation=$server.StartInfo.FileName;StartedUtc=$serverTime.ToString('o');Role='OWN_UI_SERVER'}|ConvertTo-Json -Compress)
        $serverCapture=New-AutoStartBrowserPipeCapture $server
        # The marker is written only AFTER the actual bound listener.Start().
        # No socket probe can accidentally accept a foreign listener on this port.
        $ready=$false;$deadline=[datetime]::UtcNow.AddSeconds(30)
        while(-not $ready -and [datetime]::UtcNow -lt $deadline -and -not $server.HasExited){
            Read-AutoStartBrowserPipeCapture $serverCapture
            $ready=Test-Path -LiteralPath (Join-Path $EvidenceRoot browser-listener-ready.private.json)
            if(-not $ready){Start-Sleep -Milliseconds 100}
        }
        if(-not $ready){throw 'AUTOSTART_BROWSER_SERVER_UNAVAILABLE'}
        $afterStartup=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
        $startupEqual=($before|ConvertTo-Json -Depth 5 -Compress) -ceq ($afterStartup|ConvertTo-Json -Depth 5 -Compress)
        $null=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-startup-state.private.json' ([ordered]@{StateBytesEqual=$startupEqual;PreviewNotStarted=$true}|ConvertTo-Json -Compress)
        if(-not $startupEqual){throw 'AUTOSTART_BROWSER_STARTUP_STATE_WRITE_UNEXPECTED'}
        $driver=[Diagnostics.Process]::new();$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$runtime.Node.Path
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.ArgumentList.Add($driverScript.Path);$start.ArgumentList.Add($configFile.Path);$driver.StartInfo=$start
        if(-not $driver.Start()){throw 'AUTOSTART_BROWSER_DRIVER_START'};$driverTime=$driver.StartTime.ToUniversalTime()
        $null=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-driver-custody.private.json' ([ordered]@{ProcessId=$driver.Id;Invocation=$driver.StartInfo.FileName;StartedUtc=$driverTime.ToString('o');Role='OWN_BROWSER_DRIVER'}|ConvertTo-Json -Compress)
        $driverCapture=New-AutoStartBrowserPipeCapture $driver;$deadline=[datetime]::UtcNow.AddSeconds(120)
        while(-not $driver.HasExited -and [datetime]::UtcNow -lt $deadline){Read-AutoStartBrowserPipeCapture $driverCapture;Read-AutoStartBrowserPipeCapture $serverCapture;Start-Sleep -Milliseconds 20}
        if(-not $driver.HasExited){throw 'AUTOSTART_BROWSER_DRIVER_TIMEOUT'}
        if($driver.ExitCode -ne 0){throw 'AUTOSTART_BROWSER_DRIVER_FAILED'}
        $rendered=& $Module {param($Path)Read-LabOwnedHostRecord -Path $Path} $config.ResultPath
        Assert-AutoStartBrowserRenderedRecord $rendered
        $requests=@(Get-ChildItem -LiteralPath $EvidenceRoot -Filter 'browser-request-*.private.json'|Sort-Object Name|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json})
        if(@($requests|Where-Object{-not $_.StateBytesEqual -or $_.PublicCalls -gt 1 -or ($_.PublicCalls -eq 0 -and $_.OwnershipNativeReads)}).Count -or
            ($requests|Measure-Object PublicCalls -Sum).Sum -ne 3 -or @($requests|Where-Object RepeatContentEqual -eq $true).Count -eq 0 -or
            @($requests|Where-Object DesiredOnlyDifference -eq $true).Count -eq 0){throw 'AUTOSTART_BROWSER_REQUEST_RECORDS'}
        $categories=@(Get-ChildItem -LiteralPath $EvidenceRoot -Filter 'autostart-preview-*.private.json')
        if($categories.Count -ne 3){throw 'AUTOSTART_BROWSER_CATEGORY_COUNT'}
        $result=[pscustomobject]@{RenderedBrowser='PASSED';HttpNetworkTransport='PASSED';PublicPreviewCalls=3;EarlyCancelInvalidPublicCalls=0;
            OwnershipNativeReads=($requests|Measure-Object OwnershipNativeReads -Sum).Sum;StateBytesEqual=$true;RepeatObservedContentEqual=$true;
            DesiredOnlyDifference=$true;LateRealResponseDisplayVeto=$true;CoreFiveCallRepeat='NOT_EXECUTED';ConsoleNativeRepeat='NOT_EXECUTED';
            StartupStateBytesEqual=$startupEqual;StartupStateWrites='MEASURED_SEPARATELY';WholeServerNoWriteClaim=$false;PreviewResponsesStubbed=$false;HostLogin='NOT_CHECKED';Endpoint='NOT_CHECKED';SqlPreview='NOT_CHECKED';Apply='NOT_IMPLEMENTED'}
    }catch{$primary=$_}
    finally{
        try{if($server -and -not $server.HasExited){$null=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot 'browser-stop.private.json' '{"StopOwnedListener":true}';
            $deadline=[datetime]::UtcNow.AddSeconds(10);while(-not $server.HasExited -and [datetime]::UtcNow -lt $deadline){Read-AutoStartBrowserPipeCapture $serverCapture;Start-Sleep -Milliseconds 20}
            if(-not $server.HasExited){throw 'AUTOSTART_BROWSER_SERVER_STOP_FAILED'}
        }}catch{$cleanupErrors.Add($_)}
        foreach($entry in @(@($driver,$runtime.Node.Path,$driverTime),@($server,(Get-Process -Id $PID).Path,$serverTime))){
            try{Stop-AutoStartBrowserOwnedProcess -Process $entry[0] -ExpectedInvocation $entry[1] -ExpectedStartTime $entry[2]}catch{$cleanupErrors.Add($_)}
        }
        foreach($entry in @(@($driver,'browser-driver-output.log',$driverCapture),@($server,'browser-server-output.log',$serverCapture))){
            try{if($entry[0] -and $entry[2]){$capture=$entry[2];$deadline=[datetime]::UtcNow.AddSeconds(5)
                while(@($capture.Done|Where-Object{-not $_}).Count -and [datetime]::UtcNow -lt $deadline){Read-AutoStartBrowserPipeCapture $capture;Start-Sleep -Milliseconds 10}
                if(@($capture.Done|Where-Object{-not $_}).Count){throw 'AUTOSTART_BROWSER_OUTPUT_UNCLOSED'}
                $text=[Text.UTF8Encoding]::new($false,$true).GetString($capture.Streams[0].ToArray())+"`n"+[Text.UTF8Encoding]::new($false,$true).GetString($capture.Streams[1].ToArray())
                $null=Write-AutoStartBrowserAcceptanceFile $EvidenceRoot $entry[1] $text
                foreach($stream in $capture.Streams){$stream.Dispose()}
            };if($entry[0]){if($entry[1] -ceq 'browser-server-output.log'){$serverExit=$entry[0].ExitCode};$entry[0].Dispose()}}catch{$cleanupErrors.Add($_)}
        }
    }
    if($primary){
        # A failed started driver cannot attest that every browser child closed.
        # Even if its own PID exited, retain runtime custody for exact recovery.
        if($cleanupErrors.Count -or $driverTime -ne [datetime]::MinValue){$primary.Exception.Data['AutoStartBrowserProcessRecoveryRequired']=$true}
        throw $primary
    }
    if($cleanupErrors.Count){throw 'AUTOSTART_BROWSER_PROCESS_RECOVERY_REQUIRED'}
    $restored=Get-Content -LiteralPath (Join-Path $EvidenceRoot browser-functions-restored.private.json) -Raw|ConvertFrom-Json
    if($restored.OriginalFunctionsRestored -ne $true -or $serverExit -ne 0){throw 'AUTOSTART_BROWSER_RESTORATION_REQUIRED'}
    $after=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'AUTOSTART_BROWSER_STATE_WRITE'}
    return $result
}
