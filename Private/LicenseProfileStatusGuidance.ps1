function Get-LabLicenseProfileStatusGuidance {
    param([string]$Id, [string]$StateRoot)

    $contract = 'SqlServerLab.LicenseProfileStatusGuidance/1.0'
    if (-not $IsWindows) {
        return [pscustomobject]@{ContractVersion=$contract;Status='UNSUPPORTED';Profiles=@()}
    }
    if (-not $Id) {
        return [pscustomobject]@{
            ContractVersion=$contract; Status='LISTED'
            Profiles=@(Get-SqlServerLabLicenseProfile -StateRoot $StateRoot | Sort-Object Product,Version,Edition,Id |
                Select-Object Id,Product,Version,Edition,Channel,KeyAvailable)
        }
    }
    if ($Id -cnotmatch '^[a-z][a-z0-9.-]{2,63}$') { throw 'LICENSE_STATUS_ID_INVALID' }
    try {
        $read = Test-SqlServerLabLicenseProfile -Id $Id -StateRoot $StateRoot
        if ($read.Id -cne $Id -or $read.Status -cne 'READY' -or $read.OnlineActivationTested -ne $false) { throw 'LICENSE_STATUS_UNVERIFIED' }
        $status = 'READY'
    }
    catch {
        $code = ($_.Exception.Message -split ':',2)[0]
        $status = switch ($code) {
            'LICENSE_PROFILE_NOT_FOUND' { 'NOT_FOUND' }
            'LICENSE_PROFILE_SECRET_MISSING' { 'KEY_UNAVAILABLE' }
            'LICENSE_PROFILE_KEY_FORMAT_INVALID' { 'KEY_FORMAT_INVALID' }
            default { 'UNVERIFIABLE' }
        }
    }
    [pscustomobject]@{ContractVersion=$contract;Id=$Id;Status=$status;OnlineActivationTested=$false}
}

function Invoke-LabLicenseProfileStatusRequest {
    param([string]$Method, [Collections.Specialized.NameValueCollection]$Query)

    if ($Method -cne 'GET') { return @{StatusCode=405; View=@{Code='LICENSE_STATUS_REQUEST_INVALID'}} }
    $profileId = [string]$Query['profileId']
    if (@($Query.AllKeys | Where-Object { $_ -cne 'profileId' }).Count -or
        ($Query.Count -and $profileId -cnotmatch '^[a-z][a-z0-9.-]{2,63}$')) {
        return @{StatusCode=400; View=@{Code='LICENSE_STATUS_REQUEST_INVALID'}}
    }
    try { return @{StatusCode=200; View=(Get-LabLicenseProfileStatusGuidance -Id $profileId)} }
    catch { return @{StatusCode=503; View=@{Code='LICENSE_STATUS_UNAVAILABLE'}} }
}

function Show-LabLicenseProfileStatusInteractive {
    $stateRoot = Get-LabStateRoot
    try {
        $inventory = Get-LabLicenseProfileStatusGuidance -StateRoot $stateRoot
        if ($inventory.Status -ceq 'UNSUPPORTED') { Write-LabInfo 'Lokale Lizenzprofile benötigen Windows und DPAPI.' }
        elseif (-not @($inventory.Profiles).Count) { Write-LabInfo 'Es sind keine lokalen Lizenzprofile vorhanden.' }
        else {
            $items = @(foreach ($profile in $inventory.Profiles) {
                New-LabConsoleItem -Id $profile.Id -Label ('{0} {1} {2} · {3}' -f $profile.Product,$profile.Version,$profile.Edition,$profile.Id) `
                    -Value ('Kanal {0} · Key-Datei {1}' -f $profile.Channel,$(if ($profile.KeyAvailable) {'vorhanden'} else {'fehlt'})) -Data $profile.Id
            })
            $selected = Select-LabConsoleDataItem -ScreenId 'license-profile-status' -Title 'Lizenzprofil lokal prüfen' -Items $items
            if (-not $selected) { return }
            $observation = Get-LabLicenseProfileStatusGuidance -Id $selected -StateRoot $stateRoot
            Write-LabInfo ('Lokaler Befund für {0} · {1}' -f $selected,$observation.Status)
            Write-LabInfo 'Die lokale Prüfung bestätigt keine Onlineaktivierung.'
        }
    }
    catch { Write-LabError 'Die lokalen Lizenzprofile konnten nicht eindeutig geprüft werden.' }
    $null = Wait-LabConsoleAcknowledgement
}
