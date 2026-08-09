#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$builderPath = Join-Path $repoRoot 'Private/HyperVImageBuilder.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-image-builder-$([guid]::NewGuid().ToString('N'))"
$isoPath = Join-Path $temporaryRoot 'synthetic.iso'
$evidencePath = Join-Path $temporaryRoot 'generalization-evidence.json'
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Image Builder Checks' -ForegroundColor Cyan
try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    $bytes = [byte[]]::new(65536); [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 32769)
    [System.IO.File]::WriteAllBytes($isoPath, $bytes)
    $sha = (Get-FileHash $isoPath -Algorithm SHA256).Hash
    $module = Import-Module $modulePath -Force -PassThru
    $operatorText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVImageOperator.ps1') -Raw
    $plan = & $module { param($Iso,$Sha,$Root) New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic -LicenseType test-only -OsDiskSizeBytes 64MB -StateRoot $Root } $isoPath $sha $temporaryRoot
    Add-CheckResult -Name 'Build startet in MEDIA_VERIFIED' -Success ($plan.state -eq 'MEDIA_VERIFIED')
    Add-CheckResult -Name 'Windows-Build persistiert den initialen Leertastenvertrag' -Success ($plan.media.bootInteraction.initialMediaKey -eq 'space')
    Add-CheckResult -Name 'Virtuelle Tastatur wird ohne sprachabhängigen CIM-Caption-Filter aufgelöst' -Success (
        $operatorText -match '-Filter "ElementName=''\$escapedVmName''"' -and
        $operatorText -notmatch "Caption='Virtual Machine'"
    )
    $noInputPlan = & $module { param($Iso,$Sha,$Root) New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic -LicenseType test-only -InitialMediaKey none -OsDiskSizeBytes 64MB -StateRoot $Root } $isoPath $sha (Join-Path $temporaryRoot 'no-input-plan')
    Add-CheckResult -Name 'Installationsmedium kann Tastatureingaben explizit deaktivieren' -Success ($noInputPlan.media.bootInteraction.initialMediaKey -eq 'none')
    $mediaCatalog = & $module { Get-LabMediaSourceCatalog }
    Add-CheckResult -Name 'Medienkatalog trennt Windows-Leertaste und Linux ohne Eingabe' -Success (
        @($mediaCatalog | Where-Object { $_.Category -like 'Windows*' -and $_.BootInteraction.InitialMediaKey -ne 'space' }).Count -eq 0 -and
        @($mediaCatalog | Where-Object { $_.Id -eq 'ubuntu-server' -and $_.BootInteraction.InitialMediaKey -eq 'none' }).Count -eq 1
    )
    Add-CheckResult -Name 'Cleanup-Plan existiert vor Provider-Mutation' -Success (Test-Path (Join-Path $plan.BuildDirectory 'cleanup-plan.json'))
    $rawState = Get-Content (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Portabler Build-State enthaelt keinen ISO-Hostpfad' -Success ($rawState -notmatch [regex]::Escape($isoPath))
    $builderText = Get-Content $builderPath -Raw
    Add-CheckResult -Name 'Cleanup-Schritte stehen vor New-VHD' -Success ($builderText -match 'Add-CleanupStep[\s\S]+Add-CleanupStep[\s\S]+New-VHD')
    $notesIndex = $builderText.IndexOf('ConvertTo-HyperVLabNotes')
    $dvdIndex = $builderText.IndexOf('Add-VMDvdDrive')
    Add-CheckResult -Name 'Builder-Identitaet wird vor weiterer VM-Konfiguration gesetzt' -Success ($notesIndex -ge 0 -and $dvdIndex -gt $notesIndex)
    Add-CheckResult -Name 'VM-Konfiguration verwendet keinen tiefen Build-State-Pfad' -Success ($builderText -notmatch 'New-VM[^\r\n]+-Path\s+\$resourceRoot')
    Add-CheckResult -Name 'Builder ist Generation 2 mit Secure Boot' -Success ($builderText -match 'Generation\s+2[\s\S]+EnableSecureBoot\s+On')
    Add-CheckResult -Name 'Builder deaktiviert automatische Hyper-V-Checkpoints' -Success ($builderText -match 'Set-VM[^\r\n]+AutomaticCheckpointsEnabled\s+\$false')
    Add-CheckResult -Name 'Windows-Builder erhält einen begrenzten dynamischen Speicherbereich' -Success ($builderText -match 'Math\]::Max\(\[double\]512MB,\s*\[double\]\$MemoryStartupBytes\s*/\s*2\)[\s\S]+Math\]::Min\(\[double\]1TB,\s*\[double\]\$MemoryStartupBytes\s*\*\s*2\)[\s\S]+Set-VMMemory[\s\S]+MaximumBytes\s+\$memoryMaximumBytes')
    Add-CheckResult -Name 'Builder bindet ISO als DVD ein' -Success ($builderText -match 'Add-VMDvdDrive[\s\S]+FirstBootDevice')
    $operatorText = Get-Content (Join-Path $repoRoot 'Private/HyperVImageOperator.ps1') -Raw
    Add-CheckResult -Name 'Initialer Medienboot nutzt Hyper-V-WMI und persistiert ein einmaliges Receipt' -Success (
        $operatorText -match 'Msvm_Keyboard' -and
        $operatorText -match 'TypeKey' -and
        $operatorText -match 'initialMediaBootReceipt'
    )
    Add-CheckResult -Name 'Manual Action wird persistent modelliert' -Success ($builderText -match 'MANUAL_ACTION_REQUIRED')
    $ready = & $module { param($Id,$Root) Set-HyperVImageBuildState -BuildId $Id -State BUILDER_READY -Reason test -StateRoot $Root } $plan.buildId $temporaryRoot
    $manual = & $module { param($Id,$Root) Set-HyperVImageBuildManualAction -BuildId $Id -StateRoot $Root } $plan.buildId $temporaryRoot
    Add-CheckResult -Name 'Manual Action besitzt buildgebundene Challenge' -Success ($manual.manualAction.challenge -match '^[a-f0-9-]{36}$')

    $evidence = [PSCustomObject]@{
        contractVersion = '1'; buildId = $manual.buildId; scopeId = $manual.scopeId
        challenge = '00000000-0000-0000-0000-000000000000'; kind = 'synthetic-ci-generalize'
        source = 'synthetic-test'; completedAt = [datetime]::UtcNow.ToString('o')
        checks = [PSCustomObject]@{ sysprepGeneralizeSucceeded = $true; oobeReady = $true; shutdownObserved = $true }
    }
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $evidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $wrongChallengeRejected = $false
    try {
        & $module { param($Id,$Path,$Sha,$Root) Submit-HyperVImageGeneralizationEvidence -BuildId $Id -EvidencePath $Path -ExpectedSha256 $Sha -StateRoot $Root } $plan.buildId $evidencePath $evidenceSha $temporaryRoot | Out-Null
    } catch { $wrongChallengeRejected = $_.Exception.Message -match 'HYPERV_GENERALIZATION_EVIDENCE_POSTCONDITION_FAILED' }
    Add-CheckResult -Name 'Fremde Generalisierungsevidenz wird abgelehnt' -Success $wrongChallengeRejected

    $evidence.challenge = [string]$manual.manualAction.challenge
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $evidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $resumed = & $module { param($Id,$Path,$Sha,$Root) Submit-HyperVImageGeneralizationEvidence -BuildId $Id -EvidencePath $Path -ExpectedSha256 $Sha -StateRoot $Root } $plan.buildId $evidencePath $evidenceSha $temporaryRoot
    Add-CheckResult -Name 'Gueltige Evidenz fuehrt zu RESUME_PENDING' -Success ($resumed.state -eq 'RESUME_PENDING')
    $portableState = Get-Content -LiteralPath (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Evidenz-State enthaelt keinen Quell-Hostpfad' -Success ($portableState -notmatch [regex]::Escape($evidencePath))
    Add-CheckResult -Name 'Reale Publikation bleibt OS_SEALED, CI bleibt test-only' -Success ($builderText -match 'if \(\$synthetic\) \{ ''LIFECYCLE_TEST_ONLY'' \} else \{ ''OS_SEALED'' \}')
    Add-CheckResult -Name 'Sealing darf laufende VM nicht hart ausschalten' -Success ($builderText -match 'Remove-HyperVInstance[^\r\n]+[\s\S]{0,180}-PreserveVhdx\s+-RequireOff')
    $importIndex = $builderText.IndexOf('$artifact = Import-HyperVImageArtifact')
    $removeIndex = $builderText.LastIndexOf('$null = Remove-HyperVInstance')
    $sealedIndex = $builderText.IndexOf('$build = Set-HyperVImageBuildState -BuildId $BuildId -State $finalState')
    Add-CheckResult -Name 'Registry-Import wird vor Builder-Loeschung abgeschlossen' -Success ($importIndex -ge 0 -and $removeIndex -gt $importIndex)
    Add-CheckResult -Name 'Leeres Artifact kann Build nicht als versiegelt markieren' -Success (
        $builderText -match 'HYPERV_IMAGE_ARTIFACT_PUBLICATION_FAILED' -and
        $sealedIndex -gt $removeIndex
    )
    Add-CheckResult -Name 'Sysprep verwendet Generalize, OOBE, VM-Mode und Quit' -Success ($builderText -match "'/generalize',[^\r\n]+'/oobe',[^\r\n]+'/mode:vm',[^\r\n]+'/quit',[^\r\n]+'/quiet'")
    Add-CheckResult -Name 'Sysprep prueft Microsoft ImageState vor Shutdown' -Success ($builderText -match 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE[\s\S]+shutdown\.exe')
    Add-CheckResult -Name 'Automatische Generalisierung persistiert REBOOT_REQUIRED' -Success ($builderText -match 'Set-HyperVImageBuildState[^\r\n]+-State REBOOT_REQUIRED')
    Add-CheckResult -Name 'Automatisches Sysprep ist fuer Testmedien gesperrt' -Success ($builderText -match 'HYPERV_SYSPREP_NOT_ALLOWED_FOR_TEST_MEDIA')

    $autoRoot = Join-Path $temporaryRoot 'auto-state'
    $autoPlan = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId windows-server-2025 -Edition evaluation -InstallationType core `
            -LicenseType evaluation -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-sysprep-vm'; osDiskRelativePath = 'resources/hyperv/mock.vhdx'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        $manual = Set-HyperVImageBuildManualAction -BuildId $plan.buildId -StateRoot $Root
        $manual | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
            contractVersion = '1'; verified = $true; installationType = 'core'
            editionId = 'ServerStandardEval'; currentBuild = '26100'
        }) -Force
        Write-HyperVImageBuildState -BuildDirectory $manual.BuildDirectory -State $manual
        Get-HyperVImageBuildPlan -BuildId $manual.buildId -StateRoot $Root
    } $isoPath $sha $autoRoot
    $testUser = 'sql-lab-sysprep-test'
    $testCredential = [PSCredential]::new($testUser, (ConvertTo-SecureString 'NotPersisted_1!' -AsPlainText -Force))
    $autoResult = & $module {
        param($BuildId,$Root,$Credential)
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = '' } }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]
                challenge = $ArgumentList[2]; imageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
                sysprepExitCode = 0; guestComputerName = 'MOCK-GUEST'
                guestObservedAt = [datetime]::UtcNow.ToString('o'); shutdownDelaySeconds = 30
            }
        }
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Off' }; Identity = [PSCustomObject]@{} }
        }
        Invoke-HyperVWindowsImageGeneralization -BuildId $BuildId -Credential $Credential -StateRoot $Root
    } $autoPlan.buildId $autoRoot $testCredential
    Add-CheckResult -Name 'PowerShell-Direct-Receipt fuehrt automatisch zu RESUME_PENDING' -Success ($autoResult.state -eq 'RESUME_PENDING' -and $autoResult.generalizationEvidence.source -eq 'powershell-direct')
    $jsonDate = ('{"value":"2026-08-03T18:33:14Z"}' | ConvertFrom-Json).value
    $normalizedDate = & $module {
        param($Value)
        (ConvertTo-HyperVImageDateTimeOffset -Value $Value).ToUniversalTime().ToString('o')
    } $jsonDate
    Add-CheckResult -Name 'JSON-DateTime bleibt kulturinvariant am 3. August' -Success ($normalizedDate -eq '2026-08-03T18:33:14.0000000+00:00')
    $repairResult = & $module {
        param($BuildId,$Root)
        Repair-HyperVWindowsImageGeneralizationEvidence -BuildId $BuildId -StateRoot $Root
    } $autoResult.buildId $autoRoot
    Add-CheckResult -Name 'PowerShell-Direct-Evidenz kann ohne erneutes Sysprep repariert werden' -Success (
        $repairResult.state -eq 'RESUME_PENDING' -and
        $repairResult.generalizationEvidence.source -eq 'powershell-direct'
    )
    $autoRawState = Get-Content -LiteralPath (Join-Path $autoResult.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Gast-Credentials werden nicht im Build-State persistiert' -Success ($autoRawState -notmatch [regex]::Escape($testUser) -and $autoRawState -notmatch 'NotPersisted_1!')
    Add-CheckResult -Name 'Realer Sysprep-Pfad verlangt verifizierte Installationsmetadaten' -Success ($builderText -match 'HYPERV_IMAGE_INSTALLATION_NOT_VERIFIED')

    $bootRoot = Join-Path $temporaryRoot 'boot-interaction'
    $bootResult = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId windows-server-2025 -Edition evaluation -InstallationType core `
            -LicenseType evaluation -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-boot-vm'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        $script:typedKeys = 0
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'mock-boot-vm'; State = 'Running' } }
        function Get-CimInstance { param($Namespace,$ClassName,$Filter,$ErrorAction) [PSCustomObject]@{ Name = 'mock-vm-cim' } }
        function Get-CimAssociatedInstance { param($InputObject,$Association,$ResultClassName,$ErrorAction) [PSCustomObject]@{ Name = 'mock-keyboard' } }
        function Invoke-CimMethod { param($InputObject,$MethodName,$Arguments,$ErrorAction) $script:typedKeys++; [PSCustomObject]@{ ReturnValue = 0 } }
        function Start-Sleep { param($Milliseconds) }
        $first = Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
        $second = Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
        $stored = Get-HyperVImageBuildPlan -BuildId $plan.buildId -StateRoot $Root
        [PSCustomObject]@{ First = $first; Second = $second; TypedKeys = $script:typedKeys; Stored = $stored }
    } $isoPath $sha $bootRoot
    Add-CheckResult -Name 'Leertaste wird nur beim ersten Builder-Start gesendet und als sanitisiertes Receipt gespeichert' -Success (
        $bootResult.TypedKeys -eq 12 -and
        $bootResult.First.InitialMediaBoot.status -eq 'SENT' -and
        $bootResult.Second.InitialMediaBoot.status -eq 'SENT' -and
        $bootResult.Stored.initialMediaBootReceipt.successfulSends -eq 12
    )

    $noInputBootRoot = Join-Path $temporaryRoot 'boot-interaction-none'
    $noInputBoot = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic `
            -LicenseType test-only -InitialMediaKey none -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-linux-vm'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'mock-linux-vm'; State = 'Running' } }
        function Get-CimInstance { throw 'LINUX_BOOT_MUST_NOT_USE_KEYBOARD' }
        Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
    } $isoPath $sha $noInputBootRoot
    Add-CheckResult -Name 'InitialMediaKey none überspringt die virtuelle Tastatur vollständig' -Success (
        $noInputBoot.InitialMediaBoot.status -eq 'SKIPPED' -and
        $noInputBoot.InitialMediaBoot.successfulSends -eq 0
    )
} catch { Add-CheckResult -Name 'Image-Builder-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue; if(Test-Path $temporaryRoot){Remove-Item $temporaryRoot -Recurse -Force} }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1}; exit 0



