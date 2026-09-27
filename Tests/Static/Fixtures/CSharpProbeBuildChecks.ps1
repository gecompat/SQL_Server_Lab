# Uses the valid synthetic package from CSharpAcceptancePackageChecks.
$probeBuilder=Join-Path $repoRoot 'Tools/CSharpBuild/Build-ExternalRuntimeWindowsCSharpProbe.ps1'
$badReferences=Join-Path $temporaryRoot 'bad-references.nupkg'
[IO.File]::WriteAllText($badReferences,'synthetic corrupt reference archive')
$probeOutput=Join-Path $temporaryRoot 'probe-build-output'
$caught=''
try {& $probeBuilder -Package $validPackage -PackageSha256 $validHash -ReferenceArchive $badReferences -Dotnet $PSHOME -OutputRoot $probeOutput}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp probe: Referenzhash vor Output und Compiler geprüft' -Success ($caught -ceq 'CSHARP_PROBE_REFERENCE_HASH' -and -not(Test-Path $probeOutput))
$null=New-Item -ItemType Directory -Path $probeOutput
$probeSentinel=Join-Path $probeOutput 'sentinel';[IO.File]::WriteAllText($probeSentinel,'preserve')
$caught=''
try {& $probeBuilder -Package $validPackage -PackageSha256 $validHash -ReferenceArchive $badReferences -Dotnet $PSHOME -OutputRoot $probeOutput}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp probe: vorhandenen Output nicht überschreiben' -Success ($caught -ceq 'CSHARP_PROBE_OUTPUT_EXISTS' -and [IO.File]::ReadAllText($probeSentinel) -ceq 'preserve')
# Execute the actual environment-filter AST against a synthetic child environment.
$probeAst=[Management.Automation.Language.Parser]::ParseFile($probeBuilder,[ref]$null,[ref]$null)
$environmentFilter=$probeAst.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '@($start.Environment.Keys)'},$true)
$start=[Diagnostics.ProcessStartInfo]::new()
$start.Environment.Clear()
foreach($name in @('DOTNET_STARTUP_HOOKS','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH_64','COR_ENABLE_PROFILING','COMPlus_ReadyToRun')){$start.Environment[$name]='synthetic'}
$start.Environment['PATH']='preserve'
if($null -ne $environmentFilter){& ([scriptblock]::Create($environmentFilter.Extent.Text))}
Add-CheckResult -Name 'CSharp probe: Kindprozess ohne geerbte Runtime-Hooks und Profiler' -Success ($null -ne $environmentFilter -and $start.Environment.Count -eq 1 -and $start.Environment['PATH'] -ceq 'preserve')
