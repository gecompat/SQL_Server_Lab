#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$path=Join-Path $repo 'Tests/Integration/Invoke-PortableContainerTransferPreflightAcceptance.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
$outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($outer.Count -ne 1){throw 'Acceptance cleanup boundary changed'}
$text=$outer[0].Finally.Extent.Text
$cleanupBlock=[scriptblock]::Create($text.Substring(1,$text.Length-2))
$passed=0
foreach($mode in @('local','owned')){
    foreach($scenario in @('success','run-failure','store-failure','unreturned','keep-failure')){
        $parent=Join-Path ([IO.Path]::GetTempPath()) ('preflight-cleanup-check-'+[guid]::NewGuid().ToString('N'))
        $requestedStateRoot=if($mode -eq 'owned'){$parent}else{$null}
        $testRoot=Join-Path $(if($requestedStateRoot){Join-Path $parent 'test-artifacts'}else{$parent}) ('sql-lab-transfer-preflight-'+[guid]::NewGuid().ToString('N'))
        # Local acceptance requires the real system-temp boundary.
        if($mode -eq 'local'){$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-transfer-preflight-'+[guid]::NewGuid().ToString('N'))}
        $null=New-Item -ItemType Directory -Path $testRoot -Force
        $stateRoot=$parent;$dataRoot=Join-Path $parent 'data'
        $sourceLab=[pscustomobject]@{RunId='source'};$targetLab=[pscustomobject]@{RunId='target'}
        $completed=$scenario -ne 'keep-failure';$KeepOnFailure=$scenario -eq 'keep-failure'
        $cleanupFailed=$false;$mutex=$null;$previousStateRoot=$env:SQL_SERVER_LAB_STATE;$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
        $script:unreturnedCreation=$scenario -eq 'unreturned'
        $script:runCalls=0;$script:storeCalls=0;$script:directoryCalls=0
        function Remove-SqlServerLab {
            [CmdletBinding(SupportsShouldProcess)]
            param($RunId,$StateRoot,[switch]$Force)
            $script:runCalls++;if($scenario -eq 'run-failure'){throw 'injected cleanup failure'};[pscustomobject]@{Status='REMOVED'}
        }
        function Get-SqlServerLabRetainedStoreRemovalPlan {param($PersistentStorageId,$DataRoot,$StateRoot)
            if($scenario -eq 'store-failure'){throw 'injected store failure'}
            [pscustomobject]@{Status='READY';CatalogRevision=7;PlanKey='test-plan'}
        }
        function Invoke-SqlServerLabRetainedStoreRemoval {
            [CmdletBinding(SupportsShouldProcess)]
            param($PersistentStorageId,$DataRoot,$StateRoot,$ExpectedCatalogRevision,$ExpectedPlanKey)
            if($PersistentStorageId -ne [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -or $ExpectedCatalogRevision -ne 7 -or $ExpectedPlanKey -ne 'test-plan'){throw 'Wrong store binding'}
            $script:storeCalls++;[pscustomobject]@{Status='REMOVED'}
        }
        function Remove-OwnedHostTestDataRoot {param($StateRoot,$DataRoot)$script:directoryCalls++}
        function Remove-Module {param($Name,[switch]$Force,$ErrorAction)}
        $module=New-Module -ScriptBlock {
            function Get-LabRunState {param($RunId,$StateRoot)
                [pscustomobject]@{metadata=[pscustomobject]@{desiredState=[pscustomobject]@{Instances=@([pscustomobject]@{Intents=[pscustomobject]@{Drives=@([pscustomobject]@{Id='persistent-mssql';Persistence='data-root-runtime-volume';PersistentStorageId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'})}})}}}
            }
        }
        try {
            . $cleanupBlock
            $failure=$scenario -in @('run-failure','store-failure','unreturned')
            if($cleanupFailed -ne $failure){throw "Incorrect cleanup outcome: $mode/$scenario"}
            $expectedStore=if($scenario -in @('success','keep-failure')){1}else{0}
            if($script:runCalls -ne 2 -or $script:storeCalls -ne $expectedStore){throw "Run/store cleanup missing: $mode/$scenario"}
            $preserve=$failure -or $KeepOnFailure
            if((Test-Path -LiteralPath $testRoot) -ne $preserve){throw "Recovery state disposition wrong: $mode/$scenario"}
            $passed++
        }finally{
            Microsoft.PowerShell.Core\Remove-Module $module -Force
            if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
            if(Test-Path -LiteralPath $parent){Remove-Item -LiteralPath $parent -Recurse -Force}
        }
    }
}
Write-Host "TRANSFER PREFLIGHT ACCEPTANCE CLEANUP: PASS ($passed actual-finally scenarios; no provider access)"
