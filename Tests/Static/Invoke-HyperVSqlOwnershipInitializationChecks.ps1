#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-empty-trace-flags-'+[guid]::NewGuid().ToString('N'))
try {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1'),[ref]$null,[ref]$null)
    $command=$ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Initialize-LabHyperVSqlConfigurationOwnershipReceipt'},$true)
    if(-not $command){throw 'INITIALIZATION_CALL_MISSING'}
    $call=[scriptblock]::Create($command.Extent.Text)
    foreach($case in @('absent','null','empty','positive','zero')){
        $result=& $module {
            param($Root,$Case,$Call)
            $directory=Join-Path $Root $Case
            $null=New-Item -ItemType Directory -Path $directory -Force
            $lab=[pscustomobject]@{RunDirectory=$directory;Run=[pscustomobject]@{runId=[guid]::NewGuid().ToString();scopeId=[guid]::NewGuid().ToString()};Instance=[pscustomobject]@{id='primary';vmId='synthetic-vm'}}
            $config=switch($Case){'absent'{[pscustomobject]@{maxDop=2}};'null'{[pscustomobject]@{traceFlags=$null}};'empty'{[pscustomobject]@{traceFlags=@()}};'positive'{[pscustomobject]@{traceFlags=@(3226,3226)}};'zero'{[pscustomobject]@{traceFlags=@(0)}}}
            $plan=[pscustomobject]@{serverConfig=$config}
            $errorCode='';try{$null=& $Call}catch{$errorCode=$_.Exception.Message}
            $path=Get-LabHyperVSqlConfigurationOwnershipPath -RunDirectory $directory
            if($Case -eq 'zero'){return $errorCode -eq 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_TRACE_FLAG_INVALID' -and -not (Test-Path -LiteralPath $path)}
            if($errorCode){return $false}
            $receipt=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $null=Assert-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $receipt
            if($Case -eq 'positive'){return @($receipt.TraceFlags).Count -eq 1 -and $receipt.TraceFlags[0] -eq 3226}
            return @($receipt.TraceFlags).Count -eq 0
        } $testRoot $case $call
        if(-not $result){throw "FAIL: Trace-Flag-Initialisierung $case"}
        Write-Host "PASS: Trace-Flag-Initialisierung $case"
    }
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-empty-trace-flags-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
