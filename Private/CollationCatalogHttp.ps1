# Read-only catalogue search; no SQL verification or state mutation.
function Assert-LabCollationHttpShape {
    param($Value,[string[]]$Names)
    if($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or @($Value.PSObject.Properties.Name|Where-Object {$_ -cnotin $Names}).Count){throw 'COLLATION_HTTP_RESULT_INVALID'}
}
function Assert-LabCollationHttpRow {
    param($Value,[string]$SqlVersion)
    Assert-LabCollationHttpShape $Value @('Name','Locale','CodePage','Lcid','CaseSensitivity','AccentSensitivity','Utf8','Status','SqlVersion')
    if($Value.Name -isnot [string] -or $Value.Name -cnotmatch '^[A-Za-z0-9_]{1,128}$' -or
        $Value.Locale -isnot [string] -or [string]::IsNullOrWhiteSpace($Value.Locale) -or $Value.Locale.Length -gt 256 -or $Value.Locale -match '\p{Cc}' -or
        $Value.CodePage -isnot [int] -or $Value.CodePage -lt 0 -or $Value.Lcid -isnot [int] -or $Value.Lcid -lt 0 -or
        $Value.CaseSensitivity -isnot [string] -or $Value.CaseSensitivity -cnotin @('CI','CS','BIN','BIN2') -or
        $Value.AccentSensitivity -isnot [string] -or $Value.AccentSensitivity -cnotin @('AI','AS','NOT_APPLICABLE') -or
        $Value.Utf8 -isnot [bool] -or $Value.Status -isnot [string] -or $Value.Status -cnotin @('SUPPORTED','DEPRECATED') -or
        $Value.SqlVersion -isnot [string] -or $Value.SqlVersion -cne $SqlVersion){throw 'COLLATION_HTTP_RESULT_INVALID'}
}
function Invoke-LabCollationCatalogHttpRequest {
    [CmdletBinding()]param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or [string]$Request.Headers['Origin'] -cne $authority){throw 'COLLATION_HTTP_INVALID'}
        $buffer=[byte[]]::new(2049);$count=0
        while($count -lt $buffer.Length){$read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if($read -eq 0){break};$count+=$read}
        if($count -gt 2048){throw 'COLLATION_HTTP_INVALID'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        if($text.Length -gt 1024){throw 'COLLATION_HTTP_INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'COLLATION_HTTP_INVALID'}
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($property in $document.RootElement.EnumerateObject()){
                if(-not $keys.Add($property.Name) -or $property.Name -cnotin @('SqlVersion','Query') -or $property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'COLLATION_HTTP_INVALID'}
            }
            if($keys.Count -ne 2){throw 'COLLATION_HTTP_INVALID'}
        }finally{$document.Dispose()}
        $payload=$text|ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if($payload.SqlVersion -cnotin @('2019','2022','2025') -or $payload.Query.Length -gt 256 -or $payload.Query -match '\p{Cc}'){throw 'COLLATION_HTTP_INVALID'}
    }catch{throw 'COLLATION_HTTP_INVALID'}
    try {
        $rows=@(Find-SqlServerLabCollation -Query $payload.Query -SqlVersion $payload.SqlVersion)
        foreach($row in $rows){Assert-LabCollationHttpRow $row $payload.SqlVersion}
        $display=@($rows|Select-Object -First 100)
        $result=[pscustomobject]@{
            Contract=[pscustomobject]@{Name='SqlServerLab.CollationCatalogueSearch';Version='1.0'}
            SqlVersion=$payload.SqlVersion;Status=if($display.Count){'MATCHES'}else{'NO_MATCHES'}
            Results=$display;ReturnedCount=$display.Count;Truncated=($rows.Count -gt 100)
            SqlValidation='NOT_CHECKED';ExecutionSupported=$false;MutationAllowed=$false;Actions=@()
        }
        if([Text.Encoding]::UTF8.GetByteCount(($result|ConvertTo-Json -Depth 5 -Compress)) -gt 65536){throw 'COLLATION_HTTP_RESULT_INVALID'}
        return $result
    }catch{throw 'COLLATION_HTTP_RESULT_INVALID'}
}
