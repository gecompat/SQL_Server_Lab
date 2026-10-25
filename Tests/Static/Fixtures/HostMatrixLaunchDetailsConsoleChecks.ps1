$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root Catalogs
    $script:VersionCatalog=Get-Content (Join-Path $root Catalogs/sql-server-versions.json) -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($name in @('Docker','Podman','HyperV')){$definition=Get-Content (Join-Path $root "Providers/$name/provider.json") -Raw|ConvertFrom-Json;$script:RegisteredProviders[$definition.name]=@{Definition=$definition}}
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/ExternalRuntimeCapability.ps1',
        'Private/HostCapabilityMatrix.ps1','Private/HostCapabilityMatrixConsole.ps1','Public/Get-SqlServerLabHostCapabilityMatrix.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1')){. (Join-Path $root $path)}
    $script:passed=0;$script:probes=0;$script:calls=0;$script:ack=0;$script:captured=$null;$script:cancel='';$script:probe=$false;$script:next='Details'
    function Assert-Case {param([bool]$Condition,[string]$Name) if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"}
    function Read-LabExternalRuntimeHostFacts {param($Provider) $script:probes++;[pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Facts=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='2';Rootless=$false}}}
    $script:original=(Get-Command Get-SqlServerLabExternalRuntimeCapability).ScriptBlock
    function Get-SqlServerLabExternalRuntimeCapability {param($SqlVersion,$Provider,$OperatingSystem,$SoftwareId,$RuntimeVersion,$VariantId,[switch]$CheckProviderReadiness)
        $script:calls++;$script:captured=@{};foreach($key in $PSBoundParameters.Keys){$script:captured[$key]=$PSBoundParameters[$key]}; & $script:original @PSBoundParameters
    }
    function Get-LabDiagnosticReadiness {throw 'UNEXPECTED_BOOTSTRAP_PROBE'}
    function Add-LabMessage {throw 'JOURNAL_FORBIDDEN'}
    function Write-LabInfo {throw 'JOURNAL_FORBIDDEN'}
    function Invoke-Sqlcmd {throw 'SQL_FORBIDDEN'}
    function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Data) [pscustomobject]@{Id=$Id;Data=$Data}}
    function Wait-LabConsoleAcknowledgement {param($Prompt) $script:ack++}
    function Select-LabConsoleDataItem {param($ScreenId,$Title,$Subtitle,$Items)
        if($ScreenId -ceq $script:cancel){return $null}
        switch($ScreenId){
            'host-matrix-sql'{return [pscustomobject]@{id='2022'}}
            'host-matrix-probe'{return [pscustomobject]@{Probe=$false}}
            'host-matrix-next'{return [pscustomobject]@{Action=$script:next}}
            'host-matrix-launch-variant'{return $Items[0].Data}
            'host-matrix-launch-probe'{return [pscustomobject]@{Probe=$script:probe}}
            default{throw 'UNEXPECTED_SCREEN'}
        }
    }
    $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022;$rows=@(Get-LabHostMatrixLaunchRows $matrix)
    Assert-Case ($rows.Count -eq 6 -and @($rows|Where-Object {$_.Provider -cnotin @('docker','podman') -or $_.Language -ceq 'C#'}).Count -eq 0) 'Eligible continuation uses only exact resolved Linux container variants'
    $legacy=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2016
    Assert-Case (@(Get-LabHostMatrixLaunchRows $legacy).Count -eq 0) 'Uncatalogued versions create no continuation or inferred support'
    foreach($probe in @($false,$true)) {
        $script:probe=$probe;$before=$script:probes;$beforeCalls=$script:calls;$acks=$script:ack
        $output=@(Show-LabHostCapabilityMatrixInteractive 6>&1|ForEach-Object {[string]$_})
        Assert-Case ($script:calls -eq $beforeCalls+1 -and $script:probes -eq $before+$(if($probe){1}else{0}) -and $script:ack -eq $acks+2) "Actual console continuation probe=$probe; calls=$($script:calls-$beforeCalls); probes=$($script:probes-$before); acknowledgements=$($script:ack-$acks)"
        Assert-Case ($script:captured.Provider -ceq 'docker' -and $script:captured.SqlVersion -ceq '2022' -and $script:captured.SoftwareId -ceq 'sql-python' -and
            $script:captured.VariantId -ceq 'sql2022-python310-ubuntu2204-derived' -and $script:captured.RuntimeVersion -ceq '3.10' -and $script:captured.OperatingSystem -ceq 'linux') 'Actual console/public tuple binding is preserved'
        Assert-Case (($output -join '\n') -match 'Keine Ausführungsfreigabe' -and ($output -join '\n') -match $(if($probe){'CGROUP_VERSION_UNSUPPORTED'}else{'READINESS_NOT_REQUESTED'})) 'Actual existing classifier result is displayed without granting SQL or target rights'
    }
    foreach($cancel in @('host-matrix-next','host-matrix-launch-variant','host-matrix-launch-probe')) {
        $script:cancel=$cancel;$before=$script:probes;$beforeCalls=$script:calls
        $null=@(Show-LabHostCapabilityMatrixInteractive 6>&1)
        Assert-Case ($script:probes -eq $before -and $script:calls -eq $beforeCalls) "Cancellation precedes all detail/host work: $cancel"
    }
    $script:cancel='';$script:next='Return';$before=$script:calls
    $null=@(Show-LabHostCapabilityMatrixInteractive 6>&1)
    Assert-Case ($script:calls -eq $before) 'Default return does not inspect a variant'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Private/HostCapabilityMatrixConsole.ps1),[ref]$tokens,[ref]$errors)
    $allowed=@('Where-Object','New-LabConsoleItem','Select-LabConsoleDataItem','Get-SqlServerLabExternalRuntimeCapability','Write-Host',
        'Wait-LabConsoleAcknowledgement','Get-SqlServerLabHostCapabilityMatrix','Get-LabHostMatrixLaunchRows','Show-LabHostMatrixLaunchDetailsInteractive')
    Assert-Case ($errors.Count -eq 0 -and @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|Where-Object {$_.GetCommandName() -cnotin $allowed}).Count -eq 0 -and
        @($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -or $n -is [Management.Automation.Language.FileRedirectionAst]},$true)).Count -eq 0) 'Console authority remains UI, direct nonpersisting display and existing read-only public queries'
    function Test-HelpAuthority {
        param([string]$Source)
        $tokens=$null;$errors=$null;$parsed=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
        if($errors.Count -or @($parsed.FindAll({param($n)$n -is [Management.Automation.Language.FileRedirectionAst]},$true)).Count){return $false}
        $commands=@('Assert-LabConsoleKeyNotInterrupted','ForEach-Object','Format-LabConsoleHelp','Format-LabConsoleText','Get-LabConsoleHelpCatalog',
            'Get-LabDataRootDefault','Get-LabStateRoot','Read-LabConsoleKey','Split-LabConsoleHelpText','Write-LabConsoleFrame')
        if(@($parsed.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|Where-Object {
            $name=$_.GetCommandName()
            if($null -ne $name){$name -cnotin $commands}
            else{$_.CommandElements[0].Extent.Text -cnotin @('$candidate.Test','$FrameWriter')}
        }).Count){return $false}
        $static=@('IO.Path|IsPathRooted','Math|Max');$constructors=@('System.Collections.Generic.List[object]','System.Collections.Generic.List[string]')
        $instances=@('$clean|Trim','$lines|Add','$preconditions|Add','$visible|Add','$wrapped[$index]|TrimStart')
        foreach($call in @($parsed.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true))) {
            if($call.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]){return $false}
            $name=$call.Member.Value
            if($call.Static) {
                if($call.Expression -isnot [Management.Automation.Language.TypeExpressionAst]){return $false}
                $type=$call.Expression.TypeName.FullName
                if($name -ceq 'new'){if($type -cnotin $constructors){return $false}}
                elseif("$type|$name" -cnotin $static){return $false}
            } elseif(([regex]::Replace($call.Expression.Extent.Text,'\s+','')+'|'+$name) -cnotin $instances){return $false}
        }
        return $true
    }
    Assert-Case (Test-HelpAuthority (Get-Content (Join-Path $root Private/ConsoleHelp.ps1) -Raw)) 'Curated help stays within existing metadata getters, concrete collections and console rendering'
    foreach($source in @('[IO.File]::Copy("source","target")','Get-LabConsoleHelpCatalog > private-file.json','& $untrusted')) {
        Assert-Case (-not (Test-HelpAuthority $source)) 'Help authority rejects file-copy and file-redirection syntax without executing it'
    }
    Write-Host "Host matrix launch bridge console: $script:passed PASS; actual catalogue/classifier, synthetic host facts."
}
try {& $module { }} finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
