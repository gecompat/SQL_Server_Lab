#Requires -Version 7.2
<#
.SYNOPSIS
    Stellt die Laufzeitbereitschaft registrierter Windows-Testumgebungen wieder her.
.DESCRIPTION
    Liest ausschließlich Windows-Ziele aus dem exportierten Testumgebungsvertrag,
    prüft deren gebundene Hyper-V-Identität und startet bei explizitem -Recover
    eine ausgeschaltete VM sowie vorhandene SQL-Engine-Dienste. Die geschützte
    Testgruppe wird weder neu provisioniert noch gelöscht. Geheimnisse werden nur
    im Framework-Secret-Store gelesen und nicht ausgegeben.
#>
[CmdletBinding()]
param(
    [string]$ContractPath = $env:SQL_SERVER_LAB_TEST_ENV_FILE,
    [string]$SchemaPath = $env:SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE,
    [string]$StateRoot,
    [switch]$Recover,
    [ValidateRange(10, 600)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ContractPath) { $ContractPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_FILE', 'User') }
if (-not $SchemaPath) { $SchemaPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE', 'User') }
if (-not $ContractPath) {
    $dataRoot = if ($env:SQL_SERVER_LAB_DATA_ROOT) {
        $env:SQL_SERVER_LAB_DATA_ROOT
    }
    else {
        [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    }
    if ($dataRoot) { $ContractPath = Join-Path $dataRoot 'Exports/TestUmgebung.json' }
}
if (-not $ContractPath) { throw 'TEST_ENVIRONMENT_CONTRACT_NOT_CONFIGURED' }
$ContractPath = (Resolve-Path -LiteralPath $ContractPath -ErrorAction Stop).Path
if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $ContractPath) 'TestUmgebung.schema.json' }
$SchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).Path

$raw = Get-Content -LiteralPath $ContractPath -Raw -Encoding utf8
if (-not ($raw | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) { throw 'TEST_ENVIRONMENT_SCHEMA_INVALID' }
$contract = $raw | ConvertFrom-Json -Depth 20
$windowsEnvironments = @($contract.environments | Where-Object { [string]$_.platform -eq 'windows' })
if ($windowsEnvironments.Count -eq 0) { throw 'TEST_ENVIRONMENT_WINDOWS_TARGETS_NOT_FOUND' }

$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$results = [Collections.Generic.List[object]]::new()
foreach ($environment in $windowsEnvironments) {
    if (-not $environment.runId -or -not $environment.host -or -not $environment.port) {
        throw "TEST_ENVIRONMENT_WINDOWS_BINDING_INCOMPLETE: $($environment.key)"
    }

    Write-Host "Pruefe geschuetzte Windows-Testumgebung $($environment.key)." -ForegroundColor Cyan
    $result = & $module {
        param($RunId,$RequestedStateRoot,$FallbackAddress,$AllowRecovery)

        $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $RequestedStateRoot
        $status = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
        if (-not $status.Exists) { throw "TEST_ENVIRONMENT_HYPERV_VM_NOT_FOUND: $RunId" }
        $previousState = [string]$status.State
        $vmStarted = $false
        if ($previousState -ne 'Running') {
            if (-not $AllowRecovery) { throw "TEST_ENVIRONMENT_HYPERV_VM_NOT_RUNNING: $RunId ($previousState)" }
            $null = Start-HyperVLabEnvironment -RunId $RunId -StateRoot $RequestedStateRoot
            $vmStarted = $true
            $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $RequestedStateRoot
        }

        $guestPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
        if (-not $guestPassword) { throw "TEST_ENVIRONMENT_GUEST_SECRET_NOT_FOUND: $RunId" }
        $credential = [PSCredential]::new('Administrator', $guestPassword)
        $guestReceipt = Invoke-HyperVPowerShellDirect `
            -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) `
            -ExpectedScopeId ([string]$lab.Run.scopeId) `
            -Credential $credential `
            -FallbackAddress $FallbackAddress `
            -ArgumentList @([bool]$AllowRecovery) `
            -ScriptBlock {
                param($AllowRecovery)
                $instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                if (-not (Test-Path -LiteralPath $instanceRoot)) { throw 'TEST_ENVIRONMENT_SQL_INSTANCE_REGISTRY_NOT_FOUND' }
                $instanceMap = Get-ItemProperty -LiteralPath $instanceRoot -ErrorAction Stop
                $services = @($instanceMap.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    if ([string]$_.Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + [string]$_.Name }
                } | Sort-Object -Unique)
                if ($services.Count -eq 0) { throw 'TEST_ENVIRONMENT_SQL_ENGINE_SERVICE_NOT_FOUND' }
                $started = @()
                foreach ($serviceName in $services) {
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
                    if ([string]$service.Status -ne 'Running') {
                        if (-not $AllowRecovery) { throw "TEST_ENVIRONMENT_SQL_SERVICE_NOT_RUNNING: $serviceName" }
                        Start-Service -Name $serviceName -ErrorAction Stop
                        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(60))
                        $started += $serviceName
                    }
                }
                [PSCustomObject]@{
                    ComputerName = [Environment]::MachineName
                    Services = @($services)
                    StartedServices = @($started)
                }
            }
        $guestReceipt = @($guestReceipt)[-1]
        [PSCustomObject]@{
            RunId = [string]$lab.Run.runId
            VMName = [string]$lab.Instance.vmName
            PreviousState = $previousState
            VMStarted = $vmStarted
            ComputerName = [string]$guestReceipt.ComputerName
            Services = @($guestReceipt.Services)
            StartedServices = @($guestReceipt.StartedServices)
        }
    } ([string]$environment.runId) $StateRoot ([string]$environment.host) ([bool]$Recover)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $reachable = $false
    do {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.ConnectAsync([string]$environment.host, [int]$environment.port)
            $reachable = $connect.Wait(3000) -and $client.Connected
        }
        catch { $reachable = $false }
        finally { $client.Dispose() }
        if (-not $reachable -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Seconds 3 }
    } while (-not $reachable -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if (-not $reachable) { throw "TEST_ENVIRONMENT_SQL_TCP_UNAVAILABLE: $($environment.key)" }

    $results.Add([PSCustomObject]@{
        Key = [string]$environment.key
        RunId = [string]$result.RunId
        VMName = [string]$result.VMName
        PreviousState = [string]$result.PreviousState
        VMStarted = [bool]$result.VMStarted
        SqlServices = @($result.Services).Count
        ServicesStarted = @($result.StartedServices).Count
        TcpStatus = 'READY'
    })
}

$results | Format-Table -AutoSize | Out-Host
Write-Host "WINDOWS-TESTUMGEBUNGEN: $($results.Count) READY" -ForegroundColor Green
