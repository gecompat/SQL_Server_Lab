# Offline execution of public projection and the complete issue protocol, with a synthetic API.
. (Join-Path $repoRoot 'Tools/Common/VersionCatalogResourceWatchAutomation.ps1')
$automationFixture=[pscustomobject]@{
    Contract='SqlServerLab.ResourceWatch/1.0';Status='NEW';CheckedAtUtc='2026-01-01T00:00:00Z'
    Items=@(
        [pscustomobject]@{Id='sql-cu-2022';Status='NO_CHANGE';CatalogVersion='16.0.1000.1';ObservedVersion='16.0.1000.1';SourceUrl='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates';ReasonCode='RESOURCE_WATCH_COMPLETED';Name='SYNTHETIC_PRIVATE_NAME'}
        [pscustomobject]@{Id='sqlpackage';Status='NEW';CatalogVersion='170.4.83.3';ObservedVersion='170.5.96.0';SourceUrl='https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17';ReasonCode='RESOURCE_WATCH_COMPLETED';LastSuccessfulVersion='SYNTHETIC_PRIVATE_HISTORY'}
    );Notice='SYNTHETIC_PRIVATE_NOTICE';CatalogPath='SYNTHETIC_PRIVATE_PATH'
}
function Copy-AutomationFixture { $automationFixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12 }
function Get-AutomationFixtureEvaluation {
    param($Result=$automationFixture)
    Invoke-LabResourceWatchAutomationEvaluation -Check { [pscustomobject]@{Result=$Result;ExpectedId=@('sql-cu-2022','sqlpackage')} }
}
$automation=Get-AutomationFixtureEvaluation
Add-CheckResult -Name 'UTC-Projektion bewahrt typisierte JSON-Datetimes unabhängig von lokaler Zeitzone' -Success (
    (ConvertTo-LabResourceWatchUtcTime ([datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime())) -ceq (ConvertTo-LabResourceWatchUtcTime '2026-01-01T00:00:00Z') -and
    (ConvertTo-LabResourceWatchUtcTime ([datetimeoffset]'2026-01-01T02:00:00+02:00')) -ceq (ConvertTo-LabResourceWatchUtcTime '2026-01-01T00:00:00Z')
)
Add-CheckResult -Name 'Resource-Watch automatisiert genau CU plus katalogisiertes SqlPackage ohne Rohfelder' -Success (
    -not $automation.CheckFailed -and $automation.Status -eq 'NEW' -and $automation.Findings.Count -eq 2 -and
    ($automation | ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE' -and $automation.Report -match 'Nächste Aktion' -and $automation.Report -match 'Betroffene Fähigkeit'
)
$later=Copy-AutomationFixture;$later.CheckedAtUtc='2026-02-01T00:00:00Z'
$laterEvaluation=Get-AutomationFixtureEvaluation $later
Add-CheckResult -Name 'Persistenter Befundschlüssel ist unabhängig von Monat und Zeitpunkt' -Success (
    ($automation.Findings.FindingKey -join '|') -ceq ($laterEvaluation.Findings.FindingKey -join '|')
)
foreach($case in @('source','observed','reason','duplicate','missing','time','overall','behind','empty')){
    $invalid=Copy-AutomationFixture
    switch($case){
        'source' {$invalid.Items[1].SourceUrl+='&SYNTHETIC_PRIVATE=value'}
        'observed' {$invalid.Items[1].ObservedVersion='SYNTHETIC_PRIVATE'}
        'reason' {$invalid.Items[1].ReasonCode='SYNTHETIC_PRIVATE_REASON'}
        'duplicate' {$invalid.Items[1].Id='sql-cu-2022'}
        'missing' {$invalid.Items=@($invalid.Items[0])}
        'time' {$invalid.CheckedAtUtc='SYNTHETIC_PRIVATE_TIME'}
        'overall' {$invalid.Status='NO_CHANGE'}
        'behind' {$invalid.Items[1].ObservedVersion='170.1.1.1'}
        'empty' {$invalid.Items=@()}
    }
    $safe=Get-AutomationFixtureEvaluation $invalid
    Add-CheckResult -Name ('Automation weist ungültigen Veröffentlichungsvertrag ab: '+$case) -Success (
        $safe.CheckFailed -and $safe.ReasonCode -eq 'RESOURCE_WATCH_REPORT_FAILED' -and ($safe | ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE'
    )
}
$hardFailure=@(Invoke-LabResourceWatchAutomationEvaluation -Check {Write-Warning 'SYNTHETIC_PRIVATE_WARNING';Write-Host 'SYNTHETIC_PRIVATE_HOST';throw 'SYNTHETIC_PRIVATE_EXCEPTION'} *>&1)
$softFailure=@(Invoke-LabResourceWatchAutomationEvaluation -Check {Write-Error 'SYNTHETIC_PRIVATE_ERROR' -ErrorAction Continue;[pscustomobject]@{Result=$automationFixture;ExpectedId=@('sql-cu-2022','sqlpackage')}} *>&1)
Add-CheckResult -Name 'Automation fängt harte und nichtterminierende Checkfehler ohne Rohstreams ab' -Success (
    $hardFailure.Count -eq 1 -and $softFailure.Count -eq 1 -and $hardFailure[0].CheckFailed -and $softFailure[0].CheckFailed -and
    ($hardFailure+$softFailure | ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE'
)

$fixtureStore=@{Issues=[Collections.Generic.List[object]]::new();Calls=[Collections.Generic.List[string]]::new();Writes=0;LoseWrite=$false;LoseClose=$false;FailRead=$false;Drift=$false;Mismatch=$false;FullPages=$false}
$fixtureApi={param($Method,$Path,$Body)
    $fixtureStore.Calls.Add($Method+' '+$Path)
    if($fixtureStore.FailRead){throw 'SYNTHETIC_PRIVATE_API_FAILURE'}
    if($Path -match '\?'){
        if($fixtureStore.FullPages){$data=@(1..100 | ForEach-Object {[pscustomobject]@{body='not managed'}})}else{
            $selected=if($Path -match 'labels=cu-watch'){@($fixtureStore.Issues | Where-Object {@($_.labels | Where-Object name -ceq 'cu-watch').Count -gt 0})}else{@($fixtureStore.Issues)}
            $page=[int]([regex]::Match($Path,'[?&]page=(\d+)').Groups[1].Value)
            $data=@($selected | Select-Object -Skip (($page-1)*100) -First 100 | ForEach-Object {$_ | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8})
        }
        return [pscustomobject]@{Data=$data}
    }
    if($Method -eq 'POST'){
        $number=100+$fixtureStore.Issues.Count
        $issue=[pscustomobject]@{number=$number;html_url=('https://github.com/gecompat/SQL_Server_Lab/issues/'+$number);state='open';body=$Body.body;title=$Body.title;labels=@($Body.labels | ForEach-Object {[pscustomobject]@{name=$_}})}
        $fixtureStore.Issues.Add($issue);$fixtureStore.Writes++
        if($fixtureStore.LoseWrite){$fixtureStore.LoseWrite=$false;throw 'SYNTHETIC_PRIVATE_LOST_RESPONSE'}
        return [pscustomobject]@{Data=($issue | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8)}
    }
    $number=[long]($Path -split '/')[-1];$issue=@($fixtureStore.Issues | Where-Object number -eq $number)[0]
    if($Method -eq 'PATCH'){
        $fixtureStore.Writes++;if($Body.ContainsKey('body')){$issue.body=$Body.body};if($Body.ContainsKey('title')){$issue.title=$Body.title};$issue.state=$Body.state
        if($fixtureStore.Mismatch){$issue.state='closed'}
        if($fixtureStore.LoseClose){$fixtureStore.LoseClose=$false;throw 'SYNTHETIC_PRIVATE_LOST_CLOSE'}
    }
    $copy=$issue | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8
    if($fixtureStore.Drift -and $Method -eq 'GET'){$copy.body+='SYNTHETIC_PRIVATE_EDIT'}
    if($fixtureStore.DropLabelOnRead -and $Method -eq 'GET'){$copy.labels=@()}
    [pscustomobject]@{Data=$copy}
}
$preview=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi -WhatIf
Add-CheckResult -Name 'Issuevorschau mutiert nichts und behauptet keine Veröffentlichung' -Success (
    $fixtureStore.Writes -eq 0 -and -not $preview.NotificationFailed -and @($preview.Receipts | Where-Object Status -eq 'NOT_EXECUTED').Count -eq 1
)
$published=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi
Add-CheckResult -Name 'Issueveröffentlichung benötigt exakten nachgelesenen Ressourcen- und Befundreceipt' -Success (
    -not $published.NotificationFailed -and $fixtureStore.Writes -eq 1 -and $fixtureStore.Issues.Count -eq 1 -and
    @($published.Receipts | Where-Object {$_.Status -eq 'PUBLISHED' -and $_.Verified -and $_.ResourceId -eq 'sqlpackage' -and $_.IssueNumber -eq 100}).Count -eq 1
)
$lostLabel=$fixtureStore.Issues[0];$lostLabel.labels=@();$before=$fixtureStore.Writes;$countBefore=$fixtureStore.Issues.Count
$afterLabelLoss=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi
Add-CheckResult -Name 'Labelverlust kann Marker nicht verstecken oder identischen Befund erneut POSTen' -Success (
    $afterLabelLoss.NotificationFailed -and $fixtureStore.Writes -eq $before -and $fixtureStore.Issues.Count -eq $countBefore
)
while($fixtureStore.Issues.Count -gt $countBefore){$fixtureStore.Issues.RemoveAt($fixtureStore.Issues.Count-1)}
$fixtureStore.Writes=$before;$lostLabel.labels=@([pscustomobject]@{name='cu-watch'})
$savedIssues=@($fixtureStore.Issues);$fixtureStore.Issues.Clear()
1..100 | ForEach-Object {$fixtureStore.Issues.Add([pscustomobject]@{body='unmanaged';title='unmanaged'})}
$lostLabel.labels=@();$fixtureStore.Issues.Add($lostLabel)
$pagedLabelLoss=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi
Add-CheckResult -Name 'Marker ohne Watchlabel auf zweiter vollständiger Seite blockiert Create' -Success (
    $pagedLabelLoss.NotificationFailed -and $fixtureStore.Writes -eq $before -and
    @($fixtureStore.Calls | Where-Object {$_ -match 'state=all&per_page=100&page=2$'}).Count -gt 0
)
$fixtureStore.Issues.Clear();foreach($issue in $savedIssues){$fixtureStore.Issues.Add($issue)}
$lostLabel.labels=@([pscustomobject]@{name='cu-watch'})
$fixtureStore.DropLabelOnRead=$true
$freshLabelLoss=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi
Add-CheckResult -Name 'Labelverlust erst bei frischer GET-Revalidierung blockiert auch Dedupe' -Success ($freshLabelLoss.NotificationFailed -and $fixtureStore.Writes -eq $before)
$fixtureStore.DropLabelOnRead=$false
$repeated=Invoke-LabResourceWatchIssueProjection -Evaluation $laterEvaluation -ApiAction $fixtureApi
Add-CheckResult -Name 'Gleicher Befund im Folgemonat erzeugt keine weiteren Nachrichten oder Writes' -Success (
    -not $repeated.NotificationFailed -and $fixtureStore.Writes -eq 1 -and @($repeated.Receipts | Where-Object Status -eq 'DEDUPLICATED').Count -eq 1
)
$tampered= $laterEvaluation | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
$tampered.Findings[1].Report='SYNTHETIC_PRIVATE_PAYLOAD';$tampered.Findings[1].FindingKey='F'*64
$noLeak=Invoke-LabResourceWatchIssueProjection -Evaluation $tampered -ApiAction $fixtureApi
Add-CheckResult -Name 'Issuegrenze rekonstruiert Befund und Schlüssel statt übergebene Reports hochzuladen' -Success (
    -not $noLeak.NotificationFailed -and $fixtureStore.Writes -eq 1 -and ($fixtureStore.Issues | ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE'
)
$failureResult=Copy-AutomationFixture;$failureResult.Status='UNCLEAR';$failureResult.Items[1].Status='UNCLEAR';$failureResult.Items[1].ReasonCode='RESOURCE_WATCH_TIMEOUT';$failureResult.Items[1].ObservedVersion=$null
$unclear=Get-AutomationFixtureEvaluation $failureResult
$unclearReceipt=Invoke-LabResourceWatchIssueProjection -Evaluation $unclear -ApiAction $fixtureApi
Add-CheckResult -Name 'Gelungener Issuehinweis heilt weder Timeout noch roten Metadatencheck' -Success (
    $unclearReceipt.CheckFailed -and -not $unclearReceipt.NotificationFailed -and $fixtureStore.Writes -eq 2 -and $fixtureStore.Issues[0].body -match 'RESOURCE_WATCH_TIMEOUT'
)
$recoveredResult=Copy-AutomationFixture;$recoveredResult.Status='NO_CHANGE';$recoveredResult.Items[1].Status='NO_CHANGE';$recoveredResult.Items[1].CatalogVersion='170.5.96.0';$recovered=Get-AutomationFixtureEvaluation $recoveredResult
$recoveryReceipt=Invoke-LabResourceWatchIssueProjection -Evaluation $recovered -ApiAction $fixtureApi
Add-CheckResult -Name 'Einzelerholung schließt genau das gebundene Issue ohne Kommentar oder Fremdlabeländerung' -Success (
    -not $recoveryReceipt.CheckFailed -and -not $recoveryReceipt.NotificationFailed -and $fixtureStore.Issues[0].state -eq 'closed' -and $fixtureStore.Writes -eq 3
)
$newRevision=Copy-AutomationFixture;$newRevision.Items[1].ObservedVersion='170.6.1.0';$revision=Get-AutomationFixtureEvaluation $newRevision
$fixtureStore.LoseWrite=$true
# Reopening an existing issue succeeds normally; use a fresh store to simulate lost POST response.
$fixtureStore.Issues.Clear();$before=$fixtureStore.Writes
$lost=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
$resumed=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
Add-CheckResult -Name 'Verlorene Createantwort bleibt Recoverybedarf; Wiederaufnahme findet Marker ohne zweites Issue' -Success (
    $lost.NotificationFailed -and @($lost.Receipts | Where-Object Status -eq 'RECOVERY_REQUIRED').Count -eq 1 -and
    -not $resumed.NotificationFailed -and $fixtureStore.Issues.Count -eq 1 -and $fixtureStore.Writes -eq $before+1
)
$fixtureStore.Drift=$true;$before=$fixtureStore.Writes
$driftReceipt=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
Add-CheckResult -Name 'Manuell veränderte Issuebytes blockieren vor Schreibzugriff' -Success ($driftReceipt.NotificationFailed -and $fixtureStore.Writes -eq $before)
$fixtureStore.Drift=$false
$duplicateIssue=$fixtureStore.Issues[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8
$duplicateIssue.number=101;$duplicateIssue.html_url='https://github.com/gecompat/SQL_Server_Lab/issues/101';$fixtureStore.Issues.Add($duplicateIssue)
$duplicateReceipt=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
Add-CheckResult -Name 'Mehrdeutige Ressourcenmarker blockieren statt blind ein Issue zu wählen' -Success ($duplicateReceipt.NotificationFailed -and $fixtureStore.Writes -eq $before)
$newCu=Copy-AutomationFixture;$newCu.Items[0].Status='NEW';$newCu.Items[0].ObservedVersion='16.0.1000.2'
$ambiguousBeforeNewCu=Invoke-LabResourceWatchIssueProjection -Evaluation (Get-AutomationFixtureEvaluation $newCu) -ApiAction $fixtureApi
Add-CheckResult -Name 'Scopeweite Markermehrdeutigkeit blockiert auch vorherigen neuen Ressourcenwrite' -Success ($ambiguousBeforeNewCu.NotificationFailed -and $fixtureStore.Writes -eq $before)
$fixtureStore.Issues.Clear();$fixtureStore.FailRead=$true
$apiFailure=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
Add-CheckResult -Name 'Fehlende Issueberechtigung oder API bleibt getrennt und ohne Rohdiagnose sichtbar' -Success (
    $apiFailure.NotificationFailed -and -not $apiFailure.CheckFailed -and ($apiFailure | ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_PRIVATE'
)
$fixtureStore.FailRead=$false;$fixtureStore.FullPages=$true
$full=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi
Add-CheckResult -Name 'Unvollständige begrenzte Pagination verhindert Create und Dedupebehauptung' -Success (
    $full.NotificationFailed -and $full.Receipts[0].ReasonCode -eq 'RESOURCE_WATCH_ISSUE_LIST_INCOMPLETE' -and $fixtureStore.Writes -eq $before
)
$fixtureStore.FullPages=$false
$global=Invoke-LabResourceWatchIssueProjection -Evaluation $hardFailure[0] -ApiAction $fixtureApi
$afterGlobal=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi
Add-CheckResult -Name 'Globaler Checkfehler wird dedupliziert gemeldet und nach auswertbarem Check separat geschlossen' -Success (
    $global.CheckFailed -and -not $global.NotificationFailed -and -not $afterGlobal.NotificationFailed -and
    @($fixtureStore.Issues | Where-Object {$_.body -match 'resource=watch-check' -and $_.state -eq 'closed'}).Count -eq 1
)
$ownScope='own-'+('0'*32);$before=$fixtureStore.Writes
$regularBodies=@($fixtureStore.Issues.body)
$own=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi -IssueScope $ownScope -AcceptanceResourceId sqlpackage -ExpectedId @('sql-cu-2022','sqlpackage') -PublicationHead ('a'*40)
$ownAgain=Invoke-LabResourceWatchIssueProjection -Evaluation $laterEvaluation -ApiAction $fixtureApi -IssueScope $ownScope -AcceptanceResourceId sqlpackage -ExpectedId @('sql-cu-2022','sqlpackage') -PublicationHead ('a'*40)
Add-CheckResult -Name 'Eigene Abnahmefixture verwendet getrennten Namespace und lässt reguläre Issuebytes unverändert' -Success (
    $own.IssueScope -ceq $ownScope -and -not $own.NotificationFailed -and -not $ownAgain.NotificationFailed -and $fixtureStore.Writes -eq $before+1 -and
    @($fixtureStore.Issues | Where-Object { $_.body -cin $regularBodies }).Count -eq $regularBodies.Count
)
$before=$fixtureStore.Writes
$cleanupPreview=Close-LabResourceWatchIssueFixture -Receipt $own -ExpectedIssueScope $ownScope -ApiAction $fixtureApi -WhatIf
Add-CheckResult -Name 'Own-Issue-Cleanupvorschau verändert kein Issue und bewahrt Prüfergebnis' -Success (
    $fixtureStore.Writes -eq $before -and @($cleanupPreview.Cleanup | Where-Object Status -eq 'NOT_EXECUTED').Count -eq 1 -and -not $cleanupPreview.CheckFailed
)
$fixtureStore.Mismatch=$true
$mismatch=Invoke-LabResourceWatchIssueProjection -Evaluation $revision -ApiAction $fixtureApi -IssueScope $ownScope -AcceptanceResourceId sqlpackage -ExpectedId @('sql-cu-2022','sqlpackage') -PublicationHead ('a'*40)
Add-CheckResult -Name 'Falsche Issue-Postcondition bleibt unbestätigter Write mit Recoverybedarf' -Success (
    $mismatch.NotificationFailed -and @($mismatch.Receipts | Where-Object Status -eq 'RECOVERY_REQUIRED').Count -eq 1
)
$fixtureStore.Mismatch=$false
$before=$fixtureStore.Writes
# The mismatch test changed this issue's finding. Old receipt must fail before PATCH.
$staleCleanup=Close-LabResourceWatchIssueFixture -Receipt $own -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
Add-CheckResult -Name 'Veralteter Own-Issue-Receipt blockiert Cleanup vor PATCH' -Success ($staleCleanup.RecoveryRequired -and $fixtureStore.Writes -eq $before)
$latestOwn=Invoke-LabResourceWatchIssueProjection -Evaluation $automation -ApiAction $fixtureApi -IssueScope $ownScope -AcceptanceResourceId sqlpackage -ExpectedId @('sql-cu-2022','sqlpackage') -PublicationHead ('a'*40)
$before=$fixtureStore.Writes;$callsBefore=$fixtureStore.Calls.Count
foreach($invalidStatus in @('PUBLISHED','DEDUPLICATED')){
    foreach($case in @('false','missing-number','truthy-string','numeric-verified','fractional-number','string-number','missing-verified','missing-bodyhash')){
        $badReceipt=$latestOwn | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
        $row=$badReceipt.Receipts | Where-Object ResourceId -eq 'sqlpackage';$row.Status=$invalidStatus
        $row.ReasonCode=if($invalidStatus -eq 'PUBLISHED'){'RESOURCE_WATCH_ISSUE_VERIFIED'}else{'RESOURCE_WATCH_ISSUE_ALREADY_RECORDED'}
        switch($case){
            'false' {$row.Verified=$false}
            'missing-number' {$row.PSObject.Properties.Remove('IssueNumber')}
            'truthy-string' {$row.Verified='true'}
            'numeric-verified' {$row.Verified=1}
            'fractional-number' {$row.IssueNumber=100.5}
            'string-number' {$row.IssueNumber=[string]$row.IssueNumber}
            'missing-verified' {$row.PSObject.Properties.Remove('Verified')}
            'missing-bodyhash' {$row.PSObject.Properties.Remove('BodySha256')}
        }
        $caught='';try{Close-LabResourceWatchIssueFixture -Receipt $badReceipt -ExpectedIssueScope $ownScope -ApiAction $fixtureApi | Out-Null}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name ('Cleanup validiert jeden '+$invalidStatus+'-Receipt vor Zielfilter: '+$case) -Success (
            $caught -eq 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID' -and $fixtureStore.Writes -eq $before -and $fixtureStore.Calls.Count -eq $callsBefore
        )
    }
}
foreach($case in @('check-bool','notification-bool','empty-rows','scalar-rows','unverified-notice')){
    $badReceipt=$latestOwn | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    switch($case){
        'check-bool' {$badReceipt.CheckFailed='false'}
        'notification-bool' {$badReceipt.NotificationFailed='false'}
        'empty-rows' {$badReceipt.Receipts=@()}
        'scalar-rows' {$badReceipt.Receipts=$badReceipt.Receipts[0]}
        'unverified-notice' {$badReceipt.Receipts[0].Status='NO_NOTICE_NEEDED';$badReceipt.Receipts[0].Verified=$true}
    }
    $caught='';try{Close-LabResourceWatchIssueFixture -Receipt $badReceipt -ExpectedIssueScope $ownScope -ApiAction $fixtureApi | Out-Null}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('Cleanup lehnt unvollständige oder falsch typisierte Statusclaims vor API ab: '+$case) -Success ($caught -eq 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID' -and $fixtureStore.Calls.Count -eq $callsBefore)
}
$before=$fixtureStore.Writes
$closedOwn=Close-LabResourceWatchIssueFixture -Receipt $latestOwn -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
$closedAgain=Close-LabResourceWatchIssueFixture -Receipt $latestOwn -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
Add-CheckResult -Name 'Own-Issue-Cleanup revalidiert Scope/Repo/Marker, schließt und wiederholt als No-op' -Success (
    -not $closedOwn.RecoveryRequired -and -not $closedAgain.RecoveryRequired -and $fixtureStore.Writes -eq $before+1 -and
    @($closedOwn.Cleanup | Where-Object Status -eq 'CLOSED').Count -eq 1 -and @($closedAgain.Cleanup | Where-Object Status -eq 'NO_OP').Count -eq 1 -and
    @($fixtureStore.Issues | Where-Object {$_.body -cin $regularBodies}).Count -eq $regularBodies.Count
)
foreach($case in @('scope','repo','number','resource','boundary')){
    $badReceipt=$latestOwn | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    switch($case){
        'scope' {$badReceipt.IssueScope='catalog'}
        'repo' {$badReceipt.Repository='other/fixture'}
        'number' {$badReceipt.Receipts[0].IssueNumber=999}
        'resource' {$badReceipt.Receipts[0].ResourceId='SYNTHETIC_PRIVATE'}
        'boundary' {$badReceipt.ApiBoundary='UNKNOWN'}
    }
    $caught='';try{Close-LabResourceWatchIssueFixture -Receipt $badReceipt -ExpectedIssueScope $ownScope -ApiAction $fixtureApi | Out-Null}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('Own-Issue-Cleanup lehnt ungültige Receiptbindung vor API ab: '+$case) -Success ($caught -eq 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID')
}
$ownUnclear=Invoke-LabResourceWatchIssueProjection -Evaluation $unclear -ApiAction $fixtureApi -IssueScope $ownScope -AcceptanceResourceId sqlpackage -ExpectedId @('sql-cu-2022','sqlpackage') -PublicationHead ('a'*40)
$fixtureStore.LoseClose=$true;$before=$fixtureStore.Writes
$lostClose=Close-LabResourceWatchIssueFixture -Receipt $ownUnclear -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
$resumedClose=Close-LabResourceWatchIssueFixture -Receipt $ownUnclear -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
Add-CheckResult -Name 'Verlorene Closeantwort bleibt Recoverybedarf; bestätigtes Resume heilt keinen Quellenfehler' -Success (
    $lostClose.RecoveryRequired -and $lostClose.CheckFailed -and -not $resumedClose.RecoveryRequired -and $resumedClose.CheckFailed -and
    $fixtureStore.Writes -eq $before+1 -and @($resumedClose.Cleanup | Where-Object Status -eq 'NO_OP').Count -eq 1
)
$bodyDrift=$ownUnclear | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
$bodyDrift.Receipts[0].BodySha256='F'*64;$before=$fixtureStore.Writes
$boundDrift=Close-LabResourceWatchIssueFixture -Receipt $bodyDrift -ExpectedIssueScope $ownScope -ApiAction $fixtureApi
Add-CheckResult -Name 'Cleanup bindet die exakten Bodybytes zusätzlich zum gültigen Marker' -Success ($boundDrift.RecoveryRequired -and $fixtureStore.Writes -eq $before)
foreach($invalidScope in @(('OWN-'+('a'*32)),('own-'+('A'*32)),'catalog',('own-'+('a'*31)))){
    $caught='';try{Close-LabResourceWatchIssueFixture -Receipt $ownUnclear -ExpectedIssueScope $invalidScope -ApiAction $fixtureApi | Out-Null}catch{$caught='REJECTED'}
    Add-CheckResult -Name 'Cleanupscope erzwingt exakt kleine own-Hexsyntax vor API' -Success ($caught -eq 'REJECTED' -and $fixtureStore.Writes -eq $before)
}
# Execute the actual projection with a complete four-resource evaluation and isolated API spies.
$boundedFixture=Copy-AutomationFixture
$boundedFixture.Items+=@('2019','2025') | ForEach-Object {
    [pscustomobject]@{Id=('sql-cu-'+$_);Status='NEW';CatalogVersion='16.0.1000.1';ObservedVersion='16.0.1001.1';SourceUrl=$automationFixture.Items[0].SourceUrl;ReasonCode='RESOURCE_WATCH_COMPLETED'}
}
$boundedIds=@('sql-cu-2019','sql-cu-2022','sql-cu-2025','sqlpackage')
$boundedEvaluation=Invoke-LabResourceWatchAutomationEvaluation -Check {[pscustomobject]@{Result=$boundedFixture;ExpectedId=$boundedIds}}
$boundedScope='own-'+('b'*32)
$boundedArguments=@{IssueScope=$boundedScope;AcceptanceResourceId='sqlpackage';ExpectedId=$boundedIds;PublicationHead=('b'*40);ApiAction=$fixtureApi}
$savedIssues=@($fixtureStore.Issues);$fixtureStore.Issues.Clear();$writesBefore=$fixtureStore.Writes
try{
    $one=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments
    $jsonReceipt=$one | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    $oneAgain=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments -ContinuationReceipt $jsonReceipt
    Add-CheckResult -Name 'Own-Auswahl bewahrt vollständigen Vier-Ressourcenbericht und publiziert höchstens eine Identität' -Success (
        $boundedEvaluation.Findings.Count -eq 4 -and $one.Receipts.Count -eq 1 -and $one.Receipts[0].Status -ceq 'PUBLISHED' -and
        $one.PublishWriteAttempts -eq 1 -and $fixtureStore.Writes -eq $writesBefore+1 -and $oneAgain.Receipts[0].Status -ceq 'DEDUPLICATED'
    )
    foreach($invalidCounter in @('1',1.5,2,-1,$true,[long]::MaxValue,[double]1)){
        $copy=$one | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12;$copy.PublishWriteAttempts=$invalidCounter
        $before=$fixtureStore.Writes;$callsBefore=$fixtureStore.Calls.Count;$caught=''
        try{Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments -ContinuationReceipt $copy | Out-Null}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'Continuation lässt nur echte JSON-Integer im Writebudget 0 oder 1 zu' -Success (
            $caught -ceq 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID' -and $fixtureStore.Writes -eq $before -and $fixtureStore.Calls.Count -eq $callsBefore)
    }
    foreach($case in @('missing-selector','unknown-selector','catalog-selector','foreign-scope','head','finding','bodyhash')){
        $argsCopy=@{};foreach($key in $boundedArguments.Keys){$argsCopy[$key]=$boundedArguments[$key]}
        $copy=$one | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
        switch($case){
            'missing-selector' {$argsCopy.AcceptanceResourceId=''}
            'unknown-selector' {$argsCopy.AcceptanceResourceId='sql-cu-2099'}
            'catalog-selector' {$argsCopy.IssueScope='catalog'}
            'foreign-scope' {$copy.IssueScope='own-'+('c'*32)}
            'head' {$copy.PublicationHead='c'*40}
            'finding' {$copy.Receipts[0].FindingKey='C'*64}
            'bodyhash' {$copy.Receipts[0].BodySha256='C'*64}
        }
        $before=$fixtureStore.Writes;$caught=''
        try{$answer=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @argsCopy -ContinuationReceipt $copy
            if($answer.NotificationFailed){$caught='REJECTED'}
        }catch{$caught='REJECTED'}
        Add-CheckResult -Name ('Own-Veröffentlichung blockiert ungültige Auswahl oder Continuation vor Write: '+$case) -Success ($caught -ceq 'REJECTED' -and $fixtureStore.Writes -eq $before)
    }
    $before=$fixtureStore.Writes
    $globalBlocked=Invoke-LabResourceWatchIssueProjection -Evaluation $hardFailure[0] @boundedArguments
    Add-CheckResult -Name 'Globaler Checkfehler wird bei bereits eigener Ressourcenidentität nicht durch Selector ausgeblendet' -Success (
        $globalBlocked.CheckFailed -and $globalBlocked.NotificationFailed -and $globalBlocked.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_ACCEPTANCE_LIMIT' -and $fixtureStore.Writes -eq $before)
    $fixtureStore.Issues.Clear()
    $fixtureStore.LoseWrite=$true
    $unknown=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    $afterUnknown=$fixtureStore.Writes;$committed=@($fixtureStore.Issues);$fixtureStore.Issues.Clear()
    $absent=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments -ContinuationReceipt $unknown
    $stillAbsent=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments -ContinuationReceipt $absent
    Add-CheckResult -Name 'UNKNOWN verbraucht genau einen Write und fehlender Marker verhindert POST über mehrere Continuations' -Success (
        $unknown.PublishWriteAttempts -eq 1 -and $unknown.UnconfirmedWrite -and $absent.PublishWriteAttempts -eq 0 -and $stillAbsent.UnconfirmedWrite -and
        $absent.Receipts[0].Status -ceq 'RECOVERY_REQUIRED' -and $fixtureStore.Writes -eq $afterUnknown)
    foreach($item in $committed){$fixtureStore.Issues.Add($item)}
    $reconciled=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments -ContinuationReceipt $unknown
    Add-CheckResult -Name 'UNKNOWN wird nur mit frisch gefundenem exaktem Marker ohne weiteren Write wieder gebunden' -Success (
        -not $reconciled.NotificationFailed -and -not $reconciled.UnconfirmedWrite -and $reconciled.Receipts[0].Status -ceq 'DEDUPLICATED' -and $fixtureStore.Writes -eq $afterUnknown)
    $advancedFixture=$boundedFixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12;$advancedFixture.CheckedAtUtc='2026-02-01T00:00:00Z'
    $advancedEvaluation=Invoke-LabResourceWatchAutomationEvaluation -Check {[pscustomobject]@{Result=$advancedFixture;ExpectedId=$boundedIds}}
    foreach($continuation in @($unknown,$reconciled)){
        $continued=Invoke-LabResourceWatchIssueProjection -Evaluation $advancedEvaluation @boundedArguments -ContinuationReceipt ($continuation | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12)
        Add-CheckResult -Name 'Tatsächliche JSON-Continuation akzeptiert neue Checkzeit bei gleichem Befund und ursprünglicher Bodyintegrität' -Success (
            -not $continued.NotificationFailed -and $continued.Receipts[0].Status -ceq 'DEDUPLICATED' -and $continued.PublishWriteAttempts -eq 0 -and $fixtureStore.Writes -eq $afterUnknown)
    }
    $originalIssue=$fixtureStore.Issues[0];$originalBody=$originalIssue.body
    $payload=$originalBody.Substring($originalBody.IndexOf("`n")+1).Replace('Nur Metadatenvergleich','SYNTHETIC_PRIVATE')
    $bodyHash=Get-LabResourceWatchDigest $payload
    $originalIssue.body=([regex]::Replace($originalBody.Substring(0,$originalBody.IndexOf("`n")),'payload=[A-F0-9]{64}',('payload='+$bodyHash)))+"`n"+$payload
    $noncanonical=Invoke-LabResourceWatchIssueProjection -Evaluation $advancedEvaluation @boundedArguments -ContinuationReceipt $unknown
    Add-CheckResult -Name 'UNKNOWN-Reconciliation lehnt selbstkonsistente fremde Payload trotz gleichem FindingKey ab' -Success (
        $noncanonical.NotificationFailed -and $noncanonical.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID' -and $fixtureStore.Writes -eq $afterUnknown)
    $originalIssue.body=$originalBody
    foreach($invalidTime in @('SYNTHETIC_INVALID_TIME','2026-01-01T00:00:00+05:00')){
        $payload=[regex]::Replace($originalBody.Substring($originalBody.IndexOf("`n")+1),'(?m)^- Geprüft am: [^\r\n]+$',('- Geprüft am: '+$invalidTime))
        $originalIssue.body=([regex]::Replace($originalBody.Substring(0,$originalBody.IndexOf("`n")),'payload=[A-F0-9]{64}',('payload='+(Get-LabResourceWatchDigest $payload))))+"`n"+$payload
        $badTime=Invoke-LabResourceWatchIssueProjection -Evaluation $advancedEvaluation @boundedArguments -ContinuationReceipt $unknown
        Add-CheckResult -Name 'Continuation lehnt ungültige oder nicht kanonische UTC-Zeit trotz repariertem Markerhash vor Write ab' -Success (
            $badTime.NotificationFailed -and $badTime.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID' -and $fixtureStore.Writes -eq $afterUnknown)
    }
    $originalIssue.body=$originalBody
    $changed=Copy-AutomationFixture;$changed.Items[1].ObservedVersion='170.6.1.1';$changedEvaluation=Get-AutomationFixtureEvaluation $changed
    $staleArguments=@{};foreach($key in $boundedArguments.Keys){$staleArguments[$key]=$boundedArguments[$key]};$staleArguments.ExpectedId=@('sql-cu-2022','sqlpackage')
    $staleUnknown=Invoke-LabResourceWatchIssueProjection -Evaluation $changedEvaluation @staleArguments -ContinuationReceipt $unknown
    Add-CheckResult -Name 'Geänderter Befund darf UNKNOWN-Receipt nicht als freie neue Writeauthority übernehmen' -Success (
        $staleUnknown.NotificationFailed -and $staleUnknown.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID' -and $fixtureStore.Writes -eq $afterUnknown)
    $differentArguments=@{};foreach($key in $boundedArguments.Keys){$differentArguments[$key]=$boundedArguments[$key]};$differentArguments.AcceptanceResourceId='sql-cu-2019'
    $unselected=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @differentArguments
    Add-CheckResult -Name 'Vorhandene unselektierte eigene Identität bleibt im vollständigen Budget statt verschwunden zu sein' -Success (
        $unselected.NotificationFailed -and $unselected.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_ACCEPTANCE_LIMIT' -and $fixtureStore.Writes -eq $afterUnknown)
    $fixtureStore.Issues.Clear()
    $globalOwn=Invoke-LabResourceWatchIssueProjection -Evaluation $hardFailure[0] @boundedArguments
    $before=$fixtureStore.Writes
    $recoveryBlocked=Invoke-LabResourceWatchIssueProjection -Evaluation $boundedEvaluation @boundedArguments
    Add-CheckResult -Name 'Globale Watchcheck-Recovery plus neue Ressourcenveröffentlichung überschreitet Identitätsbudget vor jedem Write' -Success (
        $globalOwn.CheckFailed -and $globalOwn.Receipts[0].Status -ceq 'PUBLISHED' -and $recoveryBlocked.NotificationFailed -and
        $recoveryBlocked.Receipts[0].ReasonCode -ceq 'RESOURCE_WATCH_ISSUE_ACCEPTANCE_LIMIT' -and $fixtureStore.Writes -eq $before)
    $fixtureStore.Issues.Clear()
    $none=Copy-AutomationFixture;$none.Status='NO_CHANGE';$none.Items[1].Status='NO_CHANGE';$none.Items[1].ObservedVersion=$none.Items[1].CatalogVersion
    $noneEvaluation=Get-AutomationFixtureEvaluation $none
    $smallArguments=@{};foreach($key in $boundedArguments.Keys){$smallArguments[$key]=$boundedArguments[$key]};$smallArguments.ExpectedId=@('sql-cu-2022','sqlpackage')
    $noNotice=Invoke-LabResourceWatchIssueProjection -Evaluation $noneEvaluation @smallArguments
    Add-CheckResult -Name 'Null Kandidaten ergeben truthful NO_NOTICE_NEEDED ohne erzwungenes Issue' -Success (
        -not $noNotice.NotificationFailed -and $noNotice.Receipts[0].Status -ceq 'NO_NOTICE_NEEDED' -and $noNotice.PublishWriteAttempts -eq 0 -and $fixtureStore.Writes -eq $before)
    $globalOnly=Invoke-LabResourceWatchIssueProjection -Evaluation $hardFailure[0] @smallArguments
    $globalResolved=Invoke-LabResourceWatchIssueProjection -Evaluation $noneEvaluation @smallArguments
    Add-CheckResult -Name 'Globale Recovery bleibt ausführbar als einziger Write wenn ausgewählte Ressource keine Nachricht benötigt' -Success (
        $globalOnly.CheckFailed -and $globalResolved.PublishWriteAttempts -eq 1 -and -not $globalResolved.NotificationFailed -and
        $globalResolved.Receipts.Count -eq 1 -and $globalResolved.Receipts[0].ResourceId -ceq 'watch-check' -and $fixtureStore.Issues[0].state -ceq 'closed')
}finally{
    $fixtureStore.Issues.Clear();foreach($item in $savedIssues){$fixtureStore.Issues.Add($item)}
}
$runnerResult=& {
    $fakeModule=New-Module -ArgumentList $automationFixture -ScriptBlock {
        param($Fixture)
        $script:Fixture=$Fixture
        function Get-LabResourceWatchConfiguration {[pscustomobject]@{CuVersions=@([pscustomobject]@{Version='2022'})}}
        function Invoke-LabResourceWatchRefresh {$script:Fixture}
    }
    function Import-Module {param($Name,[switch]$Force,[switch]$PassThru,$ErrorAction);$fakeModule}
    & (Join-Path $repoRoot 'Tools/Invoke-VersionCatalogResourceWatch.ps1') -AsJson -IssueScope ('own-'+('1'*32)) | ConvertFrom-Json -Depth 12
}
Add-CheckResult -Name 'Echter Automationsrunner erzeugt bereinigtes JSON ohne implizite Issueveröffentlichung' -Success (
    $runnerResult.Evaluation.Status -eq 'NEW' -and $runnerResult.IssueReceipt.Receipts[0].Status -eq 'NOT_EXECUTED' -and
    $runnerResult.IssueReceipt.IssueScope -eq ('own-'+('1'*32)) -and ($runnerResult | ConvertTo-Json -Depth 12) -notmatch 'SYNTHETIC_PRIVATE'
)
$runnerPublishResult=& {
    $fakeModule=New-Module -ArgumentList $automationFixture -ScriptBlock {
        param($Fixture)
        $script:Fixture=$Fixture
        function Get-LabResourceWatchConfiguration {[pscustomobject]@{CuVersions=@([pscustomobject]@{Version='2022'})}}
        function Invoke-LabResourceWatchRefresh {$script:Fixture}
    }
    function Import-Module {param($Name,[switch]$Force,[switch]$PassThru,$ErrorAction);$fakeModule}
    # Execute the complete real runner; replace only its source-reader module and API transport.
    $runnerTools=Join-Path $repoRoot 'Tools'
    $runnerCode=(Get-Content (Join-Path $runnerTools 'Invoke-VersionCatalogResourceWatch.ps1') -Raw).Replace('$PSScriptRoot','$runnerTools')
    $loader=". (Join-Path `$runnerTools 'Common/VersionCatalogResourceWatchAutomation.ps1')"
    $runnerCode=$runnerCode.Replace($loader,($loader+"`nfunction Invoke-LabResourceWatchGitHubApi {param(`$Method,`$Path,`$Body,`$Clock); & `$fixtureApi `$Method `$Path `$Body}"))
    & ([scriptblock]::Create($runnerCode)) -PublishIssues -WhatIf -AsJson -IssueScope ('own-'+('e'*32)) -AcceptanceResourceId sqlpackage | ConvertFrom-Json -Depth 12
}
Add-CheckResult -Name 'Tatsächlicher Runner bindet Own-Auswahl an Konfiguration und Git-Head bevor synthetische Issuevorschau' -Success (
    $runnerPublishResult.Evaluation.Findings.Count -eq 2 -and $runnerPublishResult.IssueReceipt.AcceptanceResourceId -ceq 'sqlpackage' -and
    $runnerPublishResult.IssueReceipt.PublicationHead -cmatch '^[a-f0-9]{40}$' -and $runnerPublishResult.IssueReceipt.PublishWriteAttempts -eq 0 -and
    $runnerPublishResult.IssueReceipt.Receipts[0].Status -ceq 'NOT_EXECUTED')
$runnerContinuationResult=& {
    $fakeModule=New-Module -ArgumentList (Copy-AutomationFixture) -ScriptBlock {
        param($Fixture)
        $script:Fixture=$Fixture
        function Get-LabResourceWatchConfiguration {[pscustomobject]@{CuVersions=@([pscustomobject]@{Version='2022'})}}
        function Invoke-LabResourceWatchRefresh {$script:Fixture}
    }
    function Import-Module {param($Name,[switch]$Force,[switch]$PassThru,$ErrorAction);$fakeModule}
    $runnerTools=Join-Path $repoRoot 'Tools'
    $runnerCode=(Get-Content (Join-Path $runnerTools 'Invoke-VersionCatalogResourceWatch.ps1') -Raw).Replace('$PSScriptRoot','$runnerTools')
    $loader=". (Join-Path `$runnerTools 'Common/VersionCatalogResourceWatchAutomation.ps1')"
    $runnerCode=$runnerCode.Replace($loader,($loader+"`nfunction Invoke-LabResourceWatchGitHubApi {param(`$Method,`$Path,`$Body,`$Clock); & `$fixtureApi `$Method `$Path `$Body}"))
    $runnerScript=[scriptblock]::Create($runnerCode)
    $scope='own-'+('f'*32);$before=$fixtureStore.Writes
    $directory=Join-Path (Join-Path $repoRoot '.artifacts/test-runs') ('resourceWatchContinuation-'+[guid]::NewGuid().ToString('N'))
    $receiptPath=Join-Path $directory 'receipt.json'
    try{
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
        $initial=& $runnerScript -PublishIssues -AsJson -IssueScope $scope -AcceptanceResourceId sqlpackage | ConvertFrom-Json -Depth 12
        $initial.IssueReceipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        & $fakeModule {$script:Fixture.CheckedAtUtc='2026-02-01T00:00:00Z'}
        $next=& $runnerScript -PublishIssues -AsJson -IssueScope $scope -AcceptanceResourceId sqlpackage -ContinuationReceiptPath $receiptPath | ConvertFrom-Json -Depth 12
        [pscustomobject]@{Initial=$initial;Continued=$next;Writes=($fixtureStore.Writes-$before)}
    }finally{
        if(Test-Path -LiteralPath $receiptPath){Remove-Item -LiteralPath $receiptPath -ErrorAction Stop}
        if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -ErrorAction Stop}
    }
}
Add-CheckResult -Name 'Tatsächlicher ganzer Runner nimmt JSON-Receiptdatei bei frischer Checkzeit ohne zweiten Write wieder auf' -Success (
    $runnerContinuationResult.Initial.IssueReceipt.Receipts[0].Status -ceq 'PUBLISHED' -and
    $runnerContinuationResult.Continued.IssueReceipt.Receipts[0].Status -ceq 'DEDUPLICATED' -and
    -not $runnerContinuationResult.Continued.IssueReceipt.NotificationFailed -and $runnerContinuationResult.Writes -eq 1 -and
    $runnerContinuationResult.Initial.Evaluation.CheckedAtUtc -cne $runnerContinuationResult.Continued.Evaluation.CheckedAtUtc)
$workflow=Get-Content (Join-Path $repoRoot '.github/workflows/sql-cu-monthly-monitor.yml') -Raw
Add-CheckResult -Name 'Automationsausbau erhält einzigen Monatscron, Serialisierung und Repo-Issuekanal' -Success (
    $workflow.Contains("cron: '0 6 1 * *'") -and $workflow.Contains('group: sql-server-lab-cu-monthly-watch') -and
    $workflow.Contains('cancel-in-progress: false') -and $workflow.Contains('issues: write') -and $workflow.Contains("github.repository == 'gecompat/SQL_Server_Lab'") -and
    $workflow -notmatch 'Register-ScheduledTask|Start-SqlServerLabScheduler|gh issue comment'
)
$stepMatch=[regex]::Match($workflow,'(?ms)      - name: Run resource metadata check and issue projection.*?        run: \|\r?\n(?<code>.*?)(?=\r?\n      - name:)')
$stepCode=$stepMatch.Groups['code'].Value -replace '(?m)^          ',''
$stepCode=$stepCode.Replace('& ./Tools/Invoke-VersionCatalogResourceWatch.ps1 @arguments','$fixtureResult')
$workflowRoot=Join-Path (Join-Path $repoRoot '.artifacts/test-runs') ('resourceWatchWorkflow-'+[guid]::NewGuid().ToString('N'))
$previousEnvironment=@{}
foreach($name in @('RUNNER_TEMP','GITHUB_OUTPUT','GITHUB_STEP_SUMMARY','GITHUB_EVENT_NAME','RESOURCE_WATCH_FIXTURE_SCOPE','RESOURCE_WATCH_FIXTURE_RESOURCE')){$previousEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
    New-Item -ItemType Directory -Path $workflowRoot -ErrorAction Stop | Out-Null
    $env:RUNNER_TEMP=$workflowRoot;$env:GITHUB_OUTPUT=Join-Path $workflowRoot 'output.txt';$env:GITHUB_STEP_SUMMARY=Join-Path $workflowRoot 'summary.md'
    $env:GITHUB_EVENT_NAME='workflow_dispatch';$env:RESOURCE_WATCH_FIXTURE_SCOPE=$ownScope;$env:RESOURCE_WATCH_FIXTURE_RESOURCE='sqlpackage'
    $fixtureResult=[pscustomobject]@{Evaluation=$unclear;IssueReceipt=$unclearReceipt}
    . ([scriptblock]::Create($stepCode))
    $outputs=Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
    $savedReceipt=Get-Content -LiteralPath (Join-Path $workflowRoot 'sql-cu-watch-receipt.json') -Raw | ConvertFrom-Json -Depth 12
    Add-CheckResult -Name 'Echte Workflow-PowerShell publiziert nur Report/Receipt und getrennte rote Check-/Noticeoutputs' -Success (
        $stepMatch.Success -and $outputs.Contains('check_failed=true') -and $outputs.Contains('notification_failed=false') -and $savedReceipt.CheckFailed -and
        (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw) -notmatch 'SYNTHETIC_PRIVATE' -and $arguments.IssueScope -ceq $ownScope -and $arguments.AcceptanceResourceId -ceq 'sqlpackage'
    )
    foreach($case in @('schedule','invalid')){
        $env:GITHUB_EVENT_NAME=if($case -eq 'schedule'){'schedule'}else{'workflow_dispatch'}
        $env:RESOURCE_WATCH_FIXTURE_SCOPE=if($case -eq 'schedule'){$ownScope}else{'SYNTHETIC_PRIVATE'}
        $caught='';try{. ([scriptblock]::Create($stepCode))}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'Scheduler verwendet keine Fixture ohne gültigen expliziten Dispatchscope' -Success ($caught -eq 'RESOURCE_WATCH_FIXTURE_SCOPE_INVALID')
    }
    foreach($case in @('missing','unknown-format','regular-with-selector')){
        $env:GITHUB_EVENT_NAME='workflow_dispatch';$env:RESOURCE_WATCH_FIXTURE_SCOPE=$ownScope
        $env:RESOURCE_WATCH_FIXTURE_RESOURCE=if($case -ceq 'missing'){''}else{'SYNTHETIC_PRIVATE'}
        if($case -ceq 'regular-with-selector'){$env:RESOURCE_WATCH_FIXTURE_SCOPE='';$env:RESOURCE_WATCH_FIXTURE_RESOURCE='sqlpackage'}
        $caught='';try{. ([scriptblock]::Create($stepCode))}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name ('Tatsächlicher Dispatchblock lehnt fehlende/fremde Auswahl ab: '+$case) -Success ($caught -ceq 'RESOURCE_WATCH_FIXTURE_RESOURCE_INVALID')
    }
}finally{
    foreach($name in $previousEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$previousEnvironment[$name])}
    foreach($leaf in @('output.txt','summary.md','sql-cu-watch-summary.md','sql-cu-watch-receipt.json')){
        $path=Join-Path $workflowRoot $leaf;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction Stop}
    }
    if(Test-Path -LiteralPath $workflowRoot){Remove-Item -LiteralPath $workflowRoot -ErrorAction Stop}
}

foreach($path in @('https://unapproved.invalid','repos/other/fixture/issues','repos/gecompat/SQL_Server_Lab/issues/1?token=value','repos/gecompat/SQL_Server_Lab/issues/../labels')){
    $caught='';try{Get-LabResourceWatchGitHubUri $path | Out-Null}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'Issue-Transport erlaubt ausschließlich festen Repo-Issuepfad' -Success ($caught -eq 'RESOURCE_WATCH_ISSUE_TARGET_INVALID')
}
# Execute the real streaming adapter; only its exact URI resolver is replaced inside this child scope.
$apiTransportChecks=& {
    . (Join-Path $repoRoot 'Tools/Common/VersionCatalogResourceWatchAutomation.ps1')
    $checks=[Collections.Generic.List[object]]::new();$requests=[Collections.Concurrent.ConcurrentBag[string]]::new()
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$server=[powershell]::Create()
    $previousToken=$env:GH_TOKEN
    try{
        $env:GH_TOKEN='SYNTHETIC_RESOURCE_WATCH_TOKEN';$listener.Start();$localPort=$listener.LocalEndpoint.Port
        function Get-LabResourceWatchGitHubUri {param($Path);'http://127.0.0.1:'+$localPort+'/'+$scenario}
        $null=$server.AddScript({param($Listener,$Requests)
            while($true){
                if(-not $Listener.Pending()){Start-Sleep -Milliseconds 5;continue}
                $client=$Listener.AcceptTcpClient()
                try{
                    $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream);$line=$reader.ReadLine();$path=($line -split ' ')[1];$auth=$false
                    while($header=$reader.ReadLine()){if($header -ceq 'Authorization: Bearer SYNTHETIC_RESOURCE_WATCH_TOKEN'){$auth=$true}}
                    $Requests.Add($path+'|'+$auth)
                    $status=if($path -match '^/(301|302|303|307|308|429|500)$'){$Matches[1]}else{'200'}
                    $body='{"id":1}';$headers=''
                    if($status -like '3*'){$headers="Location: /redirect-target`r`n"}
                    if($path -in @('/large','/stream-large')){$body='x'*1048577}
                    if($path -eq '/invalid'){$body='SYNTHETIC_PRIVATE_API_RESPONSE'}
                    if($path -eq '/encoded'){$headers="Content-Encoding: gzip`r`n"}
                    if($path -eq '/slow'){Start-Sleep -Milliseconds 200}
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $length=if($path -eq '/stream-large'){''}else{"Content-Length: $($bytes.Length)`r`n"}
                    $head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Fixture`r`n${headers}${length}Connection: close`r`n`r`n")
                    $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length)
                }catch{}finally{$client.Dispose()}
            }
        }).AddArgument($listener).AddArgument($requests)
        $running=$server.BeginInvoke()
        $scenario='ok';$reply=Invoke-LabResourceWatchGitHubApi -Method GET -Path 'repos/gecompat/SQL_Server_Lab/issues/1' -Clock ([Diagnostics.Stopwatch]::StartNew())
        $checks.Add([pscustomobject]@{Name='Echter Issue-HTTP-Reader liest JSON mit ausschließlich synthetischem Bearertoken';Success=($reply.Data.id -eq 1 -and $requests.Contains('/ok|True'))})
        foreach($scenario in @('301','302','303','307','308','429','500','large','stream-large','invalid','encoded','slow')){
            $code='';$budget=if($scenario -eq 'slow'){30}else{1000}
            try{Invoke-LabResourceWatchGitHubApi -Method GET -Path 'repos/gecompat/SQL_Server_Lab/issues/1' -Clock ([Diagnostics.Stopwatch]::StartNew()) -TimeoutMilliseconds $budget | Out-Null}catch{$code=$_.Exception.Message}
            $expected=switch($scenario){
                {$_ -in @('301','302','303','307','308')} {'RESOURCE_WATCH_ISSUE_REDIRECT_REJECTED'}
                {$_ -in @('429','500')} {'RESOURCE_WATCH_ISSUE_HTTP_ERROR'}
                {$_ -in @('large','stream-large','encoded')} {'RESOURCE_WATCH_ISSUE_RESPONSE_INVALID'}
                'invalid' {'RESOURCE_WATCH_ISSUE_REQUEST_FAILED'}
                'slow' {'RESOURCE_WATCH_ISSUE_TIMEOUT'}
            }
            $checks.Add([pscustomobject]@{Name=('Echter begrenzter Issue-Transport bewahrt Fehlerwahrheit: '+$scenario);Success=($code -ceq $expected)})
        }
        $checks.Add([pscustomobject]@{Name='Issue-Redirectfixture erhält keine Folgeanfrage';Success=(@($requests | Where-Object {$_ -like '/redirect-target*'}).Count -eq 0)})
    }finally{
        $env:GH_TOKEN=$previousToken;$listener.Stop();if($server.InvocationStateInfo.State -eq 'Running'){$server.Stop()};$server.Dispose()
    }
    $checks
}
foreach($check in $apiTransportChecks){Add-CheckResult -Name $check.Name -Success $check.Success}
