function Resolve-LabWindowsSlotPoolArtifact {
    [CmdletBinding()]
    param(
        [ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [switch]$VerifyIntegrity,
        [string]$StateRoot
    )

    $candidates = @(Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck | Where-Object {
        [string]$_.artifactState -eq 'OS_SEALED' -and
        [bool]$_.generalized -and
        [string]$_.operatingSystem.id -match '^windows-(server-)?[0-9]+$' -and
        (Test-HyperVImageArtifactEvaluationEligibility -Artifact $_ `
            -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining).Eligible
    })
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
        [Parameter(Mandatory)][string]$InputLocale,
        [Parameter(Mandatory)][string]$TimeZone,
        [Parameter(Mandatory)]$Artifact
    )

    $null = Resolve-HyperVLocaleGeoId -Region $Region
    foreach ($locale in @($SystemLocale, $UiLanguage)) {
        try { $null = [Globalization.CultureInfo]::GetCultureInfo($locale) }
        catch { throw "HYPERV_WINDOWS_SLOT_POOL_LOCALE_UNSUPPORTED: $locale" }
    }
    if ($InputLocale -notmatch '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$') {
        throw "HYPERV_WINDOWS_SLOT_POOL_INPUT_LOCALE_INVALID: $InputLocale"
    }
    try { $null = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) }
    catch { throw "HYPERV_WINDOWS_SLOT_POOL_TIME_ZONE_UNSUPPORTED: $TimeZone" }

    $artifactLanguage = [string]$Artifact.operatingSystem.language
    if (-not [string]::IsNullOrWhiteSpace($artifactLanguage) -and
        -not $artifactLanguage.Equals($UiLanguage, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HYPERV_WINDOWS_SLOT_POOL_UI_LANGUAGE_NOT_IN_BASELINE: requested=$UiLanguage, baseline=$artifactLanguage"
    }
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

        Der Aufruf ist wiederaufnehmbar: exakt passende vorhandene Slots werden
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
    .PARAMETER ArtifactId
        Optionale explizite OS_SEALED-Artifact-ID. Ohne Angabe wird die neueste
        geeignete Windows-Server-Baseline deterministisch ausgewählt.
    .PARAMETER MinimumEvaluationDaysRemaining
        Erforderliche Evaluation-Restlaufzeit. Der Standard ist 30 Tage.
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
    .PARAMETER SystemLocale
        Windows-System-Locale, zum Beispiel de-AT.
    .PARAMETER UiLanguage
        Windows-Anzeigesprache. Sie muss der Sprache der Baseline entsprechen.
    .PARAMETER InputLocale
        Windows-Tastaturlayout im Input-Locale-Format.
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
        [ValidateRange(1, 9999)][int]$StartIndex = 1,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,52}$')][string]$NamePrefix = 'windows-sql-slot',
        [ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [ValidateRange(512, 1048576)][int]$MemoryMinimumMB = 1024,
        [ValidateRange(512, 1048576)][int]$MemoryStartupMB = 2048,
        [ValidateRange(512, 1048576)][int]$MemoryMaximumMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [Parameter(Mandatory, ParameterSetName = 'UserPassword')][SecureString]$AdministratorPassword,
        [Parameter(Mandatory, ParameterSetName = 'GeneratedPassword')][switch]$GenerateAdministratorPasswords,
        [ValidatePattern('^[A-Za-z]{2}(-[A-Za-z]{2})?$')][string]$Region = 'AT',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-AT',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
        [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale = '0407:00000407',
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

    $artifact = Resolve-LabWindowsSlotPoolArtifact -ArtifactId $ArtifactId `
        -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining -VerifyIntegrity -StateRoot $StateRoot
    if (-not $artifact) {
        throw 'HYPERV_WINDOWS_SLOT_POOL_BASELINE_REQUIRED: Keine geeignete OS_SEALED-Baseline mit ausreichender Evaluation-Restlaufzeit vorhanden.'
    }
    Assert-LabWindowsSlotPoolLocale -Region $Region -SystemLocale $SystemLocale `
        -UiLanguage $UiLanguage -InputLocale $InputLocale -TimeZone $TimeZone -Artifact $artifact

    $lastIndex = $StartIndex + $Count - 1
    $indexWidth = [Math]::Max(2, ([string]$lastIndex).Length)
    $specifications = @(
        for ($index = $StartIndex; $index -le $lastIndex; $index++) {
            $name = '{0}-{1}' -f $NamePrefix, $index.ToString("D$indexWidth")
            if ($name.Length -gt 64) { throw "HYPERV_WINDOWS_SLOT_POOL_NAME_TOO_LONG: $name" }
            [PSCustomObject]@{ Index=$index; Name=$name; Existing=$null; Lab=$null }
        }
    )

    $activeRuns = @(Get-LabActiveRuns -StateRoot $StateRoot)
    foreach ($specification in $specifications) {
        $matches = @($activeRuns | Where-Object {
            [string]$_.metadata.name -eq [string]$specification.Name
        })
        if ($matches.Count -gt 1) { throw "HYPERV_WINDOWS_SLOT_POOL_NAME_AMBIGUOUS: $($specification.Name)" }
        if ($matches.Count -eq 0) { continue }
        $lab = Get-HyperVLabWorkflowRun -RunId ([string]$matches[0].runId) -StateRoot $StateRoot
        $resource = $lab.Instance.resourceSettings
        $issues = [Collections.Generic.List[string]]::new()
        if ([string]$lab.Instance.provider -ne 'hyperv') { $issues.Add('provider') }
        if ([string]$lab.Instance.workload -ne 'windows') { $issues.Add('workload') }
        if ([string]$lab.Instance.imageArtifactId -ne [string]$artifact.artifactId) { $issues.Add('artifact') }
        if (-not [bool]$resource.dynamicMemoryEnabled -or
            [int]$resource.memoryMinimumMB -ne $MemoryMinimumMB -or
            [int]$resource.memoryStartupMB -ne $MemoryStartupMB -or
            [int]$resource.memoryMaximumMB -ne $MemoryMaximumMB -or
            [int]$resource.processorCount -ne $ProcessorCount) { $issues.Add('resources') }
        if ([string]$lab.Run.metadata.networkIntent -ne 'hostOnly') { $issues.Add('network') }
        $runtime = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
        if (-not $runtime.Exists) { $issues.Add('runtime-missing') }
        if ($issues.Count -gt 0) {
            throw "HYPERV_WINDOWS_SLOT_POOL_EXISTING_SLOT_CONFLICT: $($specification.Name): $($issues -join ',')"
        }
        $specification.Existing = $true
        $specification.Lab = $lab
    }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($specification in $specifications) {
        if ($specification.Existing) { continue }
        if (-not $PSCmdlet.ShouldProcess($specification.Name, 'Windows-OS-Slot erstellen')) { continue }
        $created = New-HyperVLabEnvironment -ArtifactId ([string]$artifact.artifactId) `
            -LabName ([string]$specification.Name) -InstanceId primary `
            -DynamicMemoryEnabled $true -MemoryMinimumMB $MemoryMinimumMB `
            -MemoryStartupMB $MemoryStartupMB -MemoryMaximumMB $MemoryMaximumMB `
            -ProcessorCount $ProcessorCount -AutoStart off -NetworkIntent hostOnly -StateRoot $StateRoot
        $specification.Lab = Get-HyperVLabWorkflowRun -RunId ([string]$created.RunId) -StateRoot $StateRoot
        $results.Add([PSCustomObject]@{
            Index=$specification.Index; Name=$specification.Name; RunId=[string]$created.RunId
            VMName=[string]$created.VMName; Action='CREATED'; State='OOBE_PENDING'
        })
    }

    foreach ($specification in $specifications) {
        if (-not $specification.Lab) { continue }
        $lab = Get-HyperVLabWorkflowRun -RunId ([string]$specification.Lab.Run.runId) -StateRoot $StateRoot
        $complete = [string]$lab.Instance.windowsProvisioning.state -eq 'COMPLETE' -or
            [string]$lab.Instance.oobeAutomation.status -eq 'COMPLETED'
        if ($complete) {
            $runtime = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
            if ($LeaveRunning -and [string]$runtime.State -ne 'Running') {
                if ($PSCmdlet.ShouldProcess($specification.Name, 'Fertigen Windows-OS-Slot starten')) {
                    $null = Start-HyperVLabEnvironment -RunId ([string]$lab.Run.runId) -StateRoot $StateRoot
                }
            }
            elseif (-not $LeaveRunning -and [string]$runtime.State -ne 'Off') {
                if ($PSCmdlet.ShouldProcess($specification.Name, 'Fertigen Windows-OS-Slot stoppen')) {
                    $null = Stop-HyperVLabEnvironment -RunId ([string]$lab.Run.runId) -StateRoot $StateRoot
                }
            }
            $results.Add([PSCustomObject]@{
                Index=$specification.Index; Name=$specification.Name; RunId=[string]$lab.Run.runId
                VMName=[string]$lab.Instance.vmName; Action='REUSED'
                State=$(if ($WhatIfPreference) { 'PLANNED' } elseif ($LeaveRunning) { 'RUNNING' } else { 'STOPPED' })
            })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($specification.Name, 'Windows-OOBE unbeaufsichtigt abschließen')) { continue }

        $password = $AdministratorPassword
        $passwordSource = 'user'
        if ($GenerateAdministratorPasswords) {
            $passwordSource = 'generated'
            $password = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-windows-administrator-password'
            if (-not $password -and [string]$lab.Instance.oobeAutomation.passwordSource -eq 'generated') {
                $password = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
            }
            if (-not $password) { $password = New-HyperVSqlUnattendedPassword }
        }
        $runtime = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
        if ([string]$runtime.State -ne 'Off') {
            $null = Stop-HyperVLabEnvironment -RunId ([string]$lab.Run.runId) -StateRoot $StateRoot
        }
        $null = Invoke-HyperVLabUnattendedProvision -RunId ([string]$lab.Run.runId) `
            -AdministratorPassword $password -PasswordSource $passwordSource `
            -Region $Region -SystemLocale $SystemLocale -UiLanguage $UiLanguage `
            -InputLocale $InputLocale -TimeZone $TimeZone -StateRoot $StateRoot
        if (-not $LeaveRunning) {
            $null = Stop-HyperVLabEnvironment -RunId ([string]$lab.Run.runId) -StateRoot $StateRoot
        }
        $results.Add([PSCustomObject]@{
            Index=$specification.Index; Name=$specification.Name; RunId=[string]$lab.Run.runId
            VMName=[string]$lab.Instance.vmName; Action=$(if ($specification.Existing) { 'COMPLETED' } else { 'CREATED_AND_COMPLETED' })
            State=$(if ($LeaveRunning) { 'RUNNING' } else { 'STOPPED' })
        })
        $password = $null
    }

    $orderedResults = @($results | Group-Object RunId | ForEach-Object { $_.Group | Select-Object -Last 1 } | Sort-Object Index)
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.WindowsSlotPoolResult/1.0'
        Status = if ($WhatIfPreference) { 'PLANNED' } elseif ($orderedResults.Count -eq $Count) { 'COMPLETE' } else { 'PARTIAL' }
        ArtifactId = [string]$artifact.artifactId
        Count = $Count
        Memory = [PSCustomObject]@{ MinimumMB=$MemoryMinimumMB; StartupMB=$MemoryStartupMB; MaximumMB=$MemoryMaximumMB }
        Locale = [PSCustomObject]@{ Region=$Region; SystemLocale=$SystemLocale; UiLanguage=$UiLanguage; InputLocale=$InputLocale; TimeZone=$TimeZone }
        Slots = $orderedResults
    }
}
