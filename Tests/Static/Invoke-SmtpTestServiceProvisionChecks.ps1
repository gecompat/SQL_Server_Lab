#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$scopeId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
function New-SyntheticSecureString {
    $secret=[Security.SecureString]::new()
    foreach($character in 'synthetic-only'.ToCharArray()){$secret.AppendChar($character)}
    $secret.MakeReadOnly()
    return $secret
}
try {
    $plan=& $module {param($r,$s) New-LabSmtpTestServicePlan -Config @{id='smtp';senderInstanceIds=@('primary');imageProvisioning='require-existing'} -RunId $r -ScopeId $s -Provider docker} $runId $scopeId
    $calls=[Collections.Generic.List[string]]::new()
    & $module {
        param($calls)
        Set-Item -Path function:Get-LabOwnedHostRunPolicy -Value { $true }
        Set-Item -Path function:Invoke-LabContainerRuntimeCommand -Value {
            param($Provider,$StateRoot,$RunId,$ArgumentList)
            $calls.Add(($ArgumentList -join ' '))
            [pscustomobject]@{ExitCode=1;Output=@()}
        }.GetNewClosure()
    } $calls
    $missing=$false
    try {
        & $module {param($p,$r,$root,$password) Invoke-LabSmtpTestServiceProvision -Plan $p -RunState ([pscustomobject]@{RunId=$p.RunId}) -LabInstances @([pscustomobject]@{Id='primary';Provider='docker';ContainerId='synthetic'}) -SaPassword $password -StateRoot $r -RepositoryRoot $root} $plan $repoRoot $repoRoot (New-SyntheticSecureString) | Out-Null
    } catch { $missing=$_.Exception.Message -ceq 'SMTP_TEST_REQUIRED_IMAGE_MISSING' }
    $expectedImageId='sha256:'+('a'*64)
    & $module {
        param($id)
        Set-Item -Path function:Invoke-LabContainerRuntimeCommand -Value {
            param($Provider,$StateRoot,$RunId,$ArgumentList)
            [pscustomobject]@{ExitCode=0;Output=@($id)}
        }.GetNewClosure()
    } $expectedImageId
    $resolvedImage=& $module {param($p,$r,$id) Resolve-LabSmtpRuntimeImageId -Provider docker -StateRoot $r -RunId $p.RunId -Image 'example.invalid/synthetic@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'} $plan $repoRoot $expectedImageId
    $buildPlan=& $module {param($r,$s) New-LabSmtpTestServicePlan -Config @{id='smtp';senderInstanceIds=@('primary');imageProvisioning='build'} -RunId $r -ScopeId $s -Provider docker} $runId $scopeId
    $ownedBlocked=$false
    try {
        & $module {param($p,$r,$root,$password) Invoke-LabSmtpTestServiceProvision -Plan $p -RunState ([pscustomobject]@{RunId=$p.RunId}) -LabInstances @([pscustomobject]@{Id='primary';Provider='docker';ContainerId='synthetic'}) -SaPassword $password -StateRoot $r -RepositoryRoot $root} $buildPlan $repoRoot $repoRoot (New-SyntheticSecureString) | Out-Null
    } catch { $ownedBlocked=$_.Exception.Message -ceq 'SMTP_TEST_OWNED_HOST_REQUIRES_EXISTING_IMAGES' }
    $checks=@(
        $missing
        ($calls.Count -eq 1 -and $calls[0] -match '^image inspect --format \{\{\.Id\}\} ghcr\.io/axllent/mailpit:')
        ($resolvedImage -ceq $expectedImageId)
        $ownedBlocked
    )
    if(@($checks|Where-Object {$_}).Count -ne $checks.Count){throw 'SMTP_TEST_SERVICE_PROVISION_CHECK_FAILED'}
    Write-Host 'SMTP service provision: PASS (4/4)'
} finally { Remove-Module $module -Force }
