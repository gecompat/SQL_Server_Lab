#Requires -Version 7.5
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$driver=Join-Path $root 'Tests/Integration/Invoke-ToolbeltSsisCurrentTlsAcceptance.ps1'
$prior=Join-Path $root 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1'
$code=[IO.File]::ReadAllText($driver)
$begin=$code.IndexOf(' $source=[IO.File]::ReadAllText($labAcceptance)',[StringComparison]::Ordinal)
$end=$code.IndexOf(' $acceptanceSelf=$PSCommandPath',[StringComparison]::Ordinal)
if($begin -lt 0 -or $end -le $begin){throw 'TOOLBELT_TLS_COMPOSITION_RANGE'}
$labAcceptance=$prior
. ([scriptblock]::Create($code.Substring($begin,$end-$begin)))
$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$errors)
if($errors.Count){throw 'TOOLBELT_TLS_COMPOSED_PARSE'}
$checks=1
foreach($guard in @('SSIS_FRESH_TLS_SQL_AUDIT_REQUIRED','CURRENT_SSIS_BUILD_AND_FRESH_SQL_AUDIT',
 'TLS_PUBLIC_FOREIGN_BASELINE_CHANGED','TLS_PUBLIC_FRESH_REMOVAL_NOT_PROVEN',
 'RECOVERY_RETAIN_OWN_RESOURCES','@($worker.Cases).Count -ne 6',
 '$config.MaximumMinutes -ne 45','Invoke-CurrentAuthenticatedTlsLab.ps1')){
 if(-not $source.Contains($guard,[StringComparison]::Ordinal)){throw ('TOOLBELT_TLS_GUARD_LOST_'+$guard)}
 $checks++
}
if($source.IndexOf("`$result.Phase='CURRENT_SSIS_BUILD_CONSUMER'") -ge $source.IndexOf('Remove-SqlServerLab -RunId')){throw 'TOOLBELT_TLS_CONSUMER_AFTER_REMOVE'};$checks++
$temp=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ContosoTlsAcceptance-'+[guid]::NewGuid().ToString('N'))))
[void](New-Item -ItemType Directory -Path $temp)
try{
 $base=@{RepositoryRoot=$root;ToolbeltRoot=$temp;MaximumMinutes=45}
 $config=Join-Path $temp 'config.json'
 function Reject-Consumer($Value,[string]$Expected,[string]$OverrideHash=''){
  [IO.File]::WriteAllText($config,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $hash=if($OverrideHash){$OverrideHash}else{(Get-FileHash $config).Hash}
  $output=& (Join-Path $PSHOME 'pwsh') -NoProfile -File $driver -ConfigurationPath $config -ExpectedConfigurationSha256 $hash -ValidateOnly 2>&1|Out-String
  if($LASTEXITCODE -eq 0 -or -not $output.Contains($Expected,[StringComparison]::Ordinal)){throw ('TOOLBELT_TLS_EXPECTED_REJECTION_'+$Expected)}
  $script:checks++
 }
 Reject-Consumer $base 'SSIS_FRESH_TLS_CONFIG_CHANGED' ('0'*64)
 $bad=$base.Clone();$bad.RepositoryRoot=$temp;Reject-Consumer $bad 'SSIS_FRESH_TLS_SCOPE'
 $bad=$base.Clone();$bad.MaximumMinutes=120;Reject-Consumer $bad 'SSIS_FRESH_TLS_SCOPE'
 $record=Join-Path $temp 'Modules/toolbelt.tsql.ssis-debug/Tests/Qualification/Current.Build.20261104.json'
 [void](New-Item -ItemType Directory -Path (Split-Path $record -Parent) -Force)
 [IO.File]::WriteAllText($record,'{}')
 Reject-Consumer $base 'SSIS_FRESH_TLS_BUILD_RECORD'
}finally{
 $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 if(-not $temp.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $temp -Leaf) -notlike 'ContosoTlsAcceptance-*'){throw 'TOOLBELT_TLS_TEMP_SCOPE'}
 Remove-Item -LiteralPath $temp -Recurse -Force
}
"TOOLBELT_SSIS_TLS_ACCEPTANCE_CHECKS_PASS $checks checks; no elevation, SQL or VM"
