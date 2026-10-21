# Closed operational version selection; no native runtime, key or trust actions.
function Invoke-TlsLabVersionFixture {
    . (Join-Path $repo 'Tests/Common/AuthenticatedTlsAcceptanceSelection.ps1')
    $expected2025=Get-OwnedTlsAcceptanceProfile '2025-CU9'
    $qualification2025=[pscustomobject]@{SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3'}
    $accepted=$true;try{Assert-OwnedTlsAcceptanceSelection $expected2025 $qualification2025 ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2'})}catch{$accepted=$false}
    Add-CheckResult 'Native SQL2025 oracle accepts 0.2 only without a profile property' $accepted
    foreach($value in @($null,'')){
        $unexpected=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';SqlProfileId=$value}
        Add-CheckResult 'Native SQL2025 oracle rejects present null or empty profile properties independently' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection $expected2025 $qualification2025 $unexpected})
    }
    $expected=Get-OwnedTlsAcceptanceProfile '2022-CU27'
    $returned2025=[pscustomobject]@{SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3'}
    Add-CheckResult 'Native oracle rejects requested SQL2022 with a self-consistent SQL2025 return' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection $expected $returned2025})
    $good=[pscustomobject]@{SqlVersion='2022';Patch='cu27';SqlBuild='16.0.4295.3'}
    $accepted=$true;try{Assert-OwnedTlsAcceptanceSelection $expected $good}catch{$accepted=$false}
    Add-CheckResult 'Native oracle accepts only the independently requested SQL2022 build' $accepted
    $accepted=$true;try{Assert-OwnedTlsAcceptanceSelection $expected $good ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2022-CU27'})}catch{$accepted=$false}
    Add-CheckResult 'Native SQL2022 oracle retains its explicit 0.3 profile after absent-profile hardening' $accepted
    Add-CheckResult 'Native oracle rejects a SQL2025 record for requested SQL2022' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection $expected $good ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2'})})
    Add-CheckResult 'Native oracle rejects a SQL2025 export for requested SQL2022' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection -Expected $expected -Qualification $good -Entry ([pscustomobject]@{sqlVersion='2025';patch='cu9';resolvedVersion='17.0.5005.3';key='LINUX_SQL2025_CU9_TLS'})})
    foreach($version in @('2025-CU9','2022-CU27','2019-CU32')){
        try{
            $profile=Get-LabTlsSqlProfile $version
            $catalog=Get-Content -LiteralPath (Join-Path $repo 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json -Depth 20
            $row=@($catalog.versions|Where-Object id -CEQ $profile.SqlVersion)
            $build=@($row.docker.builds|Where-Object tag -CEQ $profile.ImageTag)
            Add-CheckResult "$version binds exactly one catalogued image and SQL build" ($build.Count -eq 1 -and $build[0].build -ceq $profile.SqlBuild -and $profile.Patch -ceq $build[0].cu.ToLowerInvariant())
        }catch{Add-CheckResult "$version operational profile available" $false}
    }
    foreach($version in @('2022','2022:cu27','2022-CU26','2022-cu27','2019','2019-CU31','2019-cu32','2025-CU8','2022-CU27-ubuntu-22.04','')){
        Add-CheckResult 'Unqualified version aliases and patch levels remain rejected' (Test-TlsLabReject {Get-LabTlsSqlProfile $version})
    }
    foreach($contract in @('0.1','0.2')){
        Add-CheckResult 'Historical record retains SQL2025 qualification profile' ((Get-LabTlsBindingSqlProfile ([pscustomobject]@{ContractVersion=('SqlServerLab.AuthenticatedTlsLab/'+$contract)})).Version -ceq '2025-CU9')
    }
    foreach($bad in @(
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2025-CU9'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';SqlProfileId='2022-CU27'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';SqlProfileId='2019-CU32'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';SqlProfileId='2019-CU32'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2019-CU31'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2019-cu32'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2022-cu27'})){
        Add-CheckResult 'Missing or rebound version profile cannot fall back to SQL2025' (Test-TlsLabReject {Get-LabTlsBindingSqlProfile ([pscustomobject]$bad)})
    }
    $record=[ordered]@{}
    foreach($name in @('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256',
        'RunId','InstanceId','ScopeId','ContainerId','ImageId','Port','CertificateSha256','CertificateDer','NotAfterUtc','StartedAt','ServerPath')){$record[$name]='synthetic'}
    $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';$record.Provider='podman';$record.RuntimeBinding=@{};$record.SqlProfileId='2022-CU27'
    Add-CheckResult 'Closed 0.3 record preserves explicit SQL profile and provider' ((Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record)).SqlProfileId -ceq '2022-CU27')
    $record.Remove('SqlProfileId')
    Add-CheckResult '0.3 record missing its profile is rejected by actual reader' (Test-TlsLabReject {Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record)})
    $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1'
    Add-CheckResult 'Historical version cannot borrow the policy-bound record shape' (Test-TlsLabReject {Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record)})
    $expected2019=[pscustomobject]@{SqlVersion='2019';Patch='cu32';SqlBuild='15.0.4430.1';Key='LINUX_SQL2019_CU32_TLS';RecordVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2019-CU32'}
    $oracle2019=Get-OwnedTlsAcceptanceProfile '2019-CU32'
    Add-CheckResult 'Native SQL2019 oracle binds the independently requested exact CU and build' ($oracle2019.SqlBuild -ceq $expected2019.SqlBuild -and $oracle2019.Key -ceq $expected2019.Key -and $oracle2019.SqlVersion -ceq $expected2019.SqlVersion -and $oracle2019.Patch -ceq $expected2019.Patch)
    $record.ContractVersion=$expected2019.RecordVersion;$record.SqlProfileId=$expected2019.SqlProfileId
    Add-CheckResult 'Closed 0.3 reader preserves the SQL2019 profile' ((Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record)).SqlProfileId -ceq '2019-CU32')
    foreach($returned in @($returned2025,$good)){
        Add-CheckResult 'Native SQL2019 oracle rejects a self-consistent different SQL profile' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection $expected2019 $returned})
    }
    $qualification2019=[pscustomobject]@{SqlVersion='2019';Patch='cu32';SqlBuild='15.0.4430.1'}
    $accepted=$true;try{Assert-OwnedTlsAcceptanceSelection $expected2019 $qualification2019 ([pscustomobject]$record)}catch{$accepted=$false}
    Add-CheckResult 'Native SQL2019 oracle accepts exact qualification and closed record' $accepted
    $record.SqlProfileId='2022-CU27'
    Add-CheckResult 'Native SQL2019 oracle rejects rebound SQL2022 record' (Test-TlsLabReject {Assert-OwnedTlsAcceptanceSelection $expected2019 $qualification2019 ([pscustomobject]$record)})
}
Invoke-TlsLabVersionFixture
