function Invoke-LabOvmsUpstreamInteractive {
    $address = Select-LabConsoleDataItem -ScreenId 'ovms-loopback' -Title 'Lokale OVMS-Adresse' -Items @(
        New-LabConsoleItem -Id 'ipv4' -Label '127.0.0.1 (IPv4)' -Data '127.0.0.1'
        New-LabConsoleItem -Id 'ipv6' -Label '::1 (IPv6)' -Data '[::1]'
    )
    if (-not $address) { return }

    $numbers = @{}
    foreach ($field in @(
        @{ Name='Port'; Label='OVMS-Port'; Minimum=1024; Maximum=65535; Default='9000' },
        @{ Name='Dimension'; Label='Erwartete Embedding-Dimension'; Minimum=1; Maximum=1998; Default='' },
        @{ Name='TimeoutSeconds'; Label='Timeout in Sekunden'; Minimum=1; Maximum=300; Default='30' }
    )) {
        do {
            $entry = Read-LabConsoleTextInput -Prompt "$($field.Label) ($($field.Minimum)–$($field.Maximum))" -Default $field.Default
            if ($entry.Status -ne 'Confirmed') { return }
            $value = 0
            $valid = [int]::TryParse($entry.Value, [ref]$value) -and $value -ge $field.Minimum -and $value -le $field.Maximum
            if (-not $valid) { Write-LabError 'Die Zahl liegt außerhalb des angegebenen Bereichs.' }
        } until ($valid)
        $numbers[$field.Name] = $value
    }
    do {
        $model = Read-LabConsoleTextInput -Prompt 'Exakter OVMS-Modellname'
        if ($model.Status -ne 'Confirmed') { return }
        $valid = $model.Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}\z'
        if (-not $valid) { Write-LabError 'Modellname mit 1 bis 256 Zeichen eingeben. Zulässig sind Buchstaben, Ziffern, Punkt, Unterstrich, Doppelpunkt, Schrägstrich, Plus und Minus.' }
    } until ($valid)
    $location = 'http://{0}:{1}/v3/embeddings' -f $address, $numbers.Port
    if (-not (Read-LabConfirm -Prompt "Einen synthetischen Embedding-Request an $location senden? OVMS muss bereits laufen." -Default $false)) { return }
    try {
        $result = Test-SqlServerLabOvmsUpstreamEndpoint -Location $location -RuntimeModel $model.Value -Dimension $numbers.Dimension -TimeoutSeconds $numbers.TimeoutSeconds -ErrorAction Stop
        if ($result.Status -cne 'UPSTREAM_VERIFIED') { throw 'OVMS_UPSTREAM_UNCONFIRMED' }
        Write-LabSuccess ("OVMS antwortet mit der erwarteten Dimension {0}. Dauer: {1} ms." -f $result.Dimension, $result.DurationMilliseconds)
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^AI_OVMS_[A-Z_]{1,64}$') { $_.Exception.Message } else { 'OVMS_UPSTREAM_UNCONFIRMED' }
        Write-LabError "OVMS konnte nicht verifiziert werden ($code). Prüfe den Port, den Modellnamen und die erwartete Dimension."
    }
    $null = Wait-LabConsoleAcknowledgement
}
