#Requires -Version 7.5
# Ausschließlich die tatsächliche Auswahl vor der Registrierung ausführen.
# Die Indexabhängigkeit ist synthetisch; keine CA-, Registry- oder Labänderung.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$text=[IO.File]::ReadAllText((Join-Path $root 'Private/AuthenticatedTlsAuthority.ps1'))
$start=$text.IndexOf('        $record=Get-LabTlsPayloadIndexRecord $fresh',[StringComparison]::Ordinal)
$end=$text.IndexOf('        if($matching.Count -eq 1){',$start,[StringComparison]::Ordinal)
if($start -lt 0 -or $end -le $start){throw 'TLS_SELECTION_TEST_SOURCE_ANCHOR'}
$selection=[scriptblock]::Create($text.Substring($start,$end-$start))
function Get-LabTlsPayloadIndexRecord($Value){@{IdentityDigest=$Value.Identity;RevisionDigest=$(if($Value.ContainsKey('Revision')){$Value.Revision}else{'unchanged'})}}
function Select-Fixture([string]$Kind,[string]$ExpectedRef,[object[]]$Payloads){
 $kind=$Kind;$fresh=@{Identity='ContosoIdentity'};$payloads=$Payloads
 $activeCandidateAuthorities=@()
 if($ExpectedRef){$activeCandidateAuthorities+=@{ClientRef=$ExpectedRef;SignerContextRef=$ExpectedRef}}
 . $selection
 return ,$matching
}
$checks=0
foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
 $a=@{Kind=$kind;Status='ACTIVE';Identity='ContosoIdentity';Ref='ContosoA'}
 $b=@{Kind=$kind;Status='ACTIVE';Identity='ContosoIdentity';Ref='ContosoB'}
 $selected=Select-Fixture $kind 'ContosoA' @($a,$b)
 if($selected.Count -ne 1 -or $selected[0].Ref -cne 'ContosoA'){throw 'TLS_SELECTION_BOUND_REF_NOT_SELECTED'};$checks++
 $selected=Select-Fixture $kind '' @($a)
 if($selected.Count -ne 1 -or $selected[0].Ref -cne 'ContosoA'){throw 'TLS_SELECTION_UNIQUE_NEW_CONTEXT_CHANGED'};$checks++
 foreach($case in @(@{ref='';rows=@($a,$b);error='TLS_AUTHORITY_CONTEXT_AMBIGUOUS'},@{ref='ContosoMissing';rows=@($a,$b);error='TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'},@{ref='ContosoA';rows=@(@{Kind=$kind;Status='ACTIVE';Identity='OtherIdentity';Ref='ContosoA'},$b);error='TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'},@{ref='ContosoA';rows=@($a,$a,$b);error='TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'})){
  $rejected=$false;try{$null=Select-Fixture $kind $case.ref $case.rows}catch{$rejected=$_.Exception.Message -ceq $case.error}
  if(-not $rejected){throw 'TLS_SELECTION_EXPECTED_REJECTION_MISSING'};$checks++
 }
}
function New-LabTlsRevisedContextPayload($Current,$Fresh){$next=$Fresh.Clone();$next.Ref=$Current.Ref;$next.Generation=$Current.Generation+1;return $next}
$loopStart=$text.IndexOf('        $fresh=$prototypes[$kind]',[StringComparison]::Ordinal)
$loopEnd=$text.IndexOf('        $contexts[$kind]=$fresh',$loopStart,[StringComparison]::Ordinal)
if($loopStart -lt 0 -or $loopEnd -le $loopStart){throw 'TLS_SELECTION_MUTATION_SOURCE_ANCHOR'}
$mutation=[scriptblock]::Create($text.Substring($loopStart,$loopEnd-$loopStart+'        $contexts[$kind]=$fresh'.Length))
$payloads=[Collections.Generic.List[object]]::new();$prototypes=@{};$contexts=@{}
$updatedContextRefs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$activeCandidateAuthorities=@(@{ClientRef='ClientA';SignerContextRef='SignerA'})
foreach($pair in @(@('CLIENT_CONTEXT','Client'),@('SIGNER_CONTEXT','Signer'))){
 foreach($suffix in @('A','B')){$payloads.Add(@{Kind=$pair[0];Status='ACTIVE';Identity='ContosoIdentity';Ref=($pair[1]+$suffix);Revision='old';Generation=1})}
 $prototypes[$pair[0]]=@{Kind=$pair[0];Status='ACTIVE';Identity='ContosoIdentity';Ref='NewRef';Revision='new';Generation=1}
}
foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){. $mutation}
if($contexts.CLIENT_CONTEXT.Ref -cne 'ClientA' -or $contexts.SIGNER_CONTEXT.Ref -cne 'SignerA'){throw 'TLS_SELECTION_REVISION_REBOUND'};$checks++
if($updatedContextRefs.Count -ne 2 -or $payloads.Count -ne 4 -or @($payloads|Where-Object {$_.Ref -cin @('ClientA','SignerA') -and $_.Generation -eq 2 -and $_.Revision -ceq 'new'}).Count -ne 2){throw 'TLS_SELECTION_SELECTED_REVISION_MISSING'};$checks++
if(@($payloads|Where-Object {$_.Ref -cin @('ClientB','SignerB') -and $_.Generation -eq 1 -and $_.Revision -ceq 'old'}).Count -ne 2){throw 'TLS_SELECTION_FOREIGN_PAYLOAD_CHANGED'};$checks++
"TLS_CONTEXT_SELECTION_CHECKS_PASS $checks; no CA/registry/VM/SQL effects"
