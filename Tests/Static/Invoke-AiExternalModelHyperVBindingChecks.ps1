#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$runId='11111111-1111-4111-8111-111111111111'
$scopeId='22222222-2222-4222-8222-222222222222'
$vmId='33333333-3333-4333-8333-333333333333'
try {
    & $module {
        $script:aiHyperVBindingFixture=[ordered]@{
            RunState='RUNNING';ScopeId='22222222-2222-4222-8222-222222222222'
            Provider='hyperv';Version='2025';VMName='sql-ai-vm'
            VMId='33333333-3333-4333-8333-333333333333';VMState='Running'
        }
        function script:Get-LabRunState {
            [pscustomobject]@{state=$script:aiHyperVBindingFixture.RunState;scopeId=$script:aiHyperVBindingFixture.ScopeId}
        }
        function script:Resolve-LabRunInstance {
            [pscustomobject]@{
                Provider=$script:aiHyperVBindingFixture.Provider;Version=$script:aiHyperVBindingFixture.Version
                VMName=$script:aiHyperVBindingFixture.VMName;VMId=$script:aiHyperVBindingFixture.VMId
                HostName='192.0.2.10';Port=1433
            }
        }
        function script:Get-HyperVManagedVM {
            [pscustomobject]@{VM=[pscustomobject]@{Id=$script:aiHyperVBindingFixture.ManagedVMId;State=$script:aiHyperVBindingFixture.VMState}}
        }
        $script:aiHyperVBindingFixture.ManagedVMId=$script:aiHyperVBindingFixture.VMId
    }
    $binding=& $module {param($run,$state)Get-LabAiExternalModelSqlBinding -RunId $run -InstanceId primary -StateRoot $state} $runId 'synthetic-state'
    $identity=& $module {param($value)Get-LabAiExternalModelSqlBindingIdentity -Binding $value} $binding
    Add-CheckResult 'Hyper-V-SQL-Bindung führt Run-, Scope-, Instanz- und VM-Identität' (
        $binding.RunId -ceq $runId -and $binding.ScopeId -ceq $scopeId -and
        $binding.InstanceId -ceq 'primary' -and $binding.Provider -ceq 'hyperv' -and
        $binding.VMId -ceq $vmId -and $binding.VMName -ceq 'sql-ai-vm')
    Add-CheckResult 'Hyper-V-SQL-Bindungsidentität bindet VM und Endpunkt ohne Hostdaten' (
        $identity.VMId -ceq $vmId -and $identity.EndpointHash -match '^[a-f0-9]{64}$' -and
        -not $identity.PSObject.Properties['HostName'] -and -not $identity.PSObject.Properties['Port'])

    $hash='a'*64;$certificateHash='b'*64
    $endpointPlan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU `
        -Location 'https://192.0.2.1:18443/v1/embeddings' -ExternalModelName HyperVEmbedding `
        -RuntimeModel bound-model -Dimension 3 -ModelSha256 $hash -RuntimeSha256 $hash `
        -ServerCertificateSha256 $certificateHash
    $transport={param($request)$null=$request;[pscustomobject]@{StatusCode=200;ServerCertificateSha256=$certificateHash;Body=[pscustomobject]@{model='bound-model';data=@([pscustomobject]@{embedding=@(1.0,-0.25,0)})}}}.GetNewClosure()
    $endpointReceipt=& $module {param($plan,$probe)Invoke-LabAiExternalModelEndpointProbe -Plan $plan -Transport $probe} $endpointPlan $transport
    $sqlPlan=Get-SqlServerLabAiExternalModelSqlPlan -Plan $endpointPlan -EndpointReceipt $endpointReceipt -DatabaseName AiLab
    $databaseGuid='55555555-5555-4555-8555-555555555555'
    $executor={param($query,$parameters,$database)$null=$query;$null=$parameters;$null=$database;[pscustomobject]@{
        SqlMajorVersion=17;DatabaseId=5;DatabaseName='AiLab';DatabaseStatus='ONLINE';IsReadWrite=$true;DatabaseGuid=$databaseGuid
        HasDatabaseMasterKey=$true;HasControlDatabase=$true;HasCreateExternalModel=$true
        CredentialExists=$false;ExternalModelExists=$false;OwnershipTableExists=$false
    }}.GetNewClosure()
    $preflight=& $module {param($plan,$run,$sql,$binding,$bindingIdentity)Invoke-LabAiExternalModelSqlPreflight -SqlPlan $plan -RunId $run -SqlExecutor $sql -Binding $binding -BindingIdentity $bindingIdentity} $sqlPlan $runId $executor $binding $identity
    Add-CheckResult 'Hyper-V-SQL-Preflight-Receipt ist VM- und datenbankgebunden' (
        $preflight.VMId -ceq $vmId -and $preflight.DatabaseGuid -ceq $databaseGuid -and
        ($preflight|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-preflight-receipt.schema.json')))

    $journal=[pscustomobject][ordered]@{
        Contract='SqlServerLab.AiExternalModelSqlApplyJournal/1.0';OperationId='66666666-6666-4666-8666-666666666666';Status='APPLIED'
        SqlPlanKey=[string]$sqlPlan.SqlPlanKey;PreflightReceiptKey=[string]$preflight.ReceiptKey;BindingKey=[string]$preflight.BindingKey
        RunId=$runId;ScopeId=$scopeId;InstanceId='primary';Provider='hyperv';VMId=$vmId
        DatabaseName='AiLab';DatabaseGuid=$databaseGuid;OwnershipTableName=[string]$sqlPlan.OwnershipTableName
        ExternalModelName=[string]$sqlPlan.ExternalModelName;CredentialName=[string]$sqlPlan.CredentialName
        Recovery='NOT_REQUIRED';UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    $applyReceipt=& $module {param($value)New-LabAiExternalModelSqlApplyReceipt -Journal $value} $journal
    $resolvedApply=& $module {param($plan,$receipt,$run,$bindingIdentity,$value)Resolve-LabAiExternalModelSqlApplyReceipt -SqlPlan $plan -ApplyReceipt $receipt -RunId $run -InstanceId primary -BindingIdentity $bindingIdentity -Journal $value} $sqlPlan $applyReceipt $runId $identity $journal
    $embeddingReceipt=& $module {param($value,$receipt)New-LabAiExternalModelSqlEmbeddingReceipt -Journal $value -ApplyReceipt $receipt -Dimension 3 -BaseType float32} $journal $applyReceipt
    $cleanupReceipt=& $module {param($value,$receipt)New-LabAiExternalModelSqlCleanupReceipt -Journal $value -ApplyReceipt $receipt} $journal $applyReceipt
    Add-CheckResult 'Hyper-V-Apply-, Embedding- und Cleanup-Receipts behalten dieselbe VMId' (
        $resolvedApply.VMId -ceq $vmId -and $embeddingReceipt.VMId -ceq $vmId -and $cleanupReceipt.VMId -ceq $vmId -and
        ($journal|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-apply-journal.schema.json')) -and
        ($applyReceipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-apply-receipt.schema.json')) -and
        ($embeddingReceipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-embedding-receipt.schema.json')) -and
        ($cleanupReceipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-cleanup-receipt.schema.json')))

    $cases=@(
        @{Name='gestoppten Run';Property='RunState';Value='STOPPED';Code='AI_EXTERNAL_MODEL_SQL_RUN_NOT_RUNNING'},
        @{Name='SQL-Version vor 2025';Property='Version';Value='2022';Code='AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED'},
        @{Name='fehlende VMId';Property='VMId';Value='';Code='AI_EXTERNAL_MODEL_SQL_HYPERV_IDENTITY_REQUIRED'},
        @{Name='abweichende Live-VMId';Property='ManagedVMId';Value='44444444-4444-4444-8444-444444444444';Code='AI_EXTERNAL_MODEL_SQL_HYPERV_IDENTITY_MISMATCH'},
        @{Name='nicht laufende VM';Property='VMState';Value='Off';Code='AI_EXTERNAL_MODEL_SQL_HYPERV_VM_NOT_RUNNING'}
    )
    foreach($case in $cases){
        & $module {param($property,$value)$script:aiHyperVBindingFixture[$property]=$value} $case.Property $case.Value
        $actual=$null
        try{& $module {param($run,$state)Get-LabAiExternalModelSqlBinding -RunId $run -InstanceId primary -StateRoot $state} $runId 'synthetic-state'|Out-Null;$actual='NO_ERROR'}catch{$actual=$_.Exception.Message}
        Add-CheckResult "Hyper-V-SQL-Bindung blockiert $($case.Name)" ($actual -ceq $case.Code)
        & $module {
            $script:aiHyperVBindingFixture.RunState='RUNNING';$script:aiHyperVBindingFixture.Version='2025'
            $script:aiHyperVBindingFixture.VMId='33333333-3333-4333-8333-333333333333'
            $script:aiHyperVBindingFixture.ManagedVMId=$script:aiHyperVBindingFixture.VMId
            $script:aiHyperVBindingFixture.VMState='Running'
        }
    }
}
finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
Write-Host "`nAI external model Hyper-V binding checks: $passed passed, $($failures.Count) failed"
if($failures.Count){$failures|ForEach-Object{Write-Host " - $_" -ForegroundColor Red};exit 1}
