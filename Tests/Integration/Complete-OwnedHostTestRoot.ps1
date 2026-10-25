#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'Tests/Common/OwnedHostTestCleanup.ps1')
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$providers=@(& $module {param($Root)(Get-LabOwnedHostPolicy -StateRoot $Root -Required).RuntimePins.Provider} $StateRoot)
$tools=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $providers)
if(@($tools|Where-Object {-not $_.Available}).Count){throw 'OWNED_TEST_CLEANUP_TOOL_UNAVAILABLE'}
$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
$held=$false
try{
    try{$held=$mutex.WaitOne([timespan]::FromMinutes(2))}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'OWNED_TEST_CLEANUP_MUTEX_TIMEOUT'}
    $null=Invoke-OwnedHostTestCleanup -StateRoot $StateRoot -Module $module
    Write-Host 'OWNED_TEST_CLEANUP_SUCCEEDED: own runs, stores and tasks absent.'
}finally{
    if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    Remove-Module $module -Force
}
