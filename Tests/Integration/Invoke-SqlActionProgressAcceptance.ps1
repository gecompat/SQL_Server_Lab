#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft SQL-Heartbeat, Unicode, Fehler und gemeinsame Verbindung an einem isolierten SQL-2025-Run.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Nur zufaellig erzeugte synthetische Credentials fuer den eigenen isolierten Test-Run.')]
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resolution=& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider
if(-not $resolution.Available) { throw 'SQL_PROGRESS_ACCEPTANCE_RUNTIME_UNRESOLVED' }
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$assessment=Test-SqlServerLabPrerequisite -Provider $Provider
if($assessment.Status -ne 'RESOURCE_OK') { throw 'SQL_PROGRESS_ACCEPTANCE_RESOURCE_NOT_READY' }
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sql-acceptance-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$password=[guid]::NewGuid().ToString('N')+'aA1!'
$credential=ConvertTo-SecureString $password -AsPlainText -Force
$password=$null; $lab=$null
try {
    $lab=New-SqlServerLab -Provider $Provider -Version 2025 -SaPassword $credential -SkipAssessment
    if($lab.State -ne 'Running' -or $lab.Instances.Count -ne 1) { throw 'SQL_PROGRESS_ACCEPTANCE_RUN_NOT_READY' }
    $result=& $module {
        param($Port,$Credential,$Root)
        $records=[Collections.Generic.List[object]]::new()
        $startFunction=${function:Start-LabActionProgress}
        function Start-LabActionProgress {
            param($Phase)
            $context=& $startFunction -Phase $Phase
            $context.Enabled=$true
            $context
        }
        function Write-Progress {
            param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed)
            $records.Add([pscustomobject]@{Time=[datetime]::UtcNow;Completed=[bool]$Completed;Text="$Status $CurrentOperation"})
        }
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential)
        try { $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        try {
            $output=Invoke-SqlQuery -Port $Port -SaPlain $plain -Query "SET NOCOUNT ON; WAITFOR DELAY '00:00:06'; SELECT 17;" -TimeoutSeconds 15
            $finished=[datetime]::UtcNow
            $heartbeat=@($records | Where-Object {-not $_.Completed -and $_.Time -lt $finished}).Count -gt 0
            $secretFree=@($records | Where-Object {$_.Text.Contains($plain) -or $_.Text.Contains('WAITFOR')}).Count -eq 0
            $sqlCorrect=(($output -join "`n") -match '(?m)^\s*17\s*$')
            $unicode=Invoke-SqlQuery -Port $Port -SaPlain $plain -Query 'SET NOCOUNT ON; SELECT N''Grüße "SQL"'';'
            $unicodeCorrect=(($unicode -join "`n") -match 'Grüße "SQL"')
            $rejected=$false
            try { Invoke-SqlQuery -Port $Port -SaPlain $plain -Query "THROW 50000, 'synthetic failure', 1;" | Out-Null } catch { $rejected=$_.Exception.Message -match 'synthetic failure' }
            $scriptPath=Join-Path $Root 'session.sql'
            [IO.File]::WriteAllText($scriptPath,"CREATE TABLE #SessionProbe (Id int);`nGO`nINSERT INTO #SessionProbe VALUES (1);`nGO`nIF (SELECT COUNT(*) FROM #SessionProbe) <> 1 THROW 50000, 'session lost', 1;")
            $session=Invoke-LabSqlScript -ScriptPath $scriptPath -Port $Port -SaPassword $Credential -KeepConnection
            [IO.File]::WriteAllText($scriptPath,"WAITFOR DELAY '00:00:20';")
            $timeout=Invoke-LabSqlScript -ScriptPath $scriptPath -Port $Port -SaPassword $Credential -KeepConnection -TimeoutSeconds 1
            [pscustomobject]@{Heartbeat=$heartbeat;SecretFree=$secretFree;Output=$sqlCorrect;Unicode=$unicodeCorrect;SqlError=$rejected;Session=$session.Success;Timeout=(-not $timeout.Success);Completed=$records[-1].Completed}
        }
        finally { $plain=$null }
    } ([int]$lab.Instances[0].Port) $credential $root
    foreach($property in $result.PSObject.Properties) {
        if(-not $property.Value) { throw "SQL_PROGRESS_ACCEPTANCE_FAILED: $($property.Name)" }
        Write-Host "PASS: SQL-Progress $($property.Name)"
    }
}
finally {
    try {
        if($lab) {
            $cleanup=Remove-SqlServerLab -RunId $lab.RunId -Force
            if($cleanup.Status -ne 'REMOVED') { throw 'SQL_PROGRESS_ACCEPTANCE_CLEANUP_REQUIRED' }
        }
    }
    finally {
        $credential.Dispose()
        $resolved=[IO.Path]::GetFullPath($root)
        $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-sql-acceptance-*') { throw 'SQL_PROGRESS_ACCEPTANCE_CLEANUP_SCOPE_INVALID' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host 'PASS: Isolierter SQL-Progress-Run und Cleanup'
