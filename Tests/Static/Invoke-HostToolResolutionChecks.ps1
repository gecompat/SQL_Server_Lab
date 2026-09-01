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
    $dockerLeaf = if ($IsWindows) { 'docker.exe' } else { 'docker' }
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

    $resolverText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\HostToolResolution.ps1') -Raw -Encoding utf8
    $dockerProviderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
    $podmanProviderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
    $runtimeScopeText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerRuntimeScope.ps1') -Raw -Encoding utf8
    $imageArtifactText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerImageArtifact.ps1') -Raw -Encoding utf8
    $storageResidencyText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\StorageResidencyInventory.ps1') -Raw -Encoding utf8
    $containerInstanceStoreText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ContainerInstanceStore.ps1') -Raw -Encoding utf8
    $cleanupAuditText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Get-SqlServerLabCleanupAudit.ps1') -Raw -Encoding utf8
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
    Add-CheckResult -Name 'Storage-Residency verwendet für Root und Volume den zentralen Runtime-Aufruf' -Success (
        @([regex]::Matches($storageResidencyText, 'Get-LabHostToolInvocation -Name \$Provider')).Count -eq 2 -and
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
