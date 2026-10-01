#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-handoff-check-'+[guid]::NewGuid().ToString('N'))
$text=Get-Content (Join-Path $repo 'Documentation/HowTo/OPERATOR_DIAGNOSTIC_HANDOFF.md') -Raw
$match=[regex]::Match($text,'<!-- OPERATOR_DIAGNOSTIC_RECIPE:BEGIN -->\s*```powershell\r?\n(?<code>.*?)\r?\n```\s*<!-- OPERATOR_DIAGNOSTIC_RECIPE:END -->','Singleline')
if(-not $match.Success){throw 'HANDOFF_RECIPE_MISSING'}
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
try {
    & $module {
        param($Root,$Repo,$Code)
        $script:handoffAssertions=0;$script:handoffApiCalls=0;$script:handoffProbeCalls=0
        function Assert-Handoff {param([bool]$Pass,[string]$Name)
            if(-not $Pass){throw "HANDOFF_CHECK_FAILED: $Name"}
            $script:handoffAssertions++;Write-Host "PASS: $Name"
        }
        $script:handoffActualApi=${function:Get-SqlServerLabDiagnosticBundle}
        function Get-SqlServerLabDiagnosticBundle {
            [CmdletBinding()]param($RunId,$InstanceId,$DataRoot,$Provider,$Operation='Inspect',[switch]$SkipReadiness)
            $script:handoffApiCalls++
            & $script:handoffActualApi @PSBoundParameters
        }
        function Invoke-LabDiagnosticReadinessProcess {
            param($Provider,$Operation)
            $script:handoffProbeCalls++
            [pscustomobject]@{Success=$true;Reason='NONE';Value=[pscustomobject]@{
                ContractVersion='SqlServerLab.DiagnosticProviderReadiness/1.0';Provider=$Provider;Operation=$Operation;Status='READY'
                Checks=@([pscustomobject]@{Category='Reachability';Code='PROVIDER_REACHABLE';Status='PASS'})}}
        }
        function Get-LabSecret {throw 'HANDOFF_FORBIDDEN_SECRET'}
        function Get-LabRunRuntimeStatus {throw 'HANDOFF_FORBIDDEN_RUNTIME_REPAIR'}
        function Invoke-Recipe {
            param($Requested=$true,$Instance='primary',$Provider='docker',$Include=$false,$SchemaRoot=$Repo)
            $diagnosticHandoffRequested=$Requested;$selectedRunId=$script:handoffRun.RunId
            $selectedInstanceId=$Instance;$selectedDataRoot=$Root;$expectedProvider=$Provider
            $diagnosticOperation='Inspect';$includeProviderReadiness=$Include;$repositoryRoot=$SchemaRoot
            & ([scriptblock]::Create($Code))
        }
        function Snapshot {
            @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
                [IO.Path]::GetRelativePath($Root,$_.FullName)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
            }) -join '|'
        }
        $instance=[pscustomobject]@{id='primary';provider='docker';version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
        $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='CANARY_PRIVATE';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
        $script:handoffRun=New-LabRunState -StateRoot (Join-Path $Root 'State') -Metadata @{desiredState=$desired;persistentData=$false;dataRoot=$null} -ProviderSubRuns @([pscustomobject]@{provider='docker';instanceIds=@('primary')})
        $controller=[guid]::NewGuid().ToString('D')
        $marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='CANARY_PRIVATE-volume';DataRoot=$Root}
        $catalog=[pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;DefaultLocationId=[guid]::NewGuid().ToString('D');LabDataLocations=@([pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');ControllerId=$controller;LabDataRoot=$Root;VolumeId='CANARY_PRIVATE-volume'})}
        $null=New-Item -ItemType Directory -Path (Join-Path $Root 'Catalog') -Force
        $marker|ConvertTo-Json -Depth 16|Set-Content (Join-Path $Root '.sql-server-lab-root.json') -Encoding utf8
        $catalog|ConvertTo-Json -Depth 16|Set-Content (Join-Path $Root 'Catalog/storage-locations.json') -Encoding utf8
        $before=Snapshot
        foreach($requested in @($false,$null,'true')) {
            Assert-Handoff ((Invoke-Recipe -Requested $requested) -ceq 'DIAGNOSTIC_HANDOFF_NOT_REQUESTED' -and $script:handoffApiCalls -eq 0) 'Nicht angeforderter Handoff ruft keine API auf'
        }
        Assert-Handoff ((Invoke-Recipe -Instance '') -ceq 'DIAGNOSTIC_HANDOFF_TARGET_REQUIRED' -and $script:handoffApiCalls -eq 0) 'Fehlendes Ziel ruft keine API auf'
        Assert-Handoff ((Invoke-Recipe -Include 'true') -ceq 'DIAGNOSTIC_HANDOFF_TARGET_REQUIRED' -and $script:handoffApiCalls -eq 0) 'Readiness braucht tatsächlichen booleschen Auftrag'
        $json=Invoke-Recipe;$bundle=$json|ConvertFrom-Json
        Assert-Handoff ($bundle.Status -ceq 'OBSERVED' -and $script:handoffApiCalls -eq 1 -and $script:handoffProbeCalls -eq 0 -and $bundle.Readiness.EvidenceStatus -ceq 'NOT_EXECUTED') 'Echtes Rezept bindet echte PublicAPI ohne Standardprobe'
        Assert-Handoff ($json -notmatch 'CANARY_PRIVATE|sql-lab-handoff-check' -and $json -notmatch [regex]::Escape($script:handoffRun.RunId) -and -not $bundle.Capabilities.MutationAllowed -and $bundle.Capabilities.SqlProbe -ceq 'NOT_EXECUTED') 'Nur geschlossenes DTO ohne private Zielwerte oder SQLfreigabe'
        $bundle=(Invoke-Recipe -Include $true)|ConvertFrom-Json
        Assert-Handoff ($bundle.Readiness.Status -ceq 'READY' -and $script:handoffProbeCalls -eq 1) 'Explizite Providerprobe nutzt bestehende öffentliche Grenze'
        foreach($caseArguments in @(@{Instance='foreign'},@{Provider='podman'})) {
            $bundle=(Invoke-Recipe @caseArguments -Include $true)|ConvertFrom-Json
            Assert-Handoff ($bundle.Status -cin @('BLOCKED','UNAVAILABLE') -and $script:handoffProbeCalls -eq 1) 'Fremdes Ziel bleibt gesperrt ohne Providerprobe'
        }
        Assert-Handoff ((Invoke-Recipe -SchemaRoot (Join-Path $Root 'missing')) -ceq 'DIAGNOSTIC_HANDOFF_UNVERIFIABLE') 'Fehlende Schemaautorität liefert nur festen Fehler'
        Assert-Handoff ($before -ceq (Snapshot)) 'Handoff verändert keine Fixturedatei'
        function Get-SqlServerLabDiagnosticBundle {
            Write-Warning 'CANARY_PRIVATE';Write-Information 'CANARY_PRIVATE' -InformationAction Continue
            [pscustomobject]@{Private='CANARY_PRIVATE'}
        }
        $fault=@(Invoke-Recipe *>&1)
        Assert-Handoff ($fault.Count -eq 1 -and $fault[0] -ceq 'DIAGNOSTIC_HANDOFF_UNVERIFIABLE') 'Ungeprüftes DTO und Nebenstreams gelangen nicht in Handoff'
        function Get-SqlServerLabDiagnosticBundle {throw 'CANARY_PRIVATE exception'}
        $fault=@(Invoke-Recipe *>&1)
        Assert-Handoff ($fault.Count -eq 1 -and $fault[0] -ceq 'DIAGNOSTIC_HANDOFF_UNVERIFIABLE') 'APIexception bleibt fester Fehler ohne Rohtext'
        Write-Host "OPERATOR_DIAGNOSTIC_HANDOFF_CHECKS: PASS ($script:handoffAssertions assertions)"
    } $root $repo $match.Groups['code'].Value
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^sql-lab-handoff-check-[a-f0-9]{32}$'){throw 'HANDOFF_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
