#Requires -Version 7.2
<#
.SYNOPSIS
    Inventarisiert den aktuellen Repository-Quellstand ohne Runtime-Probes.
.DESCRIPTION
    Trennt implementierte/exportierte Befehle, deklarierte Provider-Capabilities,
    vorhandene Tests und Planungsreferenzen. Vorhandene Tests sind kein PASS.
    Liest nur Produktquellen; lokale State-, Secret- und Artifact-Roots werden
    nicht inventarisiert. Symlinks/Junctions werden nicht als Quelldaten gelesen.
    Ein optional vorhandener versionierter Nachweisindex wird separat als
    aufgezeichnete Historie ausgegeben. Er bestaetigt keine aktuelle Ausfuehrung.
.PARAMETER RepositoryRoot
    Zu inventarisierender Checkout, standardmaessig der Parent dieses Tools.
.EXAMPLE
    ./Tools/Get-SqlServerLabCapabilityInventory.ps1 | ConvertTo-Json -Depth 12
.OUTPUTS
    SqlServerLab.RepositoryCapabilityInventory/1.0 mit relativen Quellen und
    aktuellem SHA-256, Exporten, Providerdeklarationen und Test-/Planungsindex.
#>
[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$sources=[Collections.Generic.List[object]]::new()
$issues=[Collections.Generic.List[object]]::new()
$functions=[Collections.Generic.List[object]]::new()
$tasks=[Collections.Generic.List[object]]::new()
$directories=@('Private','Public','Providers','Tools','Tests','Schemas','Catalogs','Adapters','Images','Scenarios','Ui','.agents/skills','Documentation/Project_Planning')
$files=@(foreach($directory in $directories){
    $path=Join-Path $root $directory
    if(Test-Path -LiteralPath $path -PathType Container){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){$issues.Add([pscustomobject]@{Source=$directory;Code='REPARSE_POINT_NOT_READ'});continue}
        foreach($entry in Get-ChildItem -LiteralPath $path -Recurse -Force){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){
                $issues.Add([pscustomobject]@{Source=[IO.Path]::GetRelativePath($root,$entry.FullName).Replace('\','/');Code='REPARSE_POINT_NOT_READ'})
            }
            elseif(-not $entry.PSIsContainer -and $entry.Extension -in @('.ps1','.psm1','.psd1','.json','.js','.html','.css','.md')){$entry}
        }
    }
})
$files+=@(Get-ChildItem -LiteralPath $root -File | Where-Object Name -like '*.ps*1')
foreach($file in @($files | Sort-Object FullName -Unique)){
    $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){$issues.Add([pscustomobject]@{Source=$relative;Code='REPARSE_POINT_NOT_READ'});continue}
    $kind=switch -Regex ($relative){'^Tests/Static/'{'STATIC_TEST';break};'^Tests/Integration/'{'RUNTIME_TEST';break};'^Schemas/'{'SCHEMA';break};'^Catalogs/'{'CATALOG';break};'^Documentation/'{'PLANNING';break};'^\.agents/'{'SKILL';break};'^Ui/'{'BROWSER_UI';break};default{'SOURCE'}}
    $sources.Add([pscustomobject]@{Source=$relative;Kind=$kind;Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();Status='PRESENT'})
    if($file.Extension -in @('.ps1','.psm1')){
        $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$parseErrors)
        if($parseErrors.Count){$issues.Add([pscustomobject]@{Source=$relative;Code='POWERSHELL_PARSE_ERROR'})}
        foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
            $functions.Add([pscustomobject]@{Name=$definition.Name;Source=$relative;Line=$definition.Extent.StartLineNumber;Status='DEFINED'})
        }
    }
    elseif($file.Extension -eq '.json'){
        try {$null=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop}
        catch {$issues.Add([pscustomobject]@{Source=$relative;Code='JSON_PARSE_ERROR'})}
    }
    if($kind -eq 'PLANNING'){
        $lineNumber=0
        foreach($line in Get-Content -LiteralPath $file.FullName){
            $lineNumber++
            if($line -match '^\|\s*`(?<id>[A-Z][A-Z0-9]+-\d{2,4}[A-Z]?)`\s*\|(?<rest>.*)$'){
                $tasks.Add([pscustomobject]@{Id=$Matches.id;Source=$relative;Line=$lineNumber;PlanningText=$Matches.rest.Trim();EvidenceBoundary='PLANNING_ONLY'})
            }
        }
    }
}
$evidenceSource='Documentation/Quality/capability-evidence-index.json'
$evidencePath=Join-Path $root $evidenceSource
$evidenceStatus='NOT_PRESENT';$evidenceRecords=@()
try {
    $evidenceSchema=Join-Path $root 'Schemas/capability-evidence-index.schema.json'
    foreach($candidate in @($evidencePath,$evidenceSchema)){
        $ancestor=$candidate
        while($ancestor){
            if(Test-Path -LiteralPath $ancestor){
                if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'}
            }
            if($ancestor -eq $root){break}
            $ancestor=[IO.Path]::GetDirectoryName($ancestor)
        }
    }
    if(Test-Path -LiteralPath $evidencePath){
        $evidenceStatus='INVALID'
        $evidenceFile=Get-Item -LiteralPath $evidencePath -Force
        if($evidenceFile.PSIsContainer -or $evidenceFile.Length -gt 262144){throw 'EVIDENCE_INDEX_INVALID'}
        $evidenceText=Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8
        if(-not (Test-Json -Json $evidenceText -SchemaFile $evidenceSchema -ErrorAction Stop)){throw 'EVIDENCE_INDEX_INVALID'}
        $evidenceDocument=$evidenceText | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        foreach($record in $evidenceDocument.Records){
            $null=[DateTime]::ParseExact([string]$record.Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        }
        $evidenceRecords=@($evidenceDocument.Records | ForEach-Object {
            [pscustomobject]@{
                Capability=$_.Capability;Provider=$_.Provider;SqlVersion=$_.SqlVersion
                Platform=$_.Platform;Scope=$_.Scope;SourceRevision=$_.SourceRevision;Test=$_.Test
                Result=$_.Result;Cleanup=$_.Cleanup;Date=$_.Date;Reference=$_.Reference
                CurrentTestPresence=$(if(@($sources.Source) -ccontains $_.Test){'PRESENT'}else{'ABSENT'})
                CurrentExecutionStatus='NOT_EXECUTED';EvidenceBoundary='RECORDED_HISTORY_ONLY'
            }
        })
        $evidenceStatus='RECORDED'
    }
}
catch {
    $evidenceStatus='INVALID';$evidenceRecords=@()
    $code=if($_.Exception.Message -eq 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'){'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'}else{'EVIDENCE_INDEX_INVALID'}
    $issues.Add([pscustomobject]@{Source=$evidenceSource;Code=$code})
}
$exports=@();$providers=@();$module=$null
if(@($issues | Where-Object Code -in @('REPARSE_POINT_NOT_READ','POWERSHELL_PARSE_ERROR','EVIDENCE_INDEX_REPARSE_POINT_NOT_READ')).Count){
    $issues.Add([pscustomobject]@{Source='SqlServerLab.psd1';Code='MODULE_INVENTORY_NOT_EXECUTED'})
}
else {
try {
    $manifestPath=Join-Path $root 'SqlServerLab.psd1'
    $manifest=Import-PowerShellDataFile -Path $manifestPath
    $module=Import-Module $manifestPath -Force -PassThru -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false
    if((& $module {@($script:ModuleLoadErrors).Count}) -gt 0){$issues.Add([pscustomobject]@{Source='SqlServerLab.psm1';Code='MODULE_LOAD_INCOMPLETE'})}
    $exports=@(foreach($name in @($manifest.FunctionsToExport | Sort-Object)){
        $command=$module.ExportedCommands[$name]
        $source=if($command -and $command.ScriptBlock.File){[IO.Path]::GetRelativePath($root,$command.ScriptBlock.File).Replace('\','/')}else{$null}
        if(-not $command){$issues.Add([pscustomobject]@{Source='SqlServerLab.psd1';Code='EXPORT_MISSING'})}
        [pscustomobject]@{Name=$name;Source=$source;Status=$(if($command){'EXPORTED'}else{'MISSING'});Parameters=@(if($command){$command.Parameters.Keys | Sort-Object})}
    })
    $providers=@(& $module {Get-LabProviderCapabilityContract} | ForEach-Object {
        $providerName=$_.Provider
        $providerSource=@($sources.Source | Where-Object {$_ -ieq "Providers/$providerName/provider.json"})
        [pscustomobject]@{Provider=$_.Provider;Source=$providerSource[0];DeclaredRuntimeStatus=$_.RuntimeStatus;Capabilities=@($_.Capabilities.SourceKey);Limitations=@($_.Limitations.SourceKey);EvidenceBoundary='PROVIDER_METADATA_ONLY'}
    })
}
catch {$issues.Add([pscustomobject]@{Source='SqlServerLab.psd1';Code='MODULE_INVENTORY_FAILED'})}
}
[pscustomobject]@{
    ContractVersion='SqlServerLab.RepositoryCapabilityInventory/1.0'
    Status=$(if($issues.Count){'PARTIAL'}else{'INVENTORIED'})
    SourceScope='WORKING_TREE';MutationAllowed=$false
    RuntimeEvidence=[pscustomobject]@{Status='NOT_EXECUTED';Assessed=$false}
    RecordedEvidence=[pscustomobject]@{Source=$evidenceSource;Status=$evidenceStatus;EvidenceBoundary='RECORDED_HISTORY_ONLY';ReferenceVerificationStatus='NOT_VERIFIED';Records=$evidenceRecords}
    Sources=@($sources);Functions=@($functions);Exports=$exports;Providers=$providers
    Tests=@($sources | Where-Object Kind -in @('STATIC_TEST','RUNTIME_TEST') | ForEach-Object {[pscustomobject]@{Source=$_.Source;Kind=$_.Kind;ExecutionStatus='NOT_EXECUTED'}})
    PlanningReferences=@($tasks);Issues=@($issues)
}
