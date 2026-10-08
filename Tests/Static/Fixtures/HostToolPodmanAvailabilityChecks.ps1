# Exercise the actual availability function with a recording bridge only.
$podmanTokens = $null
$podmanParseErrors = $null
$podmanAst = [Management.Automation.Language.Parser]::ParseInput($podmanProviderText,[ref]$podmanTokens,[ref]$podmanParseErrors)
$podmanFunctions = @($podmanAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-PodmanAvailable'
},$true))
if ($podmanParseErrors.Count -ne 0 -or $podmanFunctions.Count -ne 1) { throw 'SYNTHETIC_PODMAN_FUNCTION_INVALID' }
$allowedProbeCommands = @('Test-Path','Join-Path','Get-LabOwnedHostPolicy','Get-LabHostToolInvocation','Invoke-LabContainerRuntimeCommand','Out-String')
$unsafeProbeCommands = @($podmanFunctions[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        ($node.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -or
         $node.GetCommandName() -cnotin $allowedProbeCommands)
},$true))
Add-CheckResult -Name 'Podman-Probe ist vor synthetischer Ausfuehrung ohne native oder dynamische Aufrufgrenze' -Success ($unsafeProbeCommands.Count -eq 0)
if ($unsafeProbeCommands.Count -ne 0) { throw 'SYNTHETIC_PODMAN_NATIVE_CALL_FORBIDDEN' }
$probeDefinition = $podmanFunctions[0].Extent.Text
$probePathBefore = $env:PATH
try {
    # A missing absolute executable and empty PATH make an accidental fallback fail.
    $env:PATH = ''
    $observations = & {
        . ([scriptblock]::Create($probeDefinition))
        $probeRoot = Join-Path $temporaryRoot 'podman-availability'
        $plainRoot = Join-Path $probeRoot 'plain'
        $ownedRoot = Join-Path $probeRoot 'owned'
        $null = New-Item -ItemType Directory -Path $plainRoot,$ownedRoot
        Set-Content -LiteralPath (Join-Path $ownedRoot 'owned-host-required') -Value 'synthetic' -Encoding ascii
        $expectedInvocation = [IO.Path]::GetFullPath((Join-Path $probeRoot $(if ($IsWindows) {'not-executed/podman.exe'} else {'not-executed/podman'})))
        $trace = [Collections.Generic.List[object]]::new()
        $resolverTrace = [Collections.Generic.List[string]]::new()
        $policyTrace = [Collections.Generic.List[object]]::new()
        function Get-LabHostToolInvocation {
            param([string]$Name)
            $resolverTrace.Add($Name)
            if ($Name -cne 'podman' -or $mode -ceq 'resolver-failure') { throw 'SYNTHETIC_RESOLVER_REJECTED' }
            return $expectedInvocation
        }
        function Get-LabOwnedHostPolicy {
            param([string]$StateRoot,[switch]$Required)
            $policyTrace.Add([pscustomobject]@{StateRoot=$StateRoot;Required=[bool]$Required})
            if ($StateRoot -cne $ownedRoot -or -not $Required) { throw 'SYNTHETIC_POLICY_BINDING_INVALID' }
            return [pscustomobject]@{Synthetic=$true}
        }
        function Invoke-LabContainerRuntimeCommand {
            param([string]$Provider,[string]$Invocation,[string]$StateRoot,[string[]]$ArgumentList)
            $trace.Add([pscustomobject]@{Provider=$Provider;Invocation=$Invocation;StateRoot=$StateRoot;Arguments=@($ArgumentList)})
            if ($Provider -cne 'podman' -or $Invocation -cne $expectedInvocation -or
                $StateRoot -cne $expectedRoot) { throw 'SYNTHETIC_BRIDGE_BINDING_INVALID' }
            $isVersion = $ArgumentList.Count -eq 3 -and $ArgumentList[0] -ceq 'version' -and
                $ArgumentList[1] -ceq '--format' -and $ArgumentList[2] -ceq '{{.Client.Version}}'
            $isInfo = $ArgumentList.Count -eq 1 -and $ArgumentList[0] -ceq 'info'
            if (-not ($isVersion -or $isInfo)) { throw 'SYNTHETIC_BRIDGE_ARGUMENT_INVALID' }
            $exitCode = if (($isVersion -and $mode -ceq 'version-failure') -or
                ($isInfo -and $mode -ceq 'info-failure')) { 7 } else { 0 }
            Set-Variable -Name LASTEXITCODE -Value $exitCode -Scope 1
            if ($isVersion) { return ' 27.0.0 ' }
        }
        foreach ($case in @(
            @{Name='plain';Root=$plainRoot;Mode='success';Available=$true;Calls=2;PolicyCalls=0;Version='27.0.0'},
            @{Name='owned';Root=$ownedRoot;Mode='success';Available=$true;Calls=2;PolicyCalls=1;Version='27.0.0'},
            @{Name='version-failure';Root=$plainRoot;Mode='version-failure';Available=$false;Calls=1;PolicyCalls=0;Version=$null},
            @{Name='info-failure';Root=$plainRoot;Mode='info-failure';Available=$false;Calls=2;PolicyCalls=0;Version='27.0.0'},
            @{Name='resolver-failure';Root=$plainRoot;Mode='resolver-failure';Available=$false;Calls=0;PolicyCalls=0;Version=$null}
        )) {
            $trace.Clear(); $resolverTrace.Clear(); $policyTrace.Clear()
            $mode = $case.Mode
            $expectedRoot = $case.Root
            $result = Test-PodmanAvailable -StateRoot $expectedRoot
            $exactCalls = $trace.Count -eq $case.Calls
            for ($index=0; $index -lt $trace.Count; $index++) {
                $call = $trace[$index]
                $expectedArguments = if ($index -eq 0) { @('version','--format','{{.Client.Version}}') } else { @('info') }
                $exactCalls = $exactCalls -and $call.Provider -ceq 'podman' -and
                    $call.Invocation -ceq $expectedInvocation -and [IO.Path]::IsPathFullyQualified($call.Invocation) -and
                    $call.StateRoot -ceq $expectedRoot -and $call.Arguments.Count -eq $expectedArguments.Count -and
                    (@($call.Arguments) -join "`n") -ceq ($expectedArguments -join "`n")
            }
            $exactPolicy = $policyTrace.Count -eq $case.PolicyCalls
            if ($policyTrace.Count -eq 1) {
                $exactPolicy = $exactPolicy -and $policyTrace[0].StateRoot -ceq $ownedRoot -and $policyTrace[0].Required
            }
            [pscustomobject]@{Name=$case.Name;Success=(
                $result.Available -eq $case.Available -and $result.Version -ceq $case.Version -and
                $resolverTrace.Count -eq 1 -and $resolverTrace[0] -ceq 'podman' -and
                $exactCalls -and $exactPolicy -and $env:PATH -ceq '' -and -not (Test-Path -LiteralPath $expectedInvocation))}
        }
    }
    foreach ($observation in $observations) {
        Add-CheckResult -Name "Echte Podman-Probe bindet Resolver, StateRoot und version/info an die Bridge: $($observation.Name)" -Success $observation.Success
    }
    Add-CheckResult -Name 'Podman-Bridge-Fixture fuehrt alle fuenf synthetischen Faelle aus' -Success ($observations.Count -eq 5)
}
finally {
    $env:PATH = $probePathBefore
}
Add-CheckResult -Name 'Podman-Bridge-Fixture stellt den Prozess-PATH wieder her' -Success ($env:PATH -ceq $probePathBefore)
