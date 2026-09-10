# Bootstrap darf weder einen Skill noch ein geladenes Produktmodul voraussetzen.
function New-LabClientReadinessCheck {
    [CmdletBinding()]
    param([string]$Category,[string]$Code,[ValidateSet('PASS','BLOCKED','WARNING','NOT_CHECKED')][string]$Status,[string]$NextStep='')
    [pscustomobject]@{
        Category=$Category; Code=$Code; Status=$Status
        MissingPrerequisite=$(if($Status -eq 'BLOCKED'){$Code}else{$null})
        Warning=$(if($Status -in @('WARNING','NOT_CHECKED')){$Code}else{$null})
        NextStep=$NextStep
    }
}

function Get-LabClientRuntimeReadiness {
    [CmdletBinding()]
    param([ValidateSet('docker','podman','hyperv')][string]$Provider)
    if($Provider -eq 'hyperv'){
        if(-not $IsWindows){return New-LabClientReadinessCheck Provider PROVIDER_OS_UNSUPPORTED BLOCKED 'Use a Windows Hyper-V host.'}
        if(-not (Get-Command Get-VMHost -ErrorAction SilentlyContinue)){
            return New-LabClientReadinessCheck Installation PROVIDER_NOT_INSTALLED BLOCKED 'Install Hyper-V and its management tools in a separate setup operation.'
        }
        try {$null=Get-VMHost -ErrorAction Stop}
        catch {
            if($_.CategoryInfo.Category -in @('PermissionDenied','SecurityError') -or $_.Exception -is [UnauthorizedAccessException] -or $_.Exception.HResult -eq -2147024891){
                return New-LabClientReadinessCheck Permission PROVIDER_ACCESS_DENIED BLOCKED 'Use an account authorized for Hyper-V management.'
            }
            return New-LabClientReadinessCheck Reachability PROVIDER_UNREACHABLE BLOCKED 'Check the Hyper-V management service in a separate diagnostic operation.'
        }
        if(-not (Test-HyperVAvailable).Available){return New-LabClientReadinessCheck Installation PROVIDER_INSTALLATION_INCOMPLETE BLOCKED 'Check the required Hyper-V commands using Test-SqlServerLabPrerequisite.'}
        return New-LabClientReadinessCheck Reachability PROVIDER_REACHABLE PASS
    }
    try {$tool=@(Initialize-LabHostToolPath -Name $Provider)[0]}
    catch {return New-LabClientReadinessCheck Installation TOOL_RESOLUTION_FAILED BLOCKED 'Check the configured tool override with Initialize-SqlServerLabHostTools.ps1.'}
    if(-not $tool.Available){return New-LabClientReadinessCheck Installation TOOL_NOT_INSTALLED BLOCKED 'Install the selected provider CLI separately, then rerun readiness.'}
    if(-not [IO.Path]::IsPathRooted([string]$tool.Invocation)){
        return New-LabClientReadinessCheck Installation TOOL_NATIVE_PATH_REQUIRED BLOCKED 'Resolve the provider to its installed absolute executable path.'
    }
    try {
        $result=Invoke-LabProgressNativeCommand -FilePath $tool.Invocation -ArgumentList @('info','--format','json') -Phase GuestWait -TimeoutSeconds 20
    }
    catch {
        $exception=$_.Exception
        while($exception.InnerException){$exception=$exception.InnerException}
        if($exception -is [UnauthorizedAccessException] -or ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in @(5,13))){
            return New-LabClientReadinessCheck Permission TOOL_EXECUTION_DENIED BLOCKED 'Grant execution permission for the installed CLI through the normal host administration path.'
        }
        if([string]$_ -match 'NATIVE_OPERATION_TIMEOUT'){
            return New-LabClientReadinessCheck Reachability PROVIDER_PROBE_TIMEOUT BLOCKED 'Check the selected runtime endpoint; the bounded read-only probe timed out.'
        }
        return New-LabClientReadinessCheck Reachability PROVIDER_PROBE_FAILED BLOCKED 'Diagnose CLI execution separately; installation was resolved successfully.'
    }
    if($result.ExitCode -ne 0){
        if(($result.Output -join "`n") -match '(?i)permission denied|access is denied|access denied|unauthorized|not authorized|zugriff verweigert'){
            return New-LabClientReadinessCheck Permission PROVIDER_ACCESS_DENIED BLOCKED 'Use an account authorized for the selected runtime endpoint.'
        }
        return New-LabClientReadinessCheck Reachability PROVIDER_UNREACHABLE BLOCKED 'Check or start the selected runtime separately, then rerun readiness.'
    }
    try {$info=($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop}
    catch {return New-LabClientReadinessCheck Reachability PROVIDER_RESPONSE_INVALID BLOCKED 'Check the CLI/runtime version and endpoint response.'}
    if(-not $info -or ($Provider -eq 'docker' -and -not $info.ServerVersion) -or ($Provider -eq 'podman' -and (-not $info.host -or -not $info.version))){return New-LabClientReadinessCheck Reachability PROVIDER_RESPONSE_INVALID BLOCKED 'Check the CLI/runtime version and endpoint response.'}
    New-LabClientReadinessCheck Reachability PROVIDER_REACHABLE PASS
}

function Test-LabClientReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateSet('docker','podman','hyperv')][string]$Provider='docker',
        [ValidateSet('Inspect','Validate','Create','Start','Stop','Remove','PrepareImage')][string]$Operation='Inspect'
    )
    $checks=[Collections.Generic.List[object]]::new()
    $supportedOs=([Environment]::OSVersion.Platform -eq 'Win32NT' -or $IsLinux)
    $checks.Add((New-LabClientReadinessCheck OperatingSystem $(if($supportedOs){'OS_SUPPORTED'}else{'OS_UNSUPPORTED'}) $(if($supportedOs){'PASS'}else{'BLOCKED'}) $(if(-not $supportedOs){'Use a supported Windows or Linux host.'})))
    $supportedPs=$PSVersionTable.PSVersion -ge [version]'7.2'
    $checks.Add((New-LabClientReadinessCheck PowerShell $(if($supportedPs){'POWERSHELL_SUPPORTED'}else{'POWERSHELL_7_2_REQUIRED'}) $(if($supportedPs){'PASS'}else{'BLOCKED'}) $(if(-not $supportedPs){'Run this script with PowerShell 7.2 or later.'})))
    $manifestPath=Join-Path $RepositoryRoot 'SqlServerLab.psd1'
    $repositoryReady=(Test-Path -LiteralPath (Join-Path $RepositoryRoot 'AGENTS.md') -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    $checks.Add((New-LabClientReadinessCheck Repository $(if($repositoryReady){'REPOSITORY_PRESENT'}else{'REPOSITORY_INCOMPLETE'}) $(if($repositoryReady){'PASS'}else{'BLOCKED'}) $(if(-not $repositoryReady){'Use a complete SQL_Server_Lab checkout.'})))
    $module=$null
    if($supportedPs -and $repositoryReady){
        try {$manifest=Test-ModuleManifest -Path $manifestPath -ErrorAction Stop -WarningAction SilentlyContinue; $checks.Add((New-LabClientReadinessCheck Manifest MANIFEST_VALID PASS))}
        catch {$checks.Add((New-LabClientReadinessCheck Manifest MANIFEST_INVALID BLOCKED 'Restore a valid module manifest from the repository.'))}
        if($manifest){
            try {
                $module=Import-Module $manifestPath -Force -PassThru -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false
                $loadErrors=& $module { @($script:ModuleLoadErrors).Count }
                if($loadErrors -gt 0){throw 'MODULE_LOAD_INCOMPLETE'}
                $checks.Add((New-LabClientReadinessCheck ModuleImport MODULE_IMPORTED PASS))
                $data=Import-PowerShellDataFile -Path $manifestPath
                $missing=@($data.FunctionsToExport | Where-Object { -not $module.ExportedCommands.ContainsKey($_) })
                $checks.Add((New-LabClientReadinessCheck Exports $(if($missing.Count){'MODULE_EXPORTS_MISSING'}else{'MODULE_EXPORTS_PRESENT'}) $(if($missing.Count){'BLOCKED'}else{'PASS'}) $(if($missing.Count){'Repair the module export contract and run its static checks.'})))
            }
            catch {$module=$null;$checks.Add((New-LabClientReadinessCheck ModuleImport MODULE_IMPORT_FAILED BLOCKED 'Run the repository module-import and static validation checks.'))}
        }
    }
    if($module){
        $checks.Add((& $module {param($Name) Get-LabClientRuntimeReadiness -Provider $Name} $Provider))
        try {
            $storage=& $module {Get-LabStorageConfiguration}
            $storageReady=[bool]$storage.DefaultLocationId -and [bool]$storage.ControllerId
            $status=if($storageReady){'PASS'}elseif($Operation -in @('Create','PrepareImage')){'BLOCKED'}else{'WARNING'}
            $checks.Add((New-LabClientReadinessCheck Storage $(if($storageReady){'STORAGE_CONFIGURED'}else{'STORAGE_CONFIGURATION_REQUIRED'}) $status $(if(-not $storageReady){'Complete the existing storage setup explicitly before creating resources.'})))
        }
        catch {$checks.Add((New-LabClientReadinessCheck Storage STORAGE_CONFIGURATION_INVALID BLOCKED 'Validate the existing storage configuration without replacing it.'))}
        if($Provider -ne 'hyperv' -and $Operation -eq 'PrepareImage'){
            $checks.Add((New-LabClientReadinessCheck OperationRights OPERATION_PROVIDER_UNSUPPORTED BLOCKED 'Use PrepareImage only for the Hyper-V offline image workflow.'))
        }
        elseif($Provider -eq 'hyperv' -and $Operation -eq 'PrepareImage'){
            $elevated=& $module {Test-LabAdministrator}
            $checks.Add((New-LabClientReadinessCheck OperationRights $(if($elevated){'ELEVATION_PRESENT'}else{'ELEVATION_REQUIRED'}) $(if($elevated){'PASS'}else{'BLOCKED'}) $(if(-not $elevated){'Run image preparation from an explicitly elevated Windows session.'})))
        }
        elseif($Operation -notin @('Inspect','Validate')){
            $checks.Add((New-LabClientReadinessCheck OperationRights TARGET_AUTHORIZATION_REQUIRED WARNING 'The selected public operation must validate its exact target, ownership and required privileges before mutation.'))
        }
        else {$checks.Add((New-LabClientReadinessCheck OperationRights READ_ONLY_PROBE_COMPLETED PASS))}
    }
    else {
        foreach($category in @('Provider','Storage','OperationRights')){$checks.Add((New-LabClientReadinessCheck $category BOOTSTRAP_REQUIRED NOT_CHECKED 'Resolve the blocking bootstrap checks first.'))}
    }
    $blocked=@($checks | Where-Object {$_.Status -eq 'BLOCKED'})
    $warnings=@($checks | Where-Object {$_.Status -in @('WARNING','NOT_CHECKED')})
    [pscustomobject]@{
        ContractVersion='SqlServerLab.ClientReadiness/1.0'; Provider=$Provider; Operation=$Operation
        Status=$(if($blocked.Count){'NOT_READY'}elseif($warnings.Count){'READY_WITH_WARNINGS'}else{'READY'})
        MutationAllowed=$false; SkillLoaderVerified=$false; Checks=@($checks)
        MissingPrerequisites=@($blocked.Code | Sort-Object -Unique)
        Warnings=@($warnings.Code | Sort-Object -Unique)
        NextSteps=@($checks | Where-Object {$_.NextStep} | Select-Object -ExpandProperty NextStep -Unique)
    }
}
