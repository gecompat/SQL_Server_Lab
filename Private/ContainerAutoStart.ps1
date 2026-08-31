#Requires -Version 7.2

function ConvertTo-LabPowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    return "'$($Value.Replace("'", "''"))'"
}

function Get-LabContainerAutoStartTaskName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    return "SQL_Server_Lab-$Provider-Autostart"
}

function Get-LabContainerAutoStartScriptPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    if (-not $IsWindows) { return $null }
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SQL_Server_Lab/autostart'
    return Join-Path $root "Start-$Provider-Labs.ps1"
}

function Get-LabWindowsContainerDesktopPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    if (-not $IsWindows) { return $null }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $candidates = if ($Provider -eq 'docker') {
        @(
            (Join-Path $env:ProgramFiles 'Docker/Docker/Docker Desktop.exe'),
            (Join-Path $localAppData 'Docker/Docker Desktop.exe')
        )
    }
    else {
        $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $runItem = Get-ItemProperty -LiteralPath $runPath -ErrorAction SilentlyContinue
        $runProperty = if ($runItem) { $runItem.PSObject.Properties['io.podman_desktop.PodmanDesktop'] } else { $null }
        $runExecutable = if ($runProperty) { Get-LabExecutableFromWindowsRunValue -Value ([string]$runProperty.Value) } else { $null }
        @(
            $runExecutable,
            (Join-Path $env:ProgramFiles 'Podman Desktop/Podman Desktop.exe'),
            (Join-Path $env:ProgramFiles 'RedHat/Podman Desktop/Podman Desktop.exe'),
            (Join-Path $localAppData 'Programs/Podman Desktop/Podman Desktop.exe')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    }

    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Get-LabWindowsContainerAutoStartReceiptPath {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return $null }
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SQL_Server_Lab/autostart'
    return Join-Path $root 'windows-podman-desktop-autostart.json'
}

function Get-LabExecutableFromWindowsRunValue {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    $candidate = [string]$Value
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    $candidate = $candidate.Trim()
    if ($candidate.StartsWith('"')) {
        $closingQuote = $candidate.IndexOf('"', 1)
        if ($closingQuote -le 1) { return $null }
        return $candidate.Substring(1, $closingQuote - 1)
    }
    if ($candidate -match '^(?<Executable>.+?\.exe)(?:\s+.*)?$') {
        return [string]$Matches.Executable
    }
    return $null
}

function Test-LabWindowsPodmanDesktopAutoStartValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$PodmanDesktopPath
    )

    if (-not [string]::Equals([IO.Path]::GetFileName($PodmanDesktopPath), 'Podman Desktop.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $executable = Get-LabExecutableFromWindowsRunValue -Value $Value
    return (
        -not [string]::IsNullOrWhiteSpace($executable) -and
        [string]::Equals([IO.Path]::GetFileName($executable), 'Podman Desktop.exe', [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($executable, $PodmanDesktopPath, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Read-LabWindowsPodmanDesktopAutoStartReceipt {
    [CmdletBinding()]
    param()

    $path = Get-LabWindowsContainerAutoStartReceiptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $receipt = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "LAB_CONTAINER_AUTOSTART_RECEIPT_INVALID: $($_.Exception.Message)"
    }
    if ([int]$receipt.Version -ne 1 -or [string]$receipt.EntryName -ne 'io.podman_desktop.PodmanDesktop' -or
        [string]::IsNullOrWhiteSpace([string]$receipt.Value) -or [string]::IsNullOrWhiteSpace([string]$receipt.DesktopPath)) {
        throw 'LAB_CONTAINER_AUTOSTART_RECEIPT_INVALID: Pflichtfelder fehlen.'
    }
    if (-not (Test-LabWindowsPodmanDesktopAutoStartValue -Value ([string]$receipt.Value) -PodmanDesktopPath ([string]$receipt.DesktopPath))) {
        throw 'LAB_CONTAINER_AUTOSTART_RECEIPT_INVALID: Der gesicherte Login-Eintrag ist nicht an Podman Desktop gebunden.'
    }
    return $receipt
}

function Write-LabWindowsPodmanDesktopAutoStartReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$DesktopPath
    )

    $path = Get-LabWindowsContainerAutoStartReceiptPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }
    $receipt = [ordered]@{
        Version = 1
        EntryName = 'io.podman_desktop.PodmanDesktop'
        Value = $Value
        DesktopPath = $DesktopPath
        SuppressedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $temporaryPath = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $temporaryPath -Value ($receipt | ConvertTo-Json -Depth 5) -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]$receipt
}

function Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PodmanDesktopPath)

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $entryName = 'io.podman_desktop.PodmanDesktop'
    $receipt = Read-LabWindowsPodmanDesktopAutoStartReceipt
    $runItem = Get-ItemProperty -LiteralPath $runPath -ErrorAction SilentlyContinue
    $property = if ($runItem) { $runItem.PSObject.Properties[$entryName] } else { $null }

    if ($receipt) {
        if ($property) {
            if ([string]$property.Value -ne [string]$receipt.Value) {
                throw 'LAB_CONTAINER_AUTOSTART_PODMAN_DESKTOP_ENTRY_DRIFTED: Der verwaltete Login-Eintrag wurde extern geändert.'
            }
            Remove-ItemProperty -LiteralPath $runPath -Name $entryName -ErrorAction Stop
        }
        return [PSCustomObject]@{ Changed=$false; Managed=$true; DesktopPath=[string]$receipt.DesktopPath }
    }

    if (-not $property) {
        return [PSCustomObject]@{ Changed=$false; Managed=$false; DesktopPath=$PodmanDesktopPath }
    }
    if (-not (Test-LabWindowsPodmanDesktopAutoStartValue -Value ([string]$property.Value) -PodmanDesktopPath $PodmanDesktopPath)) {
        throw 'LAB_CONTAINER_AUTOSTART_PODMAN_DESKTOP_ENTRY_UNRECOGNIZED: Der Podman-Desktop-Login-Eintrag wird nicht verändert.'
    }

    $null = Write-LabWindowsPodmanDesktopAutoStartReceipt -Value ([string]$property.Value) -DesktopPath $PodmanDesktopPath
    try {
        Remove-ItemProperty -LiteralPath $runPath -Name $entryName -ErrorAction Stop
    }
    catch {
        $receiptPath = Get-LabWindowsContainerAutoStartReceiptPath
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
        throw "LAB_CONTAINER_AUTOSTART_PODMAN_DESKTOP_SUPPRESSION_FAILED: $($_.Exception.Message)"
    }
    return [PSCustomObject]@{ Changed=$true; Managed=$true; DesktopPath=$PodmanDesktopPath }
}

function Restore-LabWindowsPodmanDesktopAutoStart {
    [CmdletBinding()]
    param()

    $receipt = Read-LabWindowsPodmanDesktopAutoStartReceipt
    if (-not $receipt) { return }

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runItem = Get-ItemProperty -LiteralPath $runPath -ErrorAction SilentlyContinue
    $property = if ($runItem) { $runItem.PSObject.Properties[[string]$receipt.EntryName] } else { $null }
    if ($property -and [string]$property.Value -ne [string]$receipt.Value) {
        Write-Warning 'Der Podman-Desktop-Login-Eintrag wurde extern neu belegt; die SQL_Server_Lab-Sicherung bleibt zur manuellen Wiederherstellung erhalten.'
        return
    }

    if (-not $property) {
        $null = New-Item -Path $runPath -Force
        Set-ItemProperty -LiteralPath $runPath -Name ([string]$receipt.EntryName) -Value ([string]$receipt.Value) -Type String -ErrorAction Stop
    }
    Remove-Item -LiteralPath (Get-LabWindowsContainerAutoStartReceiptPath) -Force -ErrorAction Stop
}

function New-LabWindowsContainerAutoStartScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$Path,
        [string]$ParallelDockerRuntimePath,
        [string]$ParallelDockerDesktopPath,
        [string]$ManagedPodmanDesktopPath
    )

    $runtimeLiteral = ConvertTo-LabPowerShellSingleQuotedLiteral -Value $RuntimePath
    $runtimeBootstrap = if ($Provider -eq 'docker') {
        $desktopPath = Get-LabWindowsContainerDesktopPath -Provider docker
        if ($desktopPath) {
            $desktopLiteral = ConvertTo-LabPowerShellSingleQuotedLiteral -Value $desktopPath
            @"
& `$runtime info 1>`$null 2>`$null
if (`$LASTEXITCODE -ne 0) {
    Start-Process -FilePath $desktopLiteral -WindowStyle Hidden
}
"@
        }
        else { '' }
    }
    else {
        $parallelBootstrap = if (-not [string]::IsNullOrWhiteSpace($ParallelDockerRuntimePath) -and
            -not [string]::IsNullOrWhiteSpace($ParallelDockerDesktopPath)) {
            $dockerRuntimeLiteral = ConvertTo-LabPowerShellSingleQuotedLiteral -Value $ParallelDockerRuntimePath
            $dockerDesktopLiteral = ConvertTo-LabPowerShellSingleQuotedLiteral -Value $ParallelDockerDesktopPath
            @"
# Docker must own its named pipes before the Podman machine is started.
`$dockerRuntime = $dockerRuntimeLiteral
`$dockerDesktop = $dockerDesktopLiteral
if ((Test-Path -LiteralPath `$dockerRuntime -PathType Leaf) -and (Test-Path -LiteralPath `$dockerDesktop -PathType Leaf)) {
    & `$dockerRuntime info 1>`$null 2>`$null
    if (`$LASTEXITCODE -ne 0) {
        Start-Process -FilePath `$dockerDesktop -WindowStyle Hidden
    }
    `$dockerReady = `$false
    `$dockerDeadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        & `$dockerRuntime info 1>`$null 2>`$null
        if (`$LASTEXITCODE -eq 0) { `$dockerReady = `$true; break }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt `$dockerDeadline)
    if (-not `$dockerReady) { exit 2 }
}
"@
        }
        else { '' }
        @"
$parallelBootstrap
& `$runtime machine start 1>`$null 2>`$null
"@
    }

    $desktopBootstrap = if ($Provider -eq 'podman' -and -not [string]::IsNullOrWhiteSpace($ManagedPodmanDesktopPath)) {
        $desktopLiteral = ConvertTo-LabPowerShellSingleQuotedLiteral -Value $ManagedPodmanDesktopPath
        @"
if (Test-Path -LiteralPath $desktopLiteral -PathType Leaf) {
    if (-not (Get-Process -Name 'Podman Desktop' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $desktopLiteral -WindowStyle Hidden
    }
}
"@
    }
    else { '' }

    $content = @"
# Generated by SQL_Server_Lab. Manual changes are overwritten.
# Starts only managed containers carrying sql-server-lab.autostart=on.
#Requires -Version 7.2
`$ErrorActionPreference = 'SilentlyContinue'
`$runtime = $runtimeLiteral
$runtimeBootstrap
`$runtimeReady = `$false
`$deadline = [DateTime]::UtcNow.AddMinutes(3)
do {
    & `$runtime info 1>`$null 2>`$null
    if (`$LASTEXITCODE -eq 0) { `$runtimeReady = `$true; break }
    Start-Sleep -Seconds 3
} while ([DateTime]::UtcNow -lt `$deadline)

if (-not `$runtimeReady) { exit 1 }
$desktopBootstrap
`$containerIds = @(& `$runtime ps -a -q --filter 'label=sql-server-lab.autostart=on' 2>`$null)
foreach (`$containerId in `$containerIds) {
    if (-not [string]::IsNullOrWhiteSpace([string]`$containerId)) {
        & `$runtime start ([string]`$containerId).Trim() 1>`$null 2>`$null
    }
}
"@

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $temporaryPath -Value $content -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-LabWindowsContainerAutoStartIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskUser,
        [Parameter(Mandatory)][string]$CurrentUser
    )

    if ([string]::Equals($TaskUser, $CurrentUser, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $currentParts = @($CurrentUser -split '\\', 2)
    return (
        $TaskUser -notmatch '\\' -and
        $currentParts.Count -eq 2 -and
        [string]::Equals($currentParts[0], [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($TaskUser, $currentParts[1], [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-LabWindowsContainerAutoStartTaskReusable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$CurrentUser
    )

    $actions = @($Task.Actions)
    $triggers = @($Task.Triggers)
    if ($actions.Count -ne 1 -or $triggers.Count -ne 1 -or -not $Task.Principal) { return $false }

    $principalMatches = Test-LabWindowsContainerAutoStartIdentity -TaskUser ([string]$Task.Principal.UserId) -CurrentUser $CurrentUser
    $triggerMatches = Test-LabWindowsContainerAutoStartIdentity -TaskUser ([string]$triggers[0].UserId) -CurrentUser $CurrentUser
    return (
        $principalMatches -and
        $triggerMatches -and
        [string]$Task.Principal.LogonType -eq 'Interactive' -and
        [string]$Task.Principal.RunLevel -eq 'Limited' -and
        $triggers[0].Enabled -ne $false -and
        [string]::Equals([string]$actions[0].Execute, $PowerShellPath, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$actions[0].Arguments, $Arguments, [StringComparison]::Ordinal)
    )
}

function Enable-LabWindowsContainerAutoStartCoordinator {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    $runtimeCommand = Get-Command $Provider -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $runtimeCommand) { throw "LAB_CONTAINER_AUTOSTART_RUNTIME_NOT_FOUND: $Provider" }

    $requiredCommands = @('Get-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet', 'Register-ScheduledTask')
    foreach ($commandName in $requiredCommands) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "LAB_CONTAINER_AUTOSTART_SCHEDULED_TASKS_UNAVAILABLE: $commandName"
        }
    }

    $parallelDockerRuntimePath = $null
    $parallelDockerDesktopPath = $null
    $managedPodmanDesktopPath = $null
    $podmanDesktopMutation = $null
    if ($Provider -eq 'podman') {
        $dockerCommand = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $dockerDesktopPath = Get-LabWindowsContainerDesktopPath -Provider docker
        $podmanDesktopPath = Get-LabWindowsContainerDesktopPath -Provider podman
        if ($dockerCommand -and $dockerDesktopPath) {
            $parallelDockerRuntimePath = [string]$dockerCommand.Source
            $parallelDockerDesktopPath = [string]$dockerDesktopPath
            if ($podmanDesktopPath) {
                $podmanDesktopMutation = Disable-LabWindowsPodmanDesktopAutoStartForParallelRuntimes -PodmanDesktopPath $podmanDesktopPath
                if ($podmanDesktopMutation.Managed) {
                    $managedPodmanDesktopPath = [string]$podmanDesktopMutation.DesktopPath
                }
            }
        }
    }

    $scriptPath = Get-LabContainerAutoStartScriptPath -Provider $Provider
    $pwshPath = (Get-Process -Id $PID).Path
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
    $taskName = Get-LabContainerAutoStartTaskName -Provider $Provider

    try {
        New-LabWindowsContainerAutoStartScript -Provider $Provider -RuntimePath $runtimeCommand.Source -Path $scriptPath `
            -ParallelDockerRuntimePath $parallelDockerRuntimePath -ParallelDockerDesktopPath $parallelDockerDesktopPath `
            -ManagedPodmanDesktopPath $managedPodmanDesktopPath
    }
    catch {
        if ($podmanDesktopMutation -and $podmanDesktopMutation.Changed) {
            try { Restore-LabWindowsPodmanDesktopAutoStart }
            catch { Write-Warning "Podman-Desktop-Autostart konnte nach dem Koordinatorfehler nicht wiederhergestellt werden: $($_.Exception.Message)" }
        }
        throw "LAB_CONTAINER_AUTOSTART_SCRIPT_GENERATION_FAILED: $($_.Exception.Message)"
    }

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask -and (Test-LabWindowsContainerAutoStartTaskReusable -Task $existingTask -PowerShellPath $pwshPath -Arguments $taskArguments -CurrentUser $currentUser)) {
        return [PSCustomObject]@{ Provider=$Provider; Mode='WindowsLogonTask'; Name=$taskName; ScriptPath=$scriptPath; ParallelRuntimes=[bool]$parallelDockerRuntimePath; PodmanDesktopAutoStartManaged=[bool]$managedPodmanDesktopPath }
    }

    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $taskArguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -MultipleInstances IgnoreNew

    try {
        $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Startet SQL_Server_Lab-$Provider-Instanzen mit autostart=on nach der Benutzeranmeldung." -Force -ErrorAction Stop
    }
    catch {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask -and (Test-LabWindowsContainerAutoStartTaskReusable -Task $existingTask -PowerShellPath $pwshPath -Arguments $taskArguments -CurrentUser $currentUser)) {
            return [PSCustomObject]@{ Provider=$Provider; Mode='WindowsLogonTask'; Name=$taskName; ScriptPath=$scriptPath; ParallelRuntimes=[bool]$parallelDockerRuntimePath; PodmanDesktopAutoStartManaged=[bool]$managedPodmanDesktopPath }
        }
        if ($podmanDesktopMutation -and $podmanDesktopMutation.Changed) {
            try { Restore-LabWindowsPodmanDesktopAutoStart }
            catch { Write-Warning "Podman-Desktop-Autostart konnte nach dem Koordinatorfehler nicht wiederhergestellt werden: $($_.Exception.Message)" }
        }
        throw "LAB_CONTAINER_AUTOSTART_TASK_REGISTRATION_FAILED: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{ Provider=$Provider; Mode='WindowsLogonTask'; Name=$taskName; ScriptPath=$scriptPath; ParallelRuntimes=[bool]$parallelDockerRuntimePath; PodmanDesktopAutoStartManaged=[bool]$managedPodmanDesktopPath }
}

function Enable-LabContainerHostAutoStart {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    if ($IsWindows) {
        $result = Enable-LabWindowsContainerAutoStartCoordinator -Provider $Provider
        if ($Provider -eq 'docker') {
            $podmanTaskName = Get-LabContainerAutoStartTaskName -Provider podman
            $podmanCommand = Get-Command podman -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($podmanCommand -and (Get-ScheduledTask -TaskName $podmanTaskName -ErrorAction SilentlyContinue)) {
                $null = Enable-LabWindowsContainerAutoStartCoordinator -Provider podman
            }
        }
        return $result
    }

    if ($Provider -eq 'podman' -and $IsLinux) {
        $systemctl = Get-Command systemctl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $systemctl) { throw 'LAB_PODMAN_AUTOSTART_SYSTEMD_UNAVAILABLE: systemctl fehlt.' }
        $loginctl = Get-Command loginctl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $loginctl) { throw 'LAB_PODMAN_AUTOSTART_LINGER_UNAVAILABLE: loginctl fehlt.' }
        & $loginctl.Source enable-linger ([Environment]::UserName) 1>$null
        if ($LASTEXITCODE -ne 0) { throw 'LAB_PODMAN_AUTOSTART_LINGER_ENABLE_FAILED: systemd-Linger konnte für den aktuellen Benutzer nicht aktiviert werden.' }
        & $systemctl.Source --user enable podman-restart.service 1>$null
        if ($LASTEXITCODE -ne 0) { throw 'LAB_PODMAN_AUTOSTART_SYSTEMD_ENABLE_FAILED: podman-restart.service konnte nicht aktiviert werden.' }
        return [PSCustomObject]@{ Provider = $Provider; Mode = 'PodmanUserSystemdWithLinger'; Name = 'podman-restart.service' }
    }

    if ($Provider -eq 'docker' -and $IsLinux) {
        $systemctl = Get-Command systemctl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $systemctl) { throw 'LAB_DOCKER_AUTOSTART_SYSTEMD_UNAVAILABLE: systemctl fehlt.' }
        & $systemctl.Source is-enabled docker.service 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'LAB_DOCKER_AUTOSTART_DAEMON_DISABLED: docker.service muss beim Boot aktiviert sein.' }
        return [PSCustomObject]@{ Provider = $Provider; Mode = 'DockerSystemdWithRestartPolicy'; Name = 'docker.service' }
    }

    throw "LAB_CONTAINER_AUTOSTART_HOST_UNSUPPORTED: $Provider auf dieser Hostplattform."
}

function Remove-LabContainerAutoStartCoordinatorIfUnused {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider)

    if (-not $IsWindows) { return }
    $ids = @(& $Provider ps -a -q --filter 'label=sql-server-lab.autostart=on' 2>$null | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $ids.Count -gt 0) { return }

    $taskName = Get-LabContainerAutoStartTaskName -Provider $Provider
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $scriptPath = Get-LabContainerAutoStartScriptPath -Provider $Provider
    if ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Remove-Item -LiteralPath $scriptPath -Force
    }
    if ($Provider -eq 'podman') {
        Restore-LabWindowsPodmanDesktopAutoStart
    }
}
