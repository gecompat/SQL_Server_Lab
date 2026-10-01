#Requires -Version 7.2
# Isolated filesystem-only worker. Private input travels over stdin, never argv or logs.
$ErrorActionPreference='Stop'
try {
    $inputText=[Console]::In.ReadToEnd()
    if ($inputText.Length -gt 32768) { throw 'INITIAL_SETUP_PROBE_INPUT_INVALID' }
    $payload=$inputText | ConvertFrom-Json -Depth 12
    if ($payload.Mode -cnotin @('Probe','Cleanup')) { throw 'INITIAL_SETUP_PROBE_INPUT_INVALID' }
    $module=Import-Module (Join-Path $PSScriptRoot '../SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
    $result=& $module { param($record,$mode) Invoke-LabSetupWriteProbeWorkerCore -Record $record -Mode $mode } $payload.Record $payload.Mode
    $result | ConvertTo-Json -Depth 8 -Compress
} catch {
    # Never publish native exception messages, input paths or environment values.
    [Console]::Error.WriteLine('INITIAL_SETUP_PROBE_WORKER_FAILED')
    exit 1
}
