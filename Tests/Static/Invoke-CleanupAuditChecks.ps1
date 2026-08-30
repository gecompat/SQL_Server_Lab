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
        function Get-VM { @() }
        function Get-VMHardDiskDrive { @() }

        $stateRoot = Get-LabStateRoot
        $run = New-LabRunState -StateRoot $stateRoot -Metadata @{ name='cleanup-audit-hyperv'; workflowKind='hyperv-lab' } `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
        $binding = Initialize-LabHyperVResourceBinding -ResourceId $run.RunId -ResourceClass Run -StateDirectory $run.RunDir
        $null = New-Item -Path $binding.HyperVResourceRoot -ItemType Directory -Force
        $protectedVhdx = Join-Path $binding.HyperVResourceRoot 'protected-child.vhdx'
        $untrackedFile = Join-Path $binding.HyperVResourceRoot 'foreign-note.txt'
        $null = New-Item -Path $protectedVhdx -ItemType File -Force
        Set-Content -LiteralPath $untrackedFile -Value 'foreign-preserve' -Encoding utf8
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv' })
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType vhdx -ResourceId $protectedVhdx `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv

        $migrationPath = Join-Path $run.RunDir 'hyperv-resource-migration.local.journal.json'
        Write-LabArtifactJsonAtomic -Path $migrationPath -InputObject ([PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVResourceMigrationJournal/1.0'; Status='RECOVERY_REQUIRED'
        })
        $auditResult = Get-SqlServerLabCleanupAudit
        $migrationBlocked = Invoke-CleanupPlan -RunDir $run.RunDir -ScopeId $run.ScopeId
        $protectedAfterMigrationBlock = Test-Path -LiteralPath $protectedVhdx -PathType Leaf

        Write-LabArtifactJsonAtomic -Path $migrationPath -InputObject ([PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVResourceMigrationJournal/1.0'; Status='COMPLETED'
        })
        $cleanupPlanPath = Join-Path $run.RunDir 'cleanup-plan.json'
        $cleanupPlan = Get-Content -LiteralPath $cleanupPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        foreach ($step in @($cleanupPlan.steps)) { $step.state='PENDING'; $step.error=$null; $step.executedAt=$null }
        $cleanupPlan.status='PENDING'
        Write-LabArtifactJsonAtomic -Path $cleanupPlanPath -InputObject $cleanupPlan

        $imageState = Join-Path $stateRoot 'artifacts/hyperv/cleanup-audit-image-state'
        $null = New-Item -Path $imageState -ItemType Directory -Force
        $imageBinding = Initialize-LabHyperVResourceBinding -ResourceId 'cleanup-audit-shared-image' `
            -ResourceClass Image -StateDirectory $imageState
        $imageDirectory = Join-Path $imageBinding.HyperVResourceRoot 'shared-artifact'
        $null = New-Item -Path $imageDirectory -ItemType Directory -Force
        $sharedParent = Join-Path $imageDirectory 'parent.vhdx'
        $null = New-Item -Path $sharedParent -ItemType File -Force
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType vhdx -ResourceId $sharedParent `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv
        $foreignBlocked = Invoke-CleanupPlan -RunDir $run.RunDir -ScopeId $run.ScopeId

        $cleanRun = New-LabRunState -StateRoot $stateRoot -Metadata @{ name='cleanup-audit-valid-hyperv'; workflowKind='hyperv-lab' } `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
        $cleanBinding = Initialize-LabHyperVResourceBinding -ResourceId $cleanRun.RunId -ResourceClass Run -StateDirectory $cleanRun.RunDir
        $null = New-Item -Path $cleanBinding.HyperVResourceRoot -ItemType Directory -Force
        $cleanChild = Join-Path $cleanBinding.HyperVResourceRoot 'owned-child.vhdx'
        $null = New-Item -Path $cleanChild -ItemType File -Force
        $externalDirectory = Join-Path $cleanBinding.LabDataRoot 'Labs/lab/Instances/hyperv/primary/Storage/sqldata'
        $null = New-Item -Path $externalDirectory -ItemType Directory -Force
        $cleanPrefix = $cleanRun.RunId.Replace('-','').Substring(0,8).ToLowerInvariant()
        $cleanExternal = Join-Path $externalDirectory "owned-$cleanPrefix-sfp-02.vhdx"
        $null = New-Item -Path $cleanExternal -ItemType File -Force
        $null = New-CleanupPlan -RunDir $cleanRun.RunDir -RunId $cleanRun.RunId -ScopeId $cleanRun.ScopeId `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv' })
        $null = Add-CleanupStep -RunDir $cleanRun.RunDir -ResourceType vhdx -ResourceId $cleanChild `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv
        $null = Add-CleanupStep -RunDir $cleanRun.RunDir -ResourceType vhdx -ResourceId $cleanExternal `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv -SafetyRoot $cleanBinding.LabDataRoot
        $validCleanup = Invoke-CleanupPlan -RunDir $cleanRun.RunDir -ScopeId $cleanRun.ScopeId

        $buildId = New-LabGuid
        $buildScopeId = New-LabGuid
        $buildDirectory = Join-Path (Join-Path $stateRoot 'image-builds/hyperv') $buildId
        $null = New-Item -Path $buildDirectory -ItemType Directory -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $buildDirectory 'build-state.json') -InputObject ([PSCustomObject]@{
            buildId=$buildId; scopeId=$buildScopeId; state='TEST_ARTIFACT_PUBLISHED'
        })
        $buildBinding = Initialize-LabHyperVResourceBinding -ResourceId $buildId -ResourceClass Build `
            -StateDirectory $buildDirectory
        $null = New-Item -Path $buildBinding.HyperVResourceRoot -ItemType Directory -Force
        $buildVhdx = Join-Path $buildBinding.HyperVResourceRoot 'builder.vhdx'
        $null = New-Item -Path $buildVhdx -ItemType File -Force
        $null = New-CleanupPlan -RunDir $buildDirectory -RunId $buildId -ScopeId $buildScopeId `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv-builder'; provider='hyperv' })
        $null = Add-CleanupStep -RunDir $buildDirectory -ResourceType vhdx -ResourceId $buildVhdx `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv-builder
        $buildCleanup = Invoke-CleanupPlan -RunDir $buildDirectory -ScopeId $buildScopeId

        [PSCustomObject]@{
            Path=$auditResult.Path; Audit=$auditResult.Audit; RunId=$run.RunId
            ProtectedVhdx=$protectedVhdx; UntrackedFile=$untrackedFile; SharedParent=$sharedParent
            MigrationBlocked=$migrationBlocked; ForeignBlocked=$foreignBlocked
            ProtectedAfterMigrationBlock=$protectedAfterMigrationBlock
            ProtectedAfterForeignBlock=(Test-Path -LiteralPath $protectedVhdx -PathType Leaf)
            SharedParentPreserved=(Test-Path -LiteralPath $sharedParent -PathType Leaf)
            ValidCleanup=$validCleanup
            ValidChildRemoved=(-not (Test-Path -LiteralPath $cleanChild -PathType Leaf))
            ValidExternalRemoved=(-not (Test-Path -LiteralPath $cleanExternal -PathType Leaf))
            BuildCleanup=$buildCleanup
            BuildVhdxRemoved=(-not (Test-Path -LiteralPath $buildVhdx -PathType Leaf))
        }
    }
    Add-CheckResult -Name 'Cleanup-Audit meldet bekannte Runtime-Reste' -Success ($result.Audit.Status -eq 'RESIDUALS' -and $result.Audit.Summary.ResidualCount -ge 3)
    Add-CheckResult -Name 'Erweiterter Cleanup-Audit erfüllt das versionierte Schema' -Success (
        (($result.Audit | ConvertTo-Json -Depth 50) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-cleanup-audit.schema.json') -ErrorAction SilentlyContinue))
    Add-CheckResult -Name 'Orphan-Container wird ohne Loeschung ausgewiesen' -Success (@($result.Audit.Containers | Where-Object { $_.Orphan -and $_.Id -eq 'synthetic' }).Count -eq 1)
    Add-CheckResult -Name 'Benannte Runtime-Ressourcen werden inventarisiert' -Success ($result.Audit.ManagedVolumes[0].Name -eq 'sql-lab-synthetic-volume' -and $result.Audit.ManagedNetworks[0].Name -eq 'sql-lab-synthetic-network')
    Add-CheckResult -Name 'Audit wird im verwalteten Lab_Data gespeichert' -Success ($result.Path -and (Test-Path -LiteralPath $result.Path -PathType Leaf))
    $runScope = @($result.Audit.HyperV.RunScopes | Where-Object RunId -eq $result.RunId) | Select-Object -First 1
    Add-CheckResult -Name 'Hyper-V-Run-Binding und Recovery-Journal werden gemeinsam auditiert' -Success (
        $runScope.BindingStatus -eq 'VALID' -and $runScope.MigrationStatus -eq 'RECOVERY_REQUIRED' -and
        $result.Audit.Summary.HyperVProtectionIssues -ge 1)
    Add-CheckResult -Name 'Cleanup-Schritt ist am revalidierten Run-Root geschützt' -Success (
        @($runScope.CleanupResources | Where-Object { $_.ProtectionStatus -eq 'PROTECTED' -and $_.Path -eq $result.ProtectedVhdx }).Count -eq 1)
    Add-CheckResult -Name 'Ungetrackte Run-Datei wird nur als Preserve-Befund gemeldet' -Success (
        @($result.Audit.HyperV.UntrackedFiles | Where-Object { $_.Path -eq $result.UntrackedFile -and $_.Preservation -eq 'PRESERVE_UNTRACKED' }).Count -eq 1 -and
        (Test-Path -LiteralPath $result.UntrackedFile -PathType Leaf))
    Add-CheckResult -Name 'Nichtterminales Migrationsjournal blockiert Cleanup vor jeder Mutation' -Success (
        $result.MigrationBlocked.Status -eq 'CLEANUP_BLOCKED' -and $result.ProtectedAfterMigrationBlock)
    Add-CheckResult -Name 'Manipulierter Shared-Image-Schritt blockiert atomar und bewahrt alle Dateien' -Success (
        $result.ForeignBlocked.Status -eq 'CLEANUP_BLOCKED' -and $result.ProtectedAfterForeignBlock -and $result.SharedParentPreserved)
    Add-CheckResult -Name 'Shared Image-Roots sind ausdrücklich nur zur Bewahrung inventarisiert' -Success (
        @($result.Audit.HyperV.SharedRoots | Where-Object { $_.ResourceClass -eq 'Image' -and $_.Preservation -eq 'PRESERVE_SHARED' }).Count -ge 1)
    Add-CheckResult -Name 'Gültiger Plan entfernt Run-Root und registrierte Zusatzlaufwerks-VHDX' -Success (
        $result.ValidCleanup.Status -eq 'CLEANUP_SUCCEEDED' -and $result.ValidCleanup.Steps -eq 2 -and
        $result.ValidChildRemoved -and $result.ValidExternalRemoved)
    Add-CheckResult -Name 'Image-Builder-Cleanup validiert Build-State und Build-Binding gemeinsam' -Success (
        $result.BuildCleanup.Status -eq 'CLEANUP_SUCCEEDED' -and $result.BuildVhdxRemoved)
}
catch { Add-CheckResult -Name 'Cleanup-Audit-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
