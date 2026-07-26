[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}
$installer=Join-Path $RepositoryRoot 'Code/Install/Install_ExecutionPlanAnalysis.sql'
$builder=Join-Path $RepositoryRoot 'Code/Install/Build-ExecutionPlanAnalysisInstaller.ps1'
$manifest=Join-Path $RepositoryRoot 'Metadata/Inventory/ExecutionPlanAnalysisDependencies.csv'
foreach($path in @($installer,$builder,$manifest)) {
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fehlendes Teilinstaller-Artefakt: $path" }
}
$text=Get-Content -LiteralPath $installer -Raw -Encoding UTF8
$required=@(
'000_Preflight_und_Schema.sql','020_VW_AnalyseClassCatalog.sql','030_VW_AnalyseAccessPolicy.sql',
'040_VW_AnalyseAccessCurrent.sql','078_TVF_ParsePipeList.sql','085_TVF_ParseBigintList.sql','083a_USP_InternalCheckAnalysisPath.sql','095_USP_InternalWriteResultTable.sql','096_USP_InternalPrepareResultTables.sql',
'098_USP_InternalEmitConsoleResult.sql','041_PlanAnalysisProfile.sql','042_PlanAnalysisRuleThreshold.sql',
'043_PlanAnalysisProfileAssignment.sql','044_TVF_ParseStatisticsIoText.sql','045_TVF_ParseStatisticsTimeText.sql',
'046_TVF_ExecutionPlanObjectReferences.sql','047_TVF_ExecutionPlanStatisticsUsage.sql',
'048_TVF_ExecutionPlanColumnReferences.sql','049_InternalCollectExecutionPlanMetadata.sql',
'051_InternalAnalyzeExecutionPlan.sql','052_USP_CreateExecutionEvidenceJson.sql','053_USP_ExecutionPlanAnalysis.sql'
)
foreach($item in $required) { if($text -notmatch [regex]::Escape($item)) { throw "Teilinstaller enthält $item nicht." } }
$forbidden=@('USP_QueryStats.sql','USP_QueryHashAnalysis.sql','USP_PlanCacheHealth.sql','USP_PlanDetails.sql','USP_ShowplanAnalysis.sql','USP_PlanCacheAnalysis.sql','QueryStore','ExtendedEvents','ServerHealth')
foreach($item in $forbidden) { if($text -match [regex]::Escape($item)) { throw "Teilinstaller enthält unzulässigen Frameworkumfang: $item" } }
$rows=@(Import-Csv -LiteralPath $manifest -Encoding UTF8)
if($rows.Count -ne $required.Count+2) { throw "Dependency-Manifest besitzt eine unerwartete Zeilenanzahl." }

$builderText=Get-Content -LiteralPath $builder -Raw -Encoding UTF8
if($builderText -notmatch 'generated/Install_ExecutionPlanAnalysis\.generated\.sql') {
    throw 'PLAN_STANDALONE_DEFAULT_OUTPUT_DIRECTORY_INVALID'
}
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('sql-server-analyze-plan-' + [guid]::NewGuid().ToString('N'))
$outputPath=Join-Path $testDirectory 'nested/Install_ExecutionPlanAnalysis.generated.sql'
try {
    & $builder -RepositoryRoot $RepositoryRoot -OutputPath $outputPath
    if(-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'PLAN_STANDALONE_GENERATED_FILE_MISSING'
    }
    $generatedText=Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
    if($generatedText -match '(?im)^\s*:(?:r|ON\s+ERROR)\b') {
        throw 'PLAN_STANDALONE_SQLCMD_DIRECTIVE_FOUND'
    }
    $includeCount=@([Text.RegularExpressions.Regex]::Matches($text,'(?m)^\s*:r\s+(.+?)\s*$')).Count
    $sourceCount=@([Text.RegularExpressions.Regex]::Matches($generatedText,'(?m)^-- BEGIN SOURCE: (.+?)$')).Count
    if($sourceCount -ne $includeCount) { throw 'PLAN_STANDALONE_SOURCE_COUNT_INVALID' }
    $firstHash=(Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    & $builder -RepositoryRoot $RepositoryRoot -OutputPath $outputPath
    if((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash -ne $firstHash) {
        throw 'PLAN_STANDALONE_GENERATION_NOT_DETERMINISTIC'
    }
}
finally {
    if(Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}
Write-Host 'Execution Plan Analysis installer contract passed.'
