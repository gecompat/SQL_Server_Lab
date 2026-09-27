#Requires -Version 7.2
# Internal offline CSharp build; no SQL registration or provider mutation.
function Invoke-LabCSharpPackageBuild {
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Inputs,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$Dotnet,
    [Parameter(Mandatory)][string]$VcVars,
    [Parameter(Mandatory)][string]$RecipeRoot,
    [switch]$ValidateInputsOnly
)
$ErrorActionPreference='Stop'
$Inputs=[IO.Path]::GetFullPath($Inputs)
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
$Dotnet=[IO.Path]::GetFullPath($Dotnet)
$VcVars=[IO.Path]::GetFullPath($VcVars)
$RecipeRoot=[IO.Path]::GetFullPath($RecipeRoot)
foreach($path in @($Inputs,$OutputRoot,$Dotnet,$VcVars)){
    if($path -match '[%&!^\r\n"]'){throw 'Unsupported command-shell path character.'}
}
if(Test-Path -LiteralPath $OutputRoot){throw 'Output root must not exist.'}
function Assert-Hash([string]$Path,[string]$Algorithm,[string]$Expected){
    if((Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash -ine $Expected){throw "Input hash mismatch: $([IO.Path]::GetFileName($Path))"}
}
$sourceCommit='9a897b70e1823573e7e455f3b3c3ecf3a6bf1f0f'
$sourceZip=Join-Path $Inputs 'source.zip'
$runtimeZip=Join-Path $Inputs 'dotnet-runtime-8.0.31-win-x64.zip'
$lock=Join-Path $RecipeRoot 'packages.lock.json'
Assert-Hash $sourceZip SHA256 '5EEDB40BDC9B38D5B48F9E6FB0B94E76F805E8D855536A867C7BA670D6535BF1'
Assert-Hash $runtimeZip SHA512 '9c55c58694676ee64b0eed2cd6d8cbf58b9aa8288420acc66841e15ca0099c75d4af0182d23a641c2342e5a151a325df4a12fa0bde2e47c0fb7e9a33e7b09896'
$archiveLock=Join-Path $RecipeRoot 'archives.lock.json'
$packages=@(Get-Content -LiteralPath $archiveLock -Raw|ConvertFrom-Json)
$archives=@(foreach($package in $packages){
    $id=$package.Id;$version=$package.Version
    if($id -notmatch '^[a-z0-9][a-z0-9.\-]+$' -or $version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$'){throw 'CSHARP_BUILD_INVALID_ARCHIVE_LOCK'}
    $archive=Join-Path $Inputs "nuget/$id/$version/$id.$version.nupkg"
    $actual=[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($archive)))
    if($actual -cne $package.Sha512){throw "NuGet archive hash mismatch: $id"}
    $archive
})
if(-not (Test-Path -LiteralPath $Dotnet -PathType Leaf) -or -not (Test-Path -LiteralPath $VcVars -PathType Leaf)){throw 'Toolchain missing.'}
if($ValidateInputsOnly){return [pscustomobject]@{Status='INPUTS_VERIFIED';Packages=$archives.Count}}
if(-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64'){throw 'CSHARP_BUILD_WINDOWS_X64_REQUIRED'}
# Retain only this newly created root on failure for local diagnosis/recovery.
$null=New-Item -ItemType Directory -Path $OutputRoot
# Copy and recheck inputs so every later read is bound to this build root.
$inputCopies=Join-Path $OutputRoot 'inputs'
$null=New-Item -ItemType Directory -Path $inputCopies
Copy-Item -LiteralPath $sourceZip -Destination $inputCopies
Copy-Item -LiteralPath $runtimeZip -Destination $inputCopies
$sourceZip=Join-Path $inputCopies 'source.zip'
$runtimeZip=Join-Path $inputCopies 'dotnet-runtime-8.0.31-win-x64.zip'
Assert-Hash $sourceZip SHA256 '5EEDB40BDC9B38D5B48F9E6FB0B94E76F805E8D855536A867C7BA670D6535BF1'
Assert-Hash $runtimeZip SHA512 '9c55c58694676ee64b0eed2cd6d8cbf58b9aa8288420acc66841e15ca0099c75d4af0182d23a641c2342e5a151a325df4a12fa0bde2e47c0fb7e9a33e7b09896'
function Invoke-BuildProcess([string]$File,[string[]]$Arguments,[string]$WorkingDirectory,[string]$LogName,[hashtable]$Environment=@{}){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$File;$start.WorkingDirectory=$WorkingDirectory
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($name in @($start.Environment.Keys)){
        if($name -match '^(DOTNET_|MSBUILD|NUGET_|CL$|_CL_$|LINK$|_LINK_$|LIB$|LIBPATH$|INCLUDE$)'){$null=$start.Environment.Remove($name)}
    }
    foreach($arg in $Arguments){$null=$start.ArgumentList.Add($arg)}
    foreach($name in $Environment.Keys){$start.Environment[$name]=[string]$Environment[$name]}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not $process.Start()){throw 'Process start failed.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(180000)){$process.Kill($true);if(-not $process.WaitForExit(10000)){throw 'Build process cleanup incomplete.'};throw 'Build timeout.'}
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $OutputRoot "$LogName.log"),$out+"`n"+$err)
        if($process.ExitCode -ne 0){throw "Build step $LogName failed: $($process.ExitCode)."}
        $out.Trim()
    }finally{$process.Dispose()}
}
$environment=@{DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_NOLOGO='1';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_CLI_HOME=(Join-Path $OutputRoot 'cli-home');NUGET_PACKAGES=(Join-Path $OutputRoot 'packages');MSBUILDDISABLENODEREUSE='1';DOTNET_CLI_USE_MSBUILD_SERVER='0'}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'global.json'),'{"sdk":{"version":"10.0.401","rollForward":"disable"}}')
$sdk=Invoke-BuildProcess $Dotnet @('--version') $OutputRoot 'sdk' $environment
if($sdk -cne '10.0.401'){throw 'Unexpected SDK.'}
Expand-Archive -LiteralPath $sourceZip -DestinationPath (Join-Path $OutputRoot 'source')
Expand-Archive -LiteralPath $runtimeZip -DestinationPath (Join-Path $OutputRoot 'runtime')
$extractedSource=[IO.Path]::GetFullPath((Join-Path $OutputRoot "source/sql-server-language-extensions-$sourceCommit"))
$source=[IO.Path]::GetFullPath((Join-Path $OutputRoot 'src'))
$boundary=$OutputRoot+[IO.Path]::DirectorySeparatorChar
foreach($target in @($extractedSource,$source)){if(-not $target.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Source move escaped build root.'}}
if(Test-Path -LiteralPath $source){throw 'Short source path already exists.'}
Move-Item -LiteralPath $extractedSource -Destination $source
$extension=Join-Path $source 'language-extensions/dotnet-core-CSharp'
$project=Join-Path $extension 'src/managed/Microsoft.SqlServer.CSharpExtension.csproj'
Copy-Item -LiteralPath $lock -Destination (Join-Path $extension 'src/managed/packages.lock.json')
$feed=Join-Path $OutputRoot 'feed';$null=New-Item -ItemType Directory -Path $feed
foreach($package in $packages){
    $name="$($package.Id).$($package.Version).nupkg"
    Copy-Item -LiteralPath (Join-Path $Inputs "nuget/$($package.Id)/$($package.Version)/$name") -Destination $feed
    $hash=[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes((Join-Path $feed $name))))
    if($hash -cne $package.Sha512){throw 'CSHARP_BUILD_ARCHIVE_COPY_MISMATCH'}
}
$config=Join-Path $OutputRoot 'NuGet.Config'
[IO.File]::WriteAllText($config,'<configuration><packageSources><clear/><add key="offline" value="feed"/></packageSources><config><add key="globalPackagesFolder" value="packages"/></config></configuration>')
$binProperty='-p:BinRoot='+(Join-Path $OutputRoot 'bin')
$objProperty='-p:BaseIntermediateOutputPath='+(Join-Path $OutputRoot 'obj')+[IO.Path]::DirectorySeparatorChar
$isolation=@('-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false','-p:ImportDirectoryPackagesProps=false')
$null=Invoke-BuildProcess $Dotnet (@('restore',$project,'--locked-mode','--configfile',$config,'-p:NuGetAudit=false','--disable-parallel',$binProperty,$objProperty)+$isolation) $OutputRoot 'restore' $environment
$managed=Join-Path $OutputRoot 'managed'
$null=Invoke-BuildProcess $Dotnet (@('build',$project,'--no-restore','--configuration','Release','--output',$managed,'-p:ContinuousIntegrationBuild=true','-p:EnableSourceControlManagerQueries=false','-p:EnableSourceLink=false','-p:IncludeSourceRevisionInInformationalVersion=false','-p:DeterministicSourcePaths=false',"-p:PathMap=$OutputRoot=/_/",'-p:UseSharedCompilation=false','--disable-build-servers',$binProperty,$objProperty)+$isolation) $OutputRoot 'managed' $environment
$native=Join-Path $OutputRoot 'native';$null=New-Item -ItemType Directory -Path $native
$cpp=@('DotnetEnvironment.cpp','Logger.cpp','nativecsharpextension.cpp'|ForEach-Object {'"'+(Join-Path $extension "src/native/$_")+'"'}) -join ' '
$command=@"
@echo off
call "$VcVars" 10.0.26100.0 -vcvars_ver=14.51.36231 >nul
if errorlevel 1 exit /b %errorlevel%
if not "%VCToolsVersion%"=="14.51.36231" exit /b 21
if not "%WindowsSDKVersion%"=="10.0.26100.0\" exit /b 22
cl.exe /nologo /LD /D WINDOWS /EHsc /Brepro /experimental:deterministic /pathmap:"$OutputRoot=/_/" $cpp /I "$extension\include" /I "$source\extension-host\include" /link /Brepro /OUT:nativecsharpextension.dll
exit /b %errorlevel%
"@
$batch=Join-Path $OutputRoot 'build-native.cmd';[IO.File]::WriteAllText($batch,$command)
$null=Invoke-BuildProcess $env:ComSpec @('/d','/c',$batch) $native 'native'
if((Get-Content (Join-Path $OutputRoot 'native.log') -Raw) -match '(?im)\bwarning\b'){throw 'Native build emitted a warning; inspect before packaging.'}
$runtime=Join-Path $OutputRoot 'runtime'
$hostfxr=Join-Path $runtime 'host/fxr/8.0.31/hostfxr.dll'
Assert-Hash $hostfxr SHA256 '4F5A0500CD2A2439B0D5EDBF242950233AEC4539EC9A5E7BA9B8A9B0079F63AF'
if((Get-AuthenticodeSignature -FilePath $hostfxr).Status -ne 'Valid'){throw 'Hostfxr signature invalid.'}
$entries=[Collections.Generic.SortedDictionary[string,byte[]]]::new([StringComparer]::Ordinal)
foreach($file in Get-ChildItem -LiteralPath $managed -Recurse -File){
    if($file.Extension -eq '.pdb'){continue}
    $relative=[IO.Path]::GetRelativePath($managed,$file.FullName).Replace('\','/')
    $entries.Add($relative,[IO.File]::ReadAllBytes($file.FullName))
}
$runtimeConfig=Get-Content (Join-Path $managed 'Microsoft.SqlServer.CSharpExtension.runtimeconfig.json') -Raw|ConvertFrom-Json
$runtimeConfig.runtimeOptions.framework.version='8.0.31';$runtimeConfig.runtimeOptions.rollForward='LatestPatch'
$entries['Microsoft.SqlServer.CSharpExtension.runtimeconfig.json']=[Text.Encoding]::UTF8.GetBytes(($runtimeConfig|ConvertTo-Json -Depth 10 -Compress))
$entries.Add('nativecsharpextension.dll',[IO.File]::ReadAllBytes((Join-Path $native 'nativecsharpextension.dll')))
$entries.Add('hostfxr.dll',[IO.File]::ReadAllBytes($hostfxr))
$entries.Add('notices/sql-language-extensions/LICENSE',[IO.File]::ReadAllBytes((Join-Path $source 'LICENSE')))
$csharpLicense=@(Get-ChildItem -LiteralPath $extension -File | Where-Object Name -Match '^LICENSE(\.TXT)?$')
if($csharpLicense.Count -ne 1){throw 'CSharp license not unique.'}
$entries.Add('notices/csharp/LICENSE.txt',[IO.File]::ReadAllBytes($csharpLicense[0].FullName))
foreach($name in @('LICENSE.txt','ThirdPartyNotices.txt')){$entries.Add("notices/dotnet/$name",[IO.File]::ReadAllBytes((Join-Path $runtime $name)))}
foreach($package in $packages){
    $id=$package.Id;$version=$package.Version
    $archive=Join-Path $feed "$id.$version.nupkg"
    $packageZip=[IO.Compression.ZipFile]::OpenRead($archive)
    try{
        foreach($entry in @($packageZip.Entries|Where-Object {$_.Name -and ($_.FullName -match '(?i)(license|notice|copying)' -or $_.FullName -match '\.nuspec$')})){
            if($entry.FullName -match '(^/|\\|(^|/)\.\.(/|$)|:)'){throw 'Invalid package notice path.'}
            $buffer=[IO.MemoryStream]::new();$entryStream=$entry.Open()
            try{$entryStream.CopyTo($buffer);$entries.Add("notices/nuget/$id/$version/$($entry.FullName)",$buffer.ToArray())}finally{$entryStream.Dispose();$buffer.Dispose()}
        }
    }finally{$packageZip.Dispose()}
}
$manifest=[ordered]@{Scope='SOURCE_BUILD_NOT_SQL_VALIDATED';SourceCommit=$sourceCommit;Framework='Microsoft.NETCore.App';FrameworkVersion='8.0.31';RollForward='LatestPatch';Files=@(foreach($entry in $entries.GetEnumerator()){[ordered]@{Path=$entry.Key;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.Value)).ToLowerInvariant()}})}
$entries.Add('package-provenance.json',[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 8 -Compress)))
$zip=Join-Path $OutputRoot 'csharp-net8.zip'
$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
$zipArchive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($entry in $entries.GetEnumerator()){
        $item=$zipArchive.CreateEntry($entry.Key,[IO.Compression.CompressionLevel]::Optimal)
        $item.LastWriteTime=[datetimeoffset]::new(2000,1,1,0,0,0,[timespan]::Zero);$item.ExternalAttributes=0
        $entryStream=$item.Open();try{$entryStream.Write($entry.Value,0,$entry.Value.Length)}finally{$entryStream.Dispose()}
    }
}finally{$zipArchive.Dispose();$stream.Dispose()}
$receipt=[ordered]@{Status='BUILT_NOT_SQL_VALIDATED';Sdk=$sdk;VcToolsVersion='14.51.36231';WindowsSdkVersion='10.0.26100.0';NuGetPackages=$archives.Count;Restore='OFFLINE_LOCKED';NoticeEntries=@($entries.Keys|Where-Object {$_ -like 'notices/*'}).Count;PackageSha256=(Get-FileHash $zip -Algorithm SHA256).Hash;PackageBytes=(Get-Item $zip).Length;NativeSha256=(Get-FileHash (Join-Path $native 'nativecsharpextension.dll')).Hash;ManagedSha256=(Get-FileHash (Join-Path $managed 'Microsoft.SqlServer.CSharpExtension.dll')).Hash}
$receipt|ConvertTo-Json|Set-Content (Join-Path $OutputRoot 'build-receipt.json') -Encoding utf8
[pscustomobject]$receipt

}
