function New-LabGuidedOvmsGatewayParameters {
    param([hashtable]$InputObject,[switch]$SyntaxOnly)

    $upstream = Resolve-LabAiOvmsUpstreamLocation -Location $InputObject.UpstreamLocation
    if ($InputObject.RuntimeModel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$') { throw 'AI_OVMS_GUIDED_INPUT_INVALID' }
    $parameters = @{UpstreamLocation=$upstream.AbsoluteUri; RuntimeModel=$InputObject.RuntimeModel}
    $limits = @{Dimension=@(1,1998); Port=@(1024,65535); StartTimeoutSeconds=@(1,300); LeaseSeconds=@(30,3600)}
    foreach ($name in $limits.Keys) {
        $number = 0
        if ([string]$InputObject[$name] -cnotmatch '^[0-9]{1,5}$' -or -not [int]::TryParse([string]$InputObject[$name],[ref]$number) -or
            $number -lt $limits[$name][0] -or $number -gt $limits[$name][1]) { throw 'AI_OVMS_GUIDED_INPUT_INVALID' }
        $parameters[$name] = $number
    }
    if ($parameters.LeaseSeconds -le $parameters.StartTimeoutSeconds) { throw 'AI_OVMS_GUIDED_INPUT_INVALID' }
    foreach ($name in @('CertificatePath','PrivateKeyPath','TrustedRootPath')) {
        if ($name -ceq 'TrustedRootPath' -and -not $InputObject[$name]) { continue }
        $parameters[$name] = Resolve-LabAiSharedGatewayGuidedInputPath -Path $InputObject[$name] -SyntaxOnly:$SyntaxOnly
    }
    return $parameters
}

function Invoke-LabGuidedOvmsGatewayStart {
    param([hashtable]$Parameters,[Security.SecureString]$ApiKey)

    if (-not (Test-LabAiSharedGatewayServiceSecretValue -Secret $ApiKey)) { throw 'AI_OVMS_GUIDED_KEY_INVALID' }
    $result = @(Start-SqlServerLabOvmsHttpsGateway @Parameters -ApiKey $ApiKey)
    if ($result.Count -ne 1) { throw 'AI_OVMS_GUIDED_START_UNCONFIRMED' }
    $binding = Resolve-LabAiOvmsHttpsGatewayBinding -Binding $result[0]
    if ($binding.Location -cne ("https://127.0.0.1:{0}/v3/embeddings" -f $Parameters.Port) -or
        $binding.RuntimeModel -cne $Parameters.RuntimeModel -or $binding.Dimension -ne $Parameters.Dimension -or
        $binding.LeaseSeconds -ne $Parameters.LeaseSeconds) { throw 'AI_OVMS_GUIDED_START_UNCONFIRMED' }
    [pscustomobject][ordered]@{
        Contract='SqlServerLab.AiOvmsHttpsGateway/1.0'; Status='ENDPOINT_VERIFIED'; OperationId=$binding.OperationId
        Location=$binding.Location; RuntimeModel=$binding.RuntimeModel; Dimension=$binding.Dimension
        ServerCertificateSha256=$binding.ServerCertificateSha256; UpstreamBindingKey=$binding.UpstreamBindingKey
        LeaseSeconds=$binding.LeaseSeconds; BindingKey=$binding.BindingKey
    }
}

function Invoke-LabGuidedOvmsGatewayStartInteractive {
    if (-not $IsWindows) { Write-LabWarning 'Der OVMS-HTTPS-Worker benötigt Windows.'; return }
    $key = $null
    try {
        $fields = @(
            @{Name='UpstreamLocation'; Label='OVMS-HTTP-Endpunkt auf numerischem IPv4-Loopback'; Default='http://127.0.0.1:9000/v3/embeddings'}
            @{Name='RuntimeModel'; Label='Exakter OVMS-Modellname'}
            @{Name='Dimension'; Label='Embedding-Dimension (1 bis 1998)'}
            @{Name='Port'; Label='Freier HTTPS-Port (1024 bis 65535)'; Default='18443'}
            @{Name='CertificatePath'; Label='Lokales Leaf-Zertifikat als PEM'; Mask=$true}
            @{Name='PrivateKeyPath'; Label='Passender lokaler PEM-Schlüssel'; Mask=$true}
            @{Name='TrustedRootPath'; Label='Optionales öffentliches CA-PEM'; Mask=$true}
            @{Name='StartTimeoutSeconds'; Label='Startbudget in Sekunden (1 bis 300)'; Default='30'}
            @{Name='LeaseSeconds'; Label='Maximale Laufzeit in Sekunden (30 bis 3600)'; Default='900'}
        )
        $values = @{}
        foreach ($field in $fields) {
            $entered = Read-LabConsoleTextInput -Prompt $field.Label -Default ([string]$field.Default) -MaskInput:([bool]$field.Mask)
            if ($entered.Status -cne 'Confirmed') { return }
            $values[$field.Name] = $entered.Value
        }
        $preview = New-LabGuidedOvmsGatewayParameters -InputObject $values -SyntaxOnly
        Write-LabInfo ("OVMS {0} · Modell {1} · Dimension {2} · HTTPS-Port {3} · maximal {4} Sekunden" -f
            $preview.UpstreamLocation,$preview.RuntimeModel,$preview.Dimension,$preview.Port,$preview.LeaseSeconds)
        if (-not (Read-LabConfirm -Prompt 'Genau diesen befristeten lokalen OVMS-HTTPS-Worker nach Schlüsseleingabe starten?' -Default $false)) { return }
        $parameters = New-LabGuidedOvmsGatewayParameters -InputObject $values
        $entered = Read-LabConsoleTextInput -Prompt 'Gateway-API-Schlüssel (24 bis 256 ASCII-Zeichen, maskiert)' -AsSecureString
        if ($entered.Status -cne 'Confirmed') { return }
        if ($entered.Value -isnot [Security.SecureString]) { throw 'AI_OVMS_GUIDED_KEY_INVALID' }
        $key = $entered.Value
        $result = Invoke-LabGuidedOvmsGatewayStart -Parameters $parameters -ApiKey $key
        Write-LabInfo ($result | ConvertTo-Json -Depth 5)
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch { Write-LabWarning 'OVMS-HTTPS-Start unbestätigt. Prüfe Eingaben und eigene Sitzungen in dieser Modulsitzung.' }
    finally { if ($key) { $key.Dispose() } }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabGuidedOvmsGatewayStopInteractive {
    $presented = @{}
    $items = @(if ($script:AiOvmsGatewaySessions) {
        foreach ($id in ($script:AiOvmsGatewaySessions.Keys | Sort-Object)) {
            $session = $script:AiOvmsGatewaySessions[$id]
            $presented[$id] = $session
            New-LabConsoleItem -Id $id -Label ("Port {0} · {1}" -f $session.Port,$id)
        }
    })
    $items += New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
    $chosen = Invoke-LabConsoleMenu -ScreenId 'ovms-gateway-own-stop' -Title 'Eigene OVMS-HTTPS-Sitzung stoppen' -Items $items
    if ($chosen.Status -cne 'Selected' -or -not $presented.ContainsKey([string]$chosen.SelectedItem.Id)) { return }
    $id = [string]$chosen.SelectedItem.Id
    if (-not (Read-LabConfirm -Prompt ("Eigene Sitzung auf Port {0} stoppen? SQL-Verbraucher können die Verbindung verlieren." -f
        $presented[$id].Port) -Default $false)) { return }
    try {
        if (-not $script:AiOvmsGatewaySessions -or -not [object]::ReferenceEquals($script:AiOvmsGatewaySessions[$id],$presented[$id])) {
            throw 'AI_OVMS_GATEWAY_OWNERSHIP_NOT_FOUND'
        }
        $result = @(Stop-SqlServerLabOvmsHttpsGateway -OperationId $id)
        if ($result.Count -ne 1 -or $result[0].OperationId -cne $id -or $result[0].Status -cne 'CLEANUP_SUCCEEDED') {
            throw 'AI_OVMS_GUIDED_STOP_UNCONFIRMED'
        }
        Write-LabInfo 'Eigene OVMS-HTTPS-Sitzung und temporärer Schlüssel sind bereinigt.'
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch { Write-LabWarning 'Ende oder Cleanup der eigenen OVMS-Sitzung unbestätigt.' }
    $null = Wait-LabConsoleAcknowledgement
}

function Get-LabGuidedOvmsBrowserSessionView {
    param([hashtable]$BrowserSessions)

    $items = @(foreach ($id in ($BrowserSessions.Keys | Sort-Object)) {
        $session = if ($script:AiOvmsGatewaySessions) { $script:AiOvmsGatewaySessions[$id] }
        if ($session -and [object]::ReferenceEquals($session,$BrowserSessions[$id])) {
            [pscustomobject]@{OperationId=$id; Port=$session.Port
                Status=$(if ($session.Worker.HasExited) { 'CLEANUP_PENDING' } else { 'OWNED_SESSION' })}
        }
    })
    [pscustomobject]@{Supported=[bool]$IsWindows; VaultAvailable=[bool](Get-Command -Name Get-Secret -ErrorAction SilentlyContinue); Items=$items}
}

function Invoke-LabGuidedOvmsBrowserGatewaySession {
    param([hashtable]$BrowserSessions,[string]$Body)

    if (-not $IsWindows) { throw 'AI_OVMS_GATEWAY_WINDOWS_REQUIRED' }
    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 16384 -or $WhatIfPreference -or
        $ConfirmPreference -notin @([Management.Automation.ConfirmImpact]::High,[Management.Automation.ConfirmImpact]::None)) {
        throw 'AI_OVMS_GUIDED_REQUEST_INVALID'
    }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 2
    try { $document = [Text.Json.JsonDocument]::Parse($Body, $options) }
    catch { throw 'AI_OVMS_GUIDED_REQUEST_INVALID' }
    $key = $null
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_OVMS_GUIDED_REQUEST_INVALID' }
        $action = $root.GetProperty('Action').GetString()
        $fields = @{Action=[Text.Json.JsonValueKind]::String;Confirmed=[Text.Json.JsonValueKind]::True}
        if ($action -ceq 'Stop') {
            $fields.OperationId = [Text.Json.JsonValueKind]::String
            $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $root -Fields $fields
            $id = $values.OperationId.GetString()
            if ($id -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or -not $BrowserSessions.ContainsKey($id) -or
                -not $script:AiOvmsGatewaySessions -or -not [object]::ReferenceEquals($script:AiOvmsGatewaySessions[$id],$BrowserSessions[$id])) {
                throw 'AI_OVMS_GATEWAY_OWNERSHIP_NOT_FOUND'
            }
            $result = @(Stop-SqlServerLabOvmsHttpsGateway -OperationId $id)
            if ($result.Count -ne 1 -or $result[0].OperationId -cne $id -or $result[0].Status -cne 'CLEANUP_SUCCEEDED') {
                throw 'AI_OVMS_GUIDED_STOP_UNCONFIRMED'
            }
            $BrowserSessions.Remove($id)
            return [pscustomobject]@{Status='CLEANUP_SUCCEEDED';OperationId=$id}
        }
        if ($action -cne 'Start') { throw 'AI_OVMS_GUIDED_REQUEST_INVALID' }
        $textFields = @('UpstreamLocation','RuntimeModel','CertificatePath','PrivateKeyPath','TrustedRootPath','ApiKeyReference')
        $numberFields = @('Port','Dimension','StartTimeoutSeconds','LeaseSeconds')
        foreach ($name in $textFields) { $fields[$name]=[Text.Json.JsonValueKind]::String }
        foreach ($name in $numberFields) { $fields[$name]=[Text.Json.JsonValueKind]::Number }
        $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $root -Fields $fields
        $startValues = @{}
        foreach ($name in $textFields) { $startValues[$name]=$values[$name].GetString() }
        foreach ($name in $numberFields) {
            $number=0
            if (-not $values[$name].TryGetInt32([ref]$number)) { throw 'AI_OVMS_GUIDED_INPUT_INVALID' }
            $startValues[$name]=$number
        }
        $reference=$startValues.ApiKeyReference
        if ($reference -cnotmatch '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$') { throw 'AI_OVMS_GUIDED_KEY_INVALID' }
        $parameters=New-LabGuidedOvmsGatewayParameters -InputObject $startValues
        $vault=Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
        if (-not $vault) { throw 'AI_OVMS_GUIDED_VAULT_UNAVAILABLE' }
        try { $secret=@(& $vault -Name $reference -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null) }
        catch { throw 'AI_OVMS_GUIDED_VAULT_UNAVAILABLE' }
        if ($secret.Count -ne 1 -or $secret[0] -isnot [Security.SecureString]) { throw 'AI_OVMS_GUIDED_KEY_INVALID' }
        $key=$secret[0].Copy()
        $existing=@(if ($script:AiOvmsGatewaySessions) { $script:AiOvmsGatewaySessions.Keys })
        try {
            $receipt = Invoke-LabGuidedOvmsGatewayStart -Parameters $parameters -ApiKey $key
        } finally {
            foreach ($id in @(if ($script:AiOvmsGatewaySessions) { $script:AiOvmsGatewaySessions.Keys })) {
                if ($id -and $id -cnotin $existing -and $script:AiOvmsGatewaySessions[$id].Port -eq $parameters.Port) {
                    $BrowserSessions[$id]=$script:AiOvmsGatewaySessions[$id]
                }
            }
        }
        if (-not $BrowserSessions.ContainsKey([string]$receipt.OperationId)) { throw 'AI_OVMS_GUIDED_START_UNCONFIRMED' }
        return $receipt
    } finally {
        $document.Dispose()
        if ($key) { $key.Dispose() }
    }
}

function Close-LabGuidedOvmsBrowserGatewaySession {
    param([hashtable]$BrowserSessions)

    $closed=$true
    foreach ($id in @($BrowserSessions.Keys)) {
        $session=if ($script:AiOvmsGatewaySessions) { $script:AiOvmsGatewaySessions[$id] }
        if ($session -and [object]::ReferenceEquals($session,$BrowserSessions[$id])) {
            try { $null=Stop-LabAiOvmsHttpsGateway -OperationId $id }
            catch { $closed=$false;continue }
        }
        $BrowserSessions.Remove($id)
    }
    return $closed
}
