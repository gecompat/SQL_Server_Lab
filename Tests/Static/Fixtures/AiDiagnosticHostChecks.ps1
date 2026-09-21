param($Module,$RepoRoot,$TemporaryRoot)
& $Module {
    param($RepoRoot,$TemporaryRoot)
    $checks=[Collections.Generic.List[object]]::new()
    function Check {param($Name,$Value)$checks.Add([pscustomobject]@{Name=$Name;Success=[bool]$Value})}
    function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{$_.Exception.Message -match $Code}}
    $run='22222222-2222-4222-8222-222222222222'
    $plan=New-LabAiDiagnosticAgentPlan -RunId $run -InstanceId primary -Question 'Testzustand?' -ToolId server-summary -GenerationModelKey ollama-qwen25-coder-7b-local -LocalPort 11434
    Check 'Neues Diagnosemodell bleibt lokal mit genau einem Generierungsversuch' ($plan.GenerationPlan.Lane -eq 'local' -and $plan.GenerationPlan.RequestBudget.MaximumRequests -eq 1 -and $plan.HostModelValidation)
    $password=[SecureString]::new();$script:agentFault='';$script:agentCalls=[Collections.Generic.List[object]]::new();$script:agentPayloads=0
    $metadata={param($Path,$Model)switch($Path){
        '/api/version' {@{version='0.34.2'}}
        '/api/tags' {@{models=@([pscustomobject]@{name=$Model;digest=if($script:agentFault -eq 'drift'){'b'*64}else{'a'*64}})}}
        '/api/show' {[pscustomobject]@{capabilities=@('completion');remote_host=if($script:agentFault -eq 'remote'){'https://remote.invalid'}else{''}}}
    }}
    $sql={param($Credential,$Sql,$NonQuery)
        $script:agentCalls.Add([pscustomobject]@{Sql=$Sql;User=$Credential.UserName})
        if($Sql -like 'CREATE LOGIN*' -and $script:agentFault -eq 'create'){throw 'SYNTHETIC_CREATE_FAILURE'}
        if($Sql -like 'GRANT*' -and $script:agentFault -eq 'grant'){throw 'SYNTHETIC_GRANT_FAILURE'}
        if(-not $NonQuery){$script:ownAgentSecret=$Credential.Password;return @{ProductVersion='17.0';CpuCount=1;PhysicalMemoryKb=1024}}
    }
    $generation={param($Request)$script:agentPayloads++;if($script:agentFault -eq 'generation'){throw 'SYNTHETIC_GENERATION_FAILURE'};if($script:agentFault -eq 'after-generation'){$script:agentFault='drift'};@{StatusCode=200;Body=@{response='Synthetischer Zustand.'}}}
    $invokeArguments=@{Plan=$plan;SaPassword=$password;Target=@{Provider='hyperv';Version='2025'};Question='Testzustand?';StateRoot=$TemporaryRoot;MetadataTransport=$metadata;SqlExecutor=$sql;GenerationTransport=$generation}
    $journalPath=Join-Path $TemporaryRoot "runs/$run/ai-agent/diagnostic-primary-$($plan.PlanKey.Substring(0,12)).json"
    try{
        $preview=Invoke-SqlServerLabAiDiagnosticAgent -RunId $run -SaPassword $password -Question 'Test' -GenerationModelKey ollama-qwen25-coder-7b-local -StateRoot 'missing-state' -WhatIf
        Check 'Diagnose-WhatIf verwendet weder Host noch Runstate' ($preview.Status -eq 'READY')
        $script:agentFault='remote'
        Check 'Remoteidentity blockiert Diagnose vor Login und Journal' ((Reject {Invoke-LabAiDiagnosticAgent @invokeArguments} 'AI_RAG_HOST_REMOTE_MODEL_FORBIDDEN') -and $script:agentCalls.Count -eq 0 -and -not(Test-Path -LiteralPath $journalPath))
        $script:agentFault='';$result=Invoke-LabAiDiagnosticAgent @invokeArguments
        Check 'Diagnoseergebnis bindet tatsächlichen lokalen Modelldigest schema-valide' (($result.HostGenerationBinding.Digest -ceq ('a'*64)) -and (($result|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $RepoRoot 'Schemas/ai-query-result.schema.json')))
        Check 'CREATE und GRANT sind getrennt und bestätigter Login wird entfernt' ($script:agentCalls[0].Sql -like 'CREATE LOGIN*' -and $script:agentCalls[0].Sql -notmatch 'GRANT' -and $script:agentCalls[1].Sql -like 'GRANT*' -and $script:agentCalls[-1].Sql -like 'DROP LOGIN*')
        $disposed=$false;try{$copy=$script:ownAgentSecret.Copy();$copy.Dispose()}catch{$disposed=$_.Exception.InnerException -is [ObjectDisposedException]}
        Check 'Eigene SQL-Login-Credentials werden disposed' $disposed
        foreach($fault in @('grant','create','generation','after-generation')){
            $script:agentFault=$fault;$script:agentCalls.Clear()
            $rejected=Reject {Invoke-LabAiDiagnosticAgent @invokeArguments} 'SYNTHETIC_|AI_RAG_HOST_MODEL_DRIFT'
            $journal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
            $drops=@($script:agentCalls|Where-Object Sql -Like 'DROP LOGIN*')
            $expectedCleanup=if($fault -eq 'create'){'RECOVERY_REQUIRED'}else{'SUCCEEDED'}
            Check "Diagnose-Teilfehler $fault hat ehrlichen Cleanup ohne fremdes DROP" ($rejected -and $journal.status -eq 'FAILED' -and $journal.cleanupStatus -eq $expectedCleanup -and $drops.Count -eq $(if($fault -eq 'create'){0}else{1}))
        }
        Check 'Cloudmodell wird für Diagnose vor Ausführung abgewiesen' (Reject {New-LabAiDiagnosticAgentPlan -RunId $run -InstanceId primary -Question test -ToolId server-summary -GenerationModelKey ollama-gpt-oss-120b-cloud -LocalPort 11434} 'AI_AGENT_MODEL_INVALID')
    }finally{$password.Dispose();$script:ownAgentSecret=$null}
    $checks.ToArray()
} $RepoRoot $TemporaryRoot
