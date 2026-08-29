function Get-LabAutomatedTestEnvironmentWindowsEntries {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
    return @($registry.environments | Where-Object {
        [string]$_.platform -eq 'windows' -and [string]$_.runId
    })
}

function Get-LabAutomatedTestEnvironmentRegisteredEntries {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
    return @($registry.environments | Where-Object { [string]$_.runId } | Sort-Object key)
}

function Get-LabAutomatedTestEnvironmentExpectedMajorVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlVersion)

    switch -Regex ($SqlVersion) {
        '^2019(?:$|-)' { return 15 }
        '^2022(?:$|-)' { return 16 }
        '^2025(?:$|-)' { return 17 }
        default { return 0 }
    }
}

function Get-LabAutomatedTestEnvironmentContainerContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $runId = [string]$Entry.runId
    $run = Get-LabRunState -RunId $runId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $runId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw 'TEST_ENVIRONMENT_CONTAINER_CONNECTION_INFO_MISSING'
    }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object {
        [string]$_.id -eq [string]$Entry.instanceId -and [string]$_.provider -in @('docker','podman')
    })
    if ($instances.Count -ne 1) { throw 'TEST_ENVIRONMENT_CONTAINER_BINDING_INCOMPLETE' }
    return [PSCustomObject]@{
        Run=$run; RunDirectory=$runDirectory; Instance=$instances[0]
    }
}

function ConvertTo-LabTestEnvironmentLifecycleErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord,
        [string[]]$SensitiveValue = @()
    )

    $message = [string]$ErrorRecord.Exception.Message
    foreach ($value in @($SensitiveValue | Where-Object { $_ } | Sort-Object Length -Descending -Unique)) {
        $message = $message.Replace([string]$value, '<redacted>')
    }
    $message = [regex]::Replace($message, '(?i)((?:Password|Pwd)\s*=\s*)[^;\s]+', '$1<redacted>')
    $message = [regex]::Replace($message, '(?i)((?:Server|Data Source)\s*=\s*)[^;\r\n]+', '$1<redacted>')
    return $message
}

function Start-SqlServerLabAutomatedTestEnvironment {
    <#
    .SYNOPSIS
        Stellt alle registrierten Mitglieder der Testgruppe bereit.
    .DESCRIPTION
        Startet die registrierten, scopegebundenen Docker-/Podman-Container und
        Hyper-V-VMs der geschützten automatisierten Testgruppe. Vorhandene SQL-
        Engine-Dienste werden bei Bedarf gestartet und anschließend mit dem im
        Framework-Secret-Store liegenden SA-Kennwort authentifiziert geprüft.
        Runs, Registrierungen, Secrets, Volumes und VHDX-Dateien bleiben erhalten.
        Der kanonische TestUmgebung-Export wird nach dem Gruppenlauf live
        erneuert und bleibt bei jedem Teilfehler fail-closed.
    .PARAMETER Force
        Unterdrückt die zusätzliche Gruppenbestätigung. WhatIf und Confirm
        bleiben über SupportsShouldProcess verfügbar.
    .PARAMETER TimeoutSeconds
        Maximale Wartezeit je Ziel bis zur stabilen SQL-Bereitschaft.
    .PARAMETER OutputDirectory
        Optionales Exportziel. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root.
    .OUTPUTS
        Gruppenstatus mit Start-, Unchanged-, Ready- und Fehlerzählern,
        secretfreien Einzelresultaten und dem erneuerten Exportstatus.
    .EXAMPLE
        Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [switch]$Force,
        [ValidateRange(10, 600)][int]$TimeoutSeconds = 180,
        [string]$OutputDirectory,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registeredEntries = @(Get-LabAutomatedTestEnvironmentRegisteredEntries -OutputDirectory $directory)
    if ($registeredEntries.Count -eq 0) {
        return [PSCustomObject]@{ Status='EMPTY'; Started=0; Unchanged=0; Ready=0; Errors=0; Details=@(); Export=$null }
    }
    if (-not $PSCmdlet.ShouldProcess(
        "$($registeredEntries.Count) registrierte Testumgebung(en)",
        'Docker-/Podman-Container, Hyper-V-VMs und SQL-Dienste als geschützte Gruppe bereitstellen')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Started=0; Unchanged=0; Ready=0; Errors=0; Details=@(); Export=$null }
    }
    if (-not $Force -and -not $PSCmdlet.ShouldContinue(
        'Alle registrierten Mitglieder werden gemeinsam gestartet und bis zur SQL-Bereitschaft geprüft. Fortfahren?',
        'Automatisierte Testumgebungsgruppe bereitstellen')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Started=0; Unchanged=0; Ready=0; Errors=0; Details=@(); Export=$null }
    }

    $details = [Collections.Generic.List[object]]::new()
    $started = 0
    $unchanged = 0
    $ready = 0
    $errors = 0
    $previousGroupOperation = $script:LabAutomatedTestEnvironmentGroupOperation
    $script:LabAutomatedTestEnvironmentGroupOperation = $true
    try {
    foreach ($entry in $registeredEntries) {
        $runId = [string]$entry.runId
        $vmStarted = $false
        $lab = $null
        $instance = $null
        try {
            if ([string]$entry.platform -eq 'linux') {
                $containerContext = Get-LabAutomatedTestEnvironmentContainerContext -Entry $entry -StateRoot $StateRoot
                $instance = $containerContext.Instance
                $beforeState = Get-LabTestEnvironmentLiveRuntimeStatus -Run $containerContext.Run -Instance $instance -StateRoot $StateRoot
                $wasRunning = [string]$beforeState -eq 'RUNNING'
                $startResult = Start-SqlServerLab -RunId $runId -SkipReadyCheck `
                    -TimeoutSeconds $TimeoutSeconds -StateRoot $StateRoot
                if ([string]$startResult.Action -in @('FAILED','CANCELLED')) {
                    throw "TEST_ENVIRONMENT_CONTAINER_START_FAILED: $($startResult.Action)"
                }
                $containerContext = Get-LabAutomatedTestEnvironmentContainerContext -Entry $entry -StateRoot $StateRoot
                $instance = $containerContext.Instance
                $saPassword = Get-LabSecret -Path $containerContext.RunDirectory -Name 'sa-password'
                if (-not $saPassword) { throw 'TEST_ENVIRONMENT_SQL_SA_SECRET_NOT_FOUND' }
                $sqlReadiness = Wait-SqlReady -HostName ([string]$instance.host) -Port ([int]$instance.port) `
                    -SaPassword $saPassword -TimeoutSeconds $TimeoutSeconds `
                    -ExpectedMajorVersion (Get-LabAutomatedTestEnvironmentExpectedMajorVersion -SqlVersion ([string]$entry.sqlVersion)) `
                    -Provider ([string]$instance.provider) -ContainerIdOrName ([string]$instance.containerId)
                if (-not $sqlReadiness.Ready) { throw "TEST_ENVIRONMENT_SQL_NOT_READY: $($sqlReadiness.Message)" }
                $null = Sync-LabRunRuntimeState -Run $containerContext.Run -StateRoot $StateRoot
                if ($wasRunning) { $unchanged++ } else { $started++ }
                $ready++
                $details.Add([PSCustomObject]@{
                    Key=[string]$entry.key; RunId=$runId; Platform='linux'; Provider=[string]$instance.provider
                    Status='READY'; Action=if ($wasRunning) { 'UNCHANGED' } else { 'STARTED' }; Errors=0
                })
                continue
            }
            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $StateRoot
            $instance = @($lab.Connection.instances | Where-Object {
                [string]$_.id -eq [string]$entry.instanceId -and [string]$_.provider -eq 'hyperv'
            } | Select-Object -First 1)[0]
            if (-not $instance -or -not $instance.host -or -not $instance.port) {
                throw 'TEST_ENVIRONMENT_WINDOWS_BINDING_INCOMPLETE'
            }
            $runtime = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
            if (-not $runtime.Exists) { throw 'TEST_ENVIRONMENT_HYPERV_VM_NOT_FOUND' }
            $vmStarted = [string]$runtime.State -ne 'Running'
            if ($vmStarted) {
                $null = Start-HyperVLabEnvironment -RunId $runId -StateRoot $StateRoot
                $started++
            }
            else { $unchanged++ }

            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $StateRoot
            $guestPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
            if (-not $guestPassword) { throw 'TEST_ENVIRONMENT_GUEST_SECRET_NOT_FOUND' }
            $credential = [PSCredential]::new('Administrator', $guestPassword)
            $guestReceipt = Invoke-HyperVPowerShellDirect `
                -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId ([string]$lab.Run.runId) `
                -ExpectedScopeId ([string]$lab.Run.scopeId) `
                -Credential $credential `
                -FallbackAddress ([string]$instance.host) `
                -ScriptBlock {
                    $instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                    if (-not (Test-Path -LiteralPath $instanceRoot)) { throw 'TEST_ENVIRONMENT_SQL_INSTANCE_REGISTRY_NOT_FOUND' }
                    $instanceMap = Get-ItemProperty -LiteralPath $instanceRoot -ErrorAction Stop
                    $services = @($instanceMap.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                        if ([string]$_.Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + [string]$_.Name }
                    } | Sort-Object -Unique)
                    if ($services.Count -eq 0) { throw 'TEST_ENVIRONMENT_SQL_ENGINE_SERVICE_NOT_FOUND' }
                    $startedServices = 0
                    foreach ($serviceName in $services) {
                        $service = Get-Service -Name $serviceName -ErrorAction Stop
                        if ([string]$service.Status -ne 'Running') {
                            Start-Service -Name $serviceName -ErrorAction Stop
                            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(60))
                            $startedServices++
                        }
                    }
                    [PSCustomObject]@{ Services=$services.Count; StartedServices=$startedServices }
                }
            $guestReceipt = @($guestReceipt)[-1]

            $saPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password'
            if (-not $saPassword) { $saPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'sa-password' }
            if (-not $saPassword) { throw 'TEST_ENVIRONMENT_SQL_SA_SECRET_NOT_FOUND' }
            $expectedMajorVersion = if ([string]$entry.sqlVersion -match '^\d{4}$') {
                switch ([string]$entry.sqlVersion) { '2019' { 15 } '2022' { 16 } '2025' { 17 } default { 0 } }
            }
            else { 0 }
            $sqlReadiness = Wait-SqlReady -HostName ([string]$instance.host) -Port ([int]$instance.port) `
                -SaPassword $saPassword -TimeoutSeconds $TimeoutSeconds -ExpectedMajorVersion $expectedMajorVersion
            if (-not $sqlReadiness.Ready) { throw "TEST_ENVIRONMENT_SQL_NOT_READY: $($sqlReadiness.Message)" }

            $null = Sync-LabRunRuntimeState -Run $lab.Run -StateRoot $StateRoot
            $ready++
            $details.Add([PSCustomObject]@{
                Key=[string]$entry.key; RunId=$runId; Platform='windows'; Provider='hyperv'; Status='READY'
                Action=if ($vmStarted) { 'STARTED' } else { 'UNCHANGED' }
                VMStarted=$vmStarted; SqlServices=[int]$guestReceipt.Services
                ServicesStarted=[int]$guestReceipt.StartedServices; Errors=0
            })
        }
        catch {
            $errors++
            $safeMessage = ConvertTo-LabTestEnvironmentLifecycleErrorMessage -ErrorRecord $_ -SensitiveValue @(
                if ($lab) { [string]$lab.RunDirectory; [string]$lab.Instance.vmName }
                if ($instance) { [string]$instance.host; "$([string]$instance.host),$([string]$instance.port)" }
            )
            $details.Add([PSCustomObject]@{
                Key=[string]$entry.key; RunId=$runId; Platform=[string]$entry.platform; Status='FAILED'; Action='PARTIAL'
                VMStarted=$vmStarted; SqlServices=0; ServicesStarted=0; Errors=1
                Message=$safeMessage
            })
            Write-LabError "Testumgebung '$($entry.key)' konnte nicht bereitgestellt werden: $safeMessage"
        }
    }
    }
    finally { $script:LabAutomatedTestEnvironmentGroupOperation = $previousGroupOperation }

    $export = $null
    try {
        $export = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $StateRoot
        $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
    }
    catch {
        $errors++
        $details.Add([PSCustomObject]@{
            Key='GROUP'; RunId=$null; Status='FAILED'; Action='EXPORT'; VMStarted=$false
            SqlServices=0; ServicesStarted=0; Errors=1; Message='TEST_ENVIRONMENT_EXPORT_REFRESH_FAILED'
        })
        Write-LabError 'Testumgebungs-Export konnte nach dem Gruppenstart nicht erneuert werden: TEST_ENVIRONMENT_EXPORT_REFRESH_FAILED'
    }
    $status = if ($errors -eq 0 -and $ready -eq $registeredEntries.Count -and [string]$export.GroupStatus -eq 'READY') { 'READY' } else { 'INCOMPLETE' }
    return [PSCustomObject]@{
        Status=$status; Started=$started; Unchanged=$unchanged; Ready=$ready; Errors=$errors
        Details=@($details); Export=$export
    }
}

function Stop-SqlServerLabAutomatedTestEnvironment {
    <#
    .SYNOPSIS
        Stoppt alle registrierten Mitglieder der Testgruppe.
    .DESCRIPTION
        Stoppt die registrierten, scopegebundenen Docker-/Podman-Container und
        Hyper-V-VMs der geschützten automatisierten Testgruppe. Dadurch wird
        ihre Host-Kapazität freigegeben; Runs, Registrierungen, Secrets,
        Volumes und VHDX-Dateien bleiben erhalten. Der kanonische
        TestUmgebung-Export wird danach live und fail-closed erneuert.
    .PARAMETER Force
        Unterdrückt die zusätzliche Gruppenbestätigung. WhatIf und Confirm
        bleiben über SupportsShouldProcess verfügbar.
    .PARAMETER OutputDirectory
        Optionales Exportziel. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root.
    .OUTPUTS
        Gruppenstatus mit Released-, Unchanged- und Fehlerzählern,
        secretfreien Einzelresultaten und dem erneuerten Exportstatus.
    .EXAMPLE
        Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([switch]$Force, [string]$OutputDirectory, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registeredEntries = @(Get-LabAutomatedTestEnvironmentRegisteredEntries -OutputDirectory $directory)
    if ($registeredEntries.Count -eq 0) {
        return [PSCustomObject]@{ Status='EMPTY'; Released=0; Unchanged=0; Stopped=0; Errors=0; Details=@(); Export=$null }
    }
    if (-not $PSCmdlet.ShouldProcess(
        "$($registeredEntries.Count) registrierte Testumgebung(en)",
        'Docker-/Podman-Container und Hyper-V-VMs als geschützte Gruppe stoppen und Hostkapazität freigeben')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Released=0; Unchanged=0; Stopped=0; Errors=0; Details=@(); Export=$null }
    }
    if (-not $Force -and -not $PSCmdlet.ShouldContinue(
        'Alle registrierten Mitglieder werden gemeinsam gestoppt. Runs, Registrierungen und Daten bleiben erhalten. Fortfahren?',
        'Automatisierte Testumgebungsgruppe stoppen')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Released=0; Unchanged=0; Stopped=0; Errors=0; Details=@(); Export=$null }
    }

    $details = [Collections.Generic.List[object]]::new()
    $released = 0
    $unchanged = 0
    $stopped = 0
    $errors = 0
    $previousGroupOperation = $script:LabAutomatedTestEnvironmentGroupOperation
    $script:LabAutomatedTestEnvironmentGroupOperation = $true
    try {
    foreach ($entry in $registeredEntries) {
        $runId = [string]$entry.runId
        $lab = $null
        try {
            if ([string]$entry.platform -eq 'linux') {
                $containerContext = Get-LabAutomatedTestEnvironmentContainerContext -Entry $entry -StateRoot $StateRoot
                $instance = $containerContext.Instance
                $beforeState = Get-LabTestEnvironmentLiveRuntimeStatus -Run $containerContext.Run -Instance $instance -StateRoot $StateRoot
                $wasRunning = [string]$beforeState -ne 'STOPPED'
                if ($wasRunning) {
                    $stopResult = Stop-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
                    if ([string]$stopResult.Action -in @('FAILED','CANCELLED')) {
                        throw "TEST_ENVIRONMENT_CONTAINER_STOP_FAILED: $($stopResult.Action)"
                    }
                    $released++
                }
                else { $unchanged++ }
                $null = Sync-LabRunRuntimeState -Run $containerContext.Run -StateRoot $StateRoot
                $containerContext = Get-LabAutomatedTestEnvironmentContainerContext -Entry $entry -StateRoot $StateRoot
                $afterState = Get-LabTestEnvironmentLiveRuntimeStatus -Run $containerContext.Run `
                    -Instance $containerContext.Instance -StateRoot $StateRoot
                if ([string]$afterState -ne 'STOPPED') { throw 'TEST_ENVIRONMENT_CONTAINER_STOP_FAILED' }
                $stopped++
                $details.Add([PSCustomObject]@{
                    Key=[string]$entry.key; RunId=$runId; Platform='linux'; Provider=[string]$instance.provider
                    Status='STOPPED'; Action=if ($wasRunning) { 'RELEASED' } else { 'UNCHANGED' }; Errors=0
                })
                continue
            }
            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $StateRoot
            $runtime = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
            if (-not $runtime.Exists) { throw 'TEST_ENVIRONMENT_HYPERV_VM_NOT_FOUND' }
            $wasRunning = [string]$runtime.State -ne 'Off'
            if ($wasRunning) {
                $null = Stop-HyperVLabEnvironment -RunId $runId -StateRoot $StateRoot
                $released++
            }
            else { $unchanged++ }
            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $StateRoot
            $null = Sync-LabRunRuntimeState -Run $lab.Run -StateRoot $StateRoot
            $after = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
            if (-not $after.Exists -or [string]$after.State -ne 'Off') { throw 'TEST_ENVIRONMENT_HYPERV_VM_STOP_FAILED' }
            $stopped++
            $details.Add([PSCustomObject]@{
                Key=[string]$entry.key; RunId=$runId; Platform='windows'; Provider='hyperv'; Status='STOPPED'
                Action=if ($wasRunning) { 'RELEASED' } else { 'UNCHANGED' }; Errors=0
            })
        }
        catch {
            $errors++
            $safeMessage = ConvertTo-LabTestEnvironmentLifecycleErrorMessage -ErrorRecord $_ -SensitiveValue @(
                if ($lab) { [string]$lab.RunDirectory; [string]$lab.Instance.vmName }
            )
            $details.Add([PSCustomObject]@{
                Key=[string]$entry.key; RunId=$runId; Platform=[string]$entry.platform; Status='FAILED'; Action='PARTIAL'
                Errors=1; Message=$safeMessage
            })
            Write-LabError "Testumgebung '$($entry.key)' konnte nicht gestoppt werden: $safeMessage"
        }
    }
    }
    finally { $script:LabAutomatedTestEnvironmentGroupOperation = $previousGroupOperation }

    $export = $null
    try {
        $export = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $StateRoot
        $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
    }
    catch {
        $errors++
        $details.Add([PSCustomObject]@{
            Key='GROUP'; RunId=$null; Status='FAILED'; Action='EXPORT'; Errors=1
            Message='TEST_ENVIRONMENT_EXPORT_REFRESH_FAILED'
        })
        Write-LabError 'Testumgebungs-Export konnte nach dem Gruppenstopp nicht erneuert werden: TEST_ENVIRONMENT_EXPORT_REFRESH_FAILED'
    }
    $status = if ($errors -eq 0 -and $stopped -eq $registeredEntries.Count -and
        [string]$export.GroupStatus -in @('INCOMPLETE','STOPPED')) { 'STOPPED' } else { 'PARTIAL' }
    return [PSCustomObject]@{
        Status=$status; Released=$released; Unchanged=$unchanged; Stopped=$stopped; Errors=$errors
        Details=@($details); Export=$export
    }
}
