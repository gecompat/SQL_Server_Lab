<#
.SYNOPSIS
    Gemeinsame, secretfreie Kriterien und enger Neucontainer-Policyentscheid.
.DESCRIPTION
    Keine Runtime-/Stateabfrage. Die SQL-Erststartabnahme bleibt separat.
#>
function Get-LabSaPasswordPolicy {
    [CmdletBinding()]
    param(
        [string]$Version = '', [string]$Provider = '',
        [ValidateRange(1,8)][int]$MinimumLength = 8,
        [ValidateSet('adhoc','manifest')][string]$ProvisioningMode = 'adhoc',
        [bool]$PersistentData = $false, [object[]]$Drives = @(),
        [bool]$HasDerivedImage = $false
    )
    $reason = 'SUPPORTED_PINNED_SQL2025_NEW_CONTAINER'
    if ($ProvisioningMode -ne 'adhoc') { $reason = 'MANIFEST_DEFAULT_POLICY_ONLY' }
    elseif ($Provider -notin @('docker','podman')) { $reason = 'CONTAINER_PROVIDER_REQUIRED' }
    elseif ($PersistentData) { $reason = 'NEW_RUN_SCOPED_SYSTEM_VOLUME_REQUIRED' }
    elseif ($HasDerivedImage) { $reason = 'STANDARD_LAUNCH_REQUIRED' }
    elseif (@($Drives | Where-Object {
        if ($null -eq $_) { return $false }
        $path = ([string]$_.containerPath).TrimEnd('/')
        $path -match '//|(^|/)\.{1,2}(/|$)' -or
            $path -in @('','/var','/var/opt','/var/opt/mssql') -or
            $path.StartsWith('/var/opt/mssql/', [StringComparison]::Ordinal)
    }).Count -gt 0) { $reason = 'SYSTEM_CONFIG_MOUNT_COLLISION' }
    elseif ($Version -notmatch '^2025-CU[0-9]+(?:-.+)?$') { $reason = 'PINNED_SQL2025_CATALOG_BUILD_REQUIRED' }
    else {
        try {
            $image = Get-SqlServerDockerImage -VersionId $Version
            if ($image -notmatch '^mcr\.microsoft\.com/mssql/server:2025-CU[0-9]+-.+$') {
                $reason = 'PINNED_SQL2025_CATALOG_BUILD_REQUIRED'
            }
        }
        catch { $reason = 'PINNED_SQL2025_CATALOG_BUILD_REQUIRED' }
    }
    [pscustomobject][ordered]@{
        ContractVersion = 'SqlServerLab.SaPasswordPolicy/1.0'
        MinimumLength = $MinimumLength; MaximumLength = 128; RequiredCategories = 3
        CanCustomizeMinimum = $reason -eq 'SUPPORTED_PINNED_SQL2025_NEW_CONTAINER'
        CustomizationReason = $reason
        Criteria = @("Mindestens $MinimumLength Zeichen; hoechstens 128 Zeichen.",
            'Mindestens drei von vier Gruppen: Grossbuchstaben, Kleinbuchstaben, Ziffern, Sonderzeichen.')
        NativeFirstStart = 'NOT_EXECUTED'
    }
}

function Test-LabSaPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$Password,
        [ValidateRange(1,8)][int]$MinimumLength = 8)
    $plain = $null
    try {
        $plain = ConvertFrom-LabSecureString -SecureString $Password
        $codes = [Collections.Generic.List[string]]::new()
        if ($plain.Length -lt $MinimumLength) { $codes.Add('SA_PASSWORD_MINIMUM_LENGTH') }
        if ($plain.Length -gt 128) { $codes.Add('SA_PASSWORD_MAXIMUM_LENGTH') }
        $categories = 0
        foreach ($pattern in @('[A-Z]','[a-z]','[0-9]','[^A-Za-z0-9]')) {
            if ($plain -cmatch $pattern) { $categories++ }
        }
        if ($categories -lt 3) { $codes.Add('SA_PASSWORD_COMPLEXITY') }
        [pscustomobject][ordered]@{ Valid = $codes.Count -eq 0; ReasonCodes = $codes.ToArray() }
    }
    finally { $plain = $null }
}

function Assert-LabSaPasswordPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)]$Policy)
    if ($Policy.MinimumLength -lt 8 -and -not $Policy.CanCustomizeMinimum) {
        throw ('SA_PASSWORD_POLICY_UNSUPPORTED: ' + $Policy.CustomizationReason)
    }
    $check = Test-LabSaPassword -Password $Password -MinimumLength $Policy.MinimumLength
    if (-not $check.Valid) { throw ('SA_PASSWORD_PREFLIGHT_FAILED: ' + ($check.ReasonCodes -join ',')) }
}

function Assert-LabSaPasswordWorkflowPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('NewContainerLab','NewContainerLabFromManifest')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Parameters)
    if (-not $Parameters.ContainsKey('SaPassword') -or $Parameters.SaPassword -isnot [string] -or
        [string]::IsNullOrEmpty($Parameters.SaPassword)) { throw 'SA_PASSWORD_REQUIRED' }
    $minimum = 8
    if ($Parameters.ContainsKey('SaPasswordMinimumLength')) {
        if ($Action -ne 'NewContainerLab' -or
            ($Parameters.SaPasswordMinimumLength -isnot [int] -and $Parameters.SaPasswordMinimumLength -isnot [long]) -or
            $Parameters.SaPasswordMinimumLength -lt 1 -or $Parameters.SaPasswordMinimumLength -gt 8) {
            throw 'SA_PASSWORD_POLICY_MINIMUM_INVALID'
        }
        $minimum = [int]$Parameters.SaPasswordMinimumLength
    }
    if ($Parameters.ContainsKey('PersistentData') -and $Parameters.PersistentData -isnot [bool]) {
        throw 'SA_PASSWORD_POLICY_TARGET_INVALID'
    }
    $policy = if ($Action -eq 'NewContainerLab') {
        if ($minimum -lt 8 -and ($Parameters.SqlVersion -isnot [string] -or
            $Parameters.Provider -isnot [string] -or $Parameters.PersistentStorageId -or
            $Parameters.PersistentStorageAction -or $Parameters.PersistentData)) {
            throw 'SA_PASSWORD_POLICY_TARGET_INVALID'
        }
        Get-LabSaPasswordPolicy -Version ([string]$Parameters.SqlVersion) -Provider ([string]$Parameters.Provider) `
            -MinimumLength $minimum -PersistentData ([bool]$Parameters.PersistentData)
    }
    else { Get-LabSaPasswordPolicy -MinimumLength 8 -ProvisioningMode manifest }
    $secure = [SecureString]::new()
    foreach ($character in $Parameters.SaPassword.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    try { Assert-LabSaPasswordPreflight -Password $secure -Policy $policy }
    finally { $secure.Dispose() }
}

function Assert-LabSaPasswordWorkflowJsonShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidateSet('NewContainerLab','NewContainerLabFromManifest')][string]$Action)
    if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 8192) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
        $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $parameters = $null
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if (-not $rootNames.Add($property.Name) -or $property.Name -cnotin @('action','parameters')) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
            if ($property.Name -ceq 'action' -and
                ($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or $property.Value.GetString() -cne $Action)) {
                throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID'
            }
            if ($property.Name -ceq 'parameters') { $parameters = $property.Value }
        }
        if ($rootNames.Count -ne 2 -or $null -eq $parameters -or
            $parameters.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $allowed = if ($Action -ceq 'NewContainerLab') {
            @('Provider','SqlVersion','Profile','InstanceId','LabName','PersistentData','AutoStart',
                'SaPassword','DataRoot','PersistentStorageId','PersistentStorageAction','SaPasswordMinimumLength')
        }
        else { @('ManifestPath','SaPassword') }
        foreach ($property in $parameters.EnumerateObject()) {
            if (-not $names.Add($property.Name) -or $property.Name -cnotin $allowed) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
            $kind = $property.Value.ValueKind
            if ($property.Name -ceq 'PersistentData') {
                if ($kind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
            }
            elseif ($property.Name -ceq 'SaPasswordMinimumLength') {
                $minimum = 0
                if ($kind -ne [Text.Json.JsonValueKind]::Number -or
                    -not $property.Value.TryGetInt32([ref]$minimum) -or $minimum -lt 1 -or $minimum -gt 8) {
                    throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID'
                }
            }
            elseif ($kind -ne [Text.Json.JsonValueKind]::String) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
        }
        if (-not $names.Contains('SaPassword')) { throw 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' }
    }
    finally { $document.Dispose() }
}

function Get-LabSaPasswordConfigSeedCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,7)][int]$MinimumLength)
    # Nur ein validierter Integer gelangt in den konstanten Shelltext. Keine
    # vorhandene Datei oder Symlink wird ersetzt; Fehler stoppen vor SQLstart.
    return "test ! -e /sql-lab-volume-init/mssql.conf && test ! -L /sql-lab-volume-init/mssql.conf && (umask 007; printf '[passwordpolicy]\npasswordminimumlength=$MinimumLength\n' > /sql-lab-volume-init/mssql.conf) && chown 10001:0 /sql-lab-volume-init/mssql.conf && chmod 0660 /sql-lab-volume-init/mssql.conf"
}

function Assert-LabSaPasswordContainerSeedScope {
    [CmdletBinding()]
    param([string]$VersionId, [string]$Provider, [object[]]$Drives,
        [string]$ResolvedImage, [string]$LaunchMode)
    $system = @($Drives | Where-Object { $_.id -ceq 'runtime-mssql' -and $_.containerPath -ceq '/var/opt/mssql' })
    $others = @($Drives | Where-Object { $_ -notin $system })
    $policy = Get-LabSaPasswordPolicy -Version $VersionId -Provider $Provider -Drives $others `
        -HasDerivedImage ([bool]$ResolvedImage -or $LaunchMode -cne 'none')
    if (-not $policy.CanCustomizeMinimum -or $system.Count -ne 1 -or $system[0].hostPath -or
        $system[0].runtimeBinding -or $system[0].persistence -cne 'run-scoped-runtime-volume' -or
        -not $system[0].persistentStorageId) { throw 'SA_PASSWORD_POLICY_CONTAINER_SCOPE_INVALID' }
}

function Read-LabGuidedSaPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy, [ValidateRange(1,20)][int]$MaxAttempts = 3)
    $minimum = [int]$Policy.MinimumLength
    foreach ($criterion in $Policy.Criteria) { Write-LabInfo $criterion }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $password = $null; $confirmation = $null; $accepted = $false
        try {
            $password = Read-Host 'SA-Passwort' -AsSecureString
            $check = Test-LabSaPassword -Password $password -MinimumLength $minimum
            if (-not $check.Valid) {
                Write-LabWarning ('Passwortanforderungen: ' + ($check.ReasonCodes -join ', '))
                $items = @(
                    New-LabConsoleItem -Id 'correct' -Label 'Passwort korrigieren' -Shortcut '1'
                    New-LabConsoleItem -Id 'cancel' -Label 'Abbrechen / anderes Ziel waehlen' -Shortcut '2'
                )
                if ($Policy.CanCustomizeMinimum -and ($check.ReasonCodes -join ',') -ceq 'SA_PASSWORD_MINIMUM_LENGTH') {
                    $items += New-LabConsoleItem -Id 'adjust' -Label 'Mindestlaenge bewusst fuer dieses neue Lab aendern' -Shortcut '3'
                }
                elseif (-not $Policy.CanCustomizeMinimum) { Write-LabWarning ('Anpassung nicht verfuegbar: ' + $Policy.CustomizationReason) }
                $choice = Show-LabSubMenu -ScreenId 'sa-password-correction' -Title 'SA-Passwort korrigieren' -Items $items
                if (-not $choice -or $choice -eq 'cancel') { return [pscustomobject]@{Status='Cancelled';Password=$null;MinimumLength=8} }
                if ($choice -eq 'correct') { continue }
                if ($choice -ne 'adjust' -or -not $Policy.CanCustomizeMinimum -or
                    ($check.ReasonCodes -join ',') -cne 'SA_PASSWORD_MINIMUM_LENGTH') {
                    throw 'SA_PASSWORD_DIALOG_SELECTION_INVALID'
                }
                $inputMinimum = Read-Host 'Neue Mindestlaenge fuer dieses Lab (1 bis 8; leer = Abbruch)'
                if (-not $inputMinimum) { return [pscustomobject]@{Status='Cancelled';Password=$null;MinimumLength=8} }
                if ($inputMinimum -cnotmatch '^[1-8]$') { Write-LabWarning 'SA_PASSWORD_POLICY_MINIMUM_INVALID'; continue }
                $minimum = [int]$inputMinimum
                if (-not (Read-LabConfirm -Prompt "Mindestlaenge $minimum nur fuer dieses neue Lab konfigurieren? Drei Zeichengruppen bleiben erforderlich." -Default $false)) {
                    return [pscustomobject]@{Status='Cancelled';Password=$null;MinimumLength=8}
                }
                $check = Test-LabSaPassword -Password $password -MinimumLength $minimum
                if (-not $check.Valid) { Write-LabWarning ('Passwortanforderungen: ' + ($check.ReasonCodes -join ', ')); continue }
            }
            $confirmation = Read-Host 'SA-Passwort bestaetigen' -AsSecureString
            $plain = $null; $confirmPlain = $null
            try {
                $plain = ConvertFrom-LabSecureString -SecureString $password
                $confirmPlain = ConvertFrom-LabSecureString -SecureString $confirmation
                $matches = $plain -ceq $confirmPlain
            }
            finally { $plain = $null; $confirmPlain = $null }
            if (-not $matches) { Write-LabWarning 'Passwoerter stimmen nicht ueberein.'; continue }
            $accepted = $true
            return [pscustomobject]@{Status='Accepted';Password=$password;MinimumLength=$minimum}
        }
        finally {
            if ($confirmation) { $confirmation.Dispose() }
            if ($password -and -not $accepted) { $password.Dispose() }
        }
    }
    return [pscustomobject]@{Status='Cancelled';Password=$null;MinimumLength=8}
}

function Assert-LabSaPasswordVolumeSeedScope {
    [CmdletBinding()]
    param([string]$VersionId, [string]$Provider, [string]$ContainerPath,
        [string]$Persistence, [bool]$SyncImageContent, $RuntimeBinding)
    $policy = Get-LabSaPasswordPolicy -Version $VersionId -Provider $Provider
    if (-not $policy.CanCustomizeMinimum -or $ContainerPath -cne '/var/opt/mssql' -or
        $Persistence -cne 'run-scoped-runtime-volume' -or $SyncImageContent -or $RuntimeBinding) {
        throw 'SA_PASSWORD_POLICY_VOLUME_SCOPE_INVALID'
    }
}
