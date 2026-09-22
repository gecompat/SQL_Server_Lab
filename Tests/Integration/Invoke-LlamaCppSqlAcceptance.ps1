#Requires -Version 7.2
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Synthetic test key generated only for this isolated acceptance run; no real credential is embedded.')]
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RuntimeDirectory,[Parameter(Mandatory)][string]$ModelPath,[ValidateRange(1024,65535)][int]$Port=19435)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'LLAMA_WINDOWS_REQUIRED'}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-sql-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$operation=[guid]::NewGuid().ToString('D')
$module=$null;$runtime=$null;$binding=$null;$secret=$null;$key=$null;$cert=$null;$rsa=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke');$held=$false;$arrange=$false;$cleanupFailed=$false;$complete=$false
function Invoke-LlamaSql([string]$Query,[hashtable]$Parameters=@{},[string]$Database='master') {
    & $module {param($Binding,$State,$Op,$Secret,$Query,$Parameters,$Database)
        $actual=Assert-LabTransferBinding -Expected (Get-LabTransferBindingIdentity $Binding) -StateRoot $State -OperationId $Op
        $connection=New-LabRelationalCoreConnection -Binding $actual -DatabaseName $Database -Secret $Secret
        try{$connection.Open();Invoke-LabTransferSqlRows -Connection $connection -Query $Query -Parameters $Parameters -TimeoutSeconds 30}finally{$connection.Dispose()}
    } $binding $state $operation $secret $Query $Parameters $Database
}
try {
    try{$held=$mutex.WaitOne([TimeSpan]::FromMinutes(5))}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'LLAMA_SQL_RUNTIME_LOCKED'}
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider docker -Operation Validate
    if($readiness.Status -ne 'READY'){throw 'LLAMA_SQL_DOCKER_NOT_READY'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $null=New-Item -ItemType Directory -Path $root
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $root -AclObject $acl
    $certPath=Join-Path $root 'cert.pem';$keyPath=Join-Path $root 'key.pem'
    $rsa=[Security.Cryptography.RSA]::Create(2048)
    $csr=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('host.docker.internal');$san.AddIpAddress([Net.IPAddress]::Loopback);$csr.CertificateExtensions.Add($san.Build())
    $csr.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $cert=$csr.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddHours(1))
    [IO.File]::WriteAllText($certPath,$cert.ExportCertificatePem());[IO.File]::WriteAllText($keyPath,$rsa.ExportPkcs8PrivateKeyPem())
    $token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32));$key=ConvertTo-SecureString $token -AsPlainText -Force
    $runtime=Start-SqlServerLabLlamaCppRuntime -RuntimeDirectory $RuntimeDirectory -Backend LlamaCppCuda -Accelerator GPU -ModelPath $ModelPath -ModelName local-embedding -Dimension 768 -Pooling mean -Port $Port -CertificatePath $certPath -PrivateKeyPath $keyPath -TrustedRootPath $certPath -ApiKey $key -StartTimeoutSeconds 60 -LeaseSeconds 900
    Write-Host 'PASS: own HTTPS endpoint, model, dimension and accelerator verified without artifact hashes'
    $unauthorized=& $module {param($Location,$Pin,$Cert)Invoke-LabAiExternalModelHttpTransport -Location $Location -ExpectedServerCertificateSha256 $Pin -TrustedRootCertificate $Cert -Request @{Method='POST';TimeoutSeconds=5;Body=@{model='local-embedding';input='synthetic'}}} $runtime.Location $runtime.ServerCertificateSha256 $cert
    if($unauthorized.StatusCode -ne 401){throw 'LLAMA_AUTH_NOT_ENFORCED'}
    Write-Host 'PASS: endpoint rejects unauthenticated request'
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    & $module {param($Data)Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false|Out-Null} $data
    $arrange=$true
    $lab=& $module {param($State,$Op)
        Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {param($State)
            New-SqlServerLab -Version 2025 -Provider docker -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName llama-sql-acceptance -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='llama-sql-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($State)
    } $state $operation
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $secret=& $module {param($Run,$State)Get-LabRelationalCoreSecret -RunId $Run -StateRoot $State} $lab.RunId $state
    & $module {param($Binding,$State,$Op,$Path)
        $null=Assert-LabTransferBinding -Expected (Get-LabTransferBindingIdentity $Binding) -StateRoot $State -OperationId $Op
        $destination='/var/opt/mssql/security/ca-certificates'
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('exec','--user','0',$Binding.ContainerId,'mkdir','-p',$destination)
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('cp',$Path,($Binding.ContainerId+':'+$destination+'/sql-lab-llama.pem'))
        $null=Invoke-LabTransferNative -Provider docker -Arguments @('exec','--user','0',$Binding.ContainerId,'chmod','0644',($destination+'/sql-lab-llama.pem'))
    } $binding $state $operation $certPath
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    $null=Invoke-LlamaSql "IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'VERSION',1; EXEC sp_configure 'external rest endpoint enabled',1; RECONFIGURE; CREATE DATABASE LlamaFixture;"
    $endpoint="https://host.docker.internal:$Port/v1/embeddings"
    $query=@"
DECLARE @ddl nvarchar(max)=N'CREATE MASTER KEY ENCRYPTION BY PASSWORD='+QUOTENAME(@password,''''); EXEC(@ddl);
SET @ddl=N'CREATE DATABASE SCOPED CREDENTIAL '+QUOTENAME(@endpoint)+N' WITH IDENTITY=''HTTPEndpointHeaders'', SECRET='+QUOTENAME(@secret,''''); EXEC(@ddl);
SET @ddl=N'CREATE EXTERNAL MODEL LocalEmbedding WITH (LOCATION='+QUOTENAME(@endpoint,'''')+N', API_FORMAT=''OpenAI'', MODEL_TYPE=EMBEDDINGS, MODEL=''local-embedding'', CREDENTIAL='+QUOTENAME(@endpoint)+N', PARAMETERS='' {"sql_rest_options":{"retry_count":0}}'');'; EXEC(@ddl);
CREATE TABLE dbo.Documents(Id int PRIMARY KEY, Embedding vector(768));

"@
    $null=Invoke-LlamaSql -Database LlamaFixture -Query $query -Parameters @{password=([guid]::NewGuid().ToString('N')+'!aA9');endpoint=$endpoint;secret=(@{Authorization=('Bearer '+$token)}|ConvertTo-Json -Compress)}
    $null=Invoke-LlamaSql -Database LlamaFixture -Query "INSERT dbo.Documents SELECT 1,AI_GENERATE_EMBEDDINGS(N'search_document: SQL Server backups protect test databases.' USE MODEL LocalEmbedding);"
    foreach($phase in @('BeforeRestart','AfterRestart')) {
        if($phase -eq 'AfterRestart'){$null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false}
        $rows=@(Invoke-LlamaSql -Database LlamaFixture -Query "DECLARE @v vector(768)=AI_GENERATE_EMBEDDINGS(N'search_query: SQL Server backups' USE MODEL LocalEmbedding); SELECT CAST(@v AS varchar(max)) AS VectorJson, VECTOR_DISTANCE('cosine',Embedding,@v) AS Distance FROM dbo.Documents WHERE Id=1;")
        if($rows.Count -ne 1){throw 'LLAMA_SQL_ROWS'}
        $vector=@($rows[0].VectorJson|ConvertFrom-Json)
        if($vector.Count -ne 768 -or [double]::IsNaN([double]$rows[0].Distance) -or [double]::IsInfinity([double]$rows[0].Distance)){throw 'LLAMA_SQL_VECTOR'}
        & $module {param($Vector)foreach($v in $Vector){if($null -eq $v -or -not (Test-LabAiExternalModelNumericValue $v)){throw 'LLAMA_SQL_NUMERIC'}}} $vector
        Write-Host "PASS: SQL External Model finite VECTOR(768) and distance $phase"
    }
    $complete=$true
}
finally {
    if($runtime){try{$cleanup=Stop-SqlServerLabLlamaCppRuntime $runtime.OperationId;if($cleanup.Status -ne 'CLEANUP_SUCCEEDED'){throw 'cleanup'}}catch{$cleanupFailed=$true}}
    if($module -and $arrange){try{
        $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
        if($owned){
            if(-not $binding){$binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation}
            $null=& $module {param($Binding,$State,$Op)Assert-LabTransferBinding -Expected (Get-LabTransferBindingIdentity $Binding) -StateRoot $State -OperationId $Op} $binding $state $operation
            $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
            if($removed.Status -ne 'REMOVED'){throw 'cleanup'}
        }
        if($binding){& $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding}
    }catch{$cleanupFailed=$true}}
    foreach($disposable in @($secret,$key,$cert,$rsa)){if($disposable){$disposable.Dispose()}};$token=$null
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module -Force};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)) {
        $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-llama-sql-*'){throw 'CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    if($cleanupFailed){throw 'LLAMA_SQL_RECOVERY_REQUIRED'}
}
if(-not $complete){throw 'LLAMA_SQL_ACCEPTANCE_INCOMPLETE'}
Write-Host 'LLAMA SQL ACCEPTANCE: PASS; Docker SQL 2025; SQLrestart; CLEANUP_SUCCEEDED'
