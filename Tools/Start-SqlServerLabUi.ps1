#Requires -Version 7.2
<#
.SYNOPSIS
    Startet die lokale SQL_Server_Lab-Workflow-Oberflaeche.
.DESCRIPTION
    Stellt ausschliesslich auf 127.0.0.1 eine kleine Browser-Oberflaeche bereit.
    Aktionen ohne flüchtige Geheimnisse laufen als persistente Batchvorgänge;
    übrige Aktionen laufen als Thread-Jobs. Die Anzeige liest beide Quellen.
    Annahme bestätigt keinen Start; Statuspolling startet keinen OperationHost.
.PARAMETER Port
    Lauscht auf diesem TCP-Port (Standard: 8484).
.PARAMETER JobStopTimeoutSeconds
    Legt fest, wie lange auf das beendende Herunterfahren offener
    Hintergrundjobs gewartet wird, bevor hart aufgeräumt wird.
.PARAMETER JobLogBurstLimit
    Begrenzt die Anzahl neuer Log-Zeilen, die pro Polling-Schritt in der UI
    angezeigt werden.
.PARAMETER NoBrowser
    Unterdrueckt den automatischen Aufruf von Browser/Startseite.
.PARAMETER ShowHelp
    Zeigt diese Hilfeseite an.
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -Port 8080 -JobStopTimeoutSeconds 10 -JobLogBurstLimit 500
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -NoBrowser
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -ShowHelp
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Port = '8484',
    [Parameter(Position = 1)][string]$JobStopTimeoutSeconds = '5',
    [Parameter(Position = 2)][string]$JobLogBurstLimit = '300',
    [Alias('h', 'help', '?')][switch]$ShowHelp,
    [switch]$NoBrowser,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$extraArgs = @($RemainingArgs)
$helpTokens = @('/?', '-?', '-h', '--help', '-help')
$showHelpRequested = $ShowHelp.IsPresent -or
    $extraArgs -contains '/?' -or
    $extraArgs -contains '-?' -or
    $extraArgs -contains '-h' -or
    $extraArgs -contains '--help' -or
    ($null -ne $Port -and $Port -in $helpTokens) -or
    ($null -ne $JobStopTimeoutSeconds -and $JobStopTimeoutSeconds -in $helpTokens) -or
    ($null -ne $JobLogBurstLimit -and $JobLogBurstLimit -in $helpTokens)

function Show-Usage {
param(
    [string]$ScriptName = 'Start-SqlServerLabUi.ps1'
)
    Write-Host "$ScriptName" -ForegroundColor Cyan
    Write-Host 'Funktion:' -ForegroundColor Magenta
    Write-Host '  Startet die lokale Workflow-UI fuer SQL_Server_Lab auf 127.0.0.1.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Aufruf:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName [-Port <Int>] [-JobStopTimeoutSeconds <Int>] [-JobLogBurstLimit <Int>] [-NoBrowser] [-ShowHelp]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameter:' -ForegroundColor Magenta
    Write-Host '  -Port <int>                 Listener-Port (Default: 8484).' -ForegroundColor Cyan
    Write-Host '  -JobStopTimeoutSeconds <int> Timeout beim Stoppen von Jobs (0..300). Default: 5.' -ForegroundColor Cyan
    Write-Host '  -JobLogBurstLimit <int>      Max neue Log-Zeilen pro Poll (1..2000). Default: 300.' -ForegroundColor Cyan
    Write-Host '  -NoBrowser                  Startet keinen Browser automatisch.' -ForegroundColor Cyan
    Write-Host '  -ShowHelp                   Zeigt diese Hilfe.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Beispiele:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName" -ForegroundColor Cyan
    Write-Host '  -> Startet die UI auf Port 8484.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -Port 8080 -JobStopTimeoutSeconds 10" -ForegroundColor Cyan
    Write-Host '  -> Startet auf alternativem Port mit längerem Job-Stop-Timeout.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -NoBrowser" -ForegroundColor Cyan
    Write-Host '  -> Startet die UI ohne automatischen Browseraufruf.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
}

if ($showHelpRequested) {
    Show-Usage -ScriptName (Split-Path -Leaf $PSCommandPath)
    return
}

$parsedPort = 0
if (-not [int]::TryParse([string]$Port, [ref]$parsedPort)) {
    throw 'Parameter Port muss eine Ganzzahl zwischen 1025 und 65535 sein.'
}
if ($parsedPort -lt 1025 -or $parsedPort -gt 65535) {
    throw 'Parameter Port muss im Bereich 1025..65535 liegen.'
}
$Port = $parsedPort

$parsedJobStopTimeoutSeconds = 0
if (-not [int]::TryParse([string]$JobStopTimeoutSeconds, [ref]$parsedJobStopTimeoutSeconds)) {
    throw 'Parameter JobStopTimeoutSeconds muss eine Ganzzahl zwischen 0 und 300 sein.'
}
if ($parsedJobStopTimeoutSeconds -lt 0 -or $parsedJobStopTimeoutSeconds -gt 300) {
    throw 'Parameter JobStopTimeoutSeconds muss im Bereich 0..300 liegen.'
}
$JobStopTimeoutSeconds = $parsedJobStopTimeoutSeconds

$parsedJobLogBurstLimit = 0
if (-not [int]::TryParse([string]$JobLogBurstLimit, [ref]$parsedJobLogBurstLimit)) {
    throw 'Parameter JobLogBurstLimit muss eine Ganzzahl zwischen 1 und 2000 sein.'
}
if ($parsedJobLogBurstLimit -lt 1 -or $parsedJobLogBurstLimit -gt 2000) {
    throw 'Parameter JobLogBurstLimit muss im Bereich 1..2000 liegen.'
}
$JobLogBurstLimit = $parsedJobLogBurstLimit

$ErrorActionPreference = 'Stop'
$uiRoot = Join-Path $PSScriptRoot '..\Ui'
$modulePath = Join-Path $PSScriptRoot '..\SqlServerLab.psd1'
function Import-UiSqlServerLabModule {
    param([Parameter(Mandatory)][string]$ModulePath)
    $expected=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ModulePath) 'SqlServerLab.psm1'))
    $loaded=@(Get-Module SqlServerLab)
    if ($loaded.Count -gt 1 -or ($loaded.Count -eq 1 -and [IO.Path]::GetFullPath($loaded[0].Path) -ne $expected)) { throw 'UI_MODULE_PATH_MISMATCH' }
    # Preserve the exact caller module and its held ownership objects.
    Import-Module $ModulePath 6>$null
}
Import-UiSqlServerLabModule -ModulePath $modulePath
. (Join-Path $PSScriptRoot 'WorkflowUiJobStatus.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiRequestBoundary.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiOperator.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiJsonBody.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiCommandGrants.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiTlsLiveQualification.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiTlsCreation.ps1')
. (Join-Path $PSScriptRoot '..\Private\EnvironmentGroupsBrowserHttp.ps1')

function Get-UiCommandGrantCatalog {
    & (Get-Module SqlServerLab) { Get-LabPublicCommandWebCatalog }
}

function Write-UiCommandGrantFailure {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$ErrorRecord)
    $code=[string]$ErrorRecord.Exception.Message
    $status=switch -CaseSensitive ($code) {
        'UI_COMMAND_REQUEST_INVALID' {400}
        'UI_COMMAND_GRANT_REQUIRED' {403}
        'UI_COMMAND_GRANT_CAPACITY' {429}
        default {$code='UI_COMMAND_UNCONFIRMED';500}
    }
    Write-UiResponse -Context $Context -Body $code -StatusCode $status
}

function Write-UiResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200,
        [switch]$NoStore
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    if ($NoStore) { $Context.Response.Headers['Cache-Control'] = 'no-store' }
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-UiCapabilityConfig {
    $getSecretCommand = Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
    $secretAvailable = $null -ne $getSecretCommand
    [PSCustomObject]@{
        jobLogBurstLimit = $JobLogBurstLimit
        tlsLiveQualificationAvailable = (Test-UiTlsLiveQualificationAvailable)
        tlsAuthenticatedCreationAvailable = (Test-UiTlsLiveQualificationAvailable)
        aiSharedGatewayServiceSecret = [PSCustomObject]@{
            available = $secretAvailable
            reason = if ($secretAvailable) {
                'PowerShell SecretManagement/Get-Secret ist verfügbar. Die ausgewählten Vault-Einträge werden erst beim read-only Preflight geprüft.'
            }
            else {
                'Nicht verfügbar: PowerShell SecretManagement stellt Get-Secret in diesem Hostprozess nicht bereit.'
            }
        }
    }
}

function Get-UiJobSnapshot {
    param([Parameter(Mandatory)]$Record)

    $output = @()
    try {
        # Die UI-Meldungen sind Information-Records, damit sie nicht in der
        # Ergebnisvariable eines langen Fachbefehls verschwinden. Hier werden
        # sie bewusst in den Snapshot aufgenommen.
        $output = @(Receive-Job -Job $Record.Job -Keep -ErrorAction SilentlyContinue 2>&1 6>&1)
    }
    catch { $output = @($_) }
    $lines = @($output | ForEach-Object {
        $line = ($_ | Out-String).Trim()
        if ($line) { $line }
    })
    $burstLimit = [int]$JobLogBurstLimit
    if ($burstLimit -lt 1) { $burstLimit = 1 }
    $observed = [int]$Record.LastObservedLineCount
    if ($observed -lt 0) { $observed = 0 }
    if ($observed -gt $lines.Count) { $observed = 0 }
    $newLines = @()
    if ($lines.Count -gt $observed) {
        $newLines = $lines[$observed..($lines.Count - 1)]
        if ($newLines.Count -gt $burstLimit) {
            $newLines = $newLines[($newLines.Count - $burstLimit)..($newLines.Count - 1)]
        }
    }
    $state = [string]$Record.Job.State
    $startedAt = [datetimeoffset]::Parse(
        [string]$Record.StartedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
    if ($state -eq 'Failed' -and $lines.Count -eq 0 -and $observed -eq 0) {
        $newLines = @('[FEHLER] Hintergrundaktion wurde abgebrochen.')
    }
    if ($observed -lt $lines.Count) {
        $Record.LastObservedLineCount = $lines.Count
        $Record.LastActivityAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    [PSCustomObject]@{
        Id = $Record.Id
        Action = $Record.Action
        State = $state
        StartedAt = $Record.StartedAt
        ElapsedSeconds = [math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - $startedAt).TotalSeconds))
        LastActivityAt = $Record.LastActivityAt
        Lines = $newLines
    }
}

function Start-UiWorkflowJob {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $id = [guid]::NewGuid().ToString('n')
    $job = Start-ThreadJob -Name "sql-lab-ui-$id" -ArgumentList $modulePath, $Action, $Parameters -ScriptBlock {
        param($JobModulePath, $JobAction, $JobParameters)
        $ErrorActionPreference = 'Stop'
        # Die Modul-Lader geben bewusst Information-Records aus. In einem
        # Hintergrundjob würden sie sonst bei jedem Poll im Host-Terminal landen.
        $InformationPreference = 'SilentlyContinue'
        $WarningPreference = 'SilentlyContinue'
        try {
            Import-Module $JobModulePath -Force 6>$null
            # Thread-Jobs teilen sich den Host mit der UI. Die zentralen
            # Lab-Ausgaben werden deshalb in Job-Pipeline-Records umgeleitet,
            # nicht in das Terminal des UI-Servers geschrieben.
            $global:SqlServerLabUiCaptureOutput = $true
            $invokeParameters = @{}
            foreach ($key in $JobParameters.Keys) { $invokeParameters[$key] = $JobParameters[$key] }
            if ($invokeParameters.ContainsKey('GuestPassword')) {
                $plainPassword = [string]$invokeParameters['GuestPassword']
                $invokeParameters.Remove('GuestPassword')
                $invokeParameters['GuestPassword'] = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
            }
            if ($invokeParameters.ContainsKey('SaPassword')) {
                $plainPassword = [string]$invokeParameters['SaPassword']
                $invokeParameters.Remove('SaPassword')
                $invokeParameters['SaPassword'] = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
            }
            Write-Output "[START] $JobAction"
            $result = Invoke-SqlServerLabWorkflowAction -Action $JobAction @invokeParameters
            if ($JobAction -eq 'ReadFullMaintenancePreview') {
                & (Get-Module SqlServerLab) { param($View) Format-LabFullMaintenancePreview -View $View } $result.Result
            }
            if ($JobAction -ceq 'ReadHyperVEvaluationSqlSource') {
                $source = $result.Result
                Write-Output ('[INVENTAR] SQL-Quellzähler: ' + $source.Status)
                foreach ($item in $source.Items) { Write-Output ('[INVENTAR] {0}: {1}' -f $item.Category, $item.Count) }
                $allocated = $source.AllocatedFileStorage
                if ($allocated.Status -ceq 'OBSERVED') {
                    Write-Output ('[INVENTAR] SQL-Quelldateigrößen laut Katalog · Daten: {0} Bytes · Log: {1} Bytes' -f $allocated.DataBytes,$allocated.LogBytes)
                    Write-Output '[INFO] Nur reguläre Benutzerdatenbanken. Zielbedarf und Backupgröße bleiben offen.'
                } else { Write-Output '[INVENTAR] SQL-Quelldateigrößen konnten nicht bestimmt werden.' }
                foreach ($finding in $source.DependencyFindings) {
                    Write-Output ('[INVENTAR] Vor Übernahme prüfen: {0} · {1} ({2})' -f $finding.Code, $finding.Category, $finding.Count)
                }
                Write-Output '[INFO] Der Ersatzentscheid bleibt BLOCKED. Vollständige Inventur und Transfer benötigen weitere Nachweise.'
            }
            if ($JobAction -ceq 'ReadHyperVEvaluationWindowsLicense') {
                $license = $result.Result
                if ($license.PSObject.Properties['TargetRunId']) {
                    Write-Output ('[LIZENZ] Ziellab {0} / {1}' -f $license.TargetRunId, $license.TargetInstanceId)
                    $license = $license.WindowsLicenseObservation
                }
                Write-Output ('[LIZENZ] Windows: {0} · Lizenz: {1} · Beobachtet UTC: {2} · Frist UTC: {3}' -f
                    $license.Status, $license.LicenseState, $license.ObservedAt, $license.EvaluationExpiresAt)
            }
            if ($JobAction -ceq 'ReadHyperVEvaluationTargetSqlReadiness') {
                $target = $result.Result
                Write-Output ('[INFO] SQL-Bereitschaft im Ziellab {0} / {1}: {2} · Beobachtet UTC: {3}' -f
                    $target.TargetRunId, $target.TargetInstanceId, $target.SqlReadinessObservation.Status, $target.SqlReadinessObservation.ObservedAt)
                $edition = $target.SqlEditionObservation
                Write-Output ('[INFO] SQL-Edition im Ziellab: {0} · {1} · Evaluationsfrist: {2}' -f $edition.Status,$edition.Classification,$edition.EvaluationDeadlineStatus)
                Write-Output '[INFO] Der Ersatzentscheid bleibt BLOCKED. Lizenzgültigkeit, Speicher und Transfer erfordern weitere Nachweise.'
            }
            if ($JobAction -ceq 'ReadHyperVEvaluationTargetStorage') {
                $target = $result.Result
                $storage = $target.StorageObservation
                Write-Output ('[INFO] Freier Gast-Speicher im Ziellab {0} / {1}: {2} · Beobachtet UTC: {3}' -f
                    $target.TargetRunId, $target.TargetInstanceId, $storage.Status, $storage.ObservedAt)
                foreach ($volume in $storage.Volumes) {
                    Write-Output ('[INFO] {0}: {1} Bytes frei' -f ($volume.Roles -join ' / '), $volume.AvailableBytes)
                }
                Write-Output '[INFO] Hostkapazität und erforderlicher Transferspeicher werden separat geprüft.'
            }
            if ($JobAction -eq 'InspectContainerDatabaseMigrationDependencies') {
                $inventory = $result.Result
                $summary = [ordered]@{
                    ContractVersion = [string]$inventory.ContractVersion
                    DatabaseName = [string]$inventory.DatabaseName
                    ObservationStatus = [string]$inventory.ObservationStatus
                    MigrationBoundary = [string]$inventory.MigrationBoundary.ArtifactScope
                    FullInstanceMigration = [bool]$inventory.MigrationBoundary.FullInstanceMigration
                    Dependencies = @($inventory.Dependencies | ForEach-Object {
                        [ordered]@{
                            Category = [string]$_.Category
                            Status = [string]$_.Status
                            Count = if ($null -eq $_.Count) { $null } else { [long]$_.Count }
                            Scope = [string]$_.Scope
                            RequiredAction = [string]$_.RequiredAction
                        }
                    })
                    Warnings = @($inventory.MigrationBoundary.Warnings | ForEach-Object { [string]$_ })
                    Blockers = @($inventory.MigrationBoundary.Blockers | ForEach-Object { [string]$_ })
                    ExecutionPlan = if ($inventory.ExecutionPlan) {
                        [ordered]@{
                            ContractVersion = [string]$inventory.ExecutionPlan.ContractVersion
                            ExecutionStatus = [string]$inventory.ExecutionPlan.ExecutionStatus
                            MutationAllowed = [bool]$inventory.ExecutionPlan.MutationAllowed
                            TransferAuthority = [string]$inventory.ExecutionPlan.TransferAuthority
                            ArtifactScope = [string]$inventory.ExecutionPlan.ArtifactScope
                            Blockers = @($inventory.ExecutionPlan.Blockers | ForEach-Object { [string]$_ })
                            Steps = @($inventory.ExecutionPlan.Steps | ForEach-Object {
                                [ordered]@{
                                    Category = [string]$_.Category
                                    Status = [string]$_.Status
                                    Scope = [string]$_.Scope
                                    RequiredAction = [string]$_.RequiredAction
                                    IncludedInTransfer = [bool]$_.IncludedInTransfer
                                }
                            })
                        }
                    } else { $null }
                }
                Write-Output ('[INVENTAR] ' + ($summary | ConvertTo-Json -Depth 8 -Compress))
            }
            Write-Output '[OK] Aktion erfolgreich abgeschlossen. Die Workflow-Ansicht wird aktualisiert.'
        }
        catch {
            Write-Output "[FEHLER] $($_.Exception.Message)"
            throw
        }
        finally {
            Remove-Variable -Name SqlServerLabUiCaptureOutput -Scope Global -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]@{
        Id = $id; Action = $Action; StartedAt = (Get-Date).ToUniversalTime().ToString('o')
        LastActivityAt = (Get-Date).ToUniversalTime().ToString('o'); LastObservedLineCount = 0; Job = $job
    }
}

function Start-UiPublicCommandJob {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$ParameterSetName,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [switch]$Confirmed
    )

    $id = [guid]::NewGuid().ToString('n')
    $job = Start-ThreadJob -Name "sql-lab-ui-command-$id" -ArgumentList $modulePath, $CommandName, $ParameterSetName, $Parameters, $Confirmed.IsPresent -ScriptBlock {
        param($JobModulePath, $JobCommandName, $JobParameterSetName, $JobParameters, $JobConfirmed)
        $ErrorActionPreference = 'Stop'
        $InformationPreference = 'SilentlyContinue'
        $WarningPreference = 'SilentlyContinue'
        try {
            Import-Module $JobModulePath -Force 6>$null
            $global:SqlServerLabUiCaptureOutput = $true
            Write-Output "[START] $JobCommandName"
            $receipt = & (Get-Module SqlServerLab) {
                param($CommandName, $ParameterSetName, $Parameters, $Confirmed)
                Invoke-LabPublicCommandWebRequest -CommandName $CommandName -ParameterSetName $ParameterSetName -Parameters $Parameters -Confirmed:$Confirmed
            } $JobCommandName $JobParameterSetName $JobParameters $JobConfirmed
            Write-Output ('[ERGEBNIS] ' + ($receipt | ConvertTo-Json -Depth 30 -Compress))
            Write-Output '[OK] Befehl erfolgreich abgeschlossen.'
        }
        catch {
            if ($JobCommandName -ceq 'Get-SqlServerLabCatalog') {
                Write-Output '[FEHLER] LAB_CATALOG_EXPORT_UNCONFIRMED'
                throw 'LAB_CATALOG_EXPORT_UNCONFIRMED'
            }
            if ($JobCommandName -ceq 'Get-SqlServerLabSqlObservabilityEvidence') {
                Write-Output '[FEHLER] SQL_OBSERVABILITY_UNCONFIRMED'
                throw 'SQL_OBSERVABILITY_UNCONFIRMED'
            }
            if ($JobCommandName -ceq 'Backup-SqlServerLabDatabase') {
                Write-Output '[FEHLER] BACKUP_LIBRARY_BROWSER_UNCONFIRMED'
                throw 'BACKUP_LIBRARY_BROWSER_UNCONFIRMED'
            }
            if ($JobCommandName -ceq 'Get-SqlServerLabAiSharedGatewayServicePlan') {
                Write-Output '[FEHLER] AI_SHARED_GATEWAY_GUIDED_SERVICE_PLAN_UNCONFIRMED'
                throw 'AI_SHARED_GATEWAY_GUIDED_SERVICE_PLAN_UNCONFIRMED'
            }
            if ($JobCommandName -cin @('Test-SqlServerLabAiSharedGatewayPreflight','Register-SqlServerLabAiSharedGatewayStorage')) {
                $code = switch -CaseSensitive ($_.Exception.Message) {
                    'AI_SHARED_GATEWAY_GUIDED_PATH_INVALID' { 'AI_SHARED_GATEWAY_GUIDED_PATH_INVALID' }
                    'AI_SHARED_GATEWAY_PLAN_INVALID' { 'AI_SHARED_GATEWAY_PLAN_INVALID' }
                    'AI_SHARED_GATEWAY_STORAGE_CONFLICT' { 'AI_SHARED_GATEWAY_STORAGE_CONFLICT' }
                    'AI_SHARED_GATEWAY_STORAGE_DRIFT' { 'AI_SHARED_GATEWAY_STORAGE_DRIFT' }
                    default {
                        if ($JobCommandName -ceq 'Register-SqlServerLabAiSharedGatewayStorage') {
                            'AI_SHARED_GATEWAY_GUIDED_REGISTRATION_UNCONFIRMED'
                        } else { 'AI_SHARED_GATEWAY_GUIDED_PREFLIGHT_UNCONFIRMED' }
                    }
                }
                Write-Output "[FEHLER] $code"
                throw $code
            }
            Write-Output "[FEHLER] $($_.Exception.Message)"
            throw
        }
        finally {
            Remove-Variable -Name SqlServerLabUiCaptureOutput -Scope Global -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]@{
        Id = $id; Action = "Command: $CommandName"; StartedAt = (Get-Date).ToUniversalTime().ToString('o')
        LastActivityAt = (Get-Date).ToUniversalTime().ToString('o'); LastObservedLineCount = 0; Job = $job
    }
}

# Die Medien- und Image-Erkennung kann große ISOs kurz einbinden und ist damit
# wesentlich teurer als ein Browser-Klick. Sie läuft deshalb separat; der
# HTTP-Listener bleibt für Jobs, Live-Log und weitere Klicks ansprechbar.
$workflowInventory = [PSCustomObject]@{
    Job = $null; Snapshot = $null; MediaRoot = $null; RequestedAt = $null
}

function Update-UiWorkflowInventory {
    if (-not $workflowInventory.Job) { return }
    if ($workflowInventory.Job.State -notin @('Completed', 'Failed', 'Stopped')) { return }
    try {
        if ($workflowInventory.Job.State -eq 'Completed') {
            $snapshot = @(Receive-Job -Job $workflowInventory.Job -ErrorAction Stop)
            if ($snapshot.Count -gt 0) {
                $workflowInventory.Snapshot = $snapshot[-1]
                # Cache a completed result for five seconds even when inventory
                # itself took longer; failed or empty jobs do not renew freshness.
                $workflowInventory.RequestedAt = Get-Date
            }
        }
    }
    finally {
        Remove-Job -Job $workflowInventory.Job -Force -ErrorAction SilentlyContinue
        $workflowInventory.Job = $null
    }
}

function Get-UiWorkflowInventoryResponse {
    param([string]$MediaRoot)

    Update-UiWorkflowInventory
    $normalizedRoot = [string]$MediaRoot
    $requestedAt = if ($workflowInventory.RequestedAt) { [datetime]$workflowInventory.RequestedAt } else { [datetime]::MinValue }
    # Kurz cachen, damit das wiederholte Polling keine ISO-Scans auslöst, aber
    # nach einer Aktion neue Labs und Zustände rasch sichtbar werden.
    $isFresh = $workflowInventory.Snapshot -and $workflowInventory.MediaRoot -eq $normalizedRoot -and ((Get-Date) - $requestedAt).TotalSeconds -lt 5
    if (-not $isFresh -and -not $workflowInventory.Job) {
        $workflowInventory.MediaRoot = $normalizedRoot
        $workflowInventory.RequestedAt = Get-Date
        $workflowInventory.Job = Start-ThreadJob -Name 'sql-lab-ui-workflow-inventory' -ArgumentList $modulePath, $normalizedRoot -ScriptBlock {
            param($JobModulePath, $JobMediaRoot)
            $InformationPreference = 'SilentlyContinue'
            $WarningPreference = 'SilentlyContinue'
            Import-Module $JobModulePath -Force 6>$null
            $snapshot = Get-SqlServerLabWorkflow -MediaRoot $JobMediaRoot
            & (Get-Module SqlServerLab) {
                param($Workflow)
                ConvertTo-LabBrowserWorkflowInventory -Snapshot $Workflow
            } $snapshot
        }
    }
    return [PSCustomObject]@{
        Refreshing = [bool]$workflowInventory.Job
        Snapshot = $workflowInventory.Snapshot
    }
}

if (-not (Test-Path -LiteralPath $uiRoot -PathType Container)) {
    throw "UI_ROOT_NOT_FOUND: $uiRoot"
}

function Invoke-UiCmsInspectionRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    if($Request.HttpMethod -ceq 'GET'){return Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState}
    if($Request.HttpMethod -cne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)'){throw 'CMS_INSPECTION_REQUEST_INVALID'}
    $origin=[string]$Request.Headers['Origin']
    if($origin -and $origin -cne $Request.Url.GetLeftPart([UriPartial]::Authority)){throw 'CMS_INSPECTION_ORIGIN_INVALID'}
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 4096 -LimitErrorCode 'CMS_INSPECTION_REQUEST_INVALID') | ConvertFrom-Json -Depth 5 -ErrorAction Stop
    if($payload -isnot [pscustomobject] -or $payload.action -cne 'InspectCms' -or $payload.parameters -isnot [pscustomobject] -or @($payload.PSObject.Properties.Name|Where-Object {$_ -cnotin @('action','parameters')}).Count -or
        @($payload.parameters.PSObject.Properties).Count -ne 1 -or $payload.parameters.ExpectedPlanKey -isnot [string] -or $payload.parameters.ExpectedPlanKey -cnotmatch '^[a-f0-9]{64}$'){throw 'CMS_INSPECTION_REQUEST_INVALID'}
    Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $payload.parameters.ExpectedPlanKey
}

function Invoke-UiCmsManagementRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    if ($Request.HttpMethod -cne 'GET') { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
    Invoke-SqlServerLabWorkflowAction -Action GetCmsManagementState
}

function Invoke-UiInitialSetupRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)

    if ($Request.HttpMethod -eq 'GET') { return Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'INITIAL_SETUP_REQUEST_INVALID' }
    $origin = [string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'INITIAL_SETUP_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 16384 -LimitErrorCode 'INITIAL_SETUP_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    if (-not $payload -or @($payload.PSObject.Properties.Name | Where-Object { $_ -notin @('action', 'parameters') }).Count) { throw 'INITIAL_SETUP_REQUEST_INVALID' }
    $allowed = switch ([string]$payload.action) {
        'PlanInitialSetup' { @('MediaRoot', 'LabDataRoot', 'DefaultDataRoot') }
        'ApplyInitialSetup' { @('InitialSetupPlan', 'ConfirmSetup') }
        'RefreshSetupProvider' { @('SetupProvider') }
        'PlanSetupWriteability' { @('SetupLocationId') }
        'RefreshSetupCapacity' { @('SetupLocationId') }
        'ProbeSetupWriteability' { @('SetupWriteabilityPlanId', 'ConfirmWriteability') }
        default { throw 'INITIAL_SETUP_ACTION_INVALID' }
    }
    $parameters = @{}
    foreach ($property in @($payload.parameters.PSObject.Properties)) {
        if ($property.Name -notin $allowed) { throw 'INITIAL_SETUP_PARAMETER_INVALID' }
        $parameters[$property.Name] = $property.Value
    }
    if ($payload.action -eq 'ApplyInitialSetup' -and
        ($parameters.ConfirmSetup -isnot [bool] -or -not $parameters.ConfirmSetup)) { throw 'INITIAL_SETUP_CONFIRMATION_REQUIRED' }
    if ($payload.action -in @('PlanSetupWriteability','ProbeSetupWriteability','RefreshSetupCapacity')) {
        $key = if ($payload.action -in @('PlanSetupWriteability','RefreshSetupCapacity')) { 'SetupLocationId' } else { 'SetupWriteabilityPlanId' }
        if ($parameters[$key] -isnot [string] -or $parameters[$key] -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
            if($payload.action -eq 'RefreshSetupCapacity'){throw 'INITIAL_SETUP_CAPACITY_REQUEST_INVALID'}
            throw 'INITIAL_SETUP_PROBE_REQUEST_INVALID'
        }
        if ($payload.action -eq 'ProbeSetupWriteability' -and ($parameters.ConfirmWriteability -isnot [bool] -or -not $parameters.ConfirmWriteability)) { throw 'INITIAL_SETUP_PROBE_CONFIRMATION_REQUIRED' }
    }
    Invoke-SqlServerLabWorkflowAction -Action ([string]$payload.action) @parameters
}

function Invoke-UiSlotReserveRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)

    if ($Request.HttpMethod -eq 'GET') { return Invoke-SqlServerLabWorkflowAction -Action GetSlotReserveState }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'SLOT_RESERVE_REQUEST_INVALID' }
    $origin = [string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'SLOT_RESERVE_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 16384 -LimitErrorCode 'SLOT_RESERVE_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    if (-not $payload -or @($payload.PSObject.Properties.Name | Where-Object { $_ -notin @('action', 'parameters') }).Count) { throw 'SLOT_RESERVE_REQUEST_INVALID' }
    $allowed = switch ([string]$payload.action) {
        'PlanSlotReserve' { @('SlotReservePolicy') }
        'ApplySlotReserve' { @('SlotReservePlan', 'ConfirmSlotReserve') }
        'PlanWindowsPoolMember' { @('RunId','SlotReserveOperation','SlotReserveSqlPlan') }
        'ApplyWindowsPoolMember' { @('SlotReservePreviewId','ConfirmSlotReserveMember') }
        'CancelWindowsPoolMember' { @('SlotReservePreviewId') }
        default { throw 'SLOT_RESERVE_ACTION_INVALID' }
    }
    $parameters = @{}
    foreach ($property in @($payload.parameters.PSObject.Properties)) {
        if ($property.Name -notin $allowed) { throw 'SLOT_RESERVE_PARAMETER_INVALID' }
        $parameters[$property.Name] = $property.Value
    }
    if ($payload.action -eq 'ApplySlotReserve' -and
        ($parameters.ConfirmSlotReserve -isnot [bool] -or -not $parameters.ConfirmSlotReserve)) { throw 'SLOT_RESERVE_CONFIRMATION_REQUIRED' }
    if($payload.action -eq 'ApplyWindowsPoolMember' -and
        ($parameters.ConfirmSlotReserveMember -isnot [bool] -or -not $parameters.ConfirmSlotReserveMember)){throw 'WINDOWS_POOL_CONFIRMATION_REQUIRED'}
    Invoke-SqlServerLabWorkflowAction -Action ([string]$payload.action) @parameters
}

function Invoke-UiResourceWatchRequest {
    param([Parameter(Mandatory)]$Request)
    if ($Request.HttpMethod -eq 'GET') { return Invoke-SqlServerLabWorkflowAction -Action GetResourceWatchState }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'RESOURCE_WATCH_REQUEST_INVALID' }
    $origin = [string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'RESOURCE_WATCH_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 1024 -LimitErrorCode 'RESOURCE_WATCH_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    if ($payload -isnot [pscustomobject] -or @($payload.PSObject.Properties.Name | Where-Object { $_ -notin @('action', 'parameters') }).Count -or
        $payload.action -cne 'RefreshResourceWatch' -or $payload.parameters -isnot [pscustomobject] -or @($payload.parameters.PSObject.Properties).Count) { throw 'RESOURCE_WATCH_REQUEST_INVALID' }
    Invoke-SqlServerLabWorkflowAction -Action RefreshResourceWatch
}
function Invoke-UiLlamaInstallerRequest {
    param([Parameter(Mandatory)]$Request)
    if($Request.HttpMethod -eq 'GET'){return & (Get-Module SqlServerLab) {Get-LabLlamaInstallerView}}
    if($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)'){throw 'LLAMA_INSTALL_REQUEST_INVALID'}
    $origin=[string]$Request.Headers['Origin']
    if($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)){throw 'LLAMA_INSTALL_ORIGIN_INVALID'}
    $body = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 1024 -LimitErrorCode 'LLAMA_INSTALL_REQUEST_LIMIT') | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    if($body -isnot [pscustomobject] -or @($body.PSObject.Properties.Name|Where-Object {$_ -notin @('action','candidateId','rootId','expectedKey','confirmed')}).Count){throw 'LLAMA_INSTALL_REQUEST_INVALID'}
    if($body.action -ceq 'upstream'){
        if(@($body.PSObject.Properties).Count -ne 1){throw 'LLAMA_INSTALL_REQUEST_INVALID'}
        return & (Get-Module SqlServerLab) {Get-LabLlamaInstallerUpstream}
    }
    if($body.candidateId -isnot [string] -or $body.candidateId -cne 'llama-b11247-win-x64-cpu' -or $body.rootId -isnot [string] -or $body.rootId -cnotmatch '^[a-f0-9]{64}$'){throw 'LLAMA_INSTALL_REQUEST_INVALID'}
    if($body.action -ceq 'preview'){return & (Get-Module SqlServerLab) {param($id,$root) ConvertTo-LabLlamaInstallerPlanView (Get-LabLlamaInstallerPlan -CandidateId $id -RootId $root)} $body.candidateId $body.rootId}
    if($body.action -cne 'apply' -or $body.confirmed -isnot [bool] -or -not $body.confirmed -or $body.expectedKey -isnot [string] -or $body.expectedKey -cnotmatch '^[a-f0-9]{64}$'){throw 'LLAMA_INSTALL_CONFIRMATION_REQUIRED'}
    & (Get-Module SqlServerLab) {param($id,$root,$key) Invoke-LabLlamaInstaller -CandidateId $id -RootId $root -ExpectedKey $key -Confirmed} $body.candidateId $body.rootId $body.expectedKey
}

function Invoke-UiLlamaSessionRequest {
    param([Parameter(Mandatory)]$Request)
    if ($Request.HttpMethod -eq 'GET') { return (Invoke-SqlServerLabWorkflowAction -Action GetLlamaSessions).Result }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'LLAMA_SESSION_REQUEST_INVALID' }
    $origin=[string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'LLAMA_SESSION_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 1024 -LimitErrorCode 'LLAMA_SESSION_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    if ($payload -isnot [pscustomobject]) { throw 'LLAMA_SESSION_REQUEST_INVALID' }
    if ($payload.action -ceq 'preview' -and (($payload.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'action,operationId' -and
        $payload.operationId -is [string] -and $payload.operationId -cmatch '^[a-f0-9-]{36}$') {
        return (Invoke-SqlServerLabWorkflowAction -Action PlanLlamaSessionStop -LlamaSessionOperationId $payload.operationId).Result
    }
    if ($payload.action -ceq 'stop' -and (($payload.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'action,confirmed,planId' -and
        $payload.planId -is [string] -and $payload.planId -cmatch '^[a-f0-9-]{36}$' -and $payload.confirmed -is [bool] -and $payload.confirmed) {
        return (Invoke-SqlServerLabWorkflowAction -Action StopLlamaSession -LlamaSessionPlanId $payload.planId -ConfirmLlamaSessionStop).Result
    }
    throw 'LLAMA_SESSION_CONFIRMATION_REQUIRED'
}

function Invoke-UiMaintenanceRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    if ($Request.HttpMethod -eq 'GET') { return & (Get-Module SqlServerLab) { Get-LabMaintenanceGuidanceView } }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'MAINTENANCE_REQUEST_INVALID' }
    $origin=[string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'MAINTENANCE_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 1024 -LimitErrorCode 'MAINTENANCE_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    if ($payload -isnot [pscustomobject] -or @($payload.PSObject.Properties.Name | Where-Object {$_ -notin @('action','candidateId','expectedKey','confirmed')}).Count -or
        $payload.candidateId -isnot [string] -or $payload.candidateId -cnotmatch '^[a-f0-9]{64}$') { throw 'MAINTENANCE_REQUEST_INVALID' }
    if ($payload.action -ceq 'preview') {
        return & (Get-Module SqlServerLab) { param($id) ConvertTo-LabMaintenanceRepairView (Get-LabMaintenanceRepairPlan -CandidateId $id) } $payload.candidateId
    }
    if ($payload.action -cne 'apply' -or $payload.confirmed -isnot [bool] -or -not $payload.confirmed -or
        $payload.expectedKey -isnot [string] -or $payload.expectedKey -cnotmatch '^[a-f0-9]{64}$') { throw 'MAINTENANCE_CONFIRMATION_REQUIRED' }
    & (Get-Module SqlServerLab) { param($id,$key) Invoke-LabMaintenanceRepair -CandidateId $id -ExpectedKey $key -Confirmed } $payload.candidateId $payload.expectedKey
}

function Invoke-UiMediaOverrideRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)

    if ($Request.HttpMethod -eq 'GET') { return Invoke-SqlServerLabWorkflowAction -Action GetMediaOverrideState }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'MEDIA_SOURCE_OVERRIDE_REQUEST_INVALID' }
    $origin = [string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'MEDIA_SOURCE_OVERRIDE_ORIGIN_INVALID' }
    $payload = (Read-UiSpecializedJsonRequestBody -Request $Request -MaxCharacters 16384 -LimitErrorCode 'MEDIA_SOURCE_OVERRIDE_REQUEST_TOO_LARGE') | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    if (-not $payload -or @($payload.PSObject.Properties.Name | Where-Object { $_ -notin @('action', 'parameters') }).Count) { throw 'MEDIA_SOURCE_OVERRIDE_REQUEST_INVALID' }
    $allowed = switch ([string]$payload.action) {
        'PlanMediaOverride' { @('MediaSourceId', 'MediaSourceOperation', 'MediaSourceUrl') }
        'ApplyMediaOverride' { @('MediaSourcePlan', 'ConfirmMediaSource') }
        default { throw 'MEDIA_SOURCE_OVERRIDE_ACTION_INVALID' }
    }
    $parameters = @{}
    foreach ($property in @($payload.parameters.PSObject.Properties)) {
        if ($property.Name -notin $allowed) { throw 'MEDIA_SOURCE_OVERRIDE_PARAMETER_INVALID' }
        $parameters[$property.Name] = $property.Value
    }
    if ($payload.action -eq 'ApplyMediaOverride' -and
        ($parameters.ConfirmMediaSource -isnot [bool] -or -not $parameters.ConfirmMediaSource)) { throw 'MEDIA_SOURCE_OVERRIDE_CONFIRMATION_REQUIRED' }
    Invoke-SqlServerLabWorkflowAction -Action ([string]$payload.action) @parameters
}

$listener = [Net.HttpListener]::new()
$url = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($url)
$operatorSession = New-UiOperatorSession -ListenerUrl $url
$commandGrantStore = $null
$jobs = @{}
$tlsLiveQualificationJobs = @{}
$tlsCreationStore = New-UiTlsCreationStore
$persistentJobs = @{}
$runArtifactRemovalPreviews = @{}
$containerAutoStartRecoverySelections = @{}
$containerAutoStartChangeStore = @{}
$hyperVAutoStartBrowserStore = @{}
$aiSharedGatewayBrowserSessions = @{}

try {
    $commandGrantStore = New-UiCommandGrantStore -Session $operatorSession
    $listener.Start()
    Write-Host "SQL_Server_Lab Workflow UI: $url" -ForegroundColor Green
    Write-Host ('Privater Startlink und HTTP-CLI-Capability: ' + $operatorSession.File) -ForegroundColor DarkGray
    Write-Host 'Für Reload oder einen weiteren Tab den privaten Startlink erneut öffnen; Datei nicht teilen oder protokollieren.' -ForegroundColor DarkGray
    Write-Host 'Zum Beenden Strg+C druecken.' -ForegroundColor DarkGray
    Write-Host "Job-Stop-Timeout beim Beenden: ${JobStopTimeoutSeconds}s (Parameter: -JobStopTimeoutSeconds)." -ForegroundColor DarkGray
    Write-Host "Log-Burst-Limit pro Snapshot: ${JobLogBurstLimit} Zeilen (Parameter: -JobLogBurstLimit)." -ForegroundColor DarkGray
    if (-not $NoBrowser) { Start-Process $operatorSession.StartUrl }
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
        }
        catch {
            if (-not $listener.IsListening) { break }
            if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { break }
            throw
        }
        try {
            if (-not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address)) {
                Write-UiResponse -Context $context -Body 'Nur lokaler Zugriff ist erlaubt.' -StatusCode 403
                continue
            }

            # Gemeinsame Grenze vor jeder Route, Bodylesung und Job-/Batchanlage.
            $requestBoundary = Get-UiRequestBoundaryDecision -Request $context.Request -ListenerUrl $url
            if (-not $requestBoundary.Allowed) {
                Write-UiResponse -Context $context -Body $requestBoundary.Code -StatusCode $requestBoundary.StatusCode
                continue
            }

            $path = $context.Request.Url.AbsolutePath
            $operatorDecision = Get-UiOperatorDecision -Request $context.Request -ListenerUrl $url -Session $operatorSession
            if (-not $operatorDecision.Allowed) {
                Write-UiResponse -Context $context -Body $operatorDecision.Code -StatusCode $operatorDecision.StatusCode
                continue
            }
            if ($path -eq '/api/test-group' -and $context.Request.HttpMethod -eq 'GET') {
                try {
                    $power = [string]$context.Request.QueryString['powerAction']
                    if (-not $power) { $power = 'Start' }
                    $view = & (Get-Module SqlServerLab) { param($a) Get-LabTestGroupPowerPlan -PowerAction $a } $power
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }
                catch { Write-UiResponse -Context $context -Body 'TEST_GROUP_READ_UNAVAILABLE: Gruppe erneut lesen; keine Aktion ausgeführt.' -StatusCode 503 }
                continue
            }
            if ($path -eq '/api/test-group-management' -and $context.Request.HttpMethod -eq 'GET') {
                $query = $context.Request.QueryString
                try {
                    $operation = [string]$query['operation']
                    if ($operation -cnotin @('CreateWindows','Repair','Remove','Export') -or
                        @($query.AllKeys | Where-Object { $_ -cnotin @('operation','artifactId') }).Count -or
                        @($query.GetValues('operation')).Count -ne 1 -or
                        ($query.Count -gt 1 -and ($operation -cne 'CreateWindows' -or @($query.GetValues('artifactId')).Count -ne 1 -or -not $query['artifactId']))) {
                        throw 'TEST_GROUP_MANAGEMENT_REQUEST_INVALID'
                    }
                    $view = & (Get-Module SqlServerLab) { param($op,$id) Get-LabTestGroupManagementPlan -Operation $op -ArtifactId $id } $operation $query['artifactId']
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 6) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body 'TEST_GROUP_MANAGEMENT_PLAN_UNAVAILABLE' -StatusCode 422 }
                continue
            }
            if ($path -eq '/api/test-group-linux-create' -and $context.Request.HttpMethod -eq 'GET') {
                try {
                    $view = & (Get-Module SqlServerLab) { param($query) Invoke-LabTestGroupLinuxCreatePlanRequest -Query $query } $context.Request.QueryString
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4) -ContentType 'application/json; charset=utf-8'
                }
                catch { Write-UiResponse -Context $context -Body 'TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE' -StatusCode 422 }
                continue
            }
            if ($path -eq '/api/run-artifact-removal') {
                try {
                    $view=& (Get-Module SqlServerLab) { param($request,$listenerPort,$previews) Invoke-LabRunArtifactRemovalHttpRequest -Request $request -ListenerPort $listenerPort -Previews $previews } $context.Request $Port $runArtifactRemovalPreviews
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body '{"Code":"RUN_ARTIFACT_HTTP_UNCONFIRMED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 }
                continue
            }
            if ($path -cin @('/api/tls-creation','/api/tls-created-targets/action')) {
                try {
                    if($context.Request.HttpMethod -cne 'POST' -or $context.Request.Url.Query -or
                        [string]$context.Request.Headers['Origin'] -cne $url.TrimEnd('/')){throw 'TLS_CREATION_REQUEST_REJECTED'}
                    $bodyRead=Read-UiJsonRequestBody -Request $context.Request -MaxBytes 4096
                    if(-not $bodyRead.Allowed){throw 'TLS_CREATION_REQUEST_REJECTED'}
                    $view=Start-UiTlsCreationWork -Store $tlsCreationStore -Jobs $jobs -PersistentJobs $persistentJobs -ModulePath $modulePath -Body $bodyRead.Body -TargetAction:($path -ceq '/api/tls-created-targets/action')
                    Write-UiResponse -Context $context -Body ($view|ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                }catch{Write-UiResponse -Context $context -Body '{"Code":"TLS_CREATION_UNCONFIRMED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400}
                finally{$bodyRead=$null}
                continue
            }
            if ($path -ceq '/api/tls-created-targets' -or $path -cmatch '^/api/tls-created-targets/([a-f0-9]{32})$') {
                try {
                    if($context.Request.HttpMethod -cne 'GET' -or $context.Request.Url.Query){throw 'TLS_CREATION_REQUEST_REJECTED'}
                    $view=if($path -ceq '/api/tls-created-targets'){
                        @{Targets=@($tlsCreationStore.Tickets.Keys|ForEach-Object{Get-UiTlsCreationView -Store $tlsCreationStore -Id $_});CreationBlocked=(Test-UiTlsCreationBlocked -Store $tlsCreationStore)}
                    }else{Get-UiTlsCreationView -Store $tlsCreationStore -Id $Matches[1]}
                    Write-UiResponse -Context $context -Body ($view|ConvertTo-Json -Depth 7 -Compress) -ContentType 'application/json; charset=utf-8'
                }catch{Write-UiResponse -Context $context -Body '{"Code":"TLS_CREATION_REQUEST_REJECTED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400}
                continue
            }
            if ($path -eq '/api/tls-live-qualification') {
                if($context.Request.HttpMethod -cne 'POST' -or $context.Request.Url.Query -or
                    [string]$context.Request.Headers['Origin'] -cne $url.TrimEnd('/')){
                    Write-UiResponse -Context $context -Body '{"Code":"TLS_LIVE_HTTP_REJECTED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                    continue
                }
                $bodyRead=Read-UiJsonRequestBody -Request $context.Request -MaxBytes 2048
                if(-not $bodyRead.Allowed){
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                try {
                    $view=Start-UiTlsLiveQualificationJob -Records $tlsLiveQualificationJobs -Jobs $jobs -PersistentJobs $persistentJobs -ModulePath $modulePath -Body $bodyRead.Body
                    Write-UiResponse -Context $context -Body ($view|ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                }catch{Write-UiResponse -Context $context -Body '{"Code":"TLS_LIVE_HTTP_REJECTED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400}
                continue
            }
            if ($path -match '^/api/tls-live-qualification/([a-f0-9]{32})$') {
                try {
                    if($context.Request.HttpMethod -cne 'GET' -or $context.Request.Url.Query){throw 'TLS_LIVE_HTTP_REJECTED'}
                    $view=Get-UiTlsLiveQualificationJob -Records $tlsLiveQualificationJobs -Id $Matches[1]
                    Write-UiResponse -Context $context -Body ($view|ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                }catch{Write-UiResponse -Context $context -Body '{"Code":"TLS_LIVE_HTTP_REJECTED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400}
                continue
            }
            if ($path -ceq '/api/hyperv-autostart') {
                try {
                    $request = $context.Request
                    if ($request.HttpMethod -cne 'POST' -or $request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
                        $request.Url.Query -or [string]$request.Headers['Origin'] -cne $request.Url.GetLeftPart([UriPartial]::Authority)) {
                        throw 'HYPERV_AUTOSTART_BROWSER_INVALID'
                    }
                    $body = Read-UiSpecializedJsonRequestBody -Request $request -MaxCharacters 1024 -LimitErrorCode 'HYPERV_AUTOSTART_BROWSER_INVALID'
                    $view = & (Get-Module SqlServerLab) {
                        param($store, $json) Invoke-LabHyperVAutoStartBrowser -Store $store -Json $json
                    } $hyperVAutoStartBrowserStore $body
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body '{"Code":"HYPERV_AUTOSTART_BROWSER_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -cin @('/api/container-autostart-recovery', '/api/container-autostart-change')) {
                try {
                    $request = $context.Request
                    if ($request.Url.Query) { throw 'AUTOSTART_BROWSER_QUERY_INVALID' }
                    $module = Get-Module SqlServerLab
                    $recovery = $path -ceq '/api/container-autostart-recovery'
                    if ($request.HttpMethod -ceq 'GET' -and -not $request.HasEntityBody) {
                        $view = if ($recovery) {
                            & $module { param($selections) Read-LabContainerAutoStartRecoveryBrowser -Selections $selections } $containerAutoStartRecoverySelections
                        } else {
                            & $module { param($store) Read-LabContainerAutoStartChangeBrowser -Store $store } $containerAutoStartChangeStore
                        }
                    }
                    elseif ($request.HttpMethod -ceq 'POST' -and [string]$request.Headers['Origin'] -ceq $url.TrimEnd('/')) {
                        $body = Read-UiSpecializedJsonRequestBody -Request $request -MaxCharacters 1024 -LimitErrorCode 'AUTOSTART_BROWSER_BODY_LIMIT'
                        $view = if ($recovery) {
                            & $module { param($selections, $body) Invoke-LabContainerAutoStartRecoveryBrowser -Selections $selections -Body $body } $containerAutoStartRecoverySelections $body
                        } else {
                            & $module { param($store, $body) Invoke-LabContainerAutoStartChangeBrowser -Store $store -Body $body } $containerAutoStartChangeStore $body
                        }
                    }
                    else { throw 'AUTOSTART_BROWSER_REQUEST_INVALID' }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body '{"Code":"AUTOSTART_BROWSER_UNCONFIRMED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/container-autostart-preview') {
                try {
                    $view=& (Get-Module SqlServerLab) { param($request,$listenerPort) Invoke-LabContainerAutoStartPreviewHttpRequest -Request $request -ListenerPort $listenerPort } $context.Request $Port
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body '{"Code":"AUTOSTART_HTTP_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/container-port-preview') {
                try {
                    $view=& (Get-Module SqlServerLab) { param($request,$listenerPort) Invoke-LabContainerPortPreviewHttpRequest -Request $request -ListenerPort $listenerPort } $context.Request $Port
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body '{"Code":"PORT_HTTP_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/resource-change' -and $context.Request.HttpMethod -eq 'GET') {
                try {
                    $query = $context.Request.QueryString
                    $arguments = @{ RunId=[string]$query['runId'] }
                    if (-not $arguments.RunId) { throw 'RESOURCE_CHANGE_RUN_REQUIRED' }
                    if ($query['instanceId']) {
                        $arguments.InstanceId = [string]$query['instanceId']; $arguments.Provider = [string]$query['provider']
                        if ($null -ne $query['cpu']) { $arguments.Cpu = [decimal]::Parse($query['cpu'],[Globalization.CultureInfo]::InvariantCulture) }
                        if ($null -ne $query['memoryMB']) { if ($query['memoryMB'] -notmatch '^\d+$') { throw 'RESOURCE_CHANGE_MEMORY_INVALID' }; $arguments.MemoryMB = [int]$query['memoryMB'] }
                        $view = & (Get-Module SqlServerLab) { param($a) Get-LabResourceChangePlan @a } $arguments
                    }
                    else { $view = @{ Targets=@(& (Get-Module SqlServerLab) { param($a) Get-LabResourceChangeTargets @a } $arguments) } }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }
                catch { Write-UiResponse -Context $context -Body 'RESOURCE_CHANGE_UNAVAILABLE: Ziel, Schutzstatus, Runtime und offene Recovery prüfen; anschließend erneut lesen.' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/evaluation-refresh-plan') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request) Invoke-LabEvaluationRefreshHttpRequest -Request $request } $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $code=if($_.Exception.Message -cin @('EVALUATION_REFRESH_HTTP_INVALID','EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_INPUT_INVALID','EVALUATION_REFRESH_MODE_INVALID','EVALUATION_REFRESH_BINDING_UNAVAILABLE',
                        'EVALUATION_REFRESH_TARGET_SELECTION_INVALID','EVALUATION_REFRESH_TARGET_UNAVAILABLE','EVALUATION_REFRESH_TARGET_SCOPE_UNSUPPORTED')){$_.Exception.Message}else{'EVALUATION_REFRESH_BINDING_UNAVAILABLE'}
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/llama-start') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request,$listenerPort) Invoke-LabLlamaCppStartHttpRequest -Request $request -ListenerPort $listenerPort } $context.Request $Port
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 3 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $code=if($_.Exception.Message -cin @('LLAMA_START_HTTP_INVALID','LLAMA_START_HTTP_CONFIRMATION_REQUIRED','LLAMA_START_HTTP_CONFIRM_POLICY_BLOCKED')){$_.Exception.Message}else{'LLAMA_START_HTTP_INVALID'}
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/llama-start-plan') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request) Invoke-LabLlamaCppStartPlanHttpRequest -Request $request } $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $code=if($_.Exception.Message -cin @('LLAMA_START_PLAN_HTTP_INVALID','LLAMA_START_PLAN_HTTP_RESULT_INVALID','LLAMA_START_PLAN_PATH_INVALID','LLAMA_START_PLAN_FILE_INVALID','LLAMA_START_PLAN_REPARSE_REJECTED','LLAMA_START_PLAN_DIRECTORY_LIMIT','LLAMA_START_PLAN_FILE_LIMIT','LLAMA_START_PLAN_GGUF_REQUIRED','LLAMA_START_PLAN_LEASE_INVALID','LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED','LLAMA_START_PLAN_RUNTIME_MISMATCH','LLAMA_START_PLAN_INPUT_DRIFT','LLAMA_START_PLAN_INPUT_UNREADABLE')){$_.Exception.Message}else{'LLAMA_START_PLAN_HTTP_INVALID'}
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/collations/search') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request,$listenerPort) Invoke-LabCollationCatalogHttpRequest -Request $request -ListenerPort $listenerPort } $context.Request $Port
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $invalidResult=$_.Exception.Message -ceq 'COLLATION_HTTP_RESULT_INVALID'
                    $code=if($invalidResult){'COLLATION_HTTP_RESULT_INVALID'}else{'COLLATION_HTTP_INVALID'}
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode $(if($invalidResult){500}else{400})
                }
                continue
            }
            if ($path -eq '/api/external-runtime-capability') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request,$listenerPort) Invoke-LabExternalRuntimeCapabilityHttpRequest -Request $request -ListenerPort $listenerPort } $context.Request $Port
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    Write-UiResponse -Context $context -Body '{"Code":"EXTERNAL_RUNTIME_HTTP_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/host-capability-matrix') {
                try {
                    $result=& (Get-Module SqlServerLab) {param($request,$listenerPort) Invoke-LabHostCapabilityMatrixHttpRequest -Request $request -ListenerPort $listenerPort} $context.Request $Port
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 20 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    Write-UiResponse -Context $context -Body '{"Code":"HOST_MATRIX_HTTP_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/component-relations') {
                try {
                    $result=& (Get-Module SqlServerLab) { param($request) Invoke-LabComponentRelationHttpRequest -Request $request } $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $code=if($_.Exception.Message -cin @('COMPONENT_RELATION_HTTP_INVALID','COMPONENT_RELATION_BINDING_CHANGED','COMPONENT_RELATION_SCOPE_UNSUPPORTED','COMPONENT_RELATION_INPUT_INVALID','COMPONENT_RELATION_TARGET_INVALID','COMPONENT_RELATION_CYCLE','COMPONENT_RELATION_BINDING_UNAVAILABLE')){$_.Exception.Message}else{'COMPONENT_RELATION_BINDING_UNAVAILABLE'}
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ssms-registration') {
                try {
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'SSMS_REGISTRATION_REQUEST_INVALID'
                    }
                    $registration = & (Get-Module SqlServerLab) { Get-LabSsmsRegistrationDownload }
                    Write-UiResponse -Context $context -Body $registration -ContentType 'application/xml; charset=utf-8' -NoStore
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"SSMS_REGISTRATION_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -NoStore
                }
                finally { $registration=$null }
                continue
            }
            if ($path -eq '/api/cms-inspection') {
                try {$result=Invoke-UiCmsInspectionRequest -Request $context.Request;Write-UiResponse -Context $context -Body ($result|ConvertTo-Json -Depth 6) -ContentType 'application/json; charset=utf-8'}
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body 'CMS_INSPECTION_REQUEST_FAILED: Registrierung und Auswahl erneut lesen.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/cms-management' -and $context.Request.HttpMethod -eq 'GET') {
                try {
                    $result = Invoke-UiCmsManagementRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -NoStore
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"CMS_MANAGEMENT_STATE_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -NoStore
                }
                continue
            }
            if ($path -eq '/api/initial-setup') {
                try {
                    $result = Invoke-UiInitialSetupRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }

                    Write-UiResponse -Context $context -Body 'INITIAL_SETUP_REQUEST_FAILED: Eingaben und aktuellen Zustand erneut prüfen.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/slot-reserve') {
                try {
                    $result = Invoke-UiSlotReserveRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }

                    Write-UiResponse -Context $context -Body 'SLOT_RESERVE_REQUEST_FAILED: Eingaben und aktuellen Zustand erneut prüfen.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/resource-watch') {
                try {
                    $result = Invoke-UiResourceWatchRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                } catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body 'RESOURCE_WATCH_UNAVAILABLE' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/media-overrides') {
                try {
                    $result = Invoke-UiMediaOverrideRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }

                    Write-UiResponse -Context $context -Body 'MEDIA_SOURCE_OVERRIDE_REQUEST_FAILED: Eingaben und aktuellen Zustand erneut prüfen.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/workflow' -and $context.Request.HttpMethod -eq 'GET') {
                $mediaRoot = [string]$context.Request.QueryString['mediaRoot']
                Write-UiResponse -Context $context -Body (Get-UiWorkflowInventoryResponse -MediaRoot $mediaRoot | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/evaluation-watch' -and $context.Request.HttpMethod -eq 'GET') {
                try {
                    $view = & (Get-Module SqlServerLab) { Get-LabEvaluationWatchView }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body 'EVALUATION_WATCH_READ_UNAVAILABLE' -StatusCode 503
                }
                continue
            }
            if ($path -eq '/api/llama-installer') {
                try {
                    $view=Invoke-UiLlamaInstallerRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($view|ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }catch{
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body 'LLAMA_INSTALL_UNCONFIRMED: Ergebnis nicht bestätigt; frisch vorprüfen. Keine automatische Wiederholung oder Prerequisiteinstallation.' -StatusCode 400
                }
                continue
            }
            if ($path -cin @('/api/ssis-execution-diagnostic', '/api/ssis-package-diagnostic')) {
                try {
                    $request = $context.Request
                    if ($request.HttpMethod -cne 'POST' -or $request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
                        $request.Url.Query -or [string]$request.Headers['Origin'] -cne $request.Url.GetLeftPart([UriPartial]::Authority)) {
                        throw 'SSIS_EXECUTION_DIAGNOSTIC_HTTP_INVALID'
                    }
                    $body = Read-UiSpecializedJsonRequestBody -Request $request -MaxCharacters 1024 -LimitErrorCode 'SSIS_EXECUTION_DIAGNOSTIC_HTTP_INVALID'
                    $view = & (Get-Module SqlServerLab) {
                        param($json, $route)
                        if ($route -ceq '/api/ssis-package-diagnostic') { Invoke-LabSsisPackageDiagnosticBrowser -Json $json }
                        else { Invoke-LabSsisExecutionDiagnosticBrowser -Json $json }
                    } $body $path
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body '{"Code":"SSIS_DIAGNOSTIC_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ai-compute-inventory') {
                try {
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'AI_COMPUTE_INVENTORY_REQUEST_INVALID'
                    }
                    $view = & (Get-Module SqlServerLab) { Get-LabAiComputeInventoryView }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_COMPUTE_INVENTORY_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ai-runtime-capability') {
                try {
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'AI_RUNTIME_CAPABILITY_REQUEST_INVALID'
                    }
                    $view = & (Get-Module SqlServerLab) { Get-LabAiRuntimeCapabilityView }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_RUNTIME_CAPABILITY_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/portable-lab-import-plan') {
                try {
                    if ($context.Request.HttpMethod -cne 'POST' -or -not $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'PORTABLE_IMPORT_PLAN_REQUEST_INVALID'
                    }
                    $bodyRead = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 327680
                    if (-not $bodyRead.Allowed) { throw 'PORTABLE_IMPORT_PLAN_REQUEST_INVALID' }
                    $document = [Text.Json.JsonDocument]::Parse([string]$bodyRead.Body)
                    try {
                        $root = $document.RootElement
                        Assert-UiCommandJsonUnique $root
                        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                            (@(@($root.EnumerateObject()).Name | Sort-Object) -join ',') -cne 'Package,TargetProvider,TargetRunId' -or
                            $root.GetProperty('Package').ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                            throw 'PORTABLE_IMPORT_PLAN_REQUEST_INVALID'
                        }
                        $provider = $root.GetProperty('TargetProvider').GetString()
                        $runId = $root.GetProperty('TargetRunId').GetString()
                        $guid = [guid]::Empty
                        if ($provider -cnotin @('docker','podman') -or -not [guid]::TryParseExact($runId,'D',[ref]$guid) -or $guid -eq [guid]::Empty) {
                            throw 'PORTABLE_IMPORT_PLAN_REQUEST_INVALID'
                        }
                        $package = $root.GetProperty('Package').GetRawText() | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                    }
                    finally { $document.Dispose() }
                    $plan = & (Get-Module SqlServerLab) {
                        param($Package,$Provider,$RunId)
                        Get-LabPortableLabImportPlan -Package $Package -TargetProvider $Provider -TargetRunId $RunId -ErrorAction Stop
                    } $package $provider $guid.ToString('D')
                    Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"PORTABLE_IMPORT_PLAN_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                finally { $bodyRead=$null; $package=$null }
                continue
            }
            if ($path -ceq '/api/manifest-check') {
                try {
                    if ($context.Request.HttpMethod -cne 'POST' -or -not $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'MANIFEST_CHECK_REQUEST_INVALID'
                    }
                    $read = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 24576
                    if (-not $read.Allowed) { throw 'MANIFEST_CHECK_REQUEST_INVALID' }
                    $document = [Text.Json.JsonDocument]::Parse([string]$read.Body)
                    try {
                        $properties = @($document.RootElement.EnumerateObject())
                        if ($properties.Count -ne 1 -or $properties[0].Name -cne 'Path' -or
                            $properties[0].Value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'MANIFEST_CHECK_REQUEST_INVALID' }
                        $manifestPath = $properties[0].Value.GetString()
                    }
                    finally { $document.Dispose() }
                    $view = & (Get-Module SqlServerLab) { param($file) Get-LabManifestCheckView -Path $file } $manifestPath
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"MANIFEST_CHECK_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                finally { $read=$null; $manifestPath=$null }
                continue
            }
            if ($path -ceq '/api/run-state-upgrade-plan') {
                try {
                    $query = $context.Request.QueryString
                    $identities = @($query.GetValues('runId'))
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or
                        $query.Count -ne 1 -or $identities.Count -ne 1 -or $identities[0].Length -ne 36) {
                        throw 'RUN_STATE_UPGRADE_GUIDANCE_REQUEST_INVALID'
                    }
                    $view = & (Get-Module SqlServerLab) { param($id) Get-LabRunStateUpgradePlanView -RunId $id } $identities[0]
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"RUN_STATE_UPGRADE_GUIDANCE_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ai-scenario-plan') {
                try {
                    $query = $context.Request.QueryString
                    $runIds = @($query.GetValues('runId'))
                    $instanceIds = @($query.GetValues('instanceId'))
                    $requestedRun = [guid]::Empty
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or
                        ($query.Count -ne 0 -and ($query.Count -ne 2 -or $runIds.Count -ne 1 -or $instanceIds.Count -ne 1 -or
                            -not [guid]::TryParseExact($runIds[0], 'D', [ref]$requestedRun) -or $requestedRun -eq [guid]::Empty -or
                            [string]$instanceIds[0] -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z'))) {
                        throw 'AI_SCENARIO_PLAN_UI_REQUEST_INVALID'
                    }
                    $arguments = @{ ScenarioId='vector-core-ci'; Version='1.0'; ErrorAction='Stop' }
                    if ($query.Count) {
                        $arguments.RunId = $requestedRun.ToString('D')
                        $arguments.InstanceId = $instanceIds[0]
                    }
                    $plan = Get-SqlServerLabAiScenario @arguments
                    $codes = @(foreach ($blocker in $plan.Blockers) {
                        if ([string]$blocker -cmatch '\A((?:AI_SCENARIO|DESIRED_STATE)_[A-Z_]{1,80})(?=:|\z)') { $Matches[1] }
                        else { 'AI_SCENARIO_PLAN_BLOCKED' }
                    })
                    $view = [pscustomobject]@{
                        ScenarioId=$plan.ScenarioId; Version=$plan.Version; Status=$plan.Status
                        RunId=if ($query.Count) { $plan.RunId } else { $null }
                        InstanceId=if ($query.Count) { $plan.InstanceId } else { $null }
                        PlanKey=$plan.PlanKey; Blockers=@($codes | Sort-Object -Unique)
                        RequiredCapabilities=@($plan.RequiredCapabilities)
                    }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_SCENARIO_PLAN_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/license-profile-status') {
                $license = & (Get-Module SqlServerLab) {
                    param($method,$query)
                    Invoke-LabLicenseProfileStatusRequest -Method $method -Query $query
                } $context.Request.HttpMethod $context.Request.QueryString
                Write-UiResponse -Context $context -Body ($license.View | ConvertTo-Json -Depth 5 -Compress) `
                    -StatusCode $license.StatusCode -ContentType 'application/json; charset=utf-8' -NoStore
                continue
            }
            if ($path -ceq '/api/smtp-status') {
                $smtp = & (Get-Module SqlServerLab) {
                    param($method,$query)
                    Invoke-LabSmtpStatusGuidanceRequest -Method $method -Query $query
                } $context.Request.HttpMethod $context.Request.QueryString
                Write-UiResponse -Context $context -Body ($smtp.View | ConvertTo-Json -Depth 5 -Compress) `
                    -StatusCode $smtp.StatusCode -ContentType 'application/json; charset=utf-8' -NoStore
                continue
            }
            if ($path -ceq '/api/smtp-webmail/open') {
                if ($context.Request.HttpMethod -cne 'POST' -or $context.Request.Url.Query -or
                    [string]$context.Request.Headers['Origin'] -cne $url.TrimEnd('/')) {
                    Write-UiResponse -Context $context -Body 'SMTP_WEBMAIL_OPEN_REQUEST_INVALID' -StatusCode 400 -NoStore
                    continue
                }
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 1024
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body 'SMTP_WEBMAIL_OPEN_REQUEST_INVALID' -StatusCode 400 -NoStore
                    continue
                }
                $smtpOpen = & (Get-Module SqlServerLab) {
                    param($json)
                    Invoke-LabGuidedSmtpWebMailRequest -Json $json
                } $bodyRead.Body
                Write-UiResponse -Context $context -Body ($smtpOpen.View | ConvertTo-Json -Depth 4 -Compress) `
                    -StatusCode $smtpOpen.StatusCode -ContentType 'application/json; charset=utf-8' -NoStore
                continue
            }
            if ($path -ceq '/api/container-network-migration') {
                $network = & (Get-Module SqlServerLab) {
                    param($method,$query)
                    Invoke-LabContainerNetworkPlanRequest -Method $method -Query $query
                } $context.Request.HttpMethod $context.Request.QueryString
                Write-UiResponse -Context $context -Body ($network.View | ConvertTo-Json -Depth 5 -Compress) `
                    -StatusCode $network.StatusCode -ContentType 'application/json; charset=utf-8' -NoStore
                continue
            }
            if ($path -ceq '/api/diagnostic-bundle') {
                try {
                    $query = $context.Request.QueryString
                    $runIds = @($query.GetValues('runId'))
                    $instanceIds = @($query.GetValues('instanceId'))
                    $providers = @($query.GetValues('provider'))
                    $requestedRun = [guid]::Empty
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $query.Count -ne 3 -or
                        $runIds.Count -ne 1 -or -not [guid]::TryParseExact($runIds[0], 'D', [ref]$requestedRun) -or
                        $requestedRun -eq [guid]::Empty -or $instanceIds.Count -ne 1 -or
                        [string]$instanceIds[0] -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z' -or
                        $providers.Count -ne 1 -or $providers[0] -cnotin @('docker','podman','hyperv')) {
                        throw 'DIAGNOSTIC_BUNDLE_UI_REQUEST_INVALID'
                    }
                    $bundle = & (Get-Module SqlServerLab) {
                        param($RunId,$InstanceId,$Provider)
                        $dataRoot = Get-LabDataRootDefault
                        if (-not $dataRoot) { throw 'DIAGNOSTIC_BUNDLE_UI_ROOT_MISSING' }
                        $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                        if (-not [string]::Equals(
                            [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Get-LabStateRoot))),
                            [IO.Path]::GetFullPath((Join-Path $dataRoot 'State')), $pathComparison)) {
                            throw 'DIAGNOSTIC_BUNDLE_UI_ROOT_MISMATCH'
                        }
                        Get-SqlServerLabDiagnosticBundle -RunId $RunId -InstanceId $InstanceId -Provider $Provider -DataRoot $dataRoot -SkipReadiness
                    } $requestedRun.ToString('D') $instanceIds[0] $providers[0]
                    Write-UiResponse -Context $context -Body ($bundle | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"DIAGNOSTIC_BUNDLE_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/runtime-maintenance-preview') {
                if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                    Write-UiResponse -Context $context -Body '{"Code":"RUNTIME_MAINTENANCE_PREVIEW_REQUEST_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                    continue
                }
                try {
                    $view = & (Get-Module SqlServerLab) { Get-LabRuntimeMaintenancePreview -ErrorAction Stop }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"RUNTIME_MAINTENANCE_PREVIEW_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/hyperv-storage-preview') {
                if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                    Write-UiResponse -Context $context -Body '{"Code":"HYPERV_STORAGE_PREVIEW_REQUEST_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                    continue
                }
                try {
                    $preview = Get-SqlServerLabHyperVResourcePreview -ErrorAction Stop
                    $view = [pscustomobject]@{
                        LabDataRoot = $preview.LabDataRoot
                        FreeBytes = [string]$preview.ObservedFreeBytes
                        SystemVolume = $preview.SystemVolume
                        Targets = @($preview.Targets | Select-Object ResourceClass, ClassRoot)
                    }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"HYPERV_STORAGE_PREVIEW_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/hyperv-recovery-point-plan') {
                try {
                    $query = $context.Request.QueryString
                    $runIds = @($query.GetValues('runId'))
                    $instanceIds = @($query.GetValues('instanceId'))
                    $requestedRun = [guid]::Empty
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $query.Count -ne 2 -or
                        $runIds.Count -ne 1 -or -not [guid]::TryParseExact($runIds[0], 'D', [ref]$requestedRun) -or
                        $requestedRun -eq [guid]::Empty -or $instanceIds.Count -ne 1 -or
                        [string]$instanceIds[0] -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,127}\z') {
                        throw 'HYPERV_RECOVERY_POINT_REQUEST_INVALID'
                    }
                    $plan = Get-SqlServerLabHyperVRecoveryPointPlan -RunId $requestedRun.ToString('D') -InstanceId $instanceIds[0] -ErrorAction Stop
                    Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"HYPERV_RECOVERY_POINT_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/automation-plan') {
                try {
                    $query = $context.Request.QueryString
                    $actions = @($query.GetValues('action'))
                    if ($context.Request.HttpMethod -cne 'GET' -or $context.Request.HasEntityBody -or $query.Count -ne 1 -or
                        $actions.Count -ne 1 -or [string]$actions[0] -cnotmatch '^[A-Za-z]{1,40}$') {
                        throw 'AUTOMATION_API_PLAN_REQUEST_INVALID'
                    }
                    $plan = Get-SqlServerLabAutomationPlan -Action $actions[0] -ErrorAction Stop
                    Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AUTOMATION_API_PLAN_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ai-compute-benchmark-options') {
                try {
                    if ($context.Request.HttpMethod -cne 'POST' -or -not $context.Request.HasEntityBody -or $context.Request.Url.Query) {
                        throw 'AI_COMPUTE_BENCHMARK_OPTIONS_REQUEST_INVALID'
                    }
                    $bodyRead = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 24576
                    if (-not $bodyRead.Allowed) { throw 'AI_COMPUTE_BENCHMARK_OPTIONS_REQUEST_INVALID' }
                    $document = [Text.Json.JsonDocument]::Parse([string]$bodyRead.Body)
                    try {
                        $root = $document.RootElement
                        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                            @($root.EnumerateObject()).Count -ne 1 -or @($root.EnumerateObject()).Name -cne 'ModelPath' -or
                            $root.GetProperty('ModelPath').ValueKind -ne [Text.Json.JsonValueKind]::String) {
                            throw 'AI_COMPUTE_BENCHMARK_OPTIONS_REQUEST_INVALID'
                        }
                        $modelPath = $root.GetProperty('ModelPath').GetString()
                    }
                    finally { $document.Dispose() }
                    if ([string]::IsNullOrWhiteSpace($modelPath) -or $modelPath.Length -gt 4096) { throw 'AI_COMPUTE_BENCHMARK_OPTIONS_REQUEST_INVALID' }
                    $options = & (Get-Module SqlServerLab) { param($modelPath) Get-LabAiComputeBenchmarkOptions -ModelPath $modelPath } $modelPath
                    Write-UiResponse -Context $context -Body ($options | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_COMPUTE_BENCHMARK_OPTIONS_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                finally { $bodyRead = $null; $modelPath = $null; $options = $null }
                continue
            }
            if ($path -ceq '/api/ollama-local-generation' -and $context.Request.HttpMethod -ceq 'GET') {
                try {
                    if ($context.Request.Url.Query) { throw 'OLLAMA_LOCAL_CATALOG_REQUEST_INVALID' }
                    $models = @(& (Get-Module SqlServerLab) { Get-LabAiLocalGenerationCatalog })
                    $json = ConvertTo-Json -InputObject $models -Depth 4 -Compress
                    Write-UiResponse -Context $context -Body $json -ContentType 'application/json; charset=utf-8'
                } catch {
                    Write-UiResponse -Context $context -Body '{"Code":"OLLAMA_LOCAL_CATALOG_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 503
                }
                continue
            }
            if ($path -ceq '/api/ollama-cloud-generation' -and $context.Request.HttpMethod -ceq 'GET') {
                if ($context.Request.Url.Query) {
                    Write-UiResponse -Context $context -Body '{"Code":"OLLAMA_CLOUD_CATALOG_REQUEST_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -NoStore
                    continue
                }
                try {
                    $models = @(& (Get-Module SqlServerLab) { Get-LabAiCloudGenerationCatalog })
                    Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject $models -Depth 3 -Compress) -ContentType 'application/json; charset=utf-8' -NoStore
                } catch {
                    Write-UiResponse -Context $context -Body '{"Code":"OLLAMA_CLOUD_CATALOG_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 503 -NoStore
                }
                continue
            }
            if ($path -ceq '/api/llama-model-catalog' -and $context.Request.HttpMethod -ceq 'GET') {
                try {
                    $catalog = @(Get-SqlServerLabLlamaCppModel -ErrorAction Stop)
                    Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject $catalog -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -NoStore
                } catch {
                    Write-UiResponse -Context $context -Body '{"Code":"LLAMA_MODEL_CATALOG_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -NoStore
                }
                continue
            }
            if ($path -ceq '/api/llama-runtime-inventory') {
                try {
                    $view = & (Get-Module SqlServerLab) { param($request) Invoke-LabLlamaCppRuntimeInventoryHttpRequest -Request $request } $context.Request
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body 'LLAMA_RUNTIME_INVENTORY_UNAVAILABLE' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/llama-sessions') {
                try {
                    $view=Invoke-UiLlamaSessionRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 5) -ContentType 'application/json; charset=utf-8'
                } catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body 'LLAMA_SESSION_UNCONFIRMED: Stop nicht bestätigt. Neu lesen und vorprüfen; eigene Recovery separat prüfen. Keine automatische Wiederholung.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/maintenance') {
                try {
                    $view=Invoke-UiMaintenanceRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    if (Write-UiBodyFailureResponse -Context $context -ErrorRecord $_) { continue }
                    Write-UiResponse -Context $context -Body 'MAINTENANCE_UNCONFIRMED: Ergebnis nicht bestätigt. Erneut lesen und vorprüfen; keine automatische Wiederholung.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/commands' -and $context.Request.HttpMethod -eq 'GET') {
                $catalog = & (Get-Module SqlServerLab) { Get-LabPublicCommandWebCatalog }
                Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject @($catalog) -Depth 12) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/environment-groups/runtime') {
                if ($context.Request.HttpMethod -cne 'GET') {
                    Write-UiResponse -Context $context -Body '{"code":"UI_METHOD_NOT_ALLOWED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 405 -NoStore
                    continue
                }
                $query = $context.Request.QueryString
                $queryKeys = @($query.AllKeys | Where-Object { $_ })
                $groupValues = @($query.GetValues('groupId'))
                $runValues = @($query.GetValues('runId'))
                $groupGuid = [guid]::Empty
                $runGuid = [guid]::Empty
                if ($queryKeys.Count -ne 2 -or @($queryKeys | Where-Object { $_ -cnotin @('groupId', 'runId') }).Count -gt 0 -or
                    $groupValues.Count -ne 1 -or $runValues.Count -ne 1 -or
                    -not [guid]::TryParse([string]$groupValues[0], [ref]$groupGuid) -or -not [guid]::TryParse([string]$runValues[0], [ref]$runGuid)) {
                    Write-UiResponse -Context $context -Body '{"code":"ENVIRONMENT_GROUP_RUNTIME_REQUEST_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -NoStore
                    continue
                }
                try {
                    $view = & (Get-Module SqlServerLab) { param($groupId, $runId) Get-LabEnvironmentGroupRuntimeObservation -GroupId $groupId -RunId $runId } $groupGuid.ToString('D') $runGuid.ToString('D')
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -NoStore
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"code":"ENVIRONMENT_GROUP_RUNTIME_UNAVAILABLE"}' -ContentType 'application/json; charset=utf-8' -StatusCode 503 -NoStore
                }
                continue
            }
            if ($path -eq '/api/environment-groups') {
                if ($context.Request.HttpMethod -cne 'GET') {
                    Write-UiResponse -Context $context -Body '{"code":"UI_METHOD_NOT_ALLOWED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 405
                    continue
                }
                try {
                    $view = Get-UiEnvironmentGroupsView
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"code":"ENVIRONMENT_GROUPS_READ_UNCONFIRMED"}' -ContentType 'application/json; charset=utf-8' -StatusCode 500
                }
                continue
            }
            if ($path -eq '/api/jobs' -and $context.Request.HttpMethod -eq 'GET') {
                $snapshot = @(@($jobs.Values | ForEach-Object { Get-UiJobSnapshot -Record $_ }) + @($persistentJobs.Values | ForEach-Object { Get-UiPersistentJobSnapshot -Record $_ }) | Sort-Object StartedAt -Descending)
                Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject $snapshot -Depth 8) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/config' -and $context.Request.HttpMethod -eq 'GET') {
                Write-UiResponse -Context $context -Body (Get-UiCapabilityConfig | ConvertTo-Json -Depth 6) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -ceq '/api/ai-shared-gateway/plan') {
                if ($context.Request.HttpMethod -cne 'POST' -or $context.Request.Url.Query -or
                    $context.Request.ContentType -notmatch '^application/json(?:\s*;|$)' -or
                    [string]$context.Request.Headers['Origin'] -cne $url.TrimEnd('/')) {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_SHARED_GATEWAY_FORM_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                    continue
                }
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 65536
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                try {
                    $plan = & (Get-Module SqlServerLab) { param($Body) Invoke-LabAiSharedGatewayPlanForm -Body $Body } $bodyRead.Body
                    Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                catch {
                    Write-UiResponse -Context $context -Body '{"Code":"AI_SHARED_GATEWAY_FORM_INVALID"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -ceq '/api/ai-shared-gateway/sessions') {
                try {
                    if ($context.Request.Url.Query) { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
                    if ($context.Request.HttpMethod -ceq 'GET') {
                        $view = & (Get-Module SqlServerLab) { param($scope) Get-LabAiSharedGatewayBrowserSessions -BrowserSessions $scope } $aiSharedGatewayBrowserSessions
                    } elseif ($context.Request.HttpMethod -ceq 'POST' -and
                        $context.Request.ContentType -match '^application/json(?:\s*;|$)' -and
                        [string]$context.Request.Headers['Origin'] -ceq $url.TrimEnd('/')) {
                        $bodyRead = Read-UiJsonRequestBody -Request $context.Request -MaxBytes 65536
                        if (-not $bodyRead.Allowed) {
                            Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                            continue
                        }
                        $view = & (Get-Module SqlServerLab) {
                            param($scope,$body) Invoke-LabAiSharedGatewayBrowserSession -BrowserSessions $scope -Body $body
                        } $aiSharedGatewayBrowserSessions $bodyRead.Body
                    } else { throw 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                } catch {
                    $code = $_.Exception.Message
                    if ($code -cnotin @('AI_SHARED_GATEWAY_SESSION_HTTP_CONFIRM_POLICY_BLOCKED',
                        'AI_SHARED_GATEWAY_SESSION_HTTP_NOT_READY','AI_SHARED_GATEWAY_SESSION_HTTP_VAULT_UNAVAILABLE',
                        'AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_UNAVAILABLE','AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_INVALID',
                        'AI_SHARED_GATEWAY_SESSION_HTTP_START_UNCONFIRMED','AI_SHARED_GATEWAY_SESSION_HTTP_STOP_UNCONFIRMED',
                        'AI_SHARED_GATEWAY_SESSION_HTTP_OWNERSHIP_NOT_FOUND')) { $code = 'AI_SHARED_GATEWAY_SESSION_HTTP_INVALID' }
                    Write-UiResponse -Context $context -Body (@{Code=$code} | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/ai-shared-gateway/service-secret' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request = $body | ConvertFrom-Json -Depth 30
                if (-not $request -or $request.PSObject.Properties.Name -notcontains 'plan' -or $request.PSObject.Properties.Name -notcontains 'servicePlan') {
                    throw 'AI_SHARED_GATEWAY_UI_PLAN_AND_SERVICE_PLAN_REQUIRED'
                }
                $receipt = Test-SqlServerLabAiSharedGatewayServiceSecret -Plan $request.plan -ServicePlan $request.servicePlan
                Write-UiResponse -Context $context -Body ($receipt | ConvertTo-Json -Depth 20) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/queue' -and $context.Request.HttpMethod -eq 'GET') {
                Write-UiResponse -Context $context -Body (Get-SqlServerLabQueue | ConvertTo-Json -Depth 20) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/batches' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request = $body | ConvertFrom-Json -Depth 30
                if ($request.command -ceq 'SaveGuidedDraft') {
                    if ($body.Length -gt 32768) {
                        Write-UiResponse -Context $context -Body 'BROWSER_BATCH_DRAFT_INVALID' -StatusCode 400
                        continue
                    }
                    try {
                        $document = [Text.Json.JsonDocument]::Parse($body)
                        try { Assert-UiCommandJsonUnique $document.RootElement } finally { $document.Dispose() }
                        $draft = & (Get-Module SqlServerLab) {
                            param($DraftRequest)
                            Save-LabBrowserBatchDraft -Request $DraftRequest -StateRoot ([IO.Path]::GetFullPath((Get-LabStateRoot)))
                        } $request
                    }
                    catch {
                        if ($_.Exception.Message -cin @('BROWSER_BATCH_DRAFT_INVALID','UI_COMMAND_REQUEST_INVALID')) {
                            Write-UiResponse -Context $context -Body 'BROWSER_BATCH_DRAFT_INVALID' -StatusCode 400
                        } else {
                            Write-UiResponse -Context $context -Body 'Entwurf unbestätigt. Batchübersicht und Providerbereitschaft prüfen.' -StatusCode 409
                        }
                        continue
                    }
                    Write-UiResponse -Context $context -Body ($draft | ConvertTo-Json -Depth 5) -ContentType 'application/json; charset=utf-8' -StatusCode 201
                    continue
                }
                $batch = New-SqlServerLabBatch -Name ([string]$request.name) -Priority $(if ($request.priority) { [string]$request.priority } else { 'Normal' }) -Defaults $request.defaults -Items @($request.items) -Queue:$false
                Write-UiResponse -Context $context -Body ($batch | ConvertTo-Json -Depth 30) -ContentType 'application/json; charset=utf-8' -StatusCode 201
                continue
            }
            if ($path -eq '/api/operations' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request = $body | ConvertFrom-Json -Depth 12
                if ($request.command -ceq 'StartOperationHost') {
                    $names = @($request.PSObject.Properties.Name)
                    if ($body.Length -gt 256 -or $names.Count -ne 2 -or
                        @($names | Where-Object { $_ -cnotin @('command','confirmed') }).Count -or
                        $request.command -isnot [string] -or $request.confirmed -isnot [bool] -or -not $request.confirmed) {
                        Write-UiResponse -Context $context -Body 'OPERATION_HOST_CONFIRMATION_REQUIRED' -StatusCode 400
                        continue
                    }
                    $document = [Text.Json.JsonDocument]::Parse($body)
                    try { Assert-UiCommandJsonUnique $document.RootElement } finally { $document.Dispose() }
                    $root = & (Get-Module SqlServerLab) { [IO.Path]::GetFullPath((Get-LabStateRoot)) }
                    if ((Invoke-UiOperationHostStart -StateRoot $root) -ne 'Requested') {
                        Write-UiResponse -Context $context -Body 'OPERATION_HOST_START_FAILED: Status prüfen und bei Bedarf erneut anfordern.' -StatusCode 503
                        continue
                    }
                    Write-UiResponse -Context $context -Body '{"state":"Requested"}' -ContentType 'application/json; charset=utf-8' -StatusCode 202
                    continue
                }
                if ($request.command -cin @('BatchStopPreview','BatchStopApply','BatchSubmitPreview','BatchSubmitApply','BatchRollbackPreview','BatchRollbackApply')) {
                    $isSubmit = $request.command -cin @('BatchSubmitPreview','BatchSubmitApply')
                    $isRollback = $request.command -cin @('BatchRollbackPreview','BatchRollbackApply')
                    $isPreview = $request.command -cin @('BatchStopPreview','BatchSubmitPreview','BatchRollbackPreview')
                    $names = @($request.PSObject.Properties.Name)
                    $required = if ($isPreview) { @('command','batchId') } else { @('command','batchId','previewId','confirmed') }
                    if ($body.Length -gt 1024 -or $names.Count -ne $required.Count -or
                        @($names | Where-Object { $_ -cnotin $required }).Count -or
                        $request.batchId -isnot [string] -or $request.batchId -cnotmatch '\Abatch-\d{14}-[0-9a-f]{8}\z' -or
                        (-not $isPreview -and ($request.previewId -isnot [string] -or $request.confirmed -isnot [bool] -or -not $request.confirmed))) {
                        $code = if ($isSubmit) { 'BROWSER_BATCH_SUBMIT_REQUEST_INVALID' } else { 'BROWSER_BATCH_STOP_REQUEST_INVALID' }
                        Write-UiResponse -Context $context -Body $code -StatusCode 400
                        continue
                    }
                    $document = [Text.Json.JsonDocument]::Parse($body)
                    try { Assert-UiCommandJsonUnique $document.RootElement } finally { $document.Dispose() }

                    $labModule = Get-Module SqlServerLab
                    $batchRoot = & $labModule { [IO.Path]::GetFullPath((Get-LabStateRoot)) }
                    $previewId = if ($isPreview) { '' } else { $request.previewId }
                    try {
                        $batchResult = & $labModule {
                            param($Submit, $Preview, $Rollback, $BatchId, $PreviewId, $Root)
                            if ($Submit -and $Preview) { New-LabBrowserBatchSubmitPreview -BatchId $BatchId -StateRoot $Root }
                            elseif ($Submit) { Invoke-LabBrowserBatchSubmitPreview -BatchId $BatchId -PreviewId $PreviewId -StateRoot $Root }
                            elseif ($Preview) { New-LabBrowserBatchStopPreview -BatchId $BatchId -StateRoot $Root -Rollback:$Rollback }
                            else { Invoke-LabBrowserBatchStopPreview -BatchId $BatchId -PreviewId $PreviewId -StateRoot $Root -Rollback:$Rollback }
                        } $isSubmit $isPreview $isRollback $request.batchId $previewId $batchRoot
                    }
                    catch {
                        if ($isSubmit -and $_.Exception.Message -cmatch '^BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_(MISSING|REQUIRED):') {
                            Write-UiResponse -Context $context -Body 'Eine benötigte SQL-Kennwortvariable fehlt in der Sitzung der Browseroberfläche.' -StatusCode 409
                            continue
                        }
                        if ($_.Exception.Message -cnotin @('BROWSER_BATCH_STOP_BATCH_UNAVAILABLE','BROWSER_BATCH_STOP_BATCH_INVALID',
                            'BROWSER_BATCH_STOP_NO_TARGETS','BROWSER_BATCH_STOP_PREVIEW_REQUIRED','BROWSER_BATCH_STOP_PREVIEW_STALE',
                            'BATCH_REVIEW_INVALID','BATCH_REVIEW_STALE','BATCH_REVIEW_PREVIEW_REQUIRED')) { throw }
                        Write-UiResponse -Context $context -Body 'Der Batch oder die Vorschau hat sich geändert. Status lesen und bei Bedarf eine neue Vorschau öffnen.' -StatusCode 409
                        continue
                    }
                    if (-not $isPreview -and ($isSubmit -or $batchResult.Requested -gt 0) -and (Invoke-UiOperationHostStart -StateRoot $batchRoot) -eq 'Failed') {
                        $message = if ($isSubmit) {
                            'OPERATION_HOST_START_FAILED: Batch eingereiht. Status prüfen; keine automatische Wiederholung.'
                        } elseif ($isRollback) {
                            'OPERATION_HOST_START_FAILED: Rückbau eingereiht. Status prüfen; keine automatische Wiederholung.'
                        } else {
                            'OPERATION_HOST_START_FAILED: Stopp angenommen. Status prüfen; keine automatische Wiederholung.'
                        }
                        Write-UiResponse -Context $context -Body $message -StatusCode 503
                        continue
                    }
                    Write-UiResponse -Context $context -Body ($batchResult | ConvertTo-Json -Depth 5) -ContentType 'application/json; charset=utf-8'
                    continue
                }
                $operationId = [string]$request.operationId
                $result = switch ([string]$request.command) {
                    'Confirm' {
                        $credential = $null
                        if ($request.userName -and $request.password) {
                            $secure = [SecureString]::new()
                            foreach ($character in ([string]$request.password).ToCharArray()) { $secure.AppendChar($character) }
                            $secure.MakeReadOnly()
                            $credential = [PSCredential]::new([string]$request.userName, $secure)
                        }
                        Confirm-SqlServerLabOperationUserAction -OperationId $operationId -Credential $credential
                    }
                    'Probe' { & (Get-Module SqlServerLab) { param($Id) Invoke-SqlServerLabOperationProbe -OperationId $Id } $operationId }
                    'Suspend' { Suspend-SqlServerLabOperation -OperationId $operationId }
                    'Resume' { Resume-SqlServerLabOperation -OperationId $operationId }
                    'MoveUp' { Move-SqlServerLabOperation -OperationId $operationId -Direction Up }
                    'MoveDown' { Move-SqlServerLabOperation -OperationId $operationId -Direction Down }
                    'PriorityHigh' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority High }
                    'PriorityNormal' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority Normal }
                    'PriorityLow' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority Low }
                    'StopCleanup' { Stop-SqlServerLabOperation -OperationId $operationId -Cleanup -Confirm:$false }
                    'SubmitBatch' { & (Get-Module SqlServerLab) { param($Id) Submit-SqlServerLabBatch -BatchId $Id } ([string]$request.batchId) }
                    default { throw "Unbekanntes Operation-Kommando '$($request.command)'." }
                }
                if ((Invoke-UiOperationHostStart) -eq 'Failed') {
                    Write-UiResponse -Context $context -Body 'OPERATION_HOST_START_FAILED: Änderung angenommen; Hoststart fehlgeschlagen. Status prüfen, nicht automatisch wiederholen.' -StatusCode 503
                    continue
                }
                Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 20) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/persistent-storage/retained-removal-plan' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request=$body | ConvertFrom-Json -Depth 8
                $dataRoot=& (Get-Module SqlServerLab) { Get-LabDataRootDefault }
                $plan=Get-SqlServerLabRetainedStoreRemovalPlan -PersistentStorageId ([guid]$request.persistentStorageId) -DataRoot $dataRoot
                Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 10) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/persistent-storage/removal-plan' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request = $body | ConvertFrom-Json -Depth 30
                $runId = [string]$request.runId
                $selections = @($request.selections)
                if (-not $runId -or $selections.Count -eq 0) {
                    throw 'PERSISTENT_STORAGE_REMOVAL_PREVIEW_INPUT_REQUIRED'
                }
                $plan = Get-SqlServerLabPersistentStorageRemovalPlan -RunId $runId -Selection $selections
                Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 30) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/actions' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $body = $bodyRead.Body
                $request = $body | ConvertFrom-Json -Depth 8
                $action = [string]$request.action
                if ($action -in @('InitializeCms','AdoptCms')) {
                    try { & (Get-Module SqlServerLab) { param($json,$name) Assert-LabCmsManagementWorkflowJsonShape -Json $json -Action $name } $body $action }
                    catch { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
                }
                if ($action -in @('NewContainerLab','NewContainerLabFromManifest')) {
                    try {
                        & (Get-Module SqlServerLab) { param($json,$a) Assert-LabSaPasswordWorkflowJsonShape -Json $json -Action $a } $body $action
                    }
                    catch { throw 'UI_SA_PASSWORD_REQUEST_INVALID' }
                }
                if ($action -in @('GetCmsInspectionState','InspectCms','GetCmsManagementState','GetLlamaSessions','PlanLlamaSessionStop','StopLlamaSession','GetResourceWatchState', 'RefreshResourceWatch', 'GetMediaOverrideState', 'PlanMediaOverride', 'ApplyMediaOverride', 'GetSlotReserveState', 'PlanSlotReserve', 'ApplySlotReserve', 'PlanWindowsPoolMember', 'ApplyWindowsPoolMember', 'CancelWindowsPoolMember', 'GetInitialSetupState', 'PlanInitialSetup', 'ApplyInitialSetup', 'RefreshSetupProvider', 'PlanSetupWriteability', 'ProbeSetupWriteability', 'RefreshSetupCapacity')) { throw 'INITIAL_SETUP_DIRECT_ENDPOINT_REQUIRED' }
                $parameters = @{}
                if ($request.parameters) {
                    foreach ($property in $request.parameters.PSObject.Properties) {
                        if ($property.Name -notin @('Action', 'GuestPassword', 'SaPassword')) {
                            $parameters[$property.Name] = $property.Value
                        }
                    }
                    if ($request.parameters.PSObject.Properties.Name -contains 'GuestPassword') {
                        $parameters['GuestPassword'] = [string]$request.parameters.GuestPassword
                    }
                    if ($request.parameters.PSObject.Properties.Name -contains 'SaPassword') {
                        if ($request.parameters.SaPassword -isnot [string]) { throw 'UI_SA_PASSWORD_INVALID' }
                        $parameters['SaPassword'] = $request.parameters.SaPassword
                    }
                }
                if ($action -in @('NewContainerLab','NewContainerLabFromManifest')) {
                    try {
                        & (Get-Module SqlServerLab) { param($a,$p) Assert-LabSaPasswordWorkflowPreflight -Action $a -Parameters $p } $action $parameters
                    }
                    catch { throw 'UI_SA_PASSWORD_PREFLIGHT_FAILED' }
                }
                $hasTransientSecret = $parameters.ContainsKey('GuestPassword') -or $parameters.ContainsKey('SaPassword')
                if ($action -ieq 'InstallHyperVLabSqlSlot') {
                    $slotRun = [guid]::Empty
                    if ($action -cne 'InstallHyperVLabSqlSlot' -or $parameters.Count -ne 2 -or
                        $parameters['RunId'] -isnot [string] -or -not [guid]::TryParseExact($parameters['RunId'], 'D', [ref]$slotRun) -or $slotRun -eq [guid]::Empty -or
                        $parameters['ExpectedPlanKey'] -isnot [string] -or $parameters['ExpectedPlanKey'] -cnotmatch '^[a-f0-9]{64}$') {
                        throw 'HYPERV_LAB_SQL_INSTALL_BROWSER_REQUEST_INVALID'
                    }
                }
                if ($action -eq 'ReadFullMaintenancePreview') {
                    if ($parameters.Count -ne 0) { throw 'FULL_MAINTENANCE_PREVIEW_ARGUMENTS_INVALID' }
                    if (@($jobs.Values | Where-Object {
                        $_.Action -eq $action -and $_.Job.State -in @('NotStarted','Running')
                    }).Count) { throw 'FULL_MAINTENANCE_PREVIEW_IN_PROGRESS' }
                }
                if ($action -in @('ReadHyperVEvaluationSqlSource', 'ReadHyperVEvaluationWindowsLicense', 'ReadHyperVEvaluationTargetSqlReadiness', 'ReadHyperVEvaluationTargetStorage')) {
                    $evaluationReadKeys = @('RunId', 'InstanceId', 'DataRoot', 'ExpectedPlanKey')
                    if ($action -cin @('ReadHyperVEvaluationTargetSqlReadiness', 'ReadHyperVEvaluationTargetStorage') -or
                        ($action -ceq 'ReadHyperVEvaluationWindowsLicense' -and $parameters.Count -eq 7)) {
                        $evaluationReadKeys += @('TargetRunId', 'TargetInstanceId', 'ExpectedTargetPlanKey')
                    }
                    if ($action -cnotin @('ReadHyperVEvaluationSqlSource', 'ReadHyperVEvaluationWindowsLicense', 'ReadHyperVEvaluationTargetSqlReadiness', 'ReadHyperVEvaluationTargetStorage') -or
                        $parameters.Count -ne $evaluationReadKeys.Count -or
                        $evaluationReadKeys.Where({ $parameters[$_] -isnot [string] }).Count -gt 0) {
                        throw 'EVALUATION_REFRESH_INPUT_INVALID'
                    }
                    if (@($jobs.Values | Where-Object { $_.Action -ceq $action -and $_.Job.State -in @('NotStarted','Running') }).Count) {
                        if ($action -ceq 'ReadHyperVEvaluationSqlSource') { throw 'EVALUATION_REFRESH_SQL_SOURCE_ALREADY_RUNNING' }
                        if ($action -ceq 'ReadHyperVEvaluationTargetSqlReadiness') { throw 'EVALUATION_REFRESH_TARGET_SQL_ALREADY_RUNNING' }
                        if ($action -ceq 'ReadHyperVEvaluationTargetStorage') { throw 'EVALUATION_REFRESH_TARGET_STORAGE_ALREADY_RUNNING' }
                        throw 'EVALUATION_REFRESH_WINDOWS_READ_ALREADY_RUNNING'
                    }
                }
                # A confirmed power plan is a one-shot request: never replay it through batch recovery.
                if ($action -eq 'CreateLinuxTestGroupMember' -and ($parameters.Count -notin @(3,4) -or
                    $parameters['Provider'] -isnot [string] -or $parameters['SqlVersion'] -isnot [string] -or
                    ($parameters.Count -eq 4 -and $parameters['TestGroupPatch'] -isnot [string]) -or
                    $parameters['ExpectedPlanKey'] -isnot [string])) { throw 'TEST_GROUP_LINUX_CREATE_ACTION_INVALID' }
                $groupManagement = $action -in @('CreateWindowsTestGroupMember','RepairTestGroup','RemoveTestGroup','ExportTestGroup')
                if ($groupManagement) {
                    $expectedCount = if ($action -eq 'CreateWindowsTestGroupMember') { 2 } else { 1 }
                    if ($parameters.Count -ne $expectedCount -or $parameters['ExpectedPlanKey'] -isnot [string] -or
                        ($expectedCount -eq 2 -and $parameters['ArtifactId'] -isnot [string])) {
                        throw 'TEST_GROUP_MANAGEMENT_ACTION_INVALID'
                    }
                }
                if (-not $hasTransientSecret -and -not $groupManagement -and $action -notin @('Refresh','StartTestGroupPower','StopTestGroupPower','CreateLinuxTestGroupMember','ReadFullMaintenancePreview','ReadHyperVEvaluationSqlSource','ReadHyperVEvaluationWindowsLicense','ReadHyperVEvaluationTargetSqlReadiness','ReadHyperVEvaluationTargetStorage')) {
                    # Retain terminal cards for this server session; bound reads without evicting results.
                    if ($persistentJobs.Count -ge 256) { throw 'UI_JOB_STATUS_CAPACITY_REACHED' }
                    $batchStateRoot = & (Get-Module SqlServerLab) { Get-LabStateRoot }
                    $resourceClass = if ($action -match 'WindowsBuild|SqlBuild|HyperVLab|HyperVImage') { 'HyperVHeavy' } elseif ($action -match 'MediaRoot|DataRoot|Storage') { 'ExclusiveStorage' } else { 'LifecycleLight' }
                    $targetId = if ($action -ceq 'InstallHyperVLabSqlSlot') { $slotRun.ToString() } elseif ($parameters.ContainsKey('BuildId')) { [string]$parameters.BuildId } elseif ($parameters.ContainsKey('ArtifactId')) { [string]$parameters.ArtifactId } elseif ($parameters.ContainsKey('LabName')) { [string]$parameters.LabName } else { $action }
                    $batch = New-SqlServerLabBatch -StateRoot $batchStateRoot -Name "Browser: $action" -Items @([pscustomobject]@{
                        id = ("ui-$action-" + [guid]::NewGuid().ToString('n').Substring(0, 6)).ToLowerInvariant()
                        kind = 'Action'
                        count = 1
                        intent = [pscustomobject]@{
                            WorkflowAction = $action
                            WorkflowParameters = [pscustomobject]$parameters
                            ResourceClass = $resourceClass
                            Locks = @("ui-resource:$targetId")
                            ProviderPreference = 'Auto'
                        }
                    })
                    $persistentJobs[$batch.batchId] = [pscustomobject]@{
                        Id = $batch.batchId; Action = $action; StateRoot = $batchStateRoot; OperationIds = @($batch.operationIds)
                        StartedAt = [DateTime]::UtcNow.ToString('o'); HostStart = 'Requested'; TerminalSnapshot = $null
                    }
                    $hostStart = Invoke-UiOperationHostStart -StateRoot $batchStateRoot
                    $persistentJobs[$batch.batchId].HostStart = $hostStart
                    Write-UiResponse -Context $context -Body (@{ id = $batch.batchId; action = $action; persistent = $true; state = 'Accepted'; hostStart = $hostStart } | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                    continue
                }
                # Geheimnisse werden niemals im persistenten Batch abgelegt.
                $record = Start-UiWorkflowJob -Action $action -Parameters $parameters
                $jobs[$record.Id] = $record
                Write-UiResponse -Context $context -Body (@{ id = $record.Id; action = $action } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                continue
            }
            if ($path -eq '/api/command-grants' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request -IncludeBytes
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                try {
                    $null=Get-UiCommandGrantRequest -Body $bodyRead.Body -Catalog @(Get-UiCommandGrantCatalog)
                    $grant=New-UiCommandGrant -Store $commandGrantStore -Session $operatorSession -Request $context.Request -Bytes $bodyRead.BodyBytes
                    Write-UiResponse -Context $context -Body ($grant|ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 201
                } catch { Write-UiCommandGrantFailure -Context $context -ErrorRecord $_ }
                finally { [Array]::Clear($bodyRead.BodyBytes,0,$bodyRead.BodyBytes.Length);$bodyRead=$null;$grant=$null }
                continue
            }
            if ($path -match '^/api/command-grants/([a-f0-9]{32})(/cancel)?$') {
                $receiptId=$Matches[1];$cancel=$Matches[2] -ceq '/cancel'
                try {
                    if($cancel){
                        $bodyRead=Read-UiJsonRequestBody -Request $context.Request -MaxBytes 1024
                        if(-not $bodyRead.Allowed){Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode;continue}
                        if($bodyRead.Body -cne '{}'){throw 'UI_COMMAND_REQUEST_INVALID'}
                    }
                    $receipt=Get-UiCommandGrantReceipt -Store $commandGrantStore -Session $operatorSession -Request $context.Request -ReceiptId $receiptId -Cancel:$cancel
                    Write-UiResponse -Context $context -Body ($receipt|ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiCommandGrantFailure -Context $context -ErrorRecord $_ }
                finally {$bodyRead=$null;$receipt=$null}
                continue
            }
            if ($path -eq '/api/commands' -and $context.Request.HttpMethod -eq 'POST') {
                $bodyRead = Read-UiJsonRequestBody -Request $context.Request -IncludeBytes
                if (-not $bodyRead.Allowed) {
                    Write-UiResponse -Context $context -Body $bodyRead.Code -StatusCode $bodyRead.StatusCode
                    continue
                }
                $receiptId=$null;$request=$null;$parameters=$null
                try {
                    $request=Get-UiCommandGrantRequest -Body $bodyRead.Body -Catalog @(Get-UiCommandGrantCatalog)
                    $receiptId=Use-UiCommandGrant -Store $commandGrantStore -Session $operatorSession -Request $context.Request -Bytes $bodyRead.BodyBytes
                    $parameters=@{}
                    foreach($property in $request.parameters.PSObject.Properties){$parameters[$property.Name]=$property.Value}
                    # Consume ist unwiderruflich vor Jobanlage; Secrets bleiben flüchtig.
                    try {
                        $record=Start-UiPublicCommandJob -CommandName $request.commandName -ParameterSetName $request.parameterSetName -Parameters $parameters -Confirmed:$request.confirmed
                        $jobs[$record.Id]=$record
                        Set-UiCommandGrantOutcome -Store $commandGrantStore -ReceiptId $receiptId -JobId $record.Id
                    } catch {
                        Set-UiCommandGrantOutcome -Store $commandGrantStore -ReceiptId $receiptId -JobId $null
                        throw 'UI_COMMAND_UNCONFIRMED'
                    }
                    Write-UiResponse -Context $context -Body (@{id=$record.Id;action=$record.Action;receiptId=$receiptId}|ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                } catch { Write-UiCommandGrantFailure -Context $context -ErrorRecord $_ }
                finally { [Array]::Clear($bodyRead.BodyBytes,0,$bodyRead.BodyBytes.Length);$bodyRead=$null;$request=$null;$parameters=$null }
                continue
            }

            if ($path -match '^/api/command-grants(?:/|$)') {
                Write-UiResponse -Context $context -Body 'UI_COMMAND_GRANT_REQUIRED' -StatusCode 403
                continue
            }

            $relativePath = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
            if ($relativePath -notmatch '^[a-zA-Z0-9._-]+$') {
                Write-UiResponse -Context $context -Body 'Nicht gefunden.' -StatusCode 404
                continue
            }
            $filePath = Join-Path $uiRoot $relativePath
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Write-UiResponse -Context $context -Body 'Nicht gefunden.' -StatusCode 404
                continue
            }
            $contentType = switch ([IO.Path]::GetExtension($filePath)) {
                '.html' { 'text/html; charset=utf-8' }
                '.css' { 'text/css; charset=utf-8' }
                '.js' { 'application/javascript; charset=utf-8' }
                default { 'application/octet-stream' }
            }
            Write-UiResponse -Context $context -Body (Get-Content -LiteralPath $filePath -Raw -Encoding utf8) -ContentType $contentType
        }
        catch {
            $errorBody = if ($path -in @('/api/actions','/api/commands','/api/jobs','/api/operations') -or $path -match '^/api/command-grants(?:/|$)') { 'UI_REQUEST_UNCONFIRMED: Annahme oder Ergebnis nicht bestätigt. Status prüfen; keine automatische Wiederholung.' } else { "Fehler: " + $_.Exception.Message }
            try { Write-UiResponse -Context $context -Body $errorBody -StatusCode 500 } catch { }
        }
    }
}
finally {
    try {
    if ($jobs.Count -gt 0) { Write-Host "Beende $($jobs.Count) UI-Job(s)..." -ForegroundColor DarkGray }
    if ($workflowInventory.Job) {
        if ($workflowInventory.Job.State -eq 'Running') { Stop-Job -Job $workflowInventory.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $workflowInventory.Job -Force -ErrorAction SilentlyContinue
    }
    foreach ($record in $jobs.Values) {
        $job = $record.Job
        $state = [string]$job.State
        if ($state -eq 'Running' -or $state -eq 'NotStarted') {
            Write-Host "Job $($record.Id) ($($record.Action)) beendet: Zustand '$state'..." -ForegroundColor DarkGray
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            if (-not (Wait-Job -Job $job -Timeout $JobStopTimeoutSeconds)) {
                Write-Host "Job $($record.Id) reagierte nicht auf Stop; wird hart bereinigt." -ForegroundColor DarkYellow
            }
        }
        elseif ($state -eq 'Blocked') {
            Write-Host "Job $($record.Id) ($($record.Action)) ist blockiert; warte auf Beendigung..." -ForegroundColor DarkYellow
            if (-not (Wait-Job -Job $job -Timeout $JobStopTimeoutSeconds)) {
                Write-Host "Job $($record.Id) reagierte nicht auf Beendigung; wird hart bereinigt." -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host "Job $($record.Id) ($($record.Action)) bereits abgeschlossen (Zustand '$state')." -ForegroundColor DarkGray
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($jobs.Count -gt 0) { Write-Host 'UI-Job-Bereinigung abgeschlossen.' -ForegroundColor DarkGray }
    } finally {
        try {
            $listener.Stop()
            $listener.Close()
            if ($aiSharedGatewayBrowserSessions.Count) {
                $closed = & (Get-Module SqlServerLab) {
                    param($scope) Close-LabAiSharedGatewayBrowserSessions -BrowserSessions $scope
                } $aiSharedGatewayBrowserSessions
                if (-not $closed) { Write-Warning 'Bereinigung eigener Gateway-Sitzungen unbestätigt. Ownerkanal und Lease begrenzen den Worker.' }
            }
        }
        finally {
            try { if($commandGrantStore){Close-UiCommandGrantStore -Store $commandGrantStore} }
            finally { $null = Close-UiOperatorSession -Session $operatorSession }
        }
    }
}
