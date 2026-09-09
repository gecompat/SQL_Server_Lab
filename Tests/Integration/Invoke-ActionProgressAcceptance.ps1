#Requires -Version 7.2
<#
.SYNOPSIS Prueft den nativen Fortschrittswrapper mit einem isolierten Provider-Build.
.DESCRIPTION Baut ohne Download ein synthetisches Scratch-Image. Entfernt nur
    das eigene, labelgebundene Image und den eigenen temporaeren Kontext.
    SQL-Readiness bleibt im getrennten SQL-2025-Smoke nachzuweisen.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resolution = @(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
if (-not $resolution.Available) { throw 'PROGRESS_ACCEPTANCE_RUNTIME_MISSING' }
$runtime = [string]$resolution.Invocation
$operation = [guid]::NewGuid().ToString('N')
$tag = "sql-server-lab/progress-acceptance:$operation"
$context = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-progress-build-$operation"
$imageId = $null
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
try {
    $null = New-Item -ItemType Directory -Path $context
    # Der Plan existiert vor der ersten Provider-Mutation.
    [ordered]@{Provider=$Provider;Operation=$operation;Tag=$tag;Cleanup='VERIFY_LABEL_AND_REMOVE_IMAGE'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $context 'plan.json')
    [IO.File]::WriteAllText((Join-Path $context 'payload'), 'synthetic-payload')
    [IO.File]::WriteAllText((Join-Path $context 'Containerfile'), "FROM scratch`nLABEL sql-server-lab.progress-test=$operation`nCOPY payload /payload`n")
    $result = & (Get-Module SqlServerLab) {
        param($Executable,$ContextPath,$ImageTag)
        Invoke-LabProgressNativeCommand -FilePath $Executable -ArgumentList @('build','--file',(Join-Path $ContextPath 'Containerfile'),'--tag',$ImageTag,$ContextPath) -Phase ImageBuild -TimeoutSeconds 120
    } $runtime $context $tag
    if ($result.ExitCode -ne 0) { throw 'PROGRESS_ACCEPTANCE_BUILD_FAILED' }
    $inspection = @(& $runtime image inspect $tag 2>$null | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $inspection.Count -ne 1 -or [string]$inspection[0].Config.Labels.'sql-server-lab.progress-test' -ne $operation) { throw 'PROGRESS_ACCEPTANCE_IMAGE_BINDING_FAILED' }
    $imageId = [string]$inspection[0].Id
    Write-Host "PASS: $Provider baut ueber den Fortschrittswrapper mit exakten Argumenten"
}
finally {
    try {
        $remaining = @(& $runtime image inspect $tag 2>$null | ConvertFrom-Json)
        if ($LASTEXITCODE -eq 0) {
            if ($remaining.Count -ne 1 -or [string]$remaining[0].Config.Labels.'sql-server-lab.progress-test' -ne $operation -or
                ($imageId -and [string]$remaining[0].Id -ne $imageId)) { throw 'PROGRESS_ACCEPTANCE_CLEANUP_OWNERSHIP_FAILED' }
            & $runtime image rm $tag 1>$null 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'PROGRESS_ACCEPTANCE_CLEANUP_FAILED' }
            $null = & $runtime image inspect $tag 2>$null
            if ($LASTEXITCODE -eq 0) { throw 'PROGRESS_ACCEPTANCE_IMAGE_REMAINS' }
        }
        Write-Host "PASS: $Provider hinterlaesst kein Test-Image"
    }
    finally {
        $resolvedContext = [IO.Path]::GetFullPath($context)
        $boundary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedContext.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedContext) -ne "sql-lab-progress-build-$operation") { throw 'PROGRESS_ACCEPTANCE_CLEANUP_SCOPE_FAILED' }
        if (Test-Path -LiteralPath $resolvedContext) { Remove-Item -LiteralPath $resolvedContext -Recurse -Force }
    }
}
