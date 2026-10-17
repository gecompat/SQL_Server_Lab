# Fester Gastcode: ausschließlich Speicherdiagnose mit der zur SQL-Version gehörenden SSIS-Runtime.
function Get-LabSsisPackageDiagnosticGuest {
    [CmdletBinding()]
    param()
    return {
        param([byte[]]$PackageBytes,[string]$ExpectedPackageSha256,[int]$ExpectedMajor)
        $ErrorActionPreference='Stop'
        $package=$null;$application=$null;$assembly=$null
        $hash='';$events=@();$connections=@();$providers=@();$declaredConnections=@();$declaredProviders=@()
        $runtime=$null;$loadedObjects=$null;$status='INCONCLUSIVE';$reason='RUNTIME_UNAVAILABLE';$load='NOT_ATTEMPTED';$exceptionCode=$null
        $inventoryComplete=$false;$eventsTruncated=$false
        try {
            if ($PackageBytes.Length -lt 1 -or $PackageBytes.Length -gt 8MB -or $ExpectedMajor -notin @(15,16,17)) { throw 'INPUT_INVALID' }
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash($PackageBytes))).Replace('-','')} finally {$sha.Dispose()}
            if ($hash -cne $ExpectedPackageSha256) { $reason='PACKAGE_HASH_MISMATCH';throw 'INPUT_INVALID' }
            $reason='PACKAGE_XML_INVALID'
            # XML-Deklaration/BOM bestimmen die Kodierung; DTD und externe Auflösung bleiben gesperrt.
            $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver=$null;$settings.MaxCharactersInDocument=8MB
            $memory=[IO.MemoryStream]::new($PackageBytes,$false)
            $reader=$null;$textReader=$null;$stringReader=$null
            try {
                $textReader=[IO.StreamReader]::new($memory,[Text.UTF8Encoding]::new($false,$true),$true)
                $originalXml=$textReader.ReadToEnd()
                $stringReader=[IO.StringReader]::new($originalXml)
                $reader=[Xml.XmlReader]::Create($stringReader,$settings)
                $xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true;$xml.Load($reader)
            } finally {if($reader){$reader.Dispose()};if($stringReader){$stringReader.Dispose()};if($textReader){$textReader.Dispose()};$memory.Dispose()}
            if ($xml.DocumentElement.LocalName -cne 'Executable' -or $xml.DocumentElement.NamespaceURI -cne 'www.microsoft.com/SqlServer/Dts') { throw 'INPUT_INVALID' }
            function Read-SsisCreationNames {
                param($Nodes)
                if ($Nodes.Count -gt 512) { throw 'COMPONENT_LIMIT' }
                @($Nodes | ForEach-Object {
                    $value=$_.GetAttribute('CreationName','www.microsoft.com/SqlServer/Dts')
                    if ($value -cmatch '^[A-Za-z0-9_{}.,:=+ -]{1,512}$') {$value} else {'UNREPORTED'}
                } | Sort-Object -Unique)
            }
            $declaredConnections=@(Read-SsisCreationNames $xml.SelectNodes('//*[local-name()="ConnectionManager" and namespace-uri()="www.microsoft.com/SqlServer/Dts" and @*[local-name()="CreationName"]]'))
            $declaredProviders=@(Read-SsisCreationNames $xml.SelectNodes('//*[local-name()="LogProvider" and namespace-uri()="www.microsoft.com/SqlServer/Dts" and @*[local-name()="CreationName"]]'))
            $reason='RUNTIME_UNAVAILABLE'
            if (-not [Environment]::Is64BitProcess) { $reason='X64_RUNTIME_REQUIRED';throw 'RUNTIME_INVALID' }
            $assembly=[Reflection.Assembly]::Load("Microsoft.SqlServer.ManagedDTS, Version=$ExpectedMajor.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")
            if ($assembly.GetName().Version.Major -ne $ExpectedMajor) { throw 'RUNTIME_INVALID' }
            $runtime=[pscustomobject]@{
                AssemblyIdentity=$assembly.FullName
                FileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($assembly.Location).FileVersion
                ProcessBitness=64;OperatingSystemBitness=$(if([Environment]::Is64BitOperatingSystem){64}else{32})
                ClrVersion=[Environment]::Version.ToString();PowerShellVersion=$PSVersionTable.PSVersion.ToString()
            }
            # Statischer Event-Collector: keine Texte, Objekt-/Hostnamen oder Connection Strings.
            if (-not ('SqlServerLab.SsisLoadEvents' -as [type])) {
                Add-Type -ReferencedAssemblies $assembly.Location -TypeDefinition @'
using System;
using Microsoft.SqlServer.Dts.Runtime;
namespace SqlServerLab {
    public sealed class SsisLoadEvent {
        public string Kind;
        public int Code;
    }
    public sealed class SsisLoadEvents : DefaultEvents {
        public readonly SsisLoadEvent[] Items = new SsisLoadEvent[256];
        private int count;
        public bool Truncated;
        private void Record(string kind, int code) {
            if (count >= 256) { Truncated = true; return; }
            Items[count++] = new SsisLoadEvent { Kind = kind, Code = code };
        }
        public override bool OnError(DtsObject source, int code, string subComponent,
            string description, string helpFile, int helpContext, string id) {
            Record("ERROR", code); return false;
        }
        public override void OnWarning(DtsObject source, int code, string subComponent,
            string description, string helpFile, int helpContext, string id) {
            Record("WARNING", code);
        }
    }
}
'@ | Out-Null
            }
            $reason='COMPONENT_INVENTORY_FAILED'
            $application=New-Object Microsoft.SqlServer.Dts.Runtime.Application
            function Read-SsisInventory {
                param($Items)
                $values=[Collections.Generic.List[string]]::new()
                foreach ($item in $Items) {
                    if ($values.Count -ge 512) { throw 'COMPONENT_LIMIT' }
                    $value=[string]$item.CreationName
                    if ($value -cnotmatch '^[A-Za-z0-9_{}.,:=+ -]{1,512}$') { throw 'COMPONENT_NAME_INVALID' }
                    $values.Add($value)
                }
                @($values | Sort-Object -Unique)
            }
            $connections=@(Read-SsisInventory $application.ConnectionInfos)
            $providers=@(Read-SsisInventory $application.LogProviderInfos)
            $inventoryComplete=$true
            $collector=New-Object SqlServerLab.SsisLoadEvents
            $package=New-Object Microsoft.SqlServer.Dts.Runtime.Package
            $reason='PACKAGE_LOAD_FAILED';$load='FAILED'
            try {
                # Kein Validate, Execute oder AcquireConnections; Originaldokument bleibt unverändert.
                $package.LoadFromXML($originalXml,$collector)
                $load='RETURNED'
            } catch { $exceptionCode=[int]$_.Exception.GetBaseException().HResult }
            $loadedObjects=[pscustomobject]@{ConnectionManagers=[int]$package.Connections.Count;LogProviders=[int]$package.LogProviders.Count;Executables=[int]$package.Executables.Count}
            $events=@($collector.Items | Where-Object {$null -ne $_} | ForEach-Object {[pscustomobject]@{Kind=$_.Kind;Code=$_.Code}})
            $eventsTruncated=[bool]$collector.Truncated
            foreach ($errorItem in $package.Errors) {
                if ($events.Count -ge 256) { $eventsTruncated=$true;break }
                $events+= [pscustomobject]@{Kind='PACKAGE_ERROR';Code=[int]$errorItem.ErrorCode}
            }
            if ($eventsTruncated) {$reason='EVENT_LIMIT'}
            elseif ($load -eq 'RETURNED' -and @($events | Where-Object Kind -in @('ERROR','PACKAGE_ERROR')).Count -eq 0) {$status='OBSERVED';$reason='NONE'}
            else {$status='LOAD_FAILED'}
        }
        catch { $status='INCONCLUSIVE' }
        finally { if($package){$package.Dispose()};if($application -is [IDisposable]){$application.Dispose()} }
        [pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.SsisPackageGuest/1.0';PackageSha256=$hash
            Status=$status;ReasonCode=$reason;Runtime=$runtime
            Inventory=[pscustomobject]@{Complete=$inventoryComplete;ConnectionManagers=$connections;LogProviders=$providers}
            Serialized=[pscustomobject]@{ConnectionManagers=$declaredConnections;LogProviders=$declaredProviders}
            LoadStatus=$load;LoadedObjectCounts=$loadedObjects;ExceptionHResult=$exceptionCode;Events=$events;EventsTruncated=$eventsTruncated
            ExecutionStatus='NOT_EXECUTED'
        }
    }
}
