param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
& $Module {
    $sourceId = '11111111-1111-1111-1111-111111111111'
    $targetId = '22222222-2222-2222-2222-222222222222'
    $backupId = '33333333-3333-3333-3333-333333333333'
    $operationId = '44444444-4444-4444-4444-444444444444'
    $calls = [Collections.Generic.List[object]]::new()
    function Get-LabDataRootDefault { 'synthetic-lab-data' }
    function Get-LabContainerSqlConsoleTargets {
        [pscustomobject]@{RunId=$sourceId; InstanceId='primary'; Provider='docker'; Label='Source'}
        [pscustomobject]@{RunId=$targetId; InstanceId='other'; Provider='podman'; Label='Target'}
    }
    function Get-LabDatabaseBackupSelection {
        param($DataRoot)
        if ($DataRoot -ne 'synthetic-lab-data') { throw 'UNEXPECTED_DATA_ROOT' }
        [pscustomobject]@{BackupSetId=$backupId; Availability='SELECTABLE'; SourceSqlMajorVersion='17'; HasFileStream=$false; IsEncrypted=$false;
            DatabaseName='SourceDb'; SourceRunId=$sourceId; SourceInstanceId='primary'; SourceProvider='docker'; Bytes=128; CreatedAt='2026-01-01'}
        [pscustomobject]@{BackupSetId=$operationId; Availability='SELECTABLE'; SourceSqlMajorVersion='17'; HasFileStream=$false; IsEncrypted=$false;
            DatabaseName='WrongDb'; SourceRunId=$targetId; SourceInstanceId='primary'; SourceProvider='docker'; Bytes=128; CreatedAt='2026-01-01'}
    }
    function Select-LabConsoleDataItem {
        param($ScreenId, $Title, $Items)
        if ($Items.Count -ne 1) { throw 'CHOICES_NOT_BOUND' }
        return $Items[0].Data
    }
    function Read-LabConsoleTextInput {
        param($Prompt, $Default)
        [pscustomobject]@{Status='Confirmed'; Value=if ($Prompt -like 'Vorgangs-ID*') { $operationId } else { 'TargetDb' }}
    }
    $decisions = [Collections.Generic.Queue[bool]]::new()
    function Read-LabConfirm { param($Prompt, $Default) if ($Default) { throw 'UNSAFE_DEFAULT' }; $decisions.Dequeue() }
    function Wait-LabConsoleAcknowledgement { $null }
    function Write-LabError { param($Message) throw $Message }
    function Invoke-SqlServerLabPortableContainerTransferPreflight {
        [CmdletBinding(SupportsShouldProcess)]
        param($DataRoot, $SourceRunId, $SourceInstanceId, $TargetRunId, $TargetInstanceId, [object[]]$DatabaseTransfers)
        $calls.Add(@{RunId=$SourceRunId; TargetRunId=$TargetRunId; Transfer=$DatabaseTransfers[0]})
        [pscustomobject]@{Status='PASSED'; Blockers=@()}
    }
    function Invoke-SqlServerLabPortableContainerTransfer {
        [CmdletBinding(SupportsShouldProcess)]
        param($DataRoot, $SourceRunId, $SourceInstanceId, $SourceDatabaseName, $BackupSetId, $TargetDatabaseName, $OperationId)
        $calls.Add(@{RunId=$SourceRunId; BackupSetId=$BackupSetId; TargetDatabaseName=$TargetDatabaseName; OperationId=$OperationId})
        [pscustomobject]@{Status='SUCCEEDED'; Comparison='MATCH'; CleanupStatus='STAGE_CLEANED_TARGET_RETAINED'; TargetRunId=$targetId; FailureCode=$null}
    }
    $decisions.Enqueue($false); $decisions.Enqueue($true); $decisions.Enqueue($true)
    Invoke-LabMenuAction -ActionName PortableTransfer
    if ($calls.Count -ne 0) { throw 'DECLINED_TRANSFER_EXECUTED' }
    Invoke-LabMenuAction -ActionName PortableTransferPreflight
    Invoke-LabMenuAction -ActionName PortableTransfer
    if ($calls.Count -ne 2 -or $calls[0].RunId -ne $sourceId -or $calls[0].TargetRunId -ne $targetId -or
        $calls[0].Transfer.BackupSetId -ne $backupId -or $calls[1].RunId -ne $sourceId -or
        $calls[1].BackupSetId -ne $backupId -or $calls[1].TargetDatabaseName -ne 'TargetDb' -or
        [string]$calls[1].OperationId -ne $operationId) { throw 'TRANSFER_BINDING_MISMATCH' }
    Write-Host 'PASS: Geführte Medienvorprüfung und Transfer binden Backup, Quelle, Ziel und Vorgangs-ID.'
}
