#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft das portable US-Locale-Profil im eigenen Windows-Slot nach Kaltstart.
.DESCRIPTION
    Verwendet eine vorhandene hashverifizierte englische OS_SEALED-Baseline.
    Fuehrt ausschliesslich den eigenen Batch aus und entfernt dessen Run.
    Der Windows-Slot ist die OOBE-Grundlage des SQL-Server-Hyper-V-Pfads.
#>
[CmdletBinding()]
param([string]$StateRoot)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../../SqlServerLab.psd1') -Force -PassThru
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired=$false;$operation=$null;$batch=$null;$runId=$null;$cleanupFailed=$false
$previousLifecycle=$env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE
$previousOperation=$env:SQL_SERVER_LAB_TEST_OPERATION_ID
function Assert-LocaleAcceptance {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "WINDOWS_LOCALE_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
try {
    $acquired=$mutex.WaitOne(0)
    if(-not $acquired){throw 'WINDOWS_LOCALE_RUNTIME_HOST_BUSY'}
    $env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE='test'
    $env:SQL_SERVER_LAB_TEST_OPERATION_ID='locale-'+[guid]::NewGuid().ToString('N')
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-LocaleAcceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Offline-Child-Mount ist im erhoehten Runner autorisiert'
    $null=Get-VMHost -ErrorAction Stop
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
    $artifact=& $module {
        param($Root)
        $candidate=@(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
            $_.artifactState -eq 'OS_SEALED' -and $_.licenseType -ne 'test-only' -and $_.operatingSystem.language -eq 'en-US'
        } | Sort-Object registeredAt -Descending | Select-Object -First 1)
        if($candidate.Count -ne 1){throw 'WINDOWS_LOCALE_ENGLISH_BASELINE_REQUIRED'}
        Get-HyperVImageArtifact -ArtifactId $candidate[0].artifactId -StateRoot $Root
    } $StateRoot
    $resource=& $module {Get-LabHyperVResourceLocationPreview -ResourceClass Run}
    $freeMB=[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024)
    Assert-LocaleAcceptance ($freeMB -ge 5120 -and [Environment]::ProcessorCount -ge 2 -and $resource.ObservedFreeBytes -ge 20GB) 'Reserve fuer genau einen 4-GB-Slot ist vorhanden'
    $manifest=Get-Content (Join-Path $PSScriptRoot '../../Schemas/example-hyperv-locale-us.json') -Raw | ConvertFrom-Json -Depth 20
    $intent=& $module {param($Manifest);(Resolve-ManifestDefaults -Manifest $Manifest).instances[0].windowsLocale} $manifest
    $name='locale-us-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $batch=New-SqlServerLabBatch -Name $name -Items @(@{id=$name;kind='WindowsSlot';intent=@{
        ArtifactId=$artifact.artifactId;WindowsLocale=$intent;MemoryStartupMB=4096;ProcessorCount=2;AutoStart='off'
    }}) -Queue:$false -StateRoot $StateRoot
    $operations=@(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $StateRoot)
    Assert-LocaleAcceptance ($operations.Count -eq 1 -and $operations[0].kind -eq 'WindowsSlot') 'Nur eine eigene Operation ohne fremde Queue-Arbeit'
    $operation=$operations[0]
    $operation=& $module {param($Id,$Root);Invoke-LabOperationExecution -OperationId $Id -StateRoot $Root} $operation.operationId $StateRoot
    $runId=[string]$operation.runId
    Assert-LocaleAcceptance ($operation.status -eq 'Completed' -and -not [string]::IsNullOrWhiteSpace($runId)) 'Batch hat OOBE mit dem Manifest-Intent abgeschlossen'
    $null=Stop-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
    $context=& $module {param($Id,$Root);Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} $runId $StateRoot
    $runtime=& $module {param($Context);Get-HyperVInstanceStatus -VMName $Context.Instance.vmName -ExpectedRunId $Context.Run.runId -ExpectedScopeId $Context.Run.scopeId} $context
    Assert-LocaleAcceptance ($runtime.State -eq 'Off') 'Vollstaendiges Ausschalten vor dem Kaltstart'
    $null=& $module {param($Id,$Root);Start-HyperVLabEnvironment -RunId $Id -StateRoot $Root} $runId $StateRoot
    $observed=& $module {
        param($Context)
        $password=Get-LabSecret -Path $Context.RunDirectory -Name 'guest-administrator-password'
        if(-not $password){throw 'WINDOWS_LOCALE_GUEST_CREDENTIAL_REQUIRED'}
        $credential=[PSCredential]::new('Administrator',$password)
        $parameters=@{VMName=$Context.Instance.vmName;ExpectedRunId=$Context.Run.runId;ExpectedScopeId=$Context.Run.scopeId;Credential=$credential;FallbackAddress=$Context.Instance.oobeAutomation.labAddress;TimeoutSeconds=600}
        $null=Wait-HyperVPowerShellDirect @parameters
        Invoke-HyperVPowerShellDirect @parameters -ScriptBlock {
            [pscustomobject]@{GeoId=[int](Get-WinHomeLocation).GeoId;SystemLocale=[string](Get-WinSystemLocale);UiLanguage=[string](Get-WinUILanguageOverride);InputLocale=[string](Get-WinDefaultInputMethodOverride).InputMethodTip;TimeZone=(Get-TimeZone).Id}
        }
    } $context
    Assert-LocaleAcceptance ($observed.GeoId -eq 244 -and $observed.SystemLocale -eq 'en-US' -and $observed.UiLanguage -eq 'en-US' -and $observed.InputLocale -eq '0409:00000409' -and $observed.TimeZone -eq 'Pacific Standard Time') 'US-Region, Sprache, Tastatur und Zeitzone stimmen nach Kaltstart'
    $lock=Get-Content (Join-Path $context.RunDirectory 'manifest.lock.json') -Raw | ConvertFrom-Json -Depth 20
    $receipt=Get-Content (Join-Path $context.RunDirectory 'windows-locale-receipt.json') -Raw | ConvertFrom-Json -Depth 20
    Assert-LocaleAcceptance ($lock.windowsLocale.Region -eq 'US' -and $context.Instance.windowsLocale.Region -eq 'US' -and $receipt.RunId -eq $runId -and $receipt.Intent.Region -eq 'US' -and $receipt.Observed.GeoId -eq 244) 'Lock, Run-Verbindung und OOBE-Receipt sind an denselben Intent gebunden'
}
finally {
    try {
        if($operation){
            $latest=Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $StateRoot
            $runId=[string]$latest.runId
            if(-not $runId){
                $recovery=& $module {param($Operation,$Root);Resolve-LabOperationOwnedRun -Operation $Operation -StateRoot $Root} $latest $StateRoot
                if($recovery.action -eq 'Reuse'){$runId=[string]$recovery.runId}
            }
            if($runId){
                $removed=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
                if($removed.Status -notin @('REMOVED','COMPLETED')){throw 'WINDOWS_LOCALE_CLEANUP_FAILED'}
                Write-Host 'PASS: CLEANUP_SUCCEEDED; eigener Run entfernt, Baseline und fremde Ressourcen erhalten'
            }
        }
    }
    catch {$cleanupFailed=$true;Write-Warning 'WINDOWS_LOCALE_CLEANUP_FAILED: Eigener State bleibt fuer Recovery erhalten.'}
    finally {
        $env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE=$previousLifecycle
        $env:SQL_SERVER_LAB_TEST_OPERATION_ID=$previousOperation
        if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
    if($cleanupFailed){throw 'WINDOWS_LOCALE_CLEANUP_FAILED'}
}
Write-Host 'WINDOWS LOCALE NATIVE ACCEPTANCE: PASS'
