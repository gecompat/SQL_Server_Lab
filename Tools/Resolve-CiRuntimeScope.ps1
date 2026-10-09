#Requires -Version 7.2
# Pure admission: validate all caller input before host/provider preflight.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [AllowEmptyString()][string]$Capabilities,
    [AllowEmptyString()][string]$Mode
)
$ordinal=[StringComparer]::Ordinal
if (-not $ordinal.Equals($Mode,'lifecycle') -and -not $ordinal.Equals($Mode,'cli-acceptance')) { throw 'CI_RUNTIME_MODE_INVALID' }
$allowed=@('lifecycle','ai-vector','batch','collation','package','pitr','removal','restore','tool','transfer','transfer-preflight','upgrade')
if ($Provider -ceq 'podman') { $allowed=@('lifecycle','ai-samples')+@($allowed | Where-Object { $_ -cne 'lifecycle' }) }
$selected=if ($Capabilities -ceq '*') { $allowed } else { @($Capabilities.Split(',')) }
$allowedSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($name in $allowed) { [void]$allowedSet.Add($name) }
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $selected) {
    if (-not $allowedSet.Contains($name) -or -not $seen.Add($name)) { throw 'CI_CAPABILITY_SCOPE_INVALID' }
}
if (-not $seen.Contains('lifecycle')) { throw 'CI_CAPABILITY_SCOPE_INVALID' }
[pscustomobject]@{ Mode=$Mode; Capabilities=@($selected) }
