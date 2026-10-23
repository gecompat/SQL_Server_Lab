$ErrorActionPreference='Stop';$repo=Join-Path $PSScriptRoot '../../..';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Public/Get-SqlServerLabWorkflow.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'PINNED_WORKFLOW_PARSE'}
$tables=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.HashtableAst]},$true));$values=@()
foreach($table in $tables){foreach($pair in $table.KeyValuePairs){if($pair.Item1.Extent.Text -ceq 'ContainerPinnedBuilds'){$values+=@($pair.Item2)}}}
if($values.Count -ne 1){throw 'PINNED_WORKFLOW_PROJECTION_MISSING'}
$projection=[scriptblock]::Create($values[0].Extent.Text)
function Get-SqlServerBuilds {param($VersionId)
 $cu=switch($VersionId){'2025'{'CU9'};'2022'{'CU27'};'2019'{'CU32'};default{throw 'UNSUPPORTED_MAJOR'}}
 @([pscustomobject]@{cu=$cu;tag=($VersionId+'-'+$cu+'-ubuntu')},[pscustomobject]@{cu='CU1';tag=($VersionId+'-CU2-ubuntu')},[pscustomobject]@{cu='latest';tag=($VersionId+'-latest')},[pscustomobject]@{cu=$cu;tag=('2017-'+$cu+'-ubuntu')},[pscustomobject]@{cu='CU999999999999';tag=($VersionId+'-CU999999999999-ubuntu')})
}
$rows=@(& $projection);if($rows.Count -ne 3 -or ($rows.VersionId -join '|') -cne '2025-CU9|2022-CU27|2019-CU32'){throw 'PINNED_WORKFLOW_WRONG_OR_UNCLOSED_CHOICES'}
foreach($row in $rows){if(($row.PSObject.Properties.Name|Sort-Object) -join '|' -cne 'Cu|VersionId'){throw 'PINNED_WORKFLOW_DTO_NOT_SCALAR_CLOSED'}}
@{Status='PASS';Cases=4;ActualWorkflowProjection=$true;ProviderActions=0}|ConvertTo-Json -Compress
