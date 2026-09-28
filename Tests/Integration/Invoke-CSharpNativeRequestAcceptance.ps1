#Requires -Version 7.2
<#
.SYNOPSIS
    Führt die interne CSharp-Nativabnahme über einen explizit hashgebundenen lokalen Request aus.
.DESCRIPTION
    Nur manueller vertrauenswürdiger Main-Checkout. Reale Requestdaten bleiben lokal.
    Das ephemere Admin-Profil erhält separates exaktes Cleanup; kein UAC oder Download.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Profile,[Parameter(Mandatory)][string]$RequestSha256)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeProfileRequest.ps1')
$event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw|ConvertFrom-Json
Assert-CSharpNativeCheckout ([pscustomobject]@{EventName=$env:GITHUB_EVENT_NAME;Ref=$env:GITHUB_REF;Repository=$env:GITHUB_REPOSITORY;EventRepository=$event.repository.full_name;ExpectedCommit=$env:GITHUB_SHA;CheckoutCommit=(git -C $repoRoot rev-parse HEAD);Dirty=[bool](git -C $repoRoot status --porcelain --untracked-files=no)})
if(-not $IsWindows){throw 'CSHARP_NATIVE_WINDOWS_REQUIRED'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'CSHARP_NATIVE_ELEVATED_RUNNER_REQUIRED'}}finally{$identity.Dispose()}
if($Profile -cne 'csharp-sql2025' -or $RequestSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'CSHARP_NATIVE_REQUEST_BINDING'}
$volume=Get-CSharpNativeRequestVolumeRoot
$requestPath=Join-Path (Join-Path $volume ('SqlServerLab-CSharpRequest-'+$RequestSha256)) 'request.json'
$request=ConvertFrom-CSharpNativeRequest -Json (Read-CSharpNativeRequestBytes -Path $requestPath -ExpectedHash $RequestSha256) -ProfileName $Profile -Commit $env:GITHUB_SHA
$recoveryRecord=New-CSharpNativeRecoveryRecordPath
$binding=[pscustomobject]@{Nonce=$request.Nonce;MainCommit=$env:GITHUB_SHA;RequestSha256=$RequestSha256}
Invoke-CSharpNativeWithTemporaryProfile -ProfileJson $request.ProfileJson -RecoveryRecordPath $recoveryRecord -RequestBinding $binding -Action {
    if([DateTimeOffset]::UtcNow -ge $request.ExpiresUtc){throw 'CSHARP_NATIVE_REQUEST_EXPIRY'}
    & (Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1') -Profile $Profile
}
