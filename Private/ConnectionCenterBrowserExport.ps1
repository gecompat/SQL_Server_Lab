function Get-LabSsmsRegistrationDownload {
    $catalog = Get-SqlServerLabConnectionCenter -StoredOnly
    if ($catalog.Entries.Count -gt 500) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    $document = (New-LabSsmsRegistrationLines -ConnectionCenter $catalog) -join [Environment]::NewLine
    if ([Text.Encoding]::UTF8.GetByteCount($document) -gt 2097152) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    return $document
}
