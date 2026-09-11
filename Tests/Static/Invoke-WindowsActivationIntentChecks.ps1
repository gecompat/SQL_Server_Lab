#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../../SqlServerLab.psd1') -Force -PassThru
& $module {
    function Assert-Intent {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
    $default=Resolve-LabWindowsActivationIntent
    Assert-Intent ($default.Strategy -eq 'EvaluationOnline' -and $default.EgressPolicy -eq 'ExistingOnly') 'Kompatibler Grundintent erlaubt keine implizite neue Egress-NIC'
    Assert-Intent ((Resolve-LabWindowsActivationIntent -Isolated -LegacyRequired).EgressPolicy -eq 'Denied') 'Explizite Isolation gewinnt gegen einen impliziten Legacy-Default'
    Assert-Intent ((Resolve-LabWindowsActivationIntent -LegacyRequired).EgressPolicy -eq 'AllowTemporary') 'Expliziter bisheriger Testumgebungs-Gate behaelt seinen temporaeren Egress'
    foreach($case in @(
        @{State='LICENSED';Edition='ServerStandard';Status=1;Minutes=0;Action='NoOp';Code='WINDOWS_ACTIVATION_ALREADY_ACTIVE'},
        @{State='EVALUATION_ACTIVE';Edition='ServerStandardEval';Status=1;Minutes=100;Action='NoOp';Code='WINDOWS_ACTIVATION_ALREADY_ACTIVE'},
        @{State='EVALUATION_EXPIRED';Edition='ServerStandardEval';Status=0;Minutes=0;Action='Block';Code='WINDOWS_EVALUATION_EXPIRED'},
        @{State='ACTIVATION_REQUIRED';Edition='ServerStandard';Status=0;Minutes=0;Action='Block';Code='WINDOWS_ACTIVATION_FULL_VERSION_STRATEGY_REQUIRED'},
        @{State='ACTIVATION_REQUIRED';Edition='ServerStandardEval';Status=5;Minutes=0;Action='ActivateEvaluation';Code='WINDOWS_ACTIVATION_NETWORK_PLAN_REQUIRED'}
    )){
        $license=[pscustomobject]@{State=$case.State;Edition=$case.Edition;LicenseStatus=$case.Status;EvaluationMinutesRemaining=$case.Minutes}
        $decision=Get-LabWindowsActivationDecision -License $license -Intent $default
        Assert-Intent ($decision.Action -eq $case.Action -and $decision.Code -eq $case.Code -and -not $decision.NetworkMutationAllowed) "Live-Zustandsentscheidung: $($case.State) / $($case.Edition)"
    }
    $unlicensed=[pscustomobject]@{State='ACTIVATION_REQUIRED';Edition='ServerStandardEval';LicenseStatus=5;EvaluationMinutesRemaining=0}
    $denied=Get-LabWindowsActivationDecision -License $unlicensed -Intent (Resolve-LabWindowsActivationIntent -Isolated)
    Assert-Intent ($denied.Action -eq 'Block' -and $denied.Code -eq 'WINDOWS_ACTIVATION_EGRESS_DENIED') 'Verbotener Egress blockiert vor einer Netzwerkplanung'
    $invalid=$false
    try{$null=Resolve-LabWindowsActivationIntent -Intent @{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary';ProductKey='synthetic-disallowed'}}catch{$invalid=$_.Exception.Message -eq 'WINDOWS_ACTIVATION_INTENT_FIELD_INVALID'}
    Assert-Intent $invalid 'Aktivierungsintent akzeptiert keine Product-Key-Felder'
    $invalid=$false
    try{$null=Get-LabWindowsActivationDecision -License @{State='LICENSED';LicenseStatus=0} -Intent $default}catch{$invalid=$_.Exception.Message -eq 'WINDOWS_ACTIVATION_LICENSE_EVIDENCE_INVALID'}
    Assert-Intent $invalid 'Bereit-Label ohne passende beobachtete Lizenz ist ungueltig'
    $manifest=[pscustomobject]@{name='activation-synthetic';instances=@([pscustomobject]@{id='primary';version='2025';provider='hyperv';os='windows';network=@{intent='isolated';exposure='none'}})}
    Assert-Intent (Test-LabManifestSchema -Json ($manifest | ConvertTo-Json -Depth 20)).IsValid 'Manifest ohne Aktivierungsintent bleibt syntaktisch kompatibel'
    $resolved=Resolve-ManifestDefaults -Manifest $manifest
    Assert-Intent ($resolved.instances[0].windowsActivation.EgressPolicy -eq 'Denied') 'Manifest-Isolation erzeugt zentral den verweigerten Egress-Default'
    $explicit=Resolve-LabWindowsActivationIntent -LegacyRequired
    $manifest.instances[0] | Add-Member -NotePropertyName windowsActivation -NotePropertyValue $explicit
    Assert-Intent (Test-LabManifestSchema -Json ($manifest | ConvertTo-Json -Depth 20)).IsValid 'Manifest akzeptiert ausschliesslich vollstaendigen portablen Aktivierungsintent'
    $resolved=Resolve-ManifestDefaults -Manifest $manifest
    Assert-Intent ($resolved.instances[0].windowsActivation.EgressPolicy -eq 'AllowTemporary' -and $resolved.instances[0].windowsActivationSource -eq 'manifest') 'Expliziter temporaerer Aktivierungs-Egress bleibt als Benutzerintent erhalten'
    Assert-Intent ((Test-LabManifestSchemaInputSupport -RootSchema (Get-LabManifestSchema)).IsSupported) 'Generischer Wizard versteht den Aktivierungsvertrag'
    $vm=@{Id='synthetic-vm'}
    $adapter=@{Id='own-adapter';VMId='synthetic-vm';SwitchId='desired-switch'}
    $binding=New-LabWindowsPermanentAdapterBinding -VM $vm -Adapters @($adapter) -SwitchId desired-switch
    Assert-Intent ($binding.AdapterId -eq 'own-adapter' -and $binding.VMId -eq 'synthetic-vm') 'Neu erstellte permanente NIC erhaelt eine stabile run-lokale Bindung'
    $invalid=$false
    try{$null=New-LabWindowsPermanentAdapterBinding -VM $vm -Adapters @($adapter,$adapter) -SwitchId desired-switch}catch{$invalid=$_.Exception.Message -eq 'WINDOWS_PERMANENT_ADAPTER_BINDING_INVALID'}
    Assert-Intent $invalid 'Mehrere Adapter werden nicht als eindeutige permanente NIC geraten'
    $adapter.VMId='foreign-vm';$invalid=$false
    try{$null=New-LabWindowsPermanentAdapterBinding -VM $vm -Adapters @($adapter) -SwitchId desired-switch}catch{$invalid=$_.Exception.Message -eq 'WINDOWS_PERMANENT_ADAPTER_BINDING_INVALID'}
    Assert-Intent $invalid 'Permanente Bindung lehnt eine fremde VM-ID ab'
    & {
        function Get-HyperVLabWorkflowRun {[pscustomobject]@{Instance=@{vmName='synthetic'};Run=@{runId='synthetic-run';scopeId='synthetic-scope'}}}
        function Get-HyperVManagedVM {[pscustomobject]@{VM=@{State='Running'}}}
        function Wait-HyperVPowerShellDirect {[pscustomobject]@{Ready=$true}}
        function Invoke-HyperVPowerShellDirect {$script:licenseReceipt}
        $credential=[pscredential]::new('synthetic',[SecureString]::new())
        $script:licenseReceipt=[pscustomobject]@{edition='ServerStandardEval';productName='Windows Server Evaluation';licenseStatus=1;evaluationMinutesRemaining=100;evaluationExpiresAt='2026-09-11T00:00:00Z';evaluationEndDate='2026-09-09T00:00:00Z';observedAt='2026-09-10T00:00:00Z'}
        $result=Get-HyperVWindowsSlotLicenseStatus -RunId synthetic-run -Credential $credential
        Assert-Intent ($result.State -eq 'EVALUATION_EXPIRED') 'Live-Evaluationsende verhindert Bereitmeldung trotz widerspruechlichem Lizenzstatus'
        $script:licenseReceipt.evaluationEndDate='invalid';$invalid=$false
        try{$null=Get-HyperVWindowsSlotLicenseStatus -RunId synthetic-run -Credential $credential}catch{$invalid=$_.Exception.Message -eq 'HYPERV_WINDOWS_LICENSE_RECEIPT_INVALID'}
        Assert-Intent $invalid 'Ungueltiges Live-Ablaufdatum wird nicht still als aktive Evaluation interpretiert'
    }
}
& $module {
    function Assert-Path {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
    $script:permanentAdapter=[pscustomobject]@{Id='own-adapter';VMId='own-vm';SwitchId='own-switch';MacAddress='00155D010203'}
    $binding=New-LabWindowsPermanentAdapterBinding -VM @{Id='own-vm'} -Adapters @($script:permanentAdapter) -SwitchId own-switch
    $script:activationLab=[pscustomobject]@{RunDirectory='synthetic';StateRoot='synthetic';Run=@{runId='own-run';scopeId='own-scope'};Connection=@{};Instance=[pscustomobject]@{vmName='synthetic';windowsActivationIntent=(Resolve-LabWindowsActivationIntent);windowsActivationIntentSource='manifest';labNetwork=@{intent='lan';adapterBinding=$binding};oobeAutomation=@{labAddress='192.0.2.1'}}}
    $script:activationManaged=[pscustomobject]@{VM=@{Id='own-vm';State='Running'};Identity=@{networkBinding=$binding}}
    $script:activationMode=$null;$script:configureTemporary=$null;$script:activationFailure=$false;$script:guestReportedFailure=$false
    function Get-HyperVLabWorkflowRun {$script:activationLab}
    function Get-HyperVManagedVM {$script:activationManaged}
    function Get-VMNetworkAdapter {$script:permanentAdapter}
    function Write-LabArtifactJsonAtomic {}
    function Get-HyperVWindowsSlotLicenseStatus {[pscustomobject]@{State='ACTIVATION_REQUIRED';Edition='ServerStandardEval';LicenseStatus=5;EvaluationMinutesRemaining=0}}
    function Set-HyperVWindowsSlotActivationEvidence {param($NetworkMode);$script:activationMode=$NetworkMode}
    function New-LabWindowsActivationAdapter {throw 'UNEXPECTED_TEMPORARY_ADAPTER'}
    function Remove-LabWindowsActivationAdapter {throw 'UNEXPECTED_ADAPTER_REMOVAL'}
    function Resolve-HyperVWindowsActivationExternalSwitch {throw 'UNEXPECTED_EXTERNAL_SWITCH_LOOKUP'}
    function Invoke-HyperVPowerShellDirect {
        param($ArgumentList)
        if($ArgumentList.Count -eq 1){return [pscustomobject]@{Available=$true}}
        $script:configureTemporary=$ArgumentList[1]
        if($script:activationFailure){throw 'WINDOWS_ACTIVATION_SYNTHETIC_FAILURE'}
        if($script:guestReportedFailure){return [pscustomobject]@{contractVersion='SqlServerLab.WindowsActivationGuestReceipt/1.0';status='FAILED';failureCode='WINDOWS_ACTIVATION_NETWORK_NOT_READY'}}
        [pscustomobject]@{edition='ServerStandardEval';licenseStatus=1;evaluationMinutesRemaining=100;observedAt='2026-09-10T00:00:00Z'}
    }
    $credential=[pscredential]::new('synthetic',[SecureString]::new())
    $result=Invoke-LabWindowsSlotActivationReconcile -RunId own-run -Credential $credential
    Assert-Path ($result.State -eq 'EVALUATION_ACTIVE' -and $script:activationMode -eq 'Permanent' -and $script:configureTemporary -eq $false -and $script:permanentAdapter.SwitchId -eq 'own-switch') 'Permanente gebundene NIC wird ohne temporaere NIC oder Gast-Netzwerkkonfiguration wiederverwendet'
    $script:activationFailure=$true;$failed=$false
    try{$null=Invoke-LabWindowsSlotActivationReconcile -RunId own-run -Credential $credential}catch{$failed=$_.Exception.Message -match 'WINDOWS_ACTIVATION_SYNTHETIC_FAILURE'}
    Assert-Path ($failed -and $script:permanentAdapter.Id -eq 'own-adapter' -and $script:permanentAdapter.SwitchId -eq 'own-switch') 'Aktivierungsfehler erhaelt die permanente NIC unveraendert'
    $script:activationFailure=$false;$script:guestReportedFailure=$true;$failed=$false
    try{$null=Invoke-LabWindowsSlotActivationReconcile -RunId own-run -Credential $credential}catch{$failed=$_.Exception.Message -match 'WINDOWS_ACTIVATION_NETWORK_NOT_READY'}
    Assert-Path ($failed -and $script:permanentAdapter.Id -eq 'own-adapter' -and $script:permanentAdapter.SwitchId -eq 'own-switch') 'Sanitisierter Gast-Fehlercode bleibt bis zum Aktivierungsaufrufer erhalten'
    & {
        $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-activation-resume-'+[guid]::NewGuid().ToString('N'))
        try {
            $null=New-Item -ItemType Directory -Path $fixtureRoot
            Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-activation-network.json') -Value '{}'
            $script:activationLab.RunDirectory=$fixtureRoot
            $script:activationRecoveryCount=0
            function Remove-LabWindowsActivationAdapter {$script:activationRecoveryCount++}
            function Get-HyperVWindowsSlotLicenseStatus {
                if($script:activationRecoveryCount -ne 1){throw 'LIVE_LICENSE_PROBE_BEFORE_RECOVERY'}
                [pscustomobject]@{State='LICENSED';LicenseStatus=1;Edition='ServerStandard'}
            }
            $result=Invoke-LabWindowsSlotActivationReconcile -RunId own-run -Credential $credential
            Assert-Path ($result.State -eq 'LICENSED' -and $script:activationRecoveryCount -eq 1) 'Aktive Lizenz ueberspringt kein noch vorhandenes eigenes Adapter-Cleanup-Journal'
        }
        finally {
            $resolved=[IO.Path]::GetFullPath($fixtureRoot)
            $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-activation-resume-*'){throw 'ACTIVATION_FIXTURE_CLEANUP_SCOPE_INVALID'}
            if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
        }
    }
}
Write-Host 'WINDOWS ACTIVATION INTENT CHECKS: PASS'
