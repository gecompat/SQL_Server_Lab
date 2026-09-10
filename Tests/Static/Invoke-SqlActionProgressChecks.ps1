#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft SQL-Argumente, Timeouts, Dateibindung und Fehler ohne SQL-Runtime.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
. (Join-Path $repoRoot 'Private/SqlReadiness.ps1')
$calls=[Collections.Generic.List[object]]::new()
$behavior=[pscustomobject]@{ExitCode=0;Output=@('synthetic-result');Failure='';Available=$true}
$commandResolver=Get-Command Get-Command
function Get-Command {
    [CmdletBinding()]
    param($Name,$CommandType)
    if ($Name -eq 'sqlcmd') { if ($behavior.Available) { [pscustomobject]@{Source='synthetic-sqlcmd'} }; return }
    & $commandResolver @PSBoundParameters
}
function Invoke-LabProgressNativeCommand {
    param($FilePath,$ArgumentList,$Phase,$Progress,$TimeoutSeconds)
    $inputIndex=[array]::IndexOf($ArgumentList,'-i')
    $inputPath=if($inputIndex -ge 0) { $ArgumentList[$inputIndex+1] } else { $null }
    $outputPath=$ArgumentList[[array]::IndexOf($ArgumentList,'-o')+1]
    $calls.Add([pscustomobject]@{
        Args=@($ArgumentList);Phase=$Phase;Timeout=$TimeoutSeconds;Progress=$Progress;InputPath=$inputPath;OutputPath=$outputPath
        InputBytes=$(if($inputPath) { [IO.File]::ReadAllBytes($inputPath) } else { $null })
    })
    if($behavior.Failure) { throw $behavior.Failure }
    [IO.File]::WriteAllLines($outputPath,[string[]]$behavior.Output,[Text.Encoding]::Unicode)
    [pscustomobject]@{ExitCode=$behavior.ExitCode;Output=@()}
}
function Assert-SqlProgress {
    param([bool]$Condition,[string]$Name)
    if(-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sql-progress-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$credential=[securestring]::new()
$credential.AppendChar([char]83)
try {
    $query="SELECT N'Gruesse';"
    $output=@(Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query $query -TimeoutSeconds 7)
    $call=$calls[-1]
    Assert-SqlProgress ($output.Count -eq 1 -and $output[0] -eq 'synthetic-result' -and $call.Args[[array]::IndexOf($call.Args,'-Q')+1] -ceq $query) 'SQL-Query und Erfolgsoutput bleiben unveraendert'
    Assert-SqlProgress ($call.Args[[array]::IndexOf($call.Args,'-t')+1] -eq '7' -and $call.Timeout -eq 86400) 'Statement-Timeout bleibt getrennt von der Prozessdeadline'
    Assert-SqlProgress ($call.Args -contains '-u' -and -not [IO.File]::Exists($call.OutputPath)) 'Unicode-Ergebnisdatei wird nach Erfolg entfernt'
    $behavior.ExitCode=9
    $rejected=$false
    try { Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query $query | Out-Null } catch { $rejected=$_.Exception.Message -like 'SQL-Query fehlgeschlagen:*' }
    Assert-SqlProgress $rejected 'Nativer SQL-Exitcode bleibt ein Fehler'
    $behavior.ExitCode=0; $behavior.Output=@('Msg 50000, Level 16, State 1')
    $rejected=$false
    try { Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query $query | Out-Null } catch { $rejected=$true }
    Assert-SqlProgress $rejected 'SQL-Fehlerschwere wird auch bei Exitcode null erkannt'
    $behavior.Output=@('Sqlcmd: Error: synthetic driver: Query timeout expired.')
    $rejected=$false
    try { Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query $query | Out-Null } catch { $rejected=$true }
    Assert-SqlProgress $rejected 'sqlcmd-Timeout bleibt auch bei Exitcode null ein Fehler'
    $behavior.Output=@('Timeout expired')
    $rejected=$false
    try { Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query $query | Out-Null } catch { $rejected=$true }
    Assert-SqlProgress $rejected 'ODBC-Timeout ohne Fehlerpraefix und mit Exitcode null bleibt ein Fehler'
    $behavior.Output=@('synthetic-result')
    $scriptPath=Join-Path $root 'script.sql'
    $scriptText="SELECT N'Gruesse';`nGO`nSELECT 2;"
    [IO.File]::WriteAllText($scriptPath,$scriptText)
    $before=$calls.Count
    $result=Invoke-LabSqlScript -ScriptPath $scriptPath -Port 1433 -SaPassword $credential -KeepConnection -TimeoutSeconds 11
    $call=$calls[-1]
    Assert-SqlProgress ($result.Success -and $result.Batches -eq 2 -and $calls.Count -eq $before+1 -and $call.Args -contains '-X1' -and $call.Args -contains '-x') 'GO-Batches bleiben in einem Prozess mit deaktivierter sqlcmd-Skriptebene'
    Assert-SqlProgress ($call.InputBytes[0] -eq 239 -and $call.InputBytes[1] -eq 187 -and $call.InputBytes[2] -eq 191 -and -not [IO.File]::Exists($call.InputPath)) 'UTF-8-BOM-Datei wird nach Erfolg entfernt'
    $before=$calls.Count
    $result=Invoke-LabSqlScript -ScriptPath $scriptPath -Port 1433 -SaPassword $credential
    Assert-SqlProgress ($result.Success -and $calls.Count -eq $before+2 -and [object]::ReferenceEquals($calls[-1].Progress,$calls[-2].Progress) -and $calls[-1].Progress.Completed) 'Mehrere Skriptbatches teilen sich einen abschliessend bereinigten Reporter'
    $behavior.Failure='SYNTHETIC_PROCESS_FAILURE'
    $result=Invoke-LabSqlScript -ScriptPath $scriptPath -Port 1433 -SaPassword $credential -KeepConnection
    Assert-SqlProgress (-not $result.Success -and -not [IO.File]::Exists($calls[-1].InputPath)) 'Skriptfehler entfernt die eigene Eingabedatei'
    if($IsWindows) {
        $rejected=$false
        try { Invoke-SqlQuery -Port 1433 -SaPlain 'synthetic-only' -Query ('SELECT 1; --'+('x'*7100)) | Out-Null } catch { $rejected=$true }
        Assert-SqlProgress ($rejected -and $calls[-1].Args -contains '-X1' -and -not [IO.File]::Exists($calls[-1].InputPath)) 'Grosse Windows-Query bewahrt Dateigrenze und Fehler-Cleanup'
    }
    $behavior.Failure='LAB_NATIVE_OPERATION_TIMEOUT'
    $context=[pscustomobject]@{Completed=$false}
    $result=Invoke-LabSqlcmdProgress -ArgumentList @('-Q','SELECT 1;') -ProcessTimeoutSeconds 3 -Phase SqlReadiness -Progress $context
    Assert-SqlProgress ($result.ExitCode -ne 0 -and $result.Output[0] -eq 'SQLCMD_OPERATION_TIMEOUT' -and $calls[-1].Timeout -eq 3 -and $calls[-1].Progress -eq $context) 'Readiness nutzt ihre Restdeadline und erhaelt einen sanitisierten Timeout'
    $behavior.Available=$false; $behavior.Failure=''
    $before=$calls.Count; $rejected=$false
    try { Invoke-LabSqlcmdProgress -ArgumentList @('-Q','SELECT 1;') | Out-Null } catch { $rejected=$true }
    Assert-SqlProgress ($rejected -and $calls.Count -eq $before) 'Fehlendes sqlcmd startet keinen Prozess'
    Assert-SqlProgress (@($calls | Where-Object {[IO.File]::Exists($_.OutputPath)}).Count -eq 0) 'Ergebnisdateien bleiben auch nach Fehler oder Timeout nicht zurueck'
}
finally {
    $credential.Dispose()
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-sql-progress-*') { throw 'TEST_SQL_PROGRESS_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
