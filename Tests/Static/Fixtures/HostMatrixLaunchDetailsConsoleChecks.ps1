$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root Catalogs
    $script:VersionCatalog=Get-Content (Join-Path $root Catalogs/sql-server-versions.json) -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($name in @('Docker','Podman','HyperV')){$definition=Get-Content (Join-Path $root "Providers/$name/provider.json") -Raw|ConvertFrom-Json;$script:RegisteredProviders[$definition.name]=@{Definition=$definition}}
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/CapabilityEvidence.ps1','Private/ExternalRuntimeCapability.ps1',
        'Private/ExternalRuntimeHostPrerequisites.ps1','Private/HostCapabilityMatrix.ps1','Private/HostCapabilityMatrixConsole.ps1','Public/Get-SqlServerLabHostCapabilityMatrix.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1')){. (Join-Path $root $path)}
    $script:passed=0;$script:probes=0;$script:calls=0;$script:ack=0;$script:captured=$null;$script:cancel='';$script:mode='catalog';$script:next='Details';$script:syntheticHistory=$false
    function Assert-Case {param([bool]$Condition,[string]$Name) if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"}
    function Read-LabExternalRuntimeHostFacts {
        param($Provider,[switch]$IncludeHostPrerequisites)
        $script:probes++
        $observation = [pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Facts=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='2';Rootless=$false}}
        if ($IncludeHostPrerequisites) {
            $observation.Facts.CgroupVersion = '1'
            $observation | Add-Member -NotePropertyName PrerequisiteRuntimeInfo -NotePropertyValue ([pscustomobject]@{
                OSType='linux';CgroupVersion='1';SecurityOptions=@();MemoryLimit=$true;PidsLimit=$false;MemTotal=2GB;NCPU=16
            })
        }
        $observation
    }
    $script:original=(Get-Command Get-SqlServerLabExternalRuntimeCapability).ScriptBlock
    function Get-SqlServerLabExternalRuntimeCapability {param($SqlVersion,$Provider,$OperatingSystem,$SoftwareId,$RuntimeVersion,$VariantId,[switch]$CheckProviderReadiness,[switch]$IncludeHostPrerequisites,[switch]$IncludeProviderFacts,[switch]$IncludeRecordedEvidence,$ResourceProfile)
        $script:calls++;$script:captured=@{};foreach($key in $PSBoundParameters.Keys){$script:captured[$key]=$PSBoundParameters[$key]}
        $decision = & $script:original @PSBoundParameters
        if ($script:syntheticHistory) {
            $cell = [pscustomobject]@{RecordCount=1; Source='SYNTHETIC_PRIVATE_REFERENCE'}
            $decision.HistoricalEvidence = New-LabExternalRuntimeHistoricalEvidenceResult 'RECORDED_HISTORY_ONLY' 'DEFINED' 'INDEX_MATCH_RECORDED' -Cells @($cell)
        }
        $decision
    }
    function Get-LabDiagnosticReadiness {throw 'UNEXPECTED_BOOTSTRAP_PROBE'}
    function Add-LabMessage {throw 'JOURNAL_FORBIDDEN'}
    function Write-LabInfo {throw 'JOURNAL_FORBIDDEN'}
    function Invoke-Sqlcmd {throw 'SQL_FORBIDDEN'}
    function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Data) [pscustomobject]@{Id=$Id;Data=$Data}}
    function Wait-LabConsoleAcknowledgement {param($Prompt) $script:ack++}
    function Select-LabConsoleDataItem {param($ScreenId,$Title,$Subtitle,$Items,$SelectedId)
        if($ScreenId -ceq $script:cancel){return $null}
        switch($ScreenId){
            'host-matrix-sql'{return [pscustomobject]@{id='2022'}}
            'host-matrix-probe'{return [pscustomobject]@{Probe=$false}}
            'host-matrix-next'{return [pscustomobject]@{Action=$script:next}}
            'host-matrix-launch-variant'{return $Items[0].Data}
            'host-matrix-launch-probe'{return ($Items|Where-Object Id -CEQ $script:mode).Data}
            'host-matrix-launch-profile'{return ($Items|Where-Object Id -CEQ 'performance').Data}
            default{throw 'UNEXPECTED_SCREEN'}
        }
    }
    $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022;$rows=@(Get-LabHostMatrixLaunchRows $matrix)
    Assert-Case ($rows.Count -eq 6 -and @($rows|Where-Object {$_.Provider -cnotin @('docker','podman') -or $_.Language -ceq 'C#'}).Count -eq 0) 'Eligible continuation uses only exact resolved Linux container variants'
    $legacy=Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2016
    Assert-Case (@(Get-LabHostMatrixLaunchRows $legacy).Count -eq 0) 'Uncatalogued versions create no continuation or inferred support'
    foreach($probe in @($false,$true)) {
        $script:mode=if($probe){'probe'}else{'catalog'};$before=$script:probes;$beforeCalls=$script:calls;$acks=$script:ack
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
    $script:mode='prerequisites';$script:cancel='host-matrix-launch-profile';$before=$script:probes;$beforeCalls=$script:calls
    $null=@(Show-LabHostCapabilityMatrixInteractive 6>&1)
    Assert-Case ($script:probes -eq $before -and $script:calls -eq $beforeCalls) 'Profile cancellation does not call the service or provider'
    $script:cancel=''
    $output=@(Show-LabHostCapabilityMatrixInteractive 6>&1|ForEach-Object {[string]$_}) -join "`n"
    Assert-Case ($script:calls -eq $beforeCalls+1 -and $script:probes -eq $before+1 -and $script:captured.ResourceProfile -ceq 'performance' -and
        $script:captured.IncludeProviderFacts -and $script:captured.IncludeHostPrerequisites -and $script:captured.CheckProviderReadiness) 'Explicit profile uses one existing read-only observation'
    Assert-Case ($output -match 'RESOURCE_CONTROLLERS_UNAVAILABLE' -and $output -match 'CAPACITY_INSUFFICIENT' -and
        $output -match 'fehlend pids' -and $output -match 'Keine Ausführungsfreigabe') 'Profile result displays bounded prerequisite failure and withholds execution authority'
    Assert-Case ($output -match 'Provider meldet · Runtime-OS linux · cgroup 1 · Rootless nein') 'CLI profile details show normalized provider facts beside the blocking reason'
    $script:mode='history';$before=$script:probes;$beforeCalls=$script:calls
    $output=@(Show-LabHostCapabilityMatrixInteractive 6>&1|ForEach-Object {[string]$_}) -join "`n"
    Assert-Case ($script:calls -eq $beforeCalls+1 -and $script:probes -eq $before -and $script:captured.IncludeRecordedEvidence -and
        -not $script:captured.CheckProviderReadiness -and -not $script:captured.IncludeHostPrerequisites) 'History reads the selected identity once without a current provider probe'
    Assert-Case ($output -match 'INDEX_LEGACY_IDENTITY_UNKNOWN' -and $output -match 'historische Einträge 0' -and
        $output -match 'NOT_VERIFIED' -and $output -match 'NOT_CHECKED') 'Actual legacy index stays distinct from a positive match and host readiness'
    $script:syntheticHistory=$true
    $output=@(Show-LabHostCapabilityMatrixInteractive 6>&1|ForEach-Object {[string]$_}) -join "`n"
    Assert-Case ($output -match 'RECORDED_HISTORY_ONLY' -and $output -match 'historische Einträge 1' -and
        $output -notmatch 'SYNTHETIC_PRIVATE_REFERENCE' -and $output -match 'SQL-Sprachausführung bleibt ungeprüft') 'Positive history renders a count and leaves raw records and live evaluation out'
    $script:syntheticHistory=$false
    $script:cancel='';$script:next='Return';$before=$script:calls
    $null=@(Show-LabHostCapabilityMatrixInteractive 6>&1)
    Assert-Case ($script:calls -eq $before) 'Default return does not inspect a variant'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Private/HostCapabilityMatrixConsole.ps1),[ref]$tokens,[ref]$errors)
    $allowed=@('Where-Object','New-LabConsoleItem','Select-LabConsoleDataItem','Get-SqlServerLabExternalRuntimeCapability','Write-Host',
        'Wait-LabConsoleAcknowledgement','Get-SqlServerLabHostCapabilityMatrix','Get-LabHostMatrixLaunchRows','Show-LabHostMatrixLaunchDetailsInteractive',
        'ConvertTo-LabExternalRuntimeHistorySummary')
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
