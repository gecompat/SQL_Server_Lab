# Guided, read-only SSIS diagnostics for an existing owned Windows/Hyper-V run.
function Read-LabSsisDiagnosticText {
    param([Parameter(Mandatory)][string]$Prompt,[string]$Default='',[switch]$MaskInput)
    $inputResult=Read-LabConsoleTextInput -Prompt $Prompt -Default $Default -MaskInput:$MaskInput
    if($inputResult.Status-cne'Confirmed'){throw 'SSIS_DIAGNOSTIC_CANCELLED'}
    if($inputResult.Value-isnot[string]){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
    [string]$inputResult.Value
}

function Assert-LabSsisDiagnosticGuid {
    param([Parameter(Mandatory)][string]$Value)
    $parsed=[guid]::Empty
    if(-not[guid]::TryParseExact($Value,'D',[ref]$parsed)-or$parsed-eq[guid]::Empty){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
    $parsed
}

function Assert-LabSsisDiagnosticInstanceId {
    param([Parameter(Mandatory)][string]$Value)
    if($Value-cnotmatch'^[A-Za-z][A-Za-z0-9_-]{0,63}$'){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
    $Value
}

function ConvertTo-LabSsisDiagnosticPositiveInt64 {
    param([Parameter(Mandatory)][string]$Value)
    $parsed=[long]0
    if($Value-cnotmatch'^[1-9][0-9]{0,18}$'-or-not[long]::TryParse($Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)-or$parsed-le0){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
    $parsed
}

function ConvertTo-LabSsisDiagnosticTimeout {
    param([Parameter(Mandatory)][string]$Value)
    $parsed=0
    if($Value-cnotmatch'^[0-9]{1,3}$'-or-not[int]::TryParse($Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)-or$parsed-lt10-or$parsed-gt120){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
    $parsed
}

function Write-LabSsisDiagnosticSummary {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][ValidateSet('Package','Execution')][string]$Kind)
    if($Result-isnot[pscustomobject]){throw 'SSIS_DIAGNOSTIC_RESULT_INVALID'}
    foreach($name in @('Status','ReasonCode')){
        if($Result.$name-isnot[string]-or([string]$Result.$name-cnotmatch'^[A-Z][A-Z0-9_]{0,63}$')){throw 'SSIS_DIAGNOSTIC_RESULT_INVALID'}
    }
    Write-LabInfo ("SSIS-Diagnose: {0} · {1}"-f$Result.Status,$Result.ReasonCode)
    if($null-eq$Result.Observation){return}
    if($Kind-ceq'Package'){
        $observation=$Result.Observation
        $events=@($observation.Events|ForEach-Object {"$($_.Kind):$($_.Code)"})-join', '
        if(-not$events){$events='keine numerischen Ereigniscodes'}
        $version=if($observation.Runtime.FileVersion-is[string]){$observation.Runtime.FileVersion}else{'unbekannt'}
        $load=if($observation.LoadStatus-is[string]){$observation.LoadStatus}else{'unbekannt'}
        Write-LabInfo ("SSIS-Runtime: {0} · Paketladung: {1} · numerische Ereignisse: {2}"-f$version,$load,$events)
        Write-LabInfo 'Begrenzte Beobachtung; kein Paketstart, keine SQL-Verbindung und kein Funktionsnachweis.'
    }else{
        $observation=$Result.Observation
        $snapshot=if($observation.Snapshot.ObservedExecutionStatus-is[int]){$observation.Snapshot.ObservedExecutionStatus}else{'unbekannt'}
        $worker=if($observation.Worker.Status-is[string]){$observation.Worker.Status}else{'unbekannt'}
        $codes=@($observation.ErrorCodes|ForEach-Object {[string]$_})-join', '
        if(-not$codes){$codes='keine beobachteten Fehlercodes'}
        Write-LabInfo ("Katalogstatus: {0} · Worker: {1} · Fehlercodes: {2}"-f$snapshot,$worker,$codes)
        Write-LabInfo 'Read-only-Metadaten; kein Paketstart, keine Reparatur und keine Funktionsabnahme.'
    }
}

function ConvertTo-LabSsisCatalogCapabilitySummary {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$InstanceId)

    if ($Result.ContractVersion -cne 'SqlServerLab.SsisCatalogCapability/1.0' -or $Result.ReadOnly -isnot [bool] -or -not $Result.ReadOnly -or
        $Result.Target.RunId -cne $RunId.ToString() -or $Result.Target.InstanceId -cne $InstanceId -or
        $Result.Status -cnotin @('READY_FOR_FIXTURE_IMPLEMENTATION','BLOCKED') -or
        $Result.ReasonCode -cnotin @('NONE','WINDOWS_HOST_REQUIRED','TARGET_UNAVAILABLE','BINDING_CHANGED','PROBE_UNAVAILABLE') -or
        $Result.Sql.Status -cnotin @('SQL_2019_OBSERVED','SQL_2022_OBSERVED','SQL_2025_OBSERVED','VERSION_UNSUPPORTED','UNKNOWN') -or
        $Result.Ssis.DefaultPathComponents -cnotin @('OBSERVED','NOT_OBSERVED','UNKNOWN') -or
        $Result.Ssis.Catalog -cnotin @('MISSING','NOT_ONLINE','ONLINE_UNVERIFIED','ONLINE_CATALOG_OBSERVED','UNKNOWN')) {
        throw 'SSIS_DIAGNOSTIC_RESULT_INVALID'
    }
    [pscustomobject]@{
        Status = $Result.Status
        Reason = $Result.ReasonCode
        Sql = $Result.Sql.Status
        Components = $Result.Ssis.DefaultPathComponents
        Catalog = $Result.Ssis.Catalog
    }
}

function Invoke-LabSsisCatalogCapabilityInteractive {
    $stateRoot = Get-LabStateRoot
    $items = [Collections.Generic.List[object]]::new()
    foreach ($run in @(Get-LabActiveRuns -StateRoot $stateRoot -NoWrite)) {
        if ($run.state -cne 'RUNNING' -or $run.metadata.workflowKind -cne 'hyperv-lab') { continue }
        try {
            $runId = Assert-LabSsisDiagnosticGuid $run.runId
            $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $runId.ToString()) 'connection-info.json'
            $connection = Read-LabDiagnosticJson -Path $connectionPath
        } catch { continue }
        foreach ($instance in @($connection.instances)) {
            if ($instance.provider -cne 'hyperv' -or $instance.workload -cne 'sql' -or $instance.sqlVersion -cnotin @('2019','2022','2025') -or
                $instance.id -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { continue }
            $label = ([string]$run.metadata.name -replace '[\p{C}]','').Trim()
            if (-not $label) { $label = 'Run '+$runId.ToString().Substring(0,8) }
            $items.Add((New-LabConsoleItem -Id "$runId/$($instance.id)" -Label $label -Value "SQL $($instance.sqlVersion) · $($instance.id)" -Data @{
                RunId=$runId; InstanceId=[string]$instance.id; StateRoot=$stateRoot
            }))
        }
    }
    if (-not $items.Count) { Write-LabWarning 'Keine laufende registrierte Hyper-V-SQL-Instanz gefunden.'; return }
    $items.Add((New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen' -Shortcut 0))
    $selected = Invoke-LabConsoleMenu -ScreenId 'ssis-catalog-capability-target' -Title 'SSIS-Katalogvoraussetzungen' -Items $items.ToArray()
    if ($selected.Status -cne 'Selected' -or $selected.SelectedItem.Id -ceq 'back') { return }
    $target = $selected.SelectedItem.Data
    if (-not (Read-LabConfirm -Prompt "SSIS-Katalogvoraussetzungen für $($selected.SelectedItem.Label) / $($target.InstanceId) lesen?" -Default $false)) { return }
    $observed = Get-SqlServerLabSsisCatalogCapability @target
    $view = ConvertTo-LabSsisCatalogCapabilitySummary -Result $observed -RunId $target.RunId -InstanceId $target.InstanceId
    Write-LabInfo ("SSIS-Katalog: {0} · SQL: {1} · Komponenten: {2} · Katalogstatus: {3}" -f $view.Status,$view.Sql,$view.Components,$view.Catalog)
    if ($view.Reason -cne 'NONE') { Write-LabWarning $view.Reason }
    Write-LabInfo 'Gelesen werden die Voraussetzungen. Die Abnahme einer SSIS-Ausführung ist eine eigene Prüfung.'
}

function Invoke-LabSsisDiagnosticsInteractive {
    [CmdletBinding()]
    param()
    $arguments=@{}
    try{
        $kindChoice=Invoke-LabConsoleMenu -ScreenId 'ssis-diagnostic-kind' -Title 'SSIS-Diagnose am bestehenden Windows-Lab' `
            -Subtitle 'Nur eigene laufende Hyper-V-Runs. Wähle die benötigte SSIS-Beobachtung.' -Items @(
                New-LabConsoleItem -Id Capability -Label 'SSIS-Katalogvoraussetzungen prüfen'
                New-LabConsoleItem -Id Package -Label 'Eigenes DTSX/ISPAC im Gast laden und Komponenten beobachten'
                New-LabConsoleItem -Id Execution -Label 'Bestehende SQL-2025-SSISDB-Ausführung read-only beobachten'
                New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen' -Shortcut 0
            )
        if($kindChoice.Status-cne'Selected'-or$kindChoice.SelectedItem.Id-ceq'back'){return}
        if ($kindChoice.SelectedItem.Id -ceq 'Capability') {
            Invoke-LabSsisCatalogCapabilityInteractive
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        if($kindChoice.SelectedItem.Id-cnotin@('Package','Execution')){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
        $kind=[string]$kindChoice.SelectedItem.Id
        $runId=Assert-LabSsisDiagnosticGuid (Read-LabSsisDiagnosticText -Prompt 'RunId des bereits laufenden eigenen Windows-/Hyper-V-Labs')
        $instance=Assert-LabSsisDiagnosticInstanceId (Read-LabSsisDiagnosticText -Prompt 'Registrierte Instanz-ID' -Default 'primary')
        $timeout=ConvertTo-LabSsisDiagnosticTimeout (Read-LabSsisDiagnosticText -Prompt 'Transportfrist in Sekunden (10–120)' -Default '60')
        if($kind-ceq'Package'){
            $formatChoice=Invoke-LabConsoleMenu -ScreenId 'ssis-diagnostic-package-format' -Title 'Vertrauenswürdiges eigenes SSIS-Paket' `
                -Subtitle 'LoadFromXML ist keine Sandbox: Komponenten können während der Deserialisierung eigenen Code laden.' -Items @(
                    New-LabConsoleItem -Id Dtsx -Label 'Einzelne DTSX-Datei'
                    New-LabConsoleItem -Id Ispac -Label 'ISPAC mit exakt benanntem Root-DTSX'
                    New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen' -Shortcut 0
                )
            if($formatChoice.Status-cne'Selected'-or$formatChoice.SelectedItem.Id-ceq'back'){return}
            if($formatChoice.SelectedItem.Id-cnotin@('Dtsx','Ispac')){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
            $path=Read-LabSsisDiagnosticText -Prompt 'Absoluter lokaler Pfad zum eigenen vertrauenswürdigen Paket' -MaskInput
            if(-not[IO.Path]::IsPathFullyQualified($path)){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
            if($formatChoice.SelectedItem.Id-ceq'Ispac'){
                $packageName=Read-LabSsisDiagnosticText -Prompt 'Exakter DTSX-Dateiname im ISPAC-Stammverzeichnis'
                if($packageName-cnotmatch'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\.dtsx$'){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
                $arguments.IspacPath=$path;$arguments.PackageName=$packageName
            }else{$arguments.PackagePath=$path}
            $hash=Read-LabSsisDiagnosticText -Prompt 'Erwarteter SHA-256 aus der eigenen lokalen Receipt'
            if($hash-cnotmatch'^[A-Fa-f0-9]{64}$'){throw 'SSIS_DIAGNOSTIC_INPUT_INVALID'}
            $arguments.ExpectedSha256=$hash;$arguments.RunId=$runId;$arguments.InstanceId=$instance;$arguments.TimeoutSeconds=$timeout
            Write-LabWarning 'Paketdiagnose lädt ausschließlich ein eigenes vertrauenswürdiges Paket im Arbeitsspeicher. Keine Sandbox; unbekannte Pakete nicht verwenden.'
            if(-not(Read-LabConfirm -Prompt 'Paket ist synthetisch, vertrauenswürdig und exakt an die angegebene Receipt gebunden?' -Default $false)){return}
            $result=Get-SqlServerLabSsisPackageDiagnostic @arguments
        }else{
            $executionId=ConvertTo-LabSsisDiagnosticPositiveInt64 (Read-LabSsisDiagnosticText -Prompt 'Execution-ID aus der eigenen SSISDB-Receipt')
            $projectLsn=ConvertTo-LabSsisDiagnosticPositiveInt64 (Read-LabSsisDiagnosticText -Prompt 'Projekt-LSN aus derselben Receipt')
            $catalogId=Assert-LabSsisDiagnosticGuid (Read-LabSsisDiagnosticText -Prompt 'SSISDB-Katalogdatenbank-GUID aus derselben Receipt')
            $arguments=@{RunId=$runId;InstanceId=$instance;ExecutionId=$executionId;ExpectedProjectLsn=$projectLsn;ExpectedCatalogDatabaseGuid=$catalogId;TimeoutSeconds=$timeout}
            if(-not(Read-LabConfirm -Prompt 'Gebundene SQL-2025-SSISDB-Metadaten read-only beobachten?' -Default $false)){return}
            $result=Get-SqlServerLabSsisExecutionDiagnostic @arguments
        }
        Write-LabSsisDiagnosticSummary -Result $result -Kind $kind
    }catch{
        if($_.Exception.Message-ceq'SSIS_DIAGNOSTIC_CANCELLED'){return}
        $message=[string]$_.Exception.Message
        $code=if($message-cmatch'^SSIS_[A-Z0-9_]{1,80}$'){$message}else{'SSIS_DIAGNOSTIC_UNAVAILABLE'}
        Write-LabWarning ("{0}: Keine Bestätigung; keine Mutation ausgeführt."-f$code)
    }finally{
        $arguments.Clear();$result=$null;$path=$null;$hash=$null;$packageName=$null
    }
    $null=Wait-LabConsoleAcknowledgement
}
