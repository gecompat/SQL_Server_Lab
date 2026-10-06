#Requires -Version 7.2
<#
.SYNOPSIS Prueft Passwortbarriere, Korrektur und eigene Configinitialisierung offline.
.DESCRIPTION Keine Secrets, Runtime, Provider, SQL, Listener oder globale Defaults.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureRoot = Join-Path $repoRoot ('.artifacts/test-runs/password-policy-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $fixtureRoot -ItemType Directory
$module = $null
try {
$module = New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
    param($repoRoot,$fixtureRoot)
    . (Join-Path $repoRoot 'Private/VersionCatalog.ps1')
    . (Join-Path $repoRoot 'Private/SecretProvider.ps1')
    . (Join-Path $repoRoot 'Private/SaPasswordPolicy.ps1')
    . (Join-Path $repoRoot 'Private/ContainerOwnedHostIntegration.ps1')
    . (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1')
    . (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1')
    . (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1')
    $script:VersionCatalog = Get-Content (Join-Path $repoRoot 'Catalogs/sql-server-versions.json') -Raw | ConvertFrom-Json
    $script:passed = 0; $script:stateCalls = 0; $script:nativeCalls = [Collections.Generic.List[object]]::new()
    $version = '2025-' + $script:VersionCatalog.versions.Where({$_.id -eq '2025'})[0].docker.builds[0].cu
    function Assert-Policy { param([bool]$Condition,[string]$Name)
        if (-not $Condition) { throw ('SA_PASSWORD_FIXTURE_FAILED: ' + $Name) }
        $script:passed++
    }
    function Assert-Throws { param([scriptblock]$Action,[string]$Prefix,[string]$CheckName)
        try { & $Action | Out-Null; throw 'EXPECTED_ERROR_MISSING' }
        catch { Assert-Policy ($_.Exception.Message.StartsWith($Prefix,[StringComparison]::Ordinal)) $CheckName }
    }
    function New-FixtureSecret { param([string]$Text)
        $secret = [SecureString]::new()
        foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
        $secret.MakeReadOnly()
        return $secret
    }
    # Secrets are constructed only in this local synthetic test, never printed.
    $shortText = -join @([char]65,[char]98,[char]51)
    $longText = $shortText + ('x' * 5)
    $short = New-FixtureSecret $shortText; $long = New-FixtureSecret $longText
    try {
        foreach ($text in @($longText, ('Ab' + ('x' * 5) + '!'), ('A3' + ('X' * 5) + '!'), ('a3' + ('x' * 5) + '!'))) {
            $secret = New-FixtureSecret $text
            try { Assert-Policy (Test-LabSaPassword $secret).Valid 'each three-category combination accepted' }
            finally { $secret.Dispose() }
        }
        foreach ($length in @(7,8,128,129)) {
            $secret = New-FixtureSecret ($shortText + ('x' * ($length - 3)))
            try { Assert-Policy ((Test-LabSaPassword $secret).Valid -eq ($length -in @(8,128))) ('length boundary ' + $length) }
            finally { $secret.Dispose() }
        }
        $two = New-FixtureSecret ('a' * 7 + '3')
        try { Assert-Policy ((Test-LabSaPassword $two).ReasonCodes -contains 'SA_PASSWORD_COMPLEXITY') 'two categories rejected' }
        finally { $two.Dispose() }
        $policy = Get-LabSaPasswordPolicy -Version $version -Provider docker -MinimumLength 3
        Assert-Policy $policy.CanCustomizeMinimum 'exact catalog CU eligible'
        Assert-Policy ((Test-LabSaPassword $short -MinimumLength 3).Valid) 'custom minimum accepts same synthetic secret'
        $workflowInput = @{SaPassword=$shortText;SqlVersion=$version;Provider='docker';PersistentData=$false}
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters $workflowInput } 'SA_PASSWORD_PREFLIGHT_FAILED:' 'browser workflow default rejects short password before job'
        $workflowInput.SaPasswordMinimumLength = 3
        Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters $workflowInput
        Assert-Policy $true 'browser workflow accepts explicit eligible minimum'
        $workflowInput.PersistentData = $true
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters $workflowInput } 'SA_PASSWORD_POLICY_TARGET_INVALID' 'browser workflow rejects persistent custom target'
        $workflowInput.PersistentData = $false
        $workflowInput.SqlVersion = '2025'
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters $workflowInput } 'SA_PASSWORD_POLICY_UNSUPPORTED:' 'browser workflow rejects floating image for custom minimum'
        $workflowInput.SqlVersion = $version
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLabFromManifest -Parameters $workflowInput } 'SA_PASSWORD_POLICY_MINIMUM_INVALID' 'manifest workflow cannot customize minimum'
        $workflowInput.Remove('SaPasswordMinimumLength')
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLabFromManifest -Parameters $workflowInput } 'SA_PASSWORD_PREFLIGHT_FAILED:' 'manifest workflow retains default criteria'
        $workflowInput.SaPassword = @($shortText)
        Assert-Throws { Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters $workflowInput } 'SA_PASSWORD_REQUIRED' 'workflow rejects non-scalar password'
        $validJson = (@{action='NewContainerLab';parameters=@{Provider='docker';SqlVersion=$version;PersistentData=$false;SaPassword=$shortText;SaPasswordMinimumLength=3}} | ConvertTo-Json -Depth 4 -Compress)
        Assert-LabSaPasswordWorkflowJsonShape -Json $validJson -Action NewContainerLab
        Assert-Policy $true 'strict browser creation shape accepts bounded scalar request'
        Assert-Throws { Assert-LabSaPasswordWorkflowJsonShape -Action NewContainerLab -Json ('{"action":"NewContainerLab","parameters":{"SaPassword":"'+$shortText+'","SaPassword":"'+$shortText+'"}}') } 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' 'duplicate secret field rejected before job'
        Assert-Throws { Assert-LabSaPasswordWorkflowJsonShape -Action NewContainerLab -Json ('{"action":"NewContainerLab","parameters":{"SaPassword":"'+$shortText+'","Unexpected":"value"}}') } 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' 'unknown creation authority rejected before job'
        Assert-Throws { Assert-LabSaPasswordWorkflowJsonShape -Action NewContainerLab -Json ('{"action":"NewContainerLab","parameters":{"SaPassword":"'+$shortText+'","SaPasswordMinimumLength":"3"}}') } 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' 'minimum cannot be a string'
        Assert-Throws { Assert-LabSaPasswordWorkflowJsonShape -Action NewContainerLabFromManifest -Json ('{"action":"NewContainerLabFromManifest","parameters":{"SaPassword":"'+$shortText+'","SaPasswordMinimumLength":3}}') } 'SA_PASSWORD_WORKFLOW_REQUEST_INVALID' 'manifest request rejects custom minimum field'
        $serialized = (Test-LabSaPassword $short) | ConvertTo-Json -Compress
        Assert-Policy (-not $serialized.Contains($shortText) -and
            ((Test-LabSaPassword $short).PSObject.Properties.Name -join ',') -ceq 'Valid,ReasonCodes') 'result contains no secret or measurements'
        foreach ($arguments in @(
            @{Version='2025';Provider='docker'}, @{Version='2022-CU27';Provider='docker'},
            @{Version=$version;Provider='hyperv'}, @{Version=$version;Provider='podman';ProvisioningMode='manifest'},
            @{Version=$version;Provider='docker';PersistentData=$true}, @{Version=$version;Provider='docker';HasDerivedImage=$true},
            @{Version=$version;Provider='docker';Drives=@([pscustomobject]@{containerPath='/var/opt/mssql/mssql.conf'})},
            @{Version=$version;Provider='docker';Drives=@([pscustomobject]@{containerPath='/var//opt/mssql'})},
            @{Version='2025-CU999';Provider='docker'}
        )) {
            $unsupported = Get-LabSaPasswordPolicy @arguments -MinimumLength 3
            Assert-Policy (-not $unsupported.CanCustomizeMinimum) 'unsupported target remains default-only'
            Assert-Throws { Assert-LabSaPasswordPreflight -Password $short -Policy $unsupported } 'SA_PASSWORD_POLICY_UNSUPPORTED:' 'unsupported custom policy rejects before effects'
        }
        function Write-LabHeader {}; function Write-LabInfo {}; function Write-LabWarning {}; function Write-LabSuccess {}; function Write-LabStatus {}
        function Resolve-LabSqlServerCollation { param($Name,$SqlVersion) $Name }
        function Resolve-LabSoftwarePlansForInstance { @() }
        function Invoke-LabResourceAssessmentPreflight { [pscustomobject]@{Status='synthetic'} }
        function Get-LabResourceProfile { [pscustomobject]@{maxMemoryMB=2048;maxCpus=2} }
        function Add-LabRunScopedContainerSystemDrive {}
        function New-LabDesiredStateSnapshot {}
        function Get-LabWorkflowOperationContext { $null }
        function New-LabRunState { $script:stateCalls++; throw 'FIXTURE_STATE_BARRIER' }
        function Save-LabSecret { throw 'FORBIDDEN_SECRET_WRITE' }
        function Invoke-LabExternalRuntimeContainerImageBuild { throw 'FORBIDDEN_IMAGE_BUILD' }
        function Invoke-LabContainerToolImageBuild { throw 'FORBIDDEN_IMAGE_BUILD' }
        function New-HyperVSqlUnattendedPassword { $long.Copy() }
        function Read-LabManifest {
            [pscustomobject]@{name='synthetic';instances=@([pscustomobject]@{id='primary';provider='docker';version=$version;drives=@();software=@()});
                automation=[pscustomobject]@{mode='unattended'};persistentData=[pscustomobject]@{enabled=$false}}
        }
        Assert-Throws { New-SqlServerLab -Version $version -Provider docker -SaPassword $short -NonInteractive } 'SA_PASSWORD_PREFLIGHT_FAILED:' 'actual public explicit secret preflight'
        Assert-Policy ($script:stateCalls -eq 0) 'invalid explicit secret reaches no state'
        Assert-Throws { New-SqlServerLab -Manifest synthetic -SaPassword $short -NonInteractive } 'SA_PASSWORD_PREFLIGHT_FAILED:' 'actual manifest default preflight'
        Assert-Policy ($script:stateCalls -eq 0) 'invalid manifest reaches no state'
        Assert-Throws { New-SqlServerLab -Version '2025' -SaPassword $short -SaPasswordMinimumLength 3 -NonInteractive } 'SA_PASSWORD_POLICY_UNSUPPORTED:' 'actual latest rejects explicit relaxation'
        Assert-Policy ($script:stateCalls -eq 0) 'unsupported customization reaches no state'
        Assert-Throws { New-SqlServerLab -Version $version -SaPassword $short -SaPasswordMinimumLength 3 -NonInteractive } 'FIXTURE_STATE_BARRIER' 'actual custom preflight reaches state only after acceptance'
        Assert-Throws { New-SqlServerLab -Version $version -GenerateSaPassword -NonInteractive } 'FIXTURE_STATE_BARRIER' 'generated secret uses same barrier'

        # Execute actual masked input/confirmation and decision flow with synthetic leaves.
        $script:inputs = [Collections.Generic.Queue[object]]::new(); $script:choices = [Collections.Generic.Queue[string]]::new()
        $script:confirmPolicy = $true; $script:readCalls=0
        function Read-Host { param($Prompt,[switch]$AsSecureString)
            $script:readCalls++; if ($script:inputs.Count -eq 0) { throw 'UNEXPECTED_INPUT' }
            $next=$script:inputs.Dequeue()
            if ($AsSecureString -and $next -isnot [SecureString]) { throw 'MASKED_INPUT_REQUIRED' }
            $next
        }
        function New-LabConsoleItem { param($Id,$Label,$Value,$Shortcut,$Data) [pscustomobject]@{Id=$Id;Label=$Label;Data=$Data} }
        function Show-LabSubMenu { param($ScreenId,$Title,$Items) $script:choices.Dequeue() }
        function Read-LabConfirm { param($Prompt,$Default) $script:confirmPolicy }
        function Set-DialogInputs { param([object[]]$Inputs,[string[]]$Choices=@())
            $script:inputs.Clear();$script:choices.Clear()
            foreach($inputValue in $Inputs){$script:inputs.Enqueue($inputValue)}
            foreach($choiceValue in $Choices){$script:choices.Enqueue($choiceValue)}
        }
        Set-DialogInputs @($short.Copy(),$long.Copy(),$long.Copy()) @('correct')
        $selected=Read-LabGuidedSaPassword -Policy (Get-LabSaPasswordPolicy -Version $version -Provider docker)
        Assert-Policy ($selected.Status -eq 'Accepted' -and $selected.MinimumLength -eq 8) 'actual correction keeps default'
        $selected.Password.Dispose()
        Set-DialogInputs @($short.Copy(),'3',$short.Copy()) @('adjust')
        $selected=Read-LabGuidedSaPassword -Policy (Get-LabSaPasswordPolicy -Version $version -Provider podman)
        Assert-Policy ($selected.Status -eq 'Accepted' -and $selected.MinimumLength -eq 3) 'actual explicit supported adjustment'
        $selected.Password.Dispose()
        Set-DialogInputs @($short.Copy()) @('cancel')
        Assert-Policy ((Read-LabGuidedSaPassword -Policy (Get-LabSaPasswordPolicy -Version $version -Provider docker)).Status -eq 'Cancelled') 'cancel before effects'
        $script:confirmPolicy=$false
        Set-DialogInputs @($short.Copy(),'3') @('adjust')
        Assert-Policy ((Read-LabGuidedSaPassword -Policy (Get-LabSaPasswordPolicy -Version $version -Provider docker)).Status -eq 'Cancelled') 'declined adjustment cancels'
        $script:confirmPolicy=$true
        Set-DialogInputs @($short.Copy()) @('adjust')
        Assert-Throws { Read-LabGuidedSaPassword -Policy (Get-LabSaPasswordPolicy -Version '2025' -Provider docker) } 'SA_PASSWORD_DIALOG_SELECTION_INVALID' 'forged unsupported adjustment rejected'

        # Real CLI route and its parameter forwarding, isolated from Creation.
        $publicAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'),[ref]$null,[ref]$null)
        $route=$publicAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-LabNewContainerEnvironmentInteractive'},$true)
        . ([scriptblock]::Create($route.Extent.Text))
        $createAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Public/New-SqlServerLab.ps1'),[ref]$null,[ref]$null)
        $create=$createAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-SqlServerLab'},$true)
        $spy='function New-SqlServerLab { [CmdletBinding(DefaultParameterSetName="AdHoc")] '+$create.Body.ParamBlock.Extent.Text+'; $script:creationParameters=$PSBoundParameters; [pscustomobject]@{RunId="synthetic-cli"} }'
        . ([scriptblock]::Create($spy))
        function Select-LabConsoleDataItem { $script:VersionCatalog.versions.Where({$_.id -eq '2025'})[0] }
        function Invoke-LabConsoleMenu { param($ScreenId,$Title,$Items,$SelectedId) [pscustomobject]@{Status='Selected';SelectedItem=$Items[1]} }
        function Select-LabSampleSelection { @() }
        function Get-LabDataRootDefault { $null }
        function Show-LabSubMenu { param($ScreenId,$Title,$Items)
            if($ScreenId -like 'container-profile-*'){return 'standard'}
            if($ScreenId -like 'container-password-*'){return 'manual'}
            $script:choices.Dequeue()
        }
        Set-DialogInputs @('','',$short.Copy(),'3',$short.Copy()) @('adjust')
        Invoke-LabNewContainerEnvironmentInteractive -Provider docker
        Assert-Policy ($script:creationParameters.SaPasswordMinimumLength -eq 3 -and $script:creationParameters.Version -eq $version) 'actual CLI forwards explicitly chosen target and minimum'
        $disposed=$false
        try { $copy=$script:creationParameters.SaPassword.Copy();$copy.Dispose() }
        catch { $disposed=$_.Exception.GetBaseException() -is [ObjectDisposedException] }
        Assert-Policy $disposed 'CLI disposes its owned secret after creation'
        $script:creationParameters=$null

        $system=[pscustomobject]@{id='runtime-mssql';containerPath='/var/opt/mssql';persistence='run-scoped-runtime-volume';persistentStorageId='synthetic'}
        Assert-LabSaPasswordContainerSeedScope -VersionId $version -Provider docker -Drives @($system) -LaunchMode none
        Assert-Policy $true 'automatic own system volume admitted'
        Assert-Throws { Assert-LabSaPasswordContainerSeedScope -VersionId $version -Provider docker -Drives @($system,[pscustomobject]@{id='override';containerPath='/var/opt/mssql/mssql.conf'}) -LaunchMode none } 'SA_PASSWORD_POLICY_CONTAINER_SCOPE_INVALID' 'config child collision before provider mutation'
        Assert-Throws { Assert-LabSaPasswordContainerSeedScope -VersionId $version -Provider docker -Drives @($system) -LaunchMode none -ResolvedImage synthetic } 'SA_PASSWORD_POLICY_CONTAINER_SCOPE_INVALID' 'derived image before provider mutation'

        # Provider calls are functions, not processes. Capture actual initialization argv.
        $script:volumeExists=$false;$script:seedFailure=$false
        function Get-LabHostToolInvocation { 'Invoke-FixtureRuntime' }
        function Invoke-FixtureRuntime {
            $script:nativeCalls.Add(@($args));$global:LASTEXITCODE=0
            if ($args[0] -eq 'volume' -and $args[1] -eq 'inspect' -and -not $script:volumeExists) { $global:LASTEXITCODE=1;return }
            if ($args[0] -eq 'run' -and $script:seedFailure) { $global:LASTEXITCODE=1;return }
        }
        function Invoke-LabProviderOperation { param($Provider,$Phase,$RunId,[switch]$Native,$Command,$Action)
            $output=@(& $Action)
            [pscustomobject]@{Succeeded=$global:LASTEXITCODE -eq 0;Output=$output}
        }
        foreach ($provider in @('docker','podman')) {
            $name='Initialize-'+(Get-Culture).TextInfo.ToTitleCase($provider)+'SqlNamedVolume'
            $parameters=@{VolumeName='synthetic-policy-volume';Image='synthetic-image';RunId='synthetic-run';ScopeId='synthetic-scope';VersionId=$version;
                InstanceId='primary';ContainerPath='/var/opt/mssql';Persistence='run-scoped-runtime-volume';SaPasswordMinimumLength=3}
            $script:nativeCalls.Clear()
            Assert-Policy (& $name @parameters) ('actual fresh initializer ' + $provider)
            $last=$script:nativeCalls[$script:nativeCalls.Count-1] -join '|'
            Assert-Policy ($last.Contains('passwordminimumlength=3') -and $last.Contains('test ! -L') -and $last.Contains('chown 10001:0')) ('actual fixed seed argv ' + $provider)
            $script:volumeExists=$true;$before=$script:nativeCalls.Count
            Assert-Throws { & $name @parameters } 'SA_PASSWORD_POLICY_EXISTING_VOLUME_FORBIDDEN' ('preexisting volume veto ' + $provider)
            Assert-Policy ($script:nativeCalls.Count -eq $before+1) ('existing veto performs inspect only ' + $provider)
            $script:volumeExists=$false;$script:seedFailure=$true
            Assert-Throws { & $name @parameters } 'SA_PASSWORD_POLICY_CONFIG_SEED_FAILED' ('seed failure sanitized ' + $provider)
            $script:seedFailure=$false
            $parameters.ContainerPath='/var/opt/mssql/data';$before=$script:nativeCalls.Count
            Assert-Throws { & $name @parameters } 'SA_PASSWORD_POLICY_VOLUME_SCOPE_INVALID' ('wrong volume target veto ' + $provider)
            Assert-Policy ($script:nativeCalls.Count -eq $before) ('scope veto before native ' + $provider)
        }

        # Actual owned-host initializer with local synthetic immutable records only.
        function Get-LabOwnedHostRunPolicy { [pscustomobject]@{StateRoot=$fixtureRoot;PolicyId='synthetic';RootScopeId='synthetic'} }
        function Get-LabRunState { [pscustomobject]@{scopeId='synthetic-scope'} }
        function Assert-LabOwnedHostPath { param($Path) if (-not $Path.StartsWith($fixtureRoot)) { throw 'OUTSIDE_FIXTURE' } }
        function Write-LabOwnedHostRecordExclusive { param($Path,$Record)
            $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew);try{
                $bytes=[Text.Encoding]::UTF8.GetBytes(($Record|ConvertTo-Json -Depth 10));$stream.Write($bytes,0,$bytes.Length)
            }finally{$stream.Dispose()}
        }
        function New-LabGuid { [guid]::NewGuid().ToString() }
        function Get-LabOwnedHostContainerLabels { @() }
        function Get-LabOwnedHostVolumeReceipt { [pscustomobject]@{Intent=[pscustomobject]@{VersionId=$version;PersistentStorageId='';PersistentStorageRole=''}} }
        function Invoke-LabOwnedHostPinnedCommand { param($StateRoot,$Provider,$Arguments) [pscustomobject]@{ExitCode=0;Stdout=''} }
        $script:ephemeralCalls=0
        function Invoke-LabOwnedHostEphemeralContainer { param($StateRoot,$RunId,$ScopeId,$Provider,$ContainerArguments)
            $script:ephemeralCalls++;$script:ownedCommand=$ContainerArguments[-1]
            if($script:seedFailure){throw 'SYNTHETIC_SEED_FAILURE'}
        }
        $owned=@{StateRoot=$fixtureRoot;RunId='synthetic-run';ScopeId='synthetic-scope';Provider='docker';VolumeName='synthetic-owned';
            Image='synthetic';InstanceId='primary';VersionId=$version;ContainerPath='/var/opt/mssql';Persistence='run-scoped-runtime-volume';SaPasswordMinimumLength=3}
        $script:seedFailure=$true
        Assert-Throws { Initialize-LabOwnedHostSqlVolume @owned } 'SA_PASSWORD_POLICY_CONFIG_SEED_FAILED' 'actual owned seed error sanitized and retains created receipt'
        Assert-Policy ($script:ownedCommand.Contains('passwordminimumlength=3')) 'owned initializer receives fixed seed'
        $before=$script:ephemeralCalls
        Assert-Throws { Initialize-LabOwnedHostSqlVolume @owned } 'SA_PASSWORD_POLICY_EXISTING_VOLUME_FORBIDDEN' 'partial owned receipt never masquerades as seeded'
        Assert-Policy ($script:ephemeralCalls -eq $before) 'partial receipt causes no reinitialization'

        # Exercise the public workflow's real argument binding without a runtime.
        . (Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1')
        function Write-LabInfo { param([string]$Message) }
        function Write-LabSuccess { param([string]$Message) }
        function New-SqlServerLab {
            param([string]$Version,[string]$Provider,[string]$Profile,[string]$InstanceId,[string]$LabName,
                [string]$DataRoot,[switch]$PersistentData,
                [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$PersistentStorageId,
                [string]$PersistentStorageAction,[string]$AutoStart,[SecureString]$SaPassword,
                [int]$SaPasswordMinimumLength)
            $script:workflowBound = @{} + $PSBoundParameters
            [pscustomobject]@{RunId='synthetic-only'}
        }
        $null = Invoke-SqlServerLabWorkflowAction -Action NewContainerLab -SqlVersion $version -Provider docker -SaPassword $short -SaPasswordMinimumLength 3
        Assert-Policy (-not $script:workflowBound.ContainsKey('PersistentStorageId')) 'new browser lab omits empty persistent storage id'
        $sourceId = [guid]::NewGuid().ToString()
        $null = Invoke-SqlServerLabWorkflowAction -Action NewContainerLab -SqlVersion $version -Provider docker -SaPassword $short -SaPasswordMinimumLength 3 -PersistentData -PersistentStorageId $sourceId
        Assert-Policy ($script:workflowBound.PersistentStorageId -ceq $sourceId) 'browser retained-store selection forwards valid id'
        Write-Host ("SA PASSWORD POLICY CHECKS: $($script:passed) PASS")
    }
    finally { $short.Dispose();$long.Dispose();$shortText=$null;$longText=$null }
}
    # New-Module executes the checks once during construction; exported functions
    # remain isolated from the product module and no provider executable is resolved.
}
finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $expected=[IO.Path]::GetFullPath((Join-Path $repoRoot '.artifacts/test-runs'))
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expected -or
        [IO.Path]::GetFileName($resolved) -notmatch '^password-policy-[a-f0-9]{32}$' -or
        (Get-Item -LiteralPath $resolved).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'FIXTURE_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
