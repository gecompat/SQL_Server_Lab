# Rein synthetische Endpoint- und Orchestrierungsprüfungen; keine Modellruntime.
param($Module,$RepoRoot)
& $Module {
    param($RepoRoot)
    $checks=[Collections.Generic.List[object]]::new()
    function Check {param($Name,$Success)$checks.Add([pscustomobject]@{Name=$Name;Success=[bool]$Success})}
    function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;return $false}catch{return $_.Exception.Message -match $Code}}
    $base=@{RunId='11111111-2222-4333-8444-555555555555';InstanceId='primary';Question='Sicherung?';Document=@(@{Id='backup-policy';Content='Tägliche Sicherung.'});EmbeddingModelKey='ollama-embeddinggemma-latest';GenerationModelKey='ollama-gpt-oss-120b-cloud';LocalPort=11434;TopK=1;GenerationLane='cloud';DataClassification='synthetic-only';AllowCloudEgress=$true;GenerationTimeoutSeconds=120;GenerationRetryCount=0}
    $plan=New-LabAiRagPlan @base
    Check 'Host-RAG bindet Cloud-Lane und begrenzte Generierungsrequests' ($plan.GenerationPlan.Lane -eq 'cloud' -and $plan.GenerationPlan.RequestBudget.MaximumRequests -eq 1 -and $plan.GenerationPlan.RequestBudget.TimeoutSeconds -eq 120)
    $other=$base.Clone();$other.DataClassification='public-or-redistributable'
    Check 'RAG-PlanKey bindet Datenklassifikation' ((New-LabAiRagPlan @other).PlanKey -cne $plan.PlanKey)
    $other=$base.Clone();$other.AllowCloudEgress=$false
    Check 'Cloud ohne Egress scheitert vor Ausführung' (Reject {New-LabAiRagPlan @other} 'AI_RAG_ENDPOINT_PLAN_BLOCKED')
    foreach($classification in @('','internal-explicit')){
        $other=$base.Clone();if($classification){$other.DataClassification=$classification}else{$other.Remove('DataClassification')}
        Check "Cloud-Datenklasse $classification wird fail-closed abgewiesen" (Reject {New-LabAiRagPlan @other} 'AI_RAG_DATA_CLASSIFICATION_REQUIRED')
    }
    $script:hostFault='';$script:metadataCalls=0;$script:payloadCalls=0;$script:sqlCalls=0;$script:cloudCalls=0
    $metadata={param($Path,$Model)
        $script:metadataCalls++
        switch($Path){
            '/api/version' {@{version=if($script:hostFault -eq 'version'){'0.11.9'}else{'0.34.2'}}}
            '/api/tags' {@{models=@([pscustomobject]@{name=$Model;digest=if($script:hostFault -eq 'digest'){'bad'}elseif($script:hostFault -eq 'drift'){'b'*64}else{'a'*64};remote_model=if($script:hostFault -eq 'remote-tag'){'remote'}else{''}})}}
            '/api/show' {
                $dimension=if($script:hostFault -eq 'dimension'){384}elseif($Model -ceq 'bge-m3:latest'){1024}elseif($Model -ceq 'all-minilm:latest'){384}else{768}
                [pscustomobject]@{remote_host=if($script:hostFault -eq 'remote-show'){'https://remote.invalid'}else{''};capabilities=if($script:hostFault -eq 'capability'){@('completion')}else{@('embedding')};model_info=[pscustomobject]@{'model.embedding_length'=$dimension}}
            }
        }
    }
    $binding=Get-LabAiHostModelBinding -Plan $plan.EmbeddingPlan -MetadataTransport $metadata
    Check 'Vorhandenes lokales Modell bindet Version Dimension und Live-Digest' ($binding.Digest -ceq ('a'*64) -and $binding.Dimension -eq 768)
    $nomicBase=$base.Clone();$nomicBase.EmbeddingModelKey='ollama-nomic-embed-text-v1-5'
    $nomicPlan=New-LabAiRagPlan @nomicBase
    Check 'Nomic v1.5 bindet das katalogisierte Suchprofil und die Live-Hostprüfung' (
        $nomicPlan.EmbeddingPlan.InputProfile -ceq 'nomic-search' -and $nomicPlan.HostModelValidation)
    $nomicV2Base=$base.Clone();$nomicV2Base.EmbeddingModelKey='ollama-nomic-embed-text-v2-moe'
    $nomicV2Plan=New-LabAiRagPlan @nomicV2Base
    Check 'Nomic v2 bindet dasselbe Suchprofil und die Live-Hostprüfung im Ad-hoc-RAG' (
        $nomicV2Plan.EmbeddingPlan.InputProfile -ceq 'nomic-search' -and $nomicV2Plan.HostModelValidation)
    $bgeBase=$base.Clone();$bgeBase.EmbeddingModelKey='ollama-bge-m3-latest'
    $bgePlan=New-LabAiRagPlan @bgeBase
    Check 'BGE-M3 bindet 1024 Dimensionen, Rohtextprofil und Live-Hostprüfung' (
        $bgePlan.EmbeddingPlan.Dimension -eq 1024 -and $bgePlan.EmbeddingPlan.InputProfile -ceq 'raw' -and $bgePlan.HostModelValidation)
    $miniBase=$base.Clone();$miniBase.EmbeddingModelKey='ollama-all-minilm-latest'
    $miniPlan=New-LabAiRagPlan @miniBase
    Check 'All-MiniLM bindet 384 Dimensionen, Rohtextprofil und Live-Hostprüfung' (
        $miniPlan.EmbeddingPlan.Dimension -eq 384 -and $miniPlan.EmbeddingPlan.InputProfile -ceq 'raw' -and $miniPlan.HostModelValidation)
    $paraphraseBase=$base.Clone();$paraphraseBase.EmbeddingModelKey='ollama-paraphrase-multilingual-latest'
    $paraphrasePlan=New-LabAiRagPlan @paraphraseBase
    Check 'Paraphrase Multilingual bindet 768 Dimensionen, Rohtextprofil und Live-Hostprüfung' (
        $paraphrasePlan.EmbeddingPlan.Dimension -eq 768 -and $paraphrasePlan.EmbeddingPlan.InputProfile -ceq 'raw' -and $paraphrasePlan.HostModelValidation)
    foreach($fault in @('version','digest','remote-tag','remote-show','capability','dimension')){
        $script:hostFault=$fault
        Check "Hostmodell $fault blockiert vor Payload" (Reject {Get-LabAiHostModelBinding -Plan $plan.EmbeddingPlan -MetadataTransport $metadata} 'AI_RAG_HOST_')
    }
    $script:hostFault='drift'
    Check 'Modellwechsel wird bei Revalidierung erkannt' (Reject {Assert-LabAiHostModelBinding -Plan $plan.EmbeddingPlan -Expected $binding -MetadataTransport $metadata} 'AI_RAG_HOST_MODEL_DRIFT')
    $script:hostFault=''
    # Ein endlicher, nichtleerer 768-Vektor für den Transportvertrag.
    $embedding={param($Request)$script:payloadCalls++;$v=[double[]]::new(768);$v[0]=1;[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,$v)}}}
    $generation={param($Request)$script:cloudCalls++;if($Request.Body.prompt -notmatch '\[backup-policy\]'){throw 'context'};[pscustomobject]@{StatusCode=200;Body=@{response='Täglich [backup-policy].'}}}
    $sql={param($Query)$script:sqlCalls++;'AI_RAG_ROW|backup-policy|0.1'}
    $credential=[SecureString]::new()
    $invoke=@{Plan=$plan;Target=@{Version='2025';Provider='podman'};Question='Sicherung?';EmbeddingTransport=$embedding;GenerationTransport=$generation;SqlExecutor=$sql;GenerationCredential=$credential;MetadataTransport=$metadata}
    try{
        $result=Invoke-LabAiRag @invoke
        Check 'Hostembedding SQL-Retrieval und explizite Cloudgeneration bilden einen Aufruf' ($script:payloadCalls -eq 2 -and $script:sqlCalls -eq 1 -and $script:cloudCalls -eq 1 -and $result.Citations[0] -ceq 'backup-policy' -and $result.Metrics.RequestCount -eq 3)
        Check 'Live-Binding und ExecutionKey sind schema-valide' (($result|ConvertTo-Json -Depth 15)|Test-Json -SchemaFile (Join-Path $RepoRoot 'Schemas/ai-query-result.schema.json'))
        $script:nomicInputs=[Collections.Generic.List[string]]::new()
        $nomicInvoke=$invoke.Clone();$nomicInvoke.Plan=$nomicPlan
        $nomicInvoke.EmbeddingTransport={param($Request)$script:payloadCalls++;$script:nomicInputs.Add([string]$Request.Body.input[0]);$v=[double[]]::new(768);$v[0]=1;[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,$v)}}}
        $nomicResult=Invoke-LabAiRag @nomicInvoke
        Check 'Nomic v1.5 präfigiert Dokument und Frage rollengetreu vor dem SQL-Retrieval' (
            $nomicResult.Status -eq 'SUCCEEDED' -and $script:nomicInputs.Count -eq 2 -and
            $script:nomicInputs[0] -ceq 'search_document: Tägliche Sicherung.' -and
            $script:nomicInputs[1] -ceq 'search_query: Sicherung?')
        $script:bgeInputs=[Collections.Generic.List[string]]::new()
        $bgeInvoke=$invoke.Clone();$bgeInvoke.Plan=$bgePlan
        $bgeInvoke.EmbeddingTransport={param($Request)$script:payloadCalls++;$script:bgeInputs.Add([string]$Request.Body.input[0]);$v=[double[]]::new(1024);$v[0]=1;[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,$v)}}}
        $bgeResult=Invoke-LabAiRag @bgeInvoke
        Check 'BGE-M3 führt unveränderte Texte als 1024-dimensionale SQL-Vektoren aus' (
            $bgeResult.Status -eq 'SUCCEEDED' -and $script:bgeInputs.Count -eq 2 -and
            $script:bgeInputs[0] -ceq 'Tägliche Sicherung.' -and $script:bgeInputs[1] -ceq 'Sicherung?')
        $script:hostFault='remote-show';$before=$script:payloadCalls;$beforeSql=$script:sqlCalls;$beforeCloud=$script:cloudCalls
        Check 'Remote Hostmodell sendet weder Dokumente noch SQL oder Cloud' ((Reject {Invoke-LabAiRag @invoke} 'AI_RAG_HOST_REMOTE_MODEL_FORBIDDEN') -and $script:payloadCalls -eq $before -and $script:sqlCalls -eq $beforeSql -and $script:cloudCalls -eq $beforeCloud)
        $script:hostFault=''
        $invoke.EmbeddingTransport={param($Request)$script:hostFault='drift';$v=[double[]]::new(768);$v[0]=1;@{StatusCode=200;Body=@{embeddings=@(,$v)}}}
        Check 'Digestdrift nach Embedding sperrt SQL und Cloud' ((Reject {Invoke-LabAiRag @invoke} 'AI_RAG_HOST_MODEL_DRIFT') -and $script:sqlCalls -eq $beforeSql -and $script:cloudCalls -eq $beforeCloud)
        $script:hostFault=''
        foreach($badValue in @([double]::NaN,[double]::PositiveInfinity)){
            $v=[double[]]::new(768);$v[0]=$badValue
            Check 'Nichtendliche Vektoren werden vor SQL abgewiesen' (Reject {ConvertTo-LabAiVectorLiteral -Vector $v -Dimension 768} 'AI_RAG_VECTOR_VALUE_INVALID')
        }
        Check 'Falsche Vektordimension wird vor SQL abgewiesen' (Reject {ConvertTo-LabAiVectorLiteral -Vector @(1,2) -Dimension 768} 'AI_RAG_VECTOR_DIMENSION_MISMATCH')
        $public=$base.Clone();$public.Remove('InstanceId');$public.SaPassword=$credential;$public.SecretFilePath='missing-secret.env'
        $preview=Invoke-SqlServerLabAiRag @public -WhatIf
        Check 'Cloud-WhatIf liest weder fehlenden Run noch Secret noch Host' ($preview.Status -eq 'READY' -and $preview.GenerationLane -eq 'cloud')
        $default=Invoke-SqlServerLabAiRag -RunId $base.RunId -SaPassword $credential -Question 'Test' -Document $base.Document -TopK 1 -WhatIf
        $golden=Invoke-SqlServerLabAiRag -RunId $base.RunId -SaPassword $credential -CaseId backup-frequency -WhatIf
        Check 'Default und Golden bleiben unverändert lokale Previews' ($default.GenerationModelKey -eq 'ollama-gemma3-1b-local' -and $golden.EmbeddingModelKey -eq 'ollama-embeddinggemma-300m-q4')
    }finally{$credential.Dispose()}
    # Echter HttpClient: 307 darf weder Ziel noch Payload umleiten.
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
    $job=Start-ThreadJob -ArgumentList $listener -ScriptBlock {param($Listener)$socket=$Listener.AcceptTcpClient();try{$stream=$socket.GetStream();$buffer=[byte[]]::new(16384);$null=$stream.Read($buffer,0,$buffer.Length);$bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 307 Temporary Redirect`r`nLocation: http://127.0.0.1:1/leak`r`nContent-Length: 0`r`nConnection: close`r`n`r`n");$stream.Write($bytes,0,$bytes.Length)}finally{$socket.Dispose()}}
    try{
        $redirect=Invoke-LabOllamaHttpTransport -BaseUri "http://127.0.0.1:$port" -Request @{Path='/api/embed';Body=@{model='synthetic';input=@('synthetic')};TimeoutSeconds=5}
        Check 'Realer HTTP-Transport folgt keinem Redirect' ($redirect.StatusCode -eq 307)
    }finally{$listener.Stop();$job|Wait-Job -Timeout 10|Out-Null;$job|Remove-Job -Force}
    $credential=[SecureString]::new()
    try{
        $script:redirectAttempts=0
        $redirectTransport={param($Request)$script:redirectAttempts++;@{StatusCode=307;Body=$null}}
        Check 'Cloud-Redirect wird ohne Retry oder Fallback sanitisiert' ((Reject {Invoke-LabAiEndpointRequest -Plan $plan.GenerationPlan -InputText 'synthetic' -Credential $credential -Transport $redirectTransport} 'AI_ENDPOINT_HTTP_307') -and $script:redirectAttempts -eq 1)
        Check 'Fehlendes Cloudcredential blockiert vor Transport' (Reject {Invoke-LabAiEndpointRequest -Plan $plan.GenerationPlan -InputText 'synthetic' -Transport {throw 'unexpected transport'}} 'AI_ENDPOINT_CREDENTIAL_MISSING')
    }finally{$credential.Dispose()}
    $originals=@{}
    foreach($name in @('Resolve-LabRunInstance','Get-LabAiDotEnvSecret','Invoke-LabAiRag')){$originals[$name]=(Get-Command $name).ScriptBlock}
    try{
        Set-Item Function:script:Resolve-LabRunInstance -Value {param($RunId,$InstanceId,$StateRoot)@{Version='2025';Provider='podman'}}
        Set-Item Function:script:Get-LabAiDotEnvSecret -Value {param($Path)$script:returnedRagCredential=[SecureString]::new();@{Secret=$script:returnedRagCredential;Warnings=@()}}
        Set-Item Function:script:Invoke-LabAiRag -Value {param($Plan,$SaPassword,$Target,$Question,$GenerationCredential)if($script:ragCredentialFailure){throw 'SYNTHETIC_RAG_FAILURE'};@{Status='SUCCEEDED'}}
        foreach($failure in @($false,$true)){
            $script:ragCredentialFailure=$failure
            $public=$base.Clone();$public.SaPassword=[SecureString]::new();$public.SecretFilePath='synthetic.env'
            try{
                $failed=Reject {Invoke-SqlServerLabAiRag @public -Confirm:$false} 'SYNTHETIC_RAG_FAILURE'
                $disposed=$false
                try{$copy=$script:returnedRagCredential.Copy();$copy.Dispose()}catch{$disposed=$_.Exception.InnerException -is [ObjectDisposedException] -or $_.Exception -is [ObjectDisposedException]}
                Check "Öffentliche RAG-API disposed Cloudsecret bei Fehler=$failure" ($failed -eq $failure -and $disposed)
            }finally{$public.SaPassword.Dispose()}
        }
    }finally{foreach($name in $originals.Keys){Set-Item "Function:script:$name" -Value $originals[$name]};$script:returnedRagCredential=$null}
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Tests/Integration/Invoke-AiRagExistingOllamaAcceptance.ps1'),[ref]$null,[ref]$null)
    $function=$ast.Find({param($Node)$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Get-HostRagInventoryKey'},$true)
    . ([scriptblock]::Create($function.Extent.Text))
    $originalMetadata=(Get-Command Invoke-LabAiHostMetadata).ScriptBlock
    try{
        Set-Item Function:script:Invoke-LabAiHostMetadata -Value {param($Port,$Path)@{models=$script:inventoryFixture}}
        $script:inventoryFixture=@(@{name='alpha:latest';digest=('a'*64)},@{name='beta:latest';digest=('b'*64)})
        $firstKey=Get-HostRagInventoryKey -Module (Get-Module SqlServerLab) -Port 11434
        [array]::Reverse($script:inventoryFixture)
        $secondKey=Get-HostRagInventoryKey -Module (Get-Module SqlServerLab) -Port 11434
        $script:inventoryFixture[0].digest='c'*64
        $changedKey=Get-HostRagInventoryKey -Module (Get-Module SqlServerLab) -Port 11434
        Check 'Native Inventarprüfung ignoriert nur API-Reihenfolge und erkennt echte Drift' ($firstKey -ceq $secondKey -and $firstKey -cne $changedKey)
    }finally{Set-Item Function:script:Invoke-LabAiHostMetadata -Value $originalMetadata;$script:inventoryFixture=$null}
    $checks.ToArray()
} $RepoRoot
