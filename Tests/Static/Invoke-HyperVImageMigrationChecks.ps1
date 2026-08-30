#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryParent=Join-Path ([IO.Path]::GetTempPath()) "hvi-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$stateRoot=Join-Path $temporaryParent 'state'
$dataRoot=Join-Path $temporaryParent 'managed/Lab_Data'
$failures=[Collections.Generic.List[string]]::new(); $passed=0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Image Migration Checks' -ForegroundColor Cyan
try {
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
    $result=& $module {
        param($StateRoot,$ManagedRoot,$PlanSchema,$JournalSchema)
        $null=Initialize-LabManagedDataRoot -DataRoot $ManagedRoot -Confirm:$false
        $legacyRoot=Join-Path $StateRoot 'artifacts/hyperv/images'
        New-Item -Path $legacyRoot -ItemType Directory -Force | Out-Null
        $parentBytes=[Text.Encoding]::ASCII.GetBytes('vhdxfile-synthetic-legacy-parent')
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($parentBytes)).ToLowerInvariant()
        $artifactId="hyperv-lifecycle-test-only-$sha"
        $artifactRoot=Join-Path $legacyRoot $artifactId
        New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null
        $sourceParent=Join-Path $artifactRoot 'parent.vhdx'
        [IO.File]::WriteAllBytes($sourceParent,$parentBytes)
        (Get-Item -LiteralPath $sourceParent).IsReadOnly=$true
        [PSCustomObject]@{
            contractVersion='1'; artifactId=$artifactId; displayName='Legacy synthetic image'
            artifactState='LIFECYCLE_TEST_ONLY'; sha256=$sha; integrityOrigin='synthetic-test'
            registeredAt=Get-LabTimestamp; generalized=$true; sqlPrepared=$false
            operatingSystem=[PSCustomObject]@{ id='synthetic-ci'; version='test'; edition='test'; installationType='synthetic'; language='en-US'; architecture='x64' }
            sql=$null; license=[PSCustomObject]@{ type='test-only'; evaluationExpiresAt=$null }
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $artifactRoot 'metadata.json') -Encoding utf8
        $consumerRoot=Join-Path $StateRoot 'runs/synthetic/resources/hyperv'
        New-Item -Path $consumerRoot -ItemType Directory -Force | Out-Null
        $consumer=Join-Path $consumerRoot 'child.vhdx'
        [IO.File]::WriteAllBytes($consumer,[Text.Encoding]::ASCII.GetBytes('vhdxfile-synthetic-child'))
        $script:consumerParent=$sourceParent
        function Get-VHD { param($Path); [PSCustomObject]@{ Path=[IO.Path]::GetFullPath($Path); ParentPath=if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($consumer)) { $script:consumerParent } else { $null } } }
        function Get-VM { @() }
        function Get-VMHardDiskDrive { param($VM); @() }

        $initial=New-LabHyperVImageMigrationPlan -StateRoot $StateRoot -DataRoot $ManagedRoot
        $conflictDirectory=[string]$initial.Plan.Inventory.Artifacts[0].DestinationDirectory
        New-Item -Path $conflictDirectory -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $conflictDirectory 'unexpected.txt'),'conflict')
        $blocked=New-LabHyperVImageMigrationPlan -StateRoot $StateRoot -DataRoot $ManagedRoot
        Remove-Item -LiteralPath $conflictDirectory -Recurse -Force
        $ready=New-LabHyperVImageMigrationPlan -StateRoot $StateRoot -DataRoot $ManagedRoot
        $ready.Plan.Source.Root=Join-Path $StateRoot 'tampered-images'
        Write-LabArtifactJsonAtomic -Path $ready.Path -InputObject $ready.Plan
        $tamperedMessage=try { Invoke-LabHyperVImageMigration -PlanPath $ready.Path -DataRoot $ManagedRoot -Confirm:$false | Out-Null; '' } catch { $_.Exception.Message }
        $ready=New-LabHyperVImageMigrationPlan -StateRoot $StateRoot -DataRoot $ManagedRoot
        $targetDirectory=[string]$ready.Plan.Inventory.Artifacts[0].DestinationDirectory
        $whatIf=Invoke-LabHyperVImageMigration -PlanPath $ready.Path -DataRoot $ManagedRoot -WhatIf
        $whatIfClean=-not (Test-Path -LiteralPath $targetDirectory) -and -not (Test-Path -LiteralPath (Join-Path $StateRoot 'artifacts/hyperv/image-store-state/hyperv-resource-binding.local.json'))
        $waiting=Invoke-LabHyperVImageMigration -PlanPath $ready.Path -DataRoot $ManagedRoot -Confirm:$false
        $journalWaiting=Get-Content -LiteralPath $waiting.JournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        $targetParent=Join-Path $targetDirectory 'parent.vhdx'
        $copyValid=(Test-Path -LiteralPath $targetParent -PathType Leaf) -and (Get-FileHash -LiteralPath $targetParent -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sha -and (Get-Item -LiteralPath $targetParent).IsReadOnly
        $sourceRetained=Test-Path -LiteralPath $sourceParent -PathType Leaf
        $script:consumerParent=$targetParent
        $completed=Invoke-LabHyperVImageMigration -PlanPath $ready.Path -DataRoot $ManagedRoot -Confirm:$false
        $idempotent=Invoke-LabHyperVImageMigration -PlanPath $ready.Path -DataRoot $ManagedRoot -Confirm:$false
        $journalJson=Get-Content -LiteralPath $completed.JournalPath -Raw -Encoding utf8
        $journal=$journalJson | ConvertFrom-Json -Depth 50
        $binding=Read-LabHyperVResourceBinding -StateDirectory (Join-Path $StateRoot 'artifacts/hyperv/image-store-state') -DataRoot $ManagedRoot
        [PSCustomObject]@{
            Blocked=$blocked.Plan; TamperedMessage=$tamperedMessage; Ready=$ready.Plan
            PlanSchemaValid=(($ready.Plan | ConvertTo-Json -Depth 60) | Test-Json -SchemaFile $PlanSchema -ErrorAction SilentlyContinue)
            WhatIf=$whatIf; WhatIfClean=$whatIfClean; Waiting=$waiting; JournalWaiting=$journalWaiting
            CopyValid=$copyValid; SourceRetained=$sourceRetained; Completed=$completed; Idempotent=$idempotent
            Journal=$journal; JournalSchemaValid=($journalJson | Test-Json -SchemaFile $JournalSchema -ErrorAction SilentlyContinue)
            Binding=$binding; SourceParent=$sourceParent; TargetParent=$targetParent; LegacyRoot=$legacyRoot
        }
    } $stateRoot $dataRoot (Join-Path $repoRoot 'Schemas/hyperv-image-migration-plan.schema.json') (Join-Path $repoRoot 'Schemas/hyperv-image-migration-journal.schema.json')

    Add-CheckResult -Name 'Legacy-Image erzeugt schema-validen Plan mit Child-Graph' -Success (
        $result.Ready.Status -eq 'READY' -and $result.PlanSchemaValid -and $result.Ready.Inventory.ArtifactCount -eq 1 -and
        @($result.Ready.Inventory.Artifacts[0].Consumers).Count -eq 1
    )
    Add-CheckResult -Name 'Fremdbelegtes Ziel blockiert vor der Migration' -Success (
        $result.Blocked.Status -eq 'BLOCKED' -and @($result.Blocked.Blockers | Where-Object { $_ -match 'TARGET_CONFLICT' }).Count -eq 1
    )
    Add-CheckResult -Name 'Manipulierter Plan kann den Legacy-Root nicht ändern' -Success ($result.TamperedMessage -match 'HYPERV_IMAGE_MIGRATION_SOURCE_ROOT_CHANGED')
    Add-CheckResult -Name 'WhatIf schreibt weder Ziel noch Binding' -Success ($null -eq $result.WhatIf -and $result.WhatIfClean)
    Add-CheckResult -Name 'Erster Apply veröffentlicht hashidentisch und wartet auf Consumer' -Success (
        $result.Waiting.Status -eq 'WAITING_FOR_CONSUMERS' -and $result.CopyValid -and $result.SourceRetained -and
        $result.JournalWaiting.BindingCommitted -and @($result.JournalWaiting.SourceRetention).Count -eq 1
    )
    Add-CheckResult -Name 'Binding zeigt auf registrierten Lab_Data-Image-Store' -Success (
        $result.Binding -and $result.TargetParent -like "$($result.Binding.HyperVResourceRoot)*"
    )
    Add-CheckResult -Name 'Resume entfernt Quelle erst nach simuliertem Child-Reparent' -Success (
        $result.Completed.Status -eq 'COMPLETED' -and -not (Test-Path -LiteralPath $result.SourceParent) -and -not (Test-Path -LiteralPath $result.LegacyRoot)
    )
    Add-CheckResult -Name 'Abschluss ist idempotent und journal-schema-valid' -Success (
        $result.Idempotent.Status -eq 'COMPLETED' -and $result.Journal.Status -eq 'COMPLETED' -and $result.JournalSchemaValid -and
        @($result.Journal.SourceCleanup).Count -eq 1
    )
}
catch { Add-CheckResult -Name 'Hyper-V-Image-Migration-Testausführung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
