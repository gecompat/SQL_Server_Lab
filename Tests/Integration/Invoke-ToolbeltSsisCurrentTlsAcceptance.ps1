#Requires -Version 7.5
# Fixed current-build SQL consumer inside the existing public Lab acceptance/cleanup envelope.
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ConfigurationPath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedConfigurationSha256,
 [ValidateSet('Preflight','Supervisor','Worker')][string]$Mode='Preflight',
 [datetimeoffset]$DeadlineUtc=[datetimeoffset]::UtcNow.AddMinutes(45),
 [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$labRepositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$configPin=[IO.File]::Open($ConfigurationPath,'Open','Read','Read')
try{
 if($configPin.Length -gt 4194304){throw 'SSIS_FRESH_TLS_CONFIG_TOO_LARGE'}
 $configBytes=[byte[]]::new([int]$configPin.Length);$configPin.ReadExactly($configBytes)
 if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)) -cne $ExpectedConfigurationSha256){throw 'SSIS_FRESH_TLS_CONFIG_CHANGED'}
 $acceptanceConfig=[Text.Encoding]::UTF8.GetString($configBytes)|ConvertFrom-Json -Depth 32 -DateKind String
}finally{$configPin.Dispose()}
$toolbeltRoot=[IO.Path]::GetFullPath($acceptanceConfig.ToolbeltRoot)
if($acceptanceConfig.RepositoryRoot -cne $labRepositoryRoot -or -not [IO.Path]::IsPathRooted($acceptanceConfig.ToolbeltRoot) -or $acceptanceConfig.MaximumMinutes -ne 45 -or $DeadlineUtc -gt [datetimeoffset]::UtcNow.AddMinutes(46)){throw 'SSIS_FRESH_TLS_SCOPE'}
$recordPath=Join-Path $toolbeltRoot 'Modules/toolbelt.tsql.ssis-debug/Tests/Qualification/Current.Build.20261104.json'
if((Get-FileHash $recordPath).Hash -cne '8E17CA520F50E8385E744CF4B6464B97263B1AF17AF4C6B074DC36556F22D60C'){throw 'SSIS_FRESH_TLS_BUILD_RECORD'}
$buildRecord=Get-Content $recordPath -Raw|ConvertFrom-Json
foreach($entry in $buildRecord.source_sha256.psobject.Properties){
 $path=[IO.Path]::GetFullPath((Join-Path $toolbeltRoot $entry.Name))
 if(-not $path.StartsWith($toolbeltRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    (Get-FileHash $path).Hash.ToLowerInvariant() -cne ([string]$entry.Value).ToLowerInvariant()){throw 'SSIS_FRESH_TLS_APPROVED_SOURCE_CHANGED'}
}
$dll=Join-Path $acceptanceConfig.SsisContext.SsisReleaseDirectory 'Toolbelt.Tsql.SsisDebug.dll'
if((Get-FileHash $dll).Hash.ToLowerInvariant() -cne $buildRecord.qualified_assembly_sha256 -or
   (Get-FileHash $dll -Algorithm SHA512).Hash -cne $acceptanceConfig.SsisContext.QualifiedProviderSha512){throw 'SSIS_FRESH_TLS_CURRENT_DLL_REQUIRED'}
$labAcceptance=Join-Path $acceptanceConfig.RepositoryRoot 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1'
if((Get-FileHash $labAcceptance).Hash -cne 'AE2CEB5DB6A907AF14DD9162EE9CF87E8529DC45F13C5C349CAC1738B176FC1E'){throw 'SSIS_FRESH_TLS_LAB_METHOD_CHANGED'}
$pinHandles=[Collections.Generic.List[IDisposable]]::new()
try{
 $manifestPin=[IO.File]::Open($acceptanceConfig.SsisContext.InputManifestPath,'Open','Read','Read');$pinHandles.Add($manifestPin)
 if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestPin)) -cne $acceptanceConfig.SsisContext.InputManifestSha256){throw 'SSIS_FRESH_TLS_INPUT_MANIFEST_CHANGED'}
 $seen=@{}
 foreach($entry in $acceptanceConfig.ToolbeltInputs){
  $path=[IO.Path]::GetFullPath((Join-Path $toolbeltRoot $entry.path))
  if(-not $path.StartsWith($toolbeltRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)){throw 'SSIS_FRESH_TLS_SOURCE_PATH'}
  $seen[$path]=$true
  $handle=[IO.File]::Open($path,'Open','Read','Read');$pinHandles.Add($handle)
  if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($handle)) -cne $entry.sha256){throw 'SSIS_FRESH_TLS_SOURCE_CHANGED'}
 }
 foreach($required in @($recordPath,$dll,(Join-Path $toolbeltRoot 'Modules/toolbelt.tsql.ssis-debug/Tests/Runtime/Invoke-CurrentAuthenticatedTlsLab.ps1'))){
  if(-not $seen.ContainsKey([IO.Path]::GetFullPath($required))){throw 'SSIS_FRESH_TLS_REQUIRED_PIN_MISSING'}
 }
 $source=[IO.File]::ReadAllText($labAcceptance)
 function Replace-FreshTlsOnce([string]$Old,[string]$New){
  if($script:source.Split($Old,[StringSplitOptions]::None).Count -ne 2){throw 'SSIS_FRESH_TLS_COMPOSITION_ANCHOR'}
  $script:source=$script:source.Replace($Old,$New)
 }
 Replace-FreshTlsOnce '$config.MaximumMinutes -ne 120' '$config.MaximumMinutes -ne 45'
 Replace-FreshTlsOnce '[datetimeoffset]::UtcNow.AddMinutes(121)' '[datetimeoffset]::UtcNow.AddMinutes(46)'
 Replace-FreshTlsOnce '@($worker.Cases).Count -ne 5' '@($worker.Cases).Count -ne 6'
 $anchor="    `$result.Cases+=@('SYNTHETIC_READONLY_STRICT_CONSUMER')"
 $callback=@'
    $result.Cases+=@('SYNTHETIC_READONLY_STRICT_CONSUMER')
    Assert-Budget;$result.Phase='CURRENT_SSIS_BUILD_CONSUMER';$ended=$false
    $ssis=$config.SsisContext
    $arguments=@{LabModuleFile=(Join-Path $repo 'SqlServerLab.psd1');LabTlsStateRoot=$config.StateRoot;LabTlsRunId=$lab.RunId;LabTlsInstanceId='primary';
      ExportPath=$export.JsonPath;ExpectedExportSha256=(Get-FileHash $export.JsonPath).Hash;
      InputManifestPath=$ssis.InputManifestPath;ExpectedInputManifestSha256=$ssis.InputManifestSha256;
      SsisReleaseDirectory=$ssis.SsisReleaseDirectory;ParserReleaseDirectory=$ssis.ParserReleaseDirectory;
      QualifiedProviderSha512=$ssis.QualifiedProviderSha512;JournalDirectory=$ssis.JournalDirectory}
    $adapter=Join-Path $config.ToolbeltRoot 'Modules/toolbelt.tsql.ssis-debug/Tests/Runtime/Invoke-CurrentAuthenticatedTlsLab.ps1'
    $sqlFailure=$null;$sqlAuditPassed=$false
    try{& $adapter @arguments}catch{$sqlFailure=$_}
    finally{
      $journalPath=Join-Path $ssis.JournalDirectory 'target-1.json'
      if(Test-Path -LiteralPath $journalPath){
        $journal=Get-Content $journalPath -Raw|ConvertFrom-Json -DateKind String
        if($journal.state -in @('PASS_CLEANED','FAILED_CLEANED')){
          & $adapter @arguments -AuditJournalPath $journalPath -ExpectedAuditJournalSha256 (Get-FileHash $journalPath).Hash
          $sqlAuditPassed=$true;$ended=$true
        }
      }
    }
    if($sqlFailure){throw $sqlFailure}
    if(-not $sqlAuditPassed){throw 'SSIS_FRESH_TLS_SQL_AUDIT_REQUIRED'}
    $result.Cases+=@('CURRENT_SSIS_BUILD_AND_FRESH_SQL_AUDIT')
'@
 Replace-FreshTlsOnce $anchor $callback
 $acceptanceSelf=$PSCommandPath
 $source=$source.Replace('$PSCommandPath','$acceptanceSelf')
 $errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$errors)
 if($errors.Count){throw 'SSIS_FRESH_TLS_COMPOSED_SYNTAX'}
 if($ValidateOnly){'SSIS_FRESH_TLS_ACCEPTANCE_COMPOSED; no elevation, VM, SQL or credential access';return}
 . ([scriptblock]::Create($source)) -ConfigurationPath $ConfigurationPath -ExpectedConfigurationSha256 $ExpectedConfigurationSha256 -Mode $Mode -DeadlineUtc $DeadlineUtc
}finally{foreach($pin in $pinHandles){$pin.Dispose()}}
