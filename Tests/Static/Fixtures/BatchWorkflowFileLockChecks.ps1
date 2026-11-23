[CmdletBinding()]
param([string]$ModulePath, [string]$Root)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $Root
$operation = [pscustomobject]@{ operationId = 'file-lock-proof'; status = 'Queued'; updatedAt = $null }
$path = & $module { param($op, $dir)
    $null = Initialize-LabWorkflowStore -StateRoot $dir
    $null = Write-LabOperationState -Operation $op -StateRoot $dir
    Get-LabOperationStatePath -OperationId $op.operationId -StateRoot $dir
} $operation $Root
$readerReady = Join-Path $Root 'reader-holding'
$writerReady = Join-Path $Root 'writer-entered'
$release = Join-Path $Root 'release-reader'
$reader = $null
$writer = $null
try {
    $reader = Start-ThreadJob -ArgumentList $ModulePath, $path, $readerReady, $release -ScriptBlock {
        param($Manifest, $TestPath, $ReaderReady, $ReleaseReader)
        $ErrorActionPreference = 'Stop'
        $lab = Import-Module $Manifest -Force -PassThru
        & $lab { param($ExpectedPath, $Ready, $Release)
            function Get-Content {
                param($LiteralPath,[switch]$Raw,$Encoding,$ErrorAction)
                if ($LiteralPath -cne $ExpectedPath) { throw 'WORKFLOW_FILE_TEST_UNBOUND_READER' }
                $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                $reader = [IO.StreamReader]::new($stream)
                try {
                    [IO.File]::WriteAllText($Ready, '')
                    $deadline = [DateTime]::UtcNow.AddSeconds(25)
                    while (-not [IO.File]::Exists($Release)) {
                        if ([DateTime]::UtcNow -ge $deadline) { throw 'WORKFLOW_FILE_TEST_RELEASE_TIMEOUT' }
                        Start-Sleep -Milliseconds 25
                    }
                    $reader.ReadToEnd()
                }
                finally { $reader.Dispose() }
            }
            Read-LabWorkflowJson -Path $ExpectedPath
        } $TestPath $ReaderReady $ReleaseReader
    }
    Assert-Check (Wait-TestFile -Path $readerReady) 'Workflow-Dateileser erreichte die Halteposition nicht.'
    $operation.status = 'Completed'
    $writer = Start-ThreadJob -ArgumentList $ModulePath, $Root, $operation, $writerReady -ScriptBlock {
        param($Manifest, $TestRoot, $Operation, $WriterReady)
        $ErrorActionPreference = 'Stop'
        $lab = Import-Module $Manifest -Force -PassThru
        [IO.File]::WriteAllText($WriterReady, '')
        & $lab { param($Item, $Dir) Write-LabOperationState -Operation $Item -StateRoot $Dir } $Operation $TestRoot
    }
    Assert-Check (Wait-TestFile -Path $writerReady -TimeoutSeconds 20) 'Workflow-Dateischreiber erreichte die Halteposition nicht.'
    $null = Wait-Job -Job $writer -Timeout 1
    Assert-Check ($writer.State -eq 'Running') 'Workflow-Dateischreiber wartete nicht auf den lesenden Dateihandle.'
    [IO.File]::WriteAllText($release, '')
    $null = Wait-Job -Job @($reader,$writer) -Timeout 30
    Assert-Check ($reader.State -eq 'Completed' -and $writer.State -eq 'Completed') 'Workflow-Dateitransaktion blieb unbestätigt.'
    $before = Receive-Job -Job $reader -ErrorAction Stop
    $after = Receive-Job -Job $writer -ErrorAction Stop
    $persisted = & $module { param($File) Read-LabWorkflowJson -Path $File } $path
    Assert-Check ($before.status -ceq 'Queued' -and $after.status -ceq 'Completed' -and $persisted.status -ceq 'Completed') 'Workflow-Reader oder -Writer sah keine vollständige Dateiversion.'
}
finally {
    [IO.File]::WriteAllText($release, '')
    foreach ($job in @($reader,$writer)) { if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } }
}
