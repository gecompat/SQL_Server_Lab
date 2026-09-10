#Requires -Version 7.2
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Ausschliesslich synthetisches Secret innerhalb der isolierten Offline-Fixture.')]
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../../SqlServerLab.psd1') -Force -PassThru
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-package-recovery-'+[guid]::NewGuid().ToString('N'))
try {
    $null=New-Item -ItemType Directory -Path $fixtureRoot
    & $module {
        param($Root)
        $script:packageState='ONLINE'
        $script:packageAccess='MULTI_USER'
        $script:packageGuid='11111111-1111-4111-8111-111111111111'
        $script:packageCopyMode='fail';$script:packageRestoreFails=$false;$script:packageMutations=0;$script:packagePublications=0
        $script:packageContext=[pscustomobject]@{
            RunId='22222222-2222-4222-8222-222222222222';Run=@{scopeId='33333333-3333-4333-8333-333333333333'}
            InstanceId='primary';Provider='docker';WasRunning=$true;RunDirectory=$Root;StateRoot=$Root
            ContainerId=('a'*64);ContainerName='synthetic';CurrentPort=1433;Instance=@{host='127.0.0.1'}
        }
        function Get-LabContainerReconcileContext {$script:packageContext}
        function Get-LabSecret {ConvertTo-SecureString 'Synthetic-Only!123' -AsPlainText -Force}
        function Get-LabHostToolInvocation {'synthetic-runtime'}
        function Get-LabDatabaseMigrationDependencyInventory {$null}
        $originalCleanup=(Get-Command Remove-LabContainerPackageExportPayload).ScriptBlock
        $originalJournalWriter=(Get-Command Write-LabContainerPackageExportJournal).ScriptBlock
        function Remove-LabContainerPackageExportPayload {
            param($RunDirectory,$Path)
            if($script:packageCleanupFails){throw 'SYNTHETIC_CLEANUP_FAILURE'}
            & $originalCleanup @PSBoundParameters
        }
        function Write-LabContainerPackageExportJournal {
            param($Journal,$Path)
            if($script:packageJournalFails -and $Journal.Status -in @('ROLLED_BACK','RECOVERY_REQUIRED')){throw 'SYNTHETIC_JOURNAL_FAILURE'}
            & $originalJournalWriter @PSBoundParameters
        }
        function Invoke-SqlQuery {
            param($Query)
            if($Query -match 'PKG_META'){
                if($script:packageFileDrift -and $script:packageState -eq 'OFFLINE'){return @('PKG_META|17|0|0','PKG_FILE|ROWS|ChangedData|/var/opt/mssql/data/changed.mdf')}
                return @('PKG_META|17|0|0','PKG_FILE|ROWS|SyntheticData|/var/opt/mssql/data/synthetic.mdf',"PKG_STATE|$($script:packageGuid)|$($script:packageState)|$($script:packageAccess)")
            }
            if($Query -match 'ALTER DATABASE'){
                $script:packageMutations++
                if($Query -match 'SET ONLINE' -and $script:packageRestoreFails){throw 'SYNTHETIC_SOURCE_NOT_REACHABLE'}
                if($Query -match 'SET SINGLE_USER'){$script:packageAccess='SINGLE_USER'}
                if($script:packageOfflineFails -and $Query -match 'SET OFFLINE'){throw 'CONTAINER_DATABASE_PACKAGE_SYNTHETIC_OFFLINE_FAILED'}
                if($Query -match 'SET OFFLINE'){$script:packageState='OFFLINE'}
                if($Query -match 'SET ONLINE'){$script:packageState='ONLINE'}
                if($Query -match 'SET MULTI_USER'){$script:packageAccess='MULTI_USER'}
                if($Query -match 'SET RESTRICTED_USER'){$script:packageAccess='RESTRICTED_USER'}
                return
            }
            if($Query -match 'PKG_STATE'){
                $observedGuid=if($script:packageState -eq 'ONLINE'){$script:packageGuid}else{''}
                $fingerprint=if($script:packageGuid -eq '11111111-1111-4111-8111-111111111111'){'a'*64}else{'b'*64}
                return @("PKG_STATE|$observedGuid|$($script:packageState)|$($script:packageAccess)","PKG_CATALOG|1|$fingerprint")
            }
            if($Query -match 'state_desc'){return $script:packageState}
            throw 'UNEXPECTED_SYNTHETIC_SQL_QUERY'
        }
        function Invoke-LabProgressNativeCommand {
            param($ArgumentList)
            if($ArgumentList[1] -cnotlike "$($script:packageContext.ContainerId):/*"){throw 'COPY_NOT_BOUND_TO_EXACT_CONTAINER_ID'}
            $journals=@(Get-ChildItem -LiteralPath $script:packageContext.RunDirectory -Recurse -Filter source-journal.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
            if(@($journals | Where-Object Status -eq 'COPYING').Count -ne 1){throw 'COPY_WITHOUT_DURABLE_SOURCE_JOURNAL'}
            if($script:packageCopyMode -eq 'container-changed'){$script:packageContext.ContainerId='b'*64}
            if($script:packageCopyMode -eq 'database-changed'){$script:packageGuid='44444444-4444-4444-8444-444444444444'}
            if($script:packageCopyMode -eq 'success'){
                Set-Content -LiteralPath $ArgumentList[2] -Value 'synthetic-payload'
                return [pscustomobject]@{ExitCode=0;Output=@()}
            }
            [pscustomobject]@{ExitCode=1;Output=@()}
        }
        function New-LabDatabasePackage {
            $script:packagePublications++
            if($script:packagePublishFails){throw 'DATABASE_PACKAGE_SYNTHETIC_LIBRARY_FAILURE'}
            [pscustomobject]@{Status='REUSABLE';DatabasePackageId='55555555-5555-4555-8555-555555555555';PersistentStorageId='66666666-6666-4666-8666-666666666666'}
        }
        function Get-LabDatabasePackage {
            [pscustomobject]@{Record=[pscustomobject]@{DatabaseName='Synthetic';Source=[pscustomobject]@{RunId=$script:packageContext.RunId;InstanceId='primary';Provider='docker'}}}
        }
        function Register-LabDatabasePackagePersistentStorage {
            param([switch]$Preview)
            if(-not $Preview){throw 'PUBLISHED_RESUME_ATTEMPTED_CATALOG_MUTATION'}
            [pscustomobject]@{Changed=$script:packagePublishedBindingChanged;Store=[pscustomobject]@{PersistentStorageId='66666666-6666-4666-8666-666666666666'}}
        }
        function Assert-Recovery {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
        function Get-FixtureJournals {@(Get-ChildItem -LiteralPath $script:packageContext.RunDirectory -Recurse -Filter source-journal.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})}
        function Reset-PackageFixture {
            param([string]$Name)
            $script:packageContext.RunDirectory=Join-Path $Root $Name
            $null=New-Item -ItemType Directory -Path $script:packageContext.RunDirectory
            $script:packageContext.ContainerId='a'*64
            $script:packageState='ONLINE';$script:packageAccess='MULTI_USER'
            $script:packageGuid='11111111-1111-4111-8111-111111111111'
            $script:packageCopyMode='fail';$script:packageRestoreFails=$false;$script:packagePublishFails=$false
            $script:packageMutations=0;$script:packagePublications=0
            $script:packageCleanupFails=$false;$script:packageJournalFails=$false;$script:packageFileDrift=$false;$script:packageOfflineFails=$false
            $script:packagePublishedBindingChanged=$false
        }
        function Invoke-FixtureExport {Export-LabContainerDatabasePackage -RunId $script:packageContext.RunId -InstanceId primary -DatabaseName Synthetic -DataRoot $Root -StateRoot $Root}
        Reset-PackageFixture competingWriter
        $material=[Text.Encoding]::UTF8.GetBytes("docker|$('a'*64)|SYNTHETIC")
        $mutexName=$(if($IsWindows){'Global\'})+'SQL_Server_Lab_Package_Export_'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material))
        $ready=[Threading.ManualResetEventSlim]::new($false)
        $release=[Threading.ManualResetEventSlim]::new($false)
        $owner=[powershell]::Create()
        try {
            $null=$owner.AddScript({param($Name,$Ready,$Release)
                $lock=[Threading.Mutex]::new($false,$Name);$held=$false
                try {$held=$lock.WaitOne(0);if(-not $held){throw 'SYNTHETIC_LOCK_COLLISION'};$Ready.Set();$null=$Release.Wait(45000)}
                finally {if($held){$lock.ReleaseMutex()};$lock.Dispose()}
            }).AddArgument($mutexName).AddArgument($ready).AddArgument($release)
            $pending=$owner.BeginInvoke()
            if(-not $ready.Wait(5000)){throw 'SYNTHETIC_LOCK_OWNER_NOT_READY'}
            $blocked=$false
            try{$null=Invoke-FixtureExport}catch{$blocked=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_EXPORT_LOCK_TIMEOUT'}
            Assert-Recovery ($blocked -and $script:packageMutations -eq 0 -and @(Get-FixtureJournals).Count -eq 0) 'Konkurrierender Export blockiert vor Journal- und SQL-Mutation'
        }
        finally {$release.Set();if($pending){$null=$owner.EndInvoke($pending)};$owner.Dispose();$ready.Dispose();$release.Dispose()}

        Reset-PackageFixture initial
        $failed=$false
        try{$null=Export-LabContainerDatabasePackage -RunId $script:packageContext.RunId -InstanceId primary -DatabaseName Synthetic -DataRoot $Root -StateRoot $Root}
        catch{$failed=$_.Exception.Message -match 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED'}
        if(-not $failed){throw 'FAIL: Der kontrollierte Kopierfehler muss erhalten bleiben'}
        if($script:packageState -ne 'ONLINE' -or $script:packageAccess -ne 'MULTI_USER'){throw 'FAIL: Kopierfehler hinterlaesst die zuvor aktive Quelle offline oder exklusiv'}
        Write-Host 'PASS: Kopierfehler stellt den vorherigen SQL-Zustand wieder her'
        $journal=@(Get-FixtureJournals)[0]
        Assert-Recovery ($journal.Status -eq 'ROLLED_BACK' -and $journal.SourceRecovery -eq 'RESTORED' -and $journal.FailureCode -eq 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED') 'Fehler und erfolgreiche Quellwiederherstellung sind getrennt journalisiert'
        $journalText=$journal | ConvertTo-Json -Depth 12
        Assert-Recovery ($journalText -notmatch 'Synthetic-Only|127\.0\.0\.1|Password|Credential' -and $journalText -notmatch [regex]::Escape($Root)) 'Quelljournal enthaelt keine Secrets, Endpunkte oder Hostpfade'
        Assert-Recovery (@(Get-ChildItem -LiteralPath $script:packageContext.RunDirectory -Recurse -Directory -Filter payload).Count -eq 0) 'Unvollstaendiger Payload ist nach Kopierfehler bereinigt'

        Reset-PackageFixture partialSql
        $script:packageOfflineFails=$true;$failed=$false
        try{$null=Invoke-FixtureExport}catch{$failed=$_.Exception.Message -match 'SYNTHETIC_OFFLINE_FAILED'}
        Assert-Recovery ($failed -and $script:packageState -eq 'ONLINE' -and $script:packageAccess -eq 'MULTI_USER') 'Teilweise fehlgeschlagenes Offline-Statement stellt den Zugriffsmodus wieder her'

        Reset-PackageFixture fileDrift
        $script:packageFileDrift=$true;$failed=$false
        try{$null=Invoke-FixtureExport}catch{$failed=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_FILE_INVENTORY_CHANGED'}
        Assert-Recovery ($failed -and $script:packageState -eq 'ONLINE' -and $script:packagePublications -eq 0) 'Dateiinventarwechsel wird vor Kopie erkannt und zurueckgerollt'

        Reset-PackageFixture cleanup
        $script:packageCleanupFails=$true;$failed=$false
        try{$null=Invoke-FixtureExport -WarningAction SilentlyContinue}catch{$failed=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED'}
        Assert-Recovery ($failed -and @(Get-FixtureJournals)[0].CleanupState -eq 'FAILED') 'Cleanup-Fehler verdeckt den Kopierfehler nicht und bleibt journalisiert'
        $script:packageCleanupFails=$false;$script:packageCopyMode='success'
        $null=Invoke-FixtureExport
        Assert-Recovery (@(Get-FixtureJournals | Where-Object CleanupState -ne 'CLEANED').Count -eq 0 -and @(Get-ChildItem -LiteralPath $script:packageContext.RunDirectory -Recurse -Directory -Filter payload).Count -eq 0) 'Wiederholung bereinigt den vorherigen Payload vor neuem Export'

        Reset-PackageFixture publishedCleanup
        $script:packageCopyMode='success';$script:packageCleanupFails=$true;$failed=$false
        try{$null=Invoke-FixtureExport}catch{$failed=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_PAYLOAD_CLEANUP_FAILED'}
        Assert-Recovery ($failed -and $script:packagePublications -eq 1 -and @(Get-FixtureJournals)[0].PublishedResult.DatabasePackageId) 'Cleanup-Fehler nach Publikation behaelt stabile Ergebnis-IDs im Journal'
        $script:packageCleanupFails=$false
        $script:packagePublishedBindingChanged=$true;$blocked=$false
        try{$null=Invoke-FixtureExport}catch{$blocked=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_PUBLISHED_BINDING_CHANGED'}
        Assert-Recovery ($blocked -and $script:packagePublications -eq 1 -and @(Get-FixtureJournals)[0].Status -eq 'RECOVERY_REQUIRED') 'Veraenderte Bibliotheksbindung blockiert Cleanup-Resume dauerhaft vor einer neuen Publikation'
        $script:packagePublishedBindingChanged=$false
        $resumed=Invoke-FixtureExport
        Assert-Recovery ($resumed.Status -eq 'REUSABLE' -and $script:packagePublications -eq 1 -and $script:packageMutations -eq 1) 'Cleanup-Resume liefert das vorhandene Paket nach Revalidierung ohne erneute Publikation oder SQL-Mutation'

        Reset-PackageFixture journalFailure
        $script:packageJournalFails=$true;$failed=$false
        try{$null=Invoke-FixtureExport -WarningAction SilentlyContinue}catch{$failed=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED'}
        Assert-Recovery ($failed -and $script:packageState -eq 'ONLINE' -and @(Get-FixtureJournals)[0].Status -eq 'COPYING') 'Nicht schreibbares Recovery-Journal erhaelt den Originalfehler und den letzten dauerhaften Status'

        Reset-PackageFixture offline
        $script:packageState='OFFLINE';$script:packageAccess='SINGLE_USER'
        try{$null=Invoke-FixtureExport}catch{if($_.Exception.Message -notmatch 'COPY_FAILED'){throw}}
        Assert-Recovery ($script:packageState -eq 'OFFLINE' -and $script:packageAccess -eq 'SINGLE_USER' -and $script:packageMutations -eq 1) 'Bereits offline vorgefundene Quelle wird bei Fehler nicht online geschaltet'

        Reset-PackageFixture restricted
        $script:packageAccess='RESTRICTED_USER'
        try{$null=Invoke-FixtureExport}catch{if($_.Exception.Message -notmatch 'COPY_FAILED'){throw}}
        Assert-Recovery ($script:packageState -eq 'ONLINE' -and $script:packageAccess -eq 'RESTRICTED_USER') 'Vorheriger eingeschraenkter Zugriffsmodus bleibt erhalten'

        foreach($changed in @('container-changed','database-changed')){
            Reset-PackageFixture $changed
            $script:packageCopyMode=$changed
            try{$null=Invoke-FixtureExport}catch{if($_.Exception.Message -notmatch 'COPY_FAILED'){throw}}
            Assert-Recovery ($script:packageState -eq 'OFFLINE' -and $script:packageMutations -eq 1 -and @(Get-FixtureJournals)[0].Status -eq 'RECOVERY_REQUIRED') "Identitaetswechsel verhindert Quellmutation durch Recovery: $changed"
            $blocked=$false
            try{$null=Invoke-FixtureExport}catch{$blocked=$_.Exception.Message -match 'RECOVERY_(BINDING|DATABASE)_CHANGED'}
            Assert-Recovery ($blocked -and $script:packageMutations -eq 1) "Wiederholung blockiert vor Mutation bei Identitaetswechsel: $changed"
        }

        Reset-PackageFixture resume
        $script:packageRestoreFails=$true
        try{$null=Invoke-FixtureExport}catch{if($_.Exception.Message -notmatch 'COPY_FAILED'){throw}}
        Assert-Recovery (@(Get-FixtureJournals)[0].Status -eq 'RECOVERY_REQUIRED') 'Fehlgeschlagene Quellwiederherstellung bleibt recoverbar'
        $script:packageRestoreFails=$false;$script:packageCopyMode='success'
        $result=Invoke-FixtureExport
        $resumeJournals=@(Get-FixtureJournals)
        Assert-Recovery ($result.Status -eq 'REUSABLE' -and @($resumeJournals | Where-Object Status -eq 'ROLLED_BACK').Count -eq 1 -and @($resumeJournals | Where-Object Status -eq 'COMPLETED').Count -eq 1 -and $script:packagePublications -eq 1) 'Wiederholung schliesst zuerst die offene Quell-Recovery ab und publiziert genau ein Paket'
        Assert-Recovery ($script:packageState -eq 'OFFLINE' -and $script:packageAccess -eq 'SINGLE_USER') 'Erfolgreicher Export behaelt seinen bestehenden Offline-Vertrag'

        Reset-PackageFixture library
        $script:packageCopyMode='success';$script:packagePublishFails=$true
        try{$null=Invoke-FixtureExport}catch{if($_.Exception.Message -notmatch 'SYNTHETIC_LIBRARY_FAILURE'){throw}}
        Assert-Recovery ($script:packageState -eq 'OFFLINE' -and @(Get-FixtureJournals)[0].SourceRecovery -eq 'PRESERVE_OFFLINE') 'Bibliotheksfehler behaelt die separat vorgeschriebene Offline-Recovery'
        $mutations=$script:packageMutations;$blocked=$false
        try{$null=Invoke-FixtureExport}catch{$blocked=$_.Exception.Message -eq 'CONTAINER_DATABASE_PACKAGE_LIBRARY_RECOVERY_REQUIRED'}
        Assert-Recovery ($blocked -and $script:packageMutations -eq $mutations -and $script:packagePublications -eq 1) 'Offene Bibliotheks-Recovery wird nicht durch erneuten Export oder Online-Schalten umgangen'
    } $fixtureRoot
}
finally {
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-package-recovery-*'){throw 'PACKAGE_RECOVERY_FIXTURE_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
