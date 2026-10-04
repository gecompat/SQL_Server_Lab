# Recorded history only. This reader never verifies references or probes a runtime.
function Get-LabCapabilityEvidenceTupleKey {
    param([AllowEmptyCollection()][object[]]$Values)
    $key=[Text.StringBuilder]::new()
    foreach($value in $Values) {
        if($null -eq $value){$null=$key.Append('N;')}
        elseif($value -is [bool]){$null=$key.Append($(if($value){'B1;'}else{'B0;'}))}
        elseif($value -is [string]){$null=$key.Append('S').Append($value.Length).Append(':').Append($value).Append(';')}
        else {throw 'EVIDENCE_IDENTITY_INVALID'}
    }
    $key.ToString()
}

function Assert-LabCapabilityEvidenceJsonProperties {
    param([System.Text.Json.JsonElement]$Element)
    if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()) {
            if(-not $names.Add($property.Name)){throw 'EVIDENCE_INDEX_INVALID'}
            Assert-LabCapabilityEvidenceJsonProperties -Element $property.Value
        }
    } elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach($item in $Element.EnumerateArray()){Assert-LabCapabilityEvidenceJsonProperties -Element $item}
    }
}

function Read-LabCapabilityEvidenceIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[switch]$IncludeIdentity)
    $status='NOT_PRESENT';$reason='INDEX_NOT_PRESENT';$version=$null;$records=@();$document=$null;$stream=$null;$schemaStream=$null
    try {
        $root=[IO.Path]::GetFullPath($RepositoryRoot)
        $index=Join-Path $root 'Documentation/Quality/capability-evidence-index.json'
        # Definition-owned sources supply validation authority; RepositoryRoot is data only.
        $definitionSource=Join-Path $PSScriptRoot 'CapabilityEvidence.ps1'
        $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'Schemas/capability-evidence-index.schema.json'
        foreach($candidate in @($index,$definitionSource,$schema)) {
            $ancestor=$candidate
            while($ancestor) {
                if(Test-Path -LiteralPath $ancestor) {
                    if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'}
                }
                if($candidate -ceq $index -and $ancestor -ceq $root){break}
                $ancestor=[IO.Path]::GetDirectoryName($ancestor)
            }
        }
        if(Test-Path -LiteralPath $index) {
            $status='INVALID';$reason='INDEX_INVALID'
            foreach($sourceFile in @($definitionSource,$schema)) {
                $sourceItem=Get-Item -LiteralPath $sourceFile -Force -ErrorAction Stop
                if($sourceItem.PSIsContainer -or $sourceItem.Length -gt 262144){throw 'EVIDENCE_INDEX_INVALID'}
            }
            $schemaStream=[IO.File]::Open($schema,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $schemaBuffer=[byte[]]::new(262145);$schemaLength=0
            while($schemaLength -lt $schemaBuffer.Length) {
                $schemaRead=$schemaStream.Read($schemaBuffer,$schemaLength,$schemaBuffer.Length-$schemaLength)
                if($schemaRead -eq 0){break};$schemaLength+=$schemaRead
            }
            if($schemaLength -gt 262144){throw 'EVIDENCE_INDEX_INVALID'}
            $schemaOffset=if($schemaLength -ge 3 -and $schemaBuffer[0] -eq 239 -and $schemaBuffer[1] -eq 187 -and $schemaBuffer[2] -eq 191){3}else{0}
            $schemaText=[Text.UTF8Encoding]::new($false,$true).GetString($schemaBuffer,$schemaOffset,$schemaLength-$schemaOffset)
            $file=Get-Item -LiteralPath $index -Force
            if($file.PSIsContainer -or $file.Length -gt 262144){throw 'EVIDENCE_INDEX_INVALID'}
            $stream=[IO.File]::Open($index,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $buffer=[byte[]]::new(262145);$length=0
            while($length -lt $buffer.Length) {
                $read=$stream.Read($buffer,$length,$buffer.Length-$length)
                if($read -eq 0){break};$length+=$read
            }
            if($length -gt 262144){throw 'EVIDENCE_INDEX_INVALID'}
            $offset=if($length -ge 3 -and $buffer[0] -eq 239 -and $buffer[1] -eq 187 -and $buffer[2] -eq 191){3}else{0}
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,$offset,$length-$offset)
            $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=20
            $document=[System.Text.Json.JsonDocument]::Parse($text,$options)
            if($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object){throw 'EVIDENCE_INDEX_INVALID'}
            $versions=@($document.RootElement.EnumerateObject()|Where-Object Name -CEQ 'ContractVersion')
            if($versions.Count -eq 0 -or $versions[-1].Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String){throw 'EVIDENCE_INDEX_INVALID'}
            $version=$versions[-1].Value.GetString()
            if($version -cnotin @('SqlServerLab.CapabilityEvidenceIndex/1.0','SqlServerLab.CapabilityEvidenceIndex/1.1')) {
                $status='SCHEMA_UNSUPPORTED';$reason='INDEX_SCHEMA_UNSUPPORTED';throw 'EVIDENCE_SCHEMA_UNSUPPORTED'
            }
            if($version -ceq 'SqlServerLab.CapabilityEvidenceIndex/1.1') {
                if(-not $IncludeIdentity){$status='SCHEMA_UNSUPPORTED';$reason='INDEX_SCHEMA_UNSUPPORTED';throw 'EVIDENCE_SCHEMA_UNSUPPORTED'}
                # Only the new document version tightens duplicate/case handling.
                Assert-LabCapabilityEvidenceJsonProperties $document.RootElement
            }
            if(-not (Test-Json -Json $text -Schema $schemaText -ErrorAction Stop)){throw 'EVIDENCE_INDEX_INVALID'}
            $value=ConvertFrom-Json -InputObject $text -Depth 20 -ErrorAction Stop
            foreach($record in $value.Records) {
                $null=[DateTime]::ParseExact([string]$record.Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
            }
            $records=@($value.Records);$status='RECORDED';$reason='NONE'
        }
    } catch {
        $records=@()
        if($_.Exception.Message -ceq 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'){$status='INVALID';$reason='EVIDENCE_INDEX_REPARSE_POINT_NOT_READ'}
        elseif($_.Exception.Message -cne 'EVIDENCE_SCHEMA_UNSUPPORTED'){$status='INVALID';$reason='INDEX_INVALID'}
    } finally {
        if($null -ne $document){$document.Dispose()}
        if($null -ne $stream){$stream.Dispose()}
        if($null -ne $schemaStream){$schemaStream.Dispose()}
    }
    [pscustomobject]@{Status=$status;ReasonCode=$reason;ContractVersion=$version;Records=$records}
}

function Get-LabCapabilityEvidenceIdentityValues {
    param($Identity)
    if($Identity.Kind -ceq 'LEGACY_UNSPECIFIED'){return ,@('LEGACY_UNSPECIFIED')}
    return ,@($Identity.Kind,$Identity.TargetOperatingSystem,$Identity.TargetDistribution,$Identity.Architecture,
        $Identity.SoftwareId,$Identity.RuntimeVersion,$Identity.VariantId,$Identity.SoftwarePlanKey,$Identity.BaseImageSha256,
        $Identity.LaunchMode,$Identity.RequiredCgroupVersion)
}

function New-LabCapabilityEvidenceIdentityCells {
    param([AllowEmptyCollection()][object[]]$Records,[string]$IndexVersion)
    $groups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($record in $Records) {
        $identity=if($IndexVersion -ceq 'SqlServerLab.CapabilityEvidenceIndex/1.0'){[pscustomobject]@{Kind='LEGACY_UNSPECIFIED'}}else{$record.Identity}
        $profile=if($IndexVersion -ceq 'SqlServerLab.CapabilityEvidenceIndex/1.0'){$null}else{$record.ObservedHostProfile}
        $row=[pscustomobject][ordered]@{Capability=$record.Capability;Provider=$record.Provider;SqlVersion=$record.SqlVersion;Platform=$record.Platform;Scope=$record.Scope;
            SourceRevision=$record.SourceRevision;Test=$record.Test;Result=$record.Result;Cleanup=$record.Cleanup;Date=$record.Date;Reference=$record.Reference;
            Identity=$identity;ObservedHostProfile=$profile}
        $profileValues=if($null -eq $profile){@($null)}else{@($profile.OperatingSystem,$profile.CgroupVersion,$profile.Rootless)}
        $values=@($row.Capability,$row.Provider,$row.SqlVersion)+(Get-LabCapabilityEvidenceIdentityValues $identity)+@($row.Platform,$row.Scope)+$profileValues
        $key=Get-LabCapabilityEvidenceTupleKey $values
        if(-not $groups.ContainsKey($key)){$groups.Add($key,[Collections.Generic.List[object]]::new())}
        $groups[$key].Add($row)
    }
    $keys=[Collections.Generic.List[string]]::new([string[]]@($groups.Keys));$keys.Sort([StringComparer]::Ordinal)
    $cells=@(foreach($key in $keys) {
        $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
        $observations=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $results=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach($record in $groups[$key]) {
            $rk=Get-LabCapabilityEvidenceTupleKey @($record.Date,$record.SourceRevision,$record.Test,$record.Reference,$record.Result,$record.Cleanup)
            $ordered.Add($rk,$record)
            $ok=Get-LabCapabilityEvidenceTupleKey @($record.SourceRevision,$record.Test,$record.Date)
            if(-not $observations.ContainsKey($ok)){$observations.Add($ok,[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))}
            $null=$observations[$ok].Add((Get-LabCapabilityEvidenceTupleKey @($record.Result,$record.Cleanup)));$null=$results.Add($record.Result)
        }
        $rows=@($ordered.Values);$first=$rows[0]
        [pscustomobject][ordered]@{Capability=$first.Capability;Provider=$first.Provider;SqlVersion=$first.SqlVersion;Identity=$first.Identity;
            RecordedPlatform=$first.Platform;Scope=$first.Scope;ObservedHostProfile=$first.ObservedHostProfile;
            MappingStatus=$(if($first.Identity.Kind -ceq 'LEGACY_UNSPECIFIED'){'NOT_DEFINED'}else{'DEFINED'});
            RecordCount=$rows.Count;HistoryResults=@($results);HistoryConflict=[bool](@($observations.Values|Where-Object Count -GT 1).Count);
            Records=$rows;NativeAcceptanceStatus=$(if($first.Scope -cin @('STATIC_CONTRACT','PACKAGE')){'NOT_APPLICABLE'}else{'UNKNOWN'});
            CurrentExecutionStatus='NOT_EXECUTED';CurrentReadinessStatus='NOT_CHECKED';ReferenceVerificationStatus='NOT_VERIFIED';EvidenceBoundary='RECORDED_HISTORY_ONLY'}
    })
    return ,$cells
}

function New-LabExternalRuntimeHistoricalEvidenceResult {
    param([string]$Status,[string]$MappingStatus,[string]$ReasonCode,[AllowEmptyCollection()][object[]]$Cells=@())
    $counts=@($Cells|ForEach-Object RecordCount);$count=0;foreach($n in $counts){$count+=$n}
    [pscustomobject]@{Status=$Status;MappingStatus=$MappingStatus;ReasonCode=$ReasonCode;RecordCount=$count;Cells=@($Cells);
        ReferenceVerificationStatus='NOT_VERIFIED';EvidenceBoundary='RECORDED_HISTORY_ONLY'}
}

function Get-LabExternalRuntimeRecordedEvidence {
    param($Plan,$Recipe,[Parameter(Mandatory)][string]$RepositoryRoot)
    $unresolved=New-LabExternalRuntimeHistoricalEvidenceResult 'NOT_RECORDED' 'NOT_DEFINED' 'CATALOG_IDENTITY_UNRESOLVED'
    if($null -eq $Plan -or $null -eq $Recipe -or $Plan.Status -cne 'RESOLVED' -or $Plan.PlanKey -isnot [string] -or $Plan.PlanKey -cnotmatch '^[a-f0-9]{64}$' -or
        $Recipe.baseImage.sha256 -isnot [string] -or $Recipe.baseImage.sha256 -cnotmatch '^[a-f0-9]{64}$'){return $unresolved}
    if($Plan.Provider -cnotin @('docker','podman') -or $Plan.SqlVersion -isnot [string] -or $Plan.SqlVersion -cnotin @('2019','2022','2025') -or
        $Plan.SoftwareId -cnotin @('sql-python','sql-r','sql-java') -or $Plan.RuntimeVersion -isnot [string] -or $Plan.RuntimeVersion -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$' -or
        $Plan.VariantId -isnot [string] -or $Plan.VariantId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,127}$' -or $Recipe.operatingSystem -cnotin @('ubuntu-20.04','ubuntu-22.04','ubuntu-24.04') -or
        $Recipe.architecture -cne 'x86_64' -or $Recipe.launchContract.mode -cnotin @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2') -or
        $Recipe.launchContract.requiredCgroupVersion -isnot [string] -or $Recipe.launchContract.requiredCgroupVersion -cnotin @('1','2')){return $unresolved}
    $identity=[pscustomobject][ordered]@{Kind='EXTERNAL_RUNTIME_CONTAINER/1.0';TargetOperatingSystem='linux';TargetDistribution=$Recipe.operatingSystem;
        Architecture=$Recipe.architecture;SoftwareId=$Plan.SoftwareId;RuntimeVersion=$Plan.RuntimeVersion;VariantId=$Plan.VariantId;
        SoftwarePlanKey=$Plan.PlanKey;BaseImageSha256=$Recipe.baseImage.sha256;LaunchMode=$Recipe.launchContract.mode;RequiredCgroupVersion=$Recipe.launchContract.requiredCgroupVersion}
    $reader=Read-LabCapabilityEvidenceIndex -RepositoryRoot $RepositoryRoot -IncludeIdentity
    if($reader.Status -cne 'RECORDED') {
        $reason=if($reader.Status -ceq 'NOT_PRESENT'){'INDEX_NOT_PRESENT'}elseif($reader.Status -ceq 'SCHEMA_UNSUPPORTED'){'INDEX_SCHEMA_UNSUPPORTED'}else{'INDEX_INVALID'}
        return New-LabExternalRuntimeHistoricalEvidenceResult 'UNAVAILABLE' 'UNAVAILABLE' $reason
    }
    if($reader.ContractVersion -ceq 'SqlServerLab.CapabilityEvidenceIndex/1.0') {
        return New-LabExternalRuntimeHistoricalEvidenceResult 'NOT_RECORDED' 'NOT_DEFINED' 'INDEX_LEGACY_IDENTITY_UNKNOWN'
    }
    $expected=Get-LabCapabilityEvidenceTupleKey (@('external-runtime-capability',$Plan.Provider,$Plan.SqlVersion)+(Get-LabCapabilityEvidenceIdentityValues $identity))
    $matching=@($reader.Records|Where-Object {
        $_.Capability -ceq 'external-runtime-capability' -and $_.Identity.Kind -ceq 'EXTERNAL_RUNTIME_CONTAINER/1.0' -and
        (Get-LabCapabilityEvidenceTupleKey (@($_.Capability,$_.Provider,$_.SqlVersion)+(Get-LabCapabilityEvidenceIdentityValues $_.Identity))) -ceq $expected
    })
    if(-not $matching.Count){return New-LabExternalRuntimeHistoricalEvidenceResult 'NOT_RECORDED' 'DEFINED' 'INDEX_NO_MATCH'}
    $cells=New-LabCapabilityEvidenceIdentityCells -Records $matching -IndexVersion $reader.ContractVersion
    New-LabExternalRuntimeHistoricalEvidenceResult 'RECORDED_HISTORY_ONLY' 'DEFINED' 'INDEX_MATCH_RECORDED' -Cells $cells
}

function New-LabRecordedIdentityMatrix {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $read=Read-LabCapabilityEvidenceIndex -RepositoryRoot $RepositoryRoot -IncludeIdentity
    $cells=@();$count=0;$status='UNAVAILABLE'
    $reason=switch -CaseSensitive ($read.Status){
        NOT_PRESENT {'INDEX_NOT_PRESENT'}
        SCHEMA_UNSUPPORTED {'INDEX_SCHEMA_UNSUPPORTED'}
        RECORDED {'INDEX_EMPTY'}
        default {'INDEX_INVALID'}
    }
    if($read.Status -ceq 'RECORDED') {
        $cells=New-LabCapabilityEvidenceIdentityCells $read.Records $read.ContractVersion
        $count=$read.Records.Count
        $status=if($count){'RECORDED_HISTORY_ONLY'}else{'NOT_RECORDED'}
        if($count){$reason='INDEX_RECORDS_RECORDED'}
    }
    $result=[pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.RepositoryCapabilityInventory/1.2';SourceScope='RECORDED_IDENTITY_MATRIX_ONLY'
        EvidenceBoundary='RECORDED_HISTORY_ONLY';Status=$status;ReasonCode=$reason;ReferenceVerificationStatus='NOT_VERIFIED'
        RecordCount=$count;Cells=$cells;MutationAllowed=$false;CurrentExecutionStatus='NOT_EXECUTED';CurrentReadinessStatus='NOT_CHECKED'
    }
    if([Text.Encoding]::UTF8.GetByteCount(($result|ConvertTo-Json -Depth 30 -Compress)) -gt 262144) {
        $result.Status='UNAVAILABLE';$result.ReasonCode='EVIDENCE_OUTPUT_LIMIT';$result.RecordCount=0;$result.Cells=@()
    }
    return $result
}
