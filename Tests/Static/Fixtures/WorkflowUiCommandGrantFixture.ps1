# Gemeinsamer synthetischer Catalogleaf; echte Granthelpers und Fehlerwriter.
$fixtureRepo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $fixtureRepo 'Tools/WorkflowUiCommandGrants.ps1')
$fixtureTree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $fixtureRepo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
. ([scriptblock]::Create($fixtureTree.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiCommandGrantFailure'},$true).Extent.Text))
function Get-UiCommandGrantCatalog {
    @('synthetic','Remove-SqlServerLab')|ForEach-Object {[pscustomobject]@{Name=$_;RequiresConfirmation=$true;ParameterSets=@([pscustomobject]@{Name='synthetic';Parameters=@()})}}
}
function Get-FixtureCommandGrant {
    param([Parameter(Mandatory)][string]$ListenerUrl,[Parameter(Mandatory)][string]$Body,[string]$Capability=('a'*64))
    $client=[Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(5)
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$ListenerUrl+'api/command-grants')
    try {
        $null=$request.Headers.TryAddWithoutValidation('X-SqlServerLab-Operator',$Capability)
        $request.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        try {if([int]$response.StatusCode -ne 201){throw 'FIXTURE_GRANT_ISSUE_FAILED'};return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json}
        finally {$response.Dispose()}
    } finally {$request.Dispose();$client.Dispose()}
}
