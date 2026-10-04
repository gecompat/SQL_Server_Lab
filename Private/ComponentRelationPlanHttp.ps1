# Dedicated metadata-only browser boundary; no jobs, defaults or runtime observations.
function Invoke-LabComponentRelationHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    try {
        if ($Request.HttpMethod -cne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        $origin=[string]$Request.Headers['Origin']
        if ($origin -and $origin -cne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
        try {
            $buffer=[char[]]::new(16385);$length=$reader.ReadBlock($buffer,0,$buffer.Length)
            if ($length -gt 16384) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
            $text=[string]::new($buffer,0,$length)
        } finally { $reader.Dispose() }
        # Reject duplicate/case-alias keys before PowerShell's JSON conversion.
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=12
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement)
            $nodes=0
            while ($pending.Count) {
                if (++$nodes -gt 256) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
                $element=$pending.Pop()
                if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $element.EnumerateObject()) {
                        if (-not $keys.Add($property.Name)) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
                        $pending.Push($property.Value)
                    }
                } elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $element.EnumerateArray()) { $pending.Push($child) }
                }
            }
        } finally { $document.Dispose() }
        $payload=$text|ConvertFrom-Json -Depth 12 -ErrorAction Stop
        if ($payload -isnot [pscustomobject] -or $payload.Action -cnotin @('Read','Preview') -or
            $payload.DataRoot -isnot [string] -or $payload.DataRoot.Length -gt 2048 -or -not $payload.DataRoot) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        $names=if($payload.Action -ceq 'Read'){@('Action','DataRoot')}else{@('Action','DataRoot','RunId','Bindings','ProposedRelations')}
        Assert-LabComponentRelationShape $payload $names
        $root=Assert-LabDiagnosticPath -Path $payload.DataRoot
        if ($payload.Action -ceq 'Read') {
            $runs=@(Get-LabComponentRelationConsoleRuns -DataRoot $root | ForEach-Object {
                [pscustomobject]@{RunId=$_.RunId;ScopeId=$_.ScopeId;State=$_.State;Digest=$_.Digest;Instances=$_.Instances}
            })
            return [pscustomobject]@{ContractVersion='SqlServerLab.ComponentRelationBrowser/1.0';Status='METADATA_ONLY';Runs=$runs;
                SqlReadiness='NOT_CHECKED';SharedRemovalPolicy='PRESERVE';MutationAllowed=$false;ExecutionSupported=$false}
        }
        if (-not (Test-LabDiagnosticGuid $payload.RunId) -or $payload.Bindings -isnot [array] -or
            $payload.Bindings.Count -lt 1 -or $payload.Bindings.Count -gt 2 -or $payload.ProposedRelations -isnot [array] -or
            $payload.ProposedRelations.Count -gt 4) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        $required=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$null=$required.Add($payload.RunId)
        foreach ($relation in $payload.ProposedRelations) {
            Assert-LabComponentRelationShape $relation @('SourceInstanceId','Target','Type')
            Assert-LabComponentRelationShape $relation.Target @('RunId','ScopeId','InstanceId','ManagementMode')
            if ($relation.Type -cne 'requires-sql' -or $relation.SourceInstanceId -isnot [string] -or
                $relation.SourceInstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
                $relation.Target.InstanceId -isnot [string] -or $relation.Target.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
                -not (Test-LabDiagnosticGuid $relation.Target.RunId) -or -not (Test-LabDiagnosticGuid $relation.Target.ScopeId) -or
                $relation.Target.ManagementMode -cnotin @('PROVISIONED','EXTERNAL_READ_ONLY')) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
            $null=$required.Add($relation.Target.RunId)
        }
        if ($required.Count -ne $payload.Bindings.Count) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $stateRoot=Join-Path $root 'State'
        foreach ($selected in $payload.Bindings) {
            Assert-LabComponentRelationShape $selected @('RunId','ScopeId','State','Digest')
            if (-not (Test-LabDiagnosticGuid $selected.RunId) -or -not (Test-LabDiagnosticGuid $selected.ScopeId) -or
                $selected.State -isnot [string] -or $selected.State.Length -gt 32 -or $selected.Digest -isnot [string] -or
                $selected.Digest -cnotmatch '^[a-f0-9]{64}$' -or -not $required.Contains($selected.RunId) -or -not $seen.Add($selected.RunId)) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
            $fresh=Read-LabComponentRelationBinding -RunId $selected.RunId -StateRoot $stateRoot
            if ($fresh.Run.scopeId -cne $selected.ScopeId -or $fresh.Run.state -cne $selected.State -or $fresh.Digest -cne $selected.Digest -or
                $fresh.Run.state -ceq 'REMOVED') { throw 'COMPONENT_RELATION_BINDING_CHANGED' }
        }
        $plan=Get-SqlServerLabReconcilePlan -RunId $payload.RunId -StateRoot $stateRoot -ProposedRelations @($payload.ProposedRelations)
        if ($plan.Mode -cne 'COMPONENT_RELATIONS_PLAN_ONLY' -or $plan.Contract.Version -cne '1.2' -or
            $plan.MutationAllowed -ne $false -or $plan.ExecutionSupported -ne $false -or $plan.Actions.Count -ne 0) { throw 'COMPONENT_RELATION_HTTP_INVALID' }
        return [pscustomobject]@{ContractVersion='SqlServerLab.ComponentRelationBrowser/1.0';Status=$plan.Status;RunId=$plan.RunId;
            Mode=$plan.Mode;PrerequisiteOrder=$plan.PrerequisiteOrder;SqlReadiness='NOT_CHECKED';SharedRemovalPolicy='PRESERVE';
            Actions=@();MutationAllowed=$false;ExecutionSupported=$false}
    } catch {
        $known=@('COMPONENT_RELATION_HTTP_INVALID','COMPONENT_RELATION_BINDING_CHANGED','COMPONENT_RELATION_SCOPE_UNSUPPORTED',
            'COMPONENT_RELATION_INPUT_INVALID','COMPONENT_RELATION_TARGET_INVALID','COMPONENT_RELATION_CYCLE','COMPONENT_RELATION_BINDING_UNAVAILABLE')
        if ($_.Exception.Message -cin $known) { throw $_.Exception.Message }
        throw 'COMPONENT_RELATION_BINDING_UNAVAILABLE'
    }
}
