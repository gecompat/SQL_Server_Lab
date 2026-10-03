# Test-only coordinator. An explicit fresh root selects the additive policy;
# an environment variable alone never authorizes a product runtime effect.
function Get-OwnedHostTestTransport {
    if (-not $script:OwnedHostTestTransport) {
        $sourceRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:OwnedHostTestTransport=New-Module -ArgumentList $sourceRoot -ScriptBlock {
            param($SourceRoot)
            . (Join-Path $SourceRoot 'Private/Common.ps1')
            . (Join-Path $SourceRoot 'Private/StateMachine.ps1')
            . (Join-Path $SourceRoot 'Private/ContainerOwnedHostIntegration.ps1')
            Export-ModuleMember -Function @()
        }
    }
    return $script:OwnedHostTestTransport
}

function Assert-OwnedHostTestRoot {
    param([Parameter(Mandatory)][string]$StateRoot)
    $transport=Get-OwnedHostTestTransport
    & $transport {param($Root) $null=Get-LabOwnedHostPolicy -StateRoot $Root -Required} $StateRoot
}

function Test-OwnedHostTestEvidenceBinding {
    param([string]$StateRoot,[string]$EvidenceRoot)
    if ([IO.Path]::GetFullPath($StateRoot) -ceq [IO.Path]::GetFullPath((Join-Path $EvidenceRoot 'state'))) { return $true }
    Assert-OwnedHostTestRoot -StateRoot $StateRoot
    $transport=Get-OwnedHostTestTransport
    return & $transport {
        param($Root,$Evidence)
        $null=Assert-LabOwnedHostPath $Evidence
        $relative=[IO.Path]::GetRelativePath((Join-Path $Root 'test-artifacts'),$Evidence)
        -not [IO.Path]::IsPathRooted($relative) -and $relative -cne '.' -and $relative -cne '..' -and
            -not $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar)
    } $StateRoot $EvidenceRoot
}

function Invoke-OwnedHostTestCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Invocation,[Parameter(Mandatory)][string[]]$Arguments)
    $transport=Get-OwnedHostTestTransport
    $result=& $transport {
        param($Root,$Selected,$Cli,$Argv)
        $null=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        Invoke-LabContainerRuntimeCommand -StateRoot $Root -Provider $Selected -Invocation $Cli -ArgumentList $Argv -NativeResult
    } $StateRoot $Provider $Invocation $Arguments
    $global:LASTEXITCODE=$result.ExitCode
    Set-Variable -Name LASTEXITCODE -Value $result.ExitCode -Scope 1
    $result.Output
}

function Initialize-OwnedHostTestRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string[]]$Providers,
        [Parameter(Mandatory)][string]$ParentOperationId)
    return & $Module {
        param($Root,$Selected,$Operation)
        if (Test-Path -LiteralPath $Root) { throw 'OWNED_HOST_ROOT_ALREADY_EXISTS' }
        function Read-OwnTestClientMetadata {
            param([string]$Invocation,[string[]]$Arguments)
            $start=[Diagnostics.ProcessStartInfo]::new($Invocation)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($name in @('DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_CONNECTIONS_CONF','PODMAN_SSHKEY')) { $null=$start.Environment.Remove($name) }
            foreach($argument in $Arguments) { $start.ArgumentList.Add($argument) }
            $result=Invoke-LabOwnedHostNativeProcess -StartInfo $start -TimeoutSeconds 10 -MaximumBytes 1048576
            if ($result.ExitCode -ne 0) { throw 'OWNED_HOST_TEST_PIN_DISCOVERY_FAILED' }
            return $result.Stdout
        }
        $pins=foreach($provider in @($Selected|Sort-Object -Unique)) {
            $invocation=Get-LabHostToolInvocation -Name $provider
            if ($provider -ceq 'docker') {
                $name=(Read-OwnTestClientMetadata -Invocation $invocation -Arguments @('context','show')).Trim()
                if (-not $name -or $name.Contains("`n")) { throw 'OWNED_HOST_TEST_DOCKER_CONTEXT_UNRESOLVED' }
                $contexts=@((Read-OwnTestClientMetadata -Invocation $invocation -Arguments @('context','inspect',$name))|ConvertFrom-Json -Depth 16)
                if ($contexts.Count -ne 1) { throw 'OWNED_HOST_TEST_DOCKER_CONTEXT_UNRESOLVED' }
                [pscustomobject]@{Provider=$provider;Invocation=$invocation;Endpoint=[string]$contexts[0].Endpoints.docker.Host;IdentityPath='';IdentitySha256=''}
            } else {
                $connections=@((Read-OwnTestClientMetadata -Invocation $invocation -Arguments @('system','connection','list','--format','json'))|ConvertFrom-Json -Depth 16)
                $selectedConnection=@($connections|Where-Object {$_.Default -eq $true})
                if ($selectedConnection.Count -ne 1) { throw 'OWNED_HOST_TEST_PODMAN_CONNECTION_UNRESOLVED' }
                $identity=Assert-LabOwnedHostPath ([string]$selectedConnection[0].Identity)
                [pscustomobject]@{Provider=$provider;Invocation=$invocation;Endpoint=[string]$selectedConnection[0].URI;IdentityPath=$identity;IdentitySha256=(Get-FileHash -LiteralPath $identity).Hash.ToLowerInvariant()}
            }
        }
        $policy=Initialize-LabOwnedHostPolicy -StateRoot $Root -RuntimePins @($pins) -ParentOperationId $Operation
        foreach($provider in $Selected) {
            # Actual same-pin Info and local-machine evidence before any arrange.
            $null=Get-LabOwnedHostRuntimeScope -StateRoot $Root -Provider $provider
        }
        [pscustomobject]@{StateRoot=$policy.StateRoot;PolicyId=$policy.PolicyId;Status='READY';NativeArrangeStarted=$false}
    } $StateRoot $Providers $ParentOperationId
}

function Get-OwnedHostTestArtifactRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$Name)
    Assert-OwnedHostTestRoot -StateRoot $StateRoot
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$') { throw 'OWNED_HOST_TEST_NAME_INVALID' }
    $directory=Join-Path (Join-Path $StateRoot 'test-artifacts') ($Name+'-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -Path $directory -ItemType Directory -ErrorAction Stop
    return $directory
}

# Short data paths avoid adding the evidence directory and its GUID to native
# backup bind mounts. Only a fresh allocation in this process may be removed.
function New-OwnedHostTestDataRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidateSet('preflight','transfer')][string]$Purpose)
    $transport=Get-OwnedHostTestTransport
    & $transport {
        param($Root,$Purpose)
        $policy=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        $leaf=if($Purpose -ceq 'preflight'){'dpf'}else{'dtr'}
        $path=Assert-LabOwnedHostPath (Join-Path $policy.StateRoot $leaf)
        if(Test-Path -LiteralPath $path){throw 'OWNED_HOST_TEST_DATA_ALREADY_EXISTS'}
        $null=New-Item -Path $path -ItemType Directory -ErrorAction Stop
        $marker=Join-Path $path 'test-data-claim.private'
        [IO.File]::WriteAllText($marker,[guid]::NewGuid().ToString('D'))
        if(-not $script:OwnedHostTestDataClaims){$script:OwnedHostTestDataClaims=@{}}
        $script:OwnedHostTestDataClaims[$path]=[pscustomobject]@{
            PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
            PolicyHash=(Get-FileHash -LiteralPath (Join-Path $policy.StateRoot 'owned-host-policy.json')).Hash
            MarkerHash=(Get-FileHash -LiteralPath $marker).Hash
        }
        return $path
    } $StateRoot $Purpose
}

function Remove-OwnedHostTestDataRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$DataRoot)
    $transport=Get-OwnedHostTestTransport
    & $transport {
        param($Root,$Data)
        $policy=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        $path=Assert-LabOwnedHostPath $Data
        $allowed=@('dpf','dtr'|ForEach-Object{Join-Path $policy.StateRoot $_})
        if($path -cnotin $allowed -or -not $script:OwnedHostTestDataClaims -or
            -not $script:OwnedHostTestDataClaims.ContainsKey($path)){throw 'OWNED_HOST_TEST_DATA_UNCLAIMED'}
        $claim=$script:OwnedHostTestDataClaims[$path]
        $marker=Assert-LabOwnedHostPath (Join-Path $path 'test-data-claim.private')
        if($claim.PolicyId -cne $policy.PolicyId -or $claim.RootScopeId -cne $policy.RootScopeId -or
            $claim.PolicyHash -cne (Get-FileHash -LiteralPath (Join-Path $policy.StateRoot 'owned-host-policy.json')).Hash -or
            $claim.MarkerHash -cne (Get-FileHash -LiteralPath $marker -ErrorAction Stop).Hash){throw 'OWNED_HOST_TEST_DATA_CLAIM_DRIFT'}
        if(@(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop|
            Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'OWNED_HOST_REPARSE_PATH'}
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $path){throw 'OWNED_HOST_TEST_DATA_CLEANUP_INCOMPLETE'}
        $script:OwnedHostTestDataClaims.Remove($path)
    } $StateRoot $DataRoot
}
