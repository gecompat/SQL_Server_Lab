function Assert-LabLlamaInstallerUri {
    param([uri]$Uri)
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or
        $Uri.DnsSafeHost -cnotin @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')) { throw 'LLAMA_INSTALL_HOST_REJECTED' }
}

function Send-LabLlamaInstallerHttp {
    param([object]$Client,[uri]$Uri,[Threading.CancellationToken]$Token)
    $Client.GetAsync($Uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$Token).GetAwaiter().GetResult()
}

function Receive-LabLlamaInstallerBytes {
    param([Parameter(Mandatory)][uri]$Uri,[ValidateRange(1,33554432)][long]$MaximumBytes,[ValidateRange(1,120)][int]$TimeoutSeconds=120)
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseProxy=$false;$handler.UseDefaultCredentials=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('SQLServerLab-LlamaInstaller/1.0')
    $cts=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        for($hop=0;$hop -le 3;$hop++) {
            Assert-LabLlamaInstallerUri $Uri
            $response=Send-LabLlamaInstallerHttp -Client $client -Uri $Uri -Token $cts.Token
            try {
                if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                    if ($hop -eq 3 -or $null -eq $response.Headers.Location) {throw 'LLAMA_INSTALL_REDIRECT_LIMIT'}
                    $Uri=[uri]::new($Uri,$response.Headers.Location);continue
                }
                if ([int]$response.StatusCode -ne 200) {throw 'LLAMA_INSTALL_HTTP_FAILED'}
                if ($response.Content.Headers.ContentLength -gt $MaximumBytes) {throw 'LLAMA_INSTALL_TRANSFER_LIMIT'}
                $inputStream=$response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
                $memory=[IO.MemoryStream]::new()
                try {
                    $buffer=[byte[]]::new(65536);[long]$total=0
                    while(($count=$inputStream.ReadAsync($buffer,0,$buffer.Length,$cts.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total+=$count
                        if($total -gt $MaximumBytes){throw 'LLAMA_INSTALL_TRANSFER_LIMIT'}
                        $memory.Write($buffer,0,$count)
                    }
                    return ,$memory.ToArray()
                } finally {$memory.Dispose();$inputStream.Dispose()}
            } finally {$response.Dispose()}
        }
        throw 'LLAMA_INSTALL_TRANSFER_FAILED'
    } catch {
        if ($_.Exception.Message -cmatch '^LLAMA_INSTALL_[A-Z_]+$') {throw $_.Exception.Message}
        throw 'LLAMA_INSTALL_TRANSFER_FAILED'
    } finally {$cts.Dispose();$client.Dispose();$handler.Dispose()}
}

function Get-LabLlamaInstallerUpstream {
    $catalog=Get-LabLlamaInstallerCatalog
    $item=$catalog.Item
    $bytes=Receive-LabLlamaInstallerBytes -Uri ('https://api.github.com/repos/ggml-org/llama.cpp/releases/'+$item.ReleaseId) -MaximumBytes 2097152 -TimeoutSeconds 20
    try {$release=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -Depth 20} catch {throw 'LLAMA_INSTALL_METADATA_INVALID'}
    $assets=@($release.assets|Where-Object id -EQ $item.AssetId)
    $url='https://github.com/ggml-org/llama.cpp/releases/download/'+$item.Tag+'/'+$item.AssetName
    if ($release.id -ne $item.ReleaseId -or $release.tag_name -cne $item.Tag -or $release.target_commitish -cne $item.Commit -or
        $assets.Count -ne 1 -or $assets[0].name -cne $item.AssetName -or $assets[0].size -ne $item.Bytes -or
        $assets[0].digest -cne ('sha256:'+$item.Sha256) -or $assets[0].browser_download_url -cne $url) {throw 'LLAMA_INSTALL_UPSTREAM_DRIFT'}
    [pscustomobject]@{Status='PIN_MATCHES_OFFICIAL_METADATA';Release=$item.Tag;Catalogued=$true;Immutable=[bool]$release.immutable;Recommendation='UNASSESSED';Notice='Offizieller API-Hash, keine unabhängige Signatur. Keine Binärdatei heruntergeladen.'}
}

function Expand-LabLlamaInstallerArchive {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][object]$Catalog)
    $file=Get-Item -LiteralPath $ArchivePath -Force
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $Catalog.Bytes -or
        (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Catalog.Sha256){throw 'LLAMA_INSTALL_ARCHIVE_HASH'}
    $null=Assert-LabLlamaInstallerPath -Path $Destination
    if(Test-Path -LiteralPath $Destination){throw 'LLAMA_INSTALL_STAGE_EXISTS'}
    $archive=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if($archive.Entries.Count -ne @($Catalog.Files).Count -or $archive.Entries.Count -gt 512){throw 'LLAMA_INSTALL_ARCHIVE_ENTRIES'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);[long]$total=0
        foreach($entry in $archive.Entries){
            $expected=@($Catalog.Files|Where-Object Name -CEQ $entry.FullName)
            $mode=($entry.ExternalAttributes -shr 16) -band 0xF000
            if($entry.FullName -cnotmatch '^(?:[a-zA-Z0-9][a-zA-Z0-9.-]*\.(?:exe|dll)|LICENSE-LLVM-OpenMP)$' -or
                $entry.FullName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\.' -or
                -not $seen.Add($entry.FullName) -or $expected.Count -ne 1 -or $mode -notin @(0,0x8000) -or
                ($entry.ExternalAttributes -band 0x410) -ne 0 -or $entry.Length -ne $expected[0].Bytes -or
                $entry.Length -gt 134217728 -or $entry.CompressedLength -le 0 -or $entry.Length/$entry.CompressedLength -gt 200){throw 'LLAMA_INSTALL_ARCHIVE_UNSAFE'}
            $total+=$entry.Length
            if($total -gt 536870912){throw 'LLAMA_INSTALL_ARCHIVE_LIMIT'}
        }
        $null=[IO.Directory]::CreateDirectory($Destination)
        foreach($entry in $archive.Entries){
            $expected=$Catalog.Files|Where-Object Name -CEQ $entry.FullName
            $null=Assert-LabLlamaInstallerPath -Path $Destination
            $inputStream=$entry.Open();$memory=[IO.MemoryStream]::new()
            try {
                $buffer=[byte[]]::new(65536);[long]$copied=0
                while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
                    $copied+=$count;if($copied -gt $expected.Bytes){throw 'LLAMA_INSTALL_ARCHIVE_LIMIT'}
                    $memory.Write($buffer,0,$count)
                }
                $data=$memory.ToArray()
                if($copied -ne $expected.Bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant() -cne $expected.Sha256){throw 'LLAMA_INSTALL_ENTRY_HASH'}
                $outputStream=[IO.File]::Open((Join-Path $Destination $entry.FullName),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$outputStream.Write($data,0,$data.Length)}finally{$outputStream.Dispose()}
            }finally{$memory.Dispose();$inputStream.Dispose()}
        }
        Test-LabLlamaInstallerFiles -Path $Destination -Catalog $Catalog
    }finally{$archive.Dispose()}
}
