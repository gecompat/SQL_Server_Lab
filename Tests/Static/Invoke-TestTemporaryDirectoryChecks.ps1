#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Common/TestTemporaryDirectory.ps1')
$parent=Join-Path ([IO.Path]::GetTempPath()) ('lab-temp-check-'+[guid]::NewGuid().ToString('N'))
$passed=0
try{
    $owned=New-TestTemporaryDirectory -ParentPath $parent
    $null=New-Item -ItemType Directory -Path (Join-Path $owned.Path 'nested')
    Set-Content -LiteralPath (Join-Path $owned.Path 'nested/file.txt') -Value 'synthetic'
    Remove-TestTemporaryDirectory $owned
    Remove-TestTemporaryDirectory $owned
    if(Test-Path -LiteralPath $owned.Path){throw 'Ordinary cleanup failed'};$passed++
    $owned=New-TestTemporaryDirectory -ParentPath $parent
    Set-Content -LiteralPath (Join-Path $owned.Path '.test-owner') -Value 'foreign' -NoNewline
    $blocked=$false;try{Remove-TestTemporaryDirectory $owned}catch{$blocked=$true}
    if(-not $blocked -or -not(Test-Path -LiteralPath $owned.Path)){throw 'Owner drift was not preserved'};$passed++
    [IO.File]::WriteAllText((Join-Path $owned.Path '.test-owner'),$owned.Token)
    $foreign=Join-Path $parent 'foreign';$null=New-Item -ItemType Directory -Path $foreign
    Set-Content -LiteralPath (Join-Path $foreign 'sentinel.txt') -Value 'preserve'
    $kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    $null=New-Item -ItemType $kind -Path (Join-Path $owned.Path 'linked') -Target $foreign
    Remove-TestTemporaryDirectory $owned
    if(Test-Path -LiteralPath $owned.Path){throw 'Linked fixture remains'}
    if((Get-Content -LiteralPath (Join-Path $foreign 'sentinel.txt') -Raw).Trim() -cne 'preserve'){throw 'Foreign link target changed'};$passed++
    $linkedParent=Join-Path $parent 'linked-parent'
    $null=New-Item -ItemType $kind -Path $linkedParent -Target $foreign
    try{
        $blocked=$false;try{$unexpected=New-TestTemporaryDirectory -ParentPath (Join-Path $linkedParent 'new-parent')}catch{$blocked=$true}
        if(-not $blocked -or (Test-Path -LiteralPath (Join-Path $foreign 'new-parent'))){throw 'Allocation followed linked ancestor'};$passed++
    }finally{Remove-Item -LiteralPath $linkedParent -Force}
}finally{
    if(Test-Path -LiteralPath $parent){Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop}
}
Write-Host "TEST TEMPORARY DIRECTORY: PASS ($passed scenarios; foreign link target preserved)"
