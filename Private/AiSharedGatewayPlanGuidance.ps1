# Both guided surfaces use the public configuration-only planner.
function ConvertFrom-LabAiSharedGatewayFormObject {
    param([Text.Json.JsonElement]$Object, [hashtable]$Fields)

    if ($Object.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
    $values = @{}
    foreach ($property in $Object.EnumerateObject()) {
        if ($property.Name -cnotin $Fields.Keys -or $values.ContainsKey($property.Name) -or
            $property.Value.ValueKind -ne $Fields[$property.Name]) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $values[$property.Name] = $property.Value
    }
    if ($values.Count -ne $Fields.Count) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
    return $values
}

function Invoke-LabAiSharedGatewayPlanForm {
    param([string]$Body)

    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 65536) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 4
    try { $document = [Text.Json.JsonDocument]::Parse($Body, $options) }
    catch { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
    try {
        $fields = @{
            Dimension=[Text.Json.JsonValueKind]::Number
            Consumer=[Text.Json.JsonValueKind]::Array
        }
        foreach ($name in @('GatewayId','Location','UpstreamBackend','UpstreamLocation','RuntimeModel','InputProfile',
            'ModelSha256','RuntimeSha256','ServerCertificateSha256','CertificateAuthoritySha256')) {
            $fields[$name] = [Text.Json.JsonValueKind]::String
        }
        $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $document.RootElement -Fields $fields
        $dimension = 0
        if (-not $values.Dimension.TryGetInt32([ref]$dimension) -or $dimension -notin 1..1998 -or
            $values.Consumer.GetArrayLength() -notin 1..64) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $arguments = @{ Dimension=$dimension }
        foreach ($name in $fields.Keys) {
            if ($fields[$name] -eq [Text.Json.JsonValueKind]::String) { $arguments[$name] = $values[$name].GetString() }
        }
        $consumerFields = @{}
        foreach ($name in @('RunId','InstanceId','DatabaseId','ExternalModelName','ApiKeyReference')) {
            $consumerFields[$name] = [Text.Json.JsonValueKind]::String
        }
        $arguments.Consumer = @(foreach ($item in $values.Consumer.EnumerateArray()) {
            $entry = ConvertFrom-LabAiSharedGatewayFormObject -Object $item -Fields $consumerFields
            $consumer = @{}
            foreach ($name in $consumerFields.Keys) { $consumer[$name] = $entry[$name].GetString() }
            [pscustomobject]$consumer
        })
        Get-SqlServerLabAiSharedGatewayPlan @arguments
    }
    finally { $document.Dispose() }
}

function Read-LabAiSharedGatewayPlanFields {
    param([System.Collections.IDictionary]$Labels)

    $values = @{}
    foreach ($field in $Labels.GetEnumerator()) {
        $entry = Read-LabConsoleTextInput -Prompt $field.Value
        if ($entry.Status -cne 'Confirmed') { return }
        $value = ([string]$entry.Value).Trim()
        if (-not $value -or $value.Length -gt 1024) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $values[$field.Key] = $value
    }
    return $values
}

function Resolve-LabAiSharedGatewayGuidedInputPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path,[switch]$SyntaxOnly)

    try {
        if ($Path.Length -gt 4096 -or $Path -match '[\x00-\x1F\x7F]' -or
            -not [IO.Path]::IsPathFullyQualified($Path) -or $Path -match '^[\\/]{2}') {
            throw 'Invalid path syntax'
        }
        $full = [IO.Path]::GetFullPath($Path)
        if ($IsWindows -and $full.Substring(2).Contains(':')) { throw 'Invalid NTFS stream path' }
        if (-not $SyntaxOnly) {
            $root = [IO.Path]::GetPathRoot($full)
            if ($IsWindows -and [IO.DriveInfo]::new($root).DriveType -ne [IO.DriveType]::Fixed) {
                throw 'Invalid drive type'
            }
            Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $root -Path $full
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                (-not $IsWindows -and [string]$item.UnixMode -cnotmatch '^-')) { throw 'Expected regular file' }
        }
        return $full
    }
    catch { throw 'AI_SHARED_GATEWAY_GUIDED_PATH_INVALID' }
}

function Invoke-LabAiSharedGatewayPreflightInteractive {
    param([Parameter(Mandatory)]$Plan)

    $labels = [ordered]@{
        RuntimePath = 'Absoluter lokaler Pfad zur Runtime-Datei'
        ModelPath = 'Absoluter lokaler Pfad zur Modelldatei'
        CertificatePath = 'Absoluter lokaler Pfad zum Serverzertifikat (PEM)'
        PrivateKeyPath = 'Absoluter lokaler Pfad zur privaten Schlüsseldatei (PEM, Eingabe verdeckt)'
        CertificateAuthorityPath = 'Absoluter lokaler Pfad zum CA-Zertifikat (PEM)'
    }
    $paths = @{}
    try {
        foreach ($field in $labels.GetEnumerator()) {
            $entry = Read-LabConsoleTextInput -Prompt $field.Value -MaskInput:($field.Key -ceq 'PrivateKeyPath')
            if ($entry.Status -cne 'Confirmed') { return }
            $paths[$field.Key] = Resolve-LabAiSharedGatewayGuidedInputPath -Path ([string]$entry.Value) -SyntaxOnly
        }
    }
    catch {
        Write-LabWarning 'Ungültige Pfadeingabe. Gib für jede Datei einen absoluten lokalen Pfad an.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }

    $items = @(
        New-LabConsoleItem -Id verify -Label 'Dateien jetzt prüfen'
        New-LabConsoleItem -Id back -Label 'Abbrechen'
    )
    $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-preflight-confirm' -Title 'Lokale Gateway-Dateien prüfen' `
        -Subtitle 'Die Prüfung liest Modell, Runtime, Zertifikate und Schlüsseldatei für den angezeigten Plan.' -Items $items
    if ($selection.Status -cne 'Selected' -or $selection.SelectedItem.Id -cne 'verify') { return }

    try {
        foreach ($name in $labels.Keys) {
            $paths[$name] = Resolve-LabAiSharedGatewayGuidedInputPath -Path $paths[$name]
        }
        $receipt = Test-SqlServerLabAiSharedGatewayPreflight -Plan $Plan @paths
        if ($receipt.Status -cne 'PREFLIGHT_VERIFIED' -or $receipt.PlanKey -cne $Plan.PlanKey) {
            throw 'AI_SHARED_GATEWAY_GUIDED_PREFLIGHT_UNCONFIRMED'
        }
        Write-LabInfo 'Lokale Dateien, Zertifikate und Schlüssel passen zum angezeigten Gateway-Plan.'
        Write-LabInfo ($receipt | ConvertTo-Json -Depth 8)
    }
    catch {
        if ($_.Exception.Message -ceq 'AI_SHARED_GATEWAY_GUIDED_PATH_INVALID') {
            Write-LabWarning 'Datei nicht erreichbar. Prüfe die lokalen Pfade und verwende Dateien ohne Verknüpfungen.'
        } else {
            Write-LabWarning 'Dateiprüfung fehlgeschlagen. Prüfe die SHA-256-Werte, den Zertifikatsnamen und die Zuordnung von Schlüssel und CA.'
        }
    }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabAiSharedGatewayPlanInteractive {
    [CmdletBinding()] param()
    try {
        $options = @('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl','OpenVinoModelServer')
        $items = @(foreach ($option in $options) { New-LabConsoleItem -Id $option -Label $option })
        $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-plan-backend' -Title 'Embedding-Gateway planen' -Subtitle 'Lokales Backend wählen' -Items $items
        if ($selection.Status -cne 'Selected') { return }
        if ($selection.SelectedItem.Id -cnotin $options) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $upstreamPath = if ($selection.SelectedItem.Id -ceq 'OpenVinoModelServer') { '/v3/embeddings' } else { '/v1/embeddings' }
        $arguments = Read-LabAiSharedGatewayPlanFields ([ordered]@{
            GatewayId='Gateway-ID'
            Location='HTTPS-Endpunkt des Gateways (/v1/embeddings)'
            UpstreamLocation="Lokaler Upstream per numerischer Loopback-Adresse ($upstreamPath)"
            RuntimeModel='Modellname des Upstreams'
            Dimension='Embedding-Dimension (1 bis 1998)'
            ModelSha256='SHA-256 der Modelldatei'
            RuntimeSha256='SHA-256 der Runtime'
            ServerCertificateSha256='SHA-256 des Serverzertifikats'
            CertificateAuthoritySha256='SHA-256 der CA'
        })
        if (-not $arguments) { return }
        $dimension = 0
        if (-not [int]::TryParse($arguments.Dimension, [ref]$dimension) -or $dimension -notin 1..1998) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $arguments.Dimension = $dimension
        $arguments.UpstreamBackend = $selection.SelectedItem.Id
        $profiles = @('raw','nomic-search','snowflake-search')
        $items = @(foreach ($profile in $profiles) { New-LabConsoleItem -Id $profile -Label $profile })
        $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-plan-profile' -Title 'Eingabeprofil wählen' -Items $items
        if ($selection.Status -cne 'Selected') { return }
        if ($selection.SelectedItem.Id -cnotin $profiles) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        $arguments.InputProfile = $selection.SelectedItem.Id
        $consumers = [Collections.Generic.List[object]]::new()
        do {
            $consumer = Read-LabAiSharedGatewayPlanFields ([ordered]@{
                RunId='Run-ID des SQL-Verbrauchers'
                InstanceId='Instanz-ID'
                DatabaseId='Datenbank-ID'
                ExternalModelName='SQL-Modellname'
                ApiKeyReference='Secret-Referenz im Format SQL_SERVER_LAB_SECRET_…'
            })
            if (-not $consumer) { return }
            $consumers.Add([pscustomobject]$consumer)
            $items = @(
                New-LabConsoleItem -Id preview -Label 'Plan anzeigen'
                if ($consumers.Count -lt 64) { New-LabConsoleItem -Id add -Label 'Weiteren SQL-Verbraucher hinzufügen' }
                New-LabConsoleItem -Id cancel -Label 'Abbrechen'
            )
            $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-plan-consumers' -Title 'SQL-Verbraucher' -Items $items
            if ($selection.Status -cne 'Selected' -or $selection.SelectedItem.Id -ceq 'cancel') { return }
            if ($selection.SelectedItem.Id -cnotin $items.Id) { throw 'AI_SHARED_GATEWAY_FORM_INVALID' }
        } while ($selection.SelectedItem.Id -ceq 'add')
        $arguments.Consumer = @($consumers.ToArray())
        $plan = Get-SqlServerLabAiSharedGatewayPlan @arguments
        Write-LabInfo ("Gateway-Plan {0} · {1} · {2} SQL-Verbraucher" -f $plan.GatewayId,$plan.Status,$plan.Consumers.Count)
        Write-LabInfo ($plan | ConvertTo-Json -Depth 8)
    }
    catch {
        Write-LabWarning 'Gateway-Plan konnte nicht erstellt werden. Prüfe Endpunkte, Inhaltsdigests und Verbraucherreferenzen.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }

    $items = @(
        New-LabConsoleItem -Id preflight -Label 'Lokale Gateway-Dateien für diesen Plan prüfen'
        New-LabConsoleItem -Id status -Label 'Status für diesen Gateway-Plan lesen'
        New-LabConsoleItem -Id upstream -Label 'Registrierten Loopback-Upstream mit Testanfrage prüfen'
        New-LabConsoleItem -Id back -Label 'Zurück'
    )
    $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-plan-next' -Title 'Gateway-Plan' `
        -Subtitle 'Die Upstream-Prüfung sendet eine synthetische Anfrage an den gebundenen lokalen Dienst. Sie verwendet keinen API-Schlüssel.' -Items $items
    if ($selection.Status -cne 'Selected' -or $selection.SelectedItem.Id -cnotin @('preflight','status','upstream')) { return }
    if ($selection.SelectedItem.Id -ceq 'preflight') {
        Invoke-LabAiSharedGatewayPreflightInteractive -Plan $plan
        return
    }
    try {
        if ($selection.SelectedItem.Id -ceq 'upstream') {
            $view = Test-SqlServerLabAiSharedGatewayUpstream -Plan $plan
            Write-LabInfo ("Gateway-Upstream {0} · {1} · Dimension: {2} · Dauer: {3} ms" -f
                $view.GatewayId,$view.Status,$view.Dimension,$view.DurationMilliseconds)
        } else {
            $view = Get-SqlServerLabAiSharedGatewayStatus -Plan $plan
            Write-LabInfo ("Gateway-Status {0} · {1} · {2} · {3}" -f $view.GatewayId,$view.Status,$view.ReasonCode,$view.CheckedAtUtc)
        }
        Write-LabInfo ("Noch offen: {0}" -f ($view.PendingEvidence -join ', '))
    }
    catch {
        Write-LabWarning 'Gateway-Prüfung konnte nicht bestätigt werden. Prüfe die lokale Registrierung und den gebundenen Upstream.'
    }
    $null = Wait-LabConsoleAcknowledgement
}
