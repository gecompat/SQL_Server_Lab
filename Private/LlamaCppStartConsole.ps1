# Guided explicit Start only; ownership and cleanup remain in the existing public core.
function Select-LabGuidedLlamaValue {
    param([string]$Title,[string[]]$Allowed)
    $choice=Invoke-LabConsoleMenu -ScreenId 'llama-guided-start-choice' -Title $Title -Subtitle 'Esc: Abbruch. Noch kein Dateizugriff.' -Items @($Allowed|ForEach-Object {New-LabConsoleItem -Id $_ -Label $_})
    if($choice.Status -ne 'Selected'){return $null}
    if($choice.SelectedItem.Id -isnot [string]){throw 'LLAMA_GUIDED_INPUT_INVALID'}
    $match=@($Allowed|Where-Object {$_ -ceq $choice.SelectedItem.Id})
    if($match.Count -ne 1){throw 'LLAMA_GUIDED_INPUT_INVALID'}
    $match[0]
}

function Assert-LabGuidedLlamaResult {
    param([object]$Result,[hashtable]$Arguments)
    $names=@('Contract','OperationId','Status','Backend','Accelerator','ModelName','Dimension','Location','ServerCertificateSha256','LeaseSeconds','ArtifactEvidence','CandidateId','SelectionMode','RuntimeSelectors')
    if($Result -isnot [pscustomobject] -or @(Compare-Object ($names|Sort-Object) ($Result.PSObject.Properties.Name|Sort-Object)).Count -or
        @($Result.PSObject.Properties|Where-Object {$_.MemberType -ne 'NoteProperty'}).Count){throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
    foreach($name in @('Contract','OperationId','Status','Backend','Accelerator','ModelName','Location','ServerCertificateSha256','SelectionMode')){
        if($Result.$name -isnot [string]){throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
    }
    if($Result.Contract -cne 'SqlServerLab.LlamaCppOwnedRuntime/1.0' -or $Result.Status -cne 'ENDPOINT_VERIFIED' -or
        $Result.Backend -cne $Arguments.Backend -or $Result.Accelerator -cne $Arguments.Accelerator -or $Result.ModelName -cne $Arguments.ModelName -or
        $Result.Dimension -isnot [int] -or $Result.Dimension -ne $Arguments.Dimension -or $Result.LeaseSeconds -isnot [int] -or $Result.LeaseSeconds -ne $Arguments.LeaseSeconds -or
        $Result.Location -cne "https://127.0.0.1:$($Arguments.Port)/v1/embeddings" -or $Result.ServerCertificateSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $null -ne $Result.ArtifactEvidence -or $null -ne $Result.CandidateId -or $Result.SelectionMode -cne 'EXPLICIT_LEGACY' -or
        $Result.OperationId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
    $selector=if($Arguments.Backend -ceq 'LlamaCppOpenVino'){'OPENVINO0'}elseif($Arguments.Accelerator -ceq 'CPU'){'none'}else{'CUDA0'}
    if($Result.RuntimeSelectors -isnot [array] -or $Result.RuntimeSelectors.Count -ne 1 -or $Result.RuntimeSelectors[0] -isnot [string] -or $Result.RuntimeSelectors[0] -cne $selector){throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
    # This is only a reference to the session already owned by this exact module.
    if(-not $script:LlamaCppOwnedSessions -or -not $script:LlamaCppOwnedSessions.ContainsKey($Result.OperationId) -or
        $script:LlamaCppOwnedSessions[$Result.OperationId] -isnot [Collections.IDictionary] -or $script:LlamaCppOwnedSessions[$Result.OperationId].Port -isnot [int] -or
        $script:LlamaCppOwnedSessions[$Result.OperationId].Port -ne $Arguments.Port){throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
}

function Invoke-LabLlamaCppStartInteractive {
    [CmdletBinding()]
    param()
    $arguments=@{};$ownedKey=$null;$dispatched=$false
    try {
        Write-LabInfo 'Eigene llama.cpp-Sitzung für SQL-Embeddings: explizite Eingaben, danach bewusste Bestätigung. Noch keine Dateien oder Runtime geprüft.'
        foreach($field in @('RuntimeDirectory','ModelPath','CertificatePath','PrivateKeyPath','TrustedRootPath')){
            $prompt=if($field -ceq 'TrustedRootPath'){'Optionales öffentliches CA-PEM (leer: Systemvertrauen)'}else{"${field}: expliziter lokaler Pfad"}
            $inputResult=Read-LabConsoleTextInput -Prompt ($prompt+' (max. 4096 Zeichen; maskiert)') -MaskInput
            if($inputResult.Status -ne 'Confirmed'){return}
            if($inputResult.Value -isnot [string] -or $inputResult.Value.Length -gt 4096 -or ($field -cne 'TrustedRootPath' -and [string]::IsNullOrWhiteSpace($inputResult.Value))){throw 'LLAMA_GUIDED_INPUT_INVALID'}
            if(-not [string]::IsNullOrWhiteSpace($inputResult.Value)){$arguments[$field]=$inputResult.Value}
        }
        foreach($field in @(@{Name='Backend';Values=@('LlamaCppCuda','LlamaCppOpenVino')},@{Name='Accelerator';Values=@('CPU','GPU','NPU')},@{Name='Pooling';Values=@('mean','cls','last')})){
            $value=Select-LabGuidedLlamaValue -Title $field.Name -Allowed $field.Values
            if($null -eq $value){return};$arguments[$field.Name]=$value
        }
        if($arguments.Backend -ceq 'LlamaCppCuda' -and $arguments.Accelerator -ceq 'NPU'){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        $inputResult=Read-LabConsoleTextInput -Prompt 'Modellalias: 1 bis 128 ASCII-Buchstaben/Ziffern sowie Punkt, Unterstrich, Bindestrich' -MaskInput
        if($inputResult.Status -ne 'Confirmed'){return}
        if($inputResult.Value -isnot [string] -or $inputResult.Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        $arguments.ModelName=$inputResult.Value
        foreach($field in @(
            @{Name='Dimension';Min=1;Max=1998;Default=''},@{Name='Port';Min=1024;Max=65535;Default=''},
            @{Name='StartTimeoutSeconds';Min=1;Max=600;Default='120'},@{Name='LeaseSeconds';Min=30;Max=3600;Default='900'},@{Name='ContextSize';Min=32;Max=8192;Default='512'})){
            $inputResult=Read-LabConsoleTextInput -Prompt ("{0}: {1} bis {2}" -f $field.Name,$field.Min,$field.Max) -Default $field.Default
            if($inputResult.Status -ne 'Confirmed'){return}
            $number=0
            if($inputResult.Value -isnot [string] -or $inputResult.Value -cnotmatch '^[0-9]{1,5}$' -or -not [int]::TryParse($inputResult.Value,[ref]$number) -or $number -lt $field.Min -or $number -gt $field.Max){throw 'LLAMA_GUIDED_INPUT_INVALID'}
            $arguments[$field.Name]=$number
        }
        if($arguments.LeaseSeconds -le $arguments.StartTimeoutSeconds){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        $inputResult=Read-LabConsoleTextInput -Prompt 'API-Key: 24 bis 256 ASCII-Buchstaben/Ziffern, Unterstrich oder Bindestrich (SecureString)' -AsSecureString
        if($inputResult.Status -ne 'Confirmed'){return}
        if($inputResult.Value -isnot [Security.SecureString]){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        $ownedKey=$inputResult.Value
        if($ownedKey.Length -lt 24 -or $ownedKey.Length -gt 256){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        $arguments.ApiKey=$ownedKey
        Write-LabInfo ("Backend: {0} · Accelerator: {1} · Dimension: {2} · Pooling: {3} · Port: {4} · Startbudget: {5}s · Lease: {6}s · Kontext: {7}" -f $arguments.Backend,$arguments.Accelerator,$arguments.Dimension,$arguments.Pooling,$arguments.Port,$arguments.StartTimeoutSeconds,$arguments.LeaseSeconds,$arguments.ContextSize)
        Write-LabInfo 'Pfade und API-Key gesetzt. Der Start liest Runtime/Modell/Zertifikat/Key, prüft Loopback-Port, TLS, Gerät und Embeddings und erstellt eigene temporäre Key-/Request-/Logdateien sowie einen Worker. Lease und Ownerverlust begrenzen die eigene Sitzung. Keine Downloads, Hosttrust- oder Dienständerung. Gleichen Modulhost behalten; Stop bleibt separat. SQL-Funktion nicht geprüft.'
        $choice=Invoke-LabConsoleMenu -ScreenId 'llama-guided-start-confirm' -Title 'Eigene llama.cpp-Sitzung' -Subtitle 'Noch kein Dateizugriff. Vorschau ist keine Startfreigabe.' -Items @(
            New-LabConsoleItem -Id start -Label 'Eigene Sitzung starten (mit Bestätigung)'
            New-LabConsoleItem -Id whatif -Label 'WhatIf: keine Ausführung oder Bereitschaftsprüfung'
            New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen'
        )
        if($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -ceq 'back'){return}
        if($choice.SelectedItem.Id -isnot [string]){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        if($choice.SelectedItem.Id -ceq 'whatif'){
            $null=Start-SqlServerLabLlamaCppRuntime @arguments -WhatIf
            Write-LabInfo 'WhatIf: kein Start und keine Bereitschaftsprüfung.'
            return
        }
        if($choice.SelectedItem.Id -cne 'start'){throw 'LLAMA_GUIDED_INPUT_INVALID'}
        if(-not (Read-LabConfirm -Prompt 'Genau diese eigene zeitlich begrenzte Sitzung starten und temporären API-Key anlegen?' -Default $false)){return}
        $dispatched=$true
        # Do not override the public command's natural ShouldProcess/Confirm behavior.
        $results=@(Start-SqlServerLabLlamaCppRuntime @arguments)
        if($results.Count -ne 1){throw 'LLAMA_GUIDED_RESULT_UNCONFIRMED'}
        Assert-LabGuidedLlamaResult -Result $results[0] -Arguments $arguments
        Write-LabInfo ('ENDPOINT_VERIFIED · eigene Sitzung: '+$results[0].OperationId+' · SQL: NOT_CHECKED. Gleichen Modulhost behalten; eigenen Stop separat auswählen.')
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
        $code=[string]$_.Exception.Message
        if($code.StartsWith('LLAMA_RECOVERY_REQUIRED; OperationId=',[StringComparison]::Ordinal)){
            Write-LabWarning 'RECOVERY_REQUIRED: eigenes Ende/Cleanup unbestätigt. Nicht automatisch wiederholen. Modulhost behalten und bestehende eigene Sitzungsführung bewusst verwenden.'
        } elseif($code -ceq 'LLAMA_GUIDED_INPUT_INVALID' -and -not $dispatched){
            Write-LabWarning 'Eingabe ungültig. Feste Auswahl und angezeigte Grenzen verwenden; nichts gestartet.'
        } else {
            Write-LabWarning 'Start nicht bestätigt; eine eigene Sitzung könnte aktiv sein. Kein automatischer Stop, Retry oder Cleanup-Erfolg. Modulhost behalten und bestehende eigene Sitzungsführung bewusst verwenden.'
        }
    } finally {
        $arguments.Clear();$inputResult=$null;$results=$null
        if($ownedKey){$ownedKey.Dispose();$ownedKey=$null}
    }
}
