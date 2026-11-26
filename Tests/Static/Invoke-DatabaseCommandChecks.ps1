#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$password = [Security.SecureString]::new()
foreach ($character in 'Synthetic_Contract1!'.ToCharArray()) { $password.AppendChar($character) }
$password.MakeReadOnly()

function Assert-DatabaseContract {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "DATABASE_COMMAND_CHECK_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    & $module {
        param([securestring]$ExpectedPassword)
        $script:DatabaseCommandQueries = @()
        $script:DatabaseCommandPassword = $ExpectedPassword
        $script:DatabaseCommandOriginalQuery = (Get-Command Invoke-SqlQuery -ErrorAction Stop).ScriptBlock
        Set-Item Function:Invoke-SqlQuery -Value {
            param($HostName,$Port,$SaPlain,$ProductQueryPassword,$Query,$TimeoutSeconds)
            if ($SaPlain -or -not [object]::ReferenceEquals($ProductQueryPassword,$script:DatabaseCommandPassword)) {
                throw 'DATABASE_COMMAND_PASSWORD_BOUNDARY_CHANGED'
            }
            $script:DatabaseCommandQueries += [string]$Query
        }
    } $password

    New-SqlServerLabDatabase -HostName 127.0.0.1 -Port 1433 -SaPassword $password -DatabaseName WindowsPathContract `
        -DataFiles @([PSCustomObject]@{ name='WindowsPath_Data'; path='E:\SQLData\WindowsPath_Data.mdf'; sizeMB=8; filegrowthMB=8 }) `
        -LogFiles @([PSCustomObject]@{ name='WindowsPath_Log'; path='L:\SQLLog\WindowsPath_Log.ldf'; sizeMB=8; filegrowthMB=8 }) | Out-Null
    $windowsQuery = & $module { $script:DatabaseCommandQueries -join "`n" }
    Assert-DatabaseContract ($windowsQuery -match [regex]::Escape("E:\SQLData\WindowsPath_Data.mdf")) 'Absoluter Windows-Datenpfad wird in CREATE DATABASE uebernommen'
    Assert-DatabaseContract ($windowsQuery -match [regex]::Escape("L:\SQLLog\WindowsPath_Log.ldf")) 'Absoluter Windows-Logpfad wird in CREATE DATABASE uebernommen'

    $rejected = $false
    try {
        New-SqlServerLabDatabase -Port 1433 -SaPassword $password -DatabaseName RelativePathContract `
            -DataFiles @([PSCustomObject]@{ name='Relative_Data'; path='relative\data.mdf'; sizeMB=8; filegrowthMB=8 }) | Out-Null
    }
    catch { $rejected = $_.Exception.Message -match 'absoluter Linux- oder Windows-SQL-Pfad' }
    Assert-DatabaseContract $rejected 'Relative SQL-Dateipfade bleiben fail-closed'

    & $module {
        $script:DatabaseCommandStorageOriginals = @{}
        foreach ($name in @('Get-LabVerifiedStorageRuntimeContext','Resolve-LabStorageDatabaseFilePlan','Start-LabStorageSqlOperation','Complete-LabStorageSqlOperation','Fail-LabStorageSqlOperation')) {
            $script:DatabaseCommandStorageOriginals[$name] = (Get-Command $name -ErrorAction Stop).ScriptBlock
        }
        $script:DatabaseCommandCompletedOperations = 0
        Set-Item Function:Get-LabVerifiedStorageRuntimeContext -Value {
            param($RunId,$InstanceId,$StateRoot)
            [PSCustomObject]@{ Plan=[PSCustomObject]@{PlanId='11111111-1111-1111-1111-111111111111'}; Receipt=[PSCustomObject]@{} }
        }
        Set-Item Function:Resolve-LabStorageDatabaseFilePlan -Value {
            param($Context,$DatabaseName,$DataFiles,$LogFiles)
            [PSCustomObject]@{
                DataFiles=@([PSCustomObject]@{name='Bound_Data';path='T:\SQLLab\Data\Bound_Data.mdf';sizeMB=64;filegrowthMB=64})
                LogFiles=@([PSCustomObject]@{name='Bound_Log';path='U:\SQLLab\Log\Bound_Log.ldf';sizeMB=32;filegrowthMB=32})
            }
        }
        Set-Item Function:Start-LabStorageSqlOperation -Value { param($Context,$OperationId,$Kind,$DatabaseName) $Context }
        Set-Item Function:Complete-LabStorageSqlOperation -Value { param($Context,$OperationId,$Kind,$DatabaseName,$Files) $script:DatabaseCommandCompletedOperations++; $Context.Receipt }
        Set-Item Function:Fail-LabStorageSqlOperation -Value { param($Context,$OperationId,$ErrorMessage) $Context.Receipt }
    }
    $beforeBoundQueryCount = @(& $module { $script:DatabaseCommandQueries }).Count
    $boundResult = New-SqlServerLabDatabase -HostName 172.28.0.42 -Port 1433 -SaPassword $password `
        -DatabaseName BoundDatabase -RunId '22222222-2222-2222-2222-222222222222' -InstanceId primary `
        -Options @{queryStore=$true}
    $boundQueries = @(& $module { $script:DatabaseCommandQueries })[$beforeBoundQueryCount..(@(& $module { $script:DatabaseCommandQueries }).Count - 1)] -join "`n"
    $completedOperations = & $module { $script:DatabaseCommandCompletedOperations }
    Assert-DatabaseContract ($boundQueries -match [regex]::Escape('T:\SQLLab\Data\Bound_Data.mdf') -and
        $boundQueries -match [regex]::Escape('U:\SQLLab\Log\Bound_Log.ldf')) 'Run-basierte CREATE-Datenbank verwendet ausschließlich dateigenaue Runtime-Bindings'
    Assert-DatabaseContract ($boundQueries -match 'LAB_STORAGE_SQL_MASTER_FILES_POSTCONDITION_FAILED' -and
        $completedOperations -eq 1 -and $boundResult.StoragePlanId -eq '11111111-1111-1111-1111-111111111111') 'CREATE-Erfolg wird erst nach master_files-Postcondition quittiert'
    Assert-DatabaseContract ($boundQueries -match 'ALTER DATABASE \[BoundDatabase\] SET QUERY_STORE = ON') 'CREATE, Optionen und Dateipfadprüfung verwenden dasselbe SecureString-Credential'

    $guided = & $module {
        param([securestring]$Credential)
        $run = '33333333-2222-4333-8444-555555555555'
        $target = [pscustomobject]@{Provider='hyperv';VMId='44444444-2222-4333-8444-555555555555';HostName='192.0.2.12';Port=1438}
        $probe = [pscustomobject]@{Mode='create';Calls=0;Checks=0;Bound=$false}
        function Get-LabGuidedHyperVLibraryBinding {
            param($RunId,$InstanceId,$Guest)
            if ($probe.Mode -ceq 'unready' -or $RunId -cne $run -or $InstanceId -cne 'primary' -or
                $Guest.UserName -cne 'Administrator' -or -not [object]::ReferenceEquals($Guest.Password,$Credential)) { throw 'SYNTHETIC_UNBOUND' }
            [pscustomobject]@{Target=$target;Context=[pscustomobject]@{StateRoot='synthetic-state'}}
        }
        function Invoke-LabSqlcmdProgress {
            param($SqlPassword,$ProcessTimeoutSeconds,$ArgumentList)
            $probe.Checks++
            if (-not [object]::ReferenceEquals($SqlPassword,$Credential) -or $ArgumentList -ccontains '-P' -or
                $ArgumentList -cnotcontains '192.0.2.12,1438') { throw 'SYNTHETIC_QUERY_BINDING_CHANGED' }
            [pscustomobject]@{ExitCode=0;Output=@($(if($probe.Mode -ceq 'exists'){'1'}else{'0'}))}
        }
        function Resolve-LabRunInstance {
            param($RunId,$InstanceId,$StateRoot)
            if ($RunId -cne $run -or $InstanceId -cne 'primary' -or $StateRoot -cne 'synthetic-state') { throw 'SYNTHETIC_UNBOUND' }
            if ($probe.Mode -ceq 'drift') {
                [pscustomobject]@{Provider='hyperv';VMId=$target.VMId;HostName=$target.HostName;Port=1439}
            } else { $target }
        }
        function New-SqlServerLabDatabase {
            [CmdletBinding()]param($RunId,$InstanceId,$StateRoot,$DatabaseName,$HostName,$Port,$SaPassword)
            $probe.Calls++
            $probe.Bound = $RunId -ceq $run -and $InstanceId -ceq 'primary' -and $StateRoot -ceq 'synthetic-state' -and
                $DatabaseName -ceq 'GuidedFixture' -and $HostName -ceq $target.HostName -and $Port -eq $target.Port -and
                [object]::ReferenceEquals($SaPassword,$Credential)
            [pscustomobject]@{Success=$true;DatabaseName=$DatabaseName;StoragePlanId='66666666-2222-4333-8444-555555555555';PrivatePath='private-canary'}
        }
        $arguments = @{RunId=$run;InstanceId='primary';DatabaseName='GuidedFixture';GuestUserName='Administrator';GuestPassword=$Credential;SaPassword=$Credential}
        $blocked = @{}
        foreach ($case in @('exists','drift','unready')) {
            $probe.Mode = $case
            $blocked[$case] = try { $null = Invoke-LabGuidedHyperVDatabaseCreate @arguments; '' } catch { $_.Exception.Message }
        }
        $blockedCalls = $probe.Calls
        $probe.Mode = 'create'
        $created = Invoke-LabGuidedHyperVDatabaseCreate @arguments
        [pscustomobject]@{Blocked=$blocked;BlockedCalls=$blockedCalls;Calls=$probe.Calls;Bound=$probe.Bound;Created=$created}
    } $password
    Assert-DatabaseContract ($guided.BlockedCalls -eq 0 -and $guided.Blocked.exists -ceq 'HYPERV_DATABASE_CREATE_TARGET_EXISTS' -and
        $guided.Blocked.drift -ceq 'HYPERV_DATABASE_CREATE_TARGET_NOT_READY' -and $guided.Blocked.unready -ceq 'HYPERV_DATABASE_CREATE_TARGET_NOT_READY') 'Hyper-V-Fachaktion sperrt Namenskonflikt und Zieldrift vor CREATE'
    Assert-DatabaseContract ($guided.Calls -eq 1 -and $guided.Bound -and $guided.Created.Status -ceq 'CREATED' -and
        -not $guided.Created.PSObject.Properties['PrivatePath']) 'Hyper-V-Fachaktion bindet registriertes Laufzeitziel und gibt eine pfadfreie Quittung aus'
}
finally {
    & $module {
        if ($script:DatabaseCommandOriginalQuery) {
            Set-Item Function:Invoke-SqlQuery -Value $script:DatabaseCommandOriginalQuery
        }
        if ($script:DatabaseCommandStorageOriginals) {
            foreach ($entry in $script:DatabaseCommandStorageOriginals.GetEnumerator()) { Set-Item "Function:$($entry.Key)" -Value $entry.Value }
        }
        Remove-Variable DatabaseCommandQueries,DatabaseCommandPassword,DatabaseCommandOriginalQuery,DatabaseCommandStorageOriginals,DatabaseCommandCompletedOperations -Scope Script -ErrorAction SilentlyContinue
    }
    $password.Dispose()
}

Write-Host 'DATABASE COMMAND CHECKS: PASS' -ForegroundColor Green
