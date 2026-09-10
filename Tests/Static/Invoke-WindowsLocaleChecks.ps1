#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$module=Get-Module SqlServerLab
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-locale-'+[guid]::NewGuid().ToString('N'))
try {
    & $module {
        param($Root)
        function Assert-Locale {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
        $defaults=Resolve-LabWindowsLocaleIntent
        Assert-Locale ($defaults.Region -eq 'DE' -and $defaults.SystemLocale -eq 'de-DE' -and $defaults.UiLanguage -eq 'en-US') 'Kompatibilitaetsdefaults sind explizit und hostunabhaengig'
        $us=Resolve-LabWindowsLocaleIntent -Overrides @{Region='us';SystemLocale='en-us';UiLanguage='en-us';InputLocale='0409:00000409';TimeZone='Pacific Standard Time'}
        Assert-Locale ($us.Region -ceq 'US' -and $us.SystemLocale -ceq 'en-US' -and $us.TimeZone -eq 'Pacific Standard Time') 'US-Profil wird kanonisch normalisiert'
        $independent=Resolve-LabWindowsLocaleIntent -Overrides @{Region='AT';SystemLocale='de-AT';UiLanguage='en-US';InputLocale='0409:00000409'}
        Assert-Locale ($independent.Region -eq 'AT' -and $independent.UiLanguage -eq 'en-US' -and $independent.InputLocale -eq '0409:00000409') 'Region, Systemkultur, UI-Sprache und Tastatur bleiben unabhaengig'
        foreach($case in @(
            @{Field='Region';Value='invalid';Code='WINDOWS_LOCALE_REGION_INVALID'},
            @{Field='SystemLocale';Value='zz-ZZ';Code='WINDOWS_LOCALE_CULTURE_INVALID'},
            @{Field='InputLocale';Value='0409:FFFFFFFF';Code='WINDOWS_LOCALE_INPUT_METHOD_UNSUPPORTED'},
            @{Field='InputLocale';Value='0000:00000409';Code='WINDOWS_LOCALE_INPUT_LANGUAGE_INVALID'},
            @{Field='TimeZone';Value='Europe/Vienna';Code='WINDOWS_LOCALE_TIME_ZONE_INVALID'}
        )){
            $rejected=$false
            try{$null=Resolve-LabWindowsLocaleIntent -Overrides @{$case.Field=$case.Value}}catch{$rejected=$_.Exception.Message -eq $case.Code}
            Assert-Locale $rejected "Ungueltiger Locale-Wert wird vor Mutation klassifiziert: $($case.Field)"
        }
        $conflict=$false
        try{$null=Resolve-LabWindowsLocaleIntent -Intent $us -Overrides @{Region='DE'}}catch{$conflict=$_.Exception.Message -eq 'WINDOWS_LOCALE_MANIFEST_OVERRIDE_CONFLICT'}
        Assert-Locale $conflict 'Expliziter Manifestintent kann nicht still ueberschrieben werden'
        $artifact=[pscustomobject]@{operatingSystem=[pscustomobject]@{language='en-US'}}
        Assert-LabWindowsLocaleImageCapability -Intent $us -Artifact $artifact
        $unsupported=$false
        try{Assert-LabWindowsLocaleImageCapability -Intent (Resolve-LabWindowsLocaleIntent -Overrides @{UiLanguage='de-DE'}) -Artifact $artifact}
        catch{$unsupported=$_.Exception.Message -eq 'WINDOWS_LOCALE_IMAGE_UI_LANGUAGE_UNSUPPORTED'}
        Assert-Locale $unsupported 'Nicht belegte UI-Sprache ist vor VM-Mutation blockiert'
        $null=New-Item -ItemType Directory -Path $Root -Force
        $artifact | Add-Member -NotePropertyName artifactId -NotePropertyValue 'synthetic-english-baseline'
        $lockPath=Add-HyperVImageManifestLockEntry -RunDirectory $Root -Artifact $artifact -WindowsLocale $us
        $originalLock=[IO.File]::ReadAllText($lockPath)
        $null=Add-HyperVImageManifestLockEntry -RunDirectory $Root -Artifact $artifact -WindowsLocale $us
        Assert-Locale ([IO.File]::ReadAllText($lockPath) -ceq $originalLock) 'Wiederholte Locale-Bindung ist idempotent'
        $lockConflict=$false
        try{$null=Add-HyperVImageManifestLockEntry -RunDirectory $Root -Artifact $artifact -WindowsLocale $defaults}
        catch{$lockConflict=$_.Exception.Message -eq 'WINDOWS_LOCALE_LOCK_CONFLICT'}
        Assert-Locale ($lockConflict -and [IO.File]::ReadAllText($lockPath) -ceq $originalLock) 'Widerspruechlicher Intent veraendert den bestehenden Lock nicht'
        $null=Add-HyperVImageManifestLockEntry -RunDirectory $Root -Artifact $artifact
        Assert-Locale ([IO.File]::ReadAllText($lockPath) -ceq $originalLock) 'Bestehende Aufrufer erhalten die gebundene Locale'
        $receipt=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsLocaleReceipt/1.0';RunId='synthetic-locale';Status='POST_OOBE_VERIFIED';Intent=$us;Observed=[pscustomobject]@{GeoId=244;SystemLocale='en-US';UiLanguage='en-US';InputLocale='0409:00000409';TimeZone='Pacific Standard Time'}}
        Assert-LabWindowsLocaleReceipt -Receipt $receipt -Intent $us -RunId synthetic-locale
        $receipt.Observed.InputLocale='0407:00000407'
        $stale=$false
        try{Assert-LabWindowsLocaleReceipt -Receipt $receipt -Intent $us -RunId synthetic-locale}catch{$stale=$_.Exception.Message -eq 'WINDOWS_LOCALE_RECEIPT_OBSERVATION_MISMATCH'}
        Assert-Locale $stale 'Resume akzeptiert keinen Receipt mit abweichender beobachteter Tastatur'
        $manifest=[pscustomobject]@{name='locale-synthetic';instances=@([pscustomobject]@{id='primary';version='2025';provider='hyperv';os='windows';windowsLocale=$us})}
        Assert-Locale (Test-LabManifestSchema -Json ($manifest | ConvertTo-Json -Depth 20)).IsValid 'Manifest-Schema bindet den vollstaendigen Locale-Vertrag'
        $resolved=Resolve-ManifestDefaults -Manifest $manifest
        $snapshot=New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest
        Assert-Locale ($resolved.instances[0].windowsLocale.Region -eq 'US' -and $resolved.instances[0].windowsLocaleSource -eq 'manifest') 'Parser bewahrt normalisierten Intent und seine Herkunft'
        Assert-Locale (($snapshot | ConvertTo-Json -Depth 30) -match 'WindowsLocale' -and ($snapshot | ConvertTo-Json -Depth 30) -match 'Pacific Standard Time') 'Sollzustand enthaelt den portablen Intent'
        Assert-Locale ((Test-LabManifestSchemaInputSupport -RootSchema (Get-LabManifestSchema)).IsSupported) 'Generischer Manifest-Wizard kann das Locale-Schema lesen'
        $steps=@(Get-LabOperationStepsForPlan -Kind WindowsSlot -Provider hyperv -Effective @{WindowsLocale=$us})
        Assert-Locale (($steps.action -join ',') -eq 'CreateHyperVEnvironment,ProvisionHyperVWindowsLocale,StartHyperVEnvironment,CompleteEnvironment') 'Batch wendet explizite Locale vor seinem Startabschluss unbeaufsichtigt an'
        & {
            $script:localeProvisionCalls=0
            function Get-HyperVLabWorkflowRun {[pscustomobject]@{RunDirectory=$Root;Instance=[pscustomobject]@{windowsLocale=$us;oobeAutomation=$null}}}
            function Get-LabSecret {$null}
            function Stop-HyperVLabEnvironment {}
            function Invoke-HyperVLabUnattendedProvision {
                param($RunId,$AdministratorPassword,$PasswordSource,$StateRoot)
                if($PasswordSource -ne 'generated' -or $AdministratorPassword -isnot [SecureString]){throw 'LOCALE_BATCH_SECRET_CONTRACT_FAILED'}
                $script:localeProvisionCalls++
            }
            $operation=[pscustomobject]@{runId='synthetic-locale-run';executor=@{effective=@{WindowsLocale=$us}}}
            $result=Invoke-LabOperationStepAction -Operation $operation -Step @{action='ProvisionHyperVWindowsLocale'} -StateRoot $Root
            Assert-Locale ($result.state -eq 'Completed' -and $script:localeProvisionCalls -eq 1 -and ($result | ConvertTo-Json -Depth 10) -notmatch 'password') 'Batch bindet vorhandenen OOBE-Kern ohne Secret im Schrittergebnis'
        }
        $availabilityOriginal=${function:Get-LabProviderAvailabilityMap}
        try {
            function Get-LabProviderAvailabilityMap {@{docker=$true;podman=$true;hyperv=$true}}
            $batch=New-SqlServerLabBatch -Name locale-synthetic -Items @(@{id='locale';kind='WindowsSlot';intent=@{WindowsLocale=$us}}) -Queue:$false -StateRoot $Root
            Assert-Locale (($batch | ConvertTo-Json -Depth 40) -match 'Pacific Standard Time') 'Batch verwendet denselben normalisierten Locale-Intent'
        }
        finally {Set-Item Function:Get-LabProviderAvailabilityMap -Value $availabilityOriginal}
    } $temporaryRoot
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $temporaryRoot){
        $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        $resolvedRoot=(Get-Item -LiteralPath $temporaryRoot).FullName
        if(-not $resolvedRoot.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'LOCALE_TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
Write-Host 'WINDOWS LOCALE CHECKS: PASS'
