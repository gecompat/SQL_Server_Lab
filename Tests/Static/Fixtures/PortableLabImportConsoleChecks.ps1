param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$TestRoot)

$ErrorActionPreference = 'Stop'
& $Module {
    param($Repo,$RootPath)
    $id = '33333333-3333-3333-3333-333333333333'
    $package = '{"ContractVersion":"SqlServerLab.PortableLabPackage/1.1","PackageId":"11111111-1111-1111-1111-111111111111","Source":{"Provider":"podman","SqlMajorVersion":"17"},"BackupReferences":[]}'
    $path = Join-Path $RootPath 'guided-package.json'
    [IO.File]::WriteAllText($path,$package)
    $previousRoot = $env:SQL_SERVER_LAB_STATE
    try {
        $env:SQL_SERVER_LAB_STATE = $RootPath
        function Get-LabContainerSqlConsoleTargets {
            param([switch]$IncludeStopped)
            if (-not $IncludeStopped) { throw 'GUIDED_IMPORT_STOPPED_TARGETS_MISSING' }
            [pscustomobject]@{RunId=$id;Provider='docker';Label='Synthetic Docker'}
        }
        function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
        function Read-LabConsoleTextInput { param($Prompt) [pscustomobject]@{Status='Confirmed';Value=$path} }
        function Wait-LabConsoleAcknowledgement { $null }
        function Write-LabError { param($Message) throw $Message }
        $text = @(Invoke-LabMenuAction -ActionName PortableImportPlan 6>&1) -join "`n"
        if ($text -notmatch 'Importplan: READY' -or $text -notmatch 'Synthetic Docker') { throw 'GUIDED_PORTABLE_IMPORT_PLAN_INVALID' }

        . (Join-Path $Repo 'Tools/WorkflowUiCommandGrants.ps1')
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
        $route=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/portable-lab-import-plan'''},$true)
        if ($parseErrors.Count -or -not $route) { throw 'PORTABLE_IMPORT_ROUTE_MISSING' }
        $routeScript=[scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
        $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';HasEntityBody=$true;Url=[uri]'http://127.0.0.1:39000/api/portable-lab-import-plan'}}
        $responses=[Collections.Generic.List[object]]::new()
        function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $responses.Add(@{Status=$StatusCode;Body=$Body}) }
        $inputQueue=[Collections.Generic.Queue[string]]::new()
        $inputQueue.Enqueue(('{"TargetProvider":"docker","TargetProvider":"podman","TargetRunId":"'+$id+'","Package":'+$package+'}'))
        $inputQueue.Enqueue(('{"TargetProvider":"docker","TargetRunId":"'+$id+'","Package":'+$package+'}'))
        function Read-UiJsonRequestBody { param($Request,$MaxBytes) [pscustomobject]@{Allowed=$true;Body=$inputQueue.Dequeue()} }
        & $routeScript
        & $routeScript
        $received=$responses[1].Body | ConvertFrom-Json
        if ($responses.Count -ne 2 -or $responses[0].Status -ne 400 -or $responses[1].Status -ne 200 -or
            $received.TargetRunId -ne $id -or $received.Status -ne 'READY' -or $received.ExecutionImplemented -ne $false) { throw 'PORTABLE_IMPORT_ROUTE_INVALID' }
        Write-Host 'PASS: Geführter Importplan bindet Paket und Ziel; doppelte Eingabeschlüssel werden gesperrt.'
    }
    finally { $env:SQL_SERVER_LAB_STATE = $previousRoot }
} $Repository $TestRoot
