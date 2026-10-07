# Synthetic five-column Support article tables; no live source or runtime.
$supportUrl='https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates'
$supportHtml=@'
<h2>SQL Server complete version list tables</h2>
<h3 id="sql-server-2022">SQL Server 2022</h3>
<table><thead><tr><th>Build number or version</th><th>Service pack</th><th>Update</th><th>Knowledge Base number</th><th>Release date</th></tr></thead><tbody>
<tr><td>16.0.2000.2</td><td>None</td><td>CU2</td><td><a href="/synthetic/5000002">KB5000002</a></td><td>January 2, 2026</td></tr>
<tr><td>16.0.9000.9</td><td>None</td><td>CU2 + GDR</td><td>KB5000009</td><td>January 9, 2026</td></tr>
</tbody></table>
<h3 id="sql-server-2019">SQL Server 2019</h3>
<table><thead><tr><th>Build number or version</th><th>Service pack</th><th>Update</th><th>Knowledge Base number</th><th>Release date</th></tr></thead><tbody>
<tr><td>15.0.2000.8</td><td>None</td><td>CU8</td><td>KB5000008</td><td>January 8, 2026</td></tr>
<tr><td>15.0.2000.7</td><td>None</td><td>CU7</td><td>KB4570012</td><td>January 7, 2026</td></tr>
</tbody></table>
'@
$supportRows=& $module {
    param($Html,$Url)
    $source=Get-LabCuStatusSourceConfiguration | Select-Object -First 1
    if($source.url -cne $Url -or @($source.allowedHosts).Count -ne 1 -or $source.allowedHosts[0] -cne 'support.microsoft.com'){throw 'SUPPORT_SOURCE_BINDING_INVALID'}
    Get-LabCuStatusRows -Sources @($source) -WebRequestAction {param($Uri)if($Uri -cne $Url){throw 'UNEXPECTED_REQUEST'};[pscustomobject]@{Content=$Html}}
} $supportHtml $supportUrl
Add-CheckResult -Name 'Support-HTML verwendet feste Quelle, fünf Spalten, CU-only und bestehende Rücknahmefilter' -Success (
    @($supportRows).Count -eq 2 -and @($supportRows.Update) -contains 'CU2' -and @($supportRows.Update) -contains 'CU8' -and
    @($supportRows.SourceUrl | Sort-Object -Unique).Count -eq 1 -and $supportRows[0].SourceUrl -ceq $supportUrl -and
    $supportRows[0].Kb -ceq 'KB5000008'
)
$formattedHtml=$supportHtml.Replace('<td>CU2</td>','<td><span>CU&#50;</span></td>').Replace('KB5000002</a>','KB500000&#50;</a>')
$formattedRows=& $module {param($Html,$Url)Get-LabCuStatusRows -Sources @([pscustomobject]@{url=$Url;id='synthetic';allowedHosts=@('support.microsoft.com');excludedUpdates=@()}) -WebRequestAction {[pscustomobject]@{Content=$Html}}} $formattedHtml $supportUrl
Add-CheckResult -Name 'Support-Zellmarkup und Entities werden vor dem gebundenen CU-Parser normalisiert' -Success (
    @($formattedRows | Where-Object {$_.Version -ceq '2022' -and $_.Update -ceq 'CU2' -and $_.Kb -ceq 'KB5000002'}).Count -eq 1)
foreach($case in @('headers','duplicate','extra-table','no-table','extra','missing','build','kb','date','pipe','empty','oversize')){
    $invalid=switch($case){
        'headers' {$supportHtml.Replace('Build number or version','Unknown column')}
        'duplicate' {$supportHtml+ $supportHtml}
        'extra-table' {$supportHtml.Replace('<h3 id="sql-server-2019">','<table><tr><td>unknown</td></tr></table><h3 id="sql-server-2019">')}
        'no-table' {'<h3>SQL Server 2022</h3><p>Unknown structure</p>'}
        'extra' {$supportHtml.Replace('<td>CU2</td>','<td>CU2</td><td>extra</td>')}
        'missing' {$supportHtml.Replace('<td>CU2</td>','')}
        'build' {$supportHtml.Replace('16.0.2000.2','unknown')}
        'kb' {$supportHtml.Replace('KB5000002','unknown')}
        'date' {$supportHtml.Replace('January 2, 2026','unknown')}
        'pipe' {$supportHtml.Replace('<td>None</td>','<td>None|injected</td>')}
        'empty' {'<p>No build tables</p>'}
        'oversize' {'x'*524289}
    }
    $caught=& $module {param($Html)try{ConvertFrom-LabCuStatusSupportHtml $Html | Out-Null;''}catch{$_.Exception.Message}} $invalid
    Add-CheckResult -Name ('Support-Parser vetoisiert Formatdrift ohne vermutete Aktualität: '+$case) -Success ($caught -ceq 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID')
}
$budgetCode=& $module {param($Html)try{ConvertFrom-LabCuStatusSupportHtml $Html -ParserBudget {throw 'RESOURCE_WATCH_TIMEOUT'} | Out-Null;''}catch{$_.Exception.Message}} $supportHtml
Add-CheckResult -Name 'Support-Parser respektiert die vorhandene gesamte Parserdeadline' -Success ($budgetCode -ceq 'RESOURCE_WATCH_TIMEOUT')
$oldThreePart=$supportHtml.Replace('SQL Server 2022','SQL Server 2005').Replace('16.0.2000.2','9.00.2000')
$oldRows=& $module {param($Html,$Url)Get-LabCuStatusRows -Sources @([pscustomobject]@{url=$Url;id='synthetic';allowedHosts=@('support.microsoft.com');excludedUpdates=@()}) -WebRequestAction {[pscustomobject]@{Content=$Html}}} $oldThreePart $supportUrl
Add-CheckResult -Name 'Historische dreiteilige SQL-2005-Builds bleiben außerhalb des bestehenden vierteiligen CU-Vertrags' -Success (
    @($oldRows|Where-Object Version -eq '2005').Count -eq 0 -and @($oldRows|Where-Object Version -eq '2019').Count -eq 2)
$withOldSummary=$supportHtml+'<h3>SQL Server 2000</h3><table><tr><th>Version number</th><th>Description</th></tr><tr><td>8.0</td><td>Historical summary</td></tr></table>'
$summaryRows=& $module {param($Html,$Url)Get-LabCuStatusRows -Sources @([pscustomobject]@{url=$Url;id='synthetic';allowedHosts=@('support.microsoft.com');excludedUpdates=@()}) -WebRequestAction {[pscustomobject]@{Content=$Html}}} $withOldSummary $supportUrl
Add-CheckResult -Name 'SQL-2000-Zusammenfassung wird nicht zu einem CU-Nachweis umgedeutet' -Success (
    @($summaryRows).Count -eq 3 -and @($summaryRows|Where-Object Version -eq '2000').Count -eq 0)
foreach($uri in @(($supportUrl+'?unexpected=1'),($supportUrl+'#fragment'),$supportUrl.Replace('support.microsoft.com','unapproved.invalid'))){
    $caught=& $module {param($Uri)try{Assert-LabResourceWatchUri $Uri;''}catch{$_.Exception.Message}} $uri
    Add-CheckResult -Name 'Support-Ausbau erlaubt keine anderen Hosts, Queries oder Fragmente' -Success ($caught -ceq 'RESOURCE_WATCH_SOURCE_INVALID')
}
$completeReport=& $module {
    param($Url)
    $script:ResourceWatchCache=$null
    $catalogVersions=@(Get-SqlServerVersions -Status SUPPORTED)
    $blocks=@(foreach($entry in $catalogVersions){$last=@($entry.docker.builds|Sort-Object {[version]$_.build} -Descending|Select-Object -First 1);'<h3>SQL Server '+$entry.id+'</h3><table><thead><tr><th>Build number or version</th><th>Service pack</th><th>Update</th><th>Knowledge Base number</th><th>Release date</th></tr></thead><tbody><tr><td>'+$last[0].build+'</td><td>None</td><td>'+$last[0].cu+'</td><td>'+$last[0].kb+'</td><td>January 1, 2026</td></tr></tbody></table>'})
    $fakeHtml=$blocks -join "`n"
    $request={param($Uri)if($Uri -ceq $Url){return [pscustomobject]@{Content=$fakeHtml}};[pscustomobject]@{Content='<h2>Stable</h2><li>Build number: 170.4.83.3</li>'}}
    $view=Invoke-LabResourceWatchRefresh -WebRequestAction $request
    $script:ResourceWatchCache=$null
    $view
} $supportUrl
Add-CheckResult -Name 'Vollständiger Resource-Watch-Core verarbeitet Support-HTML und SqlPackage mit vier gebundenen Ergebnissen' -Success (
    $completeReport.Status -ceq 'NO_CHANGE' -and $completeReport.Items.Count -eq 4 -and @($completeReport.Items|Where-Object Status -cne 'NO_CHANGE').Count -eq 0)
