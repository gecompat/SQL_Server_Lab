#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$toolPath = Join-Path $repoRoot 'Tools/Initialize-SqlServerLabDataRoot.ps1'
$temporaryParent = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-cleanup-audit-$([Guid]::NewGuid().ToString('N'))"
$dataRoot = Join-Path $temporaryParent 'Lab_Data'
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Cleanup Audit Checks' -ForegroundColor Cyan
try {
    $receipt = & $toolPath -RootPath $dataRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $result = & $module {
        function docker {
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
            $global:LASTEXITCODE = 0
            if ($Arguments[0] -eq 'volume') { return 'sql-lab-synthetic-volume' }
            if ($Arguments[0] -eq 'network') { return 'sql-lab-synthetic-network' }
        }
        function Get-DockerLabContainers {
            return @([PSCustomObject]@{ ContainerId='synthetic'; Name='sql-lab-synthetic'; Status='exited'; RunId='missing-run'; ScopeId='synthetic-scope' })
        }
        return Get-SqlServerLabCleanupAudit
    }
    Add-CheckResult -Name 'Cleanup-Audit meldet bekannte Runtime-Reste' -Success ($result.Audit.Status -eq 'RESIDUALS' -and $result.Audit.Summary.ResidualCount -ge 3)
    Add-CheckResult -Name 'Orphan-Container wird ohne Loeschung ausgewiesen' -Success (@($result.Audit.Containers | Where-Object { $_.Orphan -and $_.Id -eq 'synthetic' }).Count -eq 1)
    Add-CheckResult -Name 'Benannte Runtime-Ressourcen werden inventarisiert' -Success ($result.Audit.ManagedVolumes[0].Name -eq 'sql-lab-synthetic-volume' -and $result.Audit.ManagedNetworks[0].Name -eq 'sql-lab-synthetic-network')
    Add-CheckResult -Name 'Audit wird im verwalteten Lab_Data gespeichert' -Success ($result.Path -and (Test-Path -LiteralPath $result.Path -PathType Leaf))
}
catch { Add-CheckResult -Name 'Cleanup-Audit-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
