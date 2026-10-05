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

function Write-UiResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-UiCapabilityConfig {
    $getSecretCommand = Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
    $secretAvailable = $null -ne $getSecretCommand
    [PSCustomObject]@{
        jobLogBurstLimit = $JobLogBurstLimit
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
            if ($snapshot.Count -gt 0) { $workflowInventory.Snapshot = $snapshot[-1] }
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
            Get-SqlServerLabWorkflow -MediaRoot $JobMediaRoot
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
    $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
    try {$buffer=[char[]]::new(4097);$length=$reader.ReadBlock($buffer,0,$buffer.Length);if($length -gt 4096){throw 'CMS_INSPECTION_REQUEST_INVALID'};$payload=([string]::new($buffer,0,$length))|ConvertFrom-Json -Depth 5 -ErrorAction Stop}finally{$reader.Dispose()}
    if($payload -isnot [pscustomobject] -or $payload.action -cne 'InspectCms' -or $payload.parameters -isnot [pscustomobject] -or @($payload.PSObject.Properties.Name|Where-Object {$_ -cnotin @('action','parameters')}).Count -or
        @($payload.parameters.PSObject.Properties).Count -ne 1 -or $payload.parameters.ExpectedPlanKey -isnot [string] -or $payload.parameters.ExpectedPlanKey -cnotmatch '^[a-f0-9]{64}$'){throw 'CMS_INSPECTION_REQUEST_INVALID'}
    Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $payload.parameters.ExpectedPlanKey
}

function Invoke-UiInitialSetupRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)

    if ($Request.HttpMethod -eq 'GET') { return Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState }
    if ($Request.HttpMethod -ne 'POST' -or $Request.ContentType -notmatch '^application/json(?:;|$)') { throw 'INITIAL_SETUP_REQUEST_INVALID' }
    $origin = [string]$Request.Headers['Origin']
    if ($origin -and $origin -ne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'INITIAL_SETUP_ORIGIN_INVALID' }
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $buffer = [char[]]::new(16385)
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 16384) { throw 'INITIAL_SETUP_REQUEST_TOO_LARGE' }
        $payload = ([string]::new($buffer, 0, $length)) | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    }
    finally { $reader.Dispose() }
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
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $buffer = [char[]]::new(16385)
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 16384) { throw 'SLOT_RESERVE_REQUEST_TOO_LARGE' }
        $payload = ([string]::new($buffer, 0, $length)) | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    }
    finally { $reader.Dispose() }
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
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $buffer = [char[]]::new(1025)
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 1024) { throw 'RESOURCE_WATCH_REQUEST_TOO_LARGE' }
        $payload = ([string]::new($buffer, 0, $length)) | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    } finally { $reader.Dispose() }
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
    $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
    try{$buffer=[char[]]::new(1025);$length=$reader.ReadBlock($buffer,0,1025);if($length -gt 1024){throw 'LLAMA_INSTALL_REQUEST_LIMIT'};$body=([string]::new($buffer,0,$length))|ConvertFrom-Json -Depth 4}finally{$reader.Dispose()}
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
    $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
    try {
        $buffer=[char[]]::new(1025);$length=$reader.ReadBlock($buffer,0,$buffer.Length)
        if ($length -gt 1024) { throw 'LLAMA_SESSION_REQUEST_TOO_LARGE' }
        $payload=([string]::new($buffer,0,$length)) | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    } finally { $reader.Dispose() }
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
    $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
    try {
        $buffer=[char[]]::new(1025); $length=$reader.ReadBlock($buffer,0,$buffer.Length)
        if ($length -gt 1024) { throw 'MAINTENANCE_REQUEST_TOO_LARGE' }
        $payload=([string]::new($buffer,0,$length)) | ConvertFrom-Json -Depth 4 -ErrorAction Stop
    } finally { $reader.Dispose() }
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
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $buffer = [char[]]::new(16385)
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 16384) { throw 'MEDIA_SOURCE_OVERRIDE_REQUEST_TOO_LARGE' }
        $payload = ([string]::new($buffer, 0, $length)) | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    }
    finally { $reader.Dispose() }
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
$listener.Start()
$jobs = @{}
$persistentJobs = @{}

Write-Host "SQL_Server_Lab Workflow UI: $url" -ForegroundColor Green
Write-Host 'Zum Beenden Strg+C druecken.' -ForegroundColor DarkGray
Write-Host "Job-Stop-Timeout beim Beenden: ${JobStopTimeoutSeconds}s (Parameter: -JobStopTimeoutSeconds)." -ForegroundColor DarkGray
Write-Host "Log-Burst-Limit pro Snapshot: ${JobLogBurstLimit} Zeilen (Parameter: -JobLogBurstLimit)." -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

try {
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

            $path = $context.Request.Url.AbsolutePath
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
                    $code=if($_.Exception.Message -cin @('EVALUATION_REFRESH_HTTP_INVALID','EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_INPUT_INVALID','EVALUATION_REFRESH_MODE_INVALID','EVALUATION_REFRESH_BINDING_UNAVAILABLE')){$_.Exception.Message}else{'EVALUATION_REFRESH_BINDING_UNAVAILABLE'}
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
            if ($path -eq '/api/cms-inspection') {
                try {$result=Invoke-UiCmsInspectionRequest -Request $context.Request;Write-UiResponse -Context $context -Body ($result|ConvertTo-Json -Depth 6) -ContentType 'application/json; charset=utf-8'}
                catch {Write-UiResponse -Context $context -Body 'CMS_INSPECTION_REQUEST_FAILED: Registrierung und Auswahl erneut lesen.' -StatusCode 400}
                continue
            }
            if ($path -eq '/api/initial-setup') {
                try {
                    $result = Invoke-UiInitialSetupRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                }
                catch {
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
                    Write-UiResponse -Context $context -Body 'SLOT_RESERVE_REQUEST_FAILED: Eingaben und aktuellen Zustand erneut prüfen.' -StatusCode 400
                }
                continue
            }
            if ($path -eq '/api/resource-watch') {
                try {
                    $result = Invoke-UiResourceWatchRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body 'RESOURCE_WATCH_UNAVAILABLE' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/media-overrides') {
                try {
                    $result = Invoke-UiMediaOverrideRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                }
                catch {
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
                }catch{Write-UiResponse -Context $context -Body 'LLAMA_INSTALL_UNCONFIRMED: Ergebnis nicht bestätigt; frisch vorprüfen. Keine automatische Wiederholung oder Prerequisiteinstallation.' -StatusCode 400}
                continue
            }
            if ($path -eq '/api/llama-sessions') {
                try {
                    $view=Invoke-UiLlamaSessionRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 5) -ContentType 'application/json; charset=utf-8'
                } catch { Write-UiResponse -Context $context -Body 'LLAMA_SESSION_UNCONFIRMED: Stop nicht bestätigt. Neu lesen und vorprüfen; eigene Recovery separat prüfen. Keine automatische Wiederholung.' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/maintenance') {
                try {
                    $view=Invoke-UiMaintenanceRequest -Request $context.Request
                    Write-UiResponse -Context $context -Body ($view | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
                }
                catch { Write-UiResponse -Context $context -Body 'MAINTENANCE_UNCONFIRMED: Ergebnis nicht bestätigt. Erneut lesen und vorprüfen; keine automatische Wiederholung.' -StatusCode 400 }
                continue
            }
            if ($path -eq '/api/commands' -and $context.Request.HttpMethod -eq 'GET') {
                $catalog = & (Get-Module SqlServerLab) { Get-LabPublicCommandWebCatalog }
                Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject @($catalog) -Depth 12) -ContentType 'application/json; charset=utf-8'
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
            if ($path -eq '/api/ai-shared-gateway/service-secret' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                if ($body.Length -gt 1048576) { throw 'AI_SHARED_GATEWAY_UI_REQUEST_TOO_LARGE' }
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
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 30
                $batch = New-SqlServerLabBatch -Name ([string]$request.name) -Priority $(if ($request.priority) { [string]$request.priority } else { 'Normal' }) -Defaults $request.defaults -Items @($request.items) -Queue:$false
                Write-UiResponse -Context $context -Body ($batch | ConvertTo-Json -Depth 30) -ContentType 'application/json; charset=utf-8' -StatusCode 201
                continue
            }
            if ($path -eq '/api/operations' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 12
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
                $body=[IO.StreamReader]::new($context.Request.InputStream,$context.Request.ContentEncoding).ReadToEnd()
                $request=$body | ConvertFrom-Json -Depth 8
                $dataRoot=& (Get-Module SqlServerLab) { Get-LabDataRootDefault }
                $plan=Get-SqlServerLabRetainedStoreRemovalPlan -PersistentStorageId ([guid]$request.persistentStorageId) -DataRoot $dataRoot
                Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 10) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/persistent-storage/removal-plan' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
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
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 8
                $action = [string]$request.action
                if ($action -in @('NewContainerLab','NewContainerLabFromManifest')) {
                    try {
                        & (Get-Module SqlServerLab) { param($json,$a) Assert-LabSaPasswordWorkflowJsonShape -Json $json -Action $a } $body $action
                    }
                    catch { throw 'UI_SA_PASSWORD_REQUEST_INVALID' }
                }
                if ($action -in @('GetCmsInspectionState','InspectCms','GetLlamaSessions','PlanLlamaSessionStop','StopLlamaSession','GetResourceWatchState', 'RefreshResourceWatch', 'GetMediaOverrideState', 'PlanMediaOverride', 'ApplyMediaOverride', 'GetSlotReserveState', 'PlanSlotReserve', 'ApplySlotReserve', 'PlanWindowsPoolMember', 'ApplyWindowsPoolMember', 'CancelWindowsPoolMember', 'GetInitialSetupState', 'PlanInitialSetup', 'ApplyInitialSetup', 'RefreshSetupProvider', 'PlanSetupWriteability', 'ProbeSetupWriteability', 'RefreshSetupCapacity')) { throw 'INITIAL_SETUP_DIRECT_ENDPOINT_REQUIRED' }
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
                # A confirmed power plan is a one-shot request: never replay it through batch recovery.
                if (-not $hasTransientSecret -and $action -notin @('Refresh','StartTestGroupPower','StopTestGroupPower')) {
                    # Retain terminal cards for this server session; bound reads without evicting results.
                    if ($persistentJobs.Count -ge 256) { throw 'UI_JOB_STATUS_CAPACITY_REACHED' }
                    $batchStateRoot = & (Get-Module SqlServerLab) { Get-LabStateRoot }
                    $resourceClass = if ($action -match 'WindowsBuild|SqlBuild|HyperVLab|HyperVImage') { 'HyperVHeavy' } elseif ($action -match 'MediaRoot|DataRoot|Storage') { 'ExclusiveStorage' } else { 'LifecycleLight' }
                    $targetId = if ($parameters.ContainsKey('BuildId')) { [string]$parameters.BuildId } elseif ($parameters.ContainsKey('ArtifactId')) { [string]$parameters.ArtifactId } elseif ($parameters.ContainsKey('LabName')) { [string]$parameters.LabName } else { $action }
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
            if ($path -eq '/api/commands' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                if ($body.Length -gt 1048576) { throw 'PUBLIC_COMMAND_UI_REQUEST_TOO_LARGE' }
                $request = $body | ConvertFrom-Json -Depth 30
                $commandName = [string]$request.commandName
                $parameterSetName = [string]$request.parameterSetName
                if ([string]::IsNullOrWhiteSpace($commandName) -or [string]::IsNullOrWhiteSpace($parameterSetName)) {
                    throw 'PUBLIC_COMMAND_UI_COMMAND_AND_PARAMETER_SET_REQUIRED'
                }
                $parameters = @{}
                if ($request.parameters) {
                    foreach ($property in $request.parameters.PSObject.Properties) {
                        $parameters[[string]$property.Name] = $property.Value
                    }
                }
                # Generische Befehlsparameter können Geheimnisse enthalten und
                # werden deshalb ausschließlich im flüchtigen Thread-Job gehalten.
                $record = Start-UiPublicCommandJob -CommandName $commandName -ParameterSetName $parameterSetName -Parameters $parameters -Confirmed:([bool]$request.confirmed)
                $jobs[$record.Id] = $record
                Write-UiResponse -Context $context -Body (@{ id = $record.Id; action = $record.Action } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
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
            $errorBody = if ($path -in @('/api/actions','/api/commands','/api/jobs','/api/operations')) { 'UI_REQUEST_UNCONFIRMED: Annahme oder Ergebnis nicht bestätigt. Status prüfen; keine automatische Wiederholung.' } else { "Fehler: " + $_.Exception.Message }
            try { Write-UiResponse -Context $context -Body $errorBody -StatusCode 500 } catch { }
        }
    }
}
finally {
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
    $listener.Stop()
    $listener.Close()
}
