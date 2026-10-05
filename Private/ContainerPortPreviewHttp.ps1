# Separate read-only browser boundary; target authority stays in registered metadata.
function Assert-LabContainerPortHttpShape {
    param($Value,[string[]]$Names)
    if ($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or
        @($Value.PSObject.Properties.Name | Where-Object { $_ -cnotin $Names }).Count) { throw 'PORT_HTTP_INVALID' }
}

function ConvertTo-LabContainerPortBrowserPlan {
    param($Plan,[string]$Provider)
    Assert-LabContainerPortConsolePlan -Plan $Plan -Provider $Provider
    # Do not serialize arbitrary additional properties from a public response.
    Assert-LabContainerPortHttpShape $Plan @('Contract','Mode','Status','Reason','Provider','ObservationKey','Actual','Desired','NoChange','ChangeClass','CanApply','MutationAllowed','Actions','Preview')
    Assert-LabContainerPortHttpShape $Plan.Contract @('Name','Version')
    Assert-LabContainerPortHttpShape $Plan.Actual @('Evidence','SqlBinding','Lifecycle')
    Assert-LabContainerPortHttpShape $Plan.Desired @('PortChange')
    Assert-LabContainerPortHttpShape $Plan.Preview @('Downtime','Endpoint','Sql','Backup','DataImpact','Mounts')
    # PowerShell collection comparisons must not admit arrays as scalar DTO categories.
    foreach ($value in @($Plan.Contract.Name,$Plan.Contract.Version,$Plan.Mode,$Plan.Status,$Plan.Reason,
            $Plan.Actual.Evidence,$Plan.Actual.SqlBinding,$Plan.Actual.Lifecycle,$Plan.Desired.PortChange,
            $Plan.ChangeClass,$Plan.Preview.Downtime,$Plan.Preview.Endpoint,$Plan.Preview.Sql,
            $Plan.Preview.Backup,$Plan.Preview.DataImpact)) {
        if ($value -isnot [string]) { throw 'PORT_HTTP_INVALID' }
    }
    if ($null -ne $Plan.Provider -and $Plan.Provider -isnot [string]) { throw 'PORT_HTTP_INVALID' }
    if ($null -ne $Plan.Provider -and $Plan.Provider -cnotin @('docker','podman')) { throw 'PORT_HTTP_INVALID' }
    if ($Plan.Status -cne 'PLAN_ONLY' -and $null -ne $Plan.ObservationKey) { throw 'PORT_HTTP_INVALID' }
    if ($null -ne $Plan.Preview.Mounts) {
        Assert-LabContainerPortHttpShape $Plan.Preview.Mounts @('Status','TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount','VolumeOwnership')
        if ($Plan.Preview.Mounts.Status -isnot [string] -or $Plan.Preview.Mounts.VolumeOwnership -isnot [string]) { throw 'PORT_HTTP_INVALID' }
    }
    $mounts=if ($null -eq $Plan.Preview.Mounts) { $null } else {
        $m=$Plan.Preview.Mounts
        [pscustomobject]@{Status=$m.Status;TotalMountCount=$m.TotalMountCount;VolumeMountCount=$m.VolumeMountCount;HostBindCount=$m.HostBindCount;WritableHostBindCount=$m.WritableHostBindCount;OtherMountCount=$m.OtherMountCount;VolumeOwnership=$m.VolumeOwnership}
    }
    [pscustomobject]@{Contract=[pscustomobject]@{Name=$Plan.Contract.Name;Version=$Plan.Contract.Version};Mode=$Plan.Mode;Status=$Plan.Status;Reason=$Plan.Reason;Provider=$Plan.Provider;ObservationKey=$Plan.ObservationKey;
        Actual=[pscustomobject]@{Evidence=$Plan.Actual.Evidence;SqlBinding=$Plan.Actual.SqlBinding;Lifecycle=$Plan.Actual.Lifecycle};Desired=[pscustomobject]@{PortChange=$Plan.Desired.PortChange};NoChange=$Plan.NoChange;ChangeClass=$Plan.ChangeClass;CanApply=$false;MutationAllowed=$false;Actions=@();
        Preview=[pscustomobject]@{Downtime=$Plan.Preview.Downtime;Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';DataImpact='NOT_VERIFIED';Mounts=$mounts}}
}

function Invoke-LabContainerPortPreviewHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if ($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            -not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address) -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or
            $Request.Url.AbsolutePath -cne '/api/container-port-preview' -or $Request.Url.Query -or
            [string]$Request.Headers['Origin'] -cne $authority) { throw 'PORT_HTTP_INVALID' }
        $buffer=[byte[]]::new(2049);$count=0
        while ($count -lt $buffer.Length) { $read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if ($read -eq 0) { break };$count+=$read }
        if ($count -gt 2048) { throw 'PORT_HTTP_INVALID' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'PORT_HTTP_INVALID' }
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $document.RootElement.EnumerateObject()) { if (-not $keys.Add($property.Name)) { throw 'PORT_HTTP_INVALID' } }
        } finally { $document.Dispose() }
        $payload=$text | ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if ($payload.Action -isnot [string] -or $payload.Action -cnotin @('Read','Preview')) { throw 'PORT_HTTP_INVALID' }
        Assert-LabContainerPortHttpShape $payload $(if ($payload.Action -ceq 'Read') { @('Action') } else { @('Action','RunId','InstanceId','Port') })
        if ($payload.Action -ceq 'Preview' -and ($payload.RunId -isnot [string] -or -not (Test-LabDiagnosticGuid $payload.RunId) -or
            $payload.InstanceId -isnot [string] -or $payload.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
            ($payload.Port -isnot [int] -and $payload.Port -isnot [long]) -or $payload.Port -lt 1024 -or $payload.Port -gt 65535)) { throw 'PORT_HTTP_INVALID' }
        $root=Get-LabDataRootDefault
        if (-not $root) { throw 'PORT_HTTP_INVALID' }
        $targets=@(Get-LabContainerPortConsoleTargets -DataRoot $root)
        if ($targets.Count -gt 4096) { throw 'PORT_HTTP_INVALID' }
        if ($payload.Action -ceq 'Read') {
            $rows=@(foreach ($target in $targets) {
                if (-not (Test-LabDiagnosticGuid $target.RunId) -or $target.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or $target.Provider -cnotin @('docker','podman')) { throw 'PORT_HTTP_INVALID' }
                [pscustomobject]@{RunId=$target.RunId;InstanceId=$target.InstanceId;Provider=$target.Provider}
            })
            return [pscustomobject]@{ContractVersion='SqlServerLab.ContainerPortBrowser/1.0';Status='METADATA_ONLY';Targets=$rows;CanApply=$false;MutationAllowed=$false;Actions=@()}
        }
        $matched=@($targets | Where-Object { $_.RunId -ceq $payload.RunId -and $_.InstanceId -ceq $payload.InstanceId })
        if ($matched.Count -ne 1) { throw 'PORT_HTTP_INVALID' }
        $target=$matched[0]
        $plan=Get-SqlServerLabReconcilePlan -RunId $target.RunId -InstanceId $target.InstanceId -StateRoot $target.StateRoot -ContainerPortPreview -Port $payload.Port
        ConvertTo-LabContainerPortBrowserPlan -Plan $plan -Provider $target.Provider
    } catch { throw 'PORT_HTTP_INVALID' }
}
