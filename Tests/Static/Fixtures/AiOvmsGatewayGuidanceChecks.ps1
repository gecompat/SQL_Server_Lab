param([Management.Automation.PSModuleInfo]$Module, [string]$ArtifactRoot, [string]$ExistingOperationId)

$certificate = Join-Path $ArtifactRoot 'guided-ovms-cert.pem'
$privateKey = Join-Path $ArtifactRoot 'guided-ovms-key.pem'
[IO.File]::WriteAllText($certificate, 'synthetic certificate fixture')
[IO.File]::WriteAllText($privateKey, 'synthetic key fixture')

& $Module {
    param($certificate, $privateKey, $foreignId)

    $inputValues = @{
        UpstreamLocation='http://127.0.0.1:9000/v3/embeddings'; RuntimeModel='guided-model'
        CertificatePath=$certificate; PrivateKeyPath=$privateKey; TrustedRootPath=''
        StartTimeoutSeconds=30; LeaseSeconds=900; Dimension=3; Port=18443
    }
    $parameters = New-LabGuidedOvmsGatewayParameters -InputObject $inputValues
    if ($parameters.Dimension -ne 3 -or $parameters.CertificatePath -cne $certificate) { throw 'OVMS_GUIDED_FIELDS_TEST' }
    $invalid = $inputValues.Clone()
    $invalid.LeaseSeconds = 30
    $rejected = try { $null = New-LabGuidedOvmsGatewayParameters -InputObject $invalid -SyntaxOnly; $false }
        catch { $_.Exception.Message -ceq 'AI_OVMS_GUIDED_INPUT_INVALID' }
    if (-not $rejected) { throw 'OVMS_GUIDED_BUDGET_TEST' }
    if (-not $IsWindows) { return $true }

    $fixtureSecret = [Security.SecureString]::new()
    for ($index = 0; $index -lt 32; $index++) { $fixtureSecret.AppendChar('a') }
    $fixtureSecret.MakeReadOnly()
    function Get-Secret {
        [CmdletBinding()]
        param([string]$Name)
        if ($Name -cne 'SQL_SERVER_LAB_SECRET_SYNTHETIC_OVMS') { throw 'OVMS_GUIDED_VAULT_TEST' }
        return $fixtureSecret
    }
    function Start-SqlServerLabOvmsHttpsGateway {
        param($UpstreamLocation,$RuntimeModel,$Dimension,$Port,$CertificatePath,$PrivateKeyPath,$StartTimeoutSeconds,$LeaseSeconds,$ApiKey)
        $id = [guid]::NewGuid().ToString('D')
        $script:AiOvmsGatewaySessions[$id] = @{Port=$Port;Worker=[pscustomobject]@{HasExited=$false}}
        $identity = [ordered]@{
            Contract='SqlServerLab.AiOvmsHttpsGatewayBinding/1.0'; OperationId=$id; LeaseSeconds=$LeaseSeconds
            UpstreamBindingKey='b' * 64; Location="https://127.0.0.1:$Port/v3/embeddings"
            RuntimeModel=$RuntimeModel; Dimension=$Dimension; ServerCertificateSha256='c' * 64
        }
        $bindingKey = Get-LabAiPlanKey -InputObject $identity
        $identity.Contract = 'SqlServerLab.AiOvmsHttpsGateway/1.0'
        $identity.Status = 'ENDPOINT_VERIFIED'
        $identity.BindingKey = $bindingKey
        [pscustomobject]$identity
    }
    function Stop-SqlServerLabOvmsHttpsGateway {
        param($OperationId)
        if ($OperationId -ceq $foreignId -or -not $script:AiOvmsGatewaySessions.ContainsKey($OperationId)) {
            throw 'OVMS_GUIDED_STOP_WRONG_TARGET_TEST'
        }
        $script:AiOvmsGatewaySessions.Remove($OperationId)
        [pscustomobject]@{OperationId=$OperationId;Status='CLEANUP_SUCCEEDED'}
    }

    $prior = $script:AiOvmsGatewaySessions
    $script:AiOvmsGatewaySessions = @{
        $foreignId = @{Port=18442;Worker=[pscustomobject]@{HasExited=$false}}
    }
    try {
        $scope = @{}
        $request = $inputValues.Clone()
        $request.Action = 'Start'
        $request.Confirmed = $false
        $request.ApiKeyReference = 'SQL_SERVER_LAB_SECRET_SYNTHETIC_OVMS'
        $rejected = try { $null = Invoke-LabGuidedOvmsBrowserGatewaySession $scope ($request | ConvertTo-Json -Compress); $false }
            catch { $_.Exception.Message -ceq 'AI_SHARED_GATEWAY_FORM_INVALID' }
        if (-not $rejected -or $scope.Count -ne 0 -or $script:AiOvmsGatewaySessions.Count -ne 1) { throw 'OVMS_GUIDED_CONFIRM_TEST' }
        $request.Confirmed = $true
        $result = Invoke-LabGuidedOvmsBrowserGatewaySession $scope ($request | ConvertTo-Json -Compress)
        $view = Get-LabGuidedOvmsBrowserSessionView $scope
        if ($result.Status -cne 'ENDPOINT_VERIFIED' -or $view.Items.Count -ne 1 -or $view.Items[0].OperationId -cne $result.OperationId) {
            throw 'OVMS_GUIDED_OWN_SCOPE_TEST'
        }
        $stop = @{Action='Stop';Confirmed=$true;OperationId=$foreignId}
        $rejected = try { $null = Invoke-LabGuidedOvmsBrowserGatewaySession $scope ($stop | ConvertTo-Json -Compress); $false }
            catch { $_.Exception.Message -ceq 'AI_OVMS_GATEWAY_OWNERSHIP_NOT_FOUND' }
        if (-not $rejected) { throw 'OVMS_GUIDED_FOREIGN_STOP_TEST' }
        $stop.OperationId = $result.OperationId
        $receipt = Invoke-LabGuidedOvmsBrowserGatewaySession $scope ($stop | ConvertTo-Json -Compress)
        return $receipt.Status -ceq 'CLEANUP_SUCCEEDED' -and $scope.Count -eq 0 -and
            $script:AiOvmsGatewaySessions.Count -eq 1 -and $script:AiOvmsGatewaySessions.ContainsKey($foreignId)
    } finally {
        $script:AiOvmsGatewaySessions = $prior
        $fixtureSecret.Dispose()
    }
} $certificate $privateKey $ExistingOperationId
