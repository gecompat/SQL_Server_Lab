# Test-only sources for a rendered, real-HTTP SA password creation acceptance.
# The child server is stopped through its own bound listener after the job ends.
function Get-SaPasswordBrowserServerSource {
    return @'
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if($env:SQL_SERVER_LAB_STATE -cne $c.StateRoot -or $env:SQL_SERVER_LAB_DATA_ROOT -cne $c.DataRoot){throw 'SA_BROWSER_SERVER_ROOT_INVALID'}
$global:saBrowserConfig=$c;$global:saBrowserControl=$null;$global:saBrowserControlHandle=$null
$oldHost=Get-Item Function:Write-Host -ErrorAction SilentlyContinue
$savedHost=if($oldHost){$oldHost.ScriptBlock}else{$null}
function Write-Host {
    param([Parameter(Position=0,ValueFromRemainingArguments)][object[]]$Object,
        [ConsoleColor]$ForegroundColor='Gray',[switch]$NoNewline,[string]$Separator=' ')
    if($Object.Count -eq 1 -and $Object[0] -ceq ('SQL_Server_Lab Workflow UI: http://127.0.0.1:'+$global:saBrowserConfig.ListenerPort+'/')){
        $listener=Get-Variable -Name listener -Scope 1 -ValueOnly -ErrorAction Stop
        if($listener -isnot [Net.HttpListener] -or -not $listener.IsListening -or
            @($listener.Prefixes).Count -ne 1 -or
            @($listener.Prefixes)[0] -cne ('http://127.0.0.1:'+$global:saBrowserConfig.ListenerPort+'/')){throw 'SA_BROWSER_LISTENER_BINDING'}
        $global:saBrowserControl=[powershell]::Create()
        $null=$global:saBrowserControl.AddScript({param($ownedListener,$stopPath)
            $deadline=[datetime]::UtcNow.AddMinutes(12)
            while($ownedListener.IsListening -and -not (Test-Path -LiteralPath $stopPath) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
            if($ownedListener.IsListening){$ownedListener.Stop()}
        }).AddArgument($listener).AddArgument([string]$global:saBrowserConfig.StopPath)
        $global:saBrowserControlHandle=$global:saBrowserControl.BeginInvoke()
        $operatorSession=Get-Variable -Name operatorSession -Scope 1 -ValueOnly -ErrorAction Stop
        [IO.File]::WriteAllText([string]$global:saBrowserConfig.ReadyPath,(@{OperatorFile=$operatorSession.File}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    }
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}
$problem=$null
try{& (Join-Path $c.RepositoryRoot 'Tools/Start-SqlServerLabUi.ps1') -NoBrowser -Port ([string]$c.ListenerPort)}
catch{$problem=$_}
finally{
    $restoreError=$null
    try{if($global:saBrowserControl){try{$null=$global:saBrowserControl.EndInvoke($global:saBrowserControlHandle)}finally{$global:saBrowserControl.Dispose()}}}catch{$restoreError=$_}
    try{if($savedHost){Set-Item Function:Write-Host $savedHost -ErrorAction Stop}else{Remove-Item Function:Write-Host -ErrorAction Stop}}catch{if(-not $restoreError){$restoreError=$_}}
    foreach($name in @('saBrowserConfig','saBrowserControl','saBrowserControlHandle')){Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue}
    if($restoreError){throw 'SA_BROWSER_SERVER_RESTORATION_REQUIRED'}
}
if($problem){throw $problem}
'@
}

function Get-SaPasswordBrowserDriverSource {
    return @'
'use strict';
const fs=require('node:fs');
const c=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {chromium}=require(c.PlaywrightDirectory);
const base='http://127.0.0.1:'+c.ListenerPort;
const assert=value=>{if(!value)throw Error('SA_BROWSER_ASSERTION');};
let stage='INIT';
(async()=>{
 let browser;let actionRequests=0;let foreignRequests=0;
 try{
  stage='LAUNCH';browser=await chromium.launch({executablePath:c.BrowserExecutable,headless:true,timeout:30000});
  const context=await browser.newContext({serviceWorkers:'block'});
  const page=await context.newPage();page.setDefaultTimeout(30000);
  await page.route('**/*',async route=>{
   const request=route.request();const url=new URL(request.url());
   if(url.origin!==base){foreignRequests++;return route.abort();}
   if(url.pathname==='/api/actions'&&request.method()==='POST')actionRequests++;
   return route.continue();
  });
  const locator=JSON.parse(fs.readFileSync(c.ReadyPath,'utf8'));
  const operator=JSON.parse(fs.readFileSync(locator.OperatorFile,'utf8'));
  assert(operator.ContractVersion==='SqlServerLab.UiOperator/1.0'&&operator.ListenerUrl===base+'/'&&operator.StartUrl===base+'/#sql-lab-operator='+operator.Capability);
  stage='LOAD';await page.goto(operator.StartUrl,{waitUntil:'domcontentloaded',timeout:30000});
  await page.locator('#container-version option[value="'+c.Version+'"]') .waitFor({state:'attached',timeout:45000});
  stage='DIALOG';await page.locator('#new-container').click();
  assert(await page.locator('#container-dialog').evaluate(element=>element.open));
  await page.locator('#container-provider').selectOption(c.Provider);
  await page.locator('#container-version').selectOption(c.Version);
  await page.locator('#container-profile').selectOption('compact');
  await page.locator('#container-lab-name').fill(c.LabName);
  await page.locator('#container-password').fill('Ab3');
  await page.locator('#container-password-repeat').fill('Ab3');
  stage='FIRST_VETO';await page.locator('#container-form button[value="default"]').click();
  await page.waitForFunction(()=>!document.querySelector('#container-password-adjustment').hidden);
  assert(actionRequests===0);
  stage='CONFIRMED_SUBMIT';await page.locator('#container-password-minimum').selectOption('3');
  await page.locator('#container-password-adjust-confirm').check();
  const acceptedPromise=page.waitForResponse(response=>new URL(response.url()).pathname==='/api/actions'&&response.request().method()==='POST');
  await page.locator('#container-form button[value="default"]').click();
  const accepted=await acceptedPromise;
  assert(accepted.status()===202);
  const reply=await accepted.json();
  assert(reply.action==='NewContainerLab'&&typeof reply.id==='string'&&/^[a-f0-9]{32}$/.test(reply.id));
  assert(actionRequests===1);
  assert(!(await page.locator('#container-dialog').evaluate(element=>element.open)));
  assert(await page.locator('#container-password').inputValue()==='');
  assert(!(await page.locator('#jobs').innerText()).includes('Ab3'));
  stage='REPORT';fs.writeFileSync(c.ResultPath,JSON.stringify({Contract:'SqlServerLab.SaPasswordRenderedBrowserEvidence/1.0',Status:'PASS',JobId:reply.id,ActionRequests:actionRequests,EarlyRequests:0,ForeignRequestsBlocked:foreignRequests,RenderedDialog:true,ConfirmedMinimum:3}),{flag:'wx'});
 }finally{if(browser)await browser.close();}
})().catch(()=>{process.stderr.write('SA_BROWSER_DRIVER_FAILED:'+stage+'\n');process.exitCode=1;});
'@
}
