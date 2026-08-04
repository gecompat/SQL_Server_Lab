<#
.SYNOPSIS
    Resumierbarer SQL-PrepareImage-Builder auf einer Hyper-V-OS-Baseline.
.DESCRIPTION
    Erzeugt aus einem immutable OS_SEALED-Artifact eine isolierte
    Differencing-VM, bindet ein SHA-256-verifiziertes SQL-Server-Medium ein und
    fuehrt SQL Server PrepareImage sowie Windows Sysprep ueber PowerShell Direct
    aus. Credentials und konkrete Hostpfade werden nicht im portablen State
    gespeichert. Vor der Publikation wird die Differencing-Kette in eine
    eigenstaendige VHDX konvertiert.
#>

function Write-HyperVSqlImageBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [Parameter(Mandatory)]$State)

    $State.updatedAt = Get-LabTimestamp
    $serializable = $State | Select-Object * -ExcludeProperty BuildDirectory
    Write-LabArtifactJsonAtomic -Path (Join-Path $BuildDirectory 'build-state.json') -InputObject $serializable
}

function Get-HyperVSqlImageBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if ($BuildId -notmatch '^[a-f0-9-]{36}$') { throw 'HYPERV_SQL_IMAGE_BUILD_ID_INVALID' }
    $directory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv-sql') $BuildId
    $statePath = Join-Path $directory 'build-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $state | Add-Member -NotePropertyName BuildDirectory -NotePropertyValue $directory -Force
    return $state
}

function Get-HyperVSqlImageBuildPlans {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $buildRoot = Join-Path $StateRoot 'image-builds/hyperv-sql'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $buildRoot -Directory -Force |
            Sort-Object Name |
            ForEach-Object {
                if ($_.Name -match '^[a-f0-9-]{36}$') {
                    Get-HyperVSqlImageBuildPlan -BuildId $_.Name -StateRoot $StateRoot
                }
            } |
            Where-Object { $null -ne $_ }
    )
}

function Set-HyperVSqlImageBuildState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)]
        [ValidateSet(
            'MEDIA_VERIFIED', 'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
            'REBOOT_REQUIRED', 'RESUME_PENDING', 'SQL_PREPARED_SEALED',
            'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_READY_RUN', 'TESTS_PASSED', 'FAILED'
        )]
        [string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    $build.state = $State
    $build.stateHistory = @($build.stateHistory + [PSCustomObject]@{
        state = $State; timestamp = Get-LabTimestamp; reason = $Reason
    })
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
}

function Resolve-HyperVSqlInstallationMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval'
    )

    if ($SqlVersion -in @('2019', '2022') -and $MediaEdition -ne 'Eval') {
        throw "HYPERV_SQL_MEDIA_EDITION_UNSUPPORTED: SQL $SqlVersion verwendet im kanonischen Root Eval"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw 'HYPERV_MEDIA_ROOT_NOT_FOUND'
    }
    $isoDirectory = Join-Path $resolvedRoot "SQL/$SqlVersion/$MediaEdition/ISO"
    if (-not (Test-Path -LiteralPath $isoDirectory -PathType Container)) {
        throw "HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND: $isoDirectory"
    }
    $isoFiles = @(Get-ChildItem -LiteralPath $isoDirectory -File -Force | Where-Object Extension -IEQ '.iso')
    if ($isoFiles.Count -eq 0) { throw "HYPERV_SQL_MEDIA_NOT_FOUND: $isoDirectory" }
    if ($isoFiles.Count -gt 1) { throw "HYPERV_SQL_MEDIA_AMBIGUOUS: $($isoFiles.Name -join ', ')" }

    $iso = $isoFiles[0]
    if (-not (Test-WindowsInstallationIso -Path $iso.FullName)) { throw 'HYPERV_SQL_MEDIA_INVALID_ISO' }
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $iso.FullName)
    if ($relativePath.StartsWith('..')) { throw 'HYPERV_SQL_MEDIA_OUTSIDE_ROOT' }
    $portableRelative = $relativePath.Replace('\', '/')
    $hashPath = Join-Path (Join-Path $resolvedRoot 'Hashes') ($relativePath + '.sha256')
    $expectedSha256 = $null
    $hashStatus = 'MISSING'
    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
        $content = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
        if ($content -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$') {
            throw "HYPERV_SQL_MEDIA_HASH_INVALID: $hashPath"
        }
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not $Matches['relative'].Replace('\', '/').Equals($portableRelative, $comparison)) {
            throw "HYPERV_SQL_MEDIA_HASH_PATH_MISMATCH: $hashPath"
        }
        $expectedSha256 = $Matches['sha'].ToLowerInvariant()
        $hashStatus = 'SIDECAR_READY'
    }
    return [PSCustomObject]@{
        MediaRoot = $resolvedRoot; SqlVersion = $SqlVersion; MediaEdition = $MediaEdition
        IsoPath = $iso.FullName; RelativePath = $portableRelative; LengthBytes = [long]$iso.Length
        HashPath = $hashPath; HashStatus = $hashStatus; ExpectedSha256 = $expectedSha256
    }
}

function Get-HyperVSqlSetupVersionPattern {
    <#
    .SYNOPSIS
        Liefert das erwartete Versionsmuster einer SQL-Setup-Datei.
    .DESCRIPTION
        SQL Server 2019 und 2022 verwenden die Produkt-Major-Version in den
        Dateiversionen. SQL Server 2025 RTM verwendet dagegen die
        Jahreskennzeichnung `2025.0170...`; neuere Medien können auch `17...`
        melden. Beide Kennzeichnungen gehören zum selben SQL-2025-Medium.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$SqlVersion)

    switch ($SqlVersion) {
        '2019' { return '(?<!\d)15\.' }
        '2022' { return '(?<!\d)16\.' }
        '2025' { return '(?<!\d)(?:17|2025\.0170)\.' }
    }
}

function New-HyperVSqlMediaHashSidecar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval'
    )

    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition
    if ($media.HashStatus -eq 'SIDECAR_READY') { return $media }
    $digest = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($PSCmdlet.ShouldProcess($media.HashPath, 'SHA-256-Sidecar fuer SQL-Server-ISO schreiben')) {
        New-Item -Path (Split-Path -Parent $media.HashPath) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $media.HashPath -Value "$digest  $($media.RelativePath)" -Encoding utf8NoBOM
    }
    if ($WhatIfPreference) {
        $media.HashStatus = 'WHAT_IF'; $media.ExpectedSha256 = $digest
        return $media
    }
    return Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition
}

function New-HyperVSqlImageBuildPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageArtifactId,
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('Eval', 'Enterprise', 'Standard')][string]$SqlEdition,
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $artifact = Get-HyperVImageArtifact -ArtifactId $ImageArtifactId -StateRoot $StateRoot
    if (-not $artifact -or $artifact.artifactState -ne 'OS_SEALED') { throw 'HYPERV_SQL_IMAGE_OS_BASELINE_REQUIRED' }
    if ([string]$artifact.operatingSystem.id -ne 'windows-server-2025') {
        throw 'HYPERV_SQL_IMAGE_OS_NOT_COMPATIBLE'
    }
    if ($artifact.license.type -eq 'evaluation' -and $artifact.license.evaluationExpiresAt -and
        ([datetime]$artifact.license.evaluationExpiresAt).ToUniversalTime() -lt [datetime]::UtcNow.AddDays(30)) {
        throw 'HYPERV_SQL_IMAGE_OS_EVALUATION_EXPIRING'
    }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    if (-not (Test-WindowsInstallationIso -Path $resolvedIso)) { throw 'HYPERV_SQL_MEDIA_INVALID_ISO' }
    $sha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $ExpectedSha256.ToLowerInvariant()) { throw 'HYPERV_SQL_MEDIA_INTEGRITY_MISMATCH' }
    $normalizedFeatures = @($SqlFeatures | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
    if ($normalizedFeatures.Count -eq 0 -or @($normalizedFeatures | Where-Object { $_ -notin @('SQLENGINE', 'FULLTEXT', 'REPLICATION') }).Count -gt 0) {
        throw 'HYPERV_SQL_FEATURES_UNSUPPORTED'
    }

    $buildId = New-LabGuid
    $scopeId = New-LabGuid
    $buildDirectory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv-sql') $buildId
    New-Item -Path $buildDirectory -ItemType Directory -Force | Out-Null
    $null = New-CleanupPlan -RunDir $buildDirectory -RunId $buildId -ScopeId $scopeId `
        -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv' })
    Write-LabArtifactJsonAtomic -Path (Join-Path $buildDirectory 'build-local.json') -InputObject ([PSCustomObject]@{
        sqlIsoPath = $resolvedIso
    })
    $timestamp = Get-LabTimestamp
    $state = [PSCustomObject]@{
        contractVersion = '1'; buildKind = 'hyperv-sql-prepare-image'; buildId = $buildId; scopeId = $scopeId
        state = 'MEDIA_VERIFIED'; stateHistory = @([PSCustomObject]@{
            state = 'MEDIA_VERIFIED'; timestamp = $timestamp; reason = 'OS-Artifact und SQL-ISO SHA-256 verifiziert'
        })
        parentArtifact = [PSCustomObject]@{
            artifactId = [string]$artifact.artifactId; sha256 = [string]$artifact.sha256
            operatingSystem = $artifact.operatingSystem; license = $artifact.license
        }
        sql = [PSCustomObject]@{
            version = $SqlVersion
            mediaEdition = $SqlEdition
            edition = switch ($SqlEdition) {
                'Eval' { 'Evaluation' }
                'Enterprise' { 'EnterpriseDeveloper' }
                'Standard' { 'StandardDeveloper' }
            }
            license = [PSCustomObject]@{
                type = if ($SqlEdition -eq 'Eval') { 'evaluation' } else { 'developer' }
                evaluationStartsAt = if ($SqlEdition -eq 'Eval') { 'complete-image' } else { $null }
                evaluationExpiresAt = $null
                productionUseAllowed = $false
            }
            features = $normalizedFeatures
            mediaSha256 = $sha256; setupBuild = $null
        }
        builder = $null; manualAction = $null; setupEvidence = $null; generalizationEvidence = $null
        sealPostconditions = $null; artifact = $null; cleanupStatus = $null
        createdAt = $timestamp; updatedAt = $timestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $buildDirectory -State $state
    return Get-HyperVSqlImageBuildPlan -BuildId $buildId -StateRoot $StateRoot
}

function Initialize-HyperVSqlPreparedImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$ImageArtifactId,
        [Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateRange(2GB, 1TB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$StateRoot
    )

    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition
    if ($media.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_MEDIA_HASH_REQUIRED: $($media.HashPath)" }
    $labNetwork = Ensure-LabHyperVNetwork
    $plan = New-HyperVSqlImageBuildPlan -ImageArtifactId $ImageArtifactId -IsoPath $media.IsoPath `
        -ExpectedSha256 $media.ExpectedSha256 -SqlVersion $SqlVersion -SqlEdition $MediaEdition `
        -SqlFeatures $SqlFeatures -StateRoot $StateRoot
    try {
        $instance = New-HyperVInstance -ImageArtifactId $ImageArtifactId -StateRoot $StateRoot `
            -RunDirectory $plan.BuildDirectory -RunId $plan.buildId -ScopeId $plan.scopeId `
            -InstanceId "sql-image-$SqlVersion" -MemoryStartupBytes $MemoryStartupBytes -ProcessorCount $ProcessorCount `
            -SwitchName $labNetwork.Name
        $managed = Get-HyperVManagedVM -VMName $instance.VMName -ExpectedRunId $plan.buildId -ExpectedScopeId $plan.scopeId
        $null = Add-VMDvdDrive -VM $managed.VM -Path $media.IsoPath -ErrorAction Stop
        $plan.builder = [PSCustomObject]@{
            vmName = [string]$instance.VMName
            osDiskRelativePath = [System.IO.Path]::GetRelativePath($plan.BuildDirectory, $instance.ChildVhdxPath).Replace('\', '/')
            generation = 2; secureBoot = $true; networkAttached = $true
        }
        $plan | Add-Member -NotePropertyName labNetwork -NotePropertyValue $labNetwork -Force
        $plan.manualAction = [PSCustomObject]@{
            stepId = 'complete-windows-oobe'; challenge = New-LabGuid
            instruction = 'VM starten, lokales Administratorpasswort setzen und einmal anmelden'
            requestedAt = Get-LabTimestamp
        }
        Write-HyperVSqlImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        return Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State MANUAL_ACTION_REQUIRED `
            -Reason 'Differencing-VM bereit; Windows-OOBE und lokales Administratorpasswort erforderlich' -StateRoot $StateRoot
    }
    catch {
        try { $null = Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State FAILED -Reason $_.Exception.Message -StateRoot $StateRoot } catch { }
        throw
    }
}

function Start-HyperVSqlImageBuildVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        throw 'HYPERV_SQL_IMAGE_BUILD_VM_NOT_STARTABLE'
    }
    return Start-HyperVInstance -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
}

function Invoke-HyperVSqlPrepareAndGeneralize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(30, 1800)][int]$ShutdownTimeoutSeconds = 300,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        throw 'HYPERV_SQL_IMAGE_BUILD_NOT_READY'
    }
    $vmName = [string]$build.builder.vmName
    $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MUST_BE_RUNNING' }
    $setupVersionPattern = Get-HyperVSqlSetupVersionPattern -SqlVersion $build.sql.version

    # Nach erfolgreichem PrepareImage wird dessen Receipt unmittelbar
    # persistiert. Scheitert erst das anschliessende Sysprep, darf ein
    # Wiederholungsaufruf SQL Setup nicht ein zweites Mal ausfuehren.
    if ($build.state -eq 'MANUAL_ACTION_REQUIRED' -and -not $build.setupEvidence) {
        $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $Credential `
            -ArgumentList @($build.buildId, $build.scopeId, $build.manualAction.challenge, $build.sql.version, $setupVersionPattern, ($build.sql.features -join ','), $SetupTimeoutSeconds) `
            -ScriptBlock {
                param($ExpectedBuildId, $ExpectedScopeId, $Challenge, $ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $TimeoutSeconds)
                $ErrorActionPreference = 'Stop'
                $Features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
                $setup = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                    $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                })
                if ($setup.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: $($setup.Count)" }
                $setupVersion = [string]$setup[0].VersionInfo.FileVersion
                if ([string]::IsNullOrWhiteSpace($setupVersion) -or $setupVersion -notmatch $ExpectedSetupVersionPattern) {
                    throw "SQL_SETUP_VERSION_MISMATCH: erwartet $ExpectedSqlVersion, erkannt $setupVersion"
                }
                $arguments = @(
                    '/Q', '/ACTION=PrepareImage', "/FEATURES=$(@($Features) -join ',')",
                    '/INSTANCEID=MSSQLSERVER', '/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS'
                )
                $process = Start-Process -FilePath $setup[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    throw "SQL_SETUP_PREPARE_IMAGE_TIMEOUT: $TimeoutSeconds"
                }
                $exitCode = $null
                try { $exitCode = [int]$process.ExitCode } catch { }
                if ($exitCode -notin @(0, 3010)) {
                    $logRoot = Join-Path $env:ProgramFiles 'Microsoft SQL Server'
                    $summary = @(Get-ChildItem -LiteralPath $logRoot -Filter 'Summary.txt' -File -Recurse -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
                    $detail = 'Summary.txt nicht gefunden'
                    if ($summary) {
                        $lines = @(Get-Content -LiteralPath $summary.FullName -Tail 80 -ErrorAction SilentlyContinue)
                        $relevant = @($lines | Where-Object { $_ -match '(?i)error|failed|failure|exit code|result' } | Select-Object -Last 8)
                        if ($relevant.Count -eq 0) { $relevant = @($lines | Select-Object -Last 8) }
                        $detail = (($relevant -join ' ') -replace '\s+', ' ').Trim()
                        if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
                        $detail = "Summary=$($summary.FullName); Detail=$detail"
                    }
                    $reportedExitCode = if ($null -eq $exitCode) { 'unbekannt' } else { [string]$exitCode }
                    throw "SQL_SETUP_PREPARE_IMAGE_FAILED: ExitCode=$reportedExitCode; $detail"
                }
                if ($exitCode -eq 3010) { $null = & shutdown.exe /r /t 15 /f /d p:4:1 }
                [PSCustomObject]@{
                    contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                    challenge = $Challenge; action = 'PrepareImage'; sqlVersion = $ExpectedSqlVersion
                    setupFileVersion = $setupVersion; features = @($Features); exitCode = $exitCode
                    rebootScheduled = ($exitCode -eq 3010); completedAt = [datetime]::UtcNow.ToString('o')
                }
            }
        $receipt = @($receipt)[-1]
        if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
            [string]$receipt.buildId -ne [string]$build.buildId -or [string]$receipt.scopeId -ne [string]$build.scopeId -or
            [string]$receipt.challenge -ne [string]$build.manualAction.challenge -or [string]$receipt.action -ne 'PrepareImage' -or
            [string]$receipt.sqlVersion -ne [string]$build.sql.version -or [int]$receipt.exitCode -notin @(0, 3010) -or
            (@($receipt.features | Sort-Object -Unique) -join '|') -ne (@($build.sql.features | Sort-Object -Unique) -join '|') -or
            -not [string]$receipt.setupFileVersion -or -not [string]$receipt.completedAt) {
            throw 'HYPERV_SQL_PREPARE_RECEIPT_INVALID'
        }
        $build.setupEvidence = [PSCustomObject]@{
            action = 'PrepareImage'; sqlVersion = [string]$receipt.sqlVersion; setupFileVersion = [string]$receipt.setupFileVersion
            features = @($receipt.features | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            exitCode = [int]$receipt.exitCode; completedAt = [string]$receipt.completedAt; acceptedAt = Get-LabTimestamp
        }
        $build.sql.setupBuild = [string]$receipt.setupFileVersion
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        if ([int]$receipt.exitCode -eq 3010) {
            return Set-HyperVSqlImageBuildState -BuildId $BuildId -State REBOOT_REQUIRED `
                -Reason 'SQL PrepareImage erfolgreich; von Setup angeforderter Neustart laeuft' -StateRoot $StateRoot
        }
        $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    }

    if (-not $build.setupEvidence -or [string]$build.setupEvidence.action -ne 'PrepareImage') {
        throw 'HYPERV_SQL_PREPARE_EVIDENCE_MISSING'
    }
    $sysprep = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $Credential `
        -ArgumentList @($build.buildId, $build.scopeId, $build.manualAction.challenge) `
        -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId, $Challenge)
            $ErrorActionPreference = 'Stop'
            $imageState = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
            # Ein zuvor gestartetes Sysprep kann nach der Rueckkehr von /quit
            # noch den Zwischenzustand UNDEPLOYABLE zeigen. In diesem Fall
            # keinesfalls ein zweites Sysprep starten, sondern dessen Abschluss
            # abwarten. Ein bereits final generalisiertes Image wird ebenfalls
            # nur noch in den kontrollierten Shutdown ueberfuehrt.
            if ($imageState -notin @('IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE', 'IMAGE_STATE_UNDEPLOYABLE')) {
                $sysprepPath = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
                $process = Start-Process -FilePath $sysprepPath `
                    -ArgumentList @('/generalize', '/oobe', '/mode:vm', '/quit', '/quiet') -Wait -PassThru
                if ($process.ExitCode -ne 0) { throw "WINDOWS_SYSPREP_FAILED: $($process.ExitCode)" }
            }
            # Sysprep /quit beendet den Prozess, bevor Windows Setup seinen
            # ImageState zwingend auf den finalen Generalize-Zustand geschrieben
            # hat. IMAGE_STATE_UNDEPLOYABLE ist in diesem kurzen Intervall kein
            # belastbarer Endzustand; deshalb begrenzt auf den dokumentierten
            # Zielzustand warten statt unmittelbar nach dem Prozessende lesen.
            $stateDeadline = [datetime]::UtcNow.AddSeconds(120)
            do {
                $imageState = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
                if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
                Start-Sleep -Seconds 2
            } while ([datetime]::UtcNow -lt $stateDeadline)
            if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "WINDOWS_SYSPREP_STATE_INVALID: $imageState" }
            $null = & shutdown.exe /s /t 15 /f /d p:4:1
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId; challenge = $Challenge
                sysprepExitCode = 0; imageState = $imageState; completedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $sysprep = @($sysprep)[-1]
    if (-not $sysprep -or [string]$sysprep.buildId -ne [string]$build.buildId -or
        [string]$sysprep.scopeId -ne [string]$build.scopeId -or [string]$sysprep.challenge -ne [string]$build.manualAction.challenge -or
        [int]$sysprep.sysprepExitCode -ne 0 -or [string]$sysprep.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        throw 'HYPERV_SQL_IMAGE_SYSPREP_RECEIPT_INVALID'
    }
    $deadline = [datetime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
        if (-not $managed) { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MISSING_DURING_SHUTDOWN' }
        if ([string]$managed.VM.State -eq 'Off') { break }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_SQL_IMAGE_BUILD_SHUTDOWN_TIMEOUT' }

    $build.generalizationEvidence = [PSCustomObject]@{
        source = 'powershell-direct'; challenge = [string]$sysprep.challenge
        imageState = [string]$sysprep.imageState; sysprepExitCode = 0
        shutdownObserved = $true; completedAt = [string]$sysprep.completedAt; acceptedAt = Get-LabTimestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State RESUME_PENDING `
        -Reason 'SQL PrepareImage, Windows-Generalize und Gast-Shutdown technisch verifiziert' -StateRoot $StateRoot
}

function Publish-HyperVSqlPreparedImageBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -eq 'SQL_PREPARED_SEALED') {
        $existing = Get-HyperVImageArtifact -ArtifactId $build.artifact.artifactId -StateRoot $StateRoot
        return [PSCustomObject]@{ Status = $build.state; Build = $build; Artifact = $existing }
    }
    if ($build.state -ne 'RESUME_PENDING' -or -not $build.setupEvidence -or -not $build.generalizationEvidence) {
        throw 'HYPERV_SQL_IMAGE_BUILD_NOT_READY_TO_SEAL'
    }
    if ($build.generalizationEvidence.shutdownObserved -ne $true -or
        [string]$build.generalizationEvidence.challenge -ne [string]$build.manualAction.challenge) {
        throw 'HYPERV_SQL_IMAGE_GENERALIZATION_EVIDENCE_INVALID'
    }
    $managed = Get-HyperVManagedVM -VMName $build.builder.vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if (-not $managed) { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MISSING' }
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MUST_BE_OFF' }
    if (@(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count -gt 0) { throw 'HYPERV_SQL_IMAGE_BUILD_CHECKPOINTS_PRESENT' }
    $childPath = Join-Path $build.BuildDirectory ([string]$build.builder.osDiskRelativePath)
    if (-not (Test-HyperVPathWithinRunDirectory -Path $childPath -RunDirectory $build.BuildDirectory) -or
        -not (Test-Path -LiteralPath $childPath -PathType Leaf)) { throw 'HYPERV_SQL_IMAGE_BUILD_DISK_SCOPE_INVALID' }
    if (-not ([System.IO.Path]::GetFullPath($childPath).Equals([System.IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath), [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'HYPERV_SQL_IMAGE_BUILD_DISK_IDENTITY_MISMATCH'
    }

    $flatPath = Join-Path (Join-Path $build.BuildDirectory 'resources/hyperv') "sql-prepared-$BuildId.vhdx"
    if (-not (Test-HyperVPathWithinRunDirectory -Path $flatPath -RunDirectory $build.BuildDirectory)) {
        throw 'HYPERV_SQL_IMAGE_FLAT_DISK_SCOPE_INVALID'
    }
    if (-not (Test-Path -LiteralPath $flatPath)) {
        $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vhdx -ResourceId $flatPath -Action remove `
            -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Remove flattened SQL prepared VHDX'
        Convert-VHD -Path $childPath -DestinationPath $flatPath -VHDType Dynamic -ErrorAction Stop
    }
    if (-not (Test-HyperVVhdxSignature -Path $flatPath)) { throw 'HYPERV_SQL_IMAGE_FLAT_DISK_INVALID' }
    (Get-Item -LiteralPath $flatPath -Force).IsReadOnly = $true
    $sha256 = (Get-FileHash -LiteralPath $flatPath -Algorithm SHA256).Hash
    $parent = $build.parentArtifact
    $expiry = if ($parent.license.evaluationExpiresAt) { [datetime]$parent.license.evaluationExpiresAt } else { $null }
    $artifact = Import-HyperVImageArtifact -VhdxPath $flatPath -ExpectedSha256 $sha256 `
        -ArtifactState SQL_PREPARED_SEALED -OperatingSystemId $parent.operatingSystem.id `
        -OperatingSystemVersion $parent.operatingSystem.version -Edition $parent.operatingSystem.edition `
        -InstallationType $parent.operatingSystem.installationType -Language $parent.operatingSystem.language `
        -LicenseType $parent.license.type -IntegrityOrigin generated-by-runtime -Generalized -SqlPrepared `
        -SqlVersion $build.sql.version -SqlEdition $build.sql.edition -SqlBuild $build.sql.setupBuild `
        -SqlFeatures @($build.sql.features) -SqlLicenseType $build.sql.license.type `
        -EvaluationExpiresAt $expiry -StateRoot $StateRoot
    if (-not $artifact -or $artifact.artifactState -ne 'SQL_PREPARED_SEALED' -or $artifact.sha256 -ne $sha256.ToLowerInvariant()) {
        throw 'HYPERV_SQL_IMAGE_ARTIFACT_PUBLICATION_FAILED'
    }
    # Registry-Import und Hash-Verifikation sind abgeschlossen, bevor VM und
    # buildlokale Differencing-/Flattened-VHDX entfernt werden.
    $null = Remove-HyperVInstance -VMName $build.builder.vmName -ExpectedScopeId $build.scopeId `
        -ExpectedRunDirectory $build.BuildDirectory -RequireOff
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build.sealPostconditions = [PSCustomObject]@{
        identityValidated = $true; vmOff = $true; checkpointsAbsent = $true
        differencingChainFlattened = $true; validatedAt = Get-LabTimestamp
    }
    $build.artifact = [PSCustomObject]@{
        artifactId = [string]$artifact.artifactId; artifactState = [string]$artifact.artifactState
        sha256 = [string]$artifact.sha256; publishedAt = Get-LabTimestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_PREPARED_SEALED `
        -Reason 'Eigenstaendige SQL-PrepareImage-VHDX immutable in Registry veroeffentlicht' -StateRoot $StateRoot
    $cleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId $build.scopeId
    $build.cleanupStatus = [string]$cleanup.Status
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return [PSCustomObject]@{ Status = 'SQL_PREPARED_SEALED'; Build = $build; Artifact = $artifact; Cleanup = $cleanup }
}

function Remove-HyperVSqlImageBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    $cleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId $build.scopeId
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build.cleanupStatus = [string]$cleanup.Status
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    if ([string]$cleanup.Status -eq 'CLEANUP_SUCCEEDED') { Remove-LabSecrets -Path $build.BuildDirectory }
    return [PSCustomObject]@{ BuildId = $BuildId; Status = [string]$cleanup.Status; Cleanup = $cleanup; Build = $build }
}
