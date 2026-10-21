# Test-only expectations, independent of product DTOs and TLS profile helpers.
function Get-OwnedTlsAcceptanceProfile {
    param([string]$Version)
    switch -CaseSensitive ($Version){
        '2025-CU9' {return [pscustomobject]@{SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3';Key='LINUX_SQL2025_CU9_TLS';RecordVersion='SqlServerLab.AuthenticatedTlsLab/0.2';SqlProfileId=$null}}
        '2022-CU27' {return [pscustomobject]@{SqlVersion='2022';Patch='cu27';SqlBuild='16.0.4295.3';Key='LINUX_SQL2022_CU27_TLS';RecordVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2022-CU27'}}
        '2019-CU32' {return [pscustomobject]@{SqlVersion='2019';Patch='cu32';SqlBuild='15.0.4430.1';Key='LINUX_SQL2019_CU32_TLS';RecordVersion='SqlServerLab.AuthenticatedTlsLab/0.3';SqlProfileId='2019-CU32'}}
        default {throw 'TLS_ACCEPTANCE_REQUEST_VERSION_UNSUPPORTED'}
    }
}
function Assert-OwnedTlsAcceptanceSelection {
    param([object]$Expected,[object]$Qualification,[object]$Record,[object]$Entry)
    if($Qualification.SqlVersion -cne $Expected.SqlVersion -or $Qualification.Patch -cne $Expected.Patch -or $Qualification.SqlBuild -cne $Expected.SqlBuild){throw 'TLS_ACCEPTANCE_REQUESTED_SQL_PROFILE_CHANGED'}
    $actualProfile=if($null -ne $Record -and $Record.PSObject.Properties['SqlProfileId']){[string]$Record.SqlProfileId}else{''}
    if($null -ne $Record -and ($Record.ContractVersion -cne $Expected.RecordVersion -or
        $actualProfile -cne [string]$Expected.SqlProfileId)){throw 'TLS_ACCEPTANCE_REQUESTED_RECORD_PROFILE_CHANGED'}
    if($null -ne $Entry -and ($Entry.sqlVersion -cne $Expected.SqlVersion -or $Entry.patch -cne $Expected.Patch -or
        $Entry.resolvedVersion -cne $Expected.SqlBuild -or $Entry.key -cne $Expected.Key)){throw 'TLS_ACCEPTANCE_REQUESTED_EXPORT_PROFILE_CHANGED'}
}
