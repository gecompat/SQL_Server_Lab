<#
.SYNOPSIS
    Begrenzter interner HTTPS-Referenzvertrag für SQL-2025-Docker-Embeddings.
#>
function Get-LabAiSqlHttpsFixture {
    [pscustomobject]@{
        Documents=@(
            [pscustomobject]@{Id='backup-policy';Content='SQL Server Lab überprüft synthetische Sicherungen täglich.'},
            [pscustomobject]@{Id='network-policy';Content='Das synthetische Labnetz verwendet ausschließlich isolierte Testadressen.'},
            [pscustomobject]@{Id='cleanup-policy';Content='Run-eigene Testressourcen werden nach der Abnahme vollständig entfernt.'})
        Questions=@(
            [pscustomobject]@{Id='backup-policy';Content='Wie oft werden synthetische Sicherungen überprüft?'},
            [pscustomobject]@{Id='cleanup-policy';Content='Was geschieht nach der Abnahme mit run-eigenen Testressourcen?'})
    }
}

function Read-LabAiSqlHttpsRequest {
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][string]$Token)
    $cancel=[Threading.CancellationTokenSource]::new(5000)
    try {
    $bytes=[Collections.Generic.List[byte]]::new()
    $single=[byte[]]::new(1)
    while($bytes.Count -lt 8192){
        $read=$Stream.ReadAsync($single,0,1,$cancel.Token).GetAwaiter().GetResult();if($read -ne 1){throw 'AI_SQL_HTTPS_REQUEST_INVALID'};$bytes.Add($single[0])
        $n=$bytes.Count
        if($n -ge 4 -and $bytes[$n-4] -eq 13 -and $bytes[$n-3] -eq 10 -and $bytes[$n-2] -eq 13 -and $bytes[$n-1] -eq 10){break}
    }
    if($bytes.Count -ge 8192){throw 'AI_SQL_HTTPS_REQUEST_INVALID'}
    $lines=@([Text.Encoding]::ASCII.GetString($bytes.ToArray()) -split "`r`n")
    if($lines[0] -cne 'POST /api/embed HTTP/1.1'){throw 'AI_SQL_HTTPS_REQUEST_INVALID'}
    $headers=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($line in $lines[1..($lines.Count-1)]){
        if($line -ceq ''){continue}
        if($line -notmatch '^([A-Za-z0-9-]+):[ \t]*([^\r\n]*)$' -or $headers.ContainsKey($Matches[1])){throw 'AI_SQL_HTTPS_REQUEST_INVALID'}
        $headers.Add($Matches[1],$Matches[2].Trim())
    }
    if(-not $headers.ContainsKey('X-SqlLab-Token') -or $headers['X-SqlLab-Token'] -cne $Token){throw 'AI_SQL_HTTPS_AUTH_FAILED'}
    if($headers.ContainsKey('Transfer-Encoding') -or $headers.ContainsKey('Expect') -or -not $headers.ContainsKey('Content-Length') -or
        $headers['Content-Length'] -cnotmatch '^[1-9][0-9]{0,3}$' -or [int]$headers['Content-Length'] -gt 4096 -or
        -not $headers.ContainsKey('Content-Type') -or $headers['Content-Type'] -notmatch '^application/json(?:\s*;\s*charset=utf-8)?$'){throw 'AI_SQL_HTTPS_REQUEST_INVALID'}
    $body=[byte[]]::new([int]$headers['Content-Length']);$offset=0
    while($offset -lt $body.Length){$read=$Stream.ReadAsync($body,$offset,$body.Length-$offset,$cancel.Token).GetAwaiter().GetResult();if($read -le 0){throw 'AI_SQL_HTTPS_REQUEST_INVALID'};$offset+=$read}
    try{
        $json=[Text.UTF8Encoding]::new($false,$true).GetString($body)
        $document=[Text.Json.JsonDocument]::Parse($json)
        try{
            $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($property in $document.RootElement.EnumerateObject()){
                if(-not $names.Add($property.Name) -or $property.Name -cnotin @('model','input')){throw 'payload'}
            }
            if($names.Count -ne 2){throw 'payload'}
        }finally{$document.Dispose()}
        $request=$json|ConvertFrom-Json -Depth 5
        if($request.model -isnot [string] -or $request.model -cne 'embeddinggemma:latest'){throw 'payload'}
        $inputs=@($request.input)
        if($inputs.Count -ne 1 -or $inputs[0] -isnot [string]){throw 'payload'}
        $fixture=Get-LabAiSqlHttpsFixture
        if([string]$inputs[0] -cnotin @(@($fixture.Documents.Content)+@($fixture.Questions.Content))){throw 'payload'}
        return [string]$inputs[0]
    }catch{throw 'AI_SQL_HTTPS_PAYLOAD_INVALID'}
    } finally {$cancel.Dispose()}
}

function ConvertTo-LabAiSqlHttpsResponse {
    param([Parameter(Mandatory)]$Response)
    if($Response.model -and [string]$Response.model -cne 'embeddinggemma:latest'){throw 'AI_SQL_HTTPS_RESPONSE_INVALID'}
    $vectors=@($Response.embeddings)
    if($vectors.Count -ne 1 -or @($vectors[0]).Count -ne 768){throw 'AI_SQL_HTTPS_RESPONSE_INVALID'}
    foreach($value in $vectors[0]){
        if($value -isnot [ValueType] -or $value -is [bool] -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [Math]::Abs([double]$value) -gt [float]::MaxValue){throw 'AI_SQL_HTTPS_RESPONSE_INVALID'}
    }
    return (@{model='embeddinggemma:latest';embeddings=@(,@($vectors[0]))}|ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-LabAiSqlHttpsHttp {
    param([int]$Port,[string]$Path,[string]$Body,[int]$TimeoutMilliseconds)
    if($Port -lt 1024 -or $Port -gt 65535 -or $Path -cnotin @('/api/version','/api/tags','/api/show','/api/embed') -or $TimeoutMilliseconds -le 0){throw 'AI_SQL_HTTPS_UPSTREAM_INVALID'}
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler,$true);$client.Timeout=[TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
    $cancel=[Threading.CancellationTokenSource]::new($TimeoutMilliseconds);$message=$null;$response=$null;$stream=$null
    try{
        $method=if($Body){[Net.Http.HttpMethod]::Post}else{[Net.Http.HttpMethod]::Get}
        $message=[Net.Http.HttpRequestMessage]::new($method,"http://127.0.0.1:$Port$Path")
        if($Body){$message.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')}
        $response=$client.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){throw 'response'}
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$output=[IO.MemoryStream]::new();$buffer=[byte[]]::new(8192)
        try{
            do{$read=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult();if($output.Length+$read -gt 1MB){throw 'size'};if($read){$output.Write($buffer,0,$read)}}while($read)
            return ([Text.UTF8Encoding]::new($false,$true).GetString($output.ToArray())|ConvertFrom-Json -Depth 30)
        }finally{$output.Dispose()}
    }catch{throw 'AI_SQL_HTTPS_UPSTREAM_FAILED'}
    finally{if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($message){$message.Dispose()};$cancel.Dispose();$client.Dispose()}
}

function Invoke-LabAiSqlHttpsEmbedding {
    param($Plan,$Expected,[string]$InputText,[scriptblock]$HttpTransport)
    $fixture=Get-LabAiSqlHttpsFixture
    if($Plan.ModelKey -cne 'ollama-embeddinggemma-latest' -or $Plan.Lane -cne 'local' -or $InputText -cnotin @(@($fixture.Documents.Content)+@($fixture.Questions.Content))){throw 'AI_SQL_HTTPS_PAYLOAD_INVALID'}
    $deadline=[DateTime]::UtcNow.AddSeconds(24)
    $send={param($Path,$Body,[int]$Maximum)
        $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
        if($remaining -le 0){throw 'AI_SQL_HTTPS_DEADLINE'}
        if($HttpTransport){& $HttpTransport $Path $Body ([Math]::Min($Maximum,$remaining))}
        else{Invoke-LabAiSqlHttpsHttp -Port $Plan.Port -Path $Path -Body $Body -TimeoutMilliseconds ([Math]::Min($Maximum,$remaining))}
    }
    $metadata={param($Path,$Model)$body=if($Path -ceq '/api/show'){@{model=$Model}|ConvertTo-Json -Compress}else{$null};& $send $Path $body 3000}
    Assert-LabAiHostModelBinding -Plan $Plan -Expected $Expected -MetadataTransport $metadata
    $body=@{model='embeddinggemma:latest';input=@($InputText);truncate=$false;keep_alive='1m'}|ConvertTo-Json -Compress
    $response=& $send '/api/embed' $body 16000
    $validated=ConvertTo-LabAiSqlHttpsResponse -Response $response
    Assert-LabAiHostModelBinding -Plan $Plan -Expected $Expected -MetadataTransport $metadata
    return $validated
}

function Write-LabAiSqlHttpsResponse {
    param([IO.Stream]$Stream,[int]$StatusCode,[string]$Body)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $StatusCode Result`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($header,0,$header.Length);$Stream.Write($bytes,0,$bytes.Length);$Stream.Flush()
}

function Start-LabAiSqlHttpsBridge {
    param([string]$Root,[string]$OperationId,[string]$Token,$Binding,[int]$LocalPort,[scriptblock]$FaultInjector)
    Assert-LabAiPersistentPath $Root
    if(-not(Test-Path -LiteralPath $Root -PathType Container) -or (Test-Path -LiteralPath (Join-Path $Root 'process.json'))){throw 'AI_SQL_HTTPS_ROOT_INVALID'}
    $process=$null
    try{
        Write-LabArtifactJsonAtomic -Path (Join-Path $Root 'process.json') -InputObject @{OperationId=$OperationId;Status='STARTING';ProcessId=$null;StartTicks=$null}
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tests/Integration/Support/Invoke-AiSqlHttpsBridgeServer.ps1'),'-Root',$Root)){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        $ticks=$process.StartTime.ToUniversalTime().Ticks
        Write-LabArtifactJsonAtomic -Path (Join-Path $Root 'process.json') -InputObject @{OperationId=$OperationId;Status='STARTED';ProcessId=$process.Id;StartTicks=$ticks}
        if($FaultInjector){& $FaultInjector $process.Id}
        $parent=Get-Process -Id $PID
        $process.StandardInput.WriteLine((@{OperationId=$OperationId;Token=$Token;Binding=$Binding;LocalPort=$LocalPort;ParentPid=$PID;ParentStartTicks=$parent.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json -Depth 8 -Compress));$process.StandardInput.Flush()
        $readyPath=Join-Path $Root 'ready.json';$deadline=[DateTime]::UtcNow.AddSeconds(30)
        while(-not(Test-Path -LiteralPath $readyPath)){if($process.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'AI_SQL_HTTPS_GATEWAY_START_FAILED'};Start-Sleep -Milliseconds 50}
        Assert-LabAiPersistentPath $readyPath
        $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json -Depth 8
        if($ready.OperationId -cne $OperationId -or $ready.ProcessId -ne $process.Id -or $ready.StartTicks -ne $ticks){throw 'AI_SQL_HTTPS_PROCESS_BINDING_INVALID'}
        $ports=@($ready.Ports.Good,$ready.Ports.WrongSan,$ready.Ports.WrongCa)
        if(@($ports|Select-Object -Unique).Count -ne 3 -or @($ports|Where-Object {$_ -lt 1024 -or $_ -gt 65535}).Count){throw 'AI_SQL_HTTPS_PORT_INVALID'}
        $ca=[Convert]::FromBase64String($ready.CaBase64)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ca)).ToLowerInvariant() -cne $ready.CaSha256){throw 'AI_SQL_HTTPS_CA_INVALID'}
        [pscustomobject]@{Process=$process;StartTicks=$ticks;Ready=$ready;Root=$Root;OutputTask=$out;ErrorTask=$err}
    }catch{
        $confirmed=$null -eq $process
        try{if($process){if(-not $process.HasExited){$process.Kill($true);$confirmed=$process.WaitForExit(5000)}else{$confirmed=$true}}}catch{$confirmed=$false}
        try{Write-LabArtifactJsonAtomic -Path (Join-Path $Root 'process.json') -InputObject @{OperationId=$OperationId;Status=$(if($confirmed){'STOPPED'}else{'RECOVERY_REQUIRED'});ProcessId=$(if($process){$process.Id}else{$null});StartTicks=$ticks}}catch{}
        if(-not $confirmed){throw 'AI_SQL_HTTPS_PROCESS_RECOVERY_REQUIRED'}
        if($process){$process.Dispose()};throw 'AI_SQL_HTTPS_GATEWAY_START_FAILED_CLEANED'
    }
}

function Stop-LabAiSqlHttpsBridge {
    param([Parameter(Mandatory)]$Bridge)
    $process=$Bridge.Process
    if($process.StartTime.ToUniversalTime().Ticks -ne $Bridge.StartTicks){throw 'AI_SQL_HTTPS_PROCESS_BINDING_INVALID'}
    if(-not $process.HasExited){
        $process.StandardInput.WriteLine('STOP');$process.StandardInput.Flush()
        if(-not $process.WaitForExit(55000)){$process.Kill($true);if(-not $process.WaitForExit(5000)){throw 'AI_SQL_HTTPS_PROCESS_RECOVERY_REQUIRED'};throw 'AI_SQL_HTTPS_GATEWAY_FORCED_STOP'}
    }
    $path=Join-Path $Bridge.Root 'gateway.json';Assert-LabAiPersistentPath $path
    $json=Get-Content -LiteralPath $path -Raw
    if($process.ExitCode -ne 0 -or -not($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-sql-https-bridge-receipt.schema.json') -ErrorAction Stop)){throw 'AI_SQL_HTTPS_GATEWAY_FAILED'}
    $receipt=$json|ConvertFrom-Json -Depth 8
    if($receipt.operationId -cne $Bridge.Ready.OperationId -or $receipt.status -cne 'STOPPED'){throw 'AI_SQL_HTTPS_RECEIPT_INVALID'}
    $process.Dispose();return $receipt
}
