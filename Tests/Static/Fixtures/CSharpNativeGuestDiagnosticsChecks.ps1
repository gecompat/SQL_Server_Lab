# Actual guest helper AST, synthetic messages/files only; never connects to SQL.
& {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'),[ref]$null,[ref]$null)
    & {
        # Execute the real registration branch with only its SQL transport substituted.
        $register=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$Stage -eq ''Register'''},$true)
        $body=($register.Clauses[0].Item2.Statements|ForEach-Object {$_.Extent.Text}) -join "`n"
        $Root='C:\synthetic-csharp';$queries=[Collections.Generic.List[string]]::new()
        $connection=[pscustomobject]@{Database='master'}
        $connection|Add-Member ScriptMethod ChangeDatabase {param($Name)$this.Database=$Name}
        function Invoke-ProbeSql {param([string]$Sql)$queries.Add($Sql);return 0}
        $result=& ([scriptblock]::Create($body))
        $language=@($queries|Where-Object {$_ -like 'CREATE EXTERNAL LANGUAGE*'})
        $json=[regex]::Match($language[0],"ENVIRONMENT_VARIABLES=N'([^']+)'").Groups[1].Value|ConvertFrom-Json
        Add-CheckResult -Name 'CSharp host diagnostics: real registration enables only language-scoped COREHOST_TRACE' -Success ($result -ceq 'CSHARP_NATIVE_REGISTERED' -and $connection.Database -ceq 'CSharpAcceptance' -and $language.Count -eq 1 -and @($json.PSObject.Properties).Count -eq 1 -and $json.COREHOST_TRACE -ceq '1')
        Add-CheckResult -Name 'CSharp host diagnostics: registration preserves package and library identity without trace file' -Success ($language[0].Contains("CONTENT=N'$Root\extension.zip',FILE_NAME='nativecsharpextension.dll'") -and $queries[3] -ceq "CREATE EXTERNAL LIBRARY [SqlServerLab.CSharpProbe] FROM (CONTENT=N'$Root\SqlServerLab.CSharpProbe.dll') WITH (LANGUAGE=N'dotnet');" -and $body -notmatch 'TRACEFILE|SetEnvironmentVariable|icacls')
        $queries.Clear()
        function Invoke-ProbeSql {param([string]$Sql)$queries.Add($Sql);return 1}
        $caught='';try{& ([scriptblock]::Create($body))}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp host diagnostics: actual existing-database guard still blocks all registration writes' -Success ($caught -ceq 'CSHARP_NATIVE_DATABASE_EXISTS' -and $queries.Count -eq 1 -and $queries[0] -like 'SELECT COUNT(*)*')
    }
    foreach($name in @('New-CSharpGuestSqlInfoCollector','Add-CSharpGuestSqlMessages','Save-CSharpGuestSqlFailure','Read-CSharpGuestLogTail','Get-CSharpGuestDiagnostics','Invoke-ProbeSql')){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $info=[Collections.Generic.List[object]]::new()
    $messages=@(1..20|ForEach-Object {[pscustomobject]@{Number=$_;State=1;Class=10;LineNumber=2;Procedure=('p'*200);Message=('synthetic private '+('x'*3000))}})
    Add-CSharpGuestSqlMessages $info $messages
    Add-CheckResult -Name 'CSharp guest diagnostics: actual collector caps message count and field lengths' -Success ($info.Count -eq 8 -and $info[0].Message.Length -eq 2048 -and $info[0].Procedure.Length -eq 128)
    $collection=[Activator]::CreateInstance([Data.SqlClient.SqlErrorCollection],$true)
    $constructor=[Data.SqlClient.SqlError].GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')|Where-Object {$_.GetParameters().Count -eq 8}|Select-Object -First 1
    foreach($number in @(39019,51000)){
        $errorItem=$constructor.Invoke(@([int]$number,[byte]1,[byte]16,'synthetic','synthetic private SQL error','syntheticProc',[int]9,$null))
        $null=$collection.GetType().GetMethod('Add',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($collection,@($errorItem))
    }
    $factory=[Data.SqlClient.SqlException].GetMethods([Reflection.BindingFlags]'Static,NonPublic')|Where-Object {$_.Name -eq 'CreateException' -and $_.GetParameters().Count -eq 2}|Select-Object -First 1
    $exception=$factory.Invoke($null,@($collection,'synthetic'))
    $path=Join-Path $nativeRoot 'synthetic-sql-failure.json'
    try{throw [InvalidOperationException]::new('synthetic wrapper',$exception)}catch{Save-CSharpGuestSqlFailure -Failure $_ -Info $info -Path $path}
    $saved=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    Add-CheckResult -Name 'CSharp guest diagnostics: real SqlException collection retained through wrapper' -Success ($saved.Errors.Count -eq 2 -and $saved.Errors[0].Number -eq 39019 -and $saved.Errors[1].Number -eq 51000 -and $saved.InfoMessages.Count -eq 8)
    $script:diagnosticSqlException=$exception
    $script:diagnosticInfoArgs=[Activator]::CreateInstance([Data.SqlClient.SqlInfoMessageEventArgs],[Reflection.BindingFlags]'Instance,NonPublic',$null,@($exception),$null)
    $threadSource=@'
using System;
using System.Data.SqlClient;
using System.Threading;
public static class CSharpDiagnosticCallbackTest {
    public static bool Run(SqlInfoMessageEventHandler handler, SqlInfoMessageEventArgs args) {
        Exception failure = null; int actual = 0;
        int caller = Thread.CurrentThread.ManagedThreadId;
        Thread thread = new Thread(() => {
            try { actual = Thread.CurrentThread.ManagedThreadId; for (int i=0;i<20;i++) handler(null,args); }
            catch (Exception ex) { failure = ex; }
        });
        thread.IsBackground = true; thread.Start();
        if (!thread.Join(5000)) throw new Exception("SYNTHETIC_CALLBACK_TIMEOUT");
        if (failure != null) throw new Exception("SYNTHETIC_CALLBACK_FAILED",failure);
        return actual != caller;
    }
}
'@
    $references=@([Data.SqlClient.SqlError].Assembly.Location);$options=@{}
    if($PSVersionTable.PSEdition -eq 'Core'){$references+=@('System.Runtime.dll','System.Collections.dll','System.Threading.dll','System.Threading.Thread.dll');$options.CompilerOptions='/nowarn:1701,0618'}
    Add-Type -TypeDefinition $threadSource -ReferencedAssemblies $references @options
    $collector=New-CSharpGuestSqlInfoCollector
    $differentThread=[CSharpDiagnosticCallbackTest]::Run($collector.Handler,$script:diagnosticInfoArgs)
    Add-CheckResult -Name 'CSharp guest diagnostics: compiled callback runs on foreign .NET thread without runspace and caps eight' -Success ($differentThread -and $collector.Snapshot().Count -eq 8)
    $script:diagnosticConnection=[pscustomobject]@{Handler=$null;Disposed=$false}
    $script:diagnosticConnection|Add-Member ScriptMethod add_InfoMessage {param($Handler)$this.Handler=$Handler}
    $script:diagnosticConnection|Add-Member ScriptMethod remove_InfoMessage {param($Handler)$this.Handler=$null}
    $script:diagnosticConnection|Add-Member ScriptMethod CreateCommand {
        $cmd=[pscustomobject]@{CommandText='';CommandTimeout=0}
        $cmd|Add-Member ScriptMethod ExecuteScalar {$script:diagnosticConnection.Handler.Invoke($null,$script:diagnosticInfoArgs);throw $script:diagnosticSqlException}
        $cmd|Add-Member ScriptMethod Dispose {$script:diagnosticConnection.Disposed=$true}
        return $cmd
    }
    $connection=$script:diagnosticConnection;$Stage='Probe';$Root=Join-Path $nativeRoot 'sql-command';$null=[IO.Directory]::CreateDirectory($Root)
    $caught=$null;try{Invoke-ProbeSql 'synthetic statement'}catch{$caught=$_}
    $saved=Get-Content -LiteralPath (Join-Path $Root 'sql-failure.json') -Raw|ConvertFrom-Json
    Add-CheckResult -Name 'CSharp guest diagnostics: actual command catch captures InfoMessage and SQL errors, removes handler' -Success ($caught -and $saved.Errors.Count -eq 2 -and $saved.InfoMessages.Count -eq 2 -and $connection.Handler -eq $null -and $connection.Disposed)
    & {
        function Get-ItemProperty {param($LiteralPath,$ErrorAction)throw 'synthetic unavailable registry'}
        $diagnostic=Get-CSharpGuestDiagnostics $Root
        Add-CheckResult -Name 'CSharp guest diagnostics: actual bounded saved JSON reader and unavailable instance logs' -Success ($diagnostic.Sql.Errors.Count -eq 2 -and $diagnostic.Logs.Count -eq 1 -and $diagnostic.Logs[0].Status -ceq 'UNAVAILABLE')
        [IO.File]::WriteAllText((Join-Path $Root 'sql-failure.json'),('x'*262145))
        $diagnostic=Get-CSharpGuestDiagnostics $Root
        Add-CheckResult -Name 'CSharp guest diagnostics: oversized saved JSON rejected before parsing' -Success ($diagnostic.Sql.Status -ceq 'UNAVAILABLE')
    }
    & {
        function Save-CSharpGuestSqlFailure {param($Failure,$Info,$Path)throw 'synthetic diagnostic write failed'}
        $caught=$null;try{Invoke-ProbeSql 'synthetic statement'}catch{$caught=$_}
        $original=$caught.Exception
        while($original.InnerException){$original=$original.InnerException}
        Add-CheckResult -Name 'CSharp guest diagnostics: failed diagnostic writer preserves original SqlException' -Success ($original -is [Data.SqlClient.SqlException] -and $original.Number -eq 39019 -and $connection.Handler -eq $null)
    }
    Remove-Variable diagnosticSqlException,diagnosticInfoArgs,diagnosticConnection -Scope Script
    $log=Join-Path $nativeRoot 'synthetic-errorlog';[IO.File]::WriteAllBytes($log,[byte[]](0..255)*200)
    if($IsWindows){
        $tail=Read-CSharpGuestLogTail $log 'ERRORLOG'
        Add-CheckResult -Name 'CSharp guest diagnostics: real tail bounded to 32KiB and exact suffix' -Success ($tail.Status -ceq 'AVAILABLE' -and $tail.Bytes -eq 32768 -and $tail.Offset -eq 18432 -and [Convert]::FromBase64String($tail.TailBase64)[32767] -eq 255)
    }else{Write-Host '  NOT_EXECUTED  CSharp guest diagnostics: Windows guest path tail requires Windows'}
    $missing=Read-CSharpGuestLogTail (Join-Path $nativeRoot 'absent') 'ERRORLOG'
    Add-CheckResult -Name 'CSharp guest diagnostics: unavailable file yields fixed status without path' -Success ($missing.Status -ceq 'UNAVAILABLE' -and ($missing|ConvertTo-Json) -notmatch [regex]::Escape($nativeRoot))
}
& {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpHyperVAcceptanceWorker.ps1'),[ref]$null,[ref]$null)
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-OwnGuest'},$true)
    . ([scriptblock]::Create($node.Extent.Text))
    $owned=[pscustomobject]@{VMName='synthetic';RunId='synthetic';ScopeId='synthetic';VMId=[guid]::NewGuid().ToString()}
    $credential=$null;$guestScript={};$guestRoot='synthetic';$plan=@{};$sa=$null
    foreach($diagnosticFailure in @($false,$true)){
        $module=New-Module -ArgumentList $diagnosticFailure -ScriptBlock {
            param($Fail)
            $script:Fail=$Fail;$script:Calls=[Collections.Generic.List[object]]::new()
            function Invoke-HyperVPowerShellDirect {
                param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$ScriptBlock,$ArgumentList,$TimeoutSeconds)
                $script:Calls.Add([pscustomobject]@{Stage=$ArgumentList[0];Timeout=$TimeoutSeconds;Bound=[bool]$ExpectedVmId})
                if($ArgumentList[0] -eq 'Probe'){throw 'SYNTHETIC_ORIGINAL_SQL_FAILURE'}
                if($script:Fail){throw 'synthetic private diagnostic failure'}
                [pscustomobject]@{Status='CSHARP_GUEST_DIAGNOSTICS';Message='synthetic private local detail'}
            }
        }
        $prior=[Console]::Error;$writer=[IO.StringWriter]::new();$caught=''
        try{[Console]::SetError($writer);try{Invoke-OwnGuest Probe}catch{$caught=$_.Exception.Message}}finally{[Console]::SetError($prior)}
        $calls=& $module {$script:Calls.ToArray()}
        Add-CheckResult -Name ('CSharp guest diagnostics: actual worker preserves original failure; collector fails='+$diagnosticFailure) -Success ($caught -ceq 'SYNTHETIC_ORIGINAL_SQL_FAILURE' -and $calls.Count -eq 2 -and $calls[1].Stage -ceq 'Diagnostics' -and $calls[1].Timeout -eq 30 -and $calls[1].Bound -and $(if($diagnosticFailure){$writer.ToString().Trim() -ceq 'CSHARP_NATIVE_GUEST_DIAGNOSTICS_UNAVAILABLE'}else{$writer.ToString().Contains('synthetic private local detail')}))
        $writer.Dispose();Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
}
$sql=Get-Content (Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/probe.sql') -Raw
Add-CheckResult -Name 'CSharp guest diagnostics: SQL rethrows external error before unchanged strict assertions' -Success ($sql -match '(?s)BEGIN TRY\s+INSERT INTO @actual.*sp_execute_external_script.*END TRY\s+BEGIN CATCH\s+THROW;\s+END CATCH;\s+IF \(SELECT COUNT\(\*\) FROM @actual\) <> 3' -and $sql.Contains('(-7,-14),(0,0),(21,42)') -and $sql.Contains('appContainer<>1') -and $sql.Contains('runtimeMajor<>8'))
