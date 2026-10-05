# Separate read-only browser boundary; target authority stays in registered metadata.
function Assert-LabContainerAutoStartHttpShape {
    param($Value,[string[]]$Names)
    if ($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or
        @($Value.PSObject.Properties.Name | Where-Object { $_ -cnotin $Names }).Count) { throw 'AUTOSTART_HTTP_INVALID' }
}

function ConvertTo-LabContainerAutoStartBrowserPlan {
    param($Plan,[string]$Provider)
    Assert-LabContainerAutoStartConsolePlan -Plan $Plan -Provider $Provider
    # Do not serialize arbitrary additional properties from a public response.
    Assert-LabContainerAutoStartHttpShape $Plan @('Contract','Mode','Status','Reason','Provider','ObservationKey','Actual','Desired','NoChange','ChangeClass','CanApply','MutationAllowed','Actions','Preview')
    Assert-LabContainerAutoStartHttpShape $Plan.Contract @('Name','Version')
    Assert-LabContainerAutoStartHttpShape $Plan.Actual @('Evidence','SqlBinding','Lifecycle','AutoStart')
    Assert-LabContainerAutoStartHttpShape $Plan.Desired @('AutoStartChange')
    Assert-LabContainerAutoStartHttpShape $Plan.Preview @('Downtime','Endpoint','Sql','Backup','HostLogin','DataImpact','Mounts')
    # The shared console validator enforces scalar categories and non-executable authority.
    if ($null -ne $Plan.Preview.Mounts) {
        Assert-LabContainerAutoStartHttpShape $Plan.Preview.Mounts @('Status','TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount','VolumeOwnership')
        if ($Plan.Preview.Mounts.Status -isnot [string] -or $Plan.Preview.Mounts.VolumeOwnership -isnot [string]) { throw 'AUTOSTART_HTTP_INVALID' }
    }
    $mounts=if ($null -eq $Plan.Preview.Mounts) { $null } else {
        $m=$Plan.Preview.Mounts
        [pscustomobject]@{Status=$m.Status;TotalMountCount=$m.TotalMountCount;VolumeMountCount=$m.VolumeMountCount;HostBindCount=$m.HostBindCount;WritableHostBindCount=$m.WritableHostBindCount;OtherMountCount=$m.OtherMountCount;VolumeOwnership=$m.VolumeOwnership}
    }
    [pscustomobject]@{Contract=[pscustomobject]@{Name=$Plan.Contract.Name;Version=$Plan.Contract.Version};Mode=$Plan.Mode;Status=$Plan.Status;Reason=$Plan.Reason;Provider=$Plan.Provider;ObservationKey=$Plan.ObservationKey;
        Actual=[pscustomobject]@{Evidence=$Plan.Actual.Evidence;SqlBinding=$Plan.Actual.SqlBinding;Lifecycle=$Plan.Actual.Lifecycle;AutoStart=$Plan.Actual.AutoStart};Desired=[pscustomobject]@{AutoStartChange=$Plan.Desired.AutoStartChange};NoChange=$Plan.NoChange;ChangeClass=$Plan.ChangeClass;CanApply=$false;MutationAllowed=$false;Actions=@();
        Preview=[pscustomobject]@{Downtime=$Plan.Preview.Downtime;Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';HostLogin='NOT_CHECKED';DataImpact='NOT_VERIFIED';Mounts=$mounts}}
}

function Invoke-LabContainerAutoStartPreviewHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if ($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            -not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address) -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or
            $Request.Url.AbsolutePath -cne '/api/container-autostart-preview' -or $Request.Url.Query -or
            [string]$Request.Headers['Origin'] -cne $authority) { throw 'AUTOSTART_HTTP_INVALID' }
        $buffer=[byte[]]::new(2049);$count=0
        while ($count -lt $buffer.Length) { $read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if ($read -eq 0) { break };$count+=$read }
        if ($count -gt 2048) { throw 'AUTOSTART_HTTP_INVALID' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AUTOSTART_HTTP_INVALID' }
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $document.RootElement.EnumerateObject()) { if (-not $keys.Add($property.Name)) { throw 'AUTOSTART_HTTP_INVALID' } }
        } finally { $document.Dispose() }
        $payload=$text | ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if ($payload.Action -isnot [string] -or $payload.Action -cnotin @('Read','Preview')) { throw 'AUTOSTART_HTTP_INVALID' }
        Assert-LabContainerAutoStartHttpShape $payload $(if ($payload.Action -ceq 'Read') { @('Action') } else { @('Action','RunId','InstanceId','AutoStart') })
        if ($payload.Action -ceq 'Preview' -and ($payload.RunId -isnot [string] -or -not (Test-LabDiagnosticGuid $payload.RunId) -or
            $payload.InstanceId -isnot [string] -or $payload.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
            $payload.AutoStart -isnot [string] -or $payload.AutoStart -cnotin @('on','off'))) { throw 'AUTOSTART_HTTP_INVALID' }
        $root=Get-LabDataRootDefault
        if (-not $root) { throw 'AUTOSTART_HTTP_INVALID' }
        $targets=@(Get-LabContainerPortConsoleTargets -DataRoot $root)
        if ($targets.Count -gt 4096) { throw 'AUTOSTART_HTTP_INVALID' }
        # Validate every metadata row before selection; internal StateRoot never crosses HTTP.
        $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($target in $targets) {
            if ($target.RunId -isnot [string] -or -not (Test-LabDiagnosticGuid $target.RunId) -or
                $target.InstanceId -isnot [string] -or $target.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
                $target.Provider -isnot [string] -or $target.Provider -cnotin @('docker','podman') -or
                $target.StateRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($target.StateRoot) -or
                -not $identities.Add($target.RunId+'|'+$target.InstanceId)) { throw 'AUTOSTART_HTTP_INVALID' }
        }
        if ($payload.Action -ceq 'Read') {
            $rows=@(foreach ($target in $targets) {
                if (-not (Test-LabDiagnosticGuid $target.RunId) -or $target.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or $target.Provider -cnotin @('docker','podman')) { throw 'AUTOSTART_HTTP_INVALID' }
                [pscustomobject]@{RunId=$target.RunId;InstanceId=$target.InstanceId;Provider=$target.Provider}
            })
            return [pscustomobject]@{ContractVersion='SqlServerLab.ContainerAutoStartBrowser/1.0';Status='METADATA_ONLY';Targets=$rows;CanApply=$false;MutationAllowed=$false;Actions=@()}
        }
        $matched=@($targets | Where-Object { $_.RunId -ceq $payload.RunId -and $_.InstanceId -ceq $payload.InstanceId })
        if ($matched.Count -ne 1) { throw 'AUTOSTART_HTTP_INVALID' }
        $target=$matched[0]
        $plan=Get-SqlServerLabReconcilePlan -RunId $target.RunId -InstanceId $target.InstanceId -StateRoot $target.StateRoot -ContainerAutoStartPreview -AutoStart $payload.AutoStart
        ConvertTo-LabContainerAutoStartBrowserPlan -Plan $plan -Provider $target.Provider
    } catch { throw 'AUTOSTART_HTTP_INVALID' }
}
