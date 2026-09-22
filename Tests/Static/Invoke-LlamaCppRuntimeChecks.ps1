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
    $npu=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $fixture -Accelerator NPU)
    Add-CheckResult 'NPU-Filter findet ausschließlich das OpenVINO-Paket' ($npu.Count -eq 1 -and $npu[0].Backend -eq 'LlamaCppOpenVino' -and $npu[0].SelectionEnvironment -eq 'GGML_OPENVINO_DEVICE')
    $duplicates=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot @($fixture,$npu[0].InstallationPath))
    Add-CheckResult 'Überlappende Suchwurzeln werden dedupliziert' ($duplicates.Count -eq 3)
    [IO.File]::WriteAllText((Join-Path $npu[0].InstallationPath 'ggml-cuda.dll'),'synthetic')
    $ambiguous=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $npu[0].InstallationPath)
    Add-CheckResult 'Mehrere Backends werden nicht still priorisiert' ($ambiguous[0].Backend -eq 'Ambiguous' -and $ambiguous[0].DetectedBackends.Count -eq 2 -and $null -eq $ambiguous[0].SelectionEnvironment)
    $deep=Join-Path $fixture 'parent/child';$null=New-Item -ItemType Directory -Path $deep -Force
    [IO.File]::WriteAllText((Join-Path $deep 'llama-server.exe'),'synthetic')
    Add-CheckResult 'Discovery durchsucht keine tieferen Verzeichnisse' (@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $fixture).Count -eq 3)
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
