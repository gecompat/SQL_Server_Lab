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

    try {
        if ($Provider -eq 'podman') {
            Restart-PodmanInstance -ContainerIdOrName $ContainerIdOrName -TimeoutSeconds 30
            return
        }

        $output = @(& $Provider restart $ContainerIdOrName 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "$(@($output) -join ' ')"
        }
    }
    catch {
        throw "EXTERNAL_RUNTIME_CONTAINER_RESTART_FAILED: $Provider / $ContainerIdOrName - $($_.Exception.Message)"
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
    $workerExpression = if ([string]$Plan.OperatingSystem -eq 'windows') {
        @"
import ctypes
worker_buffer = ctypes.create_unicode_buffer(256)
worker_buffer_size = ctypes.c_ulong(len(worker_buffer))
if not ctypes.windll.advapi32.GetUserNameW(worker_buffer, ctypes.byref(worker_buffer_size)):
    raise OSError(ctypes.get_last_error(), "GetUserNameW failed")
worker = worker_buffer.value
"@
    }
    else {
        "import pwd`nworker = pwd.getpwuid(os.getuid()).pw_name"
    }
    $query = @"
SET NOCOUNT ON;
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'import os, sys, numpy, pandas
from importlib.metadata import version
$workerExpression
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
    $workerValid = $parts.Count -eq 7 -and $(if ([string]$Plan.OperatingSystem -eq 'windows') {
        -not [string]::IsNullOrWhiteSpace([string]$parts[6])
    } else { $parts[6] -eq 'mssql_satellite' })
    if ($parts.Count -ne 7 -or $parts[2] -notlike '3.10.*' -or $parts[3] -ne '1.22.0' -or
        $parts[4] -ne '10.0.1' -or $parts[5] -ne '42' -or -not $workerValid) {
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
    $expectedJsonlite = if ([string]$Plan.OperatingSystem -eq 'windows') { '1.8.8' } else { '1.8.4' }
    $workerValid = $parts.Count -eq 7 -and $(if ([string]$Plan.OperatingSystem -eq 'windows') {
        -not [string]::IsNullOrWhiteSpace([string]$parts[6])
    } else { $parts[6] -eq 'mssql_satellite' })
    if ($parts.Count -ne 7 -or $parts[2] -ne '4.2.3' -or $parts[3] -ne '10.0.1' -or
        $parts[4] -ne $expectedJsonlite -or $parts[5] -ne '42' -or -not $workerValid) {
        throw "EXTERNAL_RUNTIME_R_EVIDENCE_INVALID: $marker"
    }
    return [PSCustomObject]@{
        Id='r-data-roundtrip'; Status='PASS'; Language='R'; RuntimeVersion=$parts[2]
        Package='jsonlite'; PackageVersion=$parts[4]; SqlExtensionPackage='RevoScaleR'; SqlExtensionPackageVersion=$parts[3]
        InputValue=42; OutputValue=42; WorkerIdentity=$parts[6]
    }
}

function Get-LabJavaExternalRuntimeArtifactSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ArtifactId
    )

    $artifactMatches = @($Plan.ArtifactRefs | Where-Object { [string]$_.Id -eq $ArtifactId })
    if ($artifactMatches.Count -ne 1 -or [string]$artifactMatches[0].Sha256 -notmatch '^[a-f0-9]{64}$') {
        throw "EXTERNAL_RUNTIME_JAVA_ARTIFACT_MISSING: $ArtifactId"
    }
    return ([string](($artifactMatches[0]).Sha256))
}

function Get-LabJavaExternalRuntimePlatformContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.OperatingSystem -eq 'windows') {
        return [PSCustomObject]@{
            Platform = 'WINDOWS'
            ExtensionFileName = 'javaextension.dll'
            ExtensionPath = 'C:\SqlServerLab\ExternalRuntimes\Java\extension\java-lang-extension-windows-release.zip'
            Environment = '{"JAVAHOME":"C:\\Program Files\\Microsoft\\jdk-17.0.20.1+1"}'
            SdkArtifactId = 'mssql-java-lang-extension-windows'
            SdkPath = 'C:\SqlServerLab\ExternalRuntimes\Java\libraries\mssql-java-lang-extension-windows.jar'
            ProbePath = 'C:\SqlServerLab\ExternalRuntimes\Java\libraries\sql-server-lab-java-probe-1.0.0.jar'
        }
    }
    if ([string]$Plan.OperatingSystem -ne 'linux') {
        throw "EXTERNAL_RUNTIME_JAVA_OPERATING_SYSTEM_UNSUPPORTED: $($Plan.OperatingSystem)"
    }
    return [PSCustomObject]@{
        Platform = 'LINUX'
        ExtensionFileName = 'libJavaExtension.so.1.0'
        ExtensionPath = '/opt/sql-server-lab/java/extension/java-lang-extension-linux-release.zip'
        Environment = '{"JRE_HOME":"/opt/sql-server-lab/java/jre"}'
        SdkArtifactId = 'mssql-java-lang-extension-linux'
        SdkPath = '/opt/sql-server-lab/java/libraries/mssql-java-lang-extension-linux.jar'
        ProbePath = '/opt/sql-server-lab/java/libraries/sql-server-lab-java-probe-1.0.0.jar'
    }
}

function Register-LabJavaExternalRuntimeDatabaseObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$Database
    )

    $platformContract = Get-LabJavaExternalRuntimePlatformContract -Plan $Plan
    $extensionSha256 = Get-LabJavaExternalRuntimeArtifactSha256 -Plan $Plan -ArtifactId 'java-language-extension'
    $sdkSha256 = Get-LabJavaExternalRuntimeArtifactSha256 -Plan $Plan -ArtifactId ([string]$platformContract.SdkArtifactId)
    $probeSha256 = Get-LabJavaExternalRuntimeArtifactSha256 -Plan $Plan -ArtifactId 'sql-server-lab-java-probe'
    $query = @"
SET NOCOUNT ON;
DECLARE @createdLanguage bit = 0;
DECLARE @createdSdk bit = 0;
DECLARE @createdProbe bit = 0;
DECLARE @expectedEnvironment nvarchar(4000) = N'$($platformContract.Environment)';

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.external_languages WHERE language = N'Java')
    BEGIN
        IF NOT EXISTS (
            SELECT 1
            FROM sys.external_languages AS l
            INNER JOIN sys.external_language_files AS f ON f.external_language_id = l.external_language_id
            WHERE l.language = N'Java'
              AND f.platform_desc = N'$($platformContract.Platform)'
              AND f.file_name = N'$($platformContract.ExtensionFileName)'
              AND f.environment_variables = @expectedEnvironment
              AND HASHBYTES('SHA2_256', f.content) = 0x$extensionSha256
        )
            THROW 51000, 'EXTERNAL_RUNTIME_JAVA_LANGUAGE_DRIFT', 1;
    END
    ELSE
    BEGIN
        CREATE EXTERNAL LANGUAGE Java
        FROM (
            CONTENT = N'$($platformContract.ExtensionPath)',
            FILE_NAME = '$($platformContract.ExtensionFileName)',
            PLATFORM = $($platformContract.Platform),
            ENVIRONMENT_VARIABLES = N'$($platformContract.Environment)'
        );
        SET @createdLanguage = 1;
    END;

    IF EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaSdk')
    BEGIN
        IF NOT EXISTS (
            SELECT 1
            FROM sys.external_libraries AS l
            INNER JOIN sys.external_library_files AS f ON f.external_library_id = l.external_library_id
            WHERE l.name = N'SqlServerLabJavaSdk'
              AND l.language = N'Java'
              AND l.scope = 0
              AND f.platform_desc = N'$($platformContract.Platform)'
              AND HASHBYTES('SHA2_256', f.content) = 0x$sdkSha256
        )
            THROW 51001, 'EXTERNAL_RUNTIME_JAVA_SDK_DRIFT', 1;
    END
    ELSE
    BEGIN
        CREATE EXTERNAL LIBRARY SqlServerLabJavaSdk
        FROM (CONTENT = N'$($platformContract.SdkPath)')
        WITH (LANGUAGE = 'Java', PLATFORM = $($platformContract.Platform));
        SET @createdSdk = 1;
    END;

    IF EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaProbe')
    BEGIN
        IF NOT EXISTS (
            SELECT 1
            FROM sys.external_libraries AS l
            INNER JOIN sys.external_library_files AS f ON f.external_library_id = l.external_library_id
            WHERE l.name = N'SqlServerLabJavaProbe'
              AND l.language = N'Java'
              AND l.scope = 0
              AND f.platform_desc = N'$($platformContract.Platform)'
              AND HASHBYTES('SHA2_256', f.content) = 0x$probeSha256
        )
            THROW 51002, 'EXTERNAL_RUNTIME_JAVA_PROBE_DRIFT', 1;
    END
    ELSE
    BEGIN
        CREATE EXTERNAL LIBRARY SqlServerLabJavaProbe
        FROM (CONTENT = N'$($platformContract.ProbePath)')
        WITH (LANGUAGE = 'Java', PLATFORM = $($platformContract.Platform));
        SET @createdProbe = 1;
    END;

    SELECT CONCAT(
        N'SQLLAB_JAVA_REGISTRATION|',
        CONVERT(nvarchar(1), @createdLanguage), N'|',
        CONVERT(nvarchar(1), @createdSdk), N'|',
        CONVERT(nvarchar(1), @createdProbe)
    );
END TRY
BEGIN CATCH
    IF @createdProbe = 1 AND EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaProbe')
        DROP EXTERNAL LIBRARY SqlServerLabJavaProbe;
    IF @createdSdk = 1 AND EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaSdk')
        DROP EXTERNAL LIBRARY SqlServerLabJavaSdk;
    IF @createdLanguage = 1 AND EXISTS (SELECT 1 FROM sys.external_languages WHERE language = N'Java')
        DROP EXTERNAL LANGUAGE Java;
    THROW;
END CATCH;
"@
    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $output = @(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Database $Database -Query $query -TimeoutSeconds 180)
    }
    finally { $saPlain = $null }
    $marker = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -like 'SQLLAB_JAVA_REGISTRATION|*' } | Select-Object -Last 1)[0]
    if (-not $marker) { throw "EXTERNAL_RUNTIME_JAVA_REGISTRATION_EVIDENCE_MISSING: $Database / $(@($output) -join ' ')" }
    $parts = @($marker.Split('|'))
    if ($parts.Count -ne 4 -or @($parts[1..3] | Where-Object { $_ -notin @('0', '1') }).Count -gt 0) {
        throw "EXTERNAL_RUNTIME_JAVA_REGISTRATION_EVIDENCE_INVALID: $marker"
    }
    return [PSCustomObject]@{
        Database=$Database
        CreatedLanguage=($parts[1] -eq '1')
        CreatedSdk=($parts[2] -eq '1')
        CreatedProbe=($parts[3] -eq '1')
    }
}

function Undo-LabJavaExternalRuntimeDatabaseObjects {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$Database,
        [Parameter(Mandatory)]$Registration
    )

    $dropProbe = if ([bool]$Registration.CreatedProbe) { '1' } else { '0' }
    $dropSdk = if ([bool]$Registration.CreatedSdk) { '1' } else { '0' }
    $dropLanguage = if ([bool]$Registration.CreatedLanguage) { '1' } else { '0' }
    $query = @"
SET NOCOUNT ON;
IF $dropProbe = 1 AND EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaProbe')
    DROP EXTERNAL LIBRARY SqlServerLabJavaProbe;
IF $dropSdk = 1 AND EXISTS (SELECT 1 FROM sys.external_libraries WHERE name = N'SqlServerLabJavaSdk')
    DROP EXTERNAL LIBRARY SqlServerLabJavaSdk;
IF $dropLanguage = 1 AND EXISTS (SELECT 1 FROM sys.external_languages WHERE language = N'Java')
    DROP EXTERNAL LANGUAGE Java;
SELECT N'SQLLAB_JAVA_COMPENSATION|PASS';
"@
    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $output = @(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Database $Database -Query $query -TimeoutSeconds 90)
    }
    finally { $saPlain = $null }
    if (@($output | ForEach-Object { ([string]$_).Trim() }) -notcontains 'SQLLAB_JAVA_COMPENSATION|PASS') {
        throw "EXTERNAL_RUNTIME_JAVA_COMPENSATION_FAILED: $Database"
    }
}

function Invoke-LabJavaExternalRuntimeProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$Database
    )

    $expectedMajor = if ([string]$Plan.OperatingSystem -eq 'windows') { '17' } else { '11' }
    if ([string]$Plan.RuntimeVersion -ne $expectedMajor) {
        throw "EXTERNAL_RUNTIME_JAVA_EXPECTATION_INVALID: $($Plan.RuntimeVersion)"
    }
    $registration = Register-LabJavaExternalRuntimeDatabaseObjects -Plan $Plan -HostName $HostName `
        -Port $Port -SaPassword $SaPassword -Database $Database
    $query = @"
SET NOCOUNT ON;
EXEC sp_execute_external_script
    @language = N'Java',
    @script = N'sqlserverlab.SqlServerLabExternalRuntimeProbe',
    @input_data_1 = N'SELECT CAST(42 AS int) AS value'
WITH RESULT SETS ((evidence nvarchar(4000) NOT NULL));
"@
    try {
        $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
        try {
            $output = @(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Database $Database -Query $query -TimeoutSeconds 180)
        }
        finally { $saPlain = $null }
        $marker = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -like 'SQLLAB_EXTERNAL|Java|*' } | Select-Object -Last 1)[0]
        if (-not $marker) { throw "EXTERNAL_RUNTIME_JAVA_EVIDENCE_MISSING: $Database / $(@($output) -join ' ')" }
        $parts = @($marker.Split('|'))
        $workerValid = $parts.Count -eq 6 -and $(if ([string]$Plan.OperatingSystem -eq 'windows') {
            -not [string]::IsNullOrWhiteSpace($parts[5])
        } else { $parts[5] -eq 'mssql_satellite' })
        if ($parts.Count -ne 6 -or $parts[2] -ne '1.0.0' -or $parts[3] -notlike "$expectedMajor.*" -or
            $parts[4] -ne '42' -or -not $workerValid) {
            throw "EXTERNAL_RUNTIME_JAVA_EVIDENCE_INVALID: $Database / $marker"
        }
    }
    catch {
        $probeFailure = $_
        try {
            Undo-LabJavaExternalRuntimeDatabaseObjects -HostName $HostName -Port $Port -SaPassword $SaPassword `
                -Database $Database -Registration $registration
        }
        catch {
            throw "EXTERNAL_RUNTIME_JAVA_PROBE_AND_COMPENSATION_FAILED: $($probeFailure.Exception.Message) / $($_.Exception.Message)"
        }
        throw $probeFailure
    }
    return [PSCustomObject]@{
        Id='java-data-roundtrip'; Status='PASS'; Language='Java'; Database=$Database
        RuntimeVersion=$parts[3]; ProbeVersion=$parts[2]; InputValue=42; OutputValue=42
        WorkerIdentity=$parts[5]; Registration=if ($registration.CreatedLanguage -or $registration.CreatedSdk -or $registration.CreatedProbe) { 'CREATED' } else { 'REUSED' }
        ManagedObjects=[PSCustomObject]@{
            CreatedLanguage=[bool]$registration.CreatedLanguage
            CreatedSdk=[bool]$registration.CreatedSdk
            CreatedProbe=[bool]$registration.CreatedProbe
        }
        RegistrationDetails=$registration
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

function Invoke-LabExternalRuntimeProbeWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [ValidateRange(1,3)][int]$MaximumAttempts = 2,
        [ValidateRange(0,10)][int]$RetryDelaySeconds = 3,
        [scriptblock]$RecoveryOperation
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try { return @(& $Operation) }
        catch {
            $isTransientLaunchpadFailure = $_.Exception.Message -match `
                '(?s)Msg 3901[12].*(Unable to communicate with the runtime|unable to communicate with the LaunchPad service)'
            if (-not $isTransientLaunchpadFailure -or $attempt -ge $MaximumAttempts) { throw }
            Write-LabWarning "Transiente LaunchPad-Kommunikationsstoerung; Runtime-Probe wird einmal wiederholt."
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
            if ($RecoveryOperation) { $null = & $RecoveryOperation }
        }
    }
}

function Initialize-LabExternalRuntimes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)]$LabInstance,
        [Parameter(Mandatory)]$ImageArtifact,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$RunDirectory,
        $ResourceGovernorConfig,
        [ref]$CompensationRecords
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
    $resourceGovernor = Set-LabExternalRuntimeResourceGovernor -HostName ([string]$LabInstance.Host) `
        -Port ([int]$LabInstance.Port) -SaPassword $SaPassword -ResourceGovernor $ResourceGovernorConfig
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
    $recoverProbeReadiness = {
        $recovered = Wait-SqlReady -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) `
            -SaPassword $SaPassword -TimeoutSeconds 300 -ExpectedMajorVersion ([int]$versionDefinition.major) `
            -Provider ([string]$LabInstance.Provider) -ContainerIdOrName ([string]$LabInstance.ContainerId)
        if (-not $recovered.Ready) {
            throw "EXTERNAL_RUNTIME_PROBE_RETRY_READINESS_FAILED: $($recovered.Message)"
        }
    }

    $receipts = [Collections.Generic.List[object]]::new()
    $javaCompensations = [Collections.Generic.List[object]]::new()
    try {
        $orderedPlans = @($SoftwarePlans | Sort-Object `
            @{ Expression = { if ([string]$_.Language -eq 'Java') { 1 } else { 0 } } }, SoftwareId)
        foreach ($plan in $orderedPlans) {
            $probes = @(switch ([string]$plan.Language) {
                'Python' {
                    Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recoverProbeReadiness -Operation {
                        Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) `
                            -Port ([int]$LabInstance.Port) -SaPassword $SaPassword
                    }
                }
                'R' {
                    Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recoverProbeReadiness -Operation {
                        Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) `
                            -Port ([int]$LabInstance.Port) -SaPassword $SaPassword
                    }
                }
                'Java' {
                    $databaseNames = @($LabInstance.Databases | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                    if ($databaseNames.Count -eq 0) { $databaseNames = @('master') }
                    foreach ($databaseName in $databaseNames) {
                        $javaProbe = @(Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recoverProbeReadiness -Operation {
                            Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) `
                                -Port ([int]$LabInstance.Port) -SaPassword $SaPassword -Database $databaseName
                        })[0]
                        $javaCompensations.Add([PSCustomObject]@{
                            Database=$databaseName
                            Registration=$javaProbe.RegistrationDetails
                        })
                        $javaProbe.PSObject.Properties.Remove('RegistrationDetails')
                        $javaProbe
                    }
                }
                default { throw "EXTERNAL_RUNTIME_PROBE_NOT_IMPLEMENTED: $($plan.Language)" }
            })
            $installationReceipt = New-LabSoftwareInstallationReceipt -Plan $plan `
                -Postconditions (@($resourceGovernor) + @($launchpad) + @($probes))
            $installationReceipt | Add-Member -NotePropertyName ImageKey -NotePropertyValue ([string]$ImageArtifact.ImageKey) -Force
            $installationReceipt | Add-Member -NotePropertyName LocalImageId -NotePropertyValue ([string]$ImageArtifact.LocalImageId) -Force
            $receipts.Add($installationReceipt)
        }
        $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $RunDirectory `
            -InstanceId ([string]$LabInstance.Id) -Receipts @($receipts)
        if ($CompensationRecords) {
            $CompensationRecords.Value = @($javaCompensations)
        }
        return @($receipts)
    }
    catch {
        $initialFailure = $_
        $containerDiagnostic = Get-LabContainerReadinessDiagnostic -Provider ([string]$LabInstance.Provider) `
            -ContainerIdOrName ([string]$LabInstance.ContainerId) -IncludeLogs
        $compensationFailures = [Collections.Generic.List[string]]::new()
        for ($index = $javaCompensations.Count - 1; $index -ge 0; $index--) {
            $record = $javaCompensations[$index]
            try {
                Undo-LabJavaExternalRuntimeDatabaseObjects -HostName ([string]$LabInstance.Host) `
                    -Port ([int]$LabInstance.Port) -SaPassword $SaPassword -Database ([string]$record.Database) `
                    -Registration $record.Registration
            }
            catch { $compensationFailures.Add($_.Exception.Message) }
        }
        if ($compensationFailures.Count -gt 0) {
            $diagnosticText = if ($containerDiagnostic) { " / $($containerDiagnostic.Message)" } else { '' }
            throw "EXTERNAL_RUNTIME_INITIALIZATION_AND_COMPENSATION_FAILED: $($initialFailure.Exception.Message) / $($compensationFailures -join ' | ')$diagnosticText"
        }
        if ($containerDiagnostic) {
            throw "EXTERNAL_RUNTIME_INITIALIZATION_FAILED: $($initialFailure.Exception.Message) / $($containerDiagnostic.Message)"
        }
        throw $initialFailure
    }
}
