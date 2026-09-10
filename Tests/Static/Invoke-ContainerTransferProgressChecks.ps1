#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft BACPAC-Transfer, begrenztes Cleanup und Fortschritt bei Teilfehlern.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($sourceFile in @('ConsoleUi','ActionProgress','SampleArtifactHandlers')) { . (Join-Path $repoRoot "Private/$sourceFile.ps1") }
$calls=[Collections.Generic.List[object]]::new()
$contexts=[Collections.Generic.List[object]]::new()
$reports=[Collections.Generic.List[object]]::new()
$startProgress=${function:Start-LabActionProgress}
function Start-LabActionProgress {
    param($Phase)
    $context=& $startProgress -Phase $Phase -Now ([datetime]::UtcNow.AddSeconds(-6))
    $context.Enabled=$true; $contexts.Add($context); return $context
}
function Write-Progress {
    param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed)
    $reports.Add([pscustomobject]@{Activity=$Activity;Status=$Status;Detail=$CurrentOperation;Completed=[bool]$Completed})
}
function Get-LabRunState { param($RunId,$StateRoot); return @{scopeId='synthetic-scope'} }
function Get-LabHostToolInvocation { param($Name); return 'Invoke-SyntheticContainerRuntime' }
function Invoke-SyntheticContainerRuntime {
    return (@{Config=@{Labels=@{'sql-server-lab.run-id'=$(if($mode -eq 'ownership'){'foreign'}else{'synthetic-run'});'sql-server-lab.scope-id'='synthetic-scope';'sql-server-lab.instance-id'='primary';'sql-server-lab.container-tool.ids'='sqlpackage'}};State=@{Status='running'}} | ConvertTo-Json -Depth 6 -Compress)
}
function Invoke-LabProgressNativeCommand {
    param($FilePath,$ArgumentList,$Phase,$Progress,$TimeoutSeconds)
    $kind=if($ArgumentList -contains '/Version'){'probe'}elseif($ArgumentList[0] -eq 'cp'){'copy'}elseif($ArgumentList -contains 'rm'){'cleanup'}else{'import'}
    # Persist only the cleanup target and non-sensitive control fields.
    $calls.Add([pscustomobject]@{Kind=$kind;Phase=$Phase;Progress=$Progress;Timeout=$TimeoutSeconds;Target=$(if($kind -eq 'cleanup'){$ArgumentList[-1]}elseif($kind -eq 'copy'){$ArgumentList[-1]}else{''})})
    if($kind -eq 'probe'){return @{ExitCode=0;Output=@($(if($mode -eq 'version'){'1.0.0.0'}else{'170.1.2.3'}))}}
    if($kind -eq 'copy' -and $mode -eq 'copy-throw'){throw 'SYNTHETIC_COPY_INTERRUPTED'}
    if($kind -eq 'copy' -and $mode -eq 'copy-exit'){return @{ExitCode=7;Output=@('synthetic')}}
    if($kind -eq 'cleanup' -and $mode -eq 'cleanup-throw'){throw 'SYNTHETIC_CLEANUP_TIMEOUT'}
    if($kind -eq 'cleanup' -and $mode -in @('cleanup-exit','combined')){return @{ExitCode=9;Output=@()}}
    if($kind -eq 'import' -and $mode -in @('import','combined')){return @{ExitCode=5;Output=@('synthetic password=NeverPersistThis_A7!')}}
    return @{ExitCode=0;Output=@()}
}
function Assert-ContainerTransfer {
    param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "FAIL: $Name"}; Write-Host "PASS: $Name"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-container-progress-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$secret=[Security.SecureString]::new()
foreach($character in 'NeverPersistThis_A7!'.ToCharArray()){$secret.AppendChar($character)}
try {
    $artifact=Join-Path $root 'synthetic.bacpac'; [IO.File]::WriteAllText($artifact,'synthetic test payload')
    foreach($mode in @('success','copy-exit','copy-throw','import','cleanup-exit','cleanup-throw','combined','version','ownership')) {
        $calls.Clear();$contexts.Clear();$reports.Clear();$failure='';$result=$null
        try {$result=Invoke-LabContainerBacpacImport -Provider docker -ContainerName synthetic-container -RunId synthetic-run -InstanceId primary -ArtifactPath $artifact -DatabaseName SyntheticImport -SaPassword $secret -ExpectedRuntimeVersion '170.1.2.3'} catch {$failure=$_.Exception.Message}
        $expected=switch($mode){success{''} copy-exit{'BACPAC_CONTAINER_COPY_FAILED'} copy-throw{'SYNTHETIC_COPY_INTERRUPTED'} import{'BACPAC_IMPORT_FAILED:'} cleanup-exit{'BACPAC_IMPORT_CLEANUP_FAILED'} cleanup-throw{'BACPAC_IMPORT_CLEANUP_FAILED'} combined{'BACPAC_IMPORT_AND_CLEANUP_FAILED: BACPAC_IMPORT_FAILED:'} version{'BACPAC_SQLPACKAGE_VERSION_MISMATCH:'} ownership{'BACPAC_CONTAINER_OWNERSHIP_MISMATCH'}}
        Assert-ContainerTransfer ($failure.StartsWith($expected) -and ($mode -ne 'success' -or $result.Status -eq 'BACPAC_IMPORTED')) "Ergebnisvertrag: $mode"
        Assert-ContainerTransfer (@($contexts | Where-Object {-not $_.Completed}).Count -eq 0) "Reporter abgeschlossen: $mode"
        $cleanup=@($calls | Where-Object Kind -eq cleanup);$copies=@($calls | Where-Object Kind -eq copy)
        if($mode -in @('version','ownership')) {
            Assert-ContainerTransfer ($copies.Count -eq 0 -and $cleanup.Count -eq 0) "Vorbedingung blockiert Mutationen: $mode"
        } else {
            Assert-ContainerTransfer ($cleanup.Count -eq 1 -and $cleanup[0].Target -match '^/tmp/sql-server-lab-bacpac-[0-9a-f]{32}\.bacpac$' -and $copies[0].Target -eq "synthetic-container:$($cleanup[0].Target)" -and $cleanup[0].Timeout -eq 60) "Cleanup begrenzt auf eigene Teilkopie: $mode"
            Assert-ContainerTransfer (@($calls | Where-Object { -not [object]::ReferenceEquals($_.Progress,$contexts[0]) }).Count -eq 0) "Gemeinsamer Reporter: $mode"
        }
        if($mode -like 'copy-*'){Assert-ContainerTransfer (@($calls | Where-Object Kind -eq import).Count -eq 0) "Kein Import nach Kopierfehler: $mode"}
        Assert-ContainerTransfer (($failure+($reports | ConvertTo-Json -Compress)) -notmatch 'NeverPersistThis|SQLSERVERLAB_SA_PASSWORD|synthetic-container|synthetic\.bacpac') "Fortschritt und Fehler ohne Secret oder Pfad: $mode"
    }
}
finally {
    $secret.Dispose()
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-container-progress-*'){throw 'TEST_CONTAINER_TRANSFER_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
