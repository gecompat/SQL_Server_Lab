#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
Write-Host ''
Write-Host 'SQL_Server_Lab - Container Autostart Checks' -ForegroundColor Cyan

$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$manifest = [PSCustomObject]@{
    name = 'autostart-contract'
    instances = @([PSCustomObject]@{
        id = 'primary'; version = '2025'; provider = 'docker'; autostart = 'on'
        os = 'linux'; profile = 'compact'; collation = $null; databases = @(); drives = @()
        serverConfig = $null; software = @(); postProvision = @(); hyperv = $null
    })
    persistentData = $null; resourceOverrides = $null; automation = $null; expertActions = $null
}
$resolved = & $module { param($value) Resolve-ManifestDefaults -Manifest $value } $manifest
Add-CheckResult -Name 'Providerneutraler Manifestwert wird aufgelöst' -Success (
    $resolved.instances[0].autostart -eq 'on'
)

$aliasManifest = [PSCustomObject]@{
    name = 'autostart-alias'
    instances = @([PSCustomObject]@{
        id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'; profile = 'compact'
        collation = $null; databases = @(); drives = @(); serverConfig = $null; software = @(); postProvision = @()
        hyperv = [PSCustomObject]@{ preparedImageId = $null; autostart = 'on' }
    })
    persistentData = $null; resourceOverrides = $null; automation = $null; expertActions = $null
}
$resolvedAlias = & $module { param($value) Resolve-ManifestDefaults -Manifest $value } $aliasManifest
Add-CheckResult -Name 'Hyper-V-Alias bleibt kompatibel' -Success (
    $resolvedAlias.instances[0].autostart -eq 'on' -and $resolvedAlias.instances[0].hyperv.autostart -eq 'on'
)

$conflict = [ordered]@{
    name = 'autostart-conflict'
    instances = @([ordered]@{
        id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'; autostart = 'on'
        hyperv = [ordered]@{ autostart = 'off' }
    })
}
$conflictResult = Test-SqlServerLabManifest -InputObject $conflict
Add-CheckResult -Name 'Widersprüchliche Aliaswerte werden abgelehnt' -Success (
    -not $conflictResult.IsValid -and $conflictResult.Errors -match 'widersprechen'
) -Message ($conflictResult.Errors -join '; ')

$docker = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
$podman = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
$coordinator = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerAutoStart.ps1') -Raw -Encoding utf8
$newLab = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$cms = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1') -Raw -Encoding utf8
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1') -Raw -Encoding utf8
$html = Get-Content -LiteralPath (Join-Path $repoRoot 'Ui/index.html') -Raw -Encoding utf8
$javascript = Get-Content -LiteralPath (Join-Path $repoRoot 'Ui/app.js') -Raw -Encoding utf8

Add-CheckResult -Name 'Docker und Podman setzen Restart-Policy und Autostart-Label' -Success (
    $docker -match "--restart', 'unless-stopped" -and $docker -match 'sql-server-lab\.autostart=\$AutoStart' -and
    $podman -match "--restart', 'unless-stopped" -and $podman -match 'sql-server-lab\.autostart=\$AutoStart'
)
Add-CheckResult -Name 'Hostkoordinator deckt Windows und natives Podman/Linux ab' -Success (
    $coordinator -match 'Register-ScheduledTask' -and $coordinator -match 'machine start' -and
    $coordinator -match 'podman-restart\.service' -and $coordinator -match 'enable-linger' -and
    $coordinator -match 'is-enabled docker\.service' -and $coordinator -match 'label=sql-server-lab\.autostart=on' -and
    $coordinator -match 'Test-LabWindowsContainerAutoStartTaskReusable'
)
Add-CheckResult -Name 'Paralleler Windows-Autostart besitzt Erkennung, Receipt und Recovery' -Success (
    $coordinator -match 'Get-LabWindowsContainerDesktopPath' -and
    $coordinator -match 'Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes' -and
    $coordinator -match 'windows-podman-desktop-autostart\.json' -and
    $coordinator -match 'Restore-LabWindowsPodmanDesktopAutoStart' -and
    $coordinator -match 'PODMAN_DESKTOP_ENTRY_UNRECOGNIZED'
)

$generatedScriptRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-autostart-contract-$([guid]::NewGuid().ToString('N'))"
try {
    $generatedEvidence = & $module {
        param($root)
        $null = New-Item -Path $root -ItemType Directory -Force
        $podmanOnlyPath = Join-Path $root 'podman-only.ps1'
        $parallelPath = Join-Path $root 'parallel.ps1'
        New-LabWindowsContainerAutoStartScript -Provider podman -RuntimePath 'C:\Program Files\RedHat\Podman\podman.exe' -Path $podmanOnlyPath
        New-LabWindowsContainerAutoStartScript -Provider podman -RuntimePath 'C:\Program Files\RedHat\Podman\podman.exe' -Path $parallelPath `
            -ParallelDockerRuntimePath 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' `
            -ParallelDockerDesktopPath 'C:\Program Files\Docker\Docker\Docker Desktop.exe' `
            -ManagedPodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'

        $podmanOnly = Get-Content -LiteralPath $podmanOnlyPath -Raw -Encoding utf8
        $parallel = Get-Content -LiteralPath $parallelPath -Raw -Encoding utf8
        $podmanOnlyErrors = $null
        $parallelErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($podmanOnlyPath, [ref]$null, [ref]$podmanOnlyErrors)
        $null = [System.Management.Automation.Language.Parser]::ParseFile($parallelPath, [ref]$null, [ref]$parallelErrors)
        [PSCustomObject]@{
            PodmanOnly = $podmanOnly
            Parallel = $parallel
            PodmanOnlyParseErrors = @($podmanOnlyErrors).Count
            ParallelParseErrors = @($parallelErrors).Count
            RecognizedQuotedEntry = Test-LabWindowsPodmanDesktopAutoStartValue `
                -Value '"C:\Program Files\Podman Desktop\Podman Desktop.exe" --hidden' `
                -PodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'
            RejectsForeignEntry = -not (Test-LabWindowsPodmanDesktopAutoStartValue `
                -Value '"C:\Tools\unexpected.exe"' `
                -PodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe')
            RejectsSpoofedExpectedPath = -not (Test-LabWindowsPodmanDesktopAutoStartValue `
                -Value '"C:\Tools\unexpected.exe"' `
                -PodmanDesktopPath 'C:\Tools\unexpected.exe')
        }
    } $generatedScriptRoot

    Add-CheckResult -Name 'Ein-Provider-Podman-Skript startet ohne Docker-Abhängigkeit' -Success (
        $generatedEvidence.PodmanOnly -match '\$runtime machine start' -and
        $generatedEvidence.PodmanOnly -notmatch '\$dockerRuntime' -and
        $generatedEvidence.PodmanOnlyParseErrors -eq 0
    )

    $dockerReadyIndex = $generatedEvidence.Parallel.IndexOf('$dockerRuntime info', [StringComparison]::Ordinal)
    $podmanStartIndex = $generatedEvidence.Parallel.IndexOf('$runtime machine start', [StringComparison]::Ordinal)
    $runtimeReadyIndex = $generatedEvidence.Parallel.IndexOf('if (-not $runtimeReady)', [StringComparison]::Ordinal)
    $podmanDesktopIndex = $generatedEvidence.Parallel.IndexOf("Start-Process -FilePath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'", [StringComparison]::Ordinal)
    $containerStartIndex = $generatedEvidence.Parallel.IndexOf('$containerIds =', [StringComparison]::Ordinal)
    Add-CheckResult -Name 'Zwei-Provider-Skript startet Docker, dann Podman und danach Podman Desktop' -Success (
        $dockerReadyIndex -ge 0 -and $podmanStartIndex -gt $dockerReadyIndex -and
        $runtimeReadyIndex -gt $podmanStartIndex -and $podmanDesktopIndex -gt $runtimeReadyIndex -and
        $containerStartIndex -gt $podmanDesktopIndex -and $generatedEvidence.ParallelParseErrors -eq 0
    )
    Add-CheckResult -Name 'Nur der bekannte Podman-Desktop-Loginwert wird übernommen' -Success (
        $generatedEvidence.RecognizedQuotedEntry -and $generatedEvidence.RejectsForeignEntry -and
        $generatedEvidence.RejectsSpoofedExpectedPath
    )
}
finally {
    if (Test-Path -LiteralPath $generatedScriptRoot -PathType Container) {
        Remove-Item -LiteralPath $generatedScriptRoot -Recurse -Force
    }
}

$testPowerShellPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$testScriptPath = 'C:\Users\test-user\AppData\Local\SQL_Server_Lab\autostart\Start-docker-Labs.ps1'
$testArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$testScriptPath`""
$testCurrentUser = "$([Environment]::MachineName)\test-user"
$validExistingTask = [PSCustomObject]@{
    Actions = @([PSCustomObject]@{ Execute = $testPowerShellPath; Arguments = $testArguments })
    Triggers = @([PSCustomObject]@{ UserId = $testCurrentUser; Enabled = $true })
    Principal = [PSCustomObject]@{ UserId = 'test-user'; LogonType = 'Interactive'; RunLevel = 'Limited' }
}
$existingTaskReusable = & $module {
    param($task, $powerShellPath, $arguments, $currentUser)
    Test-LabWindowsContainerAutoStartTaskReusable -Task $task -PowerShellPath $powerShellPath -Arguments $arguments -CurrentUser $currentUser
} $validExistingTask $testPowerShellPath $testArguments $testCurrentUser
Add-CheckResult -Name 'Gültiger bestehender Windows-Koordinator ist idempotent wiederverwendbar' -Success $existingTaskReusable

$foreignTask = [PSCustomObject]@{
    Actions = $validExistingTask.Actions
    Triggers = $validExistingTask.Triggers
    Principal = [PSCustomObject]@{ UserId = 'other-user'; LogonType = 'Interactive'; RunLevel = 'Limited' }
}
$foreignTaskReusable = & $module {
    param($task, $powerShellPath, $arguments, $currentUser)
    Test-LabWindowsContainerAutoStartTaskReusable -Task $task -PowerShellPath $powerShellPath -Arguments $arguments -CurrentUser $currentUser
} $foreignTask $testPowerShellPath $testArguments $testCurrentUser
Add-CheckResult -Name 'Fremder Windows-Koordinator wird nicht wiederverwendet' -Success (-not $foreignTaskReusable)

$driftedTask = [PSCustomObject]@{
    Actions = @([PSCustomObject]@{ Execute = $testPowerShellPath; Arguments = '-NoProfile -File C:\unexpected.ps1' })
    Triggers = $validExistingTask.Triggers
    Principal = $validExistingTask.Principal
}
$driftedTaskReusable = & $module {
    param($task, $powerShellPath, $arguments, $currentUser)
    Test-LabWindowsContainerAutoStartTaskReusable -Task $task -PowerShellPath $powerShellPath -Arguments $arguments -CurrentUser $currentUser
} $driftedTask $testPowerShellPath $testArguments $testCurrentUser
Add-CheckResult -Name 'Abweichender Windows-Koordinator bleibt fail-closed' -Success (-not $driftedTaskReusable)
Add-CheckResult -Name 'Provisionierung aktiviert den Hostkoordinator nur bei autostart=on' -Success (
    $newLab -match "instance\.autostart -eq 'on'" -and $newLab -match 'Enable-LabContainerHostAutoStart'
)
Add-CheckResult -Name 'CMS wird immer mit Autostart erstellt' -Success (
    $cms -match "New-SqlServerLab.*-AutoStart on" -and $cms -match "AutoStart = 'on'"
)
Add-CheckResult -Name 'Workflow und UI reichen Container-Autostart durch' -Success (
    $workflow -match 'New-SqlServerLab.*-AutoStart \$AutoStart' -and $workflow -match 'autostart = \$AutoStart' -and
    $html -match 'id="container-autostart"' -and $javascript -match "container-autostart'\)\.checked"
)

$receiptTestRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-autostart-receipt-$([guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -Path $receiptTestRoot -ItemType Directory -Force
    $receiptEvidence = & $module {
        param($receiptPath)
        $script:containerAutoStartTestReceiptPath = $receiptPath
        $script:containerAutoStartTestRunValue = '"C:\Program Files\Podman Desktop\Podman Desktop.exe" --hidden'

        function script:Get-LabWindowsContainerAutoStartReceiptPath {
            return $script:containerAutoStartTestReceiptPath
        }
        function script:Get-ItemProperty {
            [CmdletBinding()]
            param([string]$LiteralPath)
            $item = [PSCustomObject]@{}
            if ($null -ne $script:containerAutoStartTestRunValue) {
                $item | Add-Member -NotePropertyName 'io.podman_desktop.PodmanDesktop' -NotePropertyValue $script:containerAutoStartTestRunValue
            }
            return $item
        }
        function script:Remove-ItemProperty {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Name)
            $script:containerAutoStartTestRunValue = $null
        }
        function script:New-Item {
            [CmdletBinding()]
            param([string]$Path, [switch]$Force)
            return [PSCustomObject]@{ Path=$Path }
        }
        function script:Set-ItemProperty {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Name, [string]$Value, [string]$Type)
            $script:containerAutoStartTestRunValue = $Value
        }

        $first = Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes `
            -PodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'
        $suppressed = ($null -eq $script:containerAutoStartTestRunValue) -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)
        $second = Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes `
            -PodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'
        Restore-LabWindowsPodmanDesktopAutoStart
        $restoredValue = [string]$script:containerAutoStartTestRunValue
        $receiptRemoved = -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)

        $script:containerAutoStartTestRunValue = '"C:\Tools\unexpected.exe"'
        $foreignError = $null
        try {
            $null = Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes `
                -PodmanDesktopPath 'C:\Program Files\Podman Desktop\Podman Desktop.exe'
        }
        catch { $foreignError = $_.Exception.Message }

        [PSCustomObject]@{
            FirstChanged = [bool]$first.Changed
            FirstManaged = [bool]$first.Managed
            Suppressed = $suppressed
            SecondChanged = [bool]$second.Changed
            SecondManaged = [bool]$second.Managed
            RestoredValue = $restoredValue
            ReceiptRemoved = $receiptRemoved
            ForeignError = $foreignError
            ForeignValue = [string]$script:containerAutoStartTestRunValue
        }
    } (Join-Path $receiptTestRoot 'receipt.json')

    Add-CheckResult -Name 'Podman-Desktop-Loginübernahme ist idempotent und reversibel' -Success (
        $receiptEvidence.FirstChanged -and $receiptEvidence.FirstManaged -and $receiptEvidence.Suppressed -and
        -not $receiptEvidence.SecondChanged -and $receiptEvidence.SecondManaged -and
        $receiptEvidence.RestoredValue -eq '"C:\Program Files\Podman Desktop\Podman Desktop.exe" --hidden' -and
        $receiptEvidence.ReceiptRemoved
    )
    Add-CheckResult -Name 'Fremder Podman-Desktop-Loginwert bleibt unverändert' -Success (
        $receiptEvidence.ForeignError -match 'PODMAN_DESKTOP_ENTRY_UNRECOGNIZED' -and
        $receiptEvidence.ForeignValue -eq '"C:\Tools\unexpected.exe"'
    )
}
finally {
    if (Test-Path -LiteralPath $receiptTestRoot -PathType Container) {
        Remove-Item -LiteralPath $receiptTestRoot -Recurse -Force
    }
}

Remove-Module $module -Force
if ($failures.Count -gt 0) {
    Write-Host "Container Autostart Checks: FAIL ($($failures.Count))" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Container Autostart Checks: PASS ($passed)" -ForegroundColor Green
