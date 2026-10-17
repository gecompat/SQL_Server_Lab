#Requires -Version 7.2
# Private frische Metadatenbindung. Kein Keyopen, Storewrite oder TLS-Nachweis.

function Get-LabAuthenticatedTlsAuthorityPreview {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,
        [object]$AuthorityPayloadBytes,[object]$SignerPayloadBytes,[object]$ClientPayloadBytes)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_AUTHORITY_BINDING_INVALID'}
    try{
        if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context)){return $bad}
        $authority=Read-LabAuthenticatedTlsRegistryPayload $AuthorityPayloadBytes
        $signer=Read-LabAuthenticatedTlsRegistryPayload $SignerPayloadBytes
        $client=Read-LabAuthenticatedTlsRegistryPayload $ClientPayloadBytes
        if(-not $authority.Success -or -not $signer.Success -or -not $client.Success){return $bad}
        $a=$authority.Value.Payload;$s=$signer.Value.Payload;$c=$client.Value.Payload
        if($a.Kind -cne 'AUTHORITY' -or $a.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2' -or
            $s.Kind -cne 'SIGNER_CONTEXT' -or $c.Kind -cne 'CLIENT_CONTEXT' -or
            $s.Ref -cne $a.SignerContextRef -or $s.Generation -ne $a.SignerGeneration -or
            $c.Ref -cne $a.ClientRef -or $c.Generation -ne $a.ClientGeneration){return $bad}
        foreach($p in @($a,$s,$c)){
            if($p.Status -cne 'ACTIVE' -or $p.ControllerId -cne $ControllerId -or $p.LocationId -cne $LocationId){return $bad}
        }
        $binding=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $a.CandidateId
        # Candidate-/Registry-Actordigests haben verschiedene Domaenen.
        # Identitaetsfelder vergleichen, niemals diese Hashes gleichsetzen.
        foreach($p in @($s,$c)){
            foreach($name in @('UserSid','HostMarker','ProfilePath')){
                if(-not [string]::Equals($p.Actor.$name,$binding.Native.$name,[StringComparison]::Ordinal)){return $bad}
            }
        }
        $cert=$binding.Certificate;$now=[datetime]::UtcNow
        $first=[datetime]::ParseExact($a.NotBeforeUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $last=[datetime]::ParseExact($a.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if($now -lt $first -or $now -ge $last -or $binding.Digest -cne $a.CandidateBindingDigest -or
            $cert.Sha256 -cne $a.CertificateSha256 -or $cert.NotBeforeUtc -cne $a.NotBeforeUtc -or $cert.NotAfterUtc -cne $a.NotAfterUtc -or
            (Get-LabTlsCaByteDigest $binding.Encrypted) -cne $a.EncryptedKeySha256){return $bad}
        # Auch unveraendert referenzierte Kontextgenerationen frisch beobachten.
        # Ausschliesslich eigene validierte Snapshots; Callerarrays sind mutierbar.
        $signerBytes=[Text.Encoding]::UTF8.GetBytes(($s|ConvertTo-Json -Depth 8 -Compress))
        $clientBytes=[Text.Encoding]::UTF8.GetBytes(($c|ConvertTo-Json -Depth 8 -Compress))
        if(-not (Get-LabAuthenticatedTlsPayloadPreview $signerBytes).Success -or
            -not (Get-LabAuthenticatedTlsPayloadPreview $clientBytes).Success){return $bad}
        if((Get-LabTlsCaExistingTrust $binding.Der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED'){return $bad}
        $again=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $a.CandidateId
        if($again.Digest -cne $binding.Digest -or
            (Get-LabTlsCaExistingTrust $again.Der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED' -or [datetime]::UtcNow -ge $last){return $bad}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            Status='METADATA_BOUND_NOT_TLS_QUALIFIED';Payload=$a;IndexRecord=$authority.Value.IndexRecord
            RootMetadataDigest=$binding.RootMetadataDigest;CandidateBindingDigest=$binding.Digest
            KeyStatus='CIPHERTEXT_BOUND_NOT_OPENED';SnapshotStatus='NON_ATOMIC_READ'
            QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false
        };ErrorCode=$null}
    }catch{return $bad}
}
