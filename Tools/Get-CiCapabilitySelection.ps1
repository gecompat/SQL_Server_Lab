#Requires -Version 7.2
<#
.SYNOPSIS
    Selects additional container acceptances independently of provider gates.
.DESCRIPTION
    Every selected provider retains its lifecycle baseline. Unknown product
    effects and shared provider/core dependencies require full qualification
    for that provider; explicit feature paths add their dependency closure.
#>
[CmdletBinding()]
param([string[]]$ChangedPath, [System.Collections.IDictionary]$ProviderSelection)
$all = @('collation','restore','pitr','upgrade','batch','tool','removal','package','transfer-preflight','transfer','ai-vector','ai-samples')
$rules = @(
    @{ Pattern='Collation|sql-server-collation'; Names=@('collation') },
    @{ Pattern='Backup|Restore|SqlStorage'; Names=@('restore','pitr','upgrade','package','transfer-preflight','transfer') },
    @{ Pattern='PointInTime|PITR'; Names=@('restore','pitr') },
    @{ Pattern='SqlVersionUpgrade'; Names=@('restore','upgrade') },
    @{ Pattern='Batch|lab-batch'; Names=@('batch') },
    @{ Pattern='ContainerTool|Bacpac|SampleArtifact'; Names=@('tool','package') },
    @{ Pattern='PersistentStorageRemoval|RetainedStore|RunArtifactRemoval'; Names=@('removal') },
    @{ Pattern='DatabasePackage'; Names=@('package','restore') },
    @{ Pattern='PortableContainerTransfer|portable-container-transfer'; Names=@('transfer-preflight','transfer','restore','package') },
    @{ Pattern='AiVector|AiScenario|AiPersistentRetrieval'; Names=@('ai-vector') },
    @{ Pattern='AiPodmanSamples|AiPodmanSetup'; Names=@('ai-samples') }
)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$full = $false
foreach ($path in $ChangedPath) {
    if ($path -match '(?i)(\.(md|txt|rst)$|^Documentation/)') { continue }
    if ($path -match '(?i)^(Providers/|SqlServerLab\.|Private/(Common|StateMachine|CleanupEngine|ManifestParser|DesiredState|ProviderCapability|ContainerOwnedHostIntegration)|Tests/Common/OwnedHostTestScope|\.github/workflows/)') { $full=$true; continue }
    $matched=$false
    foreach ($rule in $rules) {
        if ($path -match $rule.Pattern) { $matched=$true; foreach ($name in $rule.Names) { [void]$names.Add($name) } }
    }
    # Fail closed for unclassified product and integration changes. A new
    # mapping needs its own dependency proof before it can narrow this fallback.
    if (-not $matched -and $path -match '^(Private|Public|Catalogs|Schemas|Tests/Integration)/') { $full=$true }
}
$result=[ordered]@{}
foreach ($provider in @('Docker','Podman','Mixed','HyperV','Adapter')) {
    $result[$provider]=@()
    if ($ProviderSelection[$provider]) {
        $result[$provider]=@('lifecycle')
        if ($provider -in @('Docker','Podman')) {
            $result[$provider]+= if ($full) { $all } else { @($names | Sort-Object) }
            if ($provider -eq 'Docker') { $result[$provider]=@($result[$provider] | Where-Object { $_ -ne 'ai-samples' }) }
        }
    }
}
[pscustomobject]$result
