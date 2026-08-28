<#
.SYNOPSIS
    Verifizierte Offline-Medien und Guest-Execution fuer External Runtimes auf Hyper-V/Windows.
.DESCRIPTION
    Downloads enden ausschließlich im lokalen Media Root und werden vor jeder
    Verwendung gegen den katalogisierten SHA-256 geprüft. Der Gast erhält nur
    eine run-lokale Kopie, einen geschlossenen Installationsplan und das
    repositorygebundene Installationsskript. Freie Manifestbefehle existieren
    in diesem Pfad nicht.
#>

function Get-LabExternalRuntimeWindowsRecipe {
    [CmdletBinding()]
    param()

    $path = Join-Path $script:ModuleRoot 'Images/ExternalLanguages/Windows/recipe.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_RECIPE_NOT_FOUND'
    }
    $recipe = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if (-not $recipe.contract -or [string]$recipe.contract.name -ne 'SqlServerLab.ExternalRuntimeWindowsRecipe' -or
        [string]$recipe.contract.version -ne '1.0' -or [string]$recipe.recipeVersion -ne '1') {
        throw 'EXTERNAL_RUNTIME_WINDOWS_RECIPE_INVALID'
    }
    return $recipe
}

function Get-LabExternalRuntimeWindowsCatalogVariant {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SoftwarePlan)

    $definition = Get-LabSoftwareCatalogItem -Id ([string]$SoftwarePlan.SoftwareId)
    $variant = @($definition.variants | Where-Object { [string]$_.id -eq [string]$SoftwarePlan.VariantId }) | Select-Object -First 1
    if (-not $variant -or [string]$variant.operatingSystem -ne 'windows' -or
        @($variant.providers) -notcontains 'hyperv') {
        throw "EXTERNAL_RUNTIME_WINDOWS_VARIANT_INVALID: $($SoftwarePlan.VariantId)"
    }
    return $variant
}

function Get-LabExternalRuntimeWindowsArtifactFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Artifact)

    if ([string]$Artifact.sourceType -eq 'generated') {
        throw "EXTERNAL_RUNTIME_WINDOWS_GENERATED_ARTIFACT_NOT_DOWNLOADABLE: $($Artifact.id)"
    }
    try { $name = [IO.Path]::GetFileName(([uri][string]$Artifact.source).AbsolutePath) }
    catch { throw "EXTERNAL_RUNTIME_WINDOWS_ARTIFACT_SOURCE_INVALID: $($Artifact.id)" }
    if (-not $name -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$') {
        throw "EXTERNAL_RUNTIME_WINDOWS_ARTIFACT_FILENAME_INVALID: $($Artifact.id)"
    }
    return $name
}

function Resolve-LabExternalRuntimeWindowsMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)][string]$MediaRoot,
        [switch]$Acquire
    )

    $resolvedRoot = if (Test-Path -LiteralPath $MediaRoot -PathType Container) {
        (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    }
    elseif ($Acquire) {
        (New-Item -Path $MediaRoot -ItemType Directory -Force -ErrorAction Stop).FullName
    }
    else { throw 'EXTERNAL_RUNTIME_WINDOWS_MEDIA_ROOT_NOT_FOUND' }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($plan in @($SoftwarePlans)) {
        if ([string]$plan.Status -ne 'RESOLVED' -or [string]$plan.Provider -ne 'hyperv' -or
            [string]$plan.OperatingSystem -ne 'windows') {
            throw "EXTERNAL_RUNTIME_WINDOWS_PLAN_INVALID: $($plan.SoftwareId)"
        }
        $variant = Get-LabExternalRuntimeWindowsCatalogVariant -SoftwarePlan $plan
        foreach ($artifact in @($variant.artifacts | Where-Object { [string]$_.sourceType -ne 'generated' })) {
            $fileName = Get-LabExternalRuntimeWindowsArtifactFileName -Artifact $artifact
            $destinationDirectory = Join-Path $resolvedRoot "ExternalLanguages/Windows/$(([string]$artifact.sha256).ToLowerInvariant())"
            $destinationPath = Join-Path $destinationDirectory $fileName
            if (@($selected | Where-Object { [string]$_.Id -eq [string]$artifact.id }).Count -eq 0) {
                $selected.Add([PSCustomObject]@{
                    Id = [string]$artifact.id
                    Version = [string]$artifact.version
                    Sha256 = ([string]$artifact.sha256).ToLowerInvariant()
                    Source = [string]$artifact.source
                    IntegrityOrigin = [string]$artifact.integrityOrigin
                    FileName = $fileName
                    Path = $destinationPath
                })
            }
        }
    }

    Invoke-LabArtifactStoreLock -StateRoot $resolvedRoot -ScriptBlock {
        foreach ($artifact in @($selected)) {
            if (Test-Path -LiteralPath $artifact.Path -PathType Leaf) {
                $observed = (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($observed -ne [string]$artifact.Sha256) {
                    throw "EXTERNAL_RUNTIME_WINDOWS_MEDIA_DRIFT: $($artifact.Id)"
                }
                continue
            }
            if (-not $Acquire) { throw "EXTERNAL_RUNTIME_WINDOWS_MEDIA_MISSING: $($artifact.Id)" }
            $directory = Split-Path -Parent $artifact.Path
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            $temporaryPath = Join-Path $directory ('.partial-' + [guid]::NewGuid().ToString('N'))
            try {
                Invoke-WebRequest -Uri ([string]$artifact.Source) -OutFile $temporaryPath -UseBasicParsing `
                    -TimeoutSec 600 -MaximumRetryCount 2 -RetryIntervalSec 2
                $observed = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($observed -ne [string]$artifact.Sha256) {
                    throw "EXTERNAL_RUNTIME_WINDOWS_MEDIA_HASH_MISMATCH: $($artifact.Id)"
                }
                [IO.File]::Move($temporaryPath, [string]$artifact.Path, $false)
            }
            finally {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryPath -Force
                }
            }
        }
    } | Out-Null
    return @($selected)
}

function New-LabExternalRuntimeWindowsGuestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory)][string]$RunDirectory,
        [string]$InstanceName = 'MSSQLSERVER'
    )

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_RUN_DIRECTORY_NOT_FOUND'
    }
    $languages = @($SoftwarePlans | ForEach-Object { [string]$_.Language } | Sort-Object -Unique)
    $unsupported = @($languages | Where-Object { $_ -notin @('Python', 'R', 'Java') })
    if ($unsupported.Count -gt 0) { throw "EXTERNAL_RUNTIME_WINDOWS_LANGUAGE_UNSUPPORTED: $($unsupported -join ', ')" }
    $java = $null
    if ($languages -contains 'Java') {
        $recipe = Get-LabExternalRuntimeWindowsRecipe
        $javaPlan = @($SoftwarePlans | Where-Object { [string]$_.Language -eq 'Java' }) | Select-Object -First 1
        $sdk = @($javaPlan.ArtifactRefs | Where-Object { [string]$_.Id -eq 'mssql-java-lang-extension-windows' }) | Select-Object -First 1
        $probe = @($javaPlan.ArtifactRefs | Where-Object { [string]$_.Id -eq 'sql-server-lab-java-probe' }) | Select-Object -First 1
        if (-not $sdk -or -not $probe) { throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_GENERATED_ARTIFACTS_MISSING' }
        $java = [PSCustomObject]@{
            runtimeHome = [string]$recipe.languages.Java.runtimeHome
            probeSourceFileName = [IO.Path]::GetFileName([string]$recipe.languages.Java.probeSource)
            probeSourceSha256 = [string]$recipe.languages.Java.probeSourceSha256
            sdkJarSha256 = [string]$sdk.Sha256
            probeJarSha256 = [string]$probe.Sha256
            extensionDllSha256 = [string]$recipe.languages.Java.extensionDllSha256
            bundledSdkSha256 = [string]$recipe.languages.Java.bundledSdkSha256
        }
    }
    $plan = [PSCustomObject]@{
        contract = [PSCustomObject]@{ name='SqlServerLab.ExternalRuntimeWindowsGuestPlan'; version='1.0' }
        instanceName = $InstanceName
        languages = $languages
        artifacts = @($Artifacts | Sort-Object Id | ForEach-Object {
            [PSCustomObject]@{ id=[string]$_.Id; version=[string]$_.Version; sha256=[string]$_.Sha256; fileName=[string]$_.FileName }
        })
        java = $java
    }
    $path = Join-Path $RunDirectory 'external-runtime-windows-guest-plan.json'
    Write-LabArtifactJsonAtomic -Path $path -InputObject $plan
    return [PSCustomObject]@{ Path=$path; Plan=$plan }
}

function Copy-LabExternalRuntimeWindowsPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory)][string]$GuestPlanPath
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'EXTERNAL_RUNTIME_WINDOWS_VM_NOT_RUNNING'
    }
    $guestRoot = 'C:\SqlServerLab\ExternalRuntimes\Payload'
    $null = Invoke-HyperVPowerShellDirect -VMName $VMName -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId -Credential $Credential -ArgumentList @($guestRoot) -ScriptBlock {
            param($Path)
            if (Test-Path -LiteralPath $Path -PathType Container) {
                Get-ChildItem -LiteralPath $Path -Force | Remove-Item -Recurse -Force
            }
            else { $null = New-Item -Path $Path -ItemType Directory -Force }
        }
    $guestService = Get-VMIntegrationService -VMName $VMName -ErrorAction Stop |
        Where-Object { ([string]$_.Id).EndsWith('6C09BB55-D683-4DA0-8931-C9BF705F6480', [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if (-not $guestService) { throw 'HYPERV_GUEST_FILE_COPY_SERVICE_NOT_FOUND' }
    if (-not $guestService.Enabled) { $null = Enable-VMIntegrationService -VMIntegrationService $guestService -ErrorAction Stop }

    $scriptPath = Join-Path $script:ModuleRoot 'Images/ExternalLanguages/Windows/Install-ExternalRuntimes.ps1'
    $files = @($Artifacts | ForEach-Object { [PSCustomObject]@{ Source=[string]$_.Path; Name=[string]$_.FileName } }) + @(
        [PSCustomObject]@{ Source=$GuestPlanPath; Name='guest-plan.json' },
        [PSCustomObject]@{ Source=$scriptPath; Name='Install-ExternalRuntimes.ps1' }
    )
    $plan = Get-Content -LiteralPath $GuestPlanPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($plan.java) {
        $recipe = Get-LabExternalRuntimeWindowsRecipe
        $probeSourcePath = Join-Path $script:ModuleRoot ([string]$recipe.languages.Java.probeSource)
        if (-not (Test-Path -LiteralPath $probeSourcePath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $probeSourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$plan.java.probeSourceSha256) {
            throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_PROBE_SOURCE_DRIFT'
        }
        $files += [PSCustomObject]@{ Source=$probeSourcePath; Name=[string]$plan.java.probeSourceFileName }
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) { throw "EXTERNAL_RUNTIME_WINDOWS_PAYLOAD_MISSING: $($file.Name)" }
        Copy-VMFile -VMName $VMName -SourcePath $file.Source -DestinationPath (Join-Path $guestRoot $file.Name) `
            -FileSource Host -CreateFullPath -Force -ErrorAction Stop
    }
    return [PSCustomObject]@{
        GuestRoot = $guestRoot
        GuestPlanPath = Join-Path $guestRoot 'guest-plan.json'
        GuestScriptPath = Join-Path $guestRoot 'Install-ExternalRuntimes.ps1'
        ScriptSha256 = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Set-LabHyperVExternalRuntimeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('INSTALLING', 'RECOVERY_REQUIRED', 'EXTENSIONS_READY_RUN')][string]$Status,
        [AllowEmptyCollection()][object[]]$Receipts = @(),
        [string]$Reason,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $lab.Instance | Add-Member -NotePropertyName externalRuntime -NotePropertyValue ([PSCustomObject]@{
        status=$Status
        receipts=@($Receipts)
        reason=$Reason
        updatedAt=Get-LabTimestamp
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    return $lab.Instance.externalRuntime
}

function Install-LabHyperVExternalRuntimes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][SecureString]$SqlSaPassword,
        [Parameter(Mandatory)][string]$MediaRoot,
        $ResourceGovernorConfig,
        [string]$StateRoot
    )

    if (@($SoftwarePlans).Count -eq 0) { return @() }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.workload -ne 'sql' -or -not $lab.Instance.host -or -not $lab.Instance.port) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_SQL_LAB_NOT_READY'
    }
    $recipe = Get-LabExternalRuntimeWindowsRecipe
    if ([string]$recipe.instanceName -ne 'MSSQLSERVER') { throw 'EXTERNAL_RUNTIME_WINDOWS_INSTANCE_RECIPE_INVALID' }
    $null = Set-LabHyperVExternalRuntimeStatus -RunId $RunId -Status INSTALLING -StateRoot $lab.StateRoot

    try {
        $artifacts = @(Resolve-LabExternalRuntimeWindowsMedia -SoftwarePlans $SoftwarePlans -MediaRoot $MediaRoot -Acquire)
        $guestPlan = New-LabExternalRuntimeWindowsGuestPlan -SoftwarePlans $SoftwarePlans -Artifacts $artifacts `
            -RunDirectory $lab.RunDirectory -InstanceName ([string]$recipe.instanceName)
        $payload = Copy-LabExternalRuntimeWindowsPayload -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) `
            -Credential $Credential -Artifacts $artifacts -GuestPlanPath $guestPlan.Path
        $guestReceipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) -Credential $Credential `
            -ArgumentList @($payload.GuestScriptPath, $payload.GuestPlanPath) -ScriptBlock {
                param($InstallerPath, $PlanPath)
                & $InstallerPath -PlanPath $PlanPath
            }
        $guestReceipt = @($guestReceipt)[-1]
        if (-not $guestReceipt -or [string]$guestReceipt.status -ne 'INSTALLED' -or
            [string]$guestReceipt.contractVersion -ne '1.0') {
            throw 'EXTERNAL_RUNTIME_WINDOWS_GUEST_RECEIPT_INVALID'
        }

        $activationQuery = @"
EXEC sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure N'external scripts enabled', 1;
RECONFIGURE WITH OVERRIDE;
"@
        Invoke-LabConfigurationQuery -HostName ([string]$lab.Instance.host) -Port ([int]$lab.Instance.port) `
            -SaPassword $SqlSaPassword -Query $activationQuery
        $resourceGovernor = Set-LabExternalRuntimeResourceGovernor -HostName ([string]$lab.Instance.host) `
            -Port ([int]$lab.Instance.port) -SaPassword $SqlSaPassword -ResourceGovernor $ResourceGovernorConfig
        $null = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) -Credential $Credential `
            -ScriptBlock {
                Restart-Service -Name MSSQLSERVER -Force -ErrorAction Stop
                (Get-Service -Name MSSQLSERVER).WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
                Restart-Service -Name MSSQLLaunchpad -Force -ErrorAction Stop
                (Get-Service -Name MSSQLLaunchpad).WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
                [PSCustomObject]@{ sqlService='Running'; launchpadService='Running'; observedAt=[datetime]::UtcNow.ToString('o') }
            }
        $versionDefinition = Get-SqlServerVersion -VersionId ([string]$lab.Instance.sqlVersion)
        $readiness = Wait-SqlReady -HostName ([string]$lab.Instance.host) -Port ([int]$lab.Instance.port) `
            -SaPassword $SqlSaPassword -TimeoutSeconds 300 -ExpectedMajorVersion ([int]$versionDefinition.major)
        if (-not $readiness.Ready) { throw "EXTERNAL_RUNTIME_WINDOWS_SQL_NOT_READY: $($readiness.Message)" }

        $receipts = [Collections.Generic.List[object]]::new()
        foreach ($plan in @($SoftwarePlans | Sort-Object SoftwareId)) {
            $probes = @(switch ([string]$plan.Language) {
                'Python' { Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName ([string]$lab.Instance.host) -Port ([int]$lab.Instance.port) -SaPassword $SqlSaPassword }
                'R' { Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName ([string]$lab.Instance.host) -Port ([int]$lab.Instance.port) -SaPassword $SqlSaPassword }
                'Java' {
                    $databaseNames = @($lab.Instance.databases | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
                    if ($databaseNames.Count -eq 0) { $databaseNames = @('master') }
                    foreach ($databaseName in $databaseNames) {
                        $javaProbe = Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName ([string]$lab.Instance.host) `
                            -Port ([int]$lab.Instance.port) -SaPassword $SqlSaPassword -Database $databaseName
                        $javaProbe.PSObject.Properties.Remove('RegistrationDetails')
                        $javaProbe
                    }
                }
            })
            $postconditions = @([PSCustomObject]@{
                Id='windows-guest-installation'; Status='PASS'; ScriptSha256=[string]$payload.ScriptSha256
            }) + @($resourceGovernor) + @($probes)
            $installationReceipt = New-LabSoftwareInstallationReceipt -Plan $plan -Postconditions $postconditions
            $receipts.Add($installationReceipt)
        }
        $receiptInstanceId = [string]$lab.Instance.id
        if (-not $receiptInstanceId) { throw 'EXTERNAL_RUNTIME_WINDOWS_INSTANCE_ID_MISSING' }
        $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $lab.RunDirectory `
            -InstanceId $receiptInstanceId -Receipts @($receipts)
        $null = Set-LabHyperVExternalRuntimeStatus -RunId $RunId -Status EXTENSIONS_READY_RUN `
            -Receipts @($receipts | ForEach-Object {
                [PSCustomObject]@{ SoftwareId=$_.SoftwareId; VariantId=$_.VariantId; RuntimeVersion=$_.RuntimeVersion; Status=$_.Status; CompletedAt=$_.CompletedAt }
            }) -StateRoot $lab.StateRoot
        return @($receipts)
    }
    catch {
        $reason = if ($_.Exception.Message -match '^[A-Z0-9_]+' ) { $Matches[0] } else { 'EXTERNAL_RUNTIME_WINDOWS_INSTALLATION_FAILED' }
        try { $null = Set-LabHyperVExternalRuntimeStatus -RunId $RunId -Status RECOVERY_REQUIRED -Reason $reason -StateRoot $lab.StateRoot } catch { }
        throw
    }
}
