<#
.SYNOPSIS
    Stellt den interaktiven UAC-Uebergang fuer Hyper-V-Aktionen bereit.
.DESCRIPTION
    Hyper-V-Switches, virtuelle Maschinen und deren Hostadapter duerfen nur
    in einer erhöhten Windows-Sitzung geaendert werden. Der interaktive
    Einstieg oeffnet bei Bedarf einen separaten, sichtbaren UAC-Prozess und
    uebergibt ihm die gewaehlte Lab-Aktion.
#>

function Test-LabAdministrator {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LabActionPrivilegeClass {
    <#
    .SYNOPSIS
        Klassifiziert UI-Aktionen nach ihrem maximal benoetigten Hostzugriff.
    .DESCRIPTION
        Die Klassifikation startet selbst keine Erhoehung. Administratoraktionen
        muessen weiterhin an ihrer konkreten Action Preview bestaetigt werden.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action)

    switch ($Action) {
        { $_ -in @('Image', 'WindowsSlotPool') } { 'Administrator' }
        { $_ -in @(
            'New', 'AutomatedTestEnvironment', 'ClearAutomatedTestEnvironment',
            'Stop', 'Start', 'Restart', 'Remove', 'Clear', 'Script', 'Database',
            'Rename', 'UpdateContainer', 'Resources', 'Manage', 'Install7Zip'
        ) } { 'RuntimeAccess' }
        default { 'User' }
    }
}

function Start-LabElevatedAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Image', 'WindowsSlotPool')]
        [string]$Action,
        $ResourcePreview,
        [scriptblock]$AdministratorProbe = { Test-LabAdministrator },
        [scriptblock]$ConfirmationAction,
        [scriptblock]$ProcessStarter,
        [switch]$AssumeWindows
    )

    if (-not $IsWindows -and -not $AssumeWindows) { throw 'LAB_ELEVATION_WINDOWS_REQUIRED' }

    function New-ElevationActionResult {
        param(
            [Parameter(Mandatory)][ValidateSet('Changed','NoChange','Cancelled','Failed')][string]$Status,
            [Parameter(Mandatory)][bool]$Started,
            [Parameter(Mandatory)][string]$Reason
        )
        $mutations = if ($Started) { @([PSCustomObject]@{ Kind='ElevationProcess'; Result='STARTED' }) } else { @() }
        $result = New-LabActionResult -Action $Action -Status $Status -Mutations $mutations -ConnectionCenterImpact None
        $result | Add-Member -NotePropertyName Started -NotePropertyValue $Started -Force
        $result | Add-Member -NotePropertyName Reason -NotePropertyValue $Reason -Force
        return $result
    }

    $validatedPreview = if ($ResourcePreview) {
        Assert-LabHyperVResourceLocationPreview -Preview $ResourcePreview
    }
    else { $null }

    if (& $AdministratorProbe) {
        if ($validatedPreview) { $script:HyperVResourceLocationHandoff = $validatedPreview }
        return New-ElevationActionResult -Status NoChange -Started $false -Reason 'ALREADY_ELEVATED'
    }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) { throw 'LAB_ELEVATION_PWSH_NOT_FOUND' }
    $modulePath = Join-Path $script:ModuleRoot 'SqlServerLab.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'LAB_ELEVATION_MODULE_NOT_FOUND' }

    $escapedModulePath = $modulePath.Replace("'", "''")
    # Import-Module besitzt keinen -LiteralPath-Parameter. Der einzeln
    # quotierte, zuvor maskierte Pfad verhindert weiterhin eine Auswertung
    # von Leerzeichen oder Sonderzeichen im Modulpfad.
    if ($validatedPreview) {
        $previewJson = $validatedPreview | ConvertTo-Json -Depth 12 -Compress
        $encodedPreview = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($previewJson))
        $command = "Import-Module '$escapedModulePath' -Force; & (Get-Module SqlServerLab) { param([string]`$payload) `$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$payload)); `$preview = `$json | ConvertFrom-Json -Depth 12; `$script:HyperVResourceLocationHandoff = Assert-LabHyperVResourceLocationPreview -Preview `$preview; Invoke-SqlServerLab -Action $Action } '$encodedPreview'"
    }
    else {
        $command = "Import-Module '$escapedModulePath' -Force; Invoke-SqlServerLab -Action $Action"
    }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-LabInfo "Für '$Action' wird ein neues PowerShell-Fenster mit Administratorrechten benötigt."
    Write-LabInfo 'Die aktuelle Benutzersitzung bleibt unverändert; erst die bestätigte Hyper-V-Aktion wird erhöht fortgesetzt.'
    $confirmed = if ($ConfirmationAction) {
        [bool](& $ConfirmationAction)
    }
    else {
        Read-LabConfirm -Prompt '  Administratorfenster und anschließende Windows-Sicherheitsabfrage jetzt öffnen?' -Default $false
    }
    if (-not $confirmed) {
        return New-ElevationActionResult -Status Cancelled -Started $false -Reason 'USER_DECLINED'
    }
    if ($ProcessStarter) {
        & $ProcessStarter $pwsh.Source @('-NoProfile', '-NoExit', '-EncodedCommand', $encodedCommand)
    }
    else {
        Start-Process -FilePath $pwsh.Source -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', $encodedCommand) -ErrorAction Stop
    }
    return New-ElevationActionResult -Status Changed -Started $true -Reason 'UAC_PROMPTED'
}
