#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-target-' + [guid]::NewGuid().ToString('N'))
$module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
try {
    & $module {
        param($Root, $Repo)
        . (Join-Path $Repo 'Tests/Common/CheckResult.ps1')
        $script:passed = 0
        $script:failures = [Collections.Generic.List[string]]::new()
        function Write-TlsTargetFixture { param($Path, $Value)
            $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
            $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding utf8
        }
        function Reset-TlsTargetFixture { param([string]$Provider = 'docker', [string]$Version = '2025', [string]$HostName = '127.0.0.1', [string]$Kind = 'IP')
            $script:dataRoot = Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $instance = [pscustomobject]@{ id='primary'; provider=$Provider; version=$Version; profile='standard'; autostart='manual'; drives=@(); databases=@(); software=@() }
            $desired = New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{ name='Synthetic TLS target'; instances=@($instance) }) -ProvisioningMode adhoc -PersistentData $true
            $script:run = New-LabRunState -StateRoot (Join-Path $script:dataRoot 'State') -Metadata @{
                desiredState=$desired; persistentData=$true; dataRoot=$script:dataRoot
            } -ProviderSubRuns @([pscustomobject]@{ provider=$Provider; instanceIds=@('primary') })
            $script:statePath = Join-Path $script:run.RunDir 'run-state.json'
            $script:state = Get-LabRunState -RunId $script:run.RunId -StateRoot $script:run.StateRoot
            $script:state.state = 'RUNNING'; $script:state.providerSubRuns[0].state = 'RUNNING'
            $script:state.instances = @([pscustomobject]@{ id='primary'; provider=$Provider; version=$Version; containerId=('a'*64); host=$HostName; port=15333; ignored='TLS_PRIVATE_CANARY' })
            $controller = [guid]::NewGuid().ToString('D')
            $script:marker = [pscustomobject]@{ ContractVersion='SqlServerLab.DataRoot/2.0'; ManagedBy='SQL_Server_Lab'; ControllerId=$controller; VolumeId='synthetic-volume'; DataRoot=$script:dataRoot }
            $script:catalog = [pscustomobject]@{ ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=$controller; LabDataLocations=@(
                [pscustomobject]@{ LocationId=[guid]::NewGuid().ToString('D'); ControllerId=$controller; LabDataRoot=$script:dataRoot; VolumeId='synthetic-volume' }) }
            $script:scopePath = Join-Path (Join-Path $script:run.StateRoot 'scope-markers') ($script:run.ScopeId+'.json')
            $script:scope = Get-Content -LiteralPath $script:scopePath -Raw | ConvertFrom-Json
            $script:request = [pscustomobject]@{
                ContractVersion='SqlServerLab.AuthenticatedTlsRequest/0.1'; RequestId='11111111-1111-1111-1111-111111111111'
                AuthorityRef='22222222-2222-2222-2222-222222222222'; Kind='LEAF_PROFILE'; TargetRef=$script:run.RunId
                Provider=$Provider; SqlVersion=$Version; Port=15333; Identity=[pscustomobject]@{ Kind=$Kind; Value=$HostName }
                Profile=[pscustomobject]@{ Algorithm='RSA'; RsaBits=3072; Signature='SHA256'; ValidityDays=30; RenewBeforeDays=7 }
            }
            Save-TlsTargetFixture
        }
        function Save-TlsTargetFixture {
            Write-TlsTargetFixture $script:statePath $script:state
            Write-TlsTargetFixture (Join-Path $script:dataRoot '.sql-server-lab-root.json') $script:marker
            Write-TlsTargetFixture (Join-Path $script:dataRoot 'Catalog/storage-locations.json') $script:catalog
            Write-TlsTargetFixture $script:scopePath $script:scope
        }
        function Invoke-TlsTargetFixture {
            & { Set-StrictMode -Version Latest; Get-LabAuthenticatedTlsTargetMetadata -Request $script:request -InstanceId primary -DataRoot $script:dataRoot }
        }
        function Assert-TlsTargetRejected { param([string]$Name, $Result)
            Add-CheckResult $Name ($null -ne $Result -and $Result.Success -eq $false -and $null -eq $Result.Value -and
                $Result.ErrorCode -cmatch '\ATLS_TARGET_[A-Z_]+\z' -and @($Result.PSObject.Properties).Count -eq 3)
            Add-CheckResult "$Name ohne Rohwerte" (($Result | ConvertTo-Json -Compress) -notmatch 'TLS_PRIVATE_CANARY|synthetic-volume|sql-lab-tls-target')
        }
        function Get-TlsTargetSnapshot {
            (@(Get-ChildItem -LiteralPath $script:dataRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
                [IO.Path]::GetRelativePath($script:dataRoot,$_.FullName)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
            }) -join '|')
        }
        # Der Produktpfad darf keine Provider-/Secret-/SQL-Probe erreichen.
        function Get-LabHostToolInvocation { throw 'TLS_PRIVATE_CANARY forbidden tool' }
        function Get-LabSecret { throw 'TLS_PRIVATE_CANARY forbidden secret' }
        function Get-LabContainerRuntimeScopeEvidence { throw 'TLS_PRIVATE_CANARY forbidden runtime' }
        foreach ($provider in @('docker','podman')) {
            foreach ($version in @('2019','2022','2025')) {
                foreach ($endpoint in @(@('IP','127.0.0.1'), @('IP','::1'), @('DNS','sql.example.invalid'))) {
                    Reset-TlsTargetFixture $provider $version $endpoint[1] $endpoint[0]
                    $before = Get-TlsTargetSnapshot
                    $result = Invoke-TlsTargetFixture
                    $expected = [pscustomobject][ordered]@{
                        ContractVersion='SqlServerLab.AuthenticatedTlsTargetMetadata/0.1'; Status='RECORDED'; TargetRef=$script:run.RunId
                        InstanceId='primary'; ScopeId=$script:run.ScopeId; Provider=$provider; SqlVersion=$version; ContainerId=('a'*64)
                        Port=15333; Identity=[pscustomobject][ordered]@{Kind=$endpoint[0];Value=$endpoint[1]}
                        RuntimeStatus='NOT_EXECUTED'; AuthorizationStatus='NOT_EVALUATED'; MutationAllowed=$false
                    }
                    Add-CheckResult "TLS-T01 exakte native Metadatenprojektion $provider/$version/$($endpoint[0])/$($endpoint[1])" (
                        $result.Success -and $null -eq $result.ErrorCode -and
                        [string]::Equals(($result.Value|ConvertTo-Json -Depth 8 -Compress),($expected|ConvertTo-Json -Depth 8 -Compress),[StringComparison]::Ordinal))
                    Add-CheckResult 'TLS-T02 unveraenderte Dateien und private Feldgrenze' ($before -ceq (Get-TlsTargetSnapshot) -and
                        ($result|ConvertTo-Json -Depth 8 -Compress) -notmatch 'TLS_PRIVATE_CANARY|synthetic-volume|sql-lab-tls-target')
                    $result.Value.Identity.Value='changed'
                    Add-CheckResult 'TLS-T03 tiefe getrennte Identitaet' ($script:request.Identity.Value -ceq $endpoint[1])
                }
            }
        }
        # Katalogisierte CU-Selektoren bleiben vollstaendig erhalten; Basisjahr
        # und aehnliche Tags duerfen die konkrete Auswahl nicht ersetzen.
        foreach($provider in @('docker','podman')) {
            foreach($row in @(
                @('2019','CU32','2019-CU32-ubuntu-20.04','15.0.4430.1'),
                @('2022','CU27','2022-CU27-ubuntu-22.04','16.0.4295.3'),
                @('2025','CU9','2025-CU9-ubuntu-24.04','17.0.5005.3'))) {
                foreach($selector in @(($row[0]+'-'+$row[1]),$row[2])) {
                    Reset-TlsTargetFixture $provider $selector
                    $before=Get-TlsTargetSnapshot
                    $result=Invoke-TlsTargetFixture
                    Add-CheckResult "TLS-T11 CU bleibt exakt $provider/$selector" ($result.Success -and
                        $result.Value.SqlVersion -ceq $selector -and $before -ceq (Get-TlsTargetSnapshot))
                    $binding=Get-LabDiagnosticBinding -RunId $script:run.RunId -InstanceId primary -DataRoot $script:dataRoot
                    Add-CheckResult 'TLS-T11 unabhaengige Katalogbindung' ($binding.SqlVersionBinding.Selector -ceq $selector -and
                        $binding.SqlVersionBinding.BaseVersion -ceq $row[0] -and $binding.SqlVersionBinding.CatalogBuild -ceq $row[3] -and
                        $binding.SqlVersionBinding.ContainerImage -ceq ('mcr.microsoft.com/mssql/server:'+$row[2]))
                    $script:request.SqlVersion=$row[0]
                    Assert-TlsTargetRejected 'TLS-T11 Basisjahr ersetzt keine CU' (Invoke-TlsTargetFixture)
                }
            }
        }
        foreach($selector in @('2025-CU999','2025-CU9-ubuntu-99.99','2025-cu9','2025-CU09','2025-CU9 ' ,"2025-CU9`n",'2025-CU9/../x')) {
            Reset-TlsTargetFixture docker $selector
            Assert-TlsTargetRejected 'TLS-T12 unbekannte oder nichtkanonische CU' (Invoke-TlsTargetFixture)
        }
        Reset-TlsTargetFixture docker '2025-CU9'
        $script:state.instances[0].version='2025-CU9-ubuntu-24.04';Save-TlsTargetFixture
        Assert-TlsTargetRejected 'TLS-T12 Alias und Tag sind keine identischen Runselektoren' (Invoke-TlsTargetFixture)
        Reset-TlsTargetFixture hyperv '2025-CU9'
        Assert-TlsTargetRejected 'TLS-T12 keine Hyper-V-CU-Erweiterung' (Invoke-TlsTargetFixture)
        $savedCatalog=$script:VersionCatalog
        try {
            foreach($mutation in @('duplicate-base','duplicate-tag','wrong-cu','wrong-build','wrong-case','missing-tag')) {
                $script:VersionCatalog=$savedCatalog
                Reset-TlsTargetFixture docker '2025-CU9-ubuntu-24.04'
                $script:VersionCatalog=$savedCatalog|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
                $version=@($script:VersionCatalog.versions|Where-Object id -CEQ '2025')[0]
                $build=@($version.docker.builds|Where-Object tag -CEQ '2025-CU9-ubuntu-24.04')[0]
                switch($mutation) {
                    duplicate-base { $script:VersionCatalog.versions += $version }
                    duplicate-tag { $version.docker.builds += $build }
                    wrong-cu { $build.cu='CU8' }
                    wrong-build { $build.build='17.0.invalid' }
                    wrong-case { $build.tag='2025-CU9-Ubuntu-24.04' }
                    missing-tag { $version.docker.builds=@($version.docker.builds|Where-Object tag -CNE $build.tag) }
                }
                Assert-TlsTargetRejected "TLS-T13 inkonsistenter Katalog $mutation" (Invoke-TlsTargetFixture)
            }
            $catalogCulture=[Threading.Thread]::CurrentThread.CurrentCulture
            try {
                foreach($culture in @('en-US','de-DE','tr-TR')) {
                    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
                    foreach($ignored in @([char]0x200b,[char]0x00ad)) {
                        foreach($field in @('id','cu','tag')) {
                            $script:VersionCatalog=$savedCatalog
                            Reset-TlsTargetFixture docker '2025-CU9-ubuntu-24.04'
                            $script:VersionCatalog=$savedCatalog|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
                            $version=@($script:VersionCatalog.versions|Where-Object id -CEQ '2025')[0]
                            $build=@($version.docker.builds|Where-Object tag -CEQ '2025-CU9-ubuntu-24.04')[0]
                            if($field -ceq 'id'){$version.id += $ignored}else{$build.$field += $ignored}
                            Assert-TlsTargetRejected "TLS-T13 ordinaler Katalog $culture/$field/$([int]$ignored)" (Invoke-TlsTargetFixture)
                        }
                    }
                }
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture=$catalogCulture }
        } finally { $script:VersionCatalog=$savedCatalog }
        $cases = [ordered]@{
            'fremde RunId' = { $script:request.TargetRef='33333333-3333-3333-3333-333333333333' }
            'andere Instanz' = { $script:state.instances[0].id='secondary' }
            'doppelte Instanz' = { $script:state.instances += $script:state.instances[0] }
            'fehlende Runtime' = { $script:state.instances=@() }
            'Providerabweichung' = { $script:state.instances[0].provider='podman' }
            'Versionsabweichung' = { $script:state.instances[0].version='2022' }
            'fehlende Version' = { $script:state.instances[0].PSObject.Properties.Remove('version') }
            'fehlender Container' = { $script:state.instances[0].PSObject.Properties.Remove('containerId') }
            'Containername' = { $script:state.instances[0].containerId='synthetic-container' }
            'Containercase' = { $script:state.instances[0].containerId=('A'*64) }
            'Containerarray' = { $script:state.instances[0].containerId=@('a'*64) }
            'Portabweichung' = { $script:state.instances[0].port=15334 }
            'Stringport' = { $script:state.instances[0].port='15333' }
            'Doubleport' = { $script:state.instances[0].port=15333.5 }
            'Boolport' = { $script:state.instances[0].port=$true }
            'fehlender Port' = { $script:state.instances[0].PSObject.Properties.Remove('port') }
            'Adressabweichung' = { $script:state.instances[0].host='127.0.0.2' }
            'kein localhost-Alias' = { $script:state.instances[0].host='localhost' }
            'keine DNS-Aufloesung' = { $script:state.instances[0].host='sql.example.invalid' }
            'fehlender Host' = { $script:state.instances[0].PSObject.Properties.Remove('host') }
            'Hostarray' = { $script:state.instances[0].host=@('127.0.0.1') }
            'nicht laufender Run' = { $script:state.state='STOPPED' }
            'entfernter Run' = { $script:state.state='REMOVED' }
            'nicht laufender Teilrun' = { $script:state.providerSubRuns[0].state='INITIALIZING' }
            'Rootregistrierung fehlt' = { $script:catalog.LabDataLocations=@() }
            'Rootregistrierung doppelt' = { $script:catalog.LabDataLocations += $script:catalog.LabDataLocations[0] }
            'anderer Controller' = { $script:catalog.ControllerId='33333333-3333-3333-3333-333333333333' }
            'fremder Scope' = { $script:scope.runId='33333333-3333-3333-3333-333333333333' }
            'fremder persistenter Root' = { $script:state.metadata.dataRoot=Join-Path $Root 'other' }
            'Legacyvertrag' = { $script:state.contractVersion='SqlServerLab.RunState/0.1' }
        }
        foreach ($case in $cases.GetEnumerator()) {
            Reset-TlsTargetFixture; & $case.Value; Save-TlsTargetFixture
            Assert-TlsTargetRejected ('TLS-T04 '+$case.Key) (Invoke-TlsTargetFixture)
        }
        $savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach($culture in @('en-US','de-DE','tr-TR')) {
                [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
                foreach($ignored in @([char]0x200b,[char]0x00ad)) {
                    foreach($field in @('rootContract','managedBy','catalogContract','catalogController','locationController','volume','runContract','runId','scopeRun','scopeId','desiredContract','desiredVersion','host','provider','version','instance','runState','subState','subInstance')) {
                        Reset-TlsTargetFixture
                        switch($field) {
                            rootContract { $script:marker.ContractVersion += $ignored }
                            managedBy { $script:marker.ManagedBy += $ignored }
                            catalogContract { $script:catalog.ContractVersion += $ignored }
                            catalogController { $script:catalog.ControllerId += $ignored }
                            locationController { $script:catalog.LabDataLocations[0].ControllerId += $ignored }
                            volume { $script:catalog.LabDataLocations[0].VolumeId += $ignored }
                            runContract { $script:state.contractVersion += $ignored }
                            runId { $script:state.runId += $ignored }
                            scopeRun { $script:scope.runId += $ignored }
                            scopeId { $script:scope.scopeId += $ignored }
                            desiredContract { $script:state.metadata.desiredState.Contract.Name += $ignored }
                            desiredVersion { $script:state.metadata.desiredState.Contract.Version += $ignored }
                            host { $script:state.instances[0].host += $ignored }
                            provider { $script:state.instances[0].provider += $ignored }
                            version { $script:state.instances[0].version += $ignored }
                            instance { $script:state.instances[0].id += $ignored }
                            runState { $script:state.state += $ignored }
                            subState { $script:state.providerSubRuns[0].state += $ignored }
                            subInstance { $script:state.providerSubRuns[0].instanceIds=@('primary'+$ignored) }
                        }
                        Save-TlsTargetFixture
                        Assert-TlsTargetRejected "TLS-T05 ordinal $culture/$field/$([int]$ignored)" (Invoke-TlsTargetFixture)
                    }
                }
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture }
        Reset-TlsTargetFixture
        $script:state.metadata.persistentData=$false; $script:state.metadata.desiredState.PersistentData=$false; $script:state.metadata.dataRoot=$null
        Save-TlsTargetFixture
        Add-CheckResult 'TLS-T06 nichtpersistenter moderner Run ohne Rootmigration' (Invoke-TlsTargetFixture).Success
        $connectionPath=Join-Path $script:run.RunDir 'connection-info.json'
        $secretPath=Join-Path $script:run.RunDir 'secrets/sa-password.secret'
        $null=New-Item -ItemType Directory -Path (Split-Path $secretPath) -Force
        [IO.File]::WriteAllText($connectionPath,'TLS_PRIVATE_CANARY'); [IO.File]::WriteAllText($secretPath,'TLS_PRIVATE_CANARY')
        $connectionLock=[IO.File]::Open($connectionPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $secretLock=[IO.File]::Open($secretPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Add-CheckResult 'TLS-T06 keine Connection-/Secretdatei gelesen' (Invoke-TlsTargetFixture).Success }
        finally { $connectionLock.Dispose(); $secretLock.Dispose() }
        $requestBefore=$script:request|ConvertTo-Json -Depth 8 -Compress
        $streams=@(Invoke-TlsTargetFixture *>&1)
        Add-CheckResult 'TLS-T07 genau ein Ergebnis ohne Nebenstreams oder Caller-Mutation' ($streams.Count -eq 1 -and $streams[0].Success -and
            $requestBefore -ceq ($script:request|ConvertTo-Json -Depth 8 -Compress))
        $script:request.Provider='hyperv'
        $result=Invoke-TlsTargetFixture
        Assert-TlsTargetRejected 'TLS-T08 Hyper-V bleibt explizit gesperrt' $result
        Add-CheckResult 'TLS-T08 stabiler Unsupportedcode' ($result.ErrorCode -ceq 'TLS_TARGET_PROVIDER_UNSUPPORTED')
        # Ungueltige Selektoren erreichen nicht einmal den Metadatenreader.
        $realBinding=${function:Get-LabDiagnosticBinding}; $script:bindingCalls=0
        try {
            function Get-LabDiagnosticBinding { $script:bindingCalls++; throw 'TLS_PRIVATE_CANARY unexpected read' }
            Reset-TlsTargetFixture
            foreach($id in @($null,'','../primary','primary/other',"primary`n",@('primary'),[pscustomobject]@{})) {
                Assert-TlsTargetRejected 'TLS-T09 ungueltige Instanzauswahl' (Get-LabAuthenticatedTlsTargetMetadata -Request $script:request -InstanceId $id -DataRoot $script:dataRoot)
            }
            foreach($rootValue in @($null,'',@($script:dataRoot),[pscustomobject]@{})) {
                Assert-TlsTargetRejected 'TLS-T09 ungueltiger Roottyp' (Get-LabAuthenticatedTlsTargetMetadata -Request $script:request -InstanceId primary -DataRoot $rootValue)
            }
            Assert-TlsTargetRejected 'TLS-T09 ungueltige Anfrage' (Get-LabAuthenticatedTlsTargetMetadata -Request ([pscustomobject]@{}) -InstanceId primary -DataRoot $script:dataRoot)
            Add-CheckResult 'TLS-T09 kein Metadatenread vor Formpruefung' ($script:bindingCalls -eq 0)
        } finally { Set-Item function:Get-LabDiagnosticBinding $realBinding }
        function Reset-TlsHyperVFixture {
            Reset-TlsTargetFixture hyperv '2025'
            $script:state.metadata|Add-Member -NotePropertyName workflowKind -NotePropertyValue 'hyperv-lab' -Force
            $script:state.instances=@()
            $script:connection=[pscustomobject]@{schemaVersion=1;instances=@([pscustomobject]@{
                id='primary';provider='hyperv';sqlVersion='2025';workload='sql';vmId='33333333-3333-3333-3333-333333333333';
                vmName='TLS_PRIVATE_CANARY';host='127.0.0.1';port=15333;ConnectionString='TLS_PRIVATE_CANARY';
                sqlInstances=@([pscustomobject]@{InstanceId='MSSQL17.MSSQLSERVER';Name='MSSQLSERVER';IsDefault=$true;ServiceName='MSSQLSERVER';ServiceStatus='Running';TcpPort=15333})})}
            Save-TlsHyperVFixture
        }
        function Save-TlsHyperVFixture {
            Save-TlsTargetFixture
            Write-TlsTargetFixture (Join-Path $script:run.RunDir 'connection-info.json') $script:connection
        }
        function Invoke-TlsHyperVFixture {
            & {Set-StrictMode -Version Latest;Get-LabAuthenticatedTlsHyperVTargetMetadata -Request $script:request -InstanceId primary -SqlInstanceId MSSQL17.MSSQLSERVER -DataRoot $script:dataRoot}
        }
        function Get-VM {throw 'TLS_PRIVATE_CANARY forbidden VM query'}
        function Get-HyperVLabWorkflowRun {throw 'TLS_PRIVATE_CANARY forbidden workflow repair'}
        Reset-TlsHyperVFixture
        $before=Get-TlsTargetSnapshot;$streams=@(Invoke-TlsHyperVFixture *>&1)
        $result=$streams[0]
        $expected=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsHyperVTargetMetadata/0.1';Status='RECORDED';
            TargetRef=$script:run.RunId;InstanceId='primary';SqlInstanceId='MSSQL17.MSSQLSERVER';ScopeId=$script:run.ScopeId;
            Provider='hyperv';SqlVersion='2025';VMId='33333333-3333-3333-3333-333333333333';ServiceName='MSSQLSERVER';Port=15333;
            Identity=[pscustomobject][ordered]@{Kind='IP';Value='127.0.0.1'};RuntimeStatus='NOT_EXECUTED';AuthorizationStatus='NOT_EVALUATED';MutationAllowed=$false}
        Add-CheckResult 'TLS-H01 exakter Hyper-V-DTO ohne native Aufrufe oder Rohwerte' ($streams.Count -eq 1 -and $result.Success -and
            [string]::Equals(($result.Value|ConvertTo-Json -Depth 8 -Compress),($expected|ConvertTo-Json -Depth 8 -Compress),[StringComparison]::Ordinal))
        Add-CheckResult 'TLS-H02 eigene Metadaten unveraendert' ($before -ceq (Get-TlsTargetSnapshot))
        $result.Value.Identity.Value='changed'
        Add-CheckResult 'TLS-H03 abgetrennte Identitaet' ($script:request.Identity.Value -ceq '127.0.0.1')
        Reset-TlsHyperVFixture
        $script:connection.instances[0].sqlInstances[0].Name='NAMED_SQL'
        $script:connection.instances[0].sqlInstances[0].IsDefault=$false
        $script:connection.instances[0].sqlInstances[0].ServiceName='MSSQL$NAMED_SQL'
        Save-TlsHyperVFixture
        Add-CheckResult 'TLS-H03 Instanz-ID bleibt opaque, Dienstkante aus Name und IsDefault' (Invoke-TlsHyperVFixture).Success
        $hyperVCases=[ordered]@{
            'fremder Workflow'={ $script:state.metadata.workflowKind='other' }
            'fremde Scopebindung'={ $script:scope.runId='44444444-4444-4444-4444-444444444444' }
            'gestoppter Run'={ $script:state.state='STOPPED' }
            'gestoppter Provider'={ $script:state.providerSubRuns[0].state='STOPPED' }
            'fremder Root'={ $script:marker.DataRoot=Join-Path $Root 'other' }
            'zweite registrierte Location'={ $script:catalog.LabDataLocations += $script:catalog.LabDataLocations[0] }
            'fremde VM im Run'={ $script:state.instances=@([pscustomobject]@{id='primary';provider='hyperv';version='2025';vmId='44444444-4444-4444-4444-444444444444'}) }
            'VM-ID fehlt'={ $script:connection.instances[0].vmId=$null }
            'leere VM-ID'={ $script:connection.instances[0].vmId='00000000-0000-0000-0000-000000000000' }
            'Displayname ersetzt VM-ID'={ $script:connection.instances[0].vmId='TLS_PRIVATE_CANARY' }
            'doppelte VM'={ $script:connection.instances += $script:connection.instances[0] }
            'fremde Instanz'={ $script:connection.instances[0].id='other' }
            'fremder Provider'={ $script:connection.instances[0].provider='docker' }
            'nur Windows statt SQL'={ $script:connection.instances[0].workload='windows' }
            'fremde Version'={ $script:connection.instances[0].sqlVersion='2022' }
            'CU ist kein Hyper-V-Jahr'={ $script:request.SqlVersion='2025-CU9' }
            'fremder Host'={ $script:connection.instances[0].host='localhost' }
            'Stringport'={ $script:connection.instances[0].port='15333' }
            'fremder Port'={ $script:connection.instances[0].port=1433 }
            'Stringschema'={ $script:connection.schemaVersion='1' }
            'SQL-Auswahl fehlt'={ $script:connection.instances[0].sqlInstances=@() }
            'SQL-ID fehlt'={ $script:connection.instances[0].sqlInstances[0].InstanceId='other' }
            'doppelte SQL-ID'={ $script:connection.instances[0].sqlInstances += $script:connection.instances[0].sqlInstances[0] }
            'SQL-ID-Kulturalias'={ $script:connection.instances[0].sqlInstances += [pscustomobject]@{InstanceId='mssql17.mssqlserver'} }
            'SQL-Dienst fehlt'={ $script:connection.instances[0].sqlInstances[0].ServiceName='other' }
            'Standardinstanz mit fremdem gueltigem Dienst'={ $script:connection.instances[0].sqlInstances[0].ServiceName='MSSQL$OTHER' }
            'Instanzname fehlt'={ $script:connection.instances[0].sqlInstances[0].Name=$null }
            'Defaulttyp ist String'={ $script:connection.instances[0].sqlInstances[0].IsDefault='true' }
            'Defaultinstanz mit anderem Namen'={ $script:connection.instances[0].sqlInstances[0].Name='OTHER' }
            'Namensinstanz ohne Namensdienst'={ $script:connection.instances[0].sqlInstances[0].IsDefault=$false;$script:connection.instances[0].sqlInstances[0].Name='OTHER' }
            'Defaultname als Namensinstanz'={ $script:connection.instances[0].sqlInstances[0].IsDefault=$false }
            'SQL-Dienst gestoppt'={ $script:connection.instances[0].sqlInstances[0].ServiceStatus='Stopped' }
            'SQL-Port abweichend'={ $script:connection.instances[0].sqlInstances[0].TcpPort=1433 }
            'SQL-Stringport'={ $script:connection.instances[0].sqlInstances[0].TcpPort='15333' }
        }
        foreach($case in $hyperVCases.GetEnumerator()){
            Reset-TlsHyperVFixture;& $case.Value;Save-TlsHyperVFixture
            $before=Get-TlsTargetSnapshot
            Assert-TlsTargetRejected ('TLS-H04 '+$case.Key) (Invoke-TlsHyperVFixture)
            Add-CheckResult 'TLS-H04 Gegenfall ohne Dateiwrite' ($before -ceq (Get-TlsTargetSnapshot))
        }
        $realBinding=${function:Get-LabDiagnosticBinding};$script:bindingCalls=0
        try{
            function Get-LabDiagnosticBinding {$script:bindingCalls++;throw 'unexpected metadata read'}
            Reset-TlsHyperVFixture
            foreach($selector in @($null,'',@('MSSQL17.MSSQLSERVER'),[pscustomobject]@{},'MSSQL17.MSSQLSERVER ')){
                Assert-TlsTargetRejected 'TLS-H05 SQL-Auswahlform vor I/O' (Get-LabAuthenticatedTlsHyperVTargetMetadata -Request $script:request -InstanceId primary -SqlInstanceId $selector -DataRoot $script:dataRoot)
            }
            $script:request.Provider='docker'
            Assert-TlsTargetRejected 'TLS-H05 getrennte Providerlane' (Invoke-TlsHyperVFixture)
            Add-CheckResult 'TLS-H05 kein I/O bei ungueltiger Form oder Provider' ($script:bindingCalls -eq 0)
        }finally{Set-Item function:Get-LabDiagnosticBinding $realBinding}
        $source=Join-Path $Repo 'Private/AuthenticatedTlsTarget.ps1'; $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
        Add-CheckResult 'TLS-T10 reine Definition beim Laden' ($errors.Count -eq 0 -and
            @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
        $calls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
        Add-CheckResult 'TLS-T10 geschlossener lesender Commandgraph' (@($calls|Where-Object {$_ -cnotin @(
            'Test-LabAuthenticatedTlsRequest','Test-LabTlsRequestEnum','Test-LabTlsRequestReference','Get-LabDiagnosticBinding','Where-Object',
            'Read-LabDiagnosticJson','Join-Path','Test-LabDiagnosticGuid')}).Count -eq 0)
        Write-Host "Authenticated TLS Target: $script:passed PASS, $($script:failures.Count) FAIL"
        if($script:failures.Count){throw 'AUTHENTICATED_TLS_TARGET_CHECKS_FAILED'}
    } $testRoot $repo
} finally {
    $resolvedRoot=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if($resolvedRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot) -cmatch '\Asql-lab-tls-target-[a-f0-9]{32}\z' -and (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
