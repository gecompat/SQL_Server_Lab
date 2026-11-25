#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0;$module=$null;$upstreamJob=$null;$session=$null;$portGuard=$null
$testRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-session-test-'+[guid]::NewGuid().ToString('N'))));$null=[IO.Directory]::CreateDirectory($testRoot);$disposable=[Collections.Generic.List[IDisposable]]::new()
function New-TestCa {$rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa);$r=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Session Test CA',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$r.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true));$r.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign,$true));$c=$r.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(2));$script:disposable.Add($c);$c}
function New-TestLeaf($Ca){$rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa);$r=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=host.docker.internal',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$r.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true));$r.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,[bool]$true));$eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$r.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true));$san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('host.docker.internal');$r.CertificateExtensions.Add($san.Build());$serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial);$public=$r.Create($Ca,[datetimeoffset]::UtcNow.AddHours(-1),[datetimeoffset]::UtcNow.AddDays(1),$serial);$script:disposable.Add($public);$c=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public,$rsa);$script:disposable.Add($c);[pscustomobject]@{Certificate=$c;PrivateKey=$rsa}}
function Get-FreePort {$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}}
function New-TestSecureString([string]$Value){$secure=[SecureString]::new();foreach($character in $Value.ToCharArray()){$secure.AppendChar($character)};$secure.MakeReadOnly();$secure}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
try {
    $runtime=Join-Path $testRoot 'runtime.bin';$model=Join-Path $testRoot 'model.gguf';$cert=Join-Path $testRoot 'cert.pem';$key=Join-Path $testRoot 'key.pem';$caPath=Join-Path $testRoot 'ca.pem';[IO.File]::WriteAllText($runtime,'synthetic runtime');[IO.File]::WriteAllText($model,'synthetic model')
    $ca=New-TestCa;$leaf=New-TestLeaf $ca;[IO.File]::WriteAllText($cert,$leaf.Certificate.ExportCertificatePem());[IO.File]::WriteAllText($key,$leaf.PrivateKey.ExportPkcs8PrivateKeyPem());[IO.File]::WriteAllText($caPath,$ca.ExportCertificatePem())
    $upstreamPort=Get-FreePort;$gatewayPort=Get-FreePort;while($gatewayPort -eq $upstreamPort){$gatewayPort=Get-FreePort};$ready=Join-Path $testRoot 'upstream.ready';$stop=Join-Path $testRoot 'upstream.stop'
    $server={param($port,$ready,$stop,$model)
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$listener.Start(8);[IO.File]::WriteAllText($ready,'ready')
        try{while(-not(Test-Path -LiteralPath $stop)){if(-not $listener.Pending()){Start-Sleep -Milliseconds 20;continue};$client=$listener.AcceptTcpClient();$stream=$client.GetStream();try{$bytes=[Collections.Generic.List[byte]]::new();$match=0;while($bytes.Count -lt 16384 -and $match -lt 4){$v=$stream.ReadByte();if($v -lt 0){break};$bytes.Add([byte]$v);$want=@(13,10,13,10)[$match];if($v -eq $want){$match++}elseif($v -eq 13){$match=1}else{$match=0}};$header=[Text.Encoding]::ASCII.GetString($bytes.ToArray());$length=0;if($header -match '(?im)^Content-Length:\s*([0-9]+)\s*$'){$length=[int]$Matches[1]};$body=[byte[]]::new($length);$offset=0;while($offset -lt $length){$read=$stream.Read($body,$offset,$length-$offset);if($read -le 0){break};$offset+=$read};$response=@{object='list';model=$model;data=@(@{object='embedding';index=0;embedding=@(0.1,0.2,0.3)})}|ConvertTo-Json -Depth 8 -Compress;$payload=[Text.Encoding]::UTF8.GetBytes($response);$head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n");$stream.Write($head);$stream.Write($payload);$stream.Flush()}finally{$stream.Dispose();$client.Dispose()}}}finally{$listener.Stop()}}
    $upstreamJob=Start-Job -ScriptBlock $server -ArgumentList $upstreamPort,$ready,$stop,'bound-model';$deadline=[datetime]::UtcNow.AddSeconds(15);while(-not(Test-Path $ready)){if($upstreamJob.State -ne 'Running' -or [datetime]::UtcNow -gt $deadline){throw 'synthetic upstream failed'};Start-Sleep -Milliseconds 50}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru;$stateRoot=Join-Path $testRoot 'state'
    $consumers=@([pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='a';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedA';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'},[pscustomobject]@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='b';DatabaseId='44444444-4444-4444-8444-444444444444';ExternalModelName='SharedB';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_B'})
    $planParameters=@{GatewayId='shared-session';Location="https://host.docker.internal:$gatewayPort/v1/embeddings";UpstreamBackend='LlamaCppCuda';UpstreamLocation="http://127.0.0.1:$upstreamPort/v1/embeddings";RuntimeModel='bound-model';Dimension=3;InputProfile='raw';ModelSha256=(Get-FileHash $model -Algorithm SHA256).Hash.ToLowerInvariant();RuntimeSha256=(Get-FileHash $runtime -Algorithm SHA256).Hash.ToLowerInvariant();ServerCertificateSha256=$leaf.Certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();CertificateAuthoritySha256=$ca.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();Consumer=$consumers}
    $plan=Get-SqlServerLabAiSharedGatewayPlan @planParameters
    $statusSchema=Join-Path $repoRoot 'Schemas/ai-shared-gateway-status.schema.json'
    $unregistered=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Status unterscheidet fehlende Registrierung ohne Mutation' ($unregistered.Status -ceq 'NOT_REGISTERED' -and $unregistered.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_NOT_REGISTERED' -and -not(Test-Path -LiteralPath $stateRoot) -and ($unregistered|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $null=$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false
    $stopped=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Status erkennt revalidierte Registrierung ohne Listener' ($stopped.Status -ceq 'REGISTERED_STOPPED' -and $stopped.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_REGISTERED_STOPPED' -and ($stopped|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $otherGatewayParameters=$planParameters.Clone()
    $otherGatewayParameters.GatewayId='another-shared-session'
    $otherGatewayPlan=Get-SqlServerLabAiSharedGatewayPlan @otherGatewayParameters
    $otherStateRoot=Join-Path $testRoot 'other-state'
    $storageInputs=@{RuntimePath=$runtime;ModelPath=$model;CertificatePath=$cert;PrivateKeyPath=$key;CertificateAuthorityPath=$caPath}
    $null=$otherGatewayPlan|Register-SqlServerLabAiSharedGatewayStorage @storageInputs -StateRoot $stateRoot -Confirm:$false
    $null=$plan|Register-SqlServerLabAiSharedGatewayStorage @storageInputs -StateRoot $otherStateRoot -Confirm:$false
    $keyA=New-TestSecureString 'AAAAAAAAAAAAAAAAAAAAAAAA';$keyB=New-TestSecureString 'BBBBBBBBBBBBBBBBBBBBBBBB';$keys=@{SQL_SERVER_LAB_SECRET_SHARED_AI_A=$keyA;SQL_SERVER_LAB_SECRET_SHARED_AI_B=$keyB}
    Add-CheckResult 'WhatIf startet keine Session' ($null -eq ($plan|Start-SqlServerLabAiSharedGatewaySession -ApiKeyByReference $keys -StateRoot $stateRoot -WhatIf))
    $session=$plan|Start-SqlServerLabAiSharedGatewaySession -ApiKeyByReference $keys -StateRoot $stateRoot -StartTimeoutSeconds 20 -LeaseSeconds 60 -Confirm:$false
    Add-CheckResult 'Start liefert schema-validiertes ownergebundenes Receipt' ($session.Status -ceq 'SESSION_ENDPOINT_VERIFIED' -and ($session|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-session-receipt.schema.json')))
    $running=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Status bindet eigene laufende Session an Prozess und Listener' ($running.Status -ceq 'OWNER_SESSION_RUNNING' -and $running.OperationId -ceq $session.OperationId -and $running.ProcessId -gt 0 -and ($running|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $otherGateway=$otherGatewayPlan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Gleicher Port eines anderen Gateways ist kein eigener Listener' (
        $otherGateway.Status -ceq 'RECOVERY_REQUIRED' -and $otherGateway.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_PORT_OCCUPIED_UNKNOWN' -and
        -not $otherGateway.PSObject.Properties['OperationId'] -and -not $otherGateway.PSObject.Properties['ProcessId'] -and
        ($otherGateway|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $otherRoot=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $otherStateRoot
    Add-CheckResult 'Gleicher Plan in einem anderen StateRoot ist kein eigener Listener' (
        $otherRoot.Status -ceq 'RECOVERY_REQUIRED' -and $otherRoot.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_PORT_OCCUPIED_UNKNOWN' -and
        -not $otherRoot.PSObject.Properties['OperationId'] -and -not $otherRoot.PSObject.Properties['ProcessId'] -and
        ($otherRoot|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $operationRoot=& $module {param($id)$script:AiSharedGatewaySessions[$id].OperationRoot} $session.OperationId
    $processBinding=& $module {param($id)$owned=$script:AiSharedGatewaySessions[$id];$receipt=Get-Content -LiteralPath $owned.ReceiptPath -Raw|ConvertFrom-Json;[bool]($receipt.OperationId -ceq $id -and [int]$receipt.ProcessId -eq $owned.Worker.Id -and $receipt.OwnerNonce -ceq $owned.OwnerNonce -and $receipt.OwnerNonce -cmatch '^[a-f0-9]{64}$')} $session.OperationId
    Add-CheckResult 'Workerreceipt bindet Operation, PID und plattformneutralen Owner-Nonce' $processBinding
    Add-CheckResult 'Worker löscht beide temporären Schlüsseldateien nach dem Einlesen' (-not(Test-Path (Join-Path $operationRoot 'consumer-keys.json')) -and -not(Test-Path (Join-Path $operationRoot 'upstream-key.txt')))
    & $module {param($p,$k)Invoke-LabAiSharedGatewaySessionProbe -Plan $p -ApiKey $k -TimeoutSeconds 5} $plan $keyB
    Add-CheckResult 'Zweiter geplanter Consumer authentifiziert sich am selben Endpoint' $true
    $auth=& $module {Test-LabAiSharedGatewaySessionBearer -Authorization 'Bearer BBBBBBBBBBBBBBBBBBBBBBBB' -Secrets @('AAAAAAAAAAAAAAAAAAAAAAAA','BBBBBBBBBBBBBBBBBBBBBBBB')}
    $badAuth=& $module {Test-LabAiSharedGatewaySessionBearer -Authorization 'Bearer CCCCCCCCCCCCCCCCCCCCCCCC' -Secrets @('AAAAAAAAAAAAAAAAAAAAAAAA','BBBBBBBBBBBBBBBBBBBBBBBB')}
    Add-CheckResult 'Mehrfachauthentifizierung akzeptiert nur einen gebundenen Schlüssel' ($auth -and -not $badAuth)
    $json=$session|ConvertTo-Json -Depth 20
    Add-CheckResult 'Receipt enthält weder Secret noch lokalen Pfad' ($json -notmatch 'AAAAAAAA|BBBBBBBB' -and $json -notmatch [regex]::Escape($testRoot))
    Add-CheckResult 'Unvollständige Schlüsselzuordnung scheitert geschlossen' (Reject {& $module {param($p,$m)Resolve-LabAiSharedGatewaySessionKeys $p $m} $plan @{SQL_SERVER_LAB_SECRET_SHARED_AI_A=$keyA}} 'AI_SHARED_GATEWAY_SESSION_API_KEY_SET_MISMATCH')
    Add-CheckResult 'Doppelte Consumer-Schlüssel werden abgewiesen' (Reject {& $module {param($p,$m)Resolve-LabAiSharedGatewaySessionKeys $p $m} $plan @{SQL_SERVER_LAB_SECRET_SHARED_AI_A=$keyA;SQL_SERVER_LAB_SECRET_SHARED_AI_B=$keyA}} 'AI_SHARED_GATEWAY_SESSION_API_KEY_DUPLICATE')
    $cleanup=Stop-SqlServerLabAiSharedGatewaySession -OperationId $session.OperationId -Confirm:$false;$session=$null
    Add-CheckResult 'Stop bestätigt Prozess-/Listenercleanup und entfernt Operationszustand' ($cleanup.Status -ceq 'CLEANUP_SUCCEEDED' -and -not(Test-Path $operationRoot))
    $guided = & $module {
        param($FixturePlan,$FixtureRoot,$FixtureKeyA,$FixtureKeyB)
        $fixture = [pscustomobject]@{ Confirmed=$false; Inputs=[Collections.Generic.Queue[object]]::new(); Prompts=[Collections.Generic.List[bool]]::new()
            Messages=[Collections.Generic.List[string]]::new(); ChooseForeign=$false; StopItems=@() }
        function Get-LabStateRoot { $FixtureRoot }
        function Read-LabConfirm { param($Prompt,$Default) $fixture.Confirmed }
        function Read-LabConsoleTextInput {
            param($Prompt,$Default,[switch]$AsSecureString)
            $fixture.Prompts.Add($AsSecureString.IsPresent)
            $fixture.Inputs.Dequeue()
        }
        function Write-LabInfo { param($Message) $fixture.Messages.Add($Message) }
        function Write-LabWarning { param($Message) $fixture.Messages.Add($Message) }
        function Wait-LabConsoleAcknowledgement {}
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) $Items }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Subtitle,$Items)
            $fixture.StopItems = @($Items.Id)
            $id = if ($fixture.ChooseForeign) { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } else { $Items[0].Id }
            [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$id}}
        }

        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value='60'})
        Invoke-LabAiSharedGatewaySessionStartInteractive -Plan $FixturePlan
        $startDeclined = $fixture.Prompts.Count -eq 1 -and -not $script:AiSharedGatewaySessions.Count

        $fixture.Confirmed = $true
        $fixture.Prompts.Clear()
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value='60'})
        $firstKey = $FixtureKeyA.Copy()
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$firstKey})
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Cancelled';Value=$null})
        Invoke-LabAiSharedGatewaySessionStartInteractive -Plan $FixturePlan
        $firstKeyDisposed = $false
        try { $firstKey.Copy().Dispose() } catch { $firstKeyDisposed = $_.Exception.InnerException -is [ObjectDisposedException] }
        $keyEntryCancelled = $firstKeyDisposed -and -not $script:AiSharedGatewaySessions.Count

        $fixture.Prompts.Clear()
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value='60'})
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$FixtureKeyA.Copy()})
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$FixtureKeyB.Copy()})
        $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=[Security.SecureString]::new()})
        $stopEntry = @(Show-LabHostModelsMenu | Where-Object Id -CEQ 'AiSharedGatewaySessionStop')
        if ($stopEntry.Count -ne 1) { throw 'GUIDED_GATEWAY_STOP_NOT_IN_HOST_MENU' }
        try {
            Invoke-LabAiSharedGatewaySessionStartInteractive -Plan $FixturePlan
            $status = Get-SqlServerLabAiSharedGatewayStatus -Plan $FixturePlan -StateRoot $FixtureRoot
            $id = $status.OperationId
            $startVerified = $status.Status -ceq 'OWNER_SESSION_RUNNING' -and
                $fixture.Messages[-1] -match ('Gateway-Endpunkt bestätigt.*' + [regex]::Escape([string]$id))
            $secureInputs = ($fixture.Prompts -join ',') -ceq 'False,True,True,True'

            $fixture.ChooseForeign = $true
            Invoke-LabMenuAction -ActionName $stopEntry[0].Id
            $listedOwnerOnly = ($fixture.StopItems -join ',') -ceq "$id,back" -and $script:AiSharedGatewaySessions.ContainsKey($id)
            $fixture.ChooseForeign = $false
            $fixture.Confirmed = $false
            Invoke-LabMenuAction -ActionName $stopEntry[0].Id
            $stopDeclined = $script:AiSharedGatewaySessions.ContainsKey($id)

            $fixture.Confirmed = $true
            Invoke-LabMenuAction -ActionName $stopEntry[0].Id
            $terminal = Get-SqlServerLabAiSharedGatewayStatus -Plan $FixturePlan -StateRoot $FixtureRoot
            [pscustomobject]@{
                StartDeclined=$startDeclined; KeyEntryCancelled=$keyEntryCancelled; StartVerified=$startVerified
                SecureInputs=$secureInputs; ListedOwnerOnly=$listedOwnerOnly; StopDeclined=$stopDeclined
                StopVerified=$terminal.Status -ceq 'REGISTERED_STOPPED' -and -not $script:AiSharedGatewaySessions.Count -and
                    $fixture.Messages[-1] -ceq 'Eigene Gateway-Sitzung beendet und temporärer Zustand bereinigt.'
                OutputBounded=($fixture.Messages -join ' ') -cnotmatch 'AAAAAAAA|BBBBBBBB' -and
                    ($fixture.Messages -join ' ') -notmatch [regex]::Escape($FixtureRoot)
            }
        } finally {
            foreach ($remaining in @($script:AiSharedGatewaySessions.Keys)) {
                if ($remaining) { Stop-SqlServerLabAiSharedGatewaySession -OperationId $remaining -Confirm:$false | Out-Null }
            }
        }
    } $plan $stateRoot $keyA $keyB
    Add-CheckResult 'Geführter Start liest nach abgelehnter Bestätigung keine Schlüssel' $guided.StartDeclined
    Add-CheckResult 'Abbruch der Schlüsseleingabe verwirft vorherige sichere Werte und startet nichts' $guided.KeyEntryCancelled
    Add-CheckResult 'Geführter Start bindet echte eigene Sitzung an den Plan und maskiert Schlüssel' ($guided.StartVerified -and $guided.SecureInputs)
    Add-CheckResult 'Stop-Menü zeigt nur eigene Operationen und verweigert fremde Auswahl' $guided.ListedOwnerOnly
    Add-CheckResult 'Geführter Stop respektiert Ablehnung und bestätigt nach Zustimmung eigenes Ende' ($guided.StopDeclined -and $guided.StopVerified)
    Add-CheckResult 'Geführte Sitzungsanzeige enthält keine Schlüssel oder Dateispeicherorte' $guided.OutputBounded
    $browser = & $module {
        param($FixturePlan,$FixtureRoot,$FixtureKeyA,$FixtureKeyB)
        $vaultReads = [Collections.Generic.List[string]]::new()
        function Get-LabStateRoot { $FixtureRoot }
        function Get-Secret {
            [CmdletBinding()]param([string]$Name)
            $vaultReads.Add($Name)
            if ($Name -ceq 'SQL_SERVER_LAB_SECRET_SHARED_AI_A') { return $FixtureKeyA }
            if ($Name -ceq 'SQL_SERVER_LAB_SECRET_SHARED_AI_B') { return $FixtureKeyB }
            throw 'synthetic vault mismatch'
        }
        $scope = @{}
        $foreignScope = @{}
        $startPayload = @{Action='Start'; Confirmed=$false; Plan=$FixturePlan; LeaseSeconds=60; UpstreamReference=''}
        try { Invoke-LabAiSharedGatewayBrowserSession $scope ($startPayload | ConvertTo-Json -Depth 8); $unconfirmedRejected = $false }
        catch { $unconfirmedRejected = $vaultReads.Count -eq 0 }
        $startPayload.Confirmed = $true
        $startJson = $startPayload | ConvertTo-Json -Depth 8
        $result = Invoke-LabAiSharedGatewayBrowserSession $scope $startJson
        $id = $result.OperationId
        try {
            $view = Get-LabAiSharedGatewayBrowserSessions $scope
            $foreignView = Get-LabAiSharedGatewayBrowserSessions $foreignScope
            $stopJson = @{Action='Stop'; Confirmed=$true; OperationId=$id} | ConvertTo-Json
            try { Invoke-LabAiSharedGatewayBrowserSession $foreignScope $stopJson; $foreignRejected = $false }
            catch { $foreignRejected = $_.Exception.Message -ceq 'AI_SHARED_GATEWAY_SESSION_HTTP_OWNERSHIP_NOT_FOUND' }
            $scopeIsolated = $view.Items.Count -eq 1 -and $view.Items[0].OperationId -ceq $id -and $foreignView.Items.Count -eq 0 -and $foreignRejected
            $ownStop = Invoke-LabAiSharedGatewayBrowserSession $scope $stopJson
            $explicitEnd = $ownStop.Status -ceq 'CLEANUP_SUCCEEDED' -and -not $scope.Count -and
                (Get-SqlServerLabAiSharedGatewayStatus -Plan $FixturePlan -StateRoot $FixtureRoot).Status -ceq 'REGISTERED_STOPPED'
            $firstReadCount = $vaultReads.Count
            function Start-SqlServerLabAiSharedGatewaySession {
                [CmdletBinding()]param($Plan,$StateRoot,$ApiKeyByReference,$LeaseSeconds,$UpstreamApiKey)
                $null = Start-LabAiSharedGatewaySession @PSBoundParameters
                throw 'synthetic unconfirmed reply'
            }
            $unconfirmedStart = $false
            try { $null = Invoke-LabAiSharedGatewayBrowserSession $scope $startJson }
            catch { $unconfirmedStart = $_.Exception.Message -ceq 'AI_SHARED_GATEWAY_SESSION_HTTP_START_UNCONFIRMED' }
            $retained = Get-LabAiSharedGatewayBrowserSessions $scope
            $shutdown = Close-LabAiSharedGatewayBrowserSessions $scope
            [pscustomobject]@{
                RejectedBeforeVault=$unconfirmedRejected
                BoundStart=$result.Status -ceq 'SESSION_ENDPOINT_VERIFIED' -and $result.PlanKey -ceq $FixturePlan.PlanKey -and $firstReadCount -eq 2
                Isolated=$scopeIsolated
                ExplicitEnd=$explicitEnd
                OwnerShutdown=$unconfirmedStart -and $retained.Items.Count -eq 1 -and
                    $retained.Items[0].OperationId -cne $id -and $shutdown -and -not $scope.Count -and
                    (Get-SqlServerLabAiSharedGatewayStatus -Plan $FixturePlan -StateRoot $FixtureRoot).Status -ceq 'REGISTERED_STOPPED'
                Sanitized=(($view,$result,$ownStop | ConvertTo-Json -Depth 10) -cnotmatch 'AAAAAAAA|BBBBBBBB|SECRET_SHARED_AI|OwnerNonce|ProcessId|OperationRoot')
            }
        } finally { $null = Close-LabAiSharedGatewayBrowserSessions $scope }
    } $plan $stateRoot $keyA $keyB
    Add-CheckResult 'Browser startet ohne ausdrückliche Zustimmung und Vault-Zugriff keinen Worker' $browser.RejectedBeforeVault
    Add-CheckResult 'Browser liest genau die gebundenen Vault-Referenzen und startet in derselben Modulsitzung' $browser.BoundStart
    Add-CheckResult 'Browser listet und stoppt keine eigene Operation eines anderen UI-Scopes' $browser.Isolated
    Add-CheckResult 'Browser-Stop und UI-Serverende bereinigen den eigenen Worker auch nach unbestätigtem Start' ($browser.ExplicitEnd -and $browser.OwnerShutdown)
    Add-CheckResult 'Browser-Sitzungsvertrag enthält keine Schlüssel, Referenzen oder private Prozessdaten' $browser.Sanitized
    $tokens=$null;$parseErrors=$null
    $server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Browser session route parse failed' }
    $route=$server.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/ai-shared-gateway/sessions'''},$true)
    $handler=[scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
    $transport = & $module {
        param($Handler,$Reader)
        . $Reader
        $url='http://127.0.0.1:8484/'
        $aiSharedGatewayBrowserSessions=@{}
        function Write-UiResponse {
            param($Context,$Body,$ContentType,$StatusCode=200)
            [pscustomobject]@{StatusCode=$StatusCode;Body=$Body}
        }
        $invalidOriginStream=[IO.MemoryStream]::new([byte[]]@())
        $context=[pscustomobject]@{Request=[pscustomobject]@{
            Url=[Uri]($url+'api/ai-shared-gateway/sessions'); HttpMethod='POST'; ContentType='application/json'
            Headers=@{Origin='http://127.0.0.1:8485'}; ContentLength64=[long]65537; InputStream=$invalidOriginStream
        }}
        try {
            $foreign = & $Handler
            $originRejected = $foreign.StatusCode -eq 400 -and $invalidOriginStream.CanRead
        } finally { $invalidOriginStream.Dispose() }
        $context.Request.Headers.Origin=$url.TrimEnd('/')
        $context.Request.InputStream=[IO.MemoryStream]::new([byte[]]@())
        try { $oversized = & $Handler } finally { $context.Request.InputStream.Dispose() }
        $context.Request.HttpMethod='GET'
        $view = & $Handler
        [pscustomobject]@{OriginRejectedBeforeBody=$originRejected; OversizedRejected=$oversized.StatusCode -eq 413
            EmptyOwnerView=$view.StatusCode -eq 200 -and (($view.Body | ConvertFrom-Json).Items.Count -eq 0) }
    } $handler (Join-Path $repoRoot 'Tools/WorkflowUiJsonBody.ps1')
    Add-CheckResult 'Direkte Browserroute prüft Origin vor Body, begrenzt POST und liest nur eigene Sitzungen' (
        $transport.OriginRejectedBeforeBody -and $transport.OversizedRejected -and $transport.EmptyOwnerView)
    $portGuard=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$gatewayPort);$portGuard.Start()
    $unknown=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Status meldet fremd belegten Gatewayport als Recoverybedarf' ($unknown.Status -ceq 'RECOVERY_REQUIRED' -and $unknown.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_PORT_OCCUPIED_UNKNOWN' -and ($unknown|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $portGuard.Stop();$portGuard=$null
    $conflictParameters=$planParameters.Clone();$conflictParameters.RuntimeModel='conflicting-model'
    $conflictPlan=Get-SqlServerLabAiSharedGatewayPlan @conflictParameters
    $conflict=$conflictPlan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
    Add-CheckResult 'Status unterscheidet abweichenden Plan von Inhaltsdrift' ($conflict.Status -ceq 'RECOVERY_REQUIRED' -and $conflict.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_PLAN_CONFLICT' -and ($conflict|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    $registrationPath=Join-Path $stateRoot 'shared-ai-gateways/shared-session/registration.json';$registrationJson=[IO.File]::ReadAllText($registrationPath)
    try {
        [IO.File]::WriteAllText($registrationPath,'{}')
        $drift=$plan|Get-SqlServerLabAiSharedGatewayStatus -StateRoot $stateRoot
        Add-CheckResult 'Status meldet manipulierte Registrierung als Recoverybedarf' ($drift.Status -ceq 'RECOVERY_REQUIRED' -and $drift.ReasonCode -ceq 'AI_SHARED_GATEWAY_STATUS_STORAGE_DRIFT' -and ($drift|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $statusSchema))
    }
    finally {[IO.File]::WriteAllText($registrationPath,$registrationJson)}
    Add-CheckResult 'Fremde OperationId wird nicht angefasst' (Reject {Stop-SqlServerLabAiSharedGatewaySession -OperationId ([guid]::NewGuid().ToString('D')) -Confirm:$false} 'AI_SHARED_GATEWAY_SESSION_OWNERSHIP_NOT_FOUND')
    $workerSource=Get-Content (Join-Path $repoRoot 'Tools/Invoke-AiSharedGatewaySessionWorker.ps1') -Raw
    Add-CheckResult 'Worker bindet Loopback und begrenzt den direkten Upstreamtransport' ($workerSource -match 'IPAddress\]::Loopback' -and $workerSource -match '\.UseProxy=\$false' -and $workerSource -match '\.AllowAutoRedirect=\$false' -and $workerSource -match 'ResponseHeadersRead' -and $workerSource -match 'upstreamOutput\.Length\+\$upstreamRead -gt 1MB')
    $ownerSource=Get-Content (Join-Path $repoRoot 'Private/LlamaCppOwnedRuntime.ps1') -Raw
    Add-CheckResult 'Modulentladung schließt auch Shared-Gateway-Ownerkanäle' ($ownerSource -match '\$script:AiSharedGatewaySessions' -and $ownerSource -match 'StandardInput\.Close\(\)')
    Add-CheckResult 'Öffentliche Befehle sind manifestexportiert' ((Get-Command Start-SqlServerLabAiSharedGatewaySession).ModuleName -ceq 'SqlServerLab' -and (Get-Command Stop-SqlServerLabAiSharedGatewaySession).ModuleName -ceq 'SqlServerLab' -and (Get-Command Get-SqlServerLabAiSharedGatewayStatus).ModuleName -ceq 'SqlServerLab')
}
finally {
    if($session -and $module){try{Stop-SqlServerLabAiSharedGatewaySession -OperationId $session.OperationId -Confirm:$false|Out-Null}catch{}}
    if($portGuard){try{$portGuard.Stop()}catch{}}
    [IO.File]::WriteAllText((Join-Path $testRoot 'upstream.stop'),'stop');if($upstreamJob){$null=$upstreamJob|Wait-Job -Timeout 10;$upstreamJob|Remove-Job -Force}
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue};foreach($item in @($disposable)){try{$item.Dispose()}catch{}};if(Test-Path $testRoot){Remove-Item $testRoot -Recurse -Force}
}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY SESSION: PASS ($passed)"
