# Gemeinsame HTTP-Grenze; keine Operatorauthentifizierung oder Aktionsfreigabe.
function Get-UiRequestBoundaryDecision {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ListenerUrl)
    $result = [pscustomobject]@{ Allowed = $false; StatusCode = 403; Code = 'UI_REQUEST_AUTHORITY_INVALID' }
    $listener = $null
    if (-not [uri]::TryCreate($ListenerUrl, [UriKind]::Absolute, [ref]$listener) -or
        $listener.Scheme -cne 'http' -or $listener.Host -cne '127.0.0.1' -or $listener.UserInfo -or
        $listener.Port -lt 1025 -or $listener.AbsolutePath -cne '/' -or $listener.Query -or $listener.Fragment -or
        $Request.Url -isnot [uri] -or -not $Request.Url.IsAbsoluteUri -or $Request.Url.UserInfo -or
        $Request.Url.Scheme -cne $listener.Scheme -or $Request.Url.Authority -cne $listener.Authority -or
        $Request.RemoteEndPoint -isnot [Net.IPEndPoint] -or -not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address) -or
        $Request.Headers -isnot [Collections.Specialized.NameValueCollection]) { return $result }
    $headers = @{}
    foreach ($name in @('Host', 'Origin', 'Sec-Fetch-Site', 'Content-Type')) {
        $values = $Request.Headers.GetValues($name)
        if ($null -eq $values) { $headers[$name] = $null; continue }
        if ($values.Count -gt 1 -or ($values.Count -eq 1 -and ($values[0] -isnot [string] -or -not $values[0]))) { return $result }
        $headers[$name] = if ($values.Count) { $values[0] } else { $null }
    }
    if ($headers['Host'] -cne $listener.Authority) { return $result }
    $result.Code = 'UI_REQUEST_ORIGIN_INVALID'
    if ($null -ne $headers['Origin'] -and $headers['Origin'] -cne $listener.GetLeftPart([UriPartial]::Authority)) { return $result }
    $result.Code = 'UI_REQUEST_FETCH_SITE_INVALID'
    if ($null -ne $headers['Sec-Fetch-Site'] -and $headers['Sec-Fetch-Site'] -cnotin @('same-origin', 'none')) { return $result }
    $result.StatusCode = 405; $result.Code = 'UI_REQUEST_METHOD_INVALID'
    if ($Request.HttpMethod -cnotin @('GET', 'POST')) { return $result }
    $result.StatusCode = 415; $result.Code = 'UI_REQUEST_JSON_REQUIRED'
    if ($Request.HttpMethod -ceq 'POST' -and ($null -eq $headers['Content-Type'] -or
        $headers['Content-Type'] -notmatch '\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?\z')) { return $result }
    $result.Allowed = $true; $result.StatusCode = 200; $result.Code = 'UI_REQUEST_BOUNDARY_PASSED'
    return $result
}
