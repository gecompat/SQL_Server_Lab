<#
.SYNOPSIS
    Liefert eine verdichtete, persistente Workflow-Sicht fuer SQL_Server_Lab.
.DESCRIPTION
    Fasst Container-Runs, Windows-OS-Baselines, laufende Hyper-V-Builder,
    SQL-Prepared-Images und run-lokale Abnahmeumgebungen zusammen. Die Ausgabe
    enthaelt keine Geheimnisse und kann von einer Konsole oder einer lokalen UI
    verwendet werden.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Enthält Hostfähigkeiten,
    Workflow-Status, veröffentlichte Images, Abnahmeumgebungen und aktive Labs.
.EXAMPLE
    Get-SqlServerLabWorkflow
#>
function Get-SqlServerLabWorkflow {
    [CmdletBinding()]
    param()

    $stateRoot = Get-LabStateRoot
    $isElevated = $false
    if ($IsWindows) {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { }
    }

    $hyperV = [PSCustomObject]@{
        Supported = [bool]$IsWindows
        Available = $false
        Message = if ($IsWindows) { 'Hyper-V wird geprueft.' } else { 'Hyper-V ist nur auf einem Windows-Host verfuegbar.' }
    }
    if ($IsWindows) {
        try {
            $availability = Test-HyperVAvailable
            $hyperV.Available = [bool]$availability.Available
            $hyperV.Message = [string]$availability.Message
        }
        catch {
            $hyperV.Message = $_.Exception.Message
        }
    }

    $windowsBuilds = @()
    $sqlBuilds = @()
    $artifacts = @()
    $acceptance = @()
    $activeRuns = @()
    if ($hyperV.Supported) {
        try { $windowsBuilds = @(Get-HyperVImageBuildPlans 2>$null) } catch { }
        try { $sqlBuilds = @(Get-HyperVSqlImageBuildPlans 2>$null) } catch { }
        try { $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck 2>$null) } catch { }
        try { $acceptance = @(Get-HyperVSqlAcceptanceMatrix 2>$null) } catch { }
    }
    try { $activeRuns = @(Get-LabActiveRuns -StateRoot $stateRoot 2>$null) } catch { }

    $windowsItems = @($windowsBuilds | ForEach-Object {
        $state = [string]$_.state
        $next = switch ($state) {
            'BUILDER_READY' { 'VM starten und Windows in VMConnect installieren.' }
            'MANUAL_ACTION_REQUIRED' { 'Windows-Installation abschliessen und anschliessend verifizieren.' }
            'REBOOT_REQUIRED' { 'Warten, bis der Sysprep-Shutdown abgeschlossen ist; danach erneut pruefen.' }
            'RESUME_PENDING' { 'Windows-Image veroeffentlichen.' }
            'OS_SEALED' { 'Fertig: OS-Baseline ist veroeffentlicht.' }
            'FAILED' { 'Fehlerdetails pruefen oder den Builder aufraeumen.' }
            default { 'Status pruefen.' }
        }
        [PSCustomObject]@{
            BuildId = [string]$_.buildId; State = $state
            OperatingSystem = [string]$_.operatingSystem.id
            Edition = [string]$_.operatingSystem.edition
            InstallationType = [string]$_.operatingSystem.installationType
            VMName = if ($_.builder) { [string]$_.builder.vmName } else { $null }
            ArtifactId = if ($_.artifact) { [string]$_.artifact.artifactId } else { $null }
            InstallationVerified = [bool]($_.installationEvidence -and $_.installationEvidence.verified)
            SuggestedEvaluationExpiresAt = ((Get-Date).Date.AddDays(180)).ToString('yyyy-MM-dd')
            NextStep = $next
        }
    })

    $sqlItems = @($sqlBuilds | ForEach-Object {
        $state = [string]$_.state
        $fresh = [string]$_.provisioningMode -eq 'fresh-windows-media'
        $next = switch ($state) {
            'MANUAL_ACTION_REQUIRED' {
                if ($fresh) { 'VM starten, Windows installieren und einmal als Administrator anmelden.' }
                else { 'OOBE abschliessen und die SQL-Installation starten.' }
            }
            'REBOOT_REQUIRED' { 'VM starten, vollstaendig booten lassen; danach SQL PrepareImage fortsetzen.' }
            'RESUME_PENDING' { 'Prepared-Image veroeffentlichen.' }
            'SQL_PREPARED_SEALED' { 'Fertig: SQL-Prepared-Image ist veroeffentlicht.' }
            'SQL_READY_RUN' { 'SQL-Abnahmetest ausfuehren.' }
            'TESTS_PASSED' { 'Fertig: Abnahme ist bestanden.' }
            'FAILED' { 'Fehlerdetails pruefen; danach Recovery oder Cleanup waehlen.' }
            default { 'Status pruefen.' }
        }
        [PSCustomObject]@{
            BuildId = [string]$_.buildId; State = $state
            OperatingSystem = [string]$_.operatingSystem.id
            WindowsEdition = [string]$_.operatingSystem.edition
            InstallationType = [string]$_.operatingSystem.installationType
            SqlVersion = [string]$_.sql.version; SqlEdition = [string]$_.sql.edition
            VMName = if ($_.builder) { [string]$_.builder.vmName } else { $null }
            ArtifactId = if ($_.artifact) { [string]$_.artifact.artifactId } else { $null }
            SuggestedEvaluationExpiresAt = ((Get-Date).Date.AddDays(180)).ToString('yyyy-MM-dd')
            NextStep = $next
        }
    })

    [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        Host = [PSCustomObject]@{
            Platform = if ($IsWindows) { 'Windows' } else { 'Linux/macOS' }
            IsElevated = $isElevated
            HyperV = $hyperV
            Providers = @(Get-AvailableLabProviders | Sort-Object)
        }
        Defaults = [PSCustomObject]@{ MediaRoot = Get-LabMediaRootDefault }
        Summary = [PSCustomObject]@{
            WindowsBaselines = @($artifacts | Where-Object artifactState -eq 'OS_SEALED').Count
            SqlPreparedImages = @($artifacts | Where-Object artifactState -eq 'SQL_PREPARED_SEALED').Count
            ActiveContainerLabs = $activeRuns.Count
            PendingWindowsBuilds = @($windowsItems | Where-Object State -notin @('OS_SEALED', 'TEST_ARTIFACT_PUBLISHED')).Count
            PendingSqlBuilds = @($sqlItems | Where-Object State -notin @('SQL_PREPARED_SEALED', 'TESTS_PASSED')).Count
        }
        WindowsBaselines = @($artifacts | Where-Object artifactState -eq 'OS_SEALED' | ForEach-Object {
            [PSCustomObject]@{
                ArtifactId = [string]$_.artifactId; OperatingSystem = [string]$_.operatingSystem.id
                Version = [string]$_.operatingSystem.version; Edition = [string]$_.operatingSystem.edition
                InstallationType = [string]$_.operatingSystem.installationType; PublishedAt = [string]$_.registeredAt
            }
        })
        SqlPreparedImages = @($artifacts | Where-Object artifactState -eq 'SQL_PREPARED_SEALED' | ForEach-Object {
            [PSCustomObject]@{
                ArtifactId = [string]$_.artifactId; OperatingSystem = [string]$_.operatingSystem.id
                WindowsEdition = [string]$_.operatingSystem.edition; InstallationType = [string]$_.operatingSystem.installationType
                SqlVersion = [string]$_.sql.version; SqlEdition = [string]$_.sql.edition
                SqlBuild = [string]$_.sql.build; PublishedAt = [string]$_.registeredAt
            }
        })
        WindowsBuilds = $windowsItems
        SqlBuilds = $sqlItems
        AcceptanceEnvironments = @($acceptance)
        ActiveLabs = @($activeRuns | ForEach-Object {
            $connectionInfo = $null
            try {
                $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') ([string]$_.runId)) 'connection-info.json'
                if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
                    $connectionInfo = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
                }
            }
            catch { }
            [PSCustomObject]@{
                RunId = [string]$_.runId; Name = [string]$_.metadata.name; State = [string]$_.state
                Instances = @($connectionInfo.instances | ForEach-Object {
                    [PSCustomObject]@{
                        Id = [string]$_.id; Provider = [string]$_.provider; Host = [string]$_.host
                        Port = $_.port; SqlVersion = [string]$_.sqlVersion
                    }
                })
            }
        })
    }
}
