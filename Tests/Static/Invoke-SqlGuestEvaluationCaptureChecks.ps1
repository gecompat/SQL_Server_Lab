#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-guest-capture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $checks=& $module {
        param($Root)
        $script:CaptureChecks=[Collections.Generic.List[object]]::new()
        function Check {param($Name,$Passed)$script:CaptureChecks.Add([pscustomobject]@{Name=$Name;Passed=[bool]$Passed})}
        $script:CaptureId=[guid]'11111111-1111-1111-1111-111111111111';$script:CaptureVmId=[guid]'22222222-2222-2222-2222-222222222222'
        $script:CaptureRoot=$Root;$script:CaptureDirectory=Join-Path $Root "runs/$script:CaptureId"
        $null=New-Item -ItemType Directory -Path $script:CaptureDirectory -Force
        $script:CapturePath=Join-Path $script:CaptureDirectory 'sql-guest-evaluation-evidence.json'
        $script:CaptureRealProbe=${function:Invoke-LabSqlGuestCaptureProbe};$script:CaptureWrite=${function:Write-LabArtifactJsonAtomic}
        function Reset-Fixture {
            $script:CaptureMode='';$script:CaptureProbeCalls=0;$script:CaptureSecrets=0;$script:CaptureVmCalls=0
            $script:CaptureState=[pscustomobject]@{runId=$script:CaptureId.ToString();scopeId='synthetic-scope';state='RUNNING';metadata=@{workflowKind='hyperv-lab';imageArtifactId='synthetic-image'}}
            $script:CaptureInstance=[pscustomobject]@{id='primary';provider='hyperv';workload='sql';sqlVersion='2025';vmName='SyntheticVM';vmId=$script:CaptureVmId.ToString();imageArtifactId='synthetic-image';port=1433;sqlEdition='EnterpriseDeveloper';sqlReadiness=@{status='SQL_READY_RUN';majorVersion=17;instanceName='MSSQLSERVER';edition='Developer Edition (64-bit)'}}
            Save-Fixture
            if(Test-Path -LiteralPath $script:CapturePath){Remove-Item -LiteralPath $script:CapturePath -Force}
        }
        function Save-Fixture {
            & $script:CaptureWrite -Path (Join-Path $script:CaptureDirectory 'run-state.json') -InputObject $script:CaptureState
            & $script:CaptureWrite -Path (Join-Path $script:CaptureDirectory 'connection-info.json') -InputObject @{instances=@($script:CaptureInstance)}
        }
        function script:Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            $script:CaptureVmCalls++
            if($script:CaptureMode -eq 'predrift' -and $script:CaptureVmCalls -gt 1){$script:CaptureInstance.port=1434;Save-Fixture}
            [pscustomobject]@{VM=[pscustomobject]@{State='Running';Id=if($script:CaptureMode -eq 'vmid'){[guid]::NewGuid()}else{$script:CaptureVmId}};Identity=@{runId=$ExpectedRunId;scopeId=$ExpectedScopeId;instanceId='primary';childVhdxPath=(Join-Path $Root 'child.vhdx')}}
        }
        function script:Get-HyperVImageArtifact {param($StateRoot,[switch]$SkipIntegrityCheck)if(-not $SkipIntegrityCheck){throw 'CACHE_WRITE_FORBIDDEN'};[pscustomobject]@{artifactId='synthetic-image';artifactState='SQL_PREPARED_SEALED';sql=@{version='2025'};Path=(Join-Path $Root 'parent.vhdx')}}
        function script:Get-VMHardDiskDrive {param($VM)[pscustomobject]@{Path=(Join-Path $Root 'child.vhdx')}}
        function script:Get-VHD {param($Path)[pscustomobject]@{ParentPath=if($script:CaptureMode -eq 'parent'){Join-Path $Root 'foreign.vhdx'}else{Join-Path $Root 'parent.vhdx'};DiskIdentifier='synthetic-disk'}}
        function script:Get-LabSecret {param($Path,$Name)$script:CaptureSecrets++;$secret=[securestring]::new();foreach($c in 'SyntheticOnly_A7!'.ToCharArray()){$secret.AppendChar($c)};return $secret}
        function script:Invoke-LabSqlGuestCaptureProbe {
            param($Context,$TimeoutSeconds)
            $script:CaptureProbeCalls++
            if($script:CaptureMode -eq 'timeout'){throw 'SQL_GUEST_CAPTURE_PROBE_FAILED'}
            if($script:CaptureMode -eq 'postdrift'){$script:CaptureInstance.port=1434;Save-Fixture}
            $edition=if($script:CaptureMode -eq 'editiondrift'){'Enterprise Developer Edition (64-bit)'}else{[string]$script:CaptureInstance.sqlReadiness.edition}
            [pscustomobject]@{Edition=$edition;EditionId=if($script:CaptureMode -eq 'unknown'){123}else{switch($script:CaptureInstance.sqlEdition){'Evaluation'{610778273};'StandardDeveloper'{-1785266663};default{-2117995310}}};MajorVersion=if($script:CaptureMode -eq 'major'){16}else{17};InstanceName=if($script:CaptureMode -eq 'instance'){'OTHER'}else{'MSSQLSERVER'}}
        }
        function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)if($script:CaptureMode -eq 'write'){throw 'SYNTHETIC_WRITE_FAILURE'};& $script:CaptureWrite -Path $Path -InputObject $InputObject}
        function Capture {Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $script:CaptureId -StateRoot $Root -Confirm:$false}
        function Failed {param([string]$Code)$failed=$false;try{$null=Capture}catch{$failed=$_.Exception.Message -eq $Code};return $failed}
        Reset-Fixture
        $result=Capture;$reader=Get-LabSqlGuestEvaluationEvidence -RunId $script:CaptureId -StateRoot $Root
        Check 'Developer-Capture schreibt gültigen 1.0-Receipt ohne Frist' ($result.Status -eq 'UPDATED' -and $reader.Status -eq 'VALID' -and $reader.Evidence.ObservationStatus -eq 'NO_DEADLINE' -and $null -eq $reader.Evidence.EvaluationExpiresAt)
        Check 'Receipt hat genau 24 Stunden Freshness und keine vorige ID' (([datetime]$reader.Evidence.EvidenceFreshUntil-[datetime]$reader.Evidence.ObservedAt).TotalHours -eq 24 -and $null -eq $result.PreviousEvidenceId)
        $watch=ConvertTo-LabSqlGuestEvaluationWatchItem -ReaderResult $reader -RegistrationState RUNNING -Now ([datetime]::UtcNow) -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        Check 'Frische Developer-Evidence projiziert NOT_APPLICABLE' ($watch.Status -eq 'NOT_APPLICABLE')
        $second=Capture
        Check 'Wiederholter Capture bildet neue Evidence-ID und Vorgängerkette' ($second.EvidenceId -ne $result.EvidenceId -and $second.PreviousEvidenceId -eq $result.EvidenceId)
        foreach($editionCase in @(
            @{Setup='Evaluation';Observed='Enterprise Evaluation Edition (64-bit)';Classification='EVALUATION'},
            @{Setup='EnterpriseDeveloper';Observed='Developer Edition (64-bit)';Classification='NOT_EVALUATION'},
            @{Setup='StandardDeveloper';Observed='Standard Developer Edition (64-bit)';Classification='NOT_EVALUATION'}
        )){
            Reset-Fixture;$script:CaptureInstance.sqlEdition=$editionCase.Setup;$script:CaptureInstance.sqlReadiness.edition=$editionCase.Observed;Save-Fixture
            $mapped=Capture;$mappedReader=Get-LabSqlGuestEvaluationEvidence -RunId $script:CaptureId -StateRoot $Root
            Check "SQL-2025 Setupedition $($editionCase.Setup) bindet nur ihre beobachtete Familie" ($mapped.Status -eq 'UPDATED' -and $mapped.LicenseClassification -eq $editionCase.Classification -and $mappedReader.Status -eq 'VALID')
        }
        Reset-Fixture;$script:CaptureInstance.sqlEdition='Evaluation';Save-Fixture
        Check 'SQL-2025 Setupedition blockiert beobachtete fremde Editionsfamilie' ((Failed 'SQL_GUEST_CAPTURE_BINDING_INVALID') -and $script:CaptureProbeCalls -eq 0)
        Check 'SQL-2025 Setupedition blockiert beide fremden Editionsfamilien' (-not (Test-LabSqlGuestEditionBinding -SetupEdition 'Evaluation' -ObservedEdition 'Developer Edition (64-bit)' -SqlMajorVersion 17) -and -not (Test-LabSqlGuestEditionBinding -SetupEdition 'EnterpriseDeveloper' -ObservedEdition 'Standard Developer Edition (64-bit)' -SqlMajorVersion 17))
        Reset-Fixture;$script:CaptureInstance.sqlEdition='Enterprise';Save-Fixture
        Check 'Unbekannte SQL-2025 Setupedition blockiert vor Gastzugriff' ((Failed 'SQL_GUEST_CAPTURE_BINDING_INVALID') -and $script:CaptureProbeCalls -eq 0)
        Check 'Bestehende gleiche Vollnamen bleiben unabhängig von SQL-Major kompatibel' (Test-LabSqlGuestEditionBinding -SetupEdition 'Legacy Edition' -ObservedEdition 'Legacy Edition' -SqlMajorVersion 16)
        Reset-Fixture;$first=Capture;$before=[IO.File]::ReadAllBytes($script:CapturePath);$script:CaptureMode='editiondrift'
        Check 'Geänderte beobachtete Volledition blockiert die Vorgängerkette unverändert' ((Failed 'SQL_GUEST_CAPTURE_SQL_IDENTITY_CHANGED') -and [Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:CapturePath)))
        foreach($case in @(@('timeout','PROBE_FAILED'),@('unknown','EDITION_UNSUPPORTED'),@('major','SQL_IDENTITY_CHANGED'),@('instance','SQL_IDENTITY_CHANGED'),@('write','FAILED'),@('postdrift','BINDING_CHANGED'),@('predrift','BINDING_CHANGED'),@('vmid','BINDING_INVALID'),@('parent','IMAGE_INVALID'))){
            Reset-Fixture;$null=Capture;$bytes=[IO.File]::ReadAllBytes($script:CapturePath);$script:CaptureMode=$case[0]
            Check "Fehler $($case[0]) bewahrt alte Receiptbytes" ((Failed "SQL_GUEST_CAPTURE_$($case[1])") -and [Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:CapturePath)))
        }
        Reset-Fixture;[IO.File]::WriteAllText($script:CapturePath,'{"invalid":true}')
        Check 'Ungültiger vorheriger Receipt blockiert vor Gastzugriff' ((Failed 'SQL_GUEST_CAPTURE_PRIOR_INVALID') -and $script:CaptureProbeCalls -eq 0 -and [IO.File]::ReadAllText($script:CapturePath) -ceq '{"invalid":true}')
        Reset-Fixture;$null=Capture;$prior=Get-Content -LiteralPath $script:CapturePath -Raw|ConvertFrom-Json;$prior.ScopeId='foreign';& $script:CaptureWrite -Path $script:CapturePath -InputObject $prior;$script:CaptureProbeCalls=0
        Check 'Fremder vorheriger Receipt blockiert vor Gastzugriff' ((Failed 'SQL_GUEST_CAPTURE_PRIOR_INVALID') -and $script:CaptureProbeCalls -eq 0)
        Reset-Fixture
        $held=[IO.FileStream]::new((Join-Path $script:CaptureDirectory 'sql-guest-evaluation-capture.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {Check 'Exklusive Dateisperre verhindert zweiten Capture' ((Failed 'SQL_GUEST_CAPTURE_LOCKED') -and $script:CaptureProbeCalls -eq 0)}finally{$held.Dispose()}
        Reset-Fixture;$script:CaptureState.state='STOPPED';Save-Fixture
        Check 'Gestoppter Run erreicht keine Probe' ((Failed 'SQL_GUEST_CAPTURE_BINDING_INVALID') -and $script:CaptureProbeCalls -eq 0)
        Reset-Fixture;$script:CaptureInstance.sqlReadiness.edition='Enterprise Edition';Save-Fixture
        Check 'Widersprüchliche persistierte Edition wird nicht repariert' (Failed 'SQL_GUEST_CAPTURE_BINDING_INVALID')
        Reset-Fixture;$connectionPath=Join-Path $script:CaptureDirectory 'connection-info.json';& $script:CaptureWrite -Path $connectionPath -InputObject @{instances=@($script:CaptureInstance,$script:CaptureInstance)}
        Check 'Mehrere Instanzen sind ausgeschlossen' (Failed 'SQL_GUEST_CAPTURE_BINDING_INVALID')
        Reset-Fixture;$script:CaptureInstance.sqlEdition='Evaluation';$script:CaptureInstance.sqlReadiness.edition='Enterprise Evaluation Edition (64-bit)';Save-Fixture
        $classification=Get-LabSqlGuestCaptureClassification -Observation @{Edition=$script:CaptureInstance.sqlReadiness.edition;EditionId=610778273}
        Check 'Offizielle Evaluation-ID wird ohne Frist klassifiziert' ($classification -eq 'EVALUATION')
        Check 'SQL-2025 Standard Developer-ID ist bekannt' ((Get-LabSqlGuestCaptureClassification -Observation @{Edition='Standard Developer Edition (64-bit)';EditionId=-1785266663}) -eq 'NOT_EVALUATION')
        $bad=$false;try{$null=Get-LabSqlGuestCaptureClassification -Observation @{Edition='Developer Edition';EditionId=610778273}}catch{$bad=$true};Check 'Widerspruch zwischen Edition-ID und Name blockiert' $bad
        Reset-Fixture;$noRoot=Join-Path $Root 'whatif-uncreated';$null=Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $script:CaptureId -StateRoot $noRoot -WhatIf
        Check 'WhatIf erzeugt keine Dateien und öffnet weder VM noch Secrets' (-not(Test-Path -LiteralPath $noRoot) -and $script:CaptureVmCalls -eq 0 -and $script:CaptureSecrets -eq 0)
        $context=Get-LabSqlGuestCaptureContext -RunId $script:CaptureId -StateRoot $Root
        $script:CaptureInstance.port=1434;Save-Fixture;$failed=$false
        try{$null=& $script:CaptureRealProbe -Context $context -TimeoutSeconds 30}catch{$failed=$_.Exception.Message -eq 'SQL_GUEST_CAPTURE_BINDING_CHANGED'}
        Check 'Produktive Credentialgrenze revalidiert vor Secretauflösung' ($failed -and $script:CaptureSecrets -eq 0)
        Reset-Fixture;$beforeState=[IO.File]::ReadAllText((Join-Path $script:CaptureDirectory 'run-state.json'));$beforeConnection=[IO.File]::ReadAllText($connectionPath);$null=Capture
        Check 'Erfolg verändert weder Run- noch Connection-State' ($beforeState -ceq [IO.File]::ReadAllText((Join-Path $script:CaptureDirectory 'run-state.json')) -and $beforeConnection -ceq [IO.File]::ReadAllText($connectionPath))
        $link=Join-Path $Root 'linked-root';$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $Root
        try{$blocked=$false;try{Assert-LabSqlGuestCapturePath -Root $link -Path (Join-Path $link 'runs/receipt.json')}catch{$blocked=$true};Check 'Reparse am StateRoot selbst wird blockiert' $blocked}finally{Remove-Item -LiteralPath $link -Force}
        # Führt die produktiven Gast-Statements lokal aus, ohne SQL zu öffnen.
        $guestAst=$script:CaptureRealProbe.Ast.Find({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.ScriptBlock.ParamBlock -and $node.ScriptBlock.ParamBlock.Parameters.Count -eq 3 -and $node.ScriptBlock.ParamBlock.Parameters[0].Name.VariablePath.UserPath -eq 'Password'},$true)
        $guestTry=$guestAst.ScriptBlock.Find({param($node)$node -is [Management.Automation.Language.TryStatementAst]},$true)
        $statements=@($guestTry.Body.Statements)
        $openIndex=0;while($statements[$openIndex].Extent.Text -notmatch '^\$connection\.Open'){$openIndex++}
        $setup=[scriptblock]::Create(($statements[0..($openIndex-1)]|ForEach-Object {$_.Extent.Text}) -join "`n")
        $Password=[securestring]::new();foreach($c in 'SyntheticOnly_A7!'.ToCharArray()){$Password.AppendChar($c)};$Port=1433;$SqlTimeout=30;$connection=$null;$secret=$null
        try {
            . $setup
            $parsed=[Data.SqlClient.SqlConnectionStringBuilder]::new($connection.ConnectionString)
            Check 'Echter SqlClient-Builder hält Credentials getrennt und deaktiviert Pooling' ($connection.Credential -and -not $parsed.Pooling -and -not $parsed.PersistSecurityInfo -and $parsed.Encrypt -and $parsed.DataSource -eq 'tcp:127.0.0.1,1433' -and -not $parsed.Password)
            Check 'Gastkopie ist read-only, ursprüngliches SecureString bleibt unberührt' ($secret.IsReadOnly() -and -not $Password.IsReadOnly())
        } finally {if($connection){$connection.Dispose()};if($secret){$secret.Dispose()};$Password.Dispose()}
        $readIndex=0;while($statements[$readIndex].Extent.Text -notmatch '^if\(-not \$reader.Read'){$readIndex++}
        $readScript=[scriptblock]::Create(($statements[$readIndex..($statements.Count-1)]|ForEach-Object {$_.Extent.Text}) -join "`n")
        $reader=[pscustomobject]@{Ordinal=-1;Reads=0}
        $reader|Add-Member ScriptMethod Read {$this.Reads++;return $this.Reads -eq 1}
        $reader|Add-Member ScriptMethod NextResult {return $false}
        $reader|Add-Member ScriptMethod IsDBNull {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_REGRESSION'};$this.Ordinal=$Ordinal;return $Ordinal -eq 3}
        $reader|Add-Member ScriptMethod GetValue {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_REGRESSION'};$this.Ordinal=$Ordinal;switch($Ordinal){0{return 'Developer Edition (64-bit)'}1{return [long]-2117995310}2{return [int]17}}}
        $observed=& $readScript
        Check 'Produktiver Reader liest bigint sequenziell und normalisiert Defaultinstanz' ($observed.EditionId -eq -2117995310 -and $observed.InstanceName -eq 'MSSQLSERVER' -and $reader.Ordinal -eq 3)
        return @($script:CaptureChecks)
    } $root
    foreach($check in $checks){Write-Host "$(if($check.Passed){'PASS'}else{'FAIL'}): $($check.Name)"}
    if(@($checks|Where-Object {-not $_.Passed}).Count){throw 'SQL_GUEST_CAPTURE_CHECKS_FAILED'}
    Write-Host "SQL GUEST EVALUATION CAPTURE: $($checks.Count) PASS"
}
finally {Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue; if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}}
