#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
$passed = 0
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw ('SA_PASSWORD_HTTP_FIXTURE_FAILED: '+$Name) }; $script:passed++ }
$module = New-Module -Name SqlServerLab -ArgumentList $repo -ScriptBlock {
    param($Root)
    . (Join-Path $Root 'Private/VersionCatalog.ps1')
    . (Join-Path $Root 'Private/SecretProvider.ps1')
    . (Join-Path $Root 'Private/SaPasswordPolicy.ps1')
    $script:VersionCatalog = Get-Content -Raw -LiteralPath (Join-Path $Root 'Catalogs/sql-server-versions.json') | ConvertFrom-Json
}
Import-Module $module
try {
    $server = Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($server,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'real server parses'
    $routes = @($ast.FindAll({param($Node) $Node -is [Management.Automation.Language.IfStatementAst] -and
        $Node.Clauses[0].Item1.Extent.Text.StartsWith("`$path -eq '/api/actions' -and")},$true))
    Check ($routes.Count -eq 1) 'actual action route extracted exactly once'
    $route = [scriptblock]::Create('foreach($once in @(1)) ' + $routes[0].Clauses[0].Item2.Extent.Text)
    function Start-UiWorkflowJob { param($Action,$Parameters) $script:jobsStarted++; [pscustomobject]@{Id='synthetic-job';Action=$Action} }
    function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $script:responseCode=$StatusCode; $script:responseBody=$Body }
    $jobs = @{}; $persistentJobs = @{}; $script:jobsStarted=0
    $version = '2025-' + $module.Invoke({$script:VersionCatalog.versions.Where({$_.id -eq '2025'})[0].docker.builds[0].cu})
    $short = -join @([char]65,[char]98,[char]51)
    function Invoke-SyntheticRequest([string]$Json) {
        $script:responseCode=0; $script:responseBody=''
        $context=[pscustomobject]@{Request=[pscustomobject]@{InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Json));ContentEncoding=[Text.Encoding]::UTF8}}
        & $route
    }
    $base = @{action='NewContainerLab';parameters=@{Provider='docker';SqlVersion=$version;Profile='standard';InstanceId='primary';LabName='synthetic';PersistentData=$false;AutoStart='off';SaPassword=$short}}
    try { Invoke-SyntheticRequest ($base | ConvertTo-Json -Depth 5 -Compress); throw 'EXPECTED_REJECTION_MISSING' }
    catch { Check ($_.Exception.Message -ceq 'UI_SA_PASSWORD_PREFLIGHT_FAILED') 'default short password rejected before job' }
    Check ($script:jobsStarted -eq 0) 'no job after invalid password'
    $base.parameters.SaPasswordMinimumLength=3
    Invoke-SyntheticRequest ($base | ConvertTo-Json -Depth 5 -Compress)
    Check ($script:jobsStarted -eq 1 -and $script:responseCode -eq 202) 'explicit pinned minimum reaches one synthetic job'
    $duplicate='{"action":"NewContainerLab","parameters":{"Provider":"docker","SqlVersion":"'+$version+'","SaPassword":"'+$short+'","SaPassword":"'+$short+'"}}'
    try { Invoke-SyntheticRequest $duplicate; throw 'EXPECTED_REJECTION_MISSING' }
    catch { Check ($_.Exception.Message -ceq 'UI_SA_PASSWORD_REQUEST_INVALID') 'duplicate password rejected by actual route' }
    Check ($script:jobsStarted -eq 1) 'malformed request starts no second job'
    $manifest = @{action='NewContainerLabFromManifest';parameters=@{ManifestPath='synthetic.json';SaPassword=$short}}
    try { Invoke-SyntheticRequest ($manifest | ConvertTo-Json -Depth 4 -Compress); throw 'EXPECTED_REJECTION_MISSING' }
    catch { Check ($_.Exception.Message -ceq 'UI_SA_PASSWORD_PREFLIGHT_FAILED') 'manifest default criterion rejects before job' }
    Check ($script:jobsStarted -eq 1 -and $script:responseBody -notmatch [regex]::Escape($short)) 'no secret in response or later job'
    Write-Host "SA PASSWORD HTTP CHECKS: $passed PASS; listener, action and provider NOT_EXECUTED"
}
finally { Remove-Module $module -Force }
