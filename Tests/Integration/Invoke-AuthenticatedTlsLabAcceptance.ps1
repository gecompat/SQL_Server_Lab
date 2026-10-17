#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)][string]$ControllerId,
    [Parameter(Mandatory)][string]$LocationId,[Parameter(Mandatory)][string]$CandidateId,
    [Parameter(Mandatory)][string]$EvidenceDirectory,[switch]$Execute,[switch]$KeepLab)
$ErrorActionPreference='Stop'
if(-not $Execute){throw 'TLS_ACCEPTANCE_EXECUTE_REQUIRED: creates one own Docker SQL2025 CU9 lab; no trust import.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$tool=& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name docker
if(-not $tool.Available){throw 'TLS_ACCEPTANCE_DOCKER_UNAVAILABLE'}
$ready=& (Join-Path $repo 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider docker -Operation Inspect
if($ready.Status -cne 'READY'){throw 'TLS_ACCEPTANCE_READINESS_BLOCKED'}
$evidence=& $module {param($p) Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($p))} $EvidenceDirectory
if(Test-Path -LiteralPath $evidence){throw 'TLS_ACCEPTANCE_NEW_EVIDENCE_REQUIRED'}
$null=New-Item -ItemType Directory -Path $evidence
$before=@{}
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'State/runs') -Filter connection-info.json -Recurse -File -ErrorAction SilentlyContinue)){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash}
foreach($relative in @('.sql-server-lab-root.json','Catalog/storage-locations.json')){$p=Join-Path $DataRoot $relative;$before[$p]=(Get-FileHash -LiteralPath $p).Hash}
$hostAutoStart=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SQL_Server_Lab/autostart'
if(Test-Path -LiteralPath $hostAutoStart){foreach($file in @(Get-ChildItem -LiteralPath $hostAutoStart -File)){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash}}
$podmanRunBefore=Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'io.podman_desktop.PodmanDesktop' -ErrorAction SilentlyContinue
$results=[Collections.Generic.List[object]]::new();$lab=$null;$failure=$null;$cleanup='NOT_REQUIRED'
try{
    $lab=New-SqlServerLab -Version '2025-CU9' -Provider docker -Profile compact -Cpu 2 -MemoryMB 2048 -GenerateSaPassword -NonInteractive -AutoStart off `
        -DataRoot $DataRoot -TlsControllerId $ControllerId -TlsLocationId $LocationId -TlsCandidateId $CandidateId -TrustServerCertificate:$false
    $results.Add(@{Case='OWN_LAB_TWO_STRICT_STACKS';Status='PASS'})
    $returned=[Data.SqlClient.SqlConnectionStringBuilder]::new($lab.Instances[0].ConnectionString)
    if(-not $returned.Encrypt -or $returned.TrustServerCertificate){throw 'TLS_ACCEPTANCE_PUBLIC_RESULT_FLAGS_INVALID'}
    $export=Export-SqlServerLabTestEnvironment -TrustServerCertificate:$false -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot -OutputDirectory (Join-Path $lab.StateRoot 'qualified-export')
    $results.Add(@{Case='FRESH_QUALIFIED_FALSE_EXPORT';Status='PASS'})
    & $module {
        param($export,$lab)
        if(-not (Test-LabTlsQualifiedExport $export.JsonPath $lab.StateRoot $lab.RunId primary)){throw 'TLS_ACCEPTANCE_EXPORT_VERIFICATION_FAILED'}
        $document=Get-Content -LiteralPath $export.JsonPath -Raw|ConvertFrom-Json -Depth 12 -DateKind String
        $entry=$document.environments[0]
        if($entry.encrypt -isnot [bool] -or $entry.encrypt -ne $true -or $entry.trustServerCertificate -isnot [bool] -or $entry.trustServerCertificate -ne $false){throw 'TLS_ACCEPTANCE_EXPORT_FLAGS_INVALID'}
        $connection=[Data.SqlClient.SqlConnection]::new($entry.connectionString)
        try{
            $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=10
            try{$command.CommandText="SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID";if($command.ExecuteScalar() -cne 'TRUE'){throw 'TLS_ACCEPTANCE_EXPORT_SQL_ENCRYPTION_INVALID'}}finally{$command.Dispose()}
        }finally{$connection.Dispose()}
        $password=[securestring]::new();foreach($character in $entry.password.ToCharArray()){$password.AppendChar($character)};$password.MakeReadOnly()
        $bound=Get-LabTlsOwnBinding $lab.StateRoot $lab.RunId primary
        $null=Invoke-LabTlsStrictSqlcmd $entry.port $password $bound.Authority.Client
        $settings=Get-LabSqlConnectionSettings $entry.connectionString
        if($settings.Encrypt -ne $true -or $settings.TrustServerCertificate -ne $false){throw 'TLS_ACCEPTANCE_CONNECTION_SETTINGS_INVALID'}
    } $export $lab
    $results.Add(@{Case='EXPORTED_CREDENTIALS_BOTH_REAL_STACKS';Status='PASS'})
    $previousState=$env:SQL_SERVER_LAB_STATE
    try{
        $env:SQL_SERVER_LAB_STATE=$lab.StateRoot
        $workflow=Get-SqlServerLabWorkflow
        $target=@($workflow.ActiveLabs|Where-Object RunId -CEQ $lab.RunId)
        if($target.Count -ne 1 -or $target[0].Instances[0].ConnectionSettings.Encrypt -ne $true -or
            $target[0].Instances[0].ConnectionSettings.TrustServerCertificate -ne $false){throw 'TLS_ACCEPTANCE_GUI_WORKFLOW_FLAGS_INVALID'}
        & $module {param($lab)
            $strings=@(Get-LabRunConnectionStrings -RunId $lab.RunId -StateRoot $lab.StateRoot)
            if($strings.Count -ne 1 -or (Format-LabSqlConnectionSettings $strings[0].Value) -cne 'Encrypt=True;TrustServerCertificate=False'){throw 'TLS_ACCEPTANCE_CLI_FLAGS_INVALID'}
        } $lab
    }finally{$env:SQL_SERVER_LAB_STATE=$previousState}
    $results.Add(@{Case='ACTUAL_CLI_AND_GUI_WORKFLOW_FLAGS';Status='PASS'})
    & $module {
        param($lab,$export)
        $path=Join-Path $lab.StateRoot 'authenticated-tls-lab.json';$bytes=[IO.File]::ReadAllBytes($path)
        try{
            $record=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -Depth 12 -DateKind String
            $record.StartedAt='stale-start'
            [IO.File]::WriteAllBytes($path,(ConvertTo-LabTlsRegistryWriterBytes $record))
            $blocked=$false;try{$null=Test-LabAuthenticatedTlsEnvironment $lab.RunId primary $lab.StateRoot}catch{$blocked=$true}
            if(-not $blocked){throw 'TLS_ACCEPTANCE_STALE_BINDING_NOT_REJECTED'}
        }finally{[IO.File]::WriteAllBytes($path,$bytes)}
        $exportBytes=[IO.File]::ReadAllBytes($export.JsonPath)
        try{
            $doc=[Text.Encoding]::UTF8.GetString($exportBytes)|ConvertFrom-Json -Depth 12 -DateKind String
            $doc.environments[0].trustServerCertificate=$true
            [IO.File]::WriteAllBytes($export.JsonPath,(ConvertTo-LabTlsRegistryWriterBytes $doc))
            if(Test-LabTlsQualifiedExport $export.JsonPath $lab.StateRoot $lab.RunId primary){throw 'TLS_ACCEPTANCE_TAMPER_NOT_REJECTED'}
        }finally{[IO.File]::WriteAllBytes($export.JsonPath,$exportBytes)}
        if(-not (Test-LabTlsQualifiedExport $export.JsonPath $lab.StateRoot $lab.RunId primary)){throw 'TLS_ACCEPTANCE_RESTORATION_FAILED'}
    } $lab $export
    $results.Add(@{Case='STALE_BINDING_AND_EXPORT_TAMPER_REJECTED_RESTORED';Status='PASS'})
    [IO.File]::WriteAllText((Join-Path $evidence 'lab.private.json'),($lab|ConvertTo-Json -Depth 15))
    [IO.File]::WriteAllText((Join-Path $evidence 'export.private.json'),($export|ConvertTo-Json -Depth 15))
}catch{$failure=$_;[IO.File]::WriteAllText((Join-Path $evidence 'failure.private.txt'),($_|Out-String))}
finally{
    if($lab -and ($failure -or -not $KeepLab)){
        try{
            $removed=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $lab.StateRoot -Force -Confirm:$false
            if($removed.Status -cne 'REMOVED'){throw 'TLS_ACCEPTANCE_CLEANUP_UNCONFIRMED'}
            $remaining=& $tool.Invocation ps -aq --filter "label=sql-server-lab.run-id=$($lab.RunId)"
            if($LASTEXITCODE -ne 0 -or $remaining){throw 'TLS_ACCEPTANCE_CONTAINER_REMAINS'}
            $cleanup='PASS'
        }catch{$cleanup='RECOVERY_REQUIRED';if(-not $failure){$failure=$_}}
    }elseif($lab){$cleanup='INTENTIONALLY_PERSISTENT_OWN_LAB'}
    foreach($p in $before.Keys){if(-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p).Hash -cne $before[$p]){
        $results.Add(@{Case='PREEXISTING_FILE_PRESERVATION';Status='FAIL'});if(-not $failure){$failure='TLS_ACCEPTANCE_PREEXISTING_DRIFT'};break
    }}
    $podmanRunAfter=Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'io.podman_desktop.PodmanDesktop' -ErrorAction SilentlyContinue
    if($podmanRunBefore -cne $podmanRunAfter){$results.Add(@{Case='HOST_AUTOSTART_PRESERVATION';Status='FAIL'});if(-not $failure){$failure='TLS_ACCEPTANCE_HOST_AUTOSTART_DRIFT'}}
    $summary=[pscustomobject]@{Status=$(if($failure){'FAIL'}else{'PASS'});Cases=$results;Cleanup=$cleanup;Default='Encrypt=True;TrustServerCertificate=True';Scope='Windows current user / Docker / SQL2025 CU9'}
    [IO.File]::WriteAllText((Join-Path $evidence 'summary.private.json'),($summary|ConvertTo-Json -Depth 6))
    $summary|Select-Object Status,Cleanup,Scope
}
if($failure){throw 'TLS_ACCEPTANCE_FAILED: see local private evidence.'}
