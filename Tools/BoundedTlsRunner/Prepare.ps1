#Requires -Version 7.5
<# .SYNOPSIS
    Bereitet einen privaten, hashgebundenen Windows-TLS-Runner ohne Erhöhung vor.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][string]$ControllerId,
    [Parameter(Mandatory)][string]$LocationId,
    [Parameter(Mandatory)][string]$CandidateId,
    [Parameter(Mandatory)][string]$AuthorityRef,
    [Parameter(Mandatory)][string]$ClientRef,
    [Parameter(Mandatory)][string]$PackageFamilyName,
    [Parameter(Mandatory)][string]$AppId
)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'BOUNDED_TLS_WINDOWS_REQUIRED'}
. (Join-Path $PSScriptRoot 'Common.ps1')
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$authority=& $module {param($d,$c,$l,$a,$r)Get-LabTlsOperationalAuthority $d $c $l $a $r} $DataRoot $ControllerId $LocationId $AuthorityRef $ClientRef
if($authority.Authority.CandidateId -cne $CandidateId){throw 'BOUNDED_TLS_CANDIDATE_MISMATCH'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$out=Assert-BoundedTlsLocalPath $OutputDirectory
& $module {param($p,$s)Initialize-LabTlsCaPrivateDirectory $p $s -NewOnly} $out $sid
$source=Join-Path $out 'source';New-Item -ItemType Directory -Path $source|Out-Null
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
$paths=@(Get-TlsHyperVSourceInventory $repo)
$rows=@(foreach($relative in $paths){
    $from=Join-Path $repo $relative;$item=Get-Item -LiteralPath $from -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BOUNDED_TLS_SOURCE_REPARSE'}
    $to=Join-Path $source $relative
    $null=New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force
    Copy-Item -LiteralPath $from -Destination $to
    @{RelativePath=$relative;Sha256=Get-BoundedTlsHash $to}
})
$id=[guid]::NewGuid().ToString('D')
$binaries=[ordered]@{}
$binaryPaths=@{PowerShell=(Join-Path $PSHOME 'pwsh.exe');Git=(Get-Command git -CommandType Application|Select-Object -First 1).Source;Sqlcmd=$authority.Client.Details.SqlcmdPath}
foreach($name in @('PowerShell','Git','Sqlcmd')){$binaries[$name]=@{Path=$binaryPaths[$name];Sha256=Get-BoundedTlsHash $binaryPaths[$name]}}
$plan=[ordered]@{ContractVersion='SqlServerLab.BoundedTlsRunner/0.1';RunnerId=$id;ActorSid=$sid;StageSourceRoot=$source;InstallRoot=(Get-BoundedTlsRoot $id);
    DataRoot=[IO.Path]::GetFullPath($DataRoot);StateRoot=[IO.Path]::GetFullPath((Join-Path $DataRoot 'State'));ControllerId=$ControllerId;LocationId=$LocationId;
    CandidateId=$CandidateId;AuthorityRef=$AuthorityRef;ClientRef=$ClientRef;PackageFamilyName=$PackageFamilyName;AppId=$AppId;Binaries=$binaries;Sources=$rows;
    MaximumAttempts=2;LeaseMinutes=120;AttemptMinutes=45}
Assert-BoundedTlsPlan ([pscustomobject]$plan)
Write-BoundedTlsJson (Join-Path $out 'plan.private.json') $plan
[pscustomobject]@{RunnerId=$id;PlanPath=(Join-Path $out 'plan.private.json');PlanSha256=(Get-BoundedTlsHash (Join-Path $out 'plan.private.json'));SourceFiles=$rows.Count;Status='PREPARED_NOT_INSTALLED'}
