#Requires -Version 7.2
<#
.SYNOPSIS
    Isolierte Docker-Abnahme für SQL-seitige Embeddings über eigenen HTTPS-Gateway.
.DESCRIPTION
    Benötigt vorhandenes embeddinggemma:latest am Host. Eigener SQL-2025-Run,
    eigene CA ausschließlich im SQL-Volume, frische negative TLS-Handshakes,
    exaktes Retrieval vor/nach SQLrestart und vollständiges eigenes Cleanup.
    Kein Modell-Pull, Cloudaufruf oder Hosttrust-/Firewallwechsel.
#>
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$LocalPort=11434,[switch]$RuntimeMutexAlreadyHeld)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-sql-https-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$gatewayRoot=Join-Path $root 'gateway'
$operation=[guid]::NewGuid().ToString('D');$module=$null;$binding=$null;$bridge=$null;$secret=$null;$receipt=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$complete=$false;$cleanupFailed=$false;$mutex=$null;$held=$false;$arrangeStarted=$false
$gatewayStartAttempted=$false;$gatewayStartCleaned=$false
$diagnosticRoot=Join-Path $repoRoot '.artifacts/test-runs/ai-sql-https-bridge'
$diagnosticPath=Join-Path $diagnosticRoot ('sql-'+$operation+'.json')
function Assert-Bridge {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "AI_SQL_HTTPS_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
function Invoke-BridgeSql {
    param([string]$Query,[hashtable]$Parameters=@{},[string]$Database='master',[ValidateSet('Setup','Credentials','Model','Embed','Query','NegativeTls','NegativeHttp','NegativeAuth','NegativePayload')][string]$Phase='Setup')
    & $module {
        param($Binding,$State,$Operation,$Secret,$Query,$Parameters,$Database,$DiagnosticPath,$Phase)
        $expected=Get-LabTransferBindingIdentity $Binding
        $actual=Assert-LabTransferBinding -Expected $expected -StateRoot $State -OperationId $Operation
        if($actual.Provider -cne 'docker'){throw 'AI_SQL_HTTPS_DOCKER_REQUIRED'}
        $connection=New-LabRelationalCoreConnection -Binding $actual -DatabaseName $Database -Secret $Secret
        try{$connection.Open();Invoke-LabTransferSqlRows -Connection $connection -Query $Query -Parameters $Parameters -TimeoutSeconds 45}
        catch{
            $errorValue=$_.Exception.GetBaseException()
            $details=[ordered]@{OperationId=$Operation;Phase=$Phase;Number=$null;Class=$null;State=$null}
            if($errorValue -is [Data.SqlClient.SqlException]){$details.Number=$errorValue.Number;$details.Class=$errorValue.Class;$details.State=$errorValue.State}
            try{Assert-LabAiPersistentPath $DiagnosticPath;Write-LabArtifactJsonAtomic -Path $DiagnosticPath -InputObject $details}catch{}
            throw 'AI_SQL_HTTPS_SQL_FAILED'
        }finally{$connection.Dispose()}
    } $binding $state $operation $secret $Query $Parameters $Database $diagnosticPath $Phase
}
function Read-BridgeReceipt {
    & $module {param($Path)Assert-LabAiPersistentPath $Path;$json=Get-Content -LiteralPath $Path -Raw
        if(-not($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-sql-https-bridge-receipt.schema.json') -ErrorAction Stop)){throw 'receipt'}
        $json|ConvertFrom-Json -Depth 8
    } (Join-Path $gatewayRoot 'gateway.json')
}
function Test-BridgeSqlRejected {
    param([string]$Query,[hashtable]$Parameters=@{},[string]$Phase='NegativeTls')
    try{$null=Invoke-BridgeSql -Query $Query -Parameters $Parameters -Database BridgeFixture -Phase $Phase;return $false}catch{if($_.Exception.Message -cne 'AI_SQL_HTTPS_SQL_FAILED'){throw};return $true}
}
function Invoke-BridgeRanking {
    param($Fixture)
    foreach($question in $Fixture.Questions){
        $rows=@(Invoke-BridgeSql -Database BridgeFixture -Phase Query -Query @'
DECLARE @query vector(768)=AI_GENERATE_EMBEDDINGS(@text USE MODEL LabEmbedding);
SELECT Id, VECTOR_DISTANCE('cosine',Embedding,@query) AS Distance
FROM dbo.Documents ORDER BY Distance,Id;
'@ -Parameters @{text=$question.Content})
        Assert-Bridge ($rows.Count -eq 3 -and $rows[0].Id -ceq $question.Id -and @($rows|Where-Object {[double]::IsNaN([double]$_.Distance) -or [double]::IsInfinity([double]$_.Distance)}).Count -eq 0) ('SQL-Retrieval trifft '+$question.Id)
    }
}
try{
    if(-not $RuntimeMutexAlreadyHeld){$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));try{$held=$mutex.WaitOne([TimeSpan]::FromMinutes(30))}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'AI_SQL_HTTPS_RUNTIME_LOCKED'}}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name docker)[0]
    Assert-Bridge ([bool]$resolution.Available) 'Dockerwerkzeug verfügbar'
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    & $module {param($Path)Assert-LabAiPersistentPath $Path} $diagnosticRoot
    $null=New-Item -ItemType Directory -Path $diagnosticRoot -Force
    $model=& $module {param($Port)$plan=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $Port;Get-LabAiHostModelBinding -Plan $plan} $LocalPort
    $tags=& $module {param($Port)Get-LabAiPlanKey @( (Invoke-LabAiHostMetadata -Port $Port -Path /api/tags).models|Sort-Object name -CaseSensitive)} $LocalPort
    $null=New-Item -ItemType Directory -Path $gatewayRoot -Force
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    & $module {param($Data)Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false|Out-Null} $data
    $token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $gatewayStartAttempted=$true
    try{$bridge=& $module {param($Root,$Op,$Token,$Binding,$Port)Start-LabAiSqlHttpsBridge -Root $Root -OperationId $Op -Token $Token -Binding $Binding -LocalPort $Port} $gatewayRoot $operation $token $model $LocalPort}
    catch{if($_.Exception.Message -ceq 'AI_SQL_HTTPS_GATEWAY_START_FAILED_CLEANED'){$gatewayStartCleaned=$true};throw}
    $arrangeStarted=$true
    $lab=& $module {param($State,$Op)
        Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {param($State)
            New-SqlServerLab -Version 2025 -Provider docker -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName ai-sql-https-acceptance -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='sql-https-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($State)
    } $state $operation
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $secret=& $module {param($Run,$State)Get-LabRelationalCoreSecret -RunId $Run -StateRoot $State} $lab.RunId $state
    Assert-Bridge ($binding.Provider -ceq 'docker') 'Eigener SQL-2025-Docker-Run gebunden'
    $caPath=Join-Path $gatewayRoot 'public-ca.pem'
    $ca=[Convert]::FromBase64String($bridge.Ready.CaBase64)
    [IO.File]::WriteAllText($caPath,"-----BEGIN CERTIFICATE-----`n"+[Convert]::ToBase64String($ca,[Base64FormattingOptions]::InsertLineBreaks)+"`n-----END CERTIFICATE-----`n")
    & $module {param($Binding,$State,$Op,$Path)
        $null=Assert-LabTransferBinding -Expected (Get-LabTransferBindingIdentity $Binding) -StateRoot $State -OperationId $Op
        $destination='/var/opt/mssql/security/ca-certificates'
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('exec','--user','0',$Binding.ContainerId,'mkdir','-p',$destination)
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('cp',$Path,($Binding.ContainerId+':'+$destination+'/sql-lab-bridge.pem'))
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('exec','--user','0',$Binding.ContainerId,'chmod','0644',($destination+'/sql-lab-bridge.pem'))
    } $binding $state $operation $caPath
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    $null=Invoke-BridgeSql -Query "IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'VERSION',1; EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE; IF DB_ID('BridgeFixture') IS NOT NULL THROW 51000,'COLLISION',1; CREATE DATABASE BridgeFixture;"
    $null=Invoke-BridgeSql -Database BridgeFixture -Query "DECLARE @ddl nvarchar(max)=N'CREATE MASTER KEY ENCRYPTION BY PASSWORD='+QUOTENAME(@password,''''); EXEC(@ddl); CREATE TABLE dbo.Documents(Id varchar(32) NOT NULL PRIMARY KEY,Content nvarchar(400) NOT NULL,Embedding vector(768) NOT NULL);" -Parameters @{password=([guid]::NewGuid().ToString('N')+'!aA9')}
    $endpoints=@{}
    foreach($kind in @('Good','WrongSan','WrongCa')){
        $endpoint='https://host.docker.internal:'+([int]$bridge.Ready.Ports.$kind)+'/api/embed';$endpoints[$kind]=$endpoint
        $null=Invoke-BridgeSql -Database BridgeFixture -Phase Credentials -Query @'
DECLARE @ddl nvarchar(max)=N'CREATE DATABASE SCOPED CREDENTIAL '+QUOTENAME(@endpoint)+N' WITH IDENTITY=''HTTPEndpointHeaders'', SECRET='+QUOTENAME(@secret,''''); EXEC(@ddl);
'@ -Parameters @{endpoint=$endpoint;secret=(@{'X-SqlLab-Token'=$token}|ConvertTo-Json -Compress)}
    }
    $null=Invoke-BridgeSql -Database BridgeFixture -Phase Model -Query ("CREATE EXTERNAL MODEL LabEmbedding WITH (LOCATION='$($endpoints.Good)',API_FORMAT='Ollama',MODEL_TYPE=EMBEDDINGS,MODEL='embeddinggemma:latest',CREDENTIAL=[$($endpoints.Good)],PARAMETERS='{`"sql_rest_options`":{`"retry_count`":0}}');")
    $fixture=& $module {Get-LabAiSqlHttpsFixture}
    foreach($document in $fixture.Documents){$null=Invoke-BridgeSql -Database BridgeFixture -Phase Embed -Query 'INSERT dbo.Documents(Id,Content,Embedding) SELECT @id,@text,AI_GENERATE_EMBEDDINGS(@text USE MODEL LabEmbedding);' -Parameters @{id=$document.Id;text=$document.Content}}
    $stored=@(Invoke-BridgeSql -Database BridgeFixture -Query 'SELECT Id,Content,CAST(Embedding AS varchar(max)) AS VectorJson FROM dbo.Documents ORDER BY Id;')
    foreach($row in $stored){
        $expected=@($fixture.Documents|Where-Object Id -CEQ $row.Id)
        Assert-Bridge ($expected.Count -eq 1 -and $row.Content -ceq $expected[0].Content) 'SQL speichert exakte synthetische Inhalte'
        & $module {param($Json)$null=ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,@($Json|ConvertFrom-Json))}} $row.VectorJson
    }
    Assert-Bridge ($stored.Count -eq 3) 'Drei SQL-seitig erzeugte endliche VECTOR(768) gespeichert'
    Invoke-BridgeRanking $fixture
    $before=Read-BridgeReceipt
    foreach($kind in @('WrongCa','WrongSan')){
        $tlsBefore=Read-BridgeReceipt
        $rejected=Test-BridgeSqlRejected -Query 'DECLARE @response nvarchar(max); EXEC sp_invoke_external_rest_endpoint @url=@url,@method=''POST'',@credential=@url,@payload=@body,@timeout=10,@retry_count=0,@response=@response OUTPUT;' -Parameters @{url=$endpoints[$kind];body=(@{model='embeddinggemma:latest';input=@($fixture.Questions[0].Content)}|ConvertTo-Json -Compress)}
        Assert-Bridge $rejected ('SQL lehnt frischen TLS-Handshake ab: '+$kind)
        Start-Sleep -Milliseconds 100
        $tlsAfter=Read-BridgeReceipt
        Assert-Bridge ($tlsAfter.tlsRejected -eq $tlsBefore.tlsRejected+1 -and $tlsAfter.negativeTlsConnections -eq $tlsBefore.negativeTlsConnections+1 -and $tlsAfter.requests -eq $tlsBefore.requests -and $tlsAfter.upstreamRequests -eq $tlsBefore.upstreamRequests) ('Handshake vor HTTP tatsächlich abgewiesen: '+$kind)
    }
    $http='http://host.docker.internal:'+([int]$bridge.Ready.Ports.Good)+'/api/embed'
    Assert-Bridge (Test-BridgeSqlRejected -Phase NegativeHttp -Query 'EXEC sp_invoke_external_rest_endpoint @url=@url,@method=''POST'',@payload=N''{}'',@timeout=5,@retry_count=0;' -Parameters @{url=$http}) 'SQL lehnt HTTP-Downgrade ab'
    # Fehlende Authentisierung und falsches Modell müssen vor jedem Ollama-Payload blockieren.
    $response=@(Invoke-BridgeSql -Database BridgeFixture -Phase NegativeAuth -Query 'DECLARE @response nvarchar(max),@ret int; EXEC @ret=sp_invoke_external_rest_endpoint @url=@url,@method=''POST'',@payload=@body,@timeout=10,@retry_count=0,@response=@response OUTPUT; SELECT @ret AS Code;' -Parameters @{url=$endpoints.Good;body='{"model":"embeddinggemma:latest","input":"synthetic"}'})
    Assert-Bridge ($response.Count -eq 1 -and [int]$response[0].Code -ne 0) 'Gateway lehnt fehlenden Authheader ab'
    $response=@(Invoke-BridgeSql -Database BridgeFixture -Phase NegativePayload -Query 'DECLARE @response nvarchar(max),@ret int; EXEC @ret=sp_invoke_external_rest_endpoint @url=@url,@method=''POST'',@credential=@url,@payload=@body,@timeout=10,@retry_count=0,@response=@response OUTPUT; SELECT @ret AS Code;' -Parameters @{url=$endpoints.Good;body='{"model":"other","input":"synthetic"}'})
    Assert-Bridge ($response.Count -eq 1 -and [int]$response[0].Code -ne 0) 'Gateway lehnt fremdes Modell ab'
    Start-Sleep -Milliseconds 100
    $after=Read-BridgeReceipt
    Assert-Bridge ($after.negativeTlsConnections -eq $before.negativeTlsConnections+2 -and $after.rejected -ge $before.rejected+2 -and $after.upstreamRequests -eq $before.upstreamRequests) 'Negative Handshakes/Requests belegt ohne zusätzliche Embeddings'
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    Invoke-BridgeRanking $fixture
    $tagsAfter=& $module {param($Port)Get-LabAiPlanKey @((Invoke-LabAiHostMetadata -Port $Port -Path /api/tags).models|Sort-Object name -CaseSensitive)} $LocalPort
    Assert-Bridge ($tagsAfter -ceq $tags) 'Hostmodellinventar unverändert'
    $complete=$true
}catch{Write-Warning 'AI_SQL_HTTPS_ACCEPTANCE_FAILED; eigener Cleanup folgt'}
finally{
    if($gatewayStartAttempted -and -not $bridge -and -not $gatewayStartCleaned){$cleanupFailed=$true;Write-Warning 'AI_SQL_HTTPS_GATEWAY_START_RECOVERY_REQUIRED'}
    if($bridge){try{$receipt=& $module {param($Bridge)Stop-LabAiSqlHttpsBridge $Bridge} $bridge}catch{$cleanupFailed=$true;Write-Warning 'AI_SQL_HTTPS_GATEWAY_RECOVERY_REQUIRED'}}
    if($secret){$secret.Dispose()};$token=$null
    if($module -and $arrangeStarted){
        try{
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
            if($owned){
                if(-not $binding){$binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation}
                $null=& $module {param($Binding,$State,$Op)Assert-LabTransferBinding -Expected (Get-LabTransferBindingIdentity $Binding) -StateRoot $State -OperationId $Op} $binding $state $operation
                $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                if($removed.Status -ne 'REMOVED'){throw 'cleanup'}
            }
            if($binding){& $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding}
        }catch{$cleanupFailed=$true;Write-Warning 'AI_SQL_HTTPS_RUN_RECOVERY_REQUIRED'}
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module -Force}
    if($mutex){if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-ai-sql-https-*'){throw 'AI_SQL_HTTPS_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed -or -not $complete -or -not $receipt -or $receipt.successfulEmbeddings -ne 7 -or $receipt.upstreamRequests -ne 7){throw 'AI_SQL_HTTPS_ACCEPTANCE_INCOMPLETE'}
Write-Host 'AI SQL HTTPS BRIDGE ACCEPTANCE: PASS (Docker; SQL External Model; 7 Embeddings; TLS negatives; SQLrestart; own cleanup)'
