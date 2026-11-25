#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
    $h='a'*64;$caHash='b'*64;$c1=[pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'}
    $c2=[pscustomobject]@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='secondary';DatabaseId='44444444-4444-4444-8444-444444444444';ExternalModelName='SharedEmbedding2';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_B'}
    $planArgs=@{GatewayId='shared-ai';Location='https://host.docker.internal:18443/v1/embeddings';UpstreamBackend='LlamaCppCuda';UpstreamLocation='http://127.0.0.1:18080/v1/embeddings';RuntimeModel='bound-model';Dimension=768;InputProfile='nomic-search';ModelSha256=$h;RuntimeSha256=$h;ServerCertificateSha256=$h;CertificateAuthoritySha256=$caHash;Consumer=@($c2,$c1)}
    $plan=Get-SqlServerLabAiSharedGatewayPlan @planArgs
    Add-CheckResult 'Plan ist geheimnisfrei, blockiert und schema-valide' ($plan.Status -ceq 'BLOCKED' -and $plan.EvidenceStatus -ceq 'CONFIGURATION_ONLY' -and ($plan|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-plan.schema.json')))
    $reordered=@{}+$planArgs;$reordered.Consumer=@($c1,$c2);$reorderedPlan=Get-SqlServerLabAiSharedGatewayPlan @reordered
    Add-CheckResult 'Verbraucherreihenfolge ist kanonisch und ändert PlanKey nicht' ($plan.Consumers[0].RunId -ceq $c1.RunId -and $reorderedPlan.PlanKey -ceq $plan.PlanKey)
    Add-CheckResult 'Plan bindet nur Verbraucherreferenzen, lokalen Endpunkt und Inhaltsdigests' ($plan.Consumers[0].ApiKeyReference -ceq 'SQL_SERVER_LAB_SECRET_SHARED_AI_A' -and $plan.Location -ceq 'https://host.docker.internal:18443/v1/embeddings' -and $plan.PSObject.Properties.Name -notcontains 'ApiKey')
    $publicLocation=@{}+$planArgs;$publicLocation.Location='https://example.com:18443/v1/embeddings'
    Add-CheckResult 'Öffentliches Gatewayziel wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @publicLocation} 'AI_SHARED_GATEWAY_LOCATION_INVALID')
    $remote=@{}+$planArgs;$remote.UpstreamLocation='https://example.com/v1/embeddings'
    Add-CheckResult 'Nicht-Loopback-Upstream wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @remote} 'AI_SHARED_GATEWAY_UPSTREAM_INVALID')
    $wrongPath=@{}+$planArgs;$wrongPath.UpstreamBackend='OpenVinoModelServer'
    Add-CheckResult 'Falscher Backendpfad wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @wrongPath} 'AI_SHARED_GATEWAY_UPSTREAM_INVALID')
    $sameCertificate=@{}+$planArgs;$sameCertificate.CertificateAuthoritySha256=$sameCertificate.ServerCertificateSha256
    Add-CheckResult 'Identische CA- und Serverzertifikathashes werden abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @sameCertificate} 'AI_SHARED_GATEWAY_CERTIFICATE_HASHES_MUST_DIFFER')
    $sameCertificate.CertificateAuthoritySha256=$sameCertificate.ServerCertificateSha256.ToUpperInvariant()
    Add-CheckResult 'Zertifikatidentität ist unabhängig von hexadezimaler Großschreibung' (Reject {Get-SqlServerLabAiSharedGatewayPlan @sameCertificate} 'AI_SHARED_GATEWAY_CERTIFICATE_HASHES_MUST_DIFFER')
    $duplicate=@{}+$planArgs;$duplicate.Consumer=@($c1,$c1)
    Add-CheckResult 'Doppelter Verbraucher wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @duplicate} 'AI_SHARED_GATEWAY_CONSUMER_DUPLICATE')
    $sameSecret=$c2|Select-Object *;$sameSecret.ApiKeyReference=$c1.ApiKeyReference
    $duplicateSecret=@{}+$planArgs;$duplicateSecret.Consumer=@($c1,$sameSecret)
    Add-CheckResult 'Geteilte Verbraucher-Secretreferenz wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @duplicateSecret} 'AI_SHARED_GATEWAY_SECRET_REFERENCE_DUPLICATE')
    $extra=$c1|Select-Object *,@{n='HostName';e={'private-host'}}
    $withHost=@{}+$planArgs;$withHost.Consumer=@($extra)
    Add-CheckResult 'Zusätzliche Hostdaten im Verbraucher werden abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @withHost} 'AI_SHARED_GATEWAY_CONSUMER_INVALID')
    Add-CheckResult 'Öffentlicher Befehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiSharedGatewayPlan).ModuleName -ceq 'SqlServerLab')

    $body=$planArgs | ConvertTo-Json -Depth 8 -Compress
    $formPlan=& $module {param($Value) Invoke-LabAiSharedGatewayPlanForm -Body $Value} $body
    Add-CheckResult 'Nur die gebundene Konfiguration erreicht den echten Planvertrag' ($formPlan.PlanKey -ceq $plan.PlanKey -and $formPlan.Status -ceq 'BLOCKED')
    $wrongKind=@{}+$planArgs;$wrongKind.Dimension=[string]$wrongKind.Dimension
    $foreignField=@{}+$planArgs;$foreignField.ApiKey='SYNTHETIC_NOT_ALLOWED'
    $foreignConsumer=$c1 | Select-Object *,@{n='Host';e={'SYNTHETIC_NOT_ALLOWED'}}
    $wrongConsumer=@{}+$planArgs;$wrongConsumer.Consumer=@($foreignConsumer)
    $tooMany=@{}+$planArgs;$tooMany.Consumer=@($c1)*65
    foreach ($case in @(
        @{Name='string dimension'; Body=($wrongKind | ConvertTo-Json -Depth 8 -Compress)},
        @{Name='credential field'; Body=($foreignField | ConvertTo-Json -Depth 8 -Compress)},
        @{Name='extra consumer field'; Body=($wrongConsumer | ConvertTo-Json -Depth 8 -Compress)},
        @{Name='consumer bound'; Body=($tooMany | ConvertTo-Json -Depth 8 -Compress)},
        @{Name='duplicate key'; Body=$body.Insert(1, '"GatewayId":"duplicate",')},
        @{Name='byte bound'; Body=(' ' * 65536)+$body}
    )) {
        Add-CheckResult ('Formgrenze verwirft '+$case.Name) (Reject { & $module {param($Value) Invoke-LabAiSharedGatewayPlanForm -Body $Value} $case.Body } 'AI_SHARED_GATEWAY_FORM_INVALID')
    }

    $console=& $module {
        param($Case,$FirstConsumer,$SecondConsumer)
        & {
            $planner=${function:Get-SqlServerLabAiSharedGatewayPlan}
            $script:guidedPlannerCalls=0
            $script:guidedPlan=$null
            $script:guidedStatusKeys=[Collections.Generic.List[string]]::new()
            $script:guidedUpstreamKeys=[Collections.Generic.List[string]]::new()
            $script:guidedPreflightKeys=[Collections.Generic.List[string]]::new()
            $script:guidedRegistrationKeys=[Collections.Generic.List[string]]::new()
            $script:guidedServicePlanKeys=[Collections.Generic.List[string]]::new()
            $script:guidedSessionStartKeys=[Collections.Generic.List[string]]::new()
            $script:guidedText=[Collections.Generic.Queue[string]]::new()
            $script:guidedChoices=[Collections.Generic.Queue[string]]::new()
            function New-LabConsoleItem { param($Id,$Label) [pscustomobject]@{Id=$Id;Label=$Label} }
            function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) $Items }
            function Invoke-LabConsoleMenu {
                param($ScreenId,$Title,$Subtitle,$Items)
                $choice=$script:guidedChoices.Dequeue()
                if ($choice -ceq 'ESC') { return [pscustomobject]@{Status='Cancelled'} }
                [pscustomobject]@{Status='Selected';SelectedItem=($Items | Where-Object Id -CEQ $choice)}
            }
            function Read-LabConsoleTextInput { param($Prompt) [pscustomobject]@{Status='Confirmed';Value=$script:guidedText.Dequeue()} }
            function Write-LabInfo { param($Message) }
            function Write-LabWarning { throw 'UNEXPECTED_GUIDED_PLAN_WARNING' }
            function Wait-LabConsoleAcknowledgement {}
            function Get-SqlServerLabAiSharedGatewayPlan {
                param($GatewayId,$Location,$UpstreamBackend,$UpstreamLocation,$RuntimeModel,$Dimension,$InputProfile,
                    $ModelSha256,$RuntimeSha256,$ServerCertificateSha256,$CertificateAuthoritySha256,$Consumer)
                $script:guidedPlannerCalls++
                $script:guidedPlan=& $planner @PSBoundParameters
                return $script:guidedPlan
            }
            function Get-SqlServerLabAiSharedGatewayStatus {
                param($Plan)
                $script:guidedStatusKeys.Add($Plan.PlanKey)
                [pscustomobject]@{GatewayId=$Plan.GatewayId;Status='NOT_REGISTERED';ReasonCode='AI_SHARED_GATEWAY_STATUS_NOT_REGISTERED'}
            }
            function Test-SqlServerLabAiSharedGatewayUpstream {
                param($Plan)
                $script:guidedUpstreamKeys.Add($Plan.PlanKey)
                [pscustomobject]@{GatewayId=$Plan.GatewayId;Status='UPSTREAM_VERIFIED';Dimension=768;DurationMilliseconds=4;PendingEvidence=@('PERSISTENT_GATEWAY_SERVICE')}
            }
            function Invoke-LabAiSharedGatewayFileActionInteractive {
                param($Plan,[switch]$Register)
                if ($Register) { $script:guidedRegistrationKeys.Add($Plan.PlanKey) }
                else { $script:guidedPreflightKeys.Add($Plan.PlanKey) }
            }
            function Invoke-LabAiSharedGatewayServicePlanInteractive {
                param($Plan)
                $script:guidedServicePlanKeys.Add($Plan.PlanKey)
            }
            function Invoke-LabAiSharedGatewaySessionStartInteractive {
                param($Plan)
                $script:guidedSessionStartKeys.Add($Plan.PlanKey)
            }
            $entry = @(Show-LabHostModelsMenu | Where-Object Id -CEQ 'AiSharedGatewayPlan')
            if ($entry.Count -ne 1) { throw 'GATEWAY_GUIDED_MENU_ENTRY_INVALID' }
            $script:guidedChoices.Enqueue('ESC')
            Invoke-LabMenuAction -ActionName $entry[0].Id
            $cancelled=$script:guidedPlannerCalls -eq 0
            foreach($next in @('back','status','upstream','preflight','register','service','start')) {
                foreach($name in @('GatewayId','Location','UpstreamLocation','RuntimeModel','Dimension','ModelSha256','RuntimeSha256',
                    'ServerCertificateSha256','CertificateAuthoritySha256')){ $script:guidedText.Enqueue([string]$Case[$name]) }
                foreach($consumer in @($FirstConsumer,$SecondConsumer)){
                    foreach($name in @('RunId','InstanceId','DatabaseId','ExternalModelName','ApiKeyReference')){ $script:guidedText.Enqueue($consumer.$name) }
                }
                foreach($choice in @($Case.UpstreamBackend,$Case.InputProfile,'add','preview',$next)){ $script:guidedChoices.Enqueue($choice) }
                Invoke-LabMenuAction -ActionName $entry[0].Id
            }
            [pscustomobject]@{CancelNoPlan=$cancelled; Calls=$script:guidedPlannerCalls; Key=$script:guidedPlan.PlanKey; Count=$script:guidedPlan.Consumers.Count; StatusKeys=$script:guidedStatusKeys.ToArray();UpstreamKeys=$script:guidedUpstreamKeys.ToArray();PreflightKeys=$script:guidedPreflightKeys.ToArray();RegistrationKeys=$script:guidedRegistrationKeys.ToArray();ServicePlanKeys=$script:guidedServicePlanKeys.ToArray();SessionStartKeys=$script:guidedSessionStartKeys.ToArray()}
        }
    } $planArgs $c2 $c1
    Add-CheckResult 'Geführte CLI verwendet denselben Plan mit mehreren Verbrauchern und verwirft Esc' (
        $console.CancelNoPlan -and $console.Calls -eq 7 -and $console.Key -ceq $plan.PlanKey -and $console.Count -eq 2)
    Add-CheckResult 'CLI liest den Status nur auf Auswahl und mit dem unveränderten Plan' (
        $console.StatusKeys.Count -eq 1 -and $console.StatusKeys[0] -ceq $plan.PlanKey)
    Add-CheckResult 'CLI prüft den Upstream nur auf Auswahl und mit dem unveränderten Plan' (
        $console.UpstreamKeys.Count -eq 1 -and $console.UpstreamKeys[0] -ceq $plan.PlanKey)
    Add-CheckResult 'CLI öffnet die Dateiprüfung nur auf Auswahl und mit dem unveränderten Plan' (
        $console.PreflightKeys.Count -eq 1 -and $console.PreflightKeys[0] -ceq $plan.PlanKey)
    Add-CheckResult 'CLI öffnet die Registrierung nur auf Auswahl und mit dem unveränderten Plan' (
        $console.RegistrationKeys.Count -eq 1 -and $console.RegistrationKeys[0] -ceq $plan.PlanKey)
    Add-CheckResult 'CLI öffnet den Dienstplan nur auf Auswahl und mit dem unveränderten Gateway-Plan' (
        $console.ServicePlanKeys.Count -eq 1 -and $console.ServicePlanKeys[0] -ceq $plan.PlanKey)
    Add-CheckResult 'CLI öffnet den befristeten Start nur auf Auswahl und mit dem unveränderten Gateway-Plan' (
        $console.SessionStartKeys.Count -eq 1 -and $console.SessionStartKeys[0] -ceq $plan.PlanKey)

    $statusRoot=Join-Path ([IO.Path]::GetTempPath()) ('gateway-unregistered-'+[guid]::NewGuid().ToString('N'))
    $commandReceipt=& $module {
        param($Plan,$SyntheticRoot)
        & {
            function Get-LabStateRoot { return $SyntheticRoot }
            Invoke-LabPublicCommandWebRequest -CommandName 'Get-SqlServerLabAiSharedGatewayStatus' -ParameterSetName '__AllParameterSets' -Parameters @{Plan=$Plan}
        }
    } $plan $statusRoot
    Add-CheckResult 'Der Browser-Befehl liest die Registrierung im voreingestellten StateRoot ohne Schreibzugriff' (
        $commandReceipt.Result.Count -eq 1 -and $commandReceipt.Result[0].PlanKey -ceq $plan.PlanKey -and
        $commandReceipt.Result[0].Status -ceq 'NOT_REGISTERED' -and -not (Test-Path -LiteralPath $statusRoot))

    $upstreamReceipt = & $module {
        param($Plan)
        & {
            function Test-LabAiSharedGatewayUpstream {
                param($Plan,$StateRoot,$ApiKey,$TimeoutSeconds)
                if ($StateRoot -or $ApiKey -or $TimeoutSeconds -ne 30) { throw 'UNEXPECTED_UPSTREAM_GUIDED_AUTHORITY' }
                [pscustomobject]@{PlanKey=$Plan.PlanKey;Status='UPSTREAM_VERIFIED'}
            }
            Invoke-LabPublicCommandWebRequest -CommandName 'Test-SqlServerLabAiSharedGatewayUpstream' -ParameterSetName '__AllParameterSets' -Parameters @{Plan=$Plan}
        }
    } $plan
    Add-CheckResult 'Der Browser-Befehl reicht ausschließlich den Plan an die vorhandene Upstream-Prüfung' (
        $upstreamReceipt.Result.Count -eq 1 -and $upstreamReceipt.Result[0].PlanKey -ceq $plan.PlanKey -and
        $upstreamReceipt.Result[0].Status -ceq 'UPSTREAM_VERIFIED')

    $tokens=$null;$errors=$null
    $server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'GATEWAY_TEST_SERVER_PARSE_FAILED' }
    $route=$server.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/ai-shared-gateway/plan'''},$true)
    $handler=[scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
    & {
        $url='http://localhost:18432/'
        $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';
            Url=[uri]($url+'api/ai-shared-gateway/plan');Headers=@{Origin=$url.TrimEnd('/')}}}
        $script:gatewayPlanBodyReads=0
        function Read-UiJsonRequestBody {
            param($Request,$MaxBytes)
            if ($MaxBytes -ne 65536) { throw 'GATEWAY_TEST_BODY_LIMIT_MISSING' }
            $script:gatewayPlanBodyReads++
            [pscustomobject]@{Allowed=$true;Body=$body}
        }
        function Write-UiResponse {
            param($Context,$Body,$ContentType,$StatusCode=200)
            $script:gatewayPlanHttp=[pscustomobject]@{StatusCode=$StatusCode;Body=$Body}
        }
        & $handler
        Add-CheckResult 'Tatsächlicher Browser-Handler liefert den unveränderten Konfigurationsplan' (
            $script:gatewayPlanHttp.StatusCode -eq 200 -and ($script:gatewayPlanHttp.Body | ConvertFrom-Json).PlanKey -ceq $plan.PlanKey)
        $context.Request.Headers.Origin='http://localhost:18433'
        & $handler
        Add-CheckResult 'Fremder Browser-Origin scheitert vor Body und öffentlichem Plan' (
            $script:gatewayPlanHttp.StatusCode -eq 400 -and $script:gatewayPlanBodyReads -eq 1)
    }
}
finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY PLAN: PASS ($passed)"
$node=Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$start=[Diagnostics.ProcessStartInfo]::new($node.Source)
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.ArgumentList.Add((Join-Path $PSScriptRoot 'Fixtures/AiSharedGatewayPlanUiChecks.cjs'))
$process=[Diagnostics.Process]::Start($start)
try {
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'AI_SHARED_GATEWAY_BROWSER_TEST_SHUTDOWN_FAILED' }
        throw 'AI_SHARED_GATEWAY_BROWSER_TEST_TIMEOUT'
    }
    Write-Host $stdout.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        Write-Host $stderr.GetAwaiter().GetResult()
        throw 'AI_SHARED_GATEWAY_BROWSER_TEST_FAILED'
    }
}
finally { $process.Dispose() }
