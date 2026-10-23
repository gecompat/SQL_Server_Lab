# Dedicated read-only action. A browser supplies identities, never a StateRoot.
function Get-LabTlsLiveQualificationHttpSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Body)
    try {
        if($Body.Length -gt 2048){throw 'TLS_LIVE_HTTP_INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($Body,$options)
        try {
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'TLS_LIVE_HTTP_INVALID'}
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($p in $document.RootElement.EnumerateObject()){
                if($p.Name -cnotin @('RunId','InstanceId','Provider') -or -not $keys.Add($p.Name) -or
                    $p.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'TLS_LIVE_HTTP_INVALID'}
            }
            if($keys.Count -ne 3){throw 'TLS_LIVE_HTTP_INVALID'}
        }finally{$document.Dispose()}
        $payload=$Body|ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if($payload.RunId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
            $payload.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
            $payload.Provider -cnotin @('docker','podman')){throw 'TLS_LIVE_HTTP_INVALID'}
        return $payload
    }catch{throw 'TLS_LIVE_HTTP_REJECTED'}
}

function Get-LabTlsLiveQualificationHttpTarget {
    param($Selection)
    # The workflow and worker share this current server-side state context.
    # Operational labs have a separate audit StateRoot, not DataRoot/State/runs.
    $root=Assert-LabDiagnosticPath (Get-LabStateRoot)
    $path=Join-Path (Join-Path (Join-Path $root 'runs') $Selection.RunId) 'run-state.json'
    $run=Read-LabDiagnosticJson -Path $path
    if($run.contractVersion -isnot [string] -or $run.contractVersion -cne 'SqlServerLab.RunState/1.0' -or
        $run.runId -isnot [string] -or $run.runId -cne $Selection.RunId -or
        $run.state -isnot [string] -or $run.state -cne 'RUNNING' -or
        $run.metadata.desiredState.Instances -isnot [array] -or
        $run.metadata.desiredState.Instances.Count -lt 1 -or $run.metadata.desiredState.Instances.Count -gt 64){throw 'TLS_LIVE_HTTP_INVALID'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($instance in $run.metadata.desiredState.Instances){
        if($instance.Id -isnot [string] -or $instance.Id -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
            -not $ids.Add($instance.Id) -or $instance.Provider -isnot [string] -or
            $instance.Provider -cnotin @('docker','podman','hyperv')){throw 'TLS_LIVE_HTTP_INVALID'}
    }
    $matched=@($run.metadata.desiredState.Instances|Where-Object{$_.Id -ceq $Selection.InstanceId})
    if($matched.Count -ne 1 -or $matched[0].Provider -cne $Selection.Provider){throw 'TLS_LIVE_HTTP_INVALID'}
    return [pscustomobject]@{RunId=$Selection.RunId;InstanceId=$Selection.InstanceId;Provider=$Selection.Provider;StateRoot=$root}
}

function Invoke-LabTlsLiveQualificationHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Body)
    try {
        $payload=Get-LabTlsLiveQualificationHttpSelection -Body $Body
        Assert-LabTlsLiveQualificationHost
        $target=Get-LabTlsLiveQualificationHttpTarget -Selection $payload
        $started=Get-LabTlsLiveQualificationUtcNow
        $result=Test-SqlServerLabTlsQualification -RunId $target.RunId -InstanceId $target.InstanceId -StateRoot $target.StateRoot
        ConvertTo-LabTlsLiveQualificationHttpResult -Result $result -Target $target -Started $started
    }catch{throw 'TLS_LIVE_HTTP_REJECTED'}
}

function ConvertTo-LabTlsLiveQualificationHttpResult {
    param($Result,$Target,[DateTimeOffset]$Started)
    try {
        # Validate the closed public result before serialization; never pass arbitrary
        # extra properties or native/internal diagnostics through HTTP.
        $names=@('ContractVersion','Status','RunId','InstanceId','Provider','SqlVersion','Patch','SqlBuild','Encrypt',
            'TrustServerCertificate','QualifiedAtUtc','ObservedAtUtc','ExpiresAtUtc','ClientChecks','Evidence','WireCertificateFingerprint')
        if($result -isnot [pscustomobject] -or @($result.PSObject.Properties).Count -ne $names.Count){throw 'TLS_LIVE_HTTP_INVALID'}
        foreach($name in $names){
            $p=$result.PSObject.Properties[$name]
            if($null -eq $p -or $p.Name -cne $name -or $p.MemberType -ne 'NoteProperty'){throw 'TLS_LIVE_HTTP_INVALID'}
        }
        if($result.ContractVersion -isnot [string] -or $result.ContractVersion -cne 'SqlServerLab.TlsLiveQualificationResult/0.1' -or
            $result.Status -isnot [string] -or $result.Status -cne 'QUALIFIED_AT_OBSERVATION' -or $result.Provider -cne $target.Provider -or
            $result.ClientChecks -isnot [array] -or $result.ClientChecks.Count -ne 2 -or
            $result.ClientChecks[0] -isnot [string] -or $result.ClientChecks[0] -cne 'SYSTEM_DATA_SQLCLIENT' -or
            $result.ClientChecks[1] -isnot [string] -or $result.ClientChecks[1] -cne 'ODBC_SQLCMD' -or
            $result.ObservedAtUtc -isnot [string]){throw 'TLS_LIVE_HTTP_INVALID'}
        $observed=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParseExact($result.ObservedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,[ref]$observed) -or $observed -gt (Get-LabTlsLiveQualificationUtcNow)){throw 'TLS_LIVE_HTTP_INVALID'}
        $qualification=[pscustomobject]@{
            ContractVersion='SqlServerLab.TlsQualification/0.1';Status='QUALIFIED'
            RunId=$result.RunId;InstanceId=$result.InstanceId;Provider=$result.Provider
            SqlVersion=$result.SqlVersion;Patch=$result.Patch;SqlBuild=$result.SqlBuild
            Encrypt=$result.Encrypt;TrustServerCertificate=$result.TrustServerCertificate
            QualifiedAt=$result.QualifiedAtUtc;ExpiresAt=$result.ExpiresAtUtc
            Evidence=$result.Evidence;WireCertificateFingerprint=$result.WireCertificateFingerprint
        }
        ConvertTo-LabTlsLiveQualificationResult -Qualification $qualification -RunId $target.RunId -InstanceId $target.InstanceId -StartedAt $started -ObservedAt $observed
    }catch{throw 'TLS_LIVE_HTTP_REJECTED'}
}
