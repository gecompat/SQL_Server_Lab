<#
.SYNOPSIS
    Rein lesende Identitätsprüfung bestehender Loopback-Ollama-Modelle.
#>
function Invoke-LabAiHostMetadata {
    [CmdletBinding()]
    param([int]$Port,[ValidateSet('/api/version','/api/tags','/api/show')][string]$Path,[string]$Model)
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler,$true)
    $client.Timeout=[TimeSpan]::FromSeconds(15)
    $message=$null;$response=$null
    try {
        $method=if($Path -eq '/api/show'){[Net.Http.HttpMethod]::Post}else{[Net.Http.HttpMethod]::Get}
        $message=[Net.Http.HttpRequestMessage]::new($method,"http://127.0.0.1:$Port$Path")
        if($Path -eq '/api/show'){$message.Content=[Net.Http.StringContent]::new((@{model=$Model}|ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')}
        $response=$client.SendAsync($message).GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){throw 'AI_RAG_HOST_METADATA_FAILED'}
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch {throw 'AI_RAG_HOST_METADATA_FAILED'}
    finally {if($response){$response.Dispose()};if($message){$message.Dispose()};$client.Dispose()}
}

function Get-LabAiHostModelBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[scriptblock]$MetadataTransport)
    if($Plan.Lane -cne 'local' -or $Plan.InternalBaseUri -cne "http://127.0.0.1:$($Plan.Port)"){throw 'AI_RAG_HOST_ENDPOINT_INVALID'}
    $entry=Get-LabAiModelCatalogEntry -ModelKey $Plan.ModelKey
    $read={param($Path)if($MetadataTransport){& $MetadataTransport $Path $Plan.InternalModel}else{Invoke-LabAiHostMetadata -Port $Plan.Port -Path $Path -Model $Plan.InternalModel}}
    $version=& $read '/api/version'
    if([string]$version.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [version]$version.version -lt [version]$entry.minimumOllamaVersion){throw 'AI_RAG_HOST_VERSION_UNSUPPORTED'}
    $tags=& $read '/api/tags'
    $candidates=@($tags.models|Where-Object{[string]$_.name -ceq $Plan.InternalModel})
    if($candidates.Count -ne 1 -or [string]$candidates[0].digest -cnotmatch '^(sha256:)?[a-f0-9]{64}$'){throw 'AI_RAG_HOST_MODEL_IDENTITY_INVALID'}
    $show=& $read '/api/show'
    foreach($record in @($candidates[0],$show)){
        foreach($name in @('remote_model','remote_host')){
            $property=$record.PSObject.Properties[$name]
            if($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){throw 'AI_RAG_HOST_REMOTE_MODEL_FORBIDDEN'}
        }
    }
    $capability=if($Plan.Purpose -eq 'embedding'){'embedding'}else{'completion'}
    if(@($show.capabilities) -cnotcontains $capability){throw 'AI_RAG_HOST_CAPABILITY_INVALID'}
    if($Plan.Purpose -eq 'embedding'){
        $dimensions=@($show.model_info.PSObject.Properties|Where-Object Name -Like '*.embedding_length')
        if($dimensions.Count -ne 1 -or [int]$dimensions[0].Value -ne [int]$Plan.Dimension){throw 'AI_RAG_HOST_DIMENSION_INVALID'}
    }
    [pscustomobject]@{ModelKey=$Plan.ModelKey;Model=$Plan.InternalModel;Digest=([string]$candidates[0].digest -replace '^sha256:','');Version=[string]$version.version;Dimension=$Plan.Dimension}
}

function Assert-LabAiHostModelBinding {
    [CmdletBinding()]
    param($Plan,$Expected,[scriptblock]$MetadataTransport)
    $actual=Get-LabAiHostModelBinding -Plan $Plan -MetadataTransport $MetadataTransport
    if((Get-LabAiPlanKey -InputObject $actual) -cne (Get-LabAiPlanKey -InputObject $Expected)){throw 'AI_RAG_HOST_MODEL_DRIFT'}
}
