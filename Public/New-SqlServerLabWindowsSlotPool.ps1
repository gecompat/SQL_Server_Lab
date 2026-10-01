function Resolve-LabWindowsSlotPoolArtifact {
    [CmdletBinding()]
    param(
        [ValidatePattern('^(?:hyperv-os-sealed-[a-f0-9]{64})?$')][string]$ArtifactId,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [ValidateSet('core', 'desktop-experience')][string]$InstallationType = 'desktop-experience',
        [switch]$VerifyIntegrity,
        [string]$StateRoot
    )

    $eligibleCandidates = @(Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck | Where-Object {
        [string]$_.artifactState -eq 'OS_SEALED' -and
        [bool]$_.generalized -and
        [string]$_.operatingSystem.id -match '^windows-(server-)?[0-9]+(?:-r2)?$' -and
        (Test-HyperVImageArtifactEvaluationEligibility -Artifact $_ `
            -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining).Eligible
    })
    # Eine explizite, gültige Artifact-ID ist die konkrete Auswahl. Der
    # InstallationType steuert nur die automatische Suche und darf eine
    # vorhandene Core-Baseline nicht wegen des Desktop-Defaults verwerfen.
    $candidates = if ($ArtifactId) {
        $eligibleCandidates
    }
    else {
        @($eligibleCandidates | Where-Object { [string]$_.operatingSystem.installationType -eq $InstallationType })
    }
    if ($ArtifactId -and $candidates.Count -ne 1) {
        throw 'HYPERV_WINDOWS_SLOT_POOL_ARTIFACT_NOT_ELIGIBLE'
    }
    $selected = @($candidates | Sort-Object `
        @{ Expression = {
            $match = [regex]::Match([string]$_.operatingSystem.version, '\d{4}')
            if ($match.Success) { [int]$match.Value } else { -1 }
        }; Descending = $true }, `
        @{ Expression = { [datetime]$_.registeredAt }; Descending = $true }, `
        @{ Expression = { [string]$_.artifactId }; Descending = $false } |
        Select-Object -First 1)[0]
    if (-not $selected) { return $null }
    if ($VerifyIntegrity) {
        $selected = Get-HyperVImageArtifact -ArtifactId ([string]$selected.artifactId) -StateRoot $StateRoot
    }
    return $selected
}

function Assert-LabWindowsSlotPoolLocale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$SystemLocale,
        [Parameter(Mandatory)][string]$UiLanguage,
        [AllowNull()][string]$InputLocale,
        [Parameter(Mandatory)][string]$TimeZone,
        [Parameter(Mandatory)]$Artifact
    )
    $overrides=@{Region=$Region;SystemLocale=$SystemLocale;UiLanguage=$UiLanguage;TimeZone=$TimeZone}
    if(-not [string]::IsNullOrWhiteSpace($InputLocale)){$overrides.InputLocale=$InputLocale}
    $normalized=Resolve-LabWindowsLocaleIntent -Overrides $overrides
    Assert-LabWindowsLocaleImageCapability -Intent $normalized -Artifact $Artifact
    return $normalized
}

function New-SqlServerLabWindowsSlotPool {
    <#
    .SYNOPSIS
        Erstellt einen Pool vollständig eingerichteter Windows-OS-Slots.
    .DESCRIPTION
        Wählt deterministisch eine gültige, verifizierte OS_SEALED-Baseline,
        erstellt N unabhängige differenzierende Hyper-V-VMs und führt Windows-
        OOBE, regionale Einstellungen und die notwendige Initialanmeldung
        unbeaufsichtigt aus. Danach werden die VMs standardmäßig wieder gestoppt.

        Der Aufruf ist mit derselben Pool-ID wiederaufnehmbar: exakt gebundene Slots werden
        übernommen und bereits vollständig eingerichtete Slots übersprungen.
        Namens-, Ressourcen-, Artifact- oder Runtime-Konflikte brechen vor einer
        weiteren Slot-Mutation ab. Eine fehlende oder bald ablaufende Baseline
        wird nicht technisch verlängert; der interaktive CLI-Workflow führt in
        diesem Fall zum Windows-Image-Aufbau.
    .PARAMETER Count
        Anzahl der Slots.
    .PARAMETER StartIndex
        Erste numerische Slotnummer.
    .PARAMETER NamePrefix
        Gemeinsames Namenspräfix. Die Slotnummer wird mindestens zweistellig
        angehängt, zum Beispiel windows-sql-slot-01.
    .PARAMETER PoolId
        Explizite Membership-ID. Für Resume dieselbe ID und Konfiguration
        wiederverwenden. Namen übernehmen keine bestehenden Windows-Labs.
    .PARAMETER ArtifactId
        Optionale explizite OS_SEALED-Artifact-ID. Ohne Angabe wird die neueste
        geeignete Windows-Server-Baseline deterministisch ausgewählt.
    .PARAMETER MinimumEvaluationDaysRemaining
        Erforderliche Evaluation-Restlaufzeit. Der Standard ist 30 Tage.
    .PARAMETER InstallationType
        Gewünschte Windows-Variante der OS_SEALED-Baseline: `desktop-experience` oder `core`. Der Standard bewahrt bestehende Desktop-Pools.
    .PARAMETER MemoryMinimumMB
        Minimaler dynamischer Arbeitsspeicher pro Slot. Standard: 1024 MB.
    .PARAMETER MemoryStartupMB
        Startspeicher pro Slot. Standard: 2048 MB.
    .PARAMETER MemoryMaximumMB
        Maximaler dynamischer Arbeitsspeicher pro Slot. Standard: 4096 MB.
    .PARAMETER ProcessorCount
        Virtuelle Prozessoren pro Slot. Standard: 4.
    .PARAMETER AdministratorPassword
        Eigenes gemeinsames lokales Administratorpasswort für alle Slots.
    .PARAMETER GenerateAdministratorPasswords
        Erzeugt für jeden Slot ein eigenes starkes Passwort. Es wird pro Run
        DPAPI-geschützt gespeichert und kann gezielt mit
        Get-SqlServerLabGeneratedWindowsAccess abgerufen werden.
    .PARAMETER Region
        Windows-Region, zum Beispiel AT oder DE.
    .PARAMETER WindowsActivation
        Vollstaendiger WindowsActivationIntent/1.0 mit Strategy und EgressPolicy.
        Ohne Angabe wird ausschliesslich vorhandener Egress verwendet.
    .PARAMETER SystemLocale
        Windows-System-Locale, zum Beispiel de-AT.
    .PARAMETER UiLanguage
        Windows-Anzeigesprache. Sie muss der Sprache der Baseline entsprechen.
    .PARAMETER InputLocale
        Windows-Tastaturlayout im Input-Locale-Format. Ohne Angabe wird ein
        eindeutiges unterstuetztes Layout des aktuellen interaktiven
        Windows-Benutzers gebunden; andernfalls gilt 0407:00000407 mit Grundcode.
    .PARAMETER TimeZone
        Windows-Zeitzonen-ID.
    .PARAMETER LeaveRunning
        Lässt erfolgreich eingerichtete Slots laufen. Standardmäßig werden sie
        zur Ressourcenschonung wieder gestoppt.
    .PARAMETER StateRoot
        Optionaler abweichender State Root.
    .OUTPUTS
        PSCustomObject mit Artifact-ID, Gesamtstatus und einem Ergebnis je Slot.
    .EXAMPLE
        $password = Read-Host 'Administratorpasswort' -AsSecureString
        New-SqlServerLabWindowsSlotPool -Count 20 -AdministratorPassword $password
    .EXAMPLE
        New-SqlServerLabWindowsSlotPool -Count 20 -GenerateAdministratorPasswords `
            -Region AT -SystemLocale de-AT -UiLanguage en-US `
            -InputLocale '0407:00000407'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'GeneratedPassword')]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Count,
        [guid]$PoolId = [guid]::NewGuid(),
        [ValidateRange(1, 9999)][int]$StartIndex = 1,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,52}$')][string]$NamePrefix = 'windows-sql-slot',
        [ValidatePattern('^(?:hyperv-os-sealed-[a-f0-9]{64})?$')][string]$ArtifactId,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [ValidateSet('core', 'desktop-experience')][string]$InstallationType = 'desktop-experience',
        [ValidateRange(512, 1048576)][int]$MemoryMinimumMB = 1024,
        [ValidateRange(512, 1048576)][int]$MemoryStartupMB = 2048,
        [ValidateRange(512, 1048576)][int]$MemoryMaximumMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [Parameter(Mandatory, ParameterSetName = 'UserPassword')][SecureString]$AdministratorPassword,
        [Parameter(Mandatory, ParameterSetName = 'GeneratedPassword')][switch]$GenerateAdministratorPasswords,
        [ValidatePattern('^[A-Za-z]{2}(-[A-Za-z]{2})?$')][string]$Region = 'AT',
        $WindowsActivation,
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-AT',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
        [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale,
        [string]$TimeZone = 'W. Europe Standard Time',
        [switch]$LeaveRunning,
        [string]$StateRoot
    )

    if (-not $IsWindows) { throw 'HYPERV_WINDOWS_SLOT_POOL_WINDOWS_HOST_REQUIRED' }
    if (-not (Test-LabAdministrator)) { throw 'HYPERV_WINDOWS_SLOT_POOL_REQUIRES_ELEVATED_RUNNER' }
    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "HYPERV_WINDOWS_SLOT_POOL_UNAVAILABLE: $($availability.Message)" }
    if ($MemoryMinimumMB -gt $MemoryStartupMB -or $MemoryStartupMB -gt $MemoryMaximumMB) {
        throw 'HYPERV_WINDOWS_SLOT_POOL_MEMORY_RANGE_INVALID'
    }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    # Ein Slot-Pool verwendet dauerhaft hostOnly. Dieser Adapter hat bewusst
    # keinen Egress; für die einmalige Evaluation braucht der Pool daher einen
    # explizit kontrollierten, anschließend wieder entfernten Adapter.
    $poolActivation = if ($PSBoundParameters.ContainsKey('WindowsActivation')) {
        Resolve-LabWindowsActivationIntent -Intent $WindowsActivation
    }
    else {
        Resolve-LabWindowsActivationIntent -Intent @{
            ContractVersion = 'SqlServerLab.WindowsActivationIntent/1.0'
            Strategy = 'EvaluationOnline'
            EgressPolicy = 'AllowTemporary'
        }
    }

    $artifact = Resolve-LabWindowsSlotPoolArtifact -ArtifactId $ArtifactId `
        -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining -InstallationType $InstallationType -VerifyIntegrity -StateRoot $StateRoot
    if (-not $artifact) {
        throw 'HYPERV_WINDOWS_SLOT_POOL_BASELINE_REQUIRED: Keine geeignete OS_SEALED-Baseline der gewählten Windows-Variante mit ausreichender Evaluation-Restlaufzeit vorhanden.'
    }
    $poolLocale=Assert-LabWindowsSlotPoolLocale -Region $Region -SystemLocale $SystemLocale `
        -UiLanguage $UiLanguage -InputLocale $InputLocale -TimeZone $TimeZone -Artifact $artifact

    $StateRoot=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $configuration=[ordered]@{Count=$Count;StartIndex=$StartIndex;NamePrefix=$NamePrefix;ArtifactId=[string]$artifact.artifactId
        ProcessorCount=$ProcessorCount;MemoryMinimumMB=$MemoryMinimumMB;MemoryStartupMB=$MemoryStartupMB;MemoryMaximumMB=$MemoryMaximumMB
        Locale=$poolLocale;Activation=$poolActivation;LeaveRunning=[bool]$LeaveRunning}
    $key=Get-LabWorkflowHash -Text ($configuration | ConvertTo-Json -Depth 10 -Compress) -Length 64
    $preview=Get-LabWindowsPoolCreationPreview -PoolId $PoolId.ToString() -Configuration $configuration -StateRoot $StateRoot
    if(-not $PSCmdlet.ShouldProcess(($NamePrefix+' / '+$PoolId), 'Angezeigten Windows-Pool erstellen oder exakt gebunden fortsetzen')){
        return [pscustomobject]@{ContractVersion='SqlServerLab.WindowsSlotPoolResult/1.1';PoolId=$PoolId.ToString();Status='PLANNED';Slots=$preview}
    }
    $operation=Get-LabWindowsPoolPrepareIntent -PoolId $PoolId.ToString() -ConfigurationKey $key -StateRoot $StateRoot
    $context=[pscustomobject]@{StateRoot=$StateRoot;PoolId=$PoolId.ToString();OperationId=$operation.operationId;RunId=$null;Kind='Prepare';Index=0}
    $slots=Invoke-WithLabWindowsPoolOperation -Context $context -Body {
        Invoke-LabWindowsPoolPreparation -Context $context -Configuration $configuration -AdministratorPassword $AdministratorPassword `
            -GenerateAdministratorPasswords:$GenerateAdministratorPasswords -LeaveRunning:$LeaveRunning
    }
    return [pscustomobject]@{ContractVersion='SqlServerLab.WindowsSlotPoolResult/1.1';PoolId=$PoolId.ToString();OperationId=$operation.operationId
        Status=$(if(@($slots | Where-Object State -eq 'RECOVERY_REQUIRED').Count){'RECOVERY_REQUIRED'}elseif($LeaveRunning){'PREPARED_RUNNING'}else{'COMPLETE'})
        ArtifactId=$configuration.ArtifactId;Count=$Count;Locale=$poolLocale;Memory=[pscustomobject]@{MinimumMB=$MemoryMinimumMB;StartupMB=$MemoryStartupMB;MaximumMB=$MemoryMaximumMB};Slots=@($slots)}
}
