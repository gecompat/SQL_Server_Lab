#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CheckedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$AllowedExitCodes = @(0, 3010),
        [ValidateRange(30, 10800)][int]$TimeoutSeconds = 1800,
        [string]$WorkingDirectory
    )

    $escapedArguments = @($ArgumentList | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' '
    $startParameters = @{
        FilePath = $FilePath
        ArgumentList = $escapedArguments
        PassThru = $true
        NoNewWindow = $true
    }
    if ($WorkingDirectory) { $startParameters.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @startParameters
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "EXTERNAL_RUNTIME_WINDOWS_PROCESS_TIMEOUT: $([IO.Path]::GetFileName($FilePath))"
    }
    if ([int]$process.ExitCode -notin $AllowedExitCodes) {
        throw "EXTERNAL_RUNTIME_WINDOWS_PROCESS_FAILED: $([IO.Path]::GetFileName($FilePath)) / $([int]$process.ExitCode)"
    }
    return [int]$process.ExitCode
}

function Get-VerifiedArtifactPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    $artifact = @($script:Plan.artifacts | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if (-not $artifact) { throw "EXTERNAL_RUNTIME_WINDOWS_ARTIFACT_MISSING: $Id" }
    $path = Join-Path $script:ArtifactRoot ([string]$artifact.fileName)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "EXTERNAL_RUNTIME_WINDOWS_ARTIFACT_FILE_MISSING: $Id"
    }
    $observed = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($observed -ne ([string]$artifact.sha256).ToLowerInvariant()) {
        throw "EXTERNAL_RUNTIME_WINDOWS_ARTIFACT_HASH_MISMATCH: $Id"
    }
    return $path
}

function Grant-ExternalRuntimeReadExecute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LaunchpadServiceName,
        [Parameter(Mandatory)][string]$InstanceName
    )

    $serviceAccount = "NT Service\$LaunchpadServiceName"
    $sqlServiceAccount = if ($InstanceName -eq 'MSSQLSERVER') { 'NT Service\MSSQLSERVER' } else { "NT Service\MSSQL`$$InstanceName" }
    $sqlRUserGroup = if ($InstanceName -eq 'MSSQLSERVER') { 'SQLRUsergroup' } else { "SQLRUsergroup$InstanceName" }
    $principalSids = [Collections.Generic.List[Security.Principal.SecurityIdentifier]]::new()
    foreach ($principal in @($serviceAccount,$sqlServiceAccount,$sqlRUserGroup)) {
        try {
            $account = [Security.Principal.NTAccount]::new($principal)
            $principalSids.Add($account.Translate([Security.Principal.SecurityIdentifier]))
        }
        catch {
            throw "EXTERNAL_RUNTIME_WINDOWS_ACL_PRINCIPAL_NOT_FOUND: $principal"
        }
    }
    $principalSids.Add([Security.Principal.SecurityIdentifier]::new('S-1-15-2-1'))

    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    foreach ($sid in $principalSids) {
        $grant = '*{0}:(OI)(CI)RX' -f $sid.Value
        $null = Invoke-CheckedProcess -FilePath $icacls `
            -ArgumentList @($Path, '/grant', $grant, '/T', '/C') -AllowedExitCodes @(0)
    }

    $requiredRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    foreach ($target in @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        $acl = Get-Acl -LiteralPath $target.FullName -ErrorAction Stop
        $sddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($sddl)
        $missingSids = [Collections.Generic.List[Security.Principal.SecurityIdentifier]]::new()
        foreach ($sid in $principalSids) {
            $matchingRule = @($rawDescriptor.DiscretionaryAcl | Where-Object {
                $_.PSObject.Properties['SecurityIdentifier'] -and
                $_.PSObject.Properties['AceQualifier'] -and
                $_.PSObject.Properties['AccessMask'] -and
                $_.SecurityIdentifier.Value -eq $sid.Value -and
                $_.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                (([int]$_.AccessMask -band [int]$requiredRights) -eq [int]$requiredRights)
            }) | Select-Object -First 1
            if (-not $matchingRule) {
                $missingSids.Add($sid)
            }
        }
        if ($missingSids.Count -gt 0) {
            $inheritanceFlags = if ($target.PSIsContainer) {
                [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                    [Security.AccessControl.InheritanceFlags]::ObjectInherit
            }
            else { [Security.AccessControl.InheritanceFlags]::None }
            foreach ($sid in $missingSids) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    $requiredRights,
                    $inheritanceFlags,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                $null = $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $target.FullName -AclObject $acl -ErrorAction Stop
            $acl = Get-Acl -LiteralPath $target.FullName -ErrorAction Stop
            $sddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($sddl)
        }
        foreach ($sid in $principalSids) {
            $matchingRule = @($rawDescriptor.DiscretionaryAcl | Where-Object {
                $_.PSObject.Properties['SecurityIdentifier'] -and
                $_.PSObject.Properties['AceQualifier'] -and
                $_.PSObject.Properties['AccessMask'] -and
                $_.SecurityIdentifier.Value -eq $sid.Value -and
                $_.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                (([int]$_.AccessMask -band [int]$requiredRights) -eq [int]$requiredRights)
            }) | Select-Object -First 1
            if (-not $matchingRule) {
                throw "EXTERNAL_RUNTIME_WINDOWS_ACL_POSTCONDITION_FAILED: $($target.Name) / $($sid.Value)"
            }
        }
    }
}

function Install-PythonExternalRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstanceName, [Parameter(Mandatory)][string]$LaunchpadServiceName)

    $runtimeHome = 'C:\Program Files\Python310'
    $python = Join-Path $runtimeHome 'python.exe'
    $installer = Get-VerifiedArtifactPath -Id 'python-win-3.10.11'
    $installedVersion = if (Test-Path -LiteralPath $python -PathType Leaf) {
        [string](& $python -c 'import platform; print(platform.python_version())' 2>$null)
    } else { $null }
    if ($installedVersion -ne '3.10.11') {
        $null = Invoke-CheckedProcess -FilePath $installer -ArgumentList @(
            '/quiet', 'InstallAllUsers=1', 'Include_launcher=0', 'Include_test=0',
            'PrependPath=0', 'Shortcuts=0', "TargetDir=$runtimeHome"
        ) -TimeoutSeconds 1800
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_PYTHON_INSTALLATION_MISSING'
    }

    $wheelIds = @(
        'dill-win-0.3.4', 'numpy-win-1.22.0', 'pandas-win-1.3.5', 'patsy-win-0.5.2',
        'python-dateutil-win-2.8.2', 'packaging-win-21.3', 'pyparsing-win-3.0.9',
        'six-win-1.16.0', 'pytz-win-2021.3', 'revoscalepy-win-10.0.1'
    )
    $wheelPaths = @($wheelIds | ForEach-Object { Get-VerifiedArtifactPath -Id $_ })
    $pipArguments = @('-m', 'pip', 'install', '--no-index', '--no-deps', '--disable-pip-version-check') + $wheelPaths
    $null = Invoke-CheckedProcess -FilePath $python -ArgumentList $pipArguments -AllowedExitCodes @(0) -TimeoutSeconds 1800

    $sitePackages = Join-Path $runtimeHome 'Lib\site-packages'
    Grant-ExternalRuntimeReadExecute -Path $sitePackages -LaunchpadServiceName $LaunchpadServiceName -InstanceName $InstanceName
    $registerRext = Join-Path $sitePackages 'revoscalepy\rxLibs\RegisterRext.exe'
    if (-not (Test-Path -LiteralPath $registerRext -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_PYTHON_REGISTER_TOOL_MISSING'
    }
    $null = Invoke-CheckedProcess -FilePath $registerRext `
        -ArgumentList @('/configure', "/pythonhome:$runtimeHome", "/instance:$InstanceName") -AllowedExitCodes @(0)

    $probeCaptureId = [guid]::NewGuid().ToString('N')
    $probeScriptPath = Join-Path $env:TEMP "sqlserverlab-python-version-$probeCaptureId.py"
    $probeStdoutPath = Join-Path $env:TEMP "sqlserverlab-python-version-$probeCaptureId.out"
    $probeStderrPath = Join-Path $env:TEMP "sqlserverlab-python-version-$probeCaptureId.err"
    try {
        $probeSource = @'
import platform
import numpy
import pandas
from importlib.metadata import version
print("|".join([platform.python_version(), numpy.__version__, pandas.__version__, version("revoscalepy")]))
'@
        [IO.File]::WriteAllText($probeScriptPath, $probeSource, [Text.UTF8Encoding]::new($false))
        $probeProcess = Start-Process -FilePath $python -ArgumentList @($probeScriptPath) `
            -PassThru -NoNewWindow -RedirectStandardOutput $probeStdoutPath `
            -RedirectStandardError $probeStderrPath
        if (-not $probeProcess.WaitForExit(120000)) {
            Stop-Process -Id $probeProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'EXTERNAL_RUNTIME_WINDOWS_PYTHON_VERSION_TIMEOUT'
        }
        if ([int]$probeProcess.ExitCode -ne 0) {
            throw "EXTERNAL_RUNTIME_WINDOWS_PYTHON_VERSION_COMMAND_FAILED: $([int]$probeProcess.ExitCode)"
        }
        $versionEvidence = Get-Content -LiteralPath $probeStdoutPath -Raw -ErrorAction Stop
    }
    finally {
        foreach ($capturePath in @($probeScriptPath,$probeStdoutPath,$probeStderrPath)) {
            if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
                Remove-Item -LiteralPath $capturePath -Force
            }
        }
    }
    if ($versionEvidence.Trim() -ne '3.10.11|1.22.0|1.3.5|10.0.1') {
        throw "EXTERNAL_RUNTIME_WINDOWS_PYTHON_VERSION_MISMATCH: $versionEvidence"
    }
    return [PSCustomObject]@{
        language = 'Python'; runtimeVersion = '3.10.11'; packageVersions = [PSCustomObject]@{
            numpy = '1.22.0'; pandas = '1.3.5'; revoscalepy = '10.0.1'
        }
    }
}

function Install-RExternalRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstanceName, [Parameter(Mandatory)][string]$LaunchpadServiceName)

    $runtimeHome = 'C:\Program Files\R\R-4.2.3'
    $rscript = Join-Path $runtimeHome 'bin\Rscript.exe'
    $installer = Get-VerifiedArtifactPath -Id 'r-win-4.2.3'
    $installedVersion = if (Test-Path -LiteralPath $rscript -PathType Leaf) {
        $installedCaptureId = [guid]::NewGuid().ToString('N')
        $installedScriptPath = Join-Path $env:TEMP "sqlserverlab-r-installed-version-$installedCaptureId.R"
        $installedStdoutPath = Join-Path $env:TEMP "sqlserverlab-r-installed-version-$installedCaptureId.out"
        $installedStderrPath = Join-Path $env:TEMP "sqlserverlab-r-installed-version-$installedCaptureId.err"
        try {
            [IO.File]::WriteAllText(
                $installedScriptPath,
                'cat(paste(R.version$major, R.version$minor, sep="."))',
                [Text.UTF8Encoding]::new($false)
            )
            $installedProcess = Start-Process -FilePath $rscript -ArgumentList @('--vanilla',$installedScriptPath) `
                -PassThru -NoNewWindow -RedirectStandardOutput $installedStdoutPath `
                -RedirectStandardError $installedStderrPath
            if (-not $installedProcess.WaitForExit(120000)) {
                Stop-Process -Id $installedProcess.Id -Force -ErrorAction SilentlyContinue
                throw 'EXTERNAL_RUNTIME_WINDOWS_R_INSTALLED_VERSION_TIMEOUT'
            }
            if ([int]$installedProcess.ExitCode -ne 0) {
                throw "EXTERNAL_RUNTIME_WINDOWS_R_INSTALLED_VERSION_COMMAND_FAILED: $([int]$installedProcess.ExitCode)"
            }
            [string](Get-Content -LiteralPath $installedStdoutPath -Raw -ErrorAction Stop).Trim()
        }
        finally {
            foreach ($capturePath in @($installedScriptPath,$installedStdoutPath,$installedStderrPath)) {
                if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
                    Remove-Item -LiteralPath $capturePath -Force
                }
            }
        }
    } else { $null }
    if ($installedVersion -ne '4.2.3') {
        $null = Invoke-CheckedProcess -FilePath $installer -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$runtimeHome"
        ) -TimeoutSeconds 1800
    }
    if (-not (Test-Path -LiteralPath $rscript -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_R_INSTALLATION_MISSING'
    }

    $packageIds = @(
        'iterators-win-1.0.14', 'foreach-win-1.5.2', 'r6-win-2.5.1',
        'jsonlite-win-1.8.8', 'compatibilityapi-win-1.1.0', 'revoscaler-win-10.0.1'
    )
    $packagePaths = @($packageIds | ForEach-Object { (Get-VerifiedArtifactPath -Id $_).Replace('\', '/') })
    $quotedPaths = @($packagePaths | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
    $installExpression = "install.packages(c($quotedPaths), repos=NULL, type='win.binary')"
    $null = Invoke-CheckedProcess -FilePath $rscript -ArgumentList @('--vanilla', '-e', $installExpression) `
        -AllowedExitCodes @(0) -TimeoutSeconds 1800

    Grant-ExternalRuntimeReadExecute -Path (Join-Path $runtimeHome 'library') -LaunchpadServiceName $LaunchpadServiceName -InstanceName $InstanceName
    $registerRext = Join-Path $runtimeHome 'library\RevoScaleR\rxLibs\x64\RegisterRext.exe'
    if (-not (Test-Path -LiteralPath $registerRext -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_R_REGISTER_TOOL_MISSING'
    }
    $null = Invoke-CheckedProcess -FilePath $registerRext `
        -ArgumentList @('/configure', "/rhome:$runtimeHome", "/instance:$InstanceName") -AllowedExitCodes @(0)

    $probeCaptureId = [guid]::NewGuid().ToString('N')
    $probeScriptPath = Join-Path $env:TEMP "sqlserverlab-r-version-$probeCaptureId.R"
    $probeStdoutPath = Join-Path $env:TEMP "sqlserverlab-r-version-$probeCaptureId.out"
    $probeStderrPath = Join-Path $env:TEMP "sqlserverlab-r-version-$probeCaptureId.err"
    try {
        $probeSource = @'
cat(paste(paste(R.version$major, R.version$minor, sep="."), as.character(packageVersion("jsonlite")), as.character(packageVersion("RevoScaleR")), sep="|"))
'@
        [IO.File]::WriteAllText($probeScriptPath, $probeSource, [Text.UTF8Encoding]::new($false))
        $probeProcess = Start-Process -FilePath $rscript -ArgumentList @('--vanilla',$probeScriptPath) `
            -PassThru -NoNewWindow -RedirectStandardOutput $probeStdoutPath `
            -RedirectStandardError $probeStderrPath
        if (-not $probeProcess.WaitForExit(120000)) {
            Stop-Process -Id $probeProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'EXTERNAL_RUNTIME_WINDOWS_R_VERSION_TIMEOUT'
        }
        if ([int]$probeProcess.ExitCode -ne 0) {
            throw "EXTERNAL_RUNTIME_WINDOWS_R_VERSION_COMMAND_FAILED: $([int]$probeProcess.ExitCode)"
        }
        $versionEvidence = Get-Content -LiteralPath $probeStdoutPath -Raw -ErrorAction Stop
    }
    finally {
        foreach ($capturePath in @($probeScriptPath,$probeStdoutPath,$probeStderrPath)) {
            if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
                Remove-Item -LiteralPath $capturePath -Force
            }
        }
    }
    if ($versionEvidence.Trim() -ne '4.2.3|1.8.8|10.0.1') {
        throw "EXTERNAL_RUNTIME_WINDOWS_R_VERSION_MISMATCH: $versionEvidence"
    }
    return [PSCustomObject]@{
        language = 'R'; runtimeVersion = '4.2.3'; packageVersions = [PSCustomObject]@{
            jsonlite = '1.8.8'; RevoScaleR = '10.0.1'
        }
    }
}

function Install-JavaExternalRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstanceName, [Parameter(Mandatory)][string]$LaunchpadServiceName)

    if (-not $script:Plan.java -or [string]$script:Plan.java.runtimeHome -ne 'C:\Program Files\Microsoft\jdk-17.0.20.1+1') {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_PLAN_INVALID'
    }
    foreach ($hashName in @('probeSourceSha256','sdkJarSha256','probeJarSha256','extensionDllSha256','bundledSdkSha256')) {
        if ([string]$script:Plan.java.$hashName -notmatch '^[a-f0-9]{64}$') {
            throw "EXTERNAL_RUNTIME_WINDOWS_JAVA_PLAN_HASH_INVALID: $hashName"
        }
    }

    $runtimeHome = [string]$script:Plan.java.runtimeHome
    $java = Join-Path $runtimeHome 'bin\java.exe'
    $javac = Join-Path $runtimeHome 'bin\javac.exe'
    $jar = Join-Path $runtimeHome 'bin\jar.exe'
    $jdkArchive = Get-VerifiedArtifactPath -Id 'msopenjdk-17-windows'
    if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
        if (Test-Path -LiteralPath $runtimeHome) { throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_HOME_DRIFT' }
        $extractRoot = Join-Path 'C:\SqlServerLab\ExternalRuntimes' ('.jdk-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $jdkArchive -DestinationPath $extractRoot -Force
            $extracted = Join-Path $extractRoot 'jdk-17.0.20.1+1'
            if (-not (Test-Path -LiteralPath (Join-Path $extracted 'bin\javac.exe') -PathType Leaf)) {
                throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_ARCHIVE_INVALID'
            }
            $runtimeParent = Split-Path -Parent $runtimeHome
            $null = New-Item -Path $runtimeParent -ItemType Directory -Force
            Move-Item -LiteralPath $extracted -Destination $runtimeHome -ErrorAction Stop
        }
        finally {
            if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
        }
    }
    if (-not (Test-Path -LiteralPath $javac -PathType Leaf) -or -not (Test-Path -LiteralPath $jar -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_TOOLCHAIN_MISSING'
    }
    $versionCaptureId = [guid]::NewGuid().ToString('N')
    $versionStdoutPath = Join-Path $env:TEMP "sqlserverlab-java-version-$versionCaptureId.out"
    $versionStderrPath = Join-Path $env:TEMP "sqlserverlab-java-version-$versionCaptureId.err"
    try {
        $versionProcess = Start-Process -FilePath $java -ArgumentList @('-XshowSettings:properties','-version') `
            -PassThru -NoNewWindow -RedirectStandardOutput $versionStdoutPath `
            -RedirectStandardError $versionStderrPath
        if (-not $versionProcess.WaitForExit(120000)) {
            Stop-Process -Id $versionProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_VERSION_TIMEOUT'
        }
        if ([int]$versionProcess.ExitCode -ne 0) {
            throw "EXTERNAL_RUNTIME_WINDOWS_JAVA_VERSION_COMMAND_FAILED: $([int]$versionProcess.ExitCode)"
        }
        $versionEvidence = @(
            Get-Content -LiteralPath $versionStdoutPath -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $versionStderrPath -Raw -ErrorAction SilentlyContinue
        ) -join [Environment]::NewLine
    }
    finally {
        foreach ($capturePath in @($versionStdoutPath,$versionStderrPath)) {
            if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
                Remove-Item -LiteralPath $capturePath -Force
            }
        }
    }
    if ($versionEvidence -notmatch '(?m)^\s*java\.version\s*=\s*17\.0\.20\.1\s*$') {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_VERSION_MISMATCH'
    }

    $javaRoot = 'C:\SqlServerLab\ExternalRuntimes\Java'
    $buildRoot = 'C:\SqlServerLab\ExternalRuntimes\JavaBuild'
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
    $probeClasses = Join-Path $buildRoot 'probe-classes'
    $libraryRoot = Join-Path $javaRoot 'libraries'
    $extensionRoot = Join-Path $javaRoot 'extension'
    foreach ($path in @($probeClasses,$libraryRoot,$extensionRoot)) {
        $null = New-Item -Path $path -ItemType Directory -Force
    }
    $probeSource = Join-Path $script:ArtifactRoot ([string]$script:Plan.java.probeSourceFileName)
    if (-not (Test-Path -LiteralPath $probeSource -PathType Leaf) -or
        (Get-FileHash -LiteralPath $probeSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$script:Plan.java.probeSourceSha256) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_PROBE_SOURCE_DRIFT'
    }

    $extensionArchive = Get-VerifiedArtifactPath -Id 'java-language-extension'
    $durableExtensionArchive = Join-Path $extensionRoot 'java-lang-extension-windows-release.zip'
    Copy-Item -LiteralPath $extensionArchive -Destination $durableExtensionArchive -Force
    $extensionInspect = Join-Path $buildRoot 'extension-inspect'
    Expand-Archive -LiteralPath $durableExtensionArchive -DestinationPath $extensionInspect -Force
    if ((Get-FileHash -LiteralPath (Join-Path $extensionInspect 'javaextension.dll') -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$script:Plan.java.extensionDllSha256 -or
        (Get-FileHash -LiteralPath (Join-Path $extensionInspect 'mssql-java-lang-extension.jar') -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$script:Plan.java.bundledSdkSha256) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_EXTENSION_CONTENT_MISMATCH'
    }
    $sdkJar = Join-Path $libraryRoot 'mssql-java-lang-extension-windows.jar'
    Copy-Item -LiteralPath (Join-Path $extensionInspect 'mssql-java-lang-extension.jar') -Destination $sdkJar -Force
    if ((Get-FileHash -LiteralPath $sdkJar -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$script:Plan.java.sdkJarSha256) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_SDK_JAR_HASH_MISMATCH'
    }

    $null = Invoke-CheckedProcess -FilePath $javac -ArgumentList @(
        '--release','8','-cp',$sdkJar,'-d','probe-classes',$probeSource
    ) -AllowedExitCodes @(0) -WorkingDirectory $buildRoot
    Get-ChildItem -LiteralPath $probeClasses -Recurse -File | ForEach-Object { $_.LastWriteTimeUtc = [datetime]'2024-01-01T00:00:00Z' }
    $probeJar = Join-Path $libraryRoot 'sql-server-lab-java-probe-1.0.0.jar'
    $probeEntries = @(Get-ChildItem -LiteralPath (Join-Path $probeClasses 'sqlserverlab') -Recurse -File | ForEach-Object {
        $_.FullName.Substring($probeClasses.Length + 1).Replace('\','/')
    } | Sort-Object)
    $null = Invoke-CheckedProcess -FilePath $jar -ArgumentList (@('-J-Duser.timezone=UTC','cfM',$probeJar) + $probeEntries) `
        -AllowedExitCodes @(0) -WorkingDirectory $probeClasses
    if ((Get-FileHash -LiteralPath $probeJar -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$script:Plan.java.probeJarSha256) {
        throw 'EXTERNAL_RUNTIME_WINDOWS_JAVA_PROBE_JAR_HASH_MISMATCH'
    }

    [Environment]::SetEnvironmentVariable('JRE_HOME', $runtimeHome, 'Machine')
    Grant-ExternalRuntimeReadExecute -Path $runtimeHome -LaunchpadServiceName $LaunchpadServiceName -InstanceName $InstanceName
    Grant-ExternalRuntimeReadExecute -Path $javaRoot -LaunchpadServiceName $LaunchpadServiceName -InstanceName $InstanceName
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
    return [PSCustomObject]@{
        language = 'Java'; runtimeVersion = '17.0.20.1'; extensionVersion = '1.1.0'
        sdkJarSha256 = [string]$script:Plan.java.sdkJarSha256
        probeJarSha256 = [string]$script:Plan.java.probeJarSha256
    }
}

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw 'EXTERNAL_RUNTIME_WINDOWS_PLAN_NOT_FOUND'
}
$script:Plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $script:Plan.contract -or [string]$script:Plan.contract.name -ne 'SqlServerLab.ExternalRuntimeWindowsGuestPlan' -or
    [string]$script:Plan.contract.version -ne '1.0') {
    throw 'EXTERNAL_RUNTIME_WINDOWS_PLAN_INVALID'
}
$script:ArtifactRoot = Split-Path -Parent $PlanPath
$instanceName = [string]$script:Plan.instanceName
if ($instanceName -notmatch '^[A-Za-z0-9_]{1,128}$') { throw 'EXTERNAL_RUNTIME_WINDOWS_INSTANCE_INVALID' }
$launchpadServiceName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLLaunchpad' } else { "MSSQLLaunchpad`$$instanceName" }
$sqlServiceName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceName" }
if (-not (Get-Service -Name $sqlServiceName -ErrorAction SilentlyContinue)) {
    throw 'EXTERNAL_RUNTIME_WINDOWS_SQL_SERVICE_MISSING'
}
if (-not (Get-Service -Name $launchpadServiceName -ErrorAction SilentlyContinue)) {
    throw 'EXTERNAL_RUNTIME_WINDOWS_LAUNCHPAD_SERVICE_MISSING'
}

$results = [Collections.Generic.List[object]]::new()
foreach ($language in @($script:Plan.languages | ForEach-Object { [string]$_ })) {
    switch ($language) {
        'Python' { $results.Add((Install-PythonExternalRuntime -InstanceName $instanceName -LaunchpadServiceName $launchpadServiceName)) }
        'R' { $results.Add((Install-RExternalRuntime -InstanceName $instanceName -LaunchpadServiceName $launchpadServiceName)) }
        'Java' { $results.Add((Install-JavaExternalRuntime -InstanceName $instanceName -LaunchpadServiceName $launchpadServiceName)) }
        default { throw "EXTERNAL_RUNTIME_WINDOWS_LANGUAGE_UNSUPPORTED: $language" }
    }
}

Restart-Service -Name $sqlServiceName -Force -ErrorAction Stop
(Get-Service -Name $sqlServiceName).WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
Restart-Service -Name $launchpadServiceName -Force -ErrorAction Stop
(Get-Service -Name $launchpadServiceName).WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

[PSCustomObject]@{
    contractVersion = '1.0'
    status = 'INSTALLED'
    instanceName = $instanceName
    languages = @($results)
    sqlService = $sqlServiceName
    launchpadService = $launchpadServiceName
    completedAt = [datetime]::UtcNow.ToString('o')
}
