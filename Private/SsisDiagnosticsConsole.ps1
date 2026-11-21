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

function Invoke-LabSsisDiagnosticsInteractive {
    [CmdletBinding()]
    param()
    $arguments=@{}
    try{
        $kindChoice=Invoke-LabConsoleMenu -ScreenId 'ssis-diagnostic-kind' -Title 'SSIS-Diagnose am bestehenden Windows-Lab' `
            -Subtitle 'Nur eigene laufende Hyper-V-Runs. Beide Wege beobachten; sie starten oder reparieren nichts.' -Items @(
                New-LabConsoleItem -Id Package -Label 'Eigenes DTSX/ISPAC im Gast laden und Komponenten beobachten'
                New-LabConsoleItem -Id Execution -Label 'Bestehende SQL-2025-SSISDB-Ausführung read-only beobachten'
                New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen' -Shortcut 0
            )
        if($kindChoice.Status-cne'Selected'-or$kindChoice.SelectedItem.Id-ceq'back'){return}
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
