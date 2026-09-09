#Requires -Version 7.2
<#
.SYNOPSIS Prueft direkten Fortschritt mit synthetischer Uhr, Loopback und Kindprozess.
.DESCRIPTION Keine Provider-, SQL-, Hostkonfigurations- oder Internetmutation.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/Common.ps1')
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
$records = [System.Collections.Generic.List[object]]::new()
function Write-Progress {
    param($Id, $Activity, $Status, $CurrentOperation, $PercentComplete, [switch]$Completed)
    $records.Add([pscustomobject]@{ Id=$Id; Activity=$Activity; Status=$Status; Detail=$CurrentOperation; Percent=$PercentComplete; Completed=[bool]$Completed })
}
function Assert-Progress {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
function Write-LabProviderLog { param($Provider,$Phase,$Command,$Output,$ExitCode,$RunId,$StateRoot); 'synthetic-log' }
$nativeFailure = Invoke-LabProviderOperation -Provider docker -Phase image-build -NativeResult -Action {
    [pscustomobject]@{ ExitCode=7; Output=@('synthetic-output') }
}
Assert-Progress (-not $nativeFailure.Succeeded -and $nativeFailure.ExitCode -eq 7 -and $nativeFailure.Output[0] -eq 'synthetic-output') 'Providerlog bewahrt strukturierten nativen Fehler'
$invalidResultRejected = $false
try { Invoke-LabProviderOperation -Provider docker -Phase image-build -NativeResult -Action { } | Out-Null } catch { $invalidResultRejected=$_.Exception.Message -eq 'LAB_NATIVE_RESULT_INVALID' }
Assert-Progress $invalidResultRejected 'Fehlendes natives Ergebnis kann keinen Erfolg erzeugen'
$origin = [datetime]'2026-01-01T00:00:00Z'
$progress = Start-LabActionProgress -Phase Download -Now $origin
$progress.Enabled = $true
Update-LabActionProgress -Progress $progress -Now $origin.AddSeconds(4)
Assert-Progress ($records.Count -eq 0) 'Kurze Aktionen bleiben still'
Update-LabActionProgress -Progress $progress -Now $origin.AddSeconds(5) -CompletedBytes 256 -TotalBytes 1024
Assert-Progress ($records.Count -eq 1 -and $records[0].Percent -eq 25 -and $records[0].Detail -match '256 Bytes / 1024 Bytes') 'Messbarer Bytefortschritt ab fuenf Sekunden'
Update-LabActionProgress -Progress $progress -Now $origin.AddMilliseconds(5500)
Assert-Progress ($records.Count -eq 1) 'Updates sind gedrosselt'
Update-LabActionProgress -Progress $progress -Phase Hash -Now $origin.AddMilliseconds(5500)
Assert-Progress ($records.Count -eq 2 -and $records[1].Percent -eq -1) 'Phasenwechsel ohne erfundene Prozentwerte'
$progress.Phase = 'secret=synthetic-password; C:\synthetic\private; https://example.invalid'
Update-LabActionProgress -Progress $progress -Now $origin.AddSeconds(7)
Assert-Progress (($records | ConvertTo-Json -Depth 3) -notmatch 'synthetic-password|private|example.invalid') 'Unbekannte Phasen geben keine Schutzwerte aus'
Stop-LabActionProgress -Progress $progress
Stop-LabActionProgress -Progress $progress
Update-LabActionProgress -Progress $progress -Now $origin.AddSeconds(9)
Assert-Progress (@($records | Where-Object Completed).Count -eq 1 -and $records.Count -eq 4) 'Abschluss ist idempotent und stoppt weitere Updates'

# Erzwungene Interaktivitaet nur im Testszenario; der produktive Check bleibt
# bei umgeleiteter Ausgabe stumm. Die reale Uhr prueft Aktualisierung VOR Ende.
$originalStart = ${function:Start-LabActionProgress}
function Start-LabActionProgress {
    param($Phase, [datetime]$Now = [datetime]::UtcNow)
    $context = & $originalStart -Phase $Phase -Now $Now
    $context.Enabled = $true
    $context
}
. (Join-Path $repoRoot 'Private/SqlReadiness.ps1')
function Write-LabInfo { param($Message) }
function Write-LabSuccess { param($Message) }
function sqlcmd { $global:LASTEXITCODE = 0; '17' }
$readyContexts = [System.Collections.Generic.List[object]]::new()
function Start-LabActionProgress {
    param($Phase, [datetime]$Now = [datetime]::UtcNow)
    $context = & $originalStart -Phase $Phase -Now $Now.AddSeconds(-6)
    $context.Enabled = $true
    $readyContexts.Add($context)
    $context
}
$records.Clear()
$syntheticCredential = [securestring]::new()
$ready = Wait-SqlReady -Port 1433 -SaPassword $syntheticCredential -ExpectedMajorVersion 17 -StabilitySeconds 1 -PollIntervalMilliseconds 100 -TimeoutSeconds 3
Assert-Progress ($ready.Ready -and $ready.MajorVersion -eq 17 -and $records.Count -ge 2 -and $readyContexts[-1].Completed) 'SQL-Readiness meldet aus ihrer echten Poll-Schleife und bewahrt das Resultat'
function sqlcmd { throw 'SYNTHETIC_SQL_FAILURE' }
try { Wait-SqlReady -Port 1433 -SaPassword $syntheticCredential | Out-Null } catch { }
Assert-Progress ($readyContexts[-1].Completed) 'SQL-Fehler beendet den Reporter im finally'
$syntheticCredential.Dispose()
Remove-Item Function:sqlcmd
function Start-LabActionProgress {
    param($Phase, [datetime]$Now = [datetime]::UtcNow)
    $context = & $originalStart -Phase $Phase -Now $Now
    $context.Enabled = $true
    $context
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-progress-' + [guid]::NewGuid().ToString('N'))
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$server = [powershell]::Create()
$null = New-Item -ItemType Directory -Path $tempRoot
try {
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $serverCode = {
        param($Listener)
        $ErrorActionPreference = 'Stop'
        $retry = 0
        while ($true) {
            # Pending-Poll vermeidet einen nicht unterbrechbaren nativen
            # Accept-Aufruf beim Stop des isolierten Test-Runspaces.
            if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
            $connection = $Listener.AcceptTcpClient()
            try {
                $stream = $connection.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                $request = $reader.ReadLine()
                while ($reader.ReadLine()) { }
                $status = '200 OK'; $extra = ''; $body = 'synthetic-payload'
                if ($request -match ' /redirect ') { $status='302 Found'; $extra="Location: /ok`r`n"; $body='' }
                if ($request -match ' /missing ') { $status='404 Not Found'; $body='' }
                if ($request -match ' /retry ' -and $retry++ -eq 0) { $status='503 Service Unavailable'; $body='' }
                $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`n${extra}Content-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($header,0,$header.Length)
                if ($body) {
                    $payload = [Text.Encoding]::ASCII.GetBytes($body)
                    $stream.Write($payload,0,4)
                    if ($request -match ' /slow ') { Start-Sleep -Seconds 6 }
                    $stream.Write($payload,4,$payload.Length-4)
                }
            }
            finally { $connection.Dispose() }
        }
    }
    $null = $server.AddScript($serverCode).AddArgument($listener)
    $serverRun = $server.BeginInvoke()
    $target = Join-Path $tempRoot 'payload'
    $records.Clear()
    $downloadOutput = @(Save-LabProgressDownload -Uri "http://127.0.0.1:$port/slow" -OutFile $target -TimeoutSec 15)
    Assert-Progress ($downloadOutput.Count -eq 0 -and [IO.File]::ReadAllText($target) -eq 'synthetic-payload') 'HTTP-Transfer bewahrt Payload und leeren Erfolgsstream'
    Assert-Progress (@($records | Where-Object { -not $_.Completed -and $_.Percent -gt 0 -and $_.Percent -lt 100 }).Count -gt 0) 'Echter Download zeigt Zwischenstand vor Transferende'
    Assert-Progress ($records[-1].Completed) 'Download beendet seinen Reporter'
    $rejected = $false
    try { Save-LabProgressDownload -Uri "http://127.0.0.1:$port/redirect" -OutFile $target -MaximumRedirection 0 } catch { $rejected=$true }
    Assert-Progress $rejected 'CU-Download akzeptiert keinen Redirect'
    Save-LabProgressDownload -Uri "http://127.0.0.1:$port/redirect" -OutFile $target
    Assert-Progress ([IO.File]::ReadAllText($target) -eq 'synthetic-payload') 'Freigegebener Redirect liefert unveraenderte Bytes'
    Save-LabProgressDownload -Uri "http://127.0.0.1:$port/retry" -OutFile $target -MaximumRetryCount 1 -RetryIntervalSec 1
    Assert-Progress ([IO.File]::ReadAllText($target) -eq 'synthetic-payload') 'Begrenzter Retry publiziert nur die erfolgreiche Payload'
    $rejected = $false
    try { Save-LabProgressDownload -Uri "http://127.0.0.1:$port/missing" -OutFile $target } catch { $rejected=$true }
    Assert-Progress $rejected 'HTTP-Fehler bleibt Fehler'
    $records.Clear()
    $pwsh = (Get-Process -Id $PID).Path
    $native = Invoke-LabProgressNativeCommand -FilePath $pwsh -ArgumentList @('-NoProfile','-Command', 'Start-Sleep -Seconds 6; [Console]::Out.WriteLine("synthetic-output"); [Console]::Error.WriteLine("synthetic-error"); exit 7')
    Assert-Progress ($native.ExitCode -eq 7 -and $native.Output.Count -eq 2) 'Native stdout, stderr und Exitcode bleiben erhalten'
    Assert-Progress ($records.Count -ge 2 -and $records[-1].Completed) 'Host-Heartbeat waehrend stillen nativen Prozesses'
    $rejected = $false
    try { Invoke-LabProgressNativeCommand -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -TimeoutSeconds 1 | Out-Null } catch { $rejected=$_.Exception.Message -eq 'LAB_NATIVE_OPERATION_TIMEOUT' }
    Assert-Progress $rejected 'Nativer Timeout beendet den eigenen Prozess'
}
finally {
    $listener.Stop()
    if ($serverRun) { $server.Stop() }
    $server.Dispose()
    # Ausschliesslich den oben erzeugten, zufaelligen Testroot entfernen.
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBoundary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($tempBoundary, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTemp) -notlike 'sql-lab-progress-*') { throw 'TEST_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
