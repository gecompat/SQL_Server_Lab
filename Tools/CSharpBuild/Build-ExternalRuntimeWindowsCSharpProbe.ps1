#Requires -Version 7.2
<#
.SYNOPSIS
    Baut die synthetische CSharp-SQL-Probe offline gegen geprüfte Eingaben.
.DESCRIPTION
    Benötigt vorhandenes .NET SDK 10.0.401, das geprüfte Extension-Paket und
    das gesperrte .NET-8-Referenzpaket. Keine SQL-/Provideraktion oder Downloads.
    Ein neuer Outputroot bleibt bei Fehlern für Diagnose erhalten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PackageSha256,
    [Parameter(Mandatory)][string]$ReferenceArchive,
    [Parameter(Mandatory)][string]$Dotnet,
    [Parameter(Mandatory)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw 'CSHARP_PROBE_OUTPUT_EXISTS'}
if(@($OutputRoot,$Dotnet,$Package,$ReferenceArchive) | Where-Object {$_ -match '[\r\n"]'}){throw 'CSHARP_PROBE_PATH_INVALID'}
foreach($candidate in @($OutputRoot,$Dotnet,$Package,$ReferenceArchive)){
    $ancestor=[IO.Path]::GetFullPath($candidate)
    while($ancestor){
        if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'CSHARP_PROBE_REPARSE_POINT'}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
}
$null=& (Join-Path $PSScriptRoot 'Test-ExternalRuntimeWindowsCSharpPackage.ps1') -Package $Package -ExpectedSha256 $PackageSha256
$expected='/lRLHYI1unTyWFmIbGgvqqiPEKH19Cw63ps5Q+rQd1ZndFpt3h47mpFanCkFh+hO/QkweEZNHEQxlgh0Zme/Jg=='
function Assert-CSharpReferenceArchive([string]$Path){
    $stream=[IO.File]::OpenRead($Path)
    try{$hash=[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($stream))}finally{$stream.Dispose()}
    if($hash -cne $expected){throw 'CSHARP_PROBE_REFERENCE_HASH'}
}
Assert-CSharpReferenceArchive $ReferenceArchive
$Dotnet=[IO.Path]::GetFullPath($Dotnet)
$compiler=Join-Path (Split-Path $Dotnet -Parent) 'sdk/10.0.401/Roslyn/bincore/csc.dll'
if(-not(Test-Path -LiteralPath $Dotnet -PathType Leaf) -or -not(Test-Path -LiteralPath $compiler -PathType Leaf)){throw 'CSHARP_PROBE_COMPILER_MISSING'}
$null=New-Item -ItemType Directory -Path $OutputRoot
$packageCopy=Join-Path $OutputRoot 'extension.zip';$referenceCopy=Join-Path $OutputRoot 'references.nupkg'
Copy-Item -LiteralPath $Package -Destination $packageCopy
Copy-Item -LiteralPath $ReferenceArchive -Destination $referenceCopy
$null=& (Join-Path $PSScriptRoot 'Test-ExternalRuntimeWindowsCSharpPackage.ps1') -Package $packageCopy -ExpectedSha256 $PackageSha256
Assert-CSharpReferenceArchive $referenceCopy
# Only fixed member names are extracted; no archive-controlled output paths.
$references=[Collections.Generic.List[string]]::new()
foreach($definition in @(@{Path=$referenceCopy;Kind='refs'},@{Path=$packageCopy;Kind='extension'})){
    $archive=[IO.Compression.ZipFile]::OpenRead($definition.Path)
    try{foreach($entry in $archive.Entries){
        $wanted=if($definition.Kind -eq 'refs'){$entry.FullName -cmatch '^ref/net8\.0/[A-Za-z0-9_.-]+\.dll$'}else{$entry.FullName -cin @('Microsoft.Data.Analysis.dll','Microsoft.SqlServer.CSharpExtension.dll')}
        if(-not $wanted){continue}
        $target=Join-Path $OutputRoot ($definition.Kind+'-'+$entry.Name)
        $inputStream=$entry.Open();$outputStream=[IO.File]::Open($target,[IO.FileMode]::CreateNew)
        try{$inputStream.CopyTo($outputStream)}finally{$inputStream.Dispose();$outputStream.Dispose()}
        $references.Add($target)
    }}finally{$archive.Dispose()}
}
if($references.Count -lt 10){throw 'CSHARP_PROBE_REFERENCES_MISSING'}
$source=Join-Path $OutputRoot 'Probe.cs'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../Tests/Integration/Fixtures/CSharp/Probe.cs') -Destination $source
$binary=Join-Path $OutputRoot 'SqlServerLab.CSharpProbe.dll'
$arguments=[Collections.Generic.List[string]]::new()
foreach($argument in @('/nologo','/target:library','/deterministic+','/nostdlib+')){$arguments.Add($argument)}
$arguments.Add('/out:"'+$binary+'"');$arguments.Add('/pathmap:"'+$OutputRoot+'=/_/"')
foreach($reference in $references){$arguments.Add('/reference:"'+$reference+'"')}
$arguments.Add('"'+$source+'"')
$response=Join-Path $OutputRoot 'compiler.rsp';$arguments|Set-Content -LiteralPath $response -Encoding utf8
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Dotnet;$start.WorkingDirectory=$OutputRoot
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.ArgumentList.Add($compiler);$start.ArgumentList.Add('@'+$response)
# Prevent inherited runtime hooks, profilers and diagnostic overrides in the compiler.
foreach($key in @($start.Environment.Keys)){
    if($key -match '^(DOTNET_|COMPlus_|CORECLR_|COR_)'){$null=$start.Environment.Remove($key)}
}
$start.Environment['DOTNET_ROLL_FORWARD']='Disable';$start.Environment['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try{
    if(-not $process.Start()){throw 'CSHARP_PROBE_COMPILER_START'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(120000)){$process.Kill($true);$process.WaitForExit();throw 'CSHARP_PROBE_COMPILER_TIMEOUT'}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'compiler.log'),$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult())
    if($process.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $binary)){throw 'CSHARP_PROBE_COMPILER_FAILED'}
}finally{$process.Dispose()}
$receipt=[pscustomobject]@{Status='PROBE_BUILT_NOT_SQL_VALIDATED';CompilerSdk='10.0.401';Framework='net8.0';
    PackageSha256=$PackageSha256.ToLowerInvariant();SourceSha256=(Get-FileHash $source).Hash.ToLowerInvariant();
    ProbeSha256=(Get-FileHash $binary).Hash.ToLowerInvariant();NativeAcceptanceStatus='NOT_EXECUTED'}
$receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputRoot 'probe-receipt.json') -Encoding utf8
$receipt
