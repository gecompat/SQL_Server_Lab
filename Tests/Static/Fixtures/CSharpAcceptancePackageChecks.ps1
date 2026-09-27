# Synthetic package-contract tests, not a compiler or native SQL proof.
$packageCheck=Join-Path $repoRoot 'Tools/CSharpBuild/Test-ExternalRuntimeWindowsCSharpPackage.ps1'
function New-CSharpAcceptanceFixture([string]$Name,[scriptblock]$Change){
    $content=[ordered]@{}
    foreach($entry in @('nativecsharpextension.dll','hostfxr.dll','Microsoft.SqlServer.CSharpExtension.dll',
        'Microsoft.SqlServer.CSharpExtension.deps.json','notices/sql-language-extensions/LICENSE',
        'notices/csharp/LICENSE.txt','notices/dotnet/LICENSE.txt','notices/dotnet/ThirdPartyNotices.txt')){$content[$entry]='synthetic'}
    $content['Microsoft.SqlServer.CSharpExtension.runtimeconfig.json']='{"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"8.0.31"},"rollForward":"LatestPatch"}}'
    $manifest=[ordered]@{Scope='SOURCE_BUILD_NOT_SQL_VALIDATED';SourceCommit='9a897b70e1823573e7e455f3b3c3ecf3a6bf1f0f';Framework='Microsoft.NETCore.App';FrameworkVersion='8.0.31';RollForward='LatestPatch';Files=@()}
    foreach($entry in $content.GetEnumerator()){
        $manifest.Files+=@{Path=$entry.Key;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entry.Value))).ToLowerInvariant()}
    }
    if($Change){& $Change $content $manifest}
    $content['package-provenance.json']=$manifest|ConvertTo-Json -Depth 10 -Compress
    $path=Join-Path $temporaryRoot ($Name+'.zip')
    $archive=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach($entry in $content.GetEnumerator()){
        $zipEntry=$archive.CreateEntry($entry.Key);$zipEntry.ExternalAttributes=0
        $writer=[IO.StreamWriter]::new($zipEntry.Open(),[Text.UTF8Encoding]::new($false))
        try{$writer.Write([string]$entry.Value)}finally{$writer.Dispose()}
    }}finally{$archive.Dispose()}
    $path
}
$validPackage=New-CSharpAcceptanceFixture 'valid' $null
$validHash=(Get-FileHash $validPackage).Hash
$beforeFiles=@(Get-ChildItem $temporaryRoot -Recurse -File).Count
$result=& $packageCheck -Package $validPackage -ExpectedSha256 $validHash
Add-CheckResult -Name 'CSharp package: vollständiges Paket geprüft, kein SQL-PASS oder Extraktion' -Success (
    $result.Status -ceq 'PACKAGE_VERIFIED_NOT_SQL_VALIDATED' -and -not $result.MutationAllowed -and
    $result.NativeAcceptanceStatus -ceq 'NOT_EXECUTED' -and $result.FileCount -eq 9 -and
    $beforeFiles -eq @(Get-ChildItem $temporaryRoot -Recurse -File).Count -and (Get-FileHash $validPackage).Hash -eq $validHash
)
$cases=@(
    @{Name='traversal';Change={param($c,$m)$c['../outside']='synthetic'}},
    @{Name='absolute';Change={param($c,$m)$c['/outside']='synthetic'}},
    @{Name='content';Change={param($c,$m)$c['hostfxr.dll']='changed'}},
    @{Name='missing';Change={param($c,$m)$c.Remove('hostfxr.dll')}},
    @{Name='unlisted';Change={param($c,$m)$c['extra.dll']='synthetic'}},
    @{Name='duplicate-manifest';Change={param($c,$m)$m.Files[1]=$m.Files[0]}},
    @{Name='source';Change={param($c,$m)$m.SourceCommit='0'*40}},
    @{Name='framework';Change={param($c,$m)$m.FrameworkVersion='5.0.0'}},
    @{Name='config';Change={param($c,$m)$c['Microsoft.SqlServer.CSharpExtension.runtimeconfig.json']='{}';$m.Files=@($m.Files|ForEach-Object{if($_.Path -like '*.runtimeconfig.json'){$_.Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('{}'))).ToLowerInvariant()};$_})}}
)
foreach($case in $cases){
    $package=New-CSharpAcceptanceFixture $case.Name $case.Change
    $caught='';try{& $packageCheck -Package $package -ExpectedSha256 (Get-FileHash $package).Hash}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('CSharp package: Abwehr '+$case.Name) -Success ($caught -ceq 'CSHARP_ACCEPTANCE_PACKAGE_INVALID')
}
$caught='';try{& $packageCheck -Package $validPackage -ExpectedSha256 ('0'*64)}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp package: unabhängiger erwarteter Gesamthash erforderlich' -Success ($caught -ceq 'CSHARP_ACCEPTANCE_PACKAGE_INVALID')
$missingPackage=Join-Path $temporaryRoot 'does-not-exist.zip'
$caught='';try{& $packageCheck -Package $missingPackage -ExpectedSha256 $validHash}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp package: Fehler enthalten keine Eingabepfade' -Success ($caught -ceq 'CSHARP_ACCEPTANCE_PACKAGE_INVALID')
if($IsWindows){
    $script:csharpFileReadAttempted=$false
    function New-Object {param($TypeName,$ArgumentList) if($TypeName -ne 'System.IO.DriveInfo'){throw 'Unexpected type'};[pscustomobject]@{DriveType=[IO.DriveType]::Network}}
    function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction) $script:csharpFileReadAttempted=$true;throw 'File read must not occur'}
    try {
        $caught='';try{& $packageCheck -Package $validPackage -ExpectedSha256 $validHash}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp package: gemapptes Netzlaufwerk vor Dateizugriff blockiert' -Success (
            $caught -ceq 'CSHARP_ACCEPTANCE_PACKAGE_INVALID' -and -not $script:csharpFileReadAttempted)
    } finally {Remove-Item Function:New-Object,Function:Get-Item;Remove-Variable csharpFileReadAttempted -Scope Script}
}
