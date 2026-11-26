param([PSModuleInfo]$Module,$Plan,[string]$Directory)

$ErrorActionPreference='Stop'
$null=[IO.Directory]::CreateDirectory($Directory)
$file=Join-Path $Directory 'guided-model-plan.json'
[IO.File]::WriteAllText($file,($Plan | ConvertTo-Json -Depth 8 -Compress))
$rsa=[Security.Cryptography.RSA]::Create(2048)
$certificate=$null
try {
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Synthetic Endpoint Test CA',$rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-1),[DateTimeOffset]::UtcNow.AddDays(1))
    & $Module {
        param($FixturePlan,$PlanFile,$FixturePem)
        $fixture=[pscustomobject]@{ Probes=0; VaultReads=0; Confirmed=$false; TrustedRoot=$false; KeyBound=$false; Drift=$false
            Prompts=[Collections.Generic.List[string]]::new(); Inputs=[Collections.Generic.Queue[object]]::new()
            Logs=[Collections.Generic.List[string]]::new(); Assertions=0; SqlAllowed=$false; SqlChecks=0
            LifecycleChoices=[Collections.Generic.Queue[string]]::new(); LifecycleConsents=[Collections.Generic.Queue[bool]]::new()
            Applies=0; Embeds=0; Cleans=0; ApplyFails=$false }
        $dummy=[Security.SecureString]::new()
        foreach ($letter in 'SyntheticOnlyEndpointKey'.ToCharArray()) { $dummy.AppendChar($letter) }
        $dummy.MakeReadOnly()
        function Assert-GuidedEndpoint([bool]$Condition,[string]$Name) {
            if (-not $Condition) { throw ('GUIDED_ENDPOINT_FIXTURE_FAILED '+$Name) }
            $fixture.Assertions++
        }
        function Get-Secret {
            [CmdletBinding()]param($Name)
            $fixture.VaultReads++
            if ($Name -cne 'SQL_SERVER_LAB_SECRET_SYNTHETIC') { throw 'Unexpected fixture reference' }
            $dummy
        }
        function Test-SqlServerLabAiExternalModelEndpoint {
            [CmdletBinding()]param($Plan,$TrustedRootCertificate,$ApiKey)
            $fixture.Probes++
            $fixture.TrustedRoot=$null -ne $TrustedRootCertificate -and -not $TrustedRootCertificate.HasPrivateKey
            $fixture.KeyBound=$ApiKey -is [Security.SecureString] -and $ApiKey.Length -eq $dummy.Length
            $receipt=Invoke-LabAiExternalModelEndpointProbe -Plan $Plan -Transport {
                param($Request)
                if ($Request.Method -cne 'POST' -or $Request.Body.input.Count -ne 1 -or
                    $Request.Body.input[0] -cne 'SQL Server Lab synthetic embedding probe') { throw 'Unexpected provider request' }
                [pscustomobject]@{StatusCode=200;ServerCertificateSha256=$Plan.ServerCertificateSha256
                    Body=[pscustomobject]@{model=$Plan.RuntimeModel;data=@([pscustomobject]@{embedding=@(0,1,2)})}}
            }
            if ($fixture.Drift) { $receipt.PlanKey='d'*64 }
            $receipt | Add-Member -NotePropertyName PrivateCanary -NotePropertyValue 'FIXTURE_PRIVATE_CANARY'
            $receipt
        }
        function Read-LabConfirm {
            param($Prompt,$Default)
            if ($Prompt -like 'Zur getrennten SQL-Zielprüfung*' -or $Prompt -like 'Datenbank * verwaltetem SQL-Zugang*') {
                return $fixture.SqlAllowed
            }
            if ($Prompt -match '^(SQL-Objekte für|Synthetisches Embedding für|Eigene SQL-Objekte in)') {
                if ($Default) { throw 'Lifecycle confirmation must default to decline' }
                return $fixture.LifecycleConsents.Dequeue()
            }
            $fixture.Confirmed
        }
        function Select-LabAiTargetInteractive {
            param($Prompt)
            [pscustomobject]@{RunId='11111111-2222-4333-8444-555555555555';InstanceId='primary'}
        }
        function Test-SqlServerLabAiExternalModelSqlPreflight {
            param($SqlPlan,$RunId,$InstanceId)
            if ($RunId -cne '11111111-2222-4333-8444-555555555555' -or $InstanceId -cne 'primary' -or $SqlPlan.DatabaseName -cne 'AiLab') {
                throw 'Fixture target mismatch'
            }
            $fixture.SqlChecks++
            [pscustomobject]@{Status='SQL_PREFLIGHT_VERIFIED';SqlPlanKey=$SqlPlan.SqlPlanKey;RunId=$RunId;InstanceId=$InstanceId}
        }
        function Select-LabConsoleDataItem {
            param($ScreenId,$Title,$Subtitle,$Items,$SelectedId)
            if($ScreenId -cnotin @('external-model-sql-apply','external-model-sql-follow-up') -or $SelectedId -cne 'return') {
                throw 'Unexpected lifecycle selection'
            }
            if($fixture.LifecycleChoices.Count){return $fixture.LifecycleChoices.Dequeue()}
            'return'
        }
        function Invoke-SqlServerLabAiExternalModelSqlApply {
            param($SqlPlan,$PreflightReceipt,$RunId,$InstanceId,$CredentialSecret,[switch]$Confirm)
            if ($Confirm -or $RunId -cne '11111111-2222-4333-8444-555555555555' -or $InstanceId -cne 'primary' -or
                $PreflightReceipt.SqlPlanKey -cne $SqlPlan.SqlPlanKey -or $CredentialSecret -isnot [SecureString] -or
                -not $CredentialSecret.Length) { throw 'Fixture SQL Apply binding invalid' }
            $fixture.Applies++
            if($fixture.ApplyFails){throw 'PRIVATE_APPLY_FAILURE_CANARY'}
            [pscustomobject]@{Status='SQL_EXTERNAL_MODEL_APPLIED';SqlPlanKey=$SqlPlan.SqlPlanKey;RunId=$RunId;InstanceId=$InstanceId}
        }
        function Test-SqlServerLabAiExternalModelSqlEmbedding {
            param($SqlPlan,$ApplyReceipt,$RunId,$InstanceId)
            if($ApplyReceipt.SqlPlanKey -cne $SqlPlan.SqlPlanKey -or $ApplyReceipt.RunId -cne $RunId -or
                $ApplyReceipt.InstanceId -cne $InstanceId){throw 'Embedding fixture binding invalid'}
            $fixture.Embeds++
            [pscustomobject]@{Status='SQL_EMBEDDING_VERIFIED';Dimension=3}
        }
        function Remove-SqlServerLabAiExternalModelSql {
            param($SqlPlan,$ApplyReceipt,$RunId,$InstanceId,[switch]$Confirm)
            if($Confirm -or $ApplyReceipt.SqlPlanKey -cne $SqlPlan.SqlPlanKey -or $ApplyReceipt.RunId -cne $RunId -or
                $ApplyReceipt.InstanceId -cne $InstanceId){throw 'Cleanup fixture binding invalid'}
            $fixture.Cleans++
            [pscustomobject]@{Status='SQL_EXTERNAL_MODEL_CLEANED'}
        }
        function Read-LabConsoleTextInput {
            param($Prompt,$Default,[switch]$MaskInput,[switch]$AsSecureString)
            $fixture.Prompts.Add("$MaskInput/$AsSecureString")
            $fixture.Inputs.Dequeue()
        }
        function Write-LabInfo { param($Message) $fixture.Logs.Add($Message) }
        function Write-LabWarning { param($Message) $fixture.Logs.Add($Message) }
        function Wait-LabConsoleAcknowledgement {}
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) $Items }

        try {
            $payload=@{Plan=$FixturePlan;Confirmed=$false;TrustedRootPem=$FixturePem;ApiKeyReference='SQL_SERVER_LAB_SECRET_SYNTHETIC'}
            try { Invoke-LabGuidedExternalModelEndpointHttp ($payload|ConvertTo-Json -Depth 8); $rejected=$false }
            catch { $rejected=$true }
            Assert-GuidedEndpoint ($rejected -and $fixture.Probes -eq 0 -and $fixture.VaultReads -eq 0) 'Unconfirmed HTTP request makes no query'
            $payload.Confirmed=$true
            $payload.TrustedRootPem=$FixturePem+[Environment]::NewLine+'-----BEGIN PRIVATE KEY-----'+[Environment]::NewLine+'INVALID'
            try { Invoke-LabGuidedExternalModelEndpointHttp ($payload|ConvertTo-Json -Depth 8); $rejected=$false }
            catch { $rejected=$_.Exception.Message -ceq 'AI_EXTERNAL_MODEL_GUIDED_CA_INVALID' }
            Assert-GuidedEndpoint ($rejected -and $fixture.Probes -eq 0 -and $fixture.VaultReads -eq 0) 'Combined certificate/key content is rejected before Vault or probe'
            $payload.TrustedRootPem=$FixturePem
            $result=Invoke-LabGuidedExternalModelEndpointHttp ($payload|ConvertTo-Json -Depth 8)
            Assert-GuidedEndpoint ($fixture.Probes -eq 1 -and $fixture.VaultReads -eq 1 -and $fixture.TrustedRoot -and $fixture.KeyBound -and
                $result.Status -ceq 'ENDPOINT_VERIFIED' -and $result.PlanKey -ceq $FixturePlan.PlanKey -and
                ($result|ConvertTo-Json -Depth 8) -cnotmatch 'FIXTURE_PRIVATE_CANARY|SYNTHETIC|BEGIN CERTIFICATE') 'One HTTPS probe validates, binds and projects the receipt'
            $fixture.Drift=$true
            $payload.ApiKeyReference=''
            try { Invoke-LabGuidedExternalModelEndpointHttp ($payload|ConvertTo-Json -Depth 8); $rejected=$false }
            catch { $rejected=$_.Exception.Message -ceq 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_MISMATCH' }
            Assert-GuidedEndpoint ($rejected -and $fixture.Probes -eq 2 -and $fixture.VaultReads -eq 1) 'Foreign receipt is withheld without retry'
            $fixture.Drift=$false
            $entry=@(Show-LabHostModelsMenu | Where-Object Id -CEQ 'ExternalModelEndpoint')
            Assert-GuidedEndpoint ($entry.Count -eq 1) 'Guided inspection is reachable from host models'
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$PlanFile})
            Invoke-LabMenuAction -ActionName $entry[0].Id
            Assert-GuidedEndpoint ($fixture.Probes -eq 2 -and $fixture.Prompts.Count -eq 1) 'CLI decline stops before CA and key input'
            $fixture.Confirmed=$true
            $fixture.Prompts.Clear()
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$PlanFile})
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=''})
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$dummy.Copy()})
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value='AiLab'})
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value='300'})
            Invoke-LabMenuAction -ActionName $entry[0].Id
            Assert-GuidedEndpoint ($fixture.Probes -eq 3 -and $fixture.KeyBound -and -not $fixture.TrustedRoot -and
                ($fixture.Prompts -join ',') -ceq 'True/False,True/False,False/True,False/False,False/False' -and
                ($fixture.Logs -join ' ') -match 'ENDPOINT_VERIFIED' -and
                ($fixture.Logs -join ' ') -cnotmatch 'FIXTURE_PRIVATE_CANARY|SyntheticOnlyEndpointKey') 'CLI uses masked inputs and keeps the bound receipt available'
            Assert-GuidedEndpoint (($fixture.Logs -join ' ') -match 'LIVE_ENDPOINT_BOUND' -and
                ($fixture.Logs -join ' ') -match '"DatabaseName": "AiLab"' -and
                $fixture.Inputs.Count -eq 0) 'CLI hands off the exact Plan and Receipt without another network request or path input'

            $sqlEntry=@(Show-LabHostModelsMenu | Where-Object Id -CEQ 'ExternalModelSqlPreflight')
            Assert-GuidedEndpoint ($sqlEntry.Count -eq 1 -and $fixture.SqlChecks -eq 0) 'SQL preflight is separately reachable and the prior handoff did not query SQL'
            $sqlPlan=Get-SqlServerLabAiExternalModelSqlPlan -Plan $FixturePlan -EndpointReceipt $result -DatabaseName AiLab
            $sqlFile=Join-Path (Split-Path -Parent $PlanFile) 'guided-model-sql-plan.json'
            [IO.File]::WriteAllText($sqlFile,($sqlPlan|ConvertTo-Json -Depth 10 -Compress))
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$sqlFile})
            Invoke-LabMenuAction -ActionName $sqlEntry[0].Id
            Assert-GuidedEndpoint ($fixture.SqlChecks -eq 0) 'CLI declined SQL target does not open SQL'
            $fixture.SqlAllowed=$true
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$sqlFile})
            Invoke-LabMenuAction -ActionName $sqlEntry[0].Id
            Assert-GuidedEndpoint ($fixture.SqlChecks -eq 1 -and ($fixture.Logs -join ' ') -match 'SQL_PREFLIGHT_VERIFIED') 'CLI confirmed SQL preflight passes the plan and exact target to the public API'

            Assert-GuidedEndpoint ($fixture.Applies -eq 0 -and $fixture.Inputs.Count -eq 0) 'Verified preflight only offers an optional lifecycle'
            $selection=Select-LabAiTargetInteractive
            $preflight=[pscustomobject]@{Status='SQL_PREFLIGHT_VERIFIED';SqlPlanKey=$sqlPlan.SqlPlanKey;RunId=$selection.RunId;InstanceId=$selection.InstanceId}
            $fixture.LifecycleChoices.Enqueue('apply')
            $fixture.LifecycleConsents.Enqueue($false)
            Invoke-LabGuidedExternalModelSqlLifecycleInteractive -Plan $sqlPlan -PreflightReceipt $preflight -Selection $selection
            Assert-GuidedEndpoint ($fixture.Applies -eq 0 -and $fixture.Inputs.Count -eq 0) 'Declining Apply leaves the credential and SQL untouched'
            foreach($choice in @('apply','embedding','cleanup','cleanup')){$fixture.LifecycleChoices.Enqueue($choice)}
            foreach($consent in @($true,$true,$false,$true)){$fixture.LifecycleConsents.Enqueue($consent)}
            $applySecret=$dummy.Copy()
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$applySecret})
            Invoke-LabGuidedExternalModelSqlLifecycleInteractive -Plan $sqlPlan -PreflightReceipt $preflight -Selection $selection
            $disposed=try { $copy=$applySecret.Copy();$copy.Dispose();$false } catch { $true }
            Assert-GuidedEndpoint ($fixture.Applies -eq 1 -and $fixture.Embeds -eq 1 -and $fixture.Cleans -eq 1 -and $disposed -and
                $fixture.Inputs.Count -eq 0 -and $fixture.LifecycleChoices.Count -eq 0 -and $fixture.LifecycleConsents.Count -eq 0 -and
                ($fixture.Logs -join ' ') -match 'SQL_EXTERNAL_MODEL_CLEANED') 'CLI lifecycle binds one Apply, Embedding and Cleanup with separate confirmation'
            $fixture.ApplyFails=$true
            $fixture.LifecycleChoices.Enqueue('apply')
            $fixture.LifecycleConsents.Enqueue($true)
            $fixture.Inputs.Enqueue([pscustomobject]@{Status='Confirmed';Value=$dummy.Copy()})
            Invoke-LabGuidedExternalModelSqlLifecycleInteractive -Plan $sqlPlan -PreflightReceipt $preflight -Selection $selection
            Assert-GuidedEndpoint ($fixture.Applies -eq 2 -and $fixture.Embeds -eq 1 -and $fixture.Cleans -eq 1 -and
                ($fixture.Logs -join ' ') -cnotmatch 'PRIVATE_APPLY_FAILURE_CANARY|SyntheticOnlyEndpointKey') 'Unconfirmed Apply stops follow-ups and keeps raw errors and credentials out of output'

            $tokens=$null;$errors=$null
            $server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ModuleRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw 'GUIDED_ENDPOINT_ROUTE_PARSE' }
            $route=$server.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/ai-external-model/endpoint'''},$true)
            $handler=[scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
            . (Join-Path $script:ModuleRoot 'Tools/WorkflowUiJsonBody.ps1')
            function Write-UiResponse {
                param($Context,$Body,$ContentType,$StatusCode=200,[switch]$NoStore)
                [pscustomobject]@{StatusCode=$StatusCode;Body=$Body;NoStore=$NoStore.IsPresent}
            }
            $url='http://127.0.0.1:8484/'
            $payload.TrustedRootPem=''
            $bytes=[Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Depth 8))
            $stream=[IO.MemoryStream]::new($bytes)
            $context=[pscustomobject]@{Request=[pscustomobject]@{Url=[Uri]($url+'api/ai-external-model/endpoint')
                HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:8485'}
                ContentLength64=[long]$bytes.Length;InputStream=$stream}}
            try {
                $denied=& $handler
                Assert-GuidedEndpoint ($denied.StatusCode -eq 400 -and $stream.CanRead -and $fixture.Probes -eq 3) 'Foreign origin is rejected before the request body or probe'
                $context.Request.Headers.Origin=$url.TrimEnd('/')
                $allowed=& $handler
                Assert-GuidedEndpoint ($allowed.StatusCode -eq 200 -and $fixture.Probes -eq 4 -and
                    ($allowed.Body|ConvertFrom-Json).PlanKey -ceq $FixturePlan.PlanKey) 'Actual route uses the bounded reader and confirmed public probe'
            } finally { $stream.Dispose() }
            $route=$server.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/ai-external-model/sql-preflight'''},$true)
            $preflightHandler=[scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
            $jobs=@{}
            $created=[pscustomobject]@{Count=0;Bound=$false}
            function Start-UiWorkflowJob {
                param($Action,$Parameters)
                $created.Count++
                $created.Bound=$Action -ceq 'ReadExternalModelSqlPreflight' -and $Parameters.Count -eq 3 -and
                    $Parameters.SqlPlan.SqlPlanKey -ceq $sqlPlan.SqlPlanKey -and $Parameters.InstanceId -ceq 'primary' -and
                    $Parameters.RunId -ceq '11111111-2222-4333-8444-555555555555'
                [pscustomobject]@{Id='fixture-job';Action=$Action;Job=[pscustomobject]@{State='Running'}}
            }
            $preflightBytes=[Text.Encoding]::UTF8.GetBytes((@{parameters=@{SqlPlan=$sqlPlan;RunId='11111111-2222-4333-8444-555555555555';InstanceId='primary'}} |
                ConvertTo-Json -Depth 9 -Compress))
            $stream=[IO.MemoryStream]::new($preflightBytes)
            $context.Request.Url=[Uri]($url+'api/ai-external-model/sql-preflight')
            $context.Request.Headers.Origin='http://127.0.0.1:8485'
            $context.Request.ContentLength64=[long]$preflightBytes.Length
            $context.Request.InputStream=$stream
            try {
                $denied=& $preflightHandler
                Assert-GuidedEndpoint ($denied.StatusCode -eq 400 -and $denied.NoStore -and $stream.Position -eq 0 -and $created.Count -eq 0) 'Foreign origin cannot queue the SQL probe'
                $context.Request.Headers.Origin=$url.TrimEnd('/')
                $allowed=& $preflightHandler
                Assert-GuidedEndpoint ($allowed.StatusCode -eq 202 -and $allowed.NoStore -and $created.Count -eq 1 -and $created.Bound -and
                    $jobs.ContainsKey('fixture-job')) 'Valid request queues one bound transient SQL read'
                $stream.Position=0
                $busy=& $preflightHandler
                Assert-GuidedEndpoint ($busy.StatusCode -eq 409 -and $created.Count -eq 1) 'A second request cannot queue while the read is active'
            } finally { $stream.Dispose() }
        } finally { $dummy.Dispose() }
        Write-Host "GUIDED HTTPS MODEL ENDPOINT: PASS ($($fixture.Assertions); synthetic transport)"
        $true
    } $Plan $file $certificate.ExportCertificatePem()
} finally {
    if ($certificate) { $certificate.Dispose() }
    $rsa.Dispose()
}
