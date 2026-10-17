#Requires -Version 7.2
# Nur angegebene Optionen projizieren; keine Verbindung oder Zertifikatspruefung.
function Get-LabSqlConnectionSettings {
    [CmdletBinding()]
    param([object]$ConnectionString)
    $value=[pscustomobject][ordered]@{Encrypt=$null;TrustServerCertificate=$null;Status='NOT_SPECIFIED'}
    if($null -eq $ConnectionString){return $value}
    if($ConnectionString -isnot [string] -or [string].GetProperty('Length').GetValue($ConnectionString) -gt 65536){$value.Status='UNREADABLE';return $value}
    if([string]::IsNullOrWhiteSpace($ConnectionString)){return $value}
    try{
        $builder=[System.Data.SqlClient.SqlConnectionStringBuilder]::new($ConnectionString)
        if($builder.ShouldSerialize('Encrypt')){$value.Encrypt=[bool]$builder.Encrypt}
        if($builder.ShouldSerialize('TrustServerCertificate')){$value.TrustServerCertificate=[bool]$builder.TrustServerCertificate}
        $value.Status='CONFIGURED_CONNECTION_STRING'
    }catch{$value.Encrypt=$null;$value.TrustServerCertificate=$null;$value.Status='UNREADABLE'}
    return $value
}

function Format-LabSqlConnectionSettings {
    [CmdletBinding()]
    param([object]$ConnectionString)
    $settings=Get-LabSqlConnectionSettings $ConnectionString
    $missing=if($settings.Status -ceq 'UNREADABLE'){'nicht lesbar'}else{'nicht angegeben'}
    $encrypt=if($null -eq $settings.Encrypt){$missing}elseif($settings.Encrypt){'True'}else{'False'}
    $trust=if($null -eq $settings.TrustServerCertificate){$missing}elseif($settings.TrustServerCertificate){'True'}else{'False'}
    return ('Encrypt={0};TrustServerCertificate={1}' -f $encrypt,$trust)
}
