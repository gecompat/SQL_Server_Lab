<#
.SYNOPSIS
    Aktivierung, Restart und SQL-seitige Postconditions fuer Derived Runtimes.
.DESCRIPTION
    Installiert keine Pakete in laufende Container. Die Funktion aktiviert nur
    die bereits im verifizierten Image vorhandenen Komponenten und akzeptiert
    eine Runtime erst nach einem echten Daten-In/Daten-Out-Aufruf ueber
    sp_execute_external_script.
#>

function Restart-LabExternalRuntimeContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    & $Provider restart $ContainerIdOrName 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "EXTERNAL_RUNTIME_CONTAINER_RESTART_FAILED: $Provider / $ContainerIdOrName"
    }
}

function Test-LabExternalRuntimeLaunchpadProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    $output = & $Provider exec $ContainerIdOrName bash -lc "ps -eo comm= | grep -Fx launchpadd" 2>&1
    if ($LASTEXITCODE -ne 0 -or (@($output | ForEach-Object { ([string]$_).Trim() }) -notcontains 'launchpadd')) {
        throw "EXTERNAL_RUNTIME_LAUNCHPAD_NOT_READY: $(@($output) -join ' ')"
    }
    return [PSCustomObject]@{ Id='launchpadd-process'; Status='PASS'; Process='launchpadd' }
}

function Invoke-LabPythonExternalRuntimeProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    $expectedRuntime = [string]$Plan.RuntimeVersion
    if ($expectedRuntime -notmatch '^3\.10(?:\.|$)') {
        throw "EXTERNAL_RUNTIME_PYTHON_EXPECTATION_INVALID: $expectedRuntime"
    }
    $query = @"
SET NOCOUNT ON;
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'import os, pwd, sys, numpy, pandas
from importlib.metadata import version
worker = pwd.getpwuid(os.getuid()).pw_name
evidence = ''|''.join([''SQLLAB_EXTERNAL'', ''Python'', sys.version.split()[0], numpy.__version__, version(''revoscalepy''), str(int(InputDataSet.iloc[0, 0])), worker])
OutputDataSet = pandas.DataFrame(dict(evidence=[evidence]))',
    @input_data_1 = N'SELECT CAST(42 AS int) AS value'
WITH RESULT SETS ((evidence nvarchar(4000) NOT NULL));
"@
    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $output = @(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $query -TimeoutSeconds 90)
    }
    finally { $saPlain = $null }
    $marker = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -like 'SQLLAB_EXTERNAL|Python|*' } | Select-Object -Last 1)[0]
    if (-not $marker) { throw "EXTERNAL_RUNTIME_PYTHON_EVIDENCE_MISSING: $(@($output) -join ' ')" }
    $parts = @($marker.Split('|'))
    if ($parts.Count -ne 7 -or $parts[2] -notlike '3.10.*' -or $parts[3] -ne '1.22.0' -or
        $parts[4] -ne '10.0.1' -or $parts[5] -ne '42' -or $parts[6] -ne 'mssql_satellite') {
        throw "EXTERNAL_RUNTIME_PYTHON_EVIDENCE_INVALID: $marker"
    }
    return [PSCustomObject]@{
        Id='python-data-roundtrip'; Status='PASS'; Language='Python'; RuntimeVersion=$parts[2]
        Package='numpy'; PackageVersion=$parts[3]; SqlExtensionPackage='revoscalepy'; SqlExtensionPackageVersion=$parts[4]
        InputValue=42; OutputValue=42; WorkerIdentity=$parts[6]
    }
}

function Invoke-LabRExternalRuntimeProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    $expectedRuntime = [string]$Plan.RuntimeVersion
    if ($expectedRuntime -ne '4.2.3') {
        throw "EXTERNAL_RUNTIME_R_EXPECTATION_INVALID: $expectedRuntime"
    }
    $query = @"
SET NOCOUNT ON;
EXEC sp_execute_external_script
    @language = N'R',
    @script = N'library(RevoScaleR)
worker <- unname(Sys.info()[["effective_user"]])
runtime <- paste(R.version[["major"]], R.version[["minor"]], sep=".")
evidence <- paste("SQLLAB_EXTERNAL", "R", runtime, as.character(packageVersion("RevoScaleR")), as.character(packageVersion("jsonlite")), as.integer(InputDataSet[[1]][1]), worker, sep="|")
OutputDataSet <- data.frame(evidence=evidence, stringsAsFactors=FALSE)',
    @input_data_1 = N'SELECT CAST(42 AS int) AS value'
WITH RESULT SETS ((evidence nvarchar(4000) NOT NULL));
"@
    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $output = @(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $query -TimeoutSeconds 90)
    }
    finally { $saPlain = $null }
    $marker = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -like 'SQLLAB_EXTERNAL|R|*' } | Select-Object -Last 1)[0]
    if (-not $marker) { throw "EXTERNAL_RUNTIME_R_EVIDENCE_MISSING: $(@($output) -join ' ')" }
    $parts = @($marker.Split('|'))
    if ($parts.Count -ne 7 -or $parts[2] -ne '4.2.3' -or $parts[3] -ne '10.0.1' -or
        $parts[4] -ne '1.8.4' -or $parts[5] -ne '42' -or $parts[6] -ne 'mssql_satellite') {
        throw "EXTERNAL_RUNTIME_R_EVIDENCE_INVALID: $marker"
    }
    return [PSCustomObject]@{
        Id='r-data-roundtrip'; Status='PASS'; Language='R'; RuntimeVersion=$parts[2]
        Package='jsonlite'; PackageVersion=$parts[4]; SqlExtensionPackage='RevoScaleR'; SqlExtensionPackageVersion=$parts[3]
        InputValue=42; OutputValue=42; WorkerIdentity=$parts[6]
    }
}

function Save-LabExternalRuntimeInstallationReceipts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Receipts
    )

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        throw 'EXTERNAL_RUNTIME_RECEIPT_RUN_DIRECTORY_NOT_FOUND'
    }
    if ($InstanceId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
        throw 'EXTERNAL_RUNTIME_RECEIPT_INSTANCE_ID_INVALID'
    }
    $path = Join-Path $RunDirectory 'software-installation-receipts.json'
    $document = if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    }
    else {
        [PSCustomObject]@{
            contract = [PSCustomObject]@{ name='SqlServerLab.RunSoftwareInstallationReceipts'; version='1.0' }
            instances = @()
        }
    }
    if (-not $document.contract -or [string]$document.contract.name -ne 'SqlServerLab.RunSoftwareInstallationReceipts' -or
        [string]$document.contract.version -ne '1.0') {
        throw 'EXTERNAL_RUNTIME_RECEIPT_DOCUMENT_INVALID'
    }
    $retained = @($document.instances | Where-Object { [string]$_.instanceId -ne $InstanceId })
    $document.instances = @($retained + [PSCustomObject]@{
        instanceId=$InstanceId; receipts=@($Receipts); updatedAt=Get-LabTimestamp
    })
    Write-LabArtifactJsonAtomic -Path $path -InputObject $document
    return $path
}

function Initialize-LabExternalRuntimes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)]$LabInstance,
        [Parameter(Mandatory)]$ImageArtifact,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    if (@($SoftwarePlans).Count -eq 0) { return @() }
    foreach ($plan in @($SoftwarePlans)) {
        if ([string]$plan.Status -ne 'RESOLVED') {
            throw "EXTERNAL_RUNTIME_INITIALIZATION_REQUIRES_RESOLVED_PLAN: $($plan.SoftwareId)"
        }
    }
    if (-not $ImageArtifact -or [string]$ImageArtifact.ImageKey -notmatch '^[a-f0-9]{64}$' -or
        [string]$ImageArtifact.Provider -ne [string]$LabInstance.Provider) {
        throw 'EXTERNAL_RUNTIME_INITIALIZATION_IMAGE_ARTIFACT_INVALID'
    }

    $activationQuery = @"
EXEC sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure N'external scripts enabled', 1;
RECONFIGURE WITH OVERRIDE;
"@
    Invoke-LabConfigurationQuery -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) `
        -SaPassword $SaPassword -Query $activationQuery
    Restart-LabExternalRuntimeContainer -Provider ([string]$LabInstance.Provider) -ContainerIdOrName ([string]$LabInstance.ContainerId)

    $versionDefinition = Get-SqlServerVersion -VersionId ([string]$LabInstance.Version)
    $readiness = Wait-SqlReady -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) `
        -SaPassword $SaPassword -TimeoutSeconds 300 -ExpectedMajorVersion ([int]$versionDefinition.major) `
        -Provider ([string]$LabInstance.Provider) -ContainerIdOrName ([string]$LabInstance.ContainerId)
    if (-not $readiness.Ready) {
        throw "EXTERNAL_RUNTIME_SQL_NOT_READY_AFTER_RESTART: $($readiness.Message)"
    }
    $launchpad = Test-LabExternalRuntimeLaunchpadProcess -Provider ([string]$LabInstance.Provider) `
        -ContainerIdOrName ([string]$LabInstance.ContainerId)

    $receipts = [Collections.Generic.List[object]]::new()
    foreach ($plan in @($SoftwarePlans | Sort-Object SoftwareId)) {
        $probe = switch ([string]$plan.Language) {
            'Python' {
                Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) `
                    -Port ([int]$LabInstance.Port) -SaPassword $SaPassword
            }
            'R' {
                Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) `
                    -Port ([int]$LabInstance.Port) -SaPassword $SaPassword
            }
            default { throw "EXTERNAL_RUNTIME_PROBE_NOT_IMPLEMENTED: $($plan.Language)" }
        }
        $installationReceipt = New-LabSoftwareInstallationReceipt -Plan $plan -Postconditions @($launchpad, $probe)
        $installationReceipt | Add-Member -NotePropertyName ImageKey -NotePropertyValue ([string]$ImageArtifact.ImageKey) -Force
        $installationReceipt | Add-Member -NotePropertyName LocalImageId -NotePropertyValue ([string]$ImageArtifact.LocalImageId) -Force
        $receipts.Add($installationReceipt)
    }
    $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $RunDirectory `
        -InstanceId ([string]$LabInstance.Id) -Receipts @($receipts)
    return @($receipts)
}
