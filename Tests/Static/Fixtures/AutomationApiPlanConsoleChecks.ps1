param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$Repository)

$ErrorActionPreference = 'Stop'
& $Module {
    param($Repo)
    function Select-LabConsoleDataItem {
        param($ScreenId,$Title,$Items)
        if (@($Items).Count -ne 6) { throw 'AUTOMATION_MENU_INCOMPLETE' }
        return ($Items | Where-Object Id -ceq 'import').Data
    }
    function Wait-LabConsoleAcknowledgement { $null }
    function Write-LabError { param($Message) throw $Message }
    $text = @(Invoke-LabMenuAction -ActionName AutomationApiPlan 6>&1) -join "`n"
    if ($text -notmatch 'Get-SqlServerLabPortableLabImportPlan' -or $text -notmatch 'nicht verfügbar') {
        throw 'GUIDED_AUTOMATION_PLAN_INVALID'
    }
    $tokens=$null; $parseErrors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
    $route = $ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/automation-plan'''},$true)
    if ($parseErrors.Count -or -not $route) { throw 'AUTOMATION_PLAN_ROUTE_MISSING' }
    $routeScript = [scriptblock]::Create('foreach ($once in @(1)) '+$route.Clauses[0].Item2.Extent.Text)
    $query = [Collections.Specialized.NameValueCollection]::new()
    $context = [pscustomobject]@{ Request = [pscustomobject]@{HttpMethod='GET';HasEntityBody=$false;QueryString=$query} }
    $responses = [Collections.Generic.List[object]]::new()
    function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $responses.Add(@{Status=$StatusCode;Body=$Body}) }
    $query.Add('action','HyperVRecoveryPoint')
    & $routeScript
    $query.Add('action','PortableLabImport')
    & $routeScript
    $received = $responses[0].Body | ConvertFrom-Json
    if ($responses.Count -ne 2 -or $responses[0].Status -ne 200 -or $responses[1].Status -ne 400 -or
        $received.Plan.Command -ne 'Get-SqlServerLabHyperVRecoveryPointPlan' -or $null -ne $received.Result.ActionCommand -or
        $received.ExecutionImplemented -ne $false) { throw 'AUTOMATION_PLAN_ROUTE_INVALID' }
    Write-Host 'PASS: Beide Fachansichten zeigen auch gültige Verträge ohne Ausführungsbefehl.'
} $Repository
