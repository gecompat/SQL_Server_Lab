function Get-LabConnectionCenterConfiguration {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $path = Join-Path (Join-Path $StateRoot 'catalog') 'sql-connection-center-groups.json'
    $defaults = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.ConnectionCenterGroups/1.1'
        RootGroupName = 'SQL Server Lab'
        GroupBy = 'Provider'
        CmsUseRootGroup = $true
        CmsGroupByProvider = $true
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $defaults }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        if ([string]::IsNullOrWhiteSpace([string]$saved.RootGroupName)) { return $defaults }
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.ConnectionCenterGroups/1.1'
            RootGroupName = [string]$saved.RootGroupName
            GroupBy = 'Provider'
            CmsUseRootGroup = if ($null -eq $saved.CmsUseRootGroup) { $true } else { [bool]$saved.CmsUseRootGroup }
            CmsGroupByProvider = if ($null -eq $saved.CmsGroupByProvider) { $true } else { [bool]$saved.CmsGroupByProvider }
        }
    }
    catch { return $defaults }
}

function Get-LabConnectionCenterExportDirectory {
    [CmdletBinding()]
    param([string]$StateRoot)

    $dataRoot = Get-LabDataRootDefault
    if (-not [string]::IsNullOrWhiteSpace([string]$dataRoot)) {
        return (Join-Path $dataRoot 'Exports')
    }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    return (Join-Path $StateRoot 'exports')
}

function Set-LabConnectionCenterConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootGroupName,
        [bool]$CmsUseRootGroup = $true,
        [bool]$CmsGroupByProvider = $true,
        [string]$StateRoot
    )

    if ($RootGroupName -notmatch '^[^\\/:*?"<>|'''']{1,80}$') {
        throw 'CONNECTION_CENTER_GROUP_NAME_INVALID: Der Gruppenname darf nicht leer sein oder unzulässige Dateizeichen enthalten.'
    }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $path = Join-Path (Join-Path $StateRoot 'catalog') 'sql-connection-center-groups.json'
    $configuration = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.ConnectionCenterGroups/1.1'
        RootGroupName = $RootGroupName.Trim()
        GroupBy = 'Provider'
        CmsUseRootGroup = $CmsUseRootGroup
        CmsGroupByProvider = $CmsGroupByProvider
        UpdatedAt = Get-LabTimestamp
    }
    Write-LabArtifactJsonAtomic -Path $path -InputObject $configuration
    return $configuration
}

function ConvertFrom-LabConnectionStringTarget {
    [CmdletBinding()]
    param([string]$ConnectionString, $Instance)

    if (-not [string]::IsNullOrWhiteSpace($ConnectionString)) {
        try {
            $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
            $builder.ConnectionString = $ConnectionString
            foreach ($key in @('Server', 'Data Source', 'Address', 'Addr', 'Network Address')) {
                if ($builder.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$builder[$key])) {
                    return [string]$builder[$key]
                }
            }
        }
        catch { }
    }
    $serverHost = [string]$Instance.host
    if ([string]::IsNullOrWhiteSpace($serverHost)) { $serverHost = [string]$Instance.hostName }
    if ([string]::IsNullOrWhiteSpace($serverHost)) { return $null }
    $port = [int]$Instance.port
    if ($port -gt 0) { return ('{0},{1}' -f $serverHost, $port) }
    return $serverHost
}

function Get-SqlServerLabConnectionCenter {
    <#
    .SYNOPSIS
        Liefert den passwortfreien, providerübergreifenden SQL-Endpunktkatalog.
    .DESCRIPTION
        Aggregiert gespeicherte Lab-Verbindungsinformationen zu einer zentralen
        Sicht für SSMS, CMS und Exporte. Kennwörter und vollständige Connection
        Strings werden nicht zurückgegeben.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .OUTPUTS
        PSCustomObject mit Gruppenregel und bekannten SQL-Endpunkten.
    #>
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $configuration = Get-LabConnectionCenterConfiguration -StateRoot $StateRoot
    $entries = @()
    $testRunIds = @(Get-LabAutomatedTestEnvironmentRunIds)
    $testEntriesByRunId = @{}
    $testGroupReady = $false
    if ($testRunIds.Count -gt 0) {
        try {
            $testRegistry = Get-LabTestEnvironmentRegistry
            $resolvedTestEntries = @(Get-LabTestEnvironmentResolvedEntries -Registry $testRegistry -StateRoot $StateRoot)
            $testGroupReady = $resolvedTestEntries.Count -eq @($testRegistry.environments).Count -and
                $resolvedTestEntries.Count -gt 0 -and @($resolvedTestEntries | Where-Object status -ne 'READY').Count -eq 0
            if ($testGroupReady) {
                foreach ($testEntry in $resolvedTestEntries) { $testEntriesByRunId[[string]$testEntry.runId] = $testEntry }
            }
        }
        catch { $testGroupReady = $false }
    }
    foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot)) {
        $runId = [string]$run.runId
        $isAutomatedTestEnvironment = $runId -in $testRunIds
        if ($isAutomatedTestEnvironment -and -not $testGroupReady) { continue }
        $testEnvironment = if ($isAutomatedTestEnvironment) { $testEntriesByRunId[$runId] } else { $null }
        $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $runId) 'connection-info.json'
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { continue }
        try { $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
        catch { continue }
        $runtimeState = 'UNKNOWN'
        try { $runtimeState = [string](Sync-LabRunRuntimeState -Run $run -StateRoot $StateRoot).Runtime.State } catch { }
        foreach ($instance in @($connection.instances)) {
            $target = ConvertFrom-LabConnectionStringTarget -ConnectionString ([string]$instance.connectionString) -Instance $instance
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            $provider = [string]$instance.provider
            if ([string]::IsNullOrWhiteSpace($provider)) { $provider = 'unknown' }
            $instanceId = [string]$instance.id
            if ([string]::IsNullOrWhiteSpace($instanceId)) { $instanceId = 'primary' }
            $labName = if ($testEnvironment) { "TEST · $([string]$testEnvironment.key)" } else { [string]$run.metadata.name }
            if ([string]::IsNullOrWhiteSpace($labName)) { $labName = $runId.Substring(0, [Math]::Min(8, $runId.Length)) }
            $entries += [PSCustomObject]@{
                Id = ('{0}/{1}' -f $runId, $instanceId)
                RunId = $runId
                DisplayName = ('{0} ({1})' -f $labName, $instanceId)
                Description = if ($testEnvironment) { ('SQL Server Lab · automatisierte Testumgebung · {0} · {1}' -f $provider, $runtimeState) } else { ('SQL Server Lab · {0} · {1}' -f $provider, $runtimeState) }
                Provider = $provider
                Group = $provider.ToUpperInvariant()
                Server = $target
                Authentication = 'SqlAuthentication'
                Login = 'sa'
                RuntimeState = $runtimeState
            }
        }
    }
    $orderedEntries = @($entries | Sort-Object Group, DisplayName, Server)
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.ConnectionCenter/1.0'
        GeneratedAt = Get-LabTimestamp
        StateRoot = $StateRoot
        Grouping = $configuration
        Entries = $orderedEntries
    }
}

function Sync-SqlServerLabConnectionCenter {
    <#
    .SYNOPSIS
        Synchronisiert den passwortfreien Maschinenkatalog der Verbindungszentrale.
    .DESCRIPTION
        Schreibt die aktuelle Endpunktliste atomar als JSON-Artefakt in den State Root.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .PARAMETER Quiet
        Unterdrückt die Erfolgsmeldung für automatische Lifecycle-Synchronisationen.
    .OUTPUTS
        PSCustomObject mit Zielpfad und synchronisiertem Katalog.
    #>
    [CmdletBinding()]
    param([string]$StateRoot, [switch]$Quiet)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $center = Get-SqlServerLabConnectionCenter -StateRoot $StateRoot
    $path = Join-Path (Join-Path $StateRoot 'catalog') 'sql-connection-center.json'
    Write-LabArtifactJsonAtomic -Path $path -InputObject $center
    if (-not $Quiet) { Write-LabSuccess "Verbindungszentrale synchronisiert: $($center.Entries.Count) SQL-Endpunkt(e)." }
    return [PSCustomObject]@{ Path = $path; ConnectionCenter = $center }
}

function Get-LabConnectionCenterCmsConfiguration {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $path = Join-Path (Join-Path $StateRoot 'catalog') 'sql-connection-center-cms.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 }
    catch { throw "CONNECTION_CENTER_CMS_CONFIGURATION_INVALID: $($_.Exception.Message)" }
}

function Set-LabConnectionCenterCmsConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $path = Join-Path (Join-Path $StateRoot 'catalog') 'sql-connection-center-cms.json'
    Write-LabArtifactJsonAtomic -Path $path -InputObject $Configuration
    return $Configuration
}

function New-LabConnectionCenterPassword {
    [CmdletBinding()]
    param()

    $characters = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%+=_-'.ToCharArray()
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = [Security.SecureString]::new()
    try {
        foreach ($byte in $bytes) { $password.AppendChar($characters[$byte % $characters.Length]) }
        $password.MakeReadOnly()
        return $password
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function ConvertTo-LabCmsServerTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [string]$CmsProvider)

    if ([string]::IsNullOrWhiteSpace($CmsProvider)) { return $Server }
    $hostAlias = switch ($CmsProvider) {
        'docker' { 'host.docker.internal' }
        'podman' { 'host.containers.internal' }
        default { return $Server }
    }
    if ($Server -match '^(127\.0\.0\.1|localhost)(?<port>,[0-9]+)?$') {
        return ('{0}{1}' -f $hostAlias, $Matches.port)
    }
    return $Server
}

function Initialize-SqlServerLabCms {
    <#
    .SYNOPSIS
        Erstellt eine kleine persistente SQL-Instanz als Central Management Server.
    .DESCRIPTION
        Erstellt nach explizitem Aufruf einen kompakten Docker- oder Podman-Run
        mit persistentem Data Root. Das generierte SA-Passwort wird nur einmal
        im Ergebnis ausgegeben und danach run-lokal geschützt gespeichert.
    .PARAMETER Provider
        Optionaler Containerprovider. Ohne Angabe wird Docker vor Podman bevorzugt.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .OUTPUTS
        PSCustomObject mit CMS-Konfiguration, Run-Information und einmaligem Passwort.
    #>
    [CmdletBinding()]
    param([ValidateSet('docker', 'podman')][string]$Provider, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $existing = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if ($existing) { throw "CONNECTION_CENTER_CMS_ALREADY_CONFIGURED: Run $($existing.RunId) ist bereits als CMS registriert." }
    $available = @(Get-AvailableLabProviders)
    if (-not $Provider) {
        if ('docker' -in $available) { $Provider = 'docker' }
        elseif ('podman' -in $available) { $Provider = 'podman' }
        else { throw 'CONNECTION_CENTER_CMS_CONTAINER_PROVIDER_REQUIRED: Docker oder Podman ist für den CMS erforderlich.' }
    }
    if ($Provider -notin $available) { throw "CONNECTION_CENTER_CMS_PROVIDER_UNAVAILABLE: $Provider ist nicht verfügbar." }
    $dataRoot = Get-LabDataRootDefault
    if (-not $dataRoot) { throw 'CONNECTION_CENTER_CMS_DATA_ROOT_REQUIRED: Für einen dauerhaften CMS zuerst einen Data Root konfigurieren.' }
    $password = New-LabConnectionCenterPassword
    $lab = New-SqlServerLab -Version '2025' -Provider $Provider -Profile compact -LabName 'sql-server-lab-cms' -PersistentData -DataRoot $dataRoot -AutoStart on -SaPassword $password -StateRoot $StateRoot
    $configuration = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.ConnectionCenterCms/1.0'
        RunId = [string]$lab.RunId
        Provider = $Provider
        CreatedAt = Get-LabTimestamp
        Purpose = 'Central Management Server'
        AutoStart = 'on'
        PasswordOrigin = 'Generated'
    }
    Set-LabConnectionCenterCmsConfiguration -Configuration $configuration -StateRoot $StateRoot | Out-Null
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    return [PSCustomObject]@{ Configuration = $configuration; Lab = $lab; Password = $plain }
}

function Get-LabConnectionCenterCmsEnvironmentCandidates {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $protectedRunIds = @(Get-LabAutomatedTestEnvironmentRunIds)
    $candidates = @()
    foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot)) {
        if ([string]$run.runId -in $protectedRunIds) { continue }
        $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$run.runId)) 'connection-info.json'
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { continue }
        try { $connectionInfo = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
        catch { continue }
        $instances = @($connectionInfo.instances | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.connectionString) -or
            -not [string]::IsNullOrWhiteSpace([string]$_.host) -or
            [int]$_.port -gt 0
        })
        if ($instances.Count -eq 0) { continue }

        $provider = if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
            'hyperv'
        }
        else {
            [string]@($instances | ForEach-Object { [string]$_.provider } | Where-Object { $_ -in @('docker', 'podman', 'hyperv') } | Select-Object -First 1)[0]
        }
        if ([string]::IsNullOrWhiteSpace($provider)) { continue }
        $state = [string]$run.runtime.state
        $name = [string]$run.metadata.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$run.runId }
        $candidates += [pscustomobject]@{
            Run = $run
            RunId = [string]$run.runId
            Name = $name
            Provider = $provider
            State = $state
        }
    }
    return @($candidates | Sort-Object Name, RunId)
}

function Register-SqlServerLabCmsEnvironment {
    <# .SYNOPSIS Registriert eine vorhandene providerneutrale SQL-Umgebung als verwalteten CMS. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Security.SecureString]$SaPassword,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $existing = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if ($existing) { throw "CONNECTION_CENTER_CMS_ALREADY_CONFIGURED: Run $($existing.RunId) ist bereits als CMS registriert." }
    $candidate = @(Get-LabConnectionCenterCmsEnvironmentCandidates -StateRoot $StateRoot | Where-Object RunId -eq $RunId | Select-Object -First 1)
    if ($candidate.Count -ne 1) { throw 'CONNECTION_CENTER_CMS_RUN_NOT_ELIGIBLE: Der Run besitzt keinen verwendbaren SQL-Endpunkt oder ist geschuetzt.' }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $passwordOrigin = 'ExistingRunSecret'
    if ($SaPassword) {
        $null = Save-LabSecret -Path $runDirectory -Name 'sa-password' -Secret $SaPassword
        $passwordOrigin = 'ProvidedForCms'
    }
    elseif (-not (Get-LabSecret -Path $runDirectory -Name 'sa-password')) {
        throw 'CONNECTION_CENTER_CMS_SECRET_REQUIRED: Fuer die CMS-Synchronisation ist das SA-Passwort dieser Umgebung erforderlich.'
    }

    $configuration = [pscustomobject]@{
        ContractVersion = 'SqlServerLab.ConnectionCenterCms/1.1'
        RunId = $RunId
        Provider = [string]$candidate[0].Provider
        CreatedAt = Get-LabTimestamp
        Purpose = 'Central Management Server'
        AutoStart = 'existing'
        PasswordOrigin = $passwordOrigin
        AdoptedExistingEnvironment = $true
    }
    Set-LabConnectionCenterCmsConfiguration -Configuration $configuration -StateRoot $StateRoot | Out-Null
    return [pscustomobject]@{ Configuration = $configuration; Run = $candidate[0].Run }
}

function Add-LabSsmsTextNode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document, [Parameter(Mandatory)][System.Xml.XmlElement]$Parent, [Parameter(Mandatory)][string]$Name, [string]$Value)

    $namespace = 'http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08'
    $node = $Document.CreateElement('RegisteredServers', $Name, $namespace)
    $node.InnerText = $Value
    $null = $Parent.AppendChild($node)
}

function ConvertTo-LabSsmsXmlText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function ConvertTo-LabSsmsAliasSegment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    return [System.Uri]::EscapeDataString($Value).Replace('%', '_')
}

function Add-LabSsmsSfcDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Payload
    )

    $Lines.Add('        <document>')
    $Lines.Add('          <docinfo><aliases><alias>{0}</alias></aliases><sfc:version DomainVersion="1" /></docinfo>' -f (ConvertTo-LabSsmsXmlText $Alias))
    $Lines.Add('          <data>{0}</data>' -f $Payload)
    $Lines.Add('        </document>')
}

function New-LabSsmsRegistrationLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ConnectionCenter)

    $lines = [System.Collections.Generic.List[string]]::new()
    $rs = 'RegisteredServers'
    $engineAlias = '/RegisteredServersStore/ServerGroup/DatabaseEngineServerGroup'
    $labSegment = ConvertTo-LabSsmsAliasSegment ([string]$ConnectionCenter.Grouping.RootGroupName)
    $labAlias = "$engineAlias/ServerGroup/$labSegment"

    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<model xmlns="http://schemas.serviceml.org/smlif/2007/02">')
    $lines.Add('  <identity><name>urn:uuid:{0}</name><baseURI>http://documentcollection/</baseURI></identity>' -f [Guid]::NewGuid())
    $lines.Add('  <xs:bufferSchema xmlns:xs="http://www.w3.org/2001/XMLSchema">')
    $lines.Add('    <definitions xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08">')
    $lines.Add('      <document><docinfo><aliases><alias>/system/schema/RegisteredServers</alias></aliases><sfc:version DomainVersion="1" /></docinfo><data>')
    $lines.Add('        <xs:schema targetNamespace="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema" elementFormDefault="qualified">')
    foreach ($elementName in @('ServerGroup', 'RegisteredServer')) {
        $lines.Add('          <xs:element name="{0}"><xs:complexType><xs:sequence><xs:any namespace="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" processContents="skip" minOccurs="0" maxOccurs="unbounded" /></xs:sequence></xs:complexType></xs:element>' -f $elementName)
    }
    $lines.Add('          <RegisteredServers:bufferData xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08"><instances xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08">')

    $enginePayload = '<RegisteredServers:ServerGroup xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema"><RegisteredServers:ServerGroups><sfc:Collection><sfc:Reference sml:ref="true"><sml:Uri>{0}</sml:Uri></sfc:Reference></sfc:Collection></RegisteredServers:ServerGroups><RegisteredServers:Parent><sfc:Reference sml:ref="true"><sml:Uri>/RegisteredServersStore</sml:Uri></sfc:Reference></RegisteredServers:Parent><RegisteredServers:Name type="string">DatabaseEngineServerGroup</RegisteredServers:Name><RegisteredServers:ServerType type="ServerType">DatabaseEngine</RegisteredServers:ServerType></RegisteredServers:ServerGroup>' -f $labAlias
    Add-LabSsmsSfcDocument -Lines $lines -Alias $engineAlias -Payload $enginePayload
    $serverReferences = [System.Collections.Generic.List[string]]::new()
    $serverDocumentStart = $lines.Count
    foreach ($entry in @($ConnectionCenter.Entries | Sort-Object Group, DisplayName, Server)) {
        $serverName = '[{0}] {1}' -f $entry.Group, $entry.DisplayName
        $serverSegment = ConvertTo-LabSsmsAliasSegment ('{0}-{1}' -f $serverName, $entry.Server)
        $serverAlias = "$labAlias/RegisteredServer/$serverSegment"
        $serverReferences.Add('<sfc:Reference sml:ref="true"><sml:Uri>{0}</sml:Uri></sfc:Reference>' -f $serverAlias)
        $connectionString = 'Data Source={0};Initial Catalog=master;User ID={1};Encrypt=False;TrustServerCertificate=True;Pooling=False;MultipleActiveResultSets=False' -f $entry.Server, $entry.Login
        $serverPayload = '<RegisteredServers:RegisteredServer xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema"><RegisteredServers:Parent><sfc:Reference sml:ref="true"><sml:Uri>{0}</sml:Uri></sfc:Reference></RegisteredServers:Parent><RegisteredServers:Name type="string">{1}</RegisteredServers:Name><RegisteredServers:Description type="string">{2}</RegisteredServers:Description><RegisteredServers:ServerName type="string">{3}</RegisteredServers:ServerName><RegisteredServers:UseCustomConnectionColor type="boolean">false</RegisteredServers:UseCustomConnectionColor><RegisteredServers:CustomConnectionColorArgb type="int">0</RegisteredServers:CustomConnectionColorArgb><RegisteredServers:ServerType type="ServerType">DatabaseEngine</RegisteredServers:ServerType><RegisteredServers:ConnectionStringWithEncryptedPassword type="string">{4}</RegisteredServers:ConnectionStringWithEncryptedPassword><RegisteredServers:CredentialPersistenceType type="CredentialPersistenceType">None</RegisteredServers:CredentialPersistenceType><RegisteredServers:OtherParams type="string" /><RegisteredServers:AuthenticationType type="int">0</RegisteredServers:AuthenticationType><RegisteredServers:ActiveDirectoryUserId type="string" /><RegisteredServers:ActiveDirectoryTenant type="string" /></RegisteredServers:RegisteredServer>' -f $labAlias, (ConvertTo-LabSsmsXmlText $serverName), (ConvertTo-LabSsmsXmlText $entry.Description), (ConvertTo-LabSsmsXmlText $entry.Server), (ConvertTo-LabSsmsXmlText $connectionString)
        Add-LabSsmsSfcDocument -Lines $lines -Alias $serverAlias -Payload $serverPayload
    }
    $labPayload = '<RegisteredServers:ServerGroup xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema"><RegisteredServers:RegisteredServers><sfc:Collection>{0}</sfc:Collection></RegisteredServers:RegisteredServers><RegisteredServers:Parent><sfc:Reference sml:ref="true"><sml:Uri>{1}</sml:Uri></sfc:Reference></RegisteredServers:Parent><RegisteredServers:Name type="string">{2}</RegisteredServers:Name><RegisteredServers:Description type="string">Automatisch durch SQL Server Lab verwaltet. Keine Kennwörter gespeichert.</RegisteredServers:Description><RegisteredServers:ServerType type="ServerType">DatabaseEngine</RegisteredServers:ServerType></RegisteredServers:ServerGroup>' -f ($serverReferences -join ''), $engineAlias, (ConvertTo-LabSsmsXmlText $ConnectionCenter.Grouping.RootGroupName)
    $labDocumentStart = $lines.Count
    Add-LabSsmsSfcDocument -Lines $lines -Alias $labAlias -Payload $labPayload
    $labDocument = $lines.GetRange($labDocumentStart, 4)
    $lines.RemoveRange($labDocumentStart, 4)
    $lines.InsertRange($serverDocumentStart, $labDocument)
    $lines.Add('          </instances></RegisteredServers:bufferData>')
    $lines.Add('        </xs:schema></data></document>')
    $lines.Add('    </definitions></xs:bufferSchema>')
    $lines.Add('</model>')
    return $lines
}

function Export-SqlServerLabSsmsRegistration {
    <#
    .SYNOPSIS
        Exportiert einen SSMS-importierbaren, kennwortfreien `.regsrvr`-Katalog.
    .DESCRIPTION
        Erzeugt einen SSMS-Export mit einer Lab-Gruppe. Die Providerkennung steht
        im Anzeigenamen; SQL-Anmeldenamen werden berücksichtigt, Kennwörter nie exportiert.
    .PARAMETER Path
        Optionaler Zielpfad. Standard ist `Exports` im konfigurierten Data Root.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .OUTPUTS
        PSCustomObject mit Exportpfad, Gruppenname und Endpunktanzahl.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $center = (Sync-SqlServerLabConnectionCenter -StateRoot $StateRoot -Quiet).ConnectionCenter
    if (-not $Path) { $Path = Join-Path (Get-LabConnectionCenterExportDirectory -StateRoot $StateRoot) 'sql-server-lab.regsrvr' }
    $directory = Split-Path -Parent $Path
    if ($directory) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [System.IO.File]::WriteAllLines($Path, (New-LabSsmsRegistrationLines -ConnectionCenter $center), [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ Path = $Path; Entries = $center.Entries.Count; GroupName = $center.Grouping.RootGroupName }
}

function Get-LabSsmsRegistrationFiles {
    [CmdletBinding()]
    param()

    if (-not $env:APPDATA) { return @() }
    $basePaths = @(
        (Join-Path $env:APPDATA 'Microsoft\SQL Server Management Studio'),
        (Join-Path $env:APPDATA 'Microsoft SQL Server Management Studio')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    return @($basePaths | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Join-Path $_.FullName 'SqlToolsVS\RegSrvr.xml'
        }
    } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object -Unique)
}

function Update-SqlServerLabLocalSsmsRegistration {
    <#
    .SYNOPSIS Aktualisiert ausschließlich die verwaltete SQL-Server-Lab-Gruppe einer lokalen SSMS-Registrierung. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$StateRoot)

    throw 'CONNECTION_CENTER_SSMS_LOCAL_EDIT_DISABLED: Direkte Bearbeitung der versionsabhängigen SSMS-RegSrvr.xml ist deaktiviert. Mit [3] einen validen Export nach Lab_Data/Exports erzeugen und ihn in SSMS importieren; vorhandene Servergruppen bleiben damit garantiert unverändert.'
}

function ConvertTo-LabXPathLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match "'") { throw 'CONNECTION_CENTER_GROUP_NAME_INVALID: Apostrophe im Gruppenname werden nicht unterstützt.' }
    return "'$Value'"
}

function Export-SqlServerLabCmsSyncScript {
    <#
    .SYNOPSIS
        Erzeugt ein idempotentes CMS-Synchronisationsskript ohne Kennwörter.
    .DESCRIPTION
        Gleicht den vollständig durch SQL Server Lab verwalteten CMS-Unterbaum
        mit dem Framework-State ab. Laufende und gestoppte Umgebungen werden in
        getrennten Gruppen geführt. Provider-Einträge werden nur dann gelöscht
        oder verschoben, wenn der jeweilige Provider lokal erreichbar ist.
    .PARAMETER Path
        Optionaler Zielpfad. Standard ist `Exports` im konfigurierten Data Root.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .PARAMETER CmsProvider
        Optionaler Provider eines verwalteten lokalen CMS. Lokale Containerziele
        erhalten dafür den passenden Host-Alias.
    .OUTPUTS
        PSCustomObject mit Exportpfad und Endpunktanzahl.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$StateRoot, [ValidateSet('docker', 'podman')][string]$CmsProvider)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $center = (Sync-SqlServerLabConnectionCenter -StateRoot $StateRoot -Quiet).ConnectionCenter
    $cmsConfiguration = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if ($cmsConfiguration) {
        # Ein CMS darf nicht als Ziel in seinem eigenen verwalteten Unterbaum
        # erscheinen. Die lokale Verbindungszentrale darf ihn weiterhin zeigen.
        $center.Entries = @($center.Entries | Where-Object { [string]$_.RunId -ne [string]$cmsConfiguration.RunId })
    }
    if (-not $Path) { $Path = Join-Path (Get-LabConnectionCenterExportDirectory -StateRoot $StateRoot) 'sql-server-lab-cms-sync.sql' }
    $escape = { param([string]$Value) $Value.Replace("'", "''") }
    $providerAvailability = [ordered]@{}
    foreach ($provider in @('docker', 'podman')) {
        $available = $false
        $runtimeResolution = Resolve-LabHostTool -Name $provider
        if ($runtimeResolution.Available) {
            try {
                $runtimeInvocation = [string]$runtimeResolution.Invocation
                & $runtimeInvocation info 1>$null 2>$null
                $available = ($LASTEXITCODE -eq 0)
            }
            catch { $available = $false }
        }
        $providerAvailability[$provider] = $available
    }
    $hyperVAvailable = $false
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        try {
            $null = @(Get-VM -ErrorAction Stop)
            $hyperVAvailable = $true
        }
        catch { $hyperVAvailable = $false }
    }
    $providerAvailability['hyperv'] = $hyperVAvailable

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('-- SQL Server Lab CMS-Synchronisation. Passwörter sind absichtlich nicht enthalten.')
    $lines.Add('-- Der Unterbaum SQL Server Lab ist exklusiv durch SQL Server Lab verwaltet.')
    $lines.Add('USE msdb;')
    $lines.Add('SET XACT_ABORT ON;')
    $lines.Add('BEGIN TRANSACTION;')
    $lines.Add('DECLARE @DatabaseEngineRootId int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE server_type = 0 AND is_system_object = 1 ORDER BY server_group_id);')
    $lines.Add("IF @DatabaseEngineRootId IS NULL THROW 51000, 'CMS database-engine root group was not found.', 1;")
    $lines.Add("DECLARE @ManagedRootId int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$(& $escape $center.Grouping.RootGroupName)' AND parent_id = @DatabaseEngineRootId);")
    if ([bool]$center.Grouping.CmsUseRootGroup) {
        $lines.Add("IF @ManagedRootId IS NULL BEGIN EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @name = N'$(& $escape $center.Grouping.RootGroupName)', @description = N'ManagedBy=SQL_Server_Lab;Contract=1.0', @server_type = 0, @parent_id = @DatabaseEngineRootId, @server_group_id = @ManagedRootId OUTPUT; END;")
        $lines.Add('DECLARE @LabRootId int = @ManagedRootId;')
    }
    else {
        $lines.Add('DECLARE @LabRootId int = @DatabaseEngineRootId;')
    }
    $lines.Add("DECLARE @RunningId int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'Running' AND parent_id = @LabRootId);")
    $lines.Add("IF @RunningId IS NULL BEGIN EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @name = N'Running', @description = N'SQL Server Lab: aktive SQL-Endpunkte', @server_type = 0, @parent_id = @LabRootId, @server_group_id = @RunningId OUTPUT; END;")
    $lines.Add("DECLARE @StoppedId int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'Stopped' AND parent_id = @LabRootId);")
    $lines.Add("IF @StoppedId IS NULL BEGIN EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @name = N'Stopped', @description = N'SQL Server Lab: gestoppte SQL-Endpunkte', @server_type = 0, @parent_id = @LabRootId, @server_group_id = @StoppedId OUTPUT; END;")

    $reconciledProviders = @()
    $skippedProviders = @()
    foreach ($provider in $providerAvailability.Keys) {
        $providerEntries = @($center.Entries | Where-Object { [string]$_.Provider -eq $provider })
        $providerName = $provider.ToUpperInvariant()
        $suffix = $providerName -replace '[^A-Z0-9_]', '_'
        $safeProviderName = & $escape $providerName
        $legacyGroupName = & $escape ('{0} - {1}' -f $center.Grouping.RootGroupName, $providerName)
        if (-not $providerAvailability[$provider]) {
            $skippedProviders += $provider
            $lines.Add("-- Provider '$provider' ist nicht sicher pruefbar; vorhandene Eintraege bleiben unveraendert.")
            continue
        }

        $reconciledProviders += $provider
        $lines.Add("DECLARE @RunningProvider_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$safeProviderName' AND parent_id = @RunningId);")
        $lines.Add("DECLARE @StoppedProvider_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$safeProviderName' AND parent_id = @StoppedId);")
        if ([bool]$center.Grouping.CmsGroupByProvider) {
            $lines.Add("IF @RunningProvider_$suffix IS NULL BEGIN EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @name = N'$safeProviderName', @description = N'SQL Server Lab Providergruppe', @server_type = 0, @parent_id = @RunningId, @server_group_id = @RunningProvider_$suffix OUTPUT; END;")
            $lines.Add("IF @StoppedProvider_$suffix IS NULL BEGIN EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @name = N'$safeProviderName', @description = N'SQL Server Lab Providergruppe', @server_type = 0, @parent_id = @StoppedId, @server_group_id = @StoppedProvider_$suffix OUTPUT; END;")
        }
        $lines.Add("DECLARE @LegacyProvider_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$legacyGroupName' AND parent_id = @ManagedRootId);")
        $lines.Add("DECLARE @OldManagedRunning_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'Running' AND parent_id = @ManagedRootId);")
        $lines.Add("DECLARE @OldManagedStopped_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'Stopped' AND parent_id = @ManagedRootId);")
        $lines.Add("DECLARE @OldRunningProvider_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$safeProviderName' AND parent_id = @OldManagedRunning_$suffix);")
        $lines.Add("DECLARE @OldStoppedProvider_$suffix int = (SELECT TOP (1) server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'$safeProviderName' AND parent_id = @OldManagedStopped_$suffix);")
        $lines.Add("DECLARE CmsServerCursor_$suffix CURSOR LOCAL FAST_FORWARD FOR SELECT server_id FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_group_id IN (@RunningProvider_$suffix, @StoppedProvider_$suffix, @LegacyProvider_$suffix, @OldRunningProvider_$suffix, @OldStoppedProvider_$suffix) OR (server_group_id IN (@RunningId, @StoppedId, @OldManagedRunning_$suffix, @OldManagedStopped_$suffix) AND description LIKE N'ManagedBy=SQL_Server_Lab;%;Provider=$provider;%');")
        $lines.Add("DECLARE @DeleteServerId_$suffix int; OPEN CmsServerCursor_$suffix; FETCH NEXT FROM CmsServerCursor_$suffix INTO @DeleteServerId_$suffix;")
        $lines.Add("WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_sysmanagement_delete_shared_registered_server @server_id = @DeleteServerId_$suffix; FETCH NEXT FROM CmsServerCursor_$suffix INTO @DeleteServerId_$suffix; END; CLOSE CmsServerCursor_$suffix; DEALLOCATE CmsServerCursor_$suffix;")

        foreach ($entry in @($providerEntries | Sort-Object RuntimeState, DisplayName, Server)) {
            $server = & $escape (ConvertTo-LabCmsServerTarget -Server $entry.Server -CmsProvider $CmsProvider)
            $displayName = & $escape $entry.DisplayName
            $runtimeState = ([string]$entry.RuntimeState).ToUpperInvariant()
            if ([bool]$center.Grouping.CmsGroupByProvider) {
                $targetGroup = if ($runtimeState -eq 'RUNNING') { "@RunningProvider_$suffix" } else { "@StoppedProvider_$suffix" }
            }
            else {
                $targetGroup = if ($runtimeState -eq 'RUNNING') { '@RunningId' } else { '@StoppedId' }
            }
            $identity = & $escape ([string]$entry.Id)
            $description = & $escape ("ManagedBy=SQL_Server_Lab;Contract=1.0;Identity={0};Provider={1};RuntimeState={2}" -f $entry.Id, $provider, $runtimeState)
            $variableSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $lines.Add("DECLARE @ServerId_$variableSuffix int;")
            $lines.Add("EXEC msdb.dbo.sp_sysmanagement_add_shared_registered_server @name = N'$displayName', @server_group_id = $targetGroup, @server_name = N'$server', @description = N'$description', @server_type = 0, @server_id = @ServerId_$variableSuffix OUTPUT;")
        }

        $lines.Add("IF @LegacyProvider_$suffix IS NOT NULL AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_group_id = @LegacyProvider_$suffix) EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @LegacyProvider_$suffix;")
        if (-not [bool]$center.Grouping.CmsGroupByProvider) {
            $lines.Add("IF @RunningProvider_$suffix IS NOT NULL AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_group_id = @RunningProvider_$suffix) EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @RunningProvider_$suffix;")
            $lines.Add("IF @StoppedProvider_$suffix IS NOT NULL AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_group_id = @StoppedProvider_$suffix) EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @StoppedProvider_$suffix;")
        }
    }
    foreach ($group in @($center.Entries | Group-Object Provider | Where-Object { $_.Name -notin $providerAvailability.Keys })) {
        $skippedProviders += [string]$group.Name
        $lines.Add("-- Unbekannter Provider '$(& $escape ([string]$group.Name))' wird nicht veraendert.")
    }
    if (-not [bool]$center.Grouping.CmsUseRootGroup) {
        $lines.Add("DECLARE EmptyGroupCursor CURSOR LOCAL FAST_FORWARD FOR SELECT server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups g WHERE g.parent_id IN (SELECT server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE parent_id = @ManagedRootId) AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers s WHERE s.server_group_id = g.server_group_id) AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_server_groups c WHERE c.parent_id = g.server_group_id);")
        $lines.Add('DECLARE @EmptyGroupId int; OPEN EmptyGroupCursor; FETCH NEXT FROM EmptyGroupCursor INTO @EmptyGroupId; WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @EmptyGroupId; FETCH NEXT FROM EmptyGroupCursor INTO @EmptyGroupId; END; CLOSE EmptyGroupCursor; DEALLOCATE EmptyGroupCursor;')
        $lines.Add("DECLARE EmptyStatusCursor CURSOR LOCAL FAST_FORWARD FOR SELECT server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups g WHERE g.parent_id = @ManagedRootId AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers s WHERE s.server_group_id = g.server_group_id) AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_server_groups c WHERE c.parent_id = g.server_group_id);")
        $lines.Add('OPEN EmptyStatusCursor; FETCH NEXT FROM EmptyStatusCursor INTO @EmptyGroupId; WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @EmptyGroupId; FETCH NEXT FROM EmptyStatusCursor INTO @EmptyGroupId; END; CLOSE EmptyStatusCursor; DEALLOCATE EmptyStatusCursor;')
        $lines.Add("IF @ManagedRootId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_group_id = @ManagedRootId) AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmanagement_shared_server_groups WHERE parent_id = @ManagedRootId) EXEC msdb.dbo.sp_sysmanagement_delete_shared_server_group @server_group_id = @ManagedRootId;")
    }
    $lines.Add('COMMIT TRANSACTION;')
    $directory = Split-Path -Parent $Path
    if ($directory) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{
        Path = $Path
        Entries = $center.Entries.Count
        ReconciledProviders = @($reconciledProviders)
        SkippedProviderUnavailable = @($skippedProviders | Sort-Object -Unique)
    }
}

function Sync-SqlServerLabCms {
    <#
    .SYNOPSIS
        Aktualisiert einen verwalteten lokalen CMS aus der Verbindungszentrale.
    .DESCRIPTION
        Schreibt den aktuellen CMS-Synchronisationsplan und führt ihn mit dem
        run-lokal geschützten CMS-SA-Passwort auf dem verwalteten CMS aus.
    .PARAMETER StateRoot
        Optionaler State Root. Ohne Angabe wird der konfigurierte Standard verwendet.
    .PARAMETER Quiet
        Unterdrückt die Erfolgsmeldung für automatische Lifecycle-Synchronisationen.
    .OUTPUTS
        PSCustomObject mit Pfad und Anzahl synchronisierter Endpunkte oder `$null` ohne CMS.
    #>
    [CmdletBinding()]
    param([string]$StateRoot, [switch]$Quiet)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $configuration = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if (-not $configuration) { return $null }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') ([string]$configuration.RunId)
    $password = Get-LabSecret -Path $runDirectory -Name 'sa-password'
    if (-not $password) { throw 'CONNECTION_CENTER_CMS_SECRET_UNAVAILABLE: Das CMS-SA-Passwort kann nicht lokal entschlüsselt werden.' }
    $scriptPath = Join-Path (Get-LabConnectionCenterExportDirectory -StateRoot $StateRoot) 'sql-server-lab-cms-sync.sql'
    $export = Export-SqlServerLabCmsSyncScript -Path $scriptPath -StateRoot $StateRoot -CmsProvider ([string]$configuration.Provider)
    $execution = Invoke-SqlServerLabScript -RunId ([string]$configuration.RunId) -SaPassword $password -ScriptPath $export.Path -Database 'master' -StateRoot $StateRoot
    if (-not $execution.Success) { throw "CONNECTION_CENTER_CMS_SYNC_FAILED: $($execution.Message)" }
    if (-not $Quiet) { Write-LabSuccess "CMS synchronisiert: $($export.Entries) Endpunkt(e)." }
    return $export
}

function Invoke-LabCmsInteractive {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $configuration = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    Write-Host ''
    Write-Host '  CMS-Verwaltung' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkCyan
    if (-not $configuration) {
        Write-LabInfo 'Kein verwalteter CMS vorhanden.'
        $availableProviders = @(Get-AvailableLabProviders)
        $containerProviders = @('docker', 'podman' | Where-Object { $_ -in $availableProviders })
        $candidates = @(Get-LabConnectionCenterCmsEnvironmentCandidates -StateRoot $StateRoot)
        $candidateSummary = if ($candidates.Count -gt 0) {
            (($candidates | Group-Object Provider | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }) -join ' · ')
        }
        else { 'keine geeignete bestehende SQL-Umgebung' }
        $menu = Invoke-LabConsoleMenu -ScreenId 'cms-create-menu' -Title 'CMS bereitstellen' -Subtitle 'Docker/Podman primaer; vorhandene SQL-Umgebung providerneutral uebernehmen' -Items @(
            New-LabConsoleItem -Id create -Label 'Kompakten persistenten CMS automatisch erstellen' -Value 'Docker bevorzugt · Podman als Fallback' -Shortcut 1 -Disabled:($containerProviders.Count -eq 0)
            New-LabConsoleItem -Id adopt -Label 'Bestehende SQL-Umgebung als CMS verwenden' -Value $candidateSummary -Shortcut 2 -Disabled:($candidates.Count -eq 0)
            New-LabConsoleItem -Id export -Label 'Nur CMS-Synchronisationsskript exportieren' -Shortcut 3
            New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
        ) -Footer 'Pfeile: Navigation  Enter/Shortcut: Auswahl  Esc: Zurueck'
        if ($menu.Status -ne 'Selected' -or [string]$menu.SelectedItem.Id -eq 'back') { return }
        if ([string]$menu.SelectedItem.Id -eq 'create') {
            if (-not (Read-LabConfirm -Prompt '  Persistenten kompakten CMS jetzt erstellen?' -Default $false)) { return }
            $result = Initialize-SqlServerLabCms -StateRoot $StateRoot
            Write-LabSuccess "CMS erstellt: Run $($result.Configuration.RunId)"
            Write-LabWarning "Einmaliges CMS-SA-Passwort (jetzt kopieren): $($result.Password)"
            $null = Sync-SqlServerLabCms -StateRoot $StateRoot
        }
        elseif ([string]$menu.SelectedItem.Id -eq 'adopt') {
            $candidateItems = @(
                for ($index = 0; $index -lt $candidates.Count; $index++) {
                    $candidate = $candidates[$index]
                    New-LabConsoleItem -Id $candidate.RunId -Label $candidate.Name -Value ("{0} · {1} · Run {2}" -f $candidate.Provider, $candidate.State, $candidate.RunId.Substring(0, [Math]::Min(8, $candidate.RunId.Length))) -Shortcut ([string]($index + 1))
                }
            )
            $selection = Invoke-LabConsoleMenu -ScreenId 'cms-adopt-select' -Title 'SQL-Umgebung als CMS verwenden' -Subtitle 'Die Umgebung wird als geschuetzter CMS-Systemdienst registriert' -Items $candidateItems -Footer 'Pfeile: Navigation  Enter/Shortcut: Auswahl  Esc: Zurueck'
            if ($selection.Status -ne 'Selected') { return }
            $selected = @($candidates | Where-Object RunId -eq ([string]$selection.SelectedItem.Id) | Select-Object -First 1)[0]
            $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $selected.RunId
            $storedPassword = Get-LabSecret -Path $runDirectory -Name 'sa-password'
            $providedPassword = $null
            if (-not $storedPassword) {
                Write-LabInfo 'Fuer diesen Run ist kein lokal geschuetztes SA-Passwort vorhanden.'
                $providedPassword = Read-Host '  SA-Passwort fuer CMS-Synchronisation' -AsSecureString
                if (-not $providedPassword -or $providedPassword.Length -eq 0) { Write-LabWarning 'CMS-Uebernahme abgebrochen: Passwort fehlt.'; return }
            }
            Write-LabInfo "Run $($selected.RunId) bleibt bestehen und wird als CMS-Systemdienst geschuetzt. Es wird keine neue VM und kein neuer Container erzeugt."
            if (-not (Read-LabConfirm -Prompt '  Diese SQL-Umgebung jetzt als CMS verwenden?' -Default $false)) { return }
            $result = Register-SqlServerLabCmsEnvironment -RunId $selected.RunId -SaPassword $providedPassword -StateRoot $StateRoot
            Write-LabSuccess "CMS registriert: Run $($result.Configuration.RunId) · Provider $($result.Configuration.Provider)"
            if ([string]$selected.State -eq 'RUNNING') { $null = Sync-SqlServerLabCms -StateRoot $StateRoot }
            else { Write-LabWarning 'Der CMS ist derzeit nicht gestartet. Nach dem Start kann die Synchronisation fortgesetzt werden.' }
        }
        elseif ([string]$menu.SelectedItem.Id -eq 'export') { $result = Export-SqlServerLabCmsSyncScript -StateRoot $StateRoot; Write-LabSuccess "CMS-Synchronisationsskript erstellt: $($result.Path)" }
        return
    }
    Write-Host "  Verwalteter CMS: $($configuration.RunId) · Provider: $($configuration.Provider)" -ForegroundColor White
    $cmsTarget = $null
    try {
        $cmsConnectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$configuration.RunId)) 'connection-info.json'
        $cmsConnection = Get-Content -LiteralPath $cmsConnectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $cmsInstance = @($cmsConnection.instances | Where-Object { [string]$_.id -eq 'primary' } | Select-Object -First 1)[0]
        $cmsTarget = ConvertFrom-LabConnectionStringTarget -ConnectionString ([string]$cmsInstance.connectionString) -Instance $cmsInstance
    }
    catch { }
    if ($cmsTarget) { Write-Host "  SSMS-CMS-Server: $cmsTarget" -ForegroundColor White }
    Write-Host '  Anzeige in SSMS: Ansicht -> Registrierte Server -> Datenbankmodul -> Zentrale Verwaltungsserver' -ForegroundColor DarkGray
    Write-Host "  Dort den CMS-Server registrieren/aktualisieren und 'SQL Server Lab -> Running' aufklappen." -ForegroundColor DarkGray
    $menu = Invoke-LabConsoleMenu -ScreenId 'connection-center-cms' -Title 'CMS verwalten und synchronisieren' `
        -Subtitle $(if ($cmsTarget) { "CMS: $cmsTarget" } else { 'CMS-Ziel wird aus der Konfiguration ermittelt' }) -Items @(
            New-LabConsoleItem -Id '1' -Label 'CMS jetzt synchronisieren' -Shortcut '1'
            New-LabConsoleItem -Id '2' -Label 'CMS-Synchronisationsskript exportieren' -Shortcut '2'
            New-LabConsoleItem -Id '3' -Label 'CMS-Ordnerstruktur konfigurieren' -Shortcut '3'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
    if ($menu.Status -ne 'Selected') { return }
    $choice = [string]$menu.SelectedItem.Id
    if ($choice -eq '1') { $null = Sync-SqlServerLabCms -StateRoot $StateRoot }
    elseif ($choice -eq '2') { $result = Export-SqlServerLabCmsSyncScript -StateRoot $StateRoot -CmsProvider ([string]$configuration.Provider); Write-LabSuccess "CMS-Synchronisationsskript erstellt: $($result.Path)" }
    elseif ($choice -eq '3') {
        $layout = Get-LabConnectionCenterConfiguration -StateRoot $StateRoot
        Write-LabInfo ("Aktuell: Root-Ordner={0}, Provider-Ordner={1}" -f $(if ($layout.CmsUseRootGroup) { 'Ein' } else { 'Aus' }), $(if ($layout.CmsGroupByProvider) { 'Ein' } else { 'Aus' }))
        $useRoot = Read-LabConfirm -Prompt "  Eigenen Root-Ordner '$($layout.RootGroupName)' unter dem CMS verwenden?" -Default ([bool]$layout.CmsUseRootGroup)
        $groupByProvider = Read-LabConfirm -Prompt '  Provider-Ordner unter Running/Stopped verwenden?' -Default ([bool]$layout.CmsGroupByProvider)
        $saved = Set-LabConnectionCenterConfiguration -RootGroupName ([string]$layout.RootGroupName) -CmsUseRootGroup $useRoot -CmsGroupByProvider $groupByProvider -StateRoot $StateRoot
        Write-LabSuccess ("CMS-Ordnerstruktur gespeichert: Root-Ordner={0}, Provider-Ordner={1}" -f $(if ($saved.CmsUseRootGroup) { 'Ein' } else { 'Aus' }), $(if ($saved.CmsGroupByProvider) { 'Ein' } else { 'Aus' }))
        if (Read-LabConfirm -Prompt '  CMS jetzt mit der neuen Ordnerstruktur synchronisieren?' -Default $true) { $null = Sync-SqlServerLabCms -StateRoot $StateRoot }
    }
}

function Invoke-LabConnectionCenterInteractive {
    [CmdletBinding()]
    param()

    $stateRoot = Get-LabStateRoot
    while ($true) {
        $center = Get-SqlServerLabConnectionCenter -StateRoot $stateRoot
        $menu = Invoke-LabConsoleMenu -ScreenId 'connection-center' -Title 'SQL-Verbindungszentrale' `
            -Subtitle "Gruppe: $($center.Grouping.RootGroupName) · SQL-Endpunkte: $($center.Entries.Count)" -Items @(
                New-LabConsoleItem -Id '1' -Label 'Status anzeigen und Katalog synchronisieren' -Shortcut '1'
                New-LabConsoleItem -Id '2' -Label 'Sicheren SSMS-Importweg anzeigen' -Shortcut '2'
                New-LabConsoleItem -Id '3' -Label 'Kennwortfreien SSMS-.regsrvr-Export erstellen' -Shortcut '3'
                New-LabConsoleItem -Id '4' -Label 'CMS verwalten und synchronisieren' -Shortcut '4'
                New-LabConsoleItem -Id '5' -Label 'Servergruppe konfigurieren' -Shortcut '5'
                New-LabConsoleItem -Id '6' -Label 'Jetzt synchronisieren' -Shortcut '6'
                New-LabConsoleItem -Id '7' -Label 'Änderungs-Vorschau' -Shortcut '7'
                New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
            )
        if ($menu.Status -ne 'Selected') { return }
        $choice = [string]$menu.SelectedItem.Id
        switch ($choice) {
            '0' { return }
            '1' { $result = Sync-SqlServerLabConnectionCenter -StateRoot $stateRoot; foreach ($entry in $result.ConnectionCenter.Entries) { Write-Host ('    [{0}] {1} -> {2}' -f $entry.RuntimeState, $entry.DisplayName, $entry.Server) -ForegroundColor DarkGray } }
            '2' { Write-LabInfo 'Die versionsabhängige lokale SSMS-Datei wird nicht direkt verändert. Mit [3] einen validen Export nach Lab_Data/Exports erstellen und ihn in SSMS unter Ansicht -> Registrierte Server -> Aufgaben -> Importieren importieren.' }
            '3' { $result = Export-SqlServerLabSsmsRegistration -StateRoot $stateRoot; Write-LabSuccess "SSMS-Export erstellt: $($result.Path)" }
            '4' { Invoke-LabCmsInteractive -StateRoot $stateRoot }
            '5' { $name = Read-Host "  Name der verwalteten SSMS-/CMS-Gruppe [$($center.Grouping.RootGroupName)]"; if (-not $name) { $name = $center.Grouping.RootGroupName }; $saved = Set-LabConnectionCenterConfiguration -RootGroupName $name -CmsUseRootGroup ([bool]$center.Grouping.CmsUseRootGroup) -CmsGroupByProvider ([bool]$center.Grouping.CmsGroupByProvider) -StateRoot $stateRoot; Write-LabSuccess "Gruppenname gespeichert: $($saved.RootGroupName)" }
            '6' { $null = Sync-SqlServerLabConnectionCenter -StateRoot $stateRoot }
            '7' { foreach ($entry in $center.Entries) { Write-Host ('    {0} / {1}: {2} ({3})' -f $center.Grouping.RootGroupName, $entry.Group, $entry.Server, $entry.RuntimeState) -ForegroundColor DarkGray } }
            default { Write-LabWarning 'Ungültige Auswahl.' }
        }
    }
}
