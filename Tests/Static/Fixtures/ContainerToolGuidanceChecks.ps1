param([Parameter(Mandatory)][string]$Repository)
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'Public/Test-SqlServerLabContainerTool.ps1')
. (Join-Path $Repository 'Private/ContainerToolGuidance.ps1')
$runId='11111111-2222-4333-8444-555555555555'
$scopeId='66666666-7777-4888-8999-000000000000'
$containerId='a'*64
$root=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-container-tool-'+[guid]::NewGuid().ToString('N'))
$probe=[pscustomobject]@{Id=$containerId;Arguments=$null;Calls=0;InspectExit=0}
function Get-LabRunState { param($RunId,$StateRoot) @{state='RUNNING';scopeId=$scopeId;metadata=@{ownedHostIntegration=$false}} }
function Resolve-LabRunInstance { param($RunId,$InstanceId,$StateRoot) @{Provider='docker';ContainerName='mutable-synthetic-name'} }
function Get-LabHostToolInvocation {
    param($Name)
    {
        $global:LASTEXITCODE=0
        if ($args[0] -ceq 'inspect') {
            $global:LASTEXITCODE=$probe.InspectExit
            @{
                Id=$probe.Id;State=@{Status='running'}
                Config=@{Labels=@{'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId
                    'sql-server-lab.instance-id'='primary';'sql-server-lab.container-tool.ids'='sqlpackage'}}
            } | ConvertTo-Json -Depth 6 -Compress
            return
        }
        if ($args[0] -ceq 'exec') { $probe.Calls++;$probe.Arguments=@($args);'SqlPackage 162.5.57.1';return }
        throw 'UNEXPECTED_TEST_PROVIDER_OPERATION'
    }
}

$savedExitCode=$global:LASTEXITCODE
try {
    $result=Test-SqlServerLabContainerTool -RunId $runId -InstanceId primary -StateRoot $root
    if ($result.RuntimeVersion -cne '162.5.57.1' -or $probe.Calls -ne 1 -or
        ($probe.Arguments -join '|') -cne "exec|--user|mssql|$containerId|/opt/sql-server-lab/tools/sqlpackage/sqlpackage|/Version"){
        throw 'CONTAINER_TOOL_FIXTURE_NOT_BOUND'
    }
    $probe.Id='mutable-synthetic-name'
    $invalid=try{Test-SqlServerLabContainerTool -RunId $runId -InstanceId primary -StateRoot $root | Out-Null;$false}
        catch{$_.Exception.Message -ceq 'CONTAINER_TOOL_OWNERSHIP_MISMATCH'}
    if (-not $invalid -or $probe.Calls -ne 1) { throw 'CONTAINER_TOOL_FIXTURE_UNBOUND_EXEC' }
    $probe.Id=$containerId
    $probe.InspectExit=1
    $providerFailed=try{Test-SqlServerLabContainerTool -RunId $runId -InstanceId primary -StateRoot $root | Out-Null;$false}
        catch{$_.Exception.Message -ceq 'CONTAINER_TOOL_INSPECTION_FAILED'}
    if (-not $providerFailed -or $probe.Calls -ne 1) { throw 'CONTAINER_TOOL_FIXTURE_FAILED_INSPECTION_EXEC' }
}
finally { $global:LASTEXITCODE=$savedExitCode }

function Get-LabContainerSqlConsoleTargets { @{RunId=$runId;InstanceId='primary';Label='synthetic Docker SQL'} }
function New-LabConsoleItem { param($Id,$Label,$Data) @{Data=$Data} }
function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
function Read-LabConfirm { param($Prompt,$Default) $false }
function Test-SqlServerLabContainerTool { throw 'CANCEL_MUST_NOT_START_TOOL' }
Invoke-LabContainerToolCheckInteractive
'CONTAINER TOOL GUIDANCE: 4 PASS'
