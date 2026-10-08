#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('Docker','Podman')) {
        $definition=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw|ConvertFrom-Json
        $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
    }
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1',
        'Private/DiagnosticBundleReadiness.ps1','Private/ExternalRuntimeCapability.ps1','Private/ManifestBuilder.ps1',
        'Public/Get-SqlServerLabExternalRuntimeCapability.ps1')) { . (Join-Path $root $path) }
    $script:probes=0;$script:transports=0;$script:probeMode='ready';$script:captured=$null
    $script:classifierCalls=0
    $script:actualClassifier=(Get-Command Get-LabExternalRuntimeHostCapability).ScriptBlock
    function Get-LabExternalRuntimeHostCapability {
        param($Provider,$SqlVersion,$RequiredCgroupVersion,$RuntimeInfo,$ToolAvailable,$RuntimeReachable)
        $script:classifierCalls++
        & $script:actualClassifier @PSBoundParameters
    }
    function Initialize-LabHostToolPath {
        param($Name)
        $script:probes++
        [pscustomobject]@{Available=($script:probeMode -ne 'missing');Invocation=$(if($script:probeMode -eq 'alias'){'alias'}else{Join-Path ([IO.Path]::GetTempPath()) "synthetic-$Name.exe"})}
    }
    # Actual adapter creates StartInfo and calls this exact bounded-process seam.
    function Invoke-LabDiagnosticBoundedProcess {
        param($StartInfo,$TimeoutSeconds,$MaximumBytes)
        $script:transports++;$script:captured=$StartInfo
        if($TimeoutSeconds -ne 20 -or $MaximumBytes -ne 65536 -or $StartInfo.UseShellExecute -or
            -not $StartInfo.RedirectStandardOutput -or -not $StartInfo.RedirectStandardError -or
            $StartInfo.ArgumentList.Count -ne 3 -or $StartInfo.ArgumentList[0] -cne 'info' -or
            $StartInfo.ArgumentList[1] -cne '--format') {throw 'TRANSPORT_CONTRACT_CHANGED'}
        if($script:probeMode -eq 'throw') {throw 'PRIVATE_HOST_CANARY'}
        if($script:probeMode -in @('timeout','overflow','unknown')) {
            $code=switch($script:probeMode){timeout{'DIAGNOSTIC_READINESS_TIMEOUT'}overflow{'DIAGNOSTIC_READINESS_OUTPUT_LIMIT'}unknown{'DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED'}}
            return [pscustomobject]@{Success=$false;Reason=$code;Value=$null}
        }
        $value=if($StartInfo.FileName -match 'podman') {
            [pscustomobject]@{OperatingSystem='linux';CgroupVersion='v1';Rootless=$false}
        } else {[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@('name=seccomp,profile=builtin')}}
        if($script:probeMode -eq 'malformed') {$value.CgroupVersion=$null}
        [pscustomobject]@{Success=$true;Reason='NONE';Value=$value}
    }
    function Read-LabManifestChoice {param($Options,$Prompt)
        $script:labels=@($Options);$step=$script:steps[$script:stepIndex++];
        if($step -is [int]){return $step}
        if($step -eq 'Finish'){return [array]::IndexOf($Options,'Auswahl abschliessen')}
        if($step -eq 'Probe'){return [array]::IndexOf($Options,'Hostvoraussetzungen bewusst lesend pruefen')}
        [pscustomobject]@{Action=$step}
    }
    function Test-LabManifestNavigationResult {param($InputObject) $InputObject -is [pscustomobject] -and $InputObject.PSObject.Properties.Name -contains 'Action'}
    function Write-LabWarning {param($Message) $script:warnings+=@($Message)}
    function Write-LabManifestDraftSummary {param($Path,$Draft)}
    function Assert-Case {param([bool]$Condition,[string]$Name)
        if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"
    }
    $script:passed=0
    $parameters=@{SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived'}
    $result=Get-SqlServerLabExternalRuntimeCapability @parameters
    Assert-Case ($result.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED' -and $result.CurrentReadiness.Status -ceq 'NOT_CHECKED') 'Catalog support is distinct from unchecked host'
    Assert-Case ($script:probes -eq 0 -and $script:transports -eq 0) 'Actual public default performs zero tool/native transports'
    Assert-Case (-not $result.MutationAllowed -and -not $result.ExecutionSupported -and $result.Actions.Count -eq 0 -and $result.SqlLanguageExecution -ceq 'NOT_CHECKED') 'No SQL, execution or resource authority'
    Assert-Case ($result.HistoricalEvidence.Status -ceq 'NOT_RECORDED' -and $result.HistoricalEvidence.MappingStatus -ceq 'NOT_DEFINED') 'No invented historical join'
    foreach($provider in @('docker','podman')) {
        $parameters.Provider=$provider;$script:probeMode='ready';$beforeClassifier=$script:classifierCalls
        $result=Get-SqlServerLabExternalRuntimeCapability @parameters -CheckProviderReadiness
        Assert-Case ($result.CurrentReadiness.Status -ceq 'READY') "Actual public/reader/adapter bounded composition $provider"
        Assert-Case ($script:classifierCalls -eq $beforeClassifier+1 -and $result.CurrentReadiness.ReasonCode -ceq 'NONE') "Actual classifier return reaches renamed decision branch $provider"
        Assert-Case ($script:captured.ArgumentList[2] -ceq (Get-LabExternalRuntimeInfoArguments $provider)[2]) "Exact projected readonly argv $provider"
    }
    foreach($case in @('missing','alias','timeout','overflow','unknown','throw','malformed')) {
        $script:probeMode=$case;$before=$script:transports
        $result=Get-SqlServerLabExternalRuntimeCapability @parameters -CheckProviderReadiness
        Assert-Case ($result.CurrentReadiness.Status -ceq 'BLOCKED') "Reader failure $case remains blocked"
        Assert-Case (($result|ConvertTo-Json -Depth 12 -Compress) -notmatch 'PRIVATE_HOST_CANARY|synthetic-|seccomp') "Failure $case is raw-free"
        if($case -in @('missing','alias')){Assert-Case ($script:transports -eq $before) "$case starts no transport"}
    }
    $script:probeMode='ready';$parameters.Provider='docker'
    foreach($facts in @(
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='2';Rootless=$false},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';Rootless=$true},
        [pscustomobject]@{OperatingSystem='windows';CgroupVersion='1';Rootless=$false},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';Rootless='false'},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion=$null;Rootless=$false}
    )) {
        $decision=New-LabExternalRuntimeCapabilityDecision @parameters -HostObservation ([pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Facts=$facts})
        Assert-Case ($decision.CurrentReadiness.Status -ceq 'BLOCKED') 'Typed classifier rejects unsuitable or unknown facts'
    }
    foreach($value in @(
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=$null},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';Rootless=$false},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='11';SecurityOptions=@()},
        [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@();Private='PRIVATE_HOST_CANARY'}
    )) {
        $rejected=$false;try{ConvertTo-LabExternalRuntimeHostFacts docker $value|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'PROVIDER_RESPONSE_INVALID'}
        Assert-Case $rejected 'Closed native projection rejects missing/type/extra fields'
    }
    foreach($sql in @('2019','2022','2025')) {
        $options=@(Get-LabExternalRuntimeCapabilityOptions $sql docker linux)
        Assert-Case (@($options|Where-Object{$_.Decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED'}).Count -ge 1) "Catalog retains supported SQL $sql alternatives"
        Assert-Case (@($options|Where-Object{$_.Decision.CatalogDecision.Status -ceq 'BLOCKED'}).Count -ge 1) "Catalog exposes negative SQL $sql alternatives"
    }
    $parameters.SqlVersion='2025';$parameters.VariantId='sql-python-2025-shared-user-v2'
    $facts=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='2';Rootless=$false}
    $decision=New-LabExternalRuntimeCapabilityDecision @parameters -HostObservation ([pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Facts=$facts})
    Assert-Case ($decision.CurrentReadiness.Status -ceq 'READY' -and $decision.CurrentReadiness.RequiredCgroupVersion -ceq '2') 'Explicit SQL2025 shared-user v2 uses canonical recipe'
    $parameters.SqlVersion='2022';$parameters.RuntimeVersion='PRIVATE_HOST_CANARY';$parameters.VariantId='PRIVATE_HOST_CANARY'
    $before=$script:transports;$decision=Get-SqlServerLabExternalRuntimeCapability @parameters -CheckProviderReadiness
    Assert-Case ($decision.CatalogDecision.Status -ceq 'BLOCKED' -and $decision.Identity -eq $null -and $script:transports -eq $before -and
        ($decision|ConvertTo-Json -Depth 12) -notmatch 'PRIVATE_HOST_CANARY') 'Unknown catalog identity is not echoed or probed'
    foreach($id in @('sql-csharp','private-unknown')) {
        $parameters.SoftwareId=$id;$rejected=$false
        try{Get-SqlServerLabExternalRuntimeCapability @parameters|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_CAPABILITY_INPUT_INVALID'}
        Assert-Case $rejected 'Deferred/unknown software rejected without adoption'
    }
    $draft=[ordered]@{id='primary';version='2022';provider='docker';os='linux'}
    $script:steps=@(0,'Finish');$script:stepIndex=0;$script:warnings=@();$before=$script:transports
    $selected=@(Select-LabManifestExternalRuntimeReferences -InstanceDraft $draft)
    Assert-Case ($selected.Count -eq 1 -and @($selected[0].Keys).Count -eq 6 -and $selected[0].scope -ceq 'sqlExternalRuntime') 'Actual dialog retains legacy six-field manifest return'
    Assert-Case ($script:transports -eq $before -and @($script:labels|Where-Object{$_ -match 'BLOCKED'}).Count -gt 0) 'Dialog shows negative variants without ambient probe'
    $script:steps=@(0,'Back','Cancel');$script:stepIndex=0
    $cancel=Select-LabManifestExternalRuntimeReferences -InstanceDraft $draft
    Assert-Case ($cancel.Action -ceq 'Cancel' -and $script:transports -eq $before) 'Dialog Back/Cancel performs zero provider transports'
    $script:steps=@('Probe',0,'Finish');$script:stepIndex=0;$script:probeMode='ready'
    $selected=@(Select-LabManifestExternalRuntimeReferences -InstanceDraft $draft)
    Assert-Case ($selected.Count -eq 1 -and $script:transports -eq $before+1) 'Conscious dialog probe is one shared reader call'
    $draft.version='2025';$script:steps=@('Cancel');$script:stepIndex=0
    Select-LabManifestExternalRuntimeReferences -InstanceDraft $draft|Out-Null
    Assert-Case (@($script:labels|Where-Object{$_ -match 'ohne Launchpad-Sandbox, gemeinsames Worker-Konto, Netzwerkzugriff'}).Count -eq 3) 'Existing SQL2025 isolation warning preserved'
    $value=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@('rootless=unknown')}
    $rejected=$false;try{ConvertTo-LabExternalRuntimeHostFacts docker $value|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'PROVIDER_RESPONSE_INVALID'}
    Assert-Case $rejected 'Ambiguous rootless spelling never proves rootful'
    foreach($field in @('SqlVersion','RuntimeVersion','VariantId')) {
        $input=@{SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived'}
        $input[$field]='';$rejected=$false
        try{New-LabExternalRuntimeCapabilityDecision @input|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_CAPABILITY_INPUT_INVALID'}
        Assert-Case $rejected "Explicit $field cannot silently fall back"
    }
    foreach($choice in @(-1,999)) {
        $draft.version='2022';$script:steps=@($choice);$script:stepIndex=0;$before=$script:transports;$rejected=$false
        try{Select-LabManifestExternalRuntimeReferences -InstanceDraft $draft|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_CAPABILITY_CHOICE_INVALID'}
        Assert-Case ($rejected -and $script:transports -eq $before) 'Invalid menu index cannot dispatch probe or select variant'
    }
    Write-Host "EXTERNAL RUNTIME CAPABILITY CHECKS: PASS ($script:passed assertions; synthetic transport only)"
}
try { & $module {} } finally {Remove-Module $module -ErrorAction SilentlyContinue}
& (Join-Path $PSScriptRoot 'Fixtures/ExternalRuntimeCapabilityHostFactsChecks.ps1')
