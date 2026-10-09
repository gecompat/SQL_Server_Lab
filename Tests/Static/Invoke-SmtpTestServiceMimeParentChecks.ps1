#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Beide Fixtures verwenden ausschließlich synthetisches MIME und eigene Pythonkinder.
# Der vorhandene Bytetransport begrenzt den 63-Fall-Prozess auf zehn Sekunden
# plus unabhängige fünf Sekunden Wait und fünf Sekunden Drain.
. (Join-Path $repoRoot 'Private/SmtpTestServiceMimeProcess.ps1')
$expectedCases=@(
    'M01_ASCII_DEFAULT','M02_UTF8_BODY','M03_HEADER_BASE64','M04_HEADER_QP',
    'M05_UTF8_HEADER_NAMES','M06_FOLD_ADJACENT','M07_GROUP_ADDRESS','M08_MISSING_HEADERS',
    'M09_ALTERNATIVE_PREFERS_LAST_PLAIN','M10_HTML_SOURCE','M11_RELATED_ROOT','M12_MIXED_ATTACHMENT_FIRST',
    'M13_INLINE_FILENAME_EXCLUDED','M14_EMPTY_BODY','M15_MESSAGE_ATTACHMENT_EXCLUDED','M16_RAW_IDENTITY_AND_INDEPENDENT_QUOTA',
    'M17_DUPLICATE_HEADER','M18_INVALID_UTF8_HEADER','M19_UNSUPPORTED_CHARSET','M20_NONASCII_ADDRESS',
    'M21_UNSUPPORTED_CTE','M22_STRICT_BASE64_BAD_PADDING','M23_BASE64_INVALID_SUFFIX','M24_STRICT_HEADER_B64_PADDING',
    'M25_QP_DANGLING','M26_QP_INVALID_HEX','M27_VALID_QP_AND_BODY_UNDERSCORE','M28_INVALID_CONTENT_TYPE',
    'M29_MISSING_BOUNDARY','M30_RELATED_START_MISSING','M31_SELECTED_ERROR_NO_HTML_FALLBACK','M32_BINARY_CONTROLS',
    'M33_UTF8_INVALID_BODY','M34_BODY_BOUNDARY','M35_FACTORY_BOUNDARY','M36_DEPTH_BOUNDARY',
    'M37_ROOT_FIELD_BOUNDARY','M38_LINE_BOUNDARY','M39_HEADER_VALUE_BOUNDARY','M40_JSON_ESCAPING_OVERFLOW',
    'M41_INPUT_OVERFLOW','M42_RAW_OVERFLOW','M43_UNSUPPORTED_MULTIPART_EXPLICIT','M44_CLI_FIXED_ERROR_CANARY_ABSENT',
    'M45_CLI_RAW_IDENTITY','M46_CLI_NO_ARG_CONTENT','M47_COOPERATIVE_DEADLINE','M48_IMPORT_NO_APPLICATION_IO',
    'M49_NO_EXTERNAL_ACTIONS_AST','M50_VALID_BASE64','M51_LINE_COUNT_BOUNDARY','M52_INPUT_EXACT_BOUNDARY',
    'M53_RAW_EXACT_BOUNDARY','M54_PART_HEADER_BYTES_BOUNDARY','M55_PART_HEADER_FIELDS_BOUNDARY','M56_TOTAL_FIELDS_BOUNDARY',
    'M57_TOTAL_HEADER_BYTES_REFUSAL','M58_ADDRESS_COUNTS','M59_UTF8_OUTPUT_EXPANSION_REFUSAL','M60_READ_BUFFER_FINALLY_OBSERVED',
    'M61_LITERAL_REPLACEMENT_SCALAR','M62_DUPLICATE_STRUCTURAL_HEADER','M63_NO_INPUT_IO'
)
function Read-MimeCheckFrame {
    param([string]$Line,[string[]]$Keys)
    if($Line.Length -eq 0 -or $Line.Length -gt 2048){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
    $doc=$null
    try {
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=3
        $doc=[Text.Json.JsonDocument]::Parse($Line,$options)
        if($doc.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $values=@{}
        foreach($property in $doc.RootElement.EnumerateObject()){
            if(-not $names.Add($property.Name) -or $property.Name -cnotin $Keys){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
            $values[$property.Name]=$property.Value.Clone()
        }
        if($names.Count -ne $Keys.Count){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
        return $values
    } finally {if($null -ne $doc){$doc.Dispose()}}
}
$inputBuffer=[byte[]]::new(0);$output=$null;$start=$null;$originalPath=$env:PATH
$sourcePaths=@('Private/SmtpTestServiceMimeProcess.ps1','Tools/SmtpTestServiceMime.py',
    'Tests/Static/Fixtures/SmtpTestServiceMimeChecks.py','Tests/Static/Fixtures/SmtpTestServiceMimeParentChecks.ps1',
    'Tests/Static/Invoke-SmtpTestServiceMimeParentChecks.ps1','Tools/Initialize-SqlServerLabHostTools.ps1','Private/HostToolResolution.ps1')
$before=@{}
try {
    foreach($path in $sourcePaths){$before[$path]=(Get-FileHash -LiteralPath (Join-Path $repoRoot $path) -Algorithm SHA256).Hash}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name python)
    if($resolution.Count -ne 1 -or $resolution[0].Available -isnot [bool] -or -not $resolution[0].Available -or
        $resolution[0].Invocation -isnot [string] -or -not [IO.Path]::IsPathRooted($resolution[0].Invocation)){
        throw 'SMTP_MIME_RUNTIME_UNAVAILABLE'
    }
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$resolution[0].Invocation;$start.WorkingDirectory=$repoRoot
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Environment.Clear()
    foreach($name in @('SystemRoot','WINDIR','ComSpec')){
        $value=[Environment]::GetEnvironmentVariable($name)
        if($null -ne $value){$start.Environment[$name]=$value}
    }
    foreach($argument in @('-I','-B',(Join-Path $PSScriptRoot 'Fixtures/SmtpTestServiceMimeChecks.py'))){$start.ArgumentList.Add($argument)}
    $output=Invoke-LabSmtpMimeByteProcess $start $inputBuffer 16384
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($output)
    # Eine optionale abschließende LF/CRLF ist Framing, kein Inhalts-Trim.
    $lines=$text.Split([char]10)
    if($lines[-1] -ceq ''){$lines=$lines[0..($lines.Count-2)]}
    if($lines.Count -ne 64){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
    for($index=0;$index -lt 63;$index++){
        $line=$lines[$index];if($line.EndsWith("`r",[StringComparison]::Ordinal)){$line=$line.Substring(0,$line.Length-1)}
        $row=Read-MimeCheckFrame $line @('Case','Status')
        if($row.Case.ValueKind -ne [Text.Json.JsonValueKind]::String -or $row.Status.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            -not [string]::Equals($row.Case.GetString(),$expectedCases[$index],[StringComparison]::Ordinal) -or
            -not [string]::Equals($row.Status.GetString(),'PASS',[StringComparison]::Ordinal)){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
    }
    $last=$lines[63];if($last.EndsWith("`r",[StringComparison]::Ordinal)){$last=$last.Substring(0,$last.Length-1)}
    $summary=Read-MimeCheckFrame $last @('Passed','Failed','Inventory','SourceStable','Python')
    foreach($pair in @(@('Passed',63),@('Failed',0),@('Inventory',63))){
        $number=0;$field=$summary[$pair[0]]
        if($field.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $field.TryGetInt32([ref]$number) -or $number -ne $pair[1]){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
    }
    if($summary.SourceStable.ValueKind -ne [Text.Json.JsonValueKind]::True -or $summary.Python.ValueKind -ne [Text.Json.JsonValueKind]::String -or
        $summary.Python.GetString() -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[a-zA-Z0-9.]+)?$'){throw 'SMTP_MIME_CHECK_DTO_INVALID'}
    foreach($path in $sourcePaths){if((Get-FileHash -LiteralPath (Join-Path $repoRoot $path) -Algorithm SHA256).Hash -cne $before[$path]){throw 'SMTP_MIME_CHECK_SOURCE_CHANGED'}}
    Write-Host 'SMTP MIME Python: PASS (63/63)'
} catch {
    # Keine Pythonantwort, Inhalte oder rohe Exception als Diagnostik veröffentlichen.
    Write-Host 'SMTP MIME Python: FAIL' -ForegroundColor Red
    exit 1
} finally {
    $env:PATH=$originalPath
    if($null -ne $output){[Array]::Clear($output,0,$output.Length)}
    # Der Bytetransport besitzt alle eventuell noch laufenden IO-Referenzen.
    $text=$null;$lines=$null;$row=$null;$summary=$null;$start=$null
}
& (Join-Path $PSScriptRoot 'Fixtures/SmtpTestServiceMimeParentChecks.ps1') -RepoRoot $repoRoot
$parentExit=$LASTEXITCODE
try {
    foreach($path in $sourcePaths){if((Get-FileHash -LiteralPath (Join-Path $repoRoot $path) -Algorithm SHA256).Hash -cne $before[$path]){throw 'SMTP_MIME_CHECK_SOURCE_CHANGED'}}
} catch {Write-Host 'SMTP MIME Paketquellen: FAIL' -ForegroundColor Red;exit 1}
exit $parentExit
