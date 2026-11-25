# The synchronous UI routes keep worker custody in the module that opened it.
function Get-LabAiSharedGatewayBrowserSessions {
    param([hashtable]$BrowserSessions)

    $items = @(foreach ($id in ($BrowserSessions.Keys | Sort-Object)) {
        $session = if ($script:AiSharedGatewaySessions) { $script:AiSharedGatewaySessions[$id] }
        if ($session -and [object]::ReferenceEquals($session,$BrowserSessions[$id])) {
            [pscustomobject]@{
                OperationId=$id; GatewayId=$session.GatewayId; Port=$session.Port
                Status=$(if ($session.Worker.HasExited) { 'CLEANUP_PENDING' } else { 'OWNED_SESSION' })
            }
        }
    })
    [pscustomobject]@{ Items=$items; VaultAvailable=[bool](Get-Command -Name Get-Secret -ErrorAction SilentlyContinue) }
}

function Invoke-LabAiSharedGatewayBrowserSession {
    [CmdletBinding()]
    param([hashtable]$BrowserSessions,[string]$Body)

    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 65536) { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 6
    try { $document = [Text.Json.JsonDocument]::Parse($Body,$options) }
    catch { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
        $actions = @($root.EnumerateObject() | Where-Object Name -CEQ 'Action')
        if ($actions.Count -ne 1 -or $actions[0].Value.ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID'
        }
        $action = $actions[0].Value.GetString()
        $fields = @{Action=[Text.Json.JsonValueKind]::String; Confirmed=[Text.Json.JsonValueKind]::True}
        if ($action -ceq 'Start') {
            $fields.Plan = [Text.Json.JsonValueKind]::Object
            $fields.LeaseSeconds = [Text.Json.JsonValueKind]::Number
            $fields.UpstreamReference = [Text.Json.JsonValueKind]::String
        } elseif ($action -ceq 'Stop') {
            $fields.OperationId = [Text.Json.JsonValueKind]::String
        } else { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
        $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $root -Fields $fields
        if ($WhatIfPreference -or $ConfirmPreference -notin @([Management.Automation.ConfirmImpact]::High,[Management.Automation.ConfirmImpact]::None)) {
            throw 'AI_SHARED_GATEWAY_SESSION_HTTP_CONFIRM_POLICY_BLOCKED'
        }

        if ($action -ceq 'Stop') {
            $id = $values.OperationId.GetString()
            if ($id -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or -not $BrowserSessions.ContainsKey($id) -or
                -not $script:AiSharedGatewaySessions -or -not [object]::ReferenceEquals($script:AiSharedGatewaySessions[$id],$BrowserSessions[$id])) {
                throw 'AI_SHARED_GATEWAY_SESSION_HTTP_OWNERSHIP_NOT_FOUND'
            }
            $items = @(Stop-SqlServerLabAiSharedGatewaySession -OperationId $id)
            if ($items.Count -ne 1 -or $items[0].Status -cne 'CLEANUP_SUCCEEDED' -or $items[0].OperationId -cne $id) {
                throw 'AI_SHARED_GATEWAY_SESSION_HTTP_STOP_UNCONFIRMED'
            }
            $BrowserSessions.Remove($id)
            return [pscustomobject]@{Status='CLEANUP_SUCCEEDED'; OperationId=$id}
        }

        $lease = 0
        $upstreamReference = $values.UpstreamReference.GetString()
        if (-not $values.LeaseSeconds.TryGetInt32([ref]$lease) -or $lease -lt 60 -or $lease -gt 3600 -or
            ($upstreamReference -and $upstreamReference -cnotmatch '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$')) {
            throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID'
        }
        $plan = Resolve-LabAiSharedGatewayPlan -Plan ($values.Plan.GetRawText() | ConvertFrom-Json -Depth 6 -ErrorAction Stop)
        $stateRoot = Get-LabStateRoot
        $observed = Get-SqlServerLabAiSharedGatewayStatus -Plan $plan -StateRoot $stateRoot
        if ($observed.Status -cne 'REGISTERED_STOPPED' -or $observed.PlanKey -cne $plan.PlanKey) {
            throw 'AI_SHARED_GATEWAY_SESSION_HTTP_NOT_READY'
        }

        $vault = Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
        if (-not $vault) { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_VAULT_UNAVAILABLE' }
        $keys = @{}
        $owned = [Collections.Generic.List[Security.SecureString]]::new()
        try {
            $references = @($plan.Consumers.ApiKeyReference)
            if ($upstreamReference) { $references += $upstreamReference }
            foreach ($reference in ($references | Select-Object -Unique)) {
                try { $answer = @(& $vault -Name $reference -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null) }
                catch { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_UNAVAILABLE' }
                if ($answer.Count -ne 1 -or $answer[0] -isnot [Security.SecureString] -or
                    -not (Test-LabAiSharedGatewayServiceSecretValue -Secret $answer[0])) {
                    throw 'AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_INVALID'
                }
                $copy = $answer[0].Copy()
                $owned.Add($copy)
                $keys[$reference] = $copy
                $answer = $null
            }
            $consumerKeys = @{}
            foreach ($reference in $plan.Consumers.ApiKeyReference) { $consumerKeys[$reference] = $keys[$reference] }
            $arguments = @{Plan=$plan; StateRoot=$stateRoot; ApiKeyByReference=$consumerKeys; LeaseSeconds=$lease}
            if ($upstreamReference) { $arguments.UpstreamApiKey = $keys[$upstreamReference] }
            $previousIds = @(if ($script:AiSharedGatewaySessions) { $script:AiSharedGatewaySessions.Keys })
            try {
                $result = @(Start-SqlServerLabAiSharedGatewaySession @arguments)
            } catch {
                throw 'AI_SHARED_GATEWAY_SESSION_HTTP_START_UNCONFIRMED'
            } finally {
                foreach ($id in @($script:AiSharedGatewaySessions.Keys)) {
                    if ($id -and $id -cnotin $previousIds) {
                        $session = $script:AiSharedGatewaySessions[$id]
                        if ($session.PlanKey -ceq $plan.PlanKey -and $session.GatewayId -ceq $plan.GatewayId -and $session.Port -eq $plan.Port) {
                            $BrowserSessions[$id] = $session
                        }
                    }
                }
            }
            if ($result.Count -ne 1 -or $result[0].Status -cne 'SESSION_ENDPOINT_VERIFIED' -or $result[0].PlanKey -cne $plan.PlanKey -or
                $result[0].LeaseSeconds -ne $lease -or [string]$result[0].OperationId -cnotmatch '^[a-f0-9-]{36}$' -or
                -not $BrowserSessions.ContainsKey([string]$result[0].OperationId)) {
                throw 'AI_SHARED_GATEWAY_SESSION_HTTP_START_UNCONFIRMED'
            }
            return [pscustomobject]@{Status='SESSION_ENDPOINT_VERIFIED'; OperationId=$result[0].OperationId; PlanKey=$plan.PlanKey}
        } finally {
            foreach ($key in $owned) { $key.Dispose() }
        }
    } finally { $document.Dispose() }
}

function Close-LabAiSharedGatewayBrowserSessions {
    param([hashtable]$BrowserSessions)

    $closed = $true
    foreach ($id in @($BrowserSessions.Keys)) {
        $session = if ($script:AiSharedGatewaySessions) { $script:AiSharedGatewaySessions[$id] }
        if ($session -and [object]::ReferenceEquals($session,$BrowserSessions[$id])) {
            try { $null = Stop-LabAiSharedGatewaySession -OperationId $id }
            catch { $closed = $false; continue }
        }
        $BrowserSessions.Remove($id)
    }
    return $closed
}
