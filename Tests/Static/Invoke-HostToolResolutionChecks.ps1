#Requires -Version 7.2
<#
.SYNOPSIS
    Validates process-local Docker, Podman, and Python host-tool resolution.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-host-tool-check-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')
. (Join-Path $repoRoot 'Private\HostToolResolution.ps1')

$originalProcessPath = $env:PATH
$originalUserPath = [Environment]::GetEnvironmentVariable('Path','User')
$originalMachinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$originalOverrides = @{}
foreach ($name in @('DOCKER','PODMAN','PYTHON')) {
    $variable = "SQL_SERVER_LAB_${name}_PATH"
    $originalOverrides[$variable] = [Environment]::GetEnvironmentVariable($variable,'Process')
}

try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    $dockerLeaf = if ($IsWindows) { 'docker.cmd' } else { 'docker' }
    $dockerPath = Join-Path $temporaryRoot $dockerLeaf
    Set-Content -LiteralPath $dockerPath -Value 'synthetic' -Encoding ascii
    $env:SQL_SERVER_LAB_DOCKER_PATH = $dockerPath

    $first = Resolve-LabHostTool -Name docker
    $second = Resolve-LabHostTool -Name docker
    $invocation = Get-LabHostToolInvocation -Name docker
    $matchingPathEntries = @($env:PATH -split [IO.Path]::PathSeparator | Where-Object {
        [string]::Equals($_.TrimEnd('\','/'),$temporaryRoot.TrimEnd('\','/'),$(if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}))
    })
    Add-CheckResult -Name 'Explizites Tool-Override gewinnt und wird als absoluter Aufruf zurückgegeben' -Success (
        $first.Available -and $first.Source -eq 'EXPLICIT_OVERRIDE' -and $first.Invocation -eq $dockerPath -and
        $invocation -eq $dockerPath)
    Add-CheckResult -Name 'Prozess-PATH wird idempotent nur einmal erweitert' -Success (
        $first.PathChanged -and -not $second.PathChanged -and $matchingPathEntries.Count -eq 1)

    $env:SQL_SERVER_LAB_PODMAN_PATH = Join-Path $temporaryRoot $(if($IsWindows){'docker.exe'}else{'docker'})
    $invalidLeafRejected = $false
    try { $null = Resolve-LabHostTool -Name podman }
    catch { $invalidLeafRejected = $_.Exception.Message -match 'HOST_TOOL_OVERRIDE_INVALID' }
    Add-CheckResult -Name 'Explizites Override mit falschem Executable-Namen wird fail-closed abgelehnt' -Success $invalidLeafRejected

    $env:SQL_SERVER_LAB_PODMAN_PATH = Join-Path $temporaryRoot $(if($IsWindows){'missing\podman.exe'}else{'missing/podman'})
    $missingOverrideRejected = $false
    try { $null = Resolve-LabHostTool -Name podman }
    catch { $missingOverrideRejected = $_.Exception.Message -match 'HOST_TOOL_OVERRIDE_INVALID' }
    Add-CheckResult -Name 'Explizites Override auf eine fehlende Datei wird fail-closed abgelehnt' -Success $missingOverrideRejected

    Remove-Item Env:SQL_SERVER_LAB_PODMAN_PATH -ErrorAction SilentlyContinue
    $definitions = @('docker','podman','python' | ForEach-Object { Get-LabHostToolDefinition -Name $_ })
    Add-CheckResult -Name 'Docker, Podman und Python besitzen getrennte sichere Override-Verträge' -Success (
        (@($definitions.OverrideVariable | Sort-Object) -join ',') -eq 'SQL_SERVER_LAB_DOCKER_PATH,SQL_SERVER_LAB_PODMAN_PATH,SQL_SERVER_LAB_PYTHON_PATH')

    $resolution = @(Initialize-LabHostToolPath -Name docker,docker)
    Add-CheckResult -Name 'Mehrfach angeforderte Tools werden nur einmal aufgelöst' -Success ($resolution.Count -eq 1)
    Add-CheckResult -Name 'Persistierter Benutzer- und Maschinen-PATH bleibt unverändert' -Success (
        [Environment]::GetEnvironmentVariable('Path','User') -eq $originalUserPath -and
        [Environment]::GetEnvironmentVariable('Path','Machine') -eq $originalMachinePath)

    if ($IsWindows) {
        @'
@echo off
if /I "%~1"=="info" exit /b 0
if /I "%~1"=="ps" (
  echo synthetic-container^|127.0.0.1:15433-^>1433/tcp
  exit /b 0
)
if /I "%~1"=="inspect" (
  echo {"Name":"/synthetic-container","Config":{"Labels":{"sql-server-lab.run-id":"11111111-1111-1111-1111-111111111111","sql-server-lab.scope-id":"22222222-2222-2222-2222-222222222222"}}}
  exit /b 0
)
exit /b 1
'@ | Set-Content -LiteralPath $dockerPath -Encoding ascii
    }
    else {
        @'
#!/bin/sh
if [ "$1" = "info" ]; then exit 0; fi
if [ "$1" = "ps" ]; then printf '%s\n' 'synthetic-container|127.0.0.1:15433->1433/tcp'; exit 0; fi
if [ "$1" = "inspect" ]; then printf '%s\n' '{"Name":"/synthetic-container","Config":{"Labels":{"sql-server-lab.run-id":"11111111-1111-1111-1111-111111111111","sql-server-lab.scope-id":"22222222-2222-2222-2222-222222222222"}}}'; exit 0; fi
exit 1
'@ | Set-Content -LiteralPath $dockerPath -Encoding utf8NoBOM
        & /bin/chmod +x $dockerPath
    }
    . (Join-Path $repoRoot 'Public\Restore-SqlServerLabDatabase.ps1')
    $pathBeforeRestoreProbe = $env:PATH
    try {
        $env:PATH = ''
        $restoreCandidate = Resolve-LabRestoreContainer -Provider docker -ContainerName synthetic-container -Port 15433
    }
    finally {
        $env:PATH = $pathBeforeRestoreProbe
    }
    Add-CheckResult -Name 'Restore-Zielsuche funktioniert mit Override auch bei leerem Prozess-PATH' -Success (
        $restoreCandidate.Provider -eq 'docker' -and
        $restoreCandidate.ContainerName -eq 'synthetic-container' -and
        $restoreCandidate.RunId -eq '11111111-1111-1111-1111-111111111111')

    $resolverText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\HostToolResolution.ps1') -Raw -Encoding utf8
    $dockerProviderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
    $podmanProviderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
    $runtimeScopeText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerRuntimeScope.ps1') -Raw -Encoding utf8
    $imageArtifactText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerImageArtifact.ps1') -Raw -Encoding utf8
    $storageResidencyText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\StorageResidencyInventory.ps1') -Raw -Encoding utf8
    $containerInstanceStoreText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerInstanceStore.ps1') -Raw -Encoding utf8
    $cleanupAuditText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Get-SqlServerLabCleanupAudit.ps1') -Raw -Encoding utf8
    $restoreText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Restore-SqlServerLabDatabase.ps1') -Raw -Encoding utf8
    $moduleLoaderText = Get-Content -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psm1') -Raw -Encoding utf8
    $mixedSmokeText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Invoke-MixedProviderSmokeTest.ps1') -Raw -Encoding utf8
    $batchSmokeText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1') -Raw -Encoding utf8
    $smokeMatrixText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Invoke-SmokeMatrix.ps1') -Raw -Encoding utf8
    $runtimeLifecyclePaths = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Private'),(Join-Path $repoRoot 'Public'),(Join-Path $repoRoot 'Providers') `
            -Recurse -File -Include '*.ps1','*.psm1'
    )
    $standaloneAcceptancePaths = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tests\Integration') -Recurse -File -Include '*.ps1','*.psm1'
    )
    $nakedRuntimeCommands = [Collections.Generic.List[string]]::new()
    $directRuntimeProbes = [Collections.Generic.List[string]]::new()
    $directAcceptanceRuntimeCalls = [Collections.Generic.List[string]]::new()
    foreach ($sourceFile in $runtimeLifecyclePaths) {
        $absolutePath = $sourceFile.FullName
        $relativePath = [IO.Path]::GetRelativePath($repoRoot,$absolutePath)
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($absolutePath,[ref]$tokens,[ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) { $nakedRuntimeCommands.Add("${relativePath}:parse:$($parseError.Message)") }
        foreach ($command in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('docker','podman')
        },$true))) {
            $nakedRuntimeCommands.Add("${relativePath}:$($command.Extent.StartLineNumber)")
        }
        $sourceText = Get-Content -LiteralPath $absolutePath -Raw -Encoding utf8
        if ($sourceText -match 'Get-Command\s+([''"]?(docker|podman)[''"]?|\$(candidateProvider|ProviderName|Provider|provider|runtime))\b') {
            $directRuntimeProbes.Add($relativePath)
        }
    }
    foreach ($sourceFile in $standaloneAcceptancePaths) {
        $absolutePath = $sourceFile.FullName
        $relativePath = [IO.Path]::GetRelativePath($repoRoot,$absolutePath)
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($absolutePath,[ref]$tokens,[ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) { $directAcceptanceRuntimeCalls.Add("${relativePath}:parse:$($parseError.Message)") }
        foreach ($command in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('docker','podman')
        },$true))) {
            $directAcceptanceRuntimeCalls.Add("${relativePath}:$($command.Extent.StartLineNumber)")
        }
        $sourceText = Get-Content -LiteralPath $absolutePath -Raw -Encoding utf8
        if ($sourceText -match '&\s+\$(candidateProvider|ProviderName|Provider|provider)\b' -or
            $sourceText -match 'Get-Command\s+([''"]?(docker|podman)[''"]?|\$(candidateProvider|ProviderName|Provider|provider|runtime))\b') {
            $directAcceptanceRuntimeCalls.Add($relativePath)
        }
    }
    $bootstrapText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1') -Raw -Encoding utf8
    $backupText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Invoke-BackupLibraryCrossProviderAcceptance.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Windows-Fallbacks decken Docker, Podman und lokale Python-Installationen zentral ab' -Success (
        $resolverText -match 'Docker\\Docker\\resources\\bin\\docker\.exe' -and
        $resolverText -match 'Programs\\Podman\\podman\.exe' -and
        $resolverText -match 'Programs\\Python')
    Add-CheckResult -Name 'Provider-Probes verwenden den zentral aufgeloesten absoluten Aufruf' -Success (
        $dockerProviderText -match 'Get-LabHostToolInvocation -Name docker' -and
        $dockerProviderText -match '& \$Invocation @Arguments' -and
        $podmanProviderText -match 'Get-LabHostToolInvocation -Name podman' -and
        $podmanProviderText -match '& \$podmanInvocation version')
    Add-CheckResult -Name 'Modulimport repariert Docker-, Podman- und Python-Auflösung prozesslokal' -Success (
        $moduleLoaderText -match 'Initialize-LabHostToolPath -Name docker,podman,python')
    Add-CheckResult -Name 'Produktive Aufrufpfade verwenden keine nackten Runtime-Befehle oder direkten PATH-Probes' -Success (
        $nakedRuntimeCommands.Count -eq 0 -and $directRuntimeProbes.Count -eq 0) `
        -Message ((@($nakedRuntimeCommands) + @($directRuntimeProbes)) -join ', ')
    Add-CheckResult -Name 'Eigenständige Runtime-Acceptances verwenden keine nackten oder providerindirekten PATH-Aufrufe' -Success (
        $directAcceptanceRuntimeCalls.Count -eq 0) `
        -Message (@($directAcceptanceRuntimeCalls) -join ', ')
    Add-CheckResult -Name 'Runtime-Evidence verwechselt einen eingeschraenkten PATH nicht mit fehlender Installation' -Success (
        $runtimeScopeText -match 'Resolve-LabHostTool -Name \$Provider' -and
        $runtimeScopeText -match 'Get-LabHostToolInvocation -Name \$Provider' -and
        $runtimeScopeText -notmatch 'Get-Command \$Provider' -and
        $imageArtifactText -match 'Get-LabHostToolInvocation -Name \$Provider' -and
        $imageArtifactText -notmatch 'Get-Command \$Provider')
    Add-CheckResult -Name 'Cleanup-Audit verwendet fuer Runtime-Inventar den zentral aufgeloesten Aufruf' -Success (
        $cleanupAuditText -match 'Resolve-LabHostTool -Name \$runtime' -and
        $cleanupAuditText -match 'Get-LabHostToolInvocation -Name \$runtime' -and
        $cleanupAuditText -match '& \$runtimeInvocation info' -and
        $cleanupAuditText -notmatch 'Get-Command \$runtime' -and
        $cleanupAuditText -notmatch '& \$runtime (info|volume|network)')
    Add-CheckResult -Name 'Restore-Zielsuche verwendet je Provider den zentral aufgeloesten absoluten Aufruf' -Success (
        $restoreText -match 'Resolve-LabHostTool -Name \$candidateProvider' -and
        $restoreText -match '& \$runtimeInvocation info' -and
        $restoreText -match '& \$runtimeInvocation inspect' -and
        $restoreText -notmatch 'Get-Command \$candidateProvider' -and
        $restoreText -notmatch '& \$candidateProvider')
    Add-CheckResult -Name 'Storage-Residency verwendet für Root und Volume den zentralen Runtime-Aufruf' -Success (
        @([regex]::Matches($storageResidencyText, 'Get-LabHostToolInvocation -Name \$Provider')).Count -ge 2 -and
        $storageResidencyText -notmatch '& \$Provider (info|volume)')
    Add-CheckResult -Name 'Container-Instanzstore verwendet für Inspect, Attachment und Clone den zentralen Runtime-Aufruf' -Success (
        @([regex]::Matches($containerInstanceStoreText, 'Get-LabHostToolInvocation -Name \$Provider')).Count -eq 2 -and
        $containerInstanceStoreText -notmatch '& \$Provider (ps|run|volume)')
    Add-CheckResult -Name 'Podman-Bootstrap ruft den zentral aufgelösten Pfad statt eines nackten Befehls auf' -Success (
        $bootstrapText -match 'Initialize-SqlServerLabHostTools\.ps1' -and
        $bootstrapText -match '& \$podmanInvocation info' -and
        $bootstrapText -notmatch '& podman')
    Add-CheckResult -Name 'Cross-Provider-Acceptance enthält keinen eigenen Podman-Installationspfad mehr' -Success (
        $backupText -match 'Initialize-SqlServerLabHostTools\.ps1' -and
        $backupText -notmatch 'Programs\\Podman\\podman\.exe')
    Add-CheckResult -Name 'Eigenständige Mixed-, Batch- und Matrix-Smokes umgehen den Host-Tool-Resolver nicht' -Success (
        $mixedSmokeText -match 'Initialize-SqlServerLabHostTools\.ps1' -and
        $mixedSmokeText -notmatch 'Get-Command \$Name' -and $mixedSmokeText -notmatch '& \$Name info' -and
        $batchSmokeText -match 'Initialize-SqlServerLabHostTools\.ps1' -and
        $batchSmokeText -notmatch 'Get-Command \$Name' -and $batchSmokeText -notmatch '& \$Name info' -and
        $smokeMatrixText -match 'Get-LabHostToolInvocation -Name \$Name' -and
        $smokeMatrixText -notmatch '& \$ProviderName inspect')
    $agentRulesText = Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw -Encoding utf8
    Add-CheckResult -Name 'Repository-Regeln verbieten ungeprüfte Nicht-vorhanden-Aussagen in neuen Agentprozessen' -Success (
        $agentRulesText -match 'Initialize-SqlServerLabHostTools\.ps1' -and
        $agentRulesText -match 'fehlende Auflösung, eine nicht erreichbare Runtime' -and
        $agentRulesText -match 'Benutzer- oder Maschinen-`PATH`')
}
catch {
    Add-CheckResult -Name 'Host-Tool-Resolver-Testausführung' -Success $false -Message $_.Exception.Message
}
finally {
    $env:PATH = $originalProcessPath
    foreach ($entry in $originalOverrides.GetEnumerator()) {
        if ($null -eq $entry.Value) { Remove-Item "Env:$($entry.Key)" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable([string]$entry.Key,[string]$entry.Value,'Process') }
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }
exit 0
