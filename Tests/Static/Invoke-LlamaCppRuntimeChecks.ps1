#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SQL_SERVER_LAB_LLAMA_ROOT
try {
    $null=New-Item -ItemType Directory -Path $fixture
    foreach($entry in @(@('llama-b100-bin-test','ggml-openvino.dll'),@('llama-b101-bin-test','ggml-cuda.dll'),@('plain','none'))) {
        $dir=Join-Path $fixture $entry[0];$null=New-Item -ItemType Directory -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir 'llama-server.exe'),'synthetic-not-executable')
        if($entry[1] -ne 'none'){[IO.File]::WriteAllText((Join-Path $dir $entry[1]),'synthetic')}
    }
    $env:SQL_SERVER_LAB_LLAMA_ROOT=Join-Path $fixture 'missing'
    $r=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $fixture)
    Add-CheckResult 'Explizite Wurzeln isolieren Discovery von Prozessdefaults' ($r.Count -eq 3)
    Add-CheckResult 'Buildsortierung ist deterministisch, unbekannter Build folgt' ($r[0].Build -eq 101 -and $r[1].Build -eq 100 -and $null -eq $r[2].Build)
    Add-CheckResult 'Discovery benötigt weder ausführbare Fixture noch Hash' ($r[0].EvidenceStatus -eq 'FILES_ONLY' -and $r[0].PackageOrigin -eq 'UNVERIFIED')
    foreach($runtime in $r){Add-CheckResult 'Discovery ist schema-valide' ($runtime|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/llama-cpp-runtime.schema.json'))}
    $savedPath = $env:PATH
    try {
        $env:PATH = $fixture
        $env:SQL_SERVER_LAB_LLAMA_ROOT = $fixture
        $inventory = & $module { Get-LabLlamaCppRuntimeInventory }
        Add-CheckResult 'Geführte Übersicht projiziert die drei Dateifunde ohne Pfade' (
            $inventory.ScanStatus -ceq 'COMPLETED' -and $inventory.Items.Count -eq 3 -and
            $inventory.Items[0].Build -ceq '101' -and $null -eq $inventory.Items[2].Build -and
            ($inventory | ConvertTo-Json -Depth 4) -notmatch 'InstallationPath|Invocation|sql-lab-llama-')
        & $module {
            $request = [pscustomobject]@{
                HttpMethod = 'GET'
                Url = [uri]'http://127.0.0.1:19439/api/llama-runtime-inventory'
                HasEntityBody = $false
            }
            $received = Invoke-LabLlamaCppRuntimeInventoryHttpRequest -Request $request
            if ($received.Items.Count -ne 3 -or $received.EvidenceStatus -cne 'FILES_ONLY') { throw 'HTTP_INVENTORY_RESULT_INVALID' }
            foreach ($invalid in @(
                @{ HttpMethod = 'POST' }
                @{ Url = [uri]'http://127.0.0.1:19439/api/llama-runtime-inventory?path=other' }
                @{ HasEntityBody = $true }
            )) {
                $invalidRequest = $request.PSObject.Copy()
                foreach ($name in $invalid.Keys) { $invalidRequest.$name = $invalid[$name] }
                try {
                    $null = Invoke-LabLlamaCppRuntimeInventoryHttpRequest -Request $invalidRequest
                    throw 'HTTP_INVENTORY_INVALID_INPUT_ACCEPTED'
                }
                catch {
                    if ($_.Exception.Message -cne 'LLAMA_RUNTIME_INVENTORY_REQUEST_INVALID') { throw }
                }
            }
        }
        Add-CheckResult 'HTTP akzeptiert ausschließlich GET ohne zusätzliche Eingaben' $true
        $cliLines = & $module {
            function Write-LabInfo { param([string]$Message) $Message }
            function Wait-LabConsoleAcknowledgement {}
            Invoke-LabMenuAction -ActionName LlamaRuntimeInventory
        }
        Add-CheckResult 'Menüdispatch zeigt Backend und Build ohne Paketpfad' (
            ($cliLines -join ' ') -match 'LlamaCppCuda · Build 101' -and
            ($cliLines -join ' ') -notmatch 'sql-lab-llama-')
        $env:SQL_SERVER_LAB_LLAMA_ROOT = Join-Path $fixture 'missing'
        $partial = & $module { Get-LabLlamaCppRuntimeInventory }
        Add-CheckResult 'Unlesbare Suchwurzel ergibt PARTIAL auch ohne Treffer' (
            $partial.ScanStatus -ceq 'PARTIAL' -and $partial.Items.Count -eq 0)
    }
    finally {
        $env:PATH = $savedPath
        $env:SQL_SERVER_LAB_LLAMA_ROOT = Join-Path $fixture 'missing'
    }
    $npu=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $fixture -Accelerator NPU)
    Add-CheckResult 'NPU-Filter findet ausschließlich das OpenVINO-Paket' ($npu.Count -eq 1 -and $npu[0].Backend -eq 'LlamaCppOpenVino' -and $npu[0].SelectionEnvironment -eq 'GGML_OPENVINO_DEVICE')
    $duplicates=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot @($fixture,$npu[0].InstallationPath))
    Add-CheckResult 'Überlappende Suchwurzeln werden dedupliziert' ($duplicates.Count -eq 3)
    [IO.File]::WriteAllText((Join-Path $npu[0].InstallationPath 'ggml-cuda.dll'),'synthetic')
    $ambiguous=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $npu[0].InstallationPath)
    Add-CheckResult 'Mehrere Backends werden nicht still priorisiert' ($ambiguous[0].Backend -eq 'Ambiguous' -and $ambiguous[0].DetectedBackends.Count -eq 2 -and $null -eq $ambiguous[0].SelectionEnvironment)
    $linux=Join-Path $fixture 'llama-b102-bin-linux';$null=New-Item -ItemType Directory -Path $linux
    [IO.File]::WriteAllText((Join-Path $linux 'llama-server'),'synthetic');[IO.File]::WriteAllText((Join-Path $linux 'libggml-hip.so.1'),'synthetic')
    $linuxRuntime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $linux)
    Add-CheckResult 'Linux-Paketnamen erkennen ROCm ohne Ausführung' ($linuxRuntime.Count -eq 1 -and $linuxRuntime[0].Backend -eq 'LlamaCppRocm' -and $linuxRuntime[0].Invocation -like '*llama-server')
    $deep=Join-Path $fixture 'parent/child';$null=New-Item -ItemType Directory -Path $deep -Force
    [IO.File]::WriteAllText((Join-Path $deep 'llama-server.exe'),'synthetic')
    Add-CheckResult 'Discovery durchsucht keine tieferen Verzeichnisse' (@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $fixture).Count -eq 4)
    $warnings=@();$missing=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot (Join-Path $fixture 'absent') -WarningVariable warnings -WarningAction SilentlyContinue)
    Add-CheckResult 'Unlesbare Wurzel bleibt sichtbar und liefert keine Erfindung' ($missing.Count -eq 0 -and $warnings.Count -eq 1)
    $code='';try{Get-SqlServerLabLlamaCppRuntime -SearchRoot ([IO.Path]::GetPathRoot($fixture))|Out-Null}catch{$code=$_.Exception.Message}
    Add-CheckResult 'Laufwerkswurzel wird abgewiesen' ($code -eq 'LLAMA_DISCOVERY_DRIVE_ROOT_REJECTED')
    $crowded=Join-Path $fixture 'crowded';$null=New-Item -ItemType Directory -Path $crowded
    1..257|ForEach-Object{$null=New-Item -ItemType Directory -Path (Join-Path $crowded "d$_")}
    $code='';try{Get-SqlServerLabLlamaCppRuntime -SearchRoot $crowded|Out-Null}catch{$code=$_.Exception.Message}
    Add-CheckResult 'Zu breite Wurzel bricht ab statt unvollständige Discovery zu behaupten' ($code -eq 'LLAMA_DISCOVERY_ROOT_LIMIT_EXCEEDED')
}
finally {
    $env:SQL_SERVER_LAB_LLAMA_ROOT=$oldRoot
    if((Split-Path $fixture -Parent) -eq [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -and (Split-Path $fixture -Leaf) -like 'sql-lab-llama-*') {Remove-Item -LiteralPath $fixture -Recurse -Force}
}
if($failures.Count){throw "$($failures.Count) llama.cpp-Discovery-Prüfungen fehlgeschlagen: $($failures -join '; ')"}
Write-Host "LLAMA DISCOVERY: PASS ($passed), CLEANUP_SUCCEEDED"
