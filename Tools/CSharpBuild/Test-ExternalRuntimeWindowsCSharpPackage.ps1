#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft ein explizit hashgebundenes CSharp-Buildpaket ohne Extraktion.
.DESCRIPTION
    Read-only Acceptance-Vorprüfung, keine Vertrauensentscheidung und keine
    SQL-Abnahme. Der erwartete Hash muss aus dem zuvor geprüften Build stammen.
    Ein späterer Consumer muss seine eigene Kopie erneut prüfen.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
)
$ErrorActionPreference='Stop'
$stream=$null; $archive=$null
try {
    $path=[IO.Path]::GetFullPath($Package)
    if($path.StartsWith('\\') -or $path.StartsWith('//')){throw 'REMOTE_PATH'}
    if($IsWindows){
        $drive=New-Object -TypeName System.IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot($path))
        if($drive.DriveType -ne [IO.DriveType]::Fixed){throw 'LOCAL_FIXED_DRIVE_REQUIRED'}
    }
    $ancestor=$path
    while($ancestor){
        $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'REPARSE_POINT'}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    # The hash and all ZIP reads use the same handle; do not reopen by name.
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if($stream.Length -lt 22 -or $stream.Length -gt 128MB){throw 'PACKAGE_SIZE'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    if($hash -ine $ExpectedSha256){throw 'PACKAGE_HASH'}
    $stream.Position=0
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    if($archive.Entries.Count -lt 1 -or $archive.Entries.Count -gt 512){throw 'ENTRY_COUNT'}
    $entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $total=0L
    foreach($entry in $archive.Entries){
        $name=$entry.FullName
        if($name.Length -gt 240 -or $name -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
            @($name.Split('/') | Where-Object {$_ -in @('.','..') -or $_.EndsWith('.')}).Count -or
            $entry.ExternalAttributes -ne 0 -or $entries.ContainsKey($name)){throw 'ENTRY_PATH'}
        $total+=$entry.Length
        if($entry.Length -gt 64MB -or $total -gt 256MB){throw 'EXPANDED_SIZE'}
        $entries.Add($name,$entry)
    }
    function Read-CSharpPackageJson([string]$Name){
        if(-not $entries.ContainsKey($Name) -or $entries[$Name].Length -gt 1MB){throw 'JSON_ENTRY'}
        $inputStream=$entries[$Name].Open(); $reader=[IO.StreamReader]::new($inputStream,[Text.UTF8Encoding]::new($false,$true))
        try { $reader.ReadToEnd() | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
        finally { $reader.Dispose(); $inputStream.Dispose() }
    }
    $manifest=Read-CSharpPackageJson 'package-provenance.json'
    if($manifest.Scope -cne 'SOURCE_BUILD_NOT_SQL_VALIDATED' -or
        $manifest.SourceCommit -cne '9a897b70e1823573e7e455f3b3c3ecf3a6bf1f0f' -or
        $manifest.Framework -cne 'Microsoft.NETCore.App' -or $manifest.FrameworkVersion -cne '8.0.31' -or
        $manifest.RollForward -cne 'LatestPatch'){throw 'PROVENANCE'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if(@($manifest.Files).Count -ne $entries.Count-1){throw 'MANIFEST_COVERAGE'}
    foreach($file in $manifest.Files){
        $name=[string]$file.Path
        if($name -ieq 'package-provenance.json' -or -not $entries.ContainsKey($name) -or
            -not $seen.Add($name) -or $file.Sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'MANIFEST_ENTRY'}
        $entryStream=$entries[$name].Open()
        try { $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryStream)).ToLowerInvariant() }
        finally { $entryStream.Dispose() }
        if($actual -cne $file.Sha256){throw 'CONTENT_HASH'}
    }
    foreach($required in @('nativecsharpextension.dll','hostfxr.dll','Microsoft.SqlServer.CSharpExtension.dll',
        'Microsoft.SqlServer.CSharpExtension.deps.json','Microsoft.SqlServer.CSharpExtension.runtimeconfig.json',
        'notices/sql-language-extensions/LICENSE','notices/csharp/LICENSE.txt','notices/dotnet/LICENSE.txt','notices/dotnet/ThirdPartyNotices.txt')){
        if(-not $seen.Contains($required)){throw 'REQUIRED_ENTRY'}
    }
    $config=Read-CSharpPackageJson 'Microsoft.SqlServer.CSharpExtension.runtimeconfig.json'
    if($config.runtimeOptions.framework.name -cne 'Microsoft.NETCore.App' -or
        $config.runtimeOptions.framework.version -cne '8.0.31' -or
        $config.runtimeOptions.rollForward -cne 'LatestPatch'){throw 'RUNTIME_CONFIG'}
    [pscustomobject]@{Status='PACKAGE_VERIFIED_NOT_SQL_VALIDATED';PackageSha256=$hash;
        SourceCommit=$manifest.SourceCommit;FrameworkVersion='8.0.31';FileCount=$seen.Count;
        MutationAllowed=$false;NativeAcceptanceStatus='NOT_EXECUTED'}
}
catch { throw 'CSHARP_ACCEPTANCE_PACKAGE_INVALID' }
finally { if($archive){$archive.Dispose()};if($stream){$stream.Dispose()} }
