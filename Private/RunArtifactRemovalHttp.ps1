# Servergebundene Browserführung; Metadaten und Tokens ersetzen keine Core-Prüfung.
function Assert-LabRunArtifactHttpShape {
    param($Value,[string[]]$Names)
    if ($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or
        @($Value.PSObject.Properties.Name | Where-Object { $_ -cnotin $Names }).Count) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
}

function Invoke-LabRunArtifactRemovalHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort,
        [Parameter(Mandatory)][hashtable]$Previews)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if ($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            -not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address) -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or
            $Request.Url.AbsolutePath -cne '/api/run-artifact-removal' -or $Request.Url.Query -or
            [string]$Request.Headers['Origin'] -cne $authority) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $buffer=[byte[]]::new(2049);$count=0
        while ($count -lt $buffer.Length) { $read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if ($read -eq 0) { break };$count+=$read }
        if ($count -gt 2048) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $document.RootElement.EnumerateObject()) { if (-not $keys.Add($property.Name)) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' } }
        } finally { $document.Dispose() }
        $payload=$text | ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if ($payload.Action -isnot [string] -or $payload.Action -cnotin @('Read','Preview','Apply')) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $names=switch -CaseSensitive ($payload.Action) {
            'Read' { @('Action') }
            'Preview' { @('Action','RunId') }
            'Apply' { @('Action','RunId','PreviewToken','Confirmed') }
        }
        Assert-LabRunArtifactHttpShape $payload $names
        if ($payload.Action -cne 'Read' -and ($payload.RunId -isnot [string] -or
            $payload.RunId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        if ($payload.Action -ceq 'Apply' -and ($payload.Confirmed -isnot [bool] -or -not $payload.Confirmed -or
            $payload.PreviewToken -isnot [string] -or $payload.PreviewToken -cnotmatch '^[a-f0-9]{32}$')) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $binding=$null
        if ($payload.Action -ceq 'Apply') {
            $binding=$Previews[$payload.PreviewToken]
            if ($null -eq $binding -or $binding.RunId -cne $payload.RunId) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
            # Einmalig konsumieren, auch bei Drift, Teilfehler oder verlorener Antwort.
            $Previews.Remove($payload.PreviewToken)
            if ($binding.ExpiresAtUtc -le [datetime]::UtcNow) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        }
        foreach ($token in @($Previews.Keys)) { if ($Previews[$token].ExpiresAtUtc -le [datetime]::UtcNow) { $Previews.Remove($token) } }
        $dataRoot=Get-LabDataRootDefault;$stateRoot=Get-LabStateRoot
        if (-not $dataRoot -or -not $stateRoot) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $dataRoot=[IO.Path]::GetFullPath($dataRoot);$stateRoot=[IO.Path]::GetFullPath($stateRoot)
        $configuration=Get-LabStorageConfiguration -DataRoot $dataRoot
        if (@($configuration.LabDataLocations | Where-Object {
            [IO.Path]::GetFullPath((Join-Path $_.LabDataRoot 'State')) -eq $stateRoot
        }).Count -ne 1) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        if ($binding -and ($binding.DataRoot -cne $dataRoot -or $binding.StateRoot -cne $stateRoot)) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $targets=@(Get-LabRunArtifactRemovalConsoleCandidates -StateRoot $stateRoot)
        if ($targets.Count -gt 4096) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($target in $targets) {
            if ($target.RunId -isnot [string] -or $target.RunId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                -not $identities.Add($target.RunId)) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        }
        $contract='SqlServerLab.RunArtifactRemovalBrowser/1.0'
        if ($payload.Action -ceq 'Read') {
            $Previews.Clear()
            return [pscustomobject]@{ContractVersion=$contract;Status='METADATA_ONLY';CanApply=$false;Targets=@(foreach ($target in $targets) { [pscustomobject]@{RunId=$target.RunId} })}
        }
        if (@($targets | Where-Object RunId -CEQ $payload.RunId).Count -ne 1) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        $arguments=@{RunId=$payload.RunId;DataRoot=$dataRoot;StateRoot=$stateRoot}
        if ($payload.Action -ceq 'Preview') {
            foreach ($token in @($Previews.Keys)) { if ($Previews[$token].RunId -ceq $payload.RunId) { $Previews.Remove($token) } }
            $plan=Get-SqlServerLabRunArtifactRemovalPlan @arguments
            Assert-LabRunArtifactHttpShape $plan @('RunId','Status','CanApply','PlanKey','FileCount','ReasonCode')
            if (-not (Test-LabRunArtifactRemovalConsolePlan -Plan $plan -RunId $payload.RunId) -or
                $plan.Status -isnot [string] -or ($null -ne $plan.ReasonCode -and $plan.ReasonCode -isnot [string])) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
            $previewToken=$null
            if ($plan.CanApply) {
                if ($Previews.Count -ge 64) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
                $previewToken=[guid]::NewGuid().ToString('N')
                $Previews[$previewToken]=[pscustomobject]@{RunId=$payload.RunId;DataRoot=$dataRoot;StateRoot=$stateRoot;
                    PlanKey=$plan.PlanKey;ExpiresAtUtc=[datetime]::UtcNow.AddMinutes(5)}
            }
            return [pscustomobject]@{ContractVersion=$contract;RunId=$payload.RunId;Status=$plan.Status;CanApply=$plan.CanApply;
                FileCount=$plan.FileCount;ReasonCode=$plan.ReasonCode;PreviewToken=$previewToken}
        }
        $result=Invoke-SqlServerLabRunArtifactRemoval @arguments -ExpectedPlanKey $binding.PlanKey -Confirm:$false
        Assert-LabRunArtifactHttpShape $result @('RunId','Status','Changed')
        if ($result.RunId -isnot [string] -or $result.RunId -cne $payload.RunId -or $result.Status -isnot [string] -or $result.Status -cnotin @('REMOVED','CANCELLED') -or
            $result.Changed -isnot [bool] -or ($result.Status -ceq 'CANCELLED' -and $result.Changed)) { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
        [pscustomobject]@{ContractVersion=$contract;RunId=$payload.RunId;Status=$result.Status;Changed=$result.Changed}
    } catch { throw 'RUN_ARTIFACT_HTTP_UNCONFIRMED' }
}
