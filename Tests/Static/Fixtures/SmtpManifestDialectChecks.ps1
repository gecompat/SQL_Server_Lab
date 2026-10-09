param([switch]$Standalone)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$rows=[Collections.Generic.List[object]]::new();$m=$null
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-smtp-dialect-'+[guid]::NewGuid().ToString('N'))
try{
$null=New-Item -ItemType Directory -Path $temp
$m=New-Module -ArgumentList $root -ScriptBlock {
param($root)
$script:SchemasPath=Join-Path $root 'Schemas'
$script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json -Depth 100
foreach($p in @('Private/SmtpTestServiceConfig.ps1','Private/SmtpTestServiceManifestAdmission.ps1','Private/ManifestParser.ps1','Private/ManifestBuilder.ps1','Private/VersionCatalog.ps1','Public/New-SqlServerLabManifest.ps1')){. (Join-Path $root $p)}
$script:Effects=0
function Resolve-LabSqlServerCollation {$script:Effects++;throw 'SYNTHETIC_DEFAULT_EFFECT'}
function Get-LabManifestEnvironmentSecret {$script:Effects++;throw 'SYNTHETIC_SECRET_EFFECT'}
function New-LabRunState {$script:Effects++;throw 'SYNTHETIC_STATE_EFFECT'}
function Invoke-LabProviderOperation {$script:Effects++;throw 'SYNTHETIC_PROVIDER_EFFECT'}
function Write-LabWarning {}
function Probe {
param($Json,$Route,$Path)
$script:Effects=0;$code='NONE'
try{
switch($Route){
Helper {Assert-LabSmtpManifestAdmission -Json $Json}
Read {Read-LabManifest -Path $Path|Out-Null}
Test {$result=Test-SqlServerLabManifest -Path $Path;if(!$result.IsValid){$code=if($result.Errors.Count -eq 1 -and $result.Errors[0] -cin @('SMTP_TEST_CONFIG_INVALID','SMTP_TEST_SCOPE_UNSUPPORTED','SMTP_TEST_BACKEND_UNADMITTED')){$result.Errors[0]}else{'OTHER'}}}
}
}catch{$code=if($_.Exception.Message -cin @('SMTP_TEST_CONFIG_INVALID','SMTP_TEST_SCOPE_UNSUPPORTED','SMTP_TEST_BACKEND_UNADMITTED')){$_.Exception.Message}else{'OTHER'}}
[pscustomobject]@{Code=$code;Effects=$script:Effects}
}
}
$b='"name":"synthetic","instances":[{"id":"primary","version":"2025"}]'
$cases=@(
@('COMMENT_DUP',('{/*synthetic*/'+$b+',"smtpTestService":{"enabled":true,"enabled":false}}'),'SMTP_TEST_CONFIG_INVALID'),
@('COMMENT_CASE',('{/*synthetic*/'+$b+',"SMTPTESTSERVICE":{"enabled":false}}'),'SMTP_TEST_CONFIG_INVALID'),
@('TRAIL_DUP',('{'+$b+',"smtpTestService":{"enabled":true,"enabled":false},}'),'SMTP_TEST_CONFIG_INVALID'),
@('TRAIL_CASE',('{'+$b+',"SMTPTESTSERVICE":{"enabled":false},}'),'SMTP_TEST_CONFIG_INVALID'),
@('SINGLE_QUOTE',"{'name':'synthetic','instances':[{'id':'primary','version':'2025'}],'SMTPTESTSERVICE':{'enabled':false}}",'SMTP_TEST_CONFIG_INVALID'),
@('UNQUOTED',"{name:'synthetic',instances:[{id:'primary',version:'2025'}],SMTPTESTSERVICE:{enabled:false}}",'SMTP_TEST_CONFIG_INVALID'),
@('CONFIG_COMMENT',('{'+$b+',"smtpTestService":{"enabled":false/*synthetic*/}}'),'SMTP_TEST_CONFIG_INVALID'),
@('NONSMTP_COMMENT',('{/*synthetic*/'+$b+'}'), 'LEGACY'),
@('NONSMTP_SINGLE',"{'name':'synthetic','instances':[{'id':'primary','version':'2025'}]}",'LEGACY')
)
$p=Join-Path $temp 'synthetic.json'
foreach($c in $cases){
if($c.Count -ne 3 -or $c[1] -isnot [string] -or $c[2] -isnot [string]){throw 'VECTOR_SHAPE_INVALID'}
[IO.File]::WriteAllText($p,$c[1]);foreach($route in @('Helper','Read','Test')){$r=&$m {param($j,$route,$p) Probe $j $route $p} $c[1] $route $p;$expected=if($c[2] -ceq 'LEGACY'){if($route -ceq 'Helper'){'NONE'}else{'OTHER'}}else{$c[2]};$rows.Add([pscustomobject]@{Id=$c[0];Route=$route;Expected=$expected;Code=$r.Code;Effects=$r.Effects;Pass=($r.Code -ceq $expected -and $r.Effects -eq 0)})}}
}finally{if($null-ne$m){Remove-Module $m -Force};if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}

if($Standalone) {
    [pscustomobject]@{Schema='SmtpManifestDialectChecks/v1';Passed=@($rows|Where-Object Pass).Count;
        Failed=@($rows|Where-Object {!$_.Pass}).Count;Rows=@($rows);OwnCleanup=$true;NativeOperations=0}
}
else {
    foreach($row in $rows){Add-CheckResult -Name ('SMTP Manifest dialect: '+$row.Id+'/'+$row.Route) -Success $row.Pass}
}