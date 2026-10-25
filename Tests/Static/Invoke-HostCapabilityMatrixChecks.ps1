#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw | ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('Docker','Podman','HyperV')) {
        $definition=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw | ConvertFrom-Json
        $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
    }
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ExternalRuntimeCapability.ps1',
        'Private/DiagnosticBundleReadiness.ps1','Private/HostCapabilityMatrix.ps1','Private/HostCapabilityMatrixConsole.ps1',
        'Public/Get-SqlServerLabHostCapabilityMatrix.ps1')) {. (Join-Path $root $path)}
    $script:calls=[Collections.Generic.List[string]]::new();$script:codes=@{};$script:mode='normal';$script:passed=0
    function Assert-Case {param([bool]$Condition,[string]$Name)
        if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"
    }
    # Exercise the actual public API, shared reader/validation and catalog resolver.
    # Replace only the bounded native process boundary; never start a real provider.
    function Invoke-LabDiagnosticReadinessProcess {
        param($Provider,$Operation)
        $script:calls.Add($Provider)
        if($Operation -cne 'Inspect'){throw 'UNEXPECTED_OPERATION'}
        if($script:mode -eq 'throw'){throw 'PRIVATE_HOST_CANARY'}
        if($script:mode -eq 'transport') {return [pscustomobject]@{Success=$false;Reason='DIAGNOSTIC_READINESS_TIMEOUT';Value=$null}}
        $code=if($script:codes.ContainsKey($Provider)){$script:codes[$Provider]}else{'PROVIDER_REACHABLE'}
        $category=switch($code){
            'PROVIDER_REACHABLE'{'Reachability'}
            'PROVIDER_OS_UNSUPPORTED'{'Provider'}
            {$_ -in @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED')}{'Permission'}
            {$_ -in @('PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID')}{'Reachability'}
            default{'Installation'}
        }
        $check=[pscustomobject]@{Code=$code;Category=$category;Status=$(if($code -eq 'PROVIDER_REACHABLE'){'PASS'}else{'BLOCKED'});NextStep='PRIVATE_HOST_CANARY'}
        $value=[pscustomobject]@{ContractVersion='SqlServerLab.DiagnosticProviderReadiness/1.0';Provider=$Provider;Operation=$Operation;
            Status=$(if($code -eq 'PROVIDER_REACHABLE'){'READY'}else{'NOT_READY'});Checks=@($check)}
        switch($script:mode){
            'wrong-provider'{$value.Provider='PRIVATE_HOST_CANARY'}
            'contradiction'{$value.Status='READY';$check.Status='BLOCKED'}
            'wrong-category'{$check.Category='Storage'}
            'extra-check'{$value.Checks+=@($check)}
            'warning'{$check.Status='WARNING';$value.Status='READY_WITH_WARNINGS'}
        }
        [pscustomobject]@{Success=$true;Reason='NONE';Value=$value}
    }
    $result=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022
    Assert-Case ($script:calls.Count -eq 0 -and $result.ProviderProfile -ceq 'NOT_CHECKED') 'Actual public default observes no provider'
    Assert-Case ($result.Providers.Count -eq 3 -and @($result.Capabilities | Where-Object Language -CEQ 'C#').Count -eq 3) 'All providers and deferred C# remain visible'
    Assert-Case (@($result.Capabilities | Where-Object {$_.Language -ceq 'C#' -and ($null -ne $_.SoftwareId -or $_.Availability -cne 'USER_DEFERRED')}).Count -eq 0) 'Deferred C# invents no catalog identity'
    Assert-Case (-not $result.ExecutionSupported -and -not $result.MutationAllowed -and $result.Actions.Count -eq 0 -and $result.Unassessed.Count -eq 9) 'No action authority or fabricated launch facts'
    Assert-Case ($result.CatalogFingerprint -cmatch '^[a-f0-9]{64}$' -and $result.GeneratedAtUtc -match 'Z$') 'Loaded catalog fingerprint and UTC scope'
    $keys=@($result.PSObject.Properties.Name | Sort-Object) -join ','
    Assert-Case ($keys -ceq 'Actions,Capabilities,CatalogFingerprint,Contract,ExecutionSupported,Feature,GeneratedAtUtc,HostOperatingSystem,ManufacturerSupport,MutationAllowed,ProjectAcceptance,ProviderProfile,Providers,SqlVersion,Unassessed') 'Closed top-level projection'
    $expected=@('NO_PROVIDER','DOCKER_ONLY','PODMAN_ONLY','DOCKER_PODMAN','HYPERV_ONLY','DOCKER_HYPERV','PODMAN_HYPERV','ALL_PROVIDERS')
    for($mask=0;$mask -lt 8;$mask++) {
        $script:codes=@{};$index=0
        foreach($provider in @('docker','podman','hyperv')) {
            $script:codes[$provider]=if($mask -band (1 -shl $index)){'PROVIDER_REACHABLE'}elseif($provider -eq 'hyperv'){'PROVIDER_NOT_INSTALLED'}else{'TOOL_NOT_INSTALLED'}
            $index++
        }
        $before=$script:calls.Count
        $matrix=New-LabHostCapabilityMatrix -SqlVersion 2022 -Provider @('docker','podman','hyperv') -HostOperatingSystem windows -CheckProviderReadiness
        Assert-Case ($matrix.ProviderProfile -ceq $expected[$mask] -and $script:calls.Count -eq $before+3) "All eight installation profiles, exactly one observation per provider: $mask"
        Assert-Case (@($matrix.Capabilities | Where-Object {$_.CatalogStatus -ceq 'DECLARED_SUPPORTED' -and $_.Availability -cnotin @('INCOMPLETE','PRECONDITION_MISSING')}).Count -eq 0) "Reachability never grants execution: $mask"
    }
    $script:codes=@{}
    foreach($provider in @('docker','podman','hyperv')) {
        $before=$script:calls.Count
        $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022 -Provider $provider -CheckProviderReadiness
        Assert-Case ($matrix.ProviderProfile -ceq 'PARTIAL_SELECTION' -and $matrix.Providers.Count -eq 1 -and $script:calls.Count -eq $before+1) "No hidden cross-provider dependency: $provider"
        $rows=@($matrix.Capabilities | Where-Object CatalogStatus -CEQ 'DECLARED_SUPPORTED')
        Assert-Case ($rows.Count -ge 3 -and @($rows | Where-Object Language -CEQ 'Python').Count -gt 0 -and
            @($rows | Where-Object Language -CEQ 'R').Count -gt 0 -and @($rows | Where-Object Language -CEQ 'Java').Count -gt 0) "Actual provider/OS catalog authority: $provider"
    }
    foreach($code in @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED')) {
        $script:codes=@{docker=$code}
        $matrix=New-LabHostCapabilityMatrix -SqlVersion 2022 -Provider @('docker','podman','hyperv') -HostOperatingSystem windows -CheckProviderReadiness
        $item=$matrix.Providers[0]
        Assert-Case ($item.ReasonCode -ceq $code -and $item.Presence -cne 'MISSING' -and $item.Readiness -cne 'READY') "Rights, reachability, installation and uncertainty stay distinct: $code"
    }
    $script:codes=@{}
    foreach($mode in @('throw','transport','wrong-provider','contradiction','wrong-category','extra-check','warning')) {
        $script:mode=$mode
        $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022 -Provider docker -CheckProviderReadiness
        Assert-Case ($matrix.Providers[0].Presence -ceq 'UNKNOWN' -and $matrix.Providers[0].Readiness -ceq 'UNKNOWN') "Failed/malformed observation never means absent or ready: $mode"
        Assert-Case (($matrix | ConvertTo-Json -Depth 20 -Compress) -cnotmatch 'PRIVATE_HOST_CANARY') "No raw native/advice leakage: $mode"
    }
    $script:mode='normal';$script:codes=@{hyperv='PROVIDER_OS_UNSUPPORTED'}
    $matrix=New-LabHostCapabilityMatrix -SqlVersion 2022 -Provider @('hyperv') -HostOperatingSystem linux -CheckProviderReadiness
    Assert-Case ($matrix.Providers[0].Presence -ceq 'HOST_UNSUPPORTED' -and $matrix.Capabilities[0].CatalogStatus -ceq 'DECLARED_SUPPORTED') 'Host OS exclusion does not rewrite language catalog support'
    $script:codes=@{}
    $matrix=New-LabHostCapabilityMatrix -SqlVersion 2022 -Provider @('hyperv') -HostOperatingSystem linux -CheckProviderReadiness
    Assert-Case ($matrix.Providers[0].Presence -ceq 'UNKNOWN') 'Contradictory Hyper-V host evidence fails closed'
    $before=$script:calls.Count;$failed=$false
    try {Get-SqlServerLabHostCapabilityMatrix -SqlVersion '2022-CU999-PRIVATE_HOST_CANARY' -CheckProviderReadiness | Out-Null}
    catch {$failed=$_.Exception.Message -ceq 'HOST_MATRIX_SQL_VERSION_UNKNOWN'}
    Assert-Case ($failed -and $script:calls.Count -eq $before) 'Unknown/alias SQL fails before observation without echoing input'
    foreach($version in $script:VersionCatalog.versions) {
        $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion $version.id
        Assert-Case ($matrix.SqlVersion -ceq $version.id -and $matrix.Capabilities.Count -ge 12 -and -not $matrix.MutationAllowed) "Current catalog SQL identity remains scoped: $($version.id)"
        Assert-Case (@($matrix.Capabilities | Where-Object {$null -eq $_.VariantId -and $_.RequiredCapabilities.Count -ne 0}).Count -eq 0) "Absent catalog variant invents no required capability: $($version.id)"
    }
    Assert-Case ($script:calls.Count -eq $before) 'Full version catalog inspection has no provider effects'
    $script:codes=@{};$script:consoleStep=0;$script:consoleProbe=$false;$script:consoleCancel=0;$script:messages=@()
    function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Data) [pscustomobject]@{Id=$Id;Data=$Data}}
    function Select-LabConsoleDataItem {param($ScreenId,$Title,$Subtitle,$Items)
        $script:consoleStep++
        if($script:consoleStep -eq $script:consoleCancel){return $null}
        if($ScreenId -eq 'host-matrix-sql'){return [pscustomobject]@{id='2022'}}
        return $Items[$([int]$script:consoleProbe)].Data
    }
    function Add-LabMessage {throw 'HOST_MATRIX_JOURNAL_FORBIDDEN'}
    function Write-LabInfo {param($Message) Add-LabMessage -Message $Message}
    $script:acknowledgements=0
    function Wait-LabConsoleAcknowledgement {param($Prompt) $script:acknowledgements++}
    foreach($probe in @($false,$true)) {
        $before=$script:calls.Count;$script:consoleStep=0;$script:consoleProbe=$probe
        $script:messages+=@(Show-LabHostCapabilityMatrixInteractive 6>&1 | ForEach-Object {[string]$_})
        Assert-Case ($script:calls.Count -eq $before+$(if($probe){3}else{0})) "Actual console uses the public API with explicit probe choice: $probe"
        Assert-Case ($script:acknowledgements -eq $(if($probe){2}else{1})) "Result remains visible until acknowledgement without journaling: $probe"
    }
    foreach($cancel in @(1,2)) {
        $before=$script:calls.Count;$script:consoleStep=0;$script:consoleCancel=$cancel
        Show-LabHostCapabilityMatrixInteractive
        Assert-Case ($script:calls.Count -eq $before -and $script:acknowledgements -eq 2) "Console cancellation before public observation: $cancel"
    }
    Assert-Case (($script:messages -join '\n') -match 'Keine Ausführungsfreigabe' -and ($script:messages -join '\n') -match 'C#') 'Console retains authority limits and deferred language'
    Write-Host "Host capability matrix: $script:passed PASS; synthetic provider observations only."
}
try {& $module { }} finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
