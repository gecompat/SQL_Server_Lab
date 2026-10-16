#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Providers/HyperV/HyperVWindowsSqlScript.ps1')
. (Join-Path $repoRoot 'Public/Invoke-SqlServerLabScript.ps1')
$passed=0
function Check {param($Name,[bool]$Value) if(-not $Value){throw "FAIL: $Name"};$script:passed++;Write-Host "PASS: $Name"}
function Denied {param([scriptblock]$Action) try {& $Action|Out-Null;return $false}catch{return $true}}
function New-SyntheticSecret {$secret=[securestring]::new();foreach($character in 'synthetic-only'.ToCharArray()){$secret.AppendChar($character)};return $secret}
$command=Get-Command Invoke-SqlServerLabScript
Check 'Windows reuses the existing public command; SQL parameter sets retain mandatory SA' (@($command.ParameterSets).Count -eq 3 -and
    @($command.ParameterSets|Where-Object Name -ne RunWindows|ForEach-Object {$_.Parameters|Where-Object {$_.Name -eq 'SaPassword' -and $_.IsMandatory}}).Count -eq 2)
$windows=$command.ParameterSets|Where-Object Name -eq RunWindows
Check 'Windows requires RunId and explicit auth, without free host or credentials' (@($windows.Parameters|Where-Object {$_.Name -in @('RunId','WindowsAuthentication') -and $_.IsMandatory}).Count -eq 2 -and
    @($windows.Parameters|Where-Object Name -in @('HostName','Port','SaPassword','GuestCredential')).Count -eq 0)
$binary=[byte[]]@(0,255,42)
$items=ConvertTo-LabWindowsSqlParameters @{a='synthetic';b=[long]12;c=$true;d=$binary;e=$null;f=7}
$binary[0]=99
Check 'Parameters are typed, including a copied ISPAC and SQL NULL' ($items.Count -eq 6 -and ($items|Where-Object Name -eq '@d').Value[0] -eq 0 -and ($items|Where-Object Name -eq '@b').Type -eq 'BigInt')
foreach($values in @(@{x=[securestring]::new()},@{'@x'=1;x=2},@{'x; DROP'=1},@{x=[object]::new()},@{x=[byte[]]::new(16MB+1)})) {
    Check 'Invalid, duplicate or excessive SQL parameters fail before transport' (Denied {ConvertTo-LabWindowsSqlParameters $values})
}
$directory=Join-Path $repoRoot ('.artifacts/test-runs/windows-sql-static-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
$sql=Join-Path $directory 'consumer.sql';[IO.File]::WriteAllText($sql,"SELECT @id;`nGO`nSELECT N'synthetic';")
try {
    $cases=& {
        $id=[guid]'11111111-1111-1111-1111-111111111111'
        function Assert-LabDiagnosticPath {param($Path) $Path}
        function Get-LabSsisPrerequisiteContext {
            $tracker.Context++
            if($mode -eq 'target'){throw 'SYNTHETIC_PRIVATE_TARGET'}
            [pscustomobject]@{Directory=$directory;Run=@{scopeId='synthetic'};Instance=@{vmName='synthetic';vmId='22222222-2222-2222-2222-222222222222';port=1433};
                ExpectedInstance='MSSQLSERVER';ExpectedMajor=17;Fingerprint=$(if(($mode -eq 'pre-drift' -and $tracker.Context -gt 1) -or ($mode -eq 'post-drift' -and $tracker.Context -gt 3)){'changed'}else{'stable'})}
        }
        function Get-LabSecret {param($Path,$Name)
            $tracker.SecretCalls++;if($mode -eq 'no-secret'){return $null}
            $secret=New-SyntheticSecret;$tracker.Secret=$secret;return $secret
        }
        function Write-LabArtifactJsonAtomic {param($Path,$InputObject)
            $tracker.Journals.Add(($InputObject|ConvertTo-Json -Compress))
            if($mode -eq 'journal'){throw 'SYNTHETIC_PRIVATE_JOURNAL'}
        }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$ScriptBlock,$ArgumentList,$TimeoutSeconds,[switch]$NoRetry)
            $tracker.Calls++;$tracker.NoRetry=[bool]$NoRetry
            $tracker.Bound=($ExpectedRunId -ceq $id.ToString() -and $ExpectedVmId -eq '22222222-2222-2222-2222-222222222222' -and $ExpectedScopeId -ceq 'synthetic' -and $Credential.Password -is [securestring])
            $tracker.Arguments=$ArgumentList
            if($mode -eq 'transport'){throw 'SYNTHETIC_PRIVATE_TRANSPORT'}
            if($mode -eq 'extra'){return @(@{Success=$true},@{Success=$true})}
            [pscustomobject]@{Success=($mode -ne 'sql-failure');Batches=$(if($mode -eq 'sql-failure'){0}else{2});AuthScheme=$(if($mode -eq 'sql-auth'){'SQL'}else{'NTLM'});
                ErrorCode=$(if($mode -eq 'sql-failure'){'WINDOWS_SQL_SCRIPT_FAILED'}else{$null});SqlErrorNumber=$null;ResultSets=@(@{Batch=1;Columns=@('id');Rows=@(,@(12))})}
        }
        $results=@{}
        foreach($mode in @('success','target','pre-drift','post-drift','transport','no-secret','journal','extra','sql-auth','sql-failure','whatif')) {
            $tracker=@{Context=0;Calls=0;SecretCalls=0;Journals=[Collections.Generic.List[string]]::new();NoRetry=$false;Bound=$false;Secret=$null}
            $value=$null;$errorText='';$errorData=$null
            try {$value=Invoke-SqlServerLabScript -WindowsAuthentication -RunId $id -StateRoot $directory -ScriptPath $sql -Parameters @{id=[long]12} -KeepConnection -WhatIf:($mode -eq 'whatif')}
            catch {$errorText=$_.Exception.Message;$errorData=$_.Exception.Data}
            $disposed=$true;if($tracker.Secret){try{$copy=$tracker.Secret.Copy();$copy.Dispose();$disposed=$false}catch [ObjectDisposedException]{}}
            $results[$mode]=@{Value=$value;Error=$errorText;ErrorData=$errorData;Tracker=$tracker;Disposed=$disposed}
        }
        $results
    }
    Check 'Actual public path pins VM identity, uses protected credentials and disables replay' ($cases.success.Value.Success -and $cases.success.Tracker.Bound -and $cases.success.Tracker.NoRetry -and $cases.success.Disposed)
    Check 'Single connection and typed parameters reach the guest' ($cases.success.Tracker.Arguments[0].Count -eq 2 -and $cases.success.Tracker.Arguments[1][0].Type -eq 'BigInt' -and $cases.success.Tracker.Arguments[6] -eq 17 -and $cases.success.Tracker.Arguments[7])
    Check 'Journal precedes dispatch and contains no script, values, host or credential' ($cases.success.Tracker.Journals[0] -match 'DISPATCHED' -and ($cases.success.Tracker.Journals -join '') -notmatch 'SELECT|synthetic-only|Password|vmName')
    foreach($mode in @('target','pre-drift','no-secret','journal','whatif')) {Check "$mode cannot invoke a guest" ($cases[$mode].Tracker.Calls -eq 0)}
    Check 'WhatIf does not read credentials or write a journal' ($cases.whatif.Tracker.SecretCalls -eq 0 -and $cases.whatif.Tracker.Journals.Count -eq 0)
    foreach($mode in @('post-drift','transport','extra','sql-auth')) {Check "$mode is unconfirmed, sanitized and never retried" ($cases[$mode].Tracker.Calls -eq 1 -and $cases[$mode].Error -match 'WINDOWS_SQL_OPERATION_UNCONFIRMED' -and $cases[$mode].Error -notmatch 'PRIVATE' -and $cases[$mode].Disposed)}
    Check 'Journal failure is visible and cannot dispatch' ($cases.journal.ErrorData['JournalRecorded'] -eq $false -and $cases.journal.ErrorData['Dispatched'] -eq $false)
    Check 'Missing credentials remain distinct, with no fabricated journal' ($cases['no-secret'].ErrorData['ReasonCode'] -ceq 'WINDOWS_SQL_GUEST_CREDENTIAL_REQUIRED' -and -not $cases['no-secret'].ErrorData['JournalRecorded'])
    Check 'SQL failure is returned without asserting rollback' (-not $cases['sql-failure'].Value.Success -and $cases['sql-failure'].Value.Outcome -ceq 'FAILED_UNCONFIRMED')
    Check 'Explicit false Windows switch cannot silently choose SQL auth' (Denied {Invoke-SqlServerLabScript -WindowsAuthentication:$false -RunId ([guid]::NewGuid()) -ScriptPath $sql})

    # Execute the real guest reader/parameter/batch logic with only its native
    # connection factory substituted. No SQL server or provider is contacted.
    $guest=Get-LabWindowsSqlScriptGuest
    $factory=$guest.Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WindowsSqlConnection'},$true)
    $builderCheck=& {
        $Database='SSISDB';$Port=1433;$TimeoutSeconds=20
        . ([scriptblock]::Create($factory.Extent.Text.Replace('$sql.Open();',"throw 'SYNTHETIC_OPEN_NOT_EXECUTED';")))
        try {New-WindowsSqlConnection;return $false}catch{return $_.Exception.Message -ceq 'SYNTHETIC_OPEN_NOT_EXECUTED'}
    }
    Check 'Actual connection builder accepts canonical SQL keys before any network access' $builderCheck
    $guestText=$guest.ToString().Replace($factory.Extent.Text,'function New-WindowsSqlConnection { [pscustomobject]@{Connection=$fakeConnection;AuthScheme="NTLM"} }')
    foreach($mode in @('success','sql-fault','oversize')) {
        $table=[Data.DataTable]::new();$null=$table.Columns.Add('id',[long]);$null=$table.Columns.Add('text',[string])
        $null=$table.Rows.Add(@([long]12,$(if($mode -eq 'oversize'){'x'*600KB}else{'synthetic'})))
        $commands=[Collections.Generic.List[object]]::new()
        $fakeConnection=[pscustomobject]@{Disposed=$false;Table=$table;Commands=$commands;Mode=$mode}
        $fakeConnection|Add-Member ScriptMethod CreateCommand {
            $c=[pscustomobject]@{CommandText='';CommandTimeout=0;Parameters=([Data.SqlClient.SqlCommand]::new()).Parameters;Table=$this.Table;Mode=$this.Mode;Disposed=$false}
            $c|Add-Member ScriptMethod ExecuteReader {
                if($this.Mode -eq 'sql-fault'){throw 'SYNTHETIC_PRIVATE_SQL'}
                # DataTableReader.GetChars expects char[], unlike SqlDataReader's
                # streamed string access. Adapt that provider leaf explicitly.
                $r=[pscustomobject]@{Inner=$this.Table.CreateDataReader();FieldCount=$this.Table.Columns.Count}
                $r|Add-Member ScriptMethod Read {$this.Inner.Read()}
                $r|Add-Member ScriptMethod NextResult {$this.Inner.NextResult()}
                $r|Add-Member ScriptMethod GetName {param($i)$this.Inner.GetName($i)}
                $r|Add-Member ScriptMethod GetValue {param($i)$this.Inner.GetValue($i)}
                $r|Add-Member ScriptMethod GetFieldType {param($i)$this.Inner.GetFieldType($i)}
                $r|Add-Member ScriptMethod IsDBNull {param($i)$this.Inner.IsDBNull($i)}
                $r|Add-Member ScriptMethod GetChars {param($i,$offset,$buffer,$bufferOffset,$length)
                    $value=$this.Inner.GetString($i);if($null -eq $buffer){return [long]$value.Length}
                    $count=[math]::Min($length,$value.Length-$offset);$value.CopyTo([int]$offset,$buffer,[int]$bufferOffset,[int]$count);return [long]$count
                }
                $r|Add-Member ScriptMethod Dispose {$this.Inner.Dispose()}
                return $r
            }
            $c|Add-Member ScriptMethod Dispose {$this.Disposed=$true};$this.Commands.Add($c);return $c
        }
        $fakeConnection|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $actual=& ([scriptblock]::Create($guestText)) @('SELECT @id','SELECT @stream') @(@{Name='@id';Type='BigInt';Value=[long]12},@{Name='@stream';Type='VarBinary';Value=[object[]]@([byte]1,[byte]2)}) SSISDB 1433 MSSQLSERVER 17 $true 20
        if($mode -eq 'success') {
            Check 'Actual guest executes both batches with typed binary parameters and result rows' ($actual.Success -and $actual.Batches -eq 2 -and $actual.ResultSets.Count -eq 2 -and $actual.ResultSets[0].Rows[0][0] -eq 12 -and $commands[0].Parameters['@stream'].SqlDbType -eq 'VarBinary')
            Check 'Remoted object[] is restored to native SqlClient binary data' ($commands[0].Parameters['@stream'].Value -is [byte[]] -and $commands[0].Parameters['@stream'].SqlValue.Value.Length -eq 2)
        } else {Check "Actual guest $mode sanitizes and bounds output" (-not $actual.Success -and $actual.ResultSets.Count -eq 0 -and ($actual|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE')}
        Check 'Actual guest always disposes connection and commands' ($fakeConnection.Disposed -and @($commands|Where-Object {-not $_.Disposed}).Count -eq 0)
        $table.Dispose()
    }
    $sqlCalls=0
    function Invoke-LabSqlScript {param($ScriptPath,$HostName,$Port,$SaPassword,$Database,[switch]$KeepConnection) $script:sqlCalls++;[pscustomobject]@{Success=$true;Message='synthetic';Batches=1;Duration=[timespan]::Zero}}
    function Write-LabInfo {} function Write-LabSuccess {} function Write-LabError {}
    $secret=New-SyntheticSecret
    try {
        $null=Invoke-SqlServerLabScript -ScriptPath $sql -Port 1433 -SaPassword $secret
        $null=Invoke-SqlServerLabScript -ScriptPath $sql -Port 1433 -SaPassword $secret -WhatIf
        Check 'Existing SQL dispatch is preserved and WhatIf cannot execute it' ($sqlCalls -eq 1)
    } finally {$secret.Dispose()}
    Write-Host "Ergebnis: $passed PASS, 0 FAIL"
} finally {
    # Exact, unique test root under ignored repository artifacts.
    if(-not $directory.StartsWith((Join-Path $repoRoot '.artifacts/test-runs/'),[StringComparison]::OrdinalIgnoreCase)){throw 'STATIC_CLEANUP_ROOT_INVALID'}
    Remove-Item -LiteralPath $directory -Recurse -Force
}
