# Test-only ownership for disposable filesystem fixtures. Not a product cleanup API.
function New-TestTemporaryDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ParentPath)
    $parent=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ParentPath))
    $probe=$parent
    while(-not(Test-Path -LiteralPath $probe)){
        $probe=[IO.Path]::GetDirectoryName($probe)
        if(-not $probe){throw 'TEST_DIRECTORY_PARENT_UNRESOLVED'}
    }
    for($ancestor=Get-Item -LiteralPath $probe -Force;$ancestor;$ancestor=$ancestor.Parent){
        if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TEST_DIRECTORY_ANCESTOR_LINK'}
    }
    $null=New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
    $token=[guid]::NewGuid().ToString('D')
    $path=Join-Path $parent ([guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $path -ErrorAction Stop
    $marker=Join-Path $path '.test-owner'
    [IO.File]::WriteAllText($marker,$token)
    [pscustomobject]@{Path=$path;Parent=$parent;Token=$token}
}

function Remove-TestTemporaryDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$OwnedDirectory)
    $path=[IO.Path]::GetFullPath([string]$OwnedDirectory.Path)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not [IO.Path]::GetDirectoryName($path).Equals([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$OwnedDirectory.Parent)),$comparison) -or
        [IO.Path]::GetFileName($path) -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$OwnedDirectory.Token -cnotmatch '^[a-f0-9-]{36}$'){throw 'TEST_DIRECTORY_SCOPE_INVALID'}
    if(-not(Test-Path -LiteralPath $path)){return}
    for($ancestor=Get-Item -LiteralPath $path -Force;$ancestor;$ancestor=$ancestor.Parent){
        if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TEST_DIRECTORY_ANCESTOR_LINK'}
    }
    $marker=Get-Item -LiteralPath (Join-Path $path '.test-owner') -Force -ErrorAction Stop
    if($marker.Attributes -band [IO.FileAttributes]::ReparsePoint -or [IO.File]::ReadAllText($marker.FullName) -cne $OwnedDirectory.Token){throw 'TEST_DIRECTORY_OWNER_DRIFT'}
    # Enumerate without following directory links. Unlink them separately, so
    # foreign junction/symlink targets are never included in recursive removal.
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($path)
    $links=[Collections.Generic.List[string]]::new()
    while($pending.Count){
        foreach($entry in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$links.Add($entry.FullName)}
            elseif($entry.PSIsContainer){$pending.Push($entry.FullName)}
        }
    }
    foreach($link in $links){Remove-Item -LiteralPath $link -Force -ErrorAction Stop}
    if(@(Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'TEST_DIRECTORY_LINK_CHANGED'}
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    if(Test-Path -LiteralPath $path){throw 'TEST_DIRECTORY_CLEANUP_INCOMPLETE'}
}
