#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft echte SQL-2025-Preview-Vektorindizes auf einem eigenen Container-Run.
.DESCRIPTION
    Abnahmeversion 1.0 bindet DiskANN mit TOP_N und Indexversion kleiner 3.
    Erstellt 4096 synthetische 32-dimensionale Vektoren, vergleicht vier
    Suchfälle mit exakter Suche und prüft Index/Daten nach Containerneustart.
    Preview ist kein Ausschlussgrund. Neue Indexsemantik verlangt eine eigene
    Testversion. Der Ergebnisstatus wird erst nach verifiziertem Cleanup ausgegeben.
.PARAMETER Provider
    Getrennt nachzuweisender Containerprovider docker oder podman.
.EXAMPLE
    ./Tests/Integration/Invoke-AiVectorIndexAcceptance.ps1 -Provider docker
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot=Join-Path $PSScriptRoot 'Fixtures/VectorIndex/1.0'
$token=[guid]::NewGuid().ToString('N')
$stateRoot=Join-Path $repoRoot ".artifacts/test-state/ann-$Provider-$token"
$database='AnnFixture_'+$token.Substring(0,12)
$lab=$null; $module=$null; $runtime=$null; $failure=$null; $cleanupFailure=$null
$credential=$null; $report=$null; $mutex=$null; $acquired=$false

function Invoke-AnnQuery {
    param([Parameter(Mandatory)][string]$Query,[string]$Database='master',[int]$TimeoutSeconds=300)
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source']="127.0.0.1,$($lab.Instances[0].Port)"
    $builder['Initial Catalog']=$Database; $builder['Encrypt']=$true; $builder['TrustServerCertificate']=$true
    $builder['Connect Timeout']=15; $builder['Pooling']=$false
    $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString,$credential)
    $command=$null
    try {
        $connection.Open(); $command=$connection.CreateCommand()
        $command.CommandText=$Query; $command.CommandTimeout=$TimeoutSeconds
        return $command.ExecuteScalar()
    }
    finally {if($command){$command.Dispose()};$connection.Dispose()}
}

try {
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if([string]$readiness.Status -notin @('READY','READY_WITH_WARNINGS')){throw 'ANN_PROVIDER_NOT_READY'}
    $resolved=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolved.Available){throw 'ANN_PROVIDER_TOOL_UNAVAILABLE'}
    $runtime=[string]$resolved.Invocation
    $mutexName=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    $acquired=$mutex.WaitOne([timespan]::FromMinutes(10))
    if(-not $acquired){throw 'ANN_RUNTIME_LOCK_TIMEOUT'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $bytes=[byte[]]::new(24); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $plain='Aa1!'+[Convert]::ToBase64String($bytes); $password=[SecureString]::new()
    foreach($character in $plain.ToCharArray()){$password.AppendChar($character)}
    $password.MakeReadOnly(); [Array]::Clear($bytes,0,$bytes.Length); $plain=$null
    $credential=[Data.SqlClient.SqlCredential]::new('sa',$password)
    $lab=New-SqlServerLab -Version 2025 -Provider $Provider -SaPassword $password `
        -StateRoot $stateRoot -NonInteractive -SkipAssessment
    if(-not $lab -or [string]$lab.State -ne 'Running'){throw 'ANN_SQL_PROVISION_FAILED'}
    $null=Invoke-AnnQuery -Query "CREATE DATABASE [$database];"
    $setup=Invoke-AnnQuery -Database $database -Query (Get-Content -LiteralPath (Join-Path $fixtureRoot 'setup.sql') -Raw) -TimeoutSeconds 600
    $build=$setup | ConvertFrom-Json
    $query=Get-Content -LiteralPath (Join-Path $fixtureRoot 'assert.sql') -Raw
    $before=(Invoke-AnnQuery -Database $database -Query $query) | ConvertFrom-Json
    if($before.QueryCount -ne 4 -or $before.MinimumRecallAt10 -lt 0.8){throw 'ANN_RESULT_INVALID'}
    $stopped=Stop-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Confirm:$false
    if($stopped.Status -ne 'STOPPED' -or $stopped.Action -ne 'STOPPED'){throw 'ANN_STOP_FAILED'}
    $started=Start-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -TimeoutSeconds 180
    if($started.Status -ne 'RUNNING' -or $started.Action -ne 'STARTED'){throw 'ANN_START_FAILED'}
    $after=(Invoke-AnnQuery -Database $database -Query $query) | ConvertFrom-Json
    if($after.QueryCount -ne 4 -or $after.MinimumRecallAt10 -lt 0.8 -or
        $after.IndexVersion -ne $before.IndexVersion){throw 'ANN_RESTART_RESULT_INVALID'}
    $report=[pscustomobject]@{
        Contract='SqlServerLab.AiVectorIndexAcceptance/1.0';Provider=$Provider;SqlBuild=$build.SqlBuild
        IndexVersion=$build.IndexVersion;CompatibilityLevel=$build.CompatibilityLevel;Preview=$true
        Rows=$build.RowCount;Dimension=32;BuildMicroseconds=$build.BuildMicroseconds
        BeforeRestart=$before;AfterRestart=$after;Cleanup='PENDING';Status='PENDING'
        FixtureHashes=@(Get-ChildItem -LiteralPath $fixtureRoot -File | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{Name=$_.Name;Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
    }
}
catch {$failure=$_}
finally {
    if($module){
        try {
            $runs=@(& $module {param($Root) Get-LabActiveRuns -StateRoot $Root} $stateRoot)
            foreach($run in $runs){
                Remove-SqlServerLab -RunId $run.runId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null
                $remaining=@(& $runtime ps -a -q --filter "label=sql-server-lab.run-id=$($run.runId)" 2>$null | Where-Object {$_})
                if($LASTEXITCODE -ne 0 -or $remaining.Count){throw 'ANN_CONTAINER_CLEANUP_NOT_VERIFIED'}
            }
        }
        catch {$cleanupFailure=$_}
    }
    $credential=$null; if($password){$password.Dispose()}
    if($acquired){$mutex.ReleaseMutex()}; if($mutex){$mutex.Dispose()}
}
if($failure){Write-Error -ErrorRecord $failure -ErrorAction Continue}
if($cleanupFailure){Write-Error 'ANN_RECOVERY_REQUIRED' -ErrorAction Continue}
if($failure -or $cleanupFailure){exit 1}
$report.Cleanup='PASS';$report.Status='PASS';$report
