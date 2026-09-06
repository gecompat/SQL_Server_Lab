#Requires -Version 7.2
<#
.SYNOPSIS
Erstellt und prüft eine reproduzierbare Legacy-SQL-Abnahmeumgebung auf Hyper-V.

.DESCRIPTION
Verwendet ausschließlich ein veröffentlichtes, kompatibles und ausreichend
lange gültiges OS_SEALED-Artefakt sowie ein hashgebundenes SQL-Medium. Windows
OOBE, internes Labnetz, SQL Setup und der Create/Backup/Restore-Abnahmetest
laufen unbeaufsichtigt. Passwörter werden zufällig erzeugt, DPAPI-geschützt im
buildlokalen Secret Store gehalten und weder ausgegeben noch in den portablen
Build-State geschrieben.

Freigegeben sind SQL Server 2012 Evaluation und SQL Server 2014 Express SP3
auf Windows Server 2012 R2 Standard Evaluation. Das offizielle SQL-2014-
Vollpaket wird bei Bedarf geladen, verifiziert und als offline einbindbares
Daten-ISO verpackt. Erfolgreiche Runs bleiben als TESTS_PASSED-Abnahmeumgebung
erhalten und werden bei einem erneuten Aufruf wiederverwendet.

.PARAMETER SqlVersion
Legacy-SQL-Hauptversion. SQL Server 2012 und 2014 sind freigegeben.

.PARAMETER ArtifactId
Optionales exaktes OS_SEALED-Artefakt. Ohne Angabe wird die kompatible,
ausreichend lange gültige und child-boot-verifizierte Vorlage aufgelöst.

.PARAMETER ResultPath
Optionaler JSON-Nachweis. Er enthält keine Credentials oder Passwörter.

.PARAMETER ShowHelp
Zeigt die vollständige Hilfe und beendet das Skript ohne Prüfung oder Mutation.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('2012','2014')]
    [string]$SqlVersion,
    [string]$ArtifactId,
    [string]$MediaRoot='D:\Lab1_Base',
    [string]$StateRoot,
    [string]$SqlMediaPath,
    [ValidateRange(2048,32768)][int]$MemoryStartupMB=4096,
    [ValidateRange(1,16)][int]$ProcessorCount=4,
    [ValidateRange(300,3600)][int]$OobeTimeoutSeconds=1200,
    [ValidateRange(600,10800)][int]$SetupTimeoutSeconds=7200,
    [ValidateRange(120,1800)][int]$ReadinessTimeoutSeconds=900,
    [string]$ResultPath,
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$RemainingArgs
)

$ErrorActionPreference='Stop'
$showHelpRequested=$ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if($showHelpRequested){Get-Help -Full -Name $PSCommandPath|Out-Host;return}
if(-not $SqlVersion){throw 'LEGACY_SQL_ACCEPTANCE_SQL_VERSION_REQUIRED'}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
if(-not $StateRoot){$StateRoot=& $module { Get-LabStateRoot }}
$mapping=@{
    '2012'=[pscustomobject]@{
        OperatingSystemId='windows-server-2012-r2';OperatingSystemVersion='2012-r2'
        Edition='standard-evaluation';InstallationType='desktop-experience';MediaEdition='Eval'
        SqlFeatures=@('SQLENGINE','FULLTEXT','REPLICATION');PackageSourceId=$null;PackageIsoRelativePath=$null
    }
    '2014'=[pscustomobject]@{
        OperatingSystemId='windows-server-2012-r2';OperatingSystemVersion='2012-r2'
        Edition='standard-evaluation';InstallationType='desktop-experience';MediaEdition='Express'
        SqlFeatures=@('SQLENGINE');PackageSourceId='sql-server-2014-express-sp3-full'
        PackageIsoRelativePath='SQL/2014/Express/ISO/SQLServer2014SP3Express-x64-ENU.iso'
    }
}
$target=$mapping[$SqlVersion]
$existingBuilds=@(& $module {
    param($Target,$ArtifactId,$SqlVersion,$StateRoot)
    @(Get-HyperVSqlImageBuildPlans -StateRoot $StateRoot | Where-Object {
        [string]$_.provisioningMode -eq 'sealed-os-baseline' -and
        [string]$_.sql.version -eq $SqlVersion -and
        [string]$_.parentArtifact.operatingSystem.id -eq [string]$Target.OperatingSystemId -and
        [string]$_.parentArtifact.operatingSystem.version -eq [string]$Target.OperatingSystemVersion -and
        [string]$_.parentArtifact.operatingSystem.edition -eq [string]$Target.Edition -and
        [string]$_.parentArtifact.operatingSystem.installationType -eq [string]$Target.InstallationType -and
        (-not $ArtifactId -or [string]$_.parentArtifact.artifactId -eq $ArtifactId) -and
        [string]$_.state -notin @('CLEANED_UP','SQL_PREPARED_SEALED','FAILED')
    })
} $target $ArtifactId $SqlVersion $StateRoot)
if($existingBuilds.Count -gt 1){throw "LEGACY_SQL_ACCEPTANCE_BUILD_AMBIGUOUS: $($existingBuilds.Count)"}

$resolved=if($existingBuilds.Count -eq 1){
    & $module {
        param($Build,$MediaRoot,$StateRoot)
        # Der aktive Build wurde beim Anlegen bereits gegen das OS_SEALED-
        # Register und dessen SHA-256 geprüft. Beim Resume genügt der gebundene
        # Parent-Beleg; das große Parent-VHDX wird nicht erneut gehasht.
        $artifact=$Build.parentArtifact
        if(-not [string]$artifact.artifactId -or -not [string]$artifact.sha256){
            throw 'LEGACY_SQL_ACCEPTANCE_ARTIFACT_NOT_ELIGIBLE'
        }
        if([string]$artifact.license.type -eq 'evaluation' -and $artifact.license.evaluationExpiresAt -and
            ([datetime]$artifact.license.evaluationExpiresAt).ToUniversalTime() -lt [datetime]::UtcNow.AddDays(30)){
            throw 'LEGACY_SQL_ACCEPTANCE_OS_EVALUATION_EXPIRING'
        }
        $localPath=Join-Path $Build.BuildDirectory 'build-local.json'
        if(-not(Test-Path -LiteralPath $localPath -PathType Leaf)){throw 'LEGACY_SQL_ACCEPTANCE_MEDIA_VERIFICATION_CACHE_MISSING'}
        $local=Get-Content -LiteralPath $localPath -Raw -Encoding utf8|ConvertFrom-Json
        if(-not $local.mediaVerification){throw 'LEGACY_SQL_ACCEPTANCE_MEDIA_VERIFICATION_CACHE_MISSING'}
        $iso=Get-Item -LiteralPath ([string]$local.sqlIsoPath) -ErrorAction Stop
        $root=(Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
        $relative=[IO.Path]::GetRelativePath($root,$iso.FullName).Replace('\','/')
        if($relative.StartsWith('..') -or $relative -notmatch '^SQL/'){
            throw 'LEGACY_SQL_ACCEPTANCE_MEDIA_OUTSIDE_ROOT'
        }
        $expected=[string]$Build.sql.mediaSha256
        if([string]$local.mediaVerification.sha256 -ne $expected -or
            [long]$local.mediaVerification.lengthBytes -ne [long]$iso.Length -or
            [datetime]$local.mediaVerification.lastWriteTimeUtc -ne $iso.LastWriteTimeUtc){
            throw 'LEGACY_SQL_ACCEPTANCE_MEDIA_CHANGED_REVERIFY_REQUIRED'
        }
        $sidecar=Join-Path (Join-Path $root 'Hashes') ($relative.Replace('/','\')+'.sha256')
        $content=(Get-Content -LiteralPath $sidecar -Raw -Encoding utf8).Trim()
        if($content -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$' -or
            $Matches.sha -ne $expected -or $Matches.relative.Replace('\','/') -ne $relative){
            throw 'LEGACY_SQL_ACCEPTANCE_MEDIA_HASH_BINDING_CHANGED'
        }
        [pscustomobject]@{
            Artifact=$artifact
            Media=[pscustomobject]@{RelativePath=$relative;ExpectedSha256=$expected;IsoPath=$iso.FullName;HashStatus='VERIFIED_CACHE'}
            Detected=[pscustomobject]@{SqlVersion=[string]$Build.sql.version;SetupVersion=[string]$Build.sql.setupBuild}
            ExistingBuildId=[string]$Build.buildId
        }
    } $existingBuilds[0] $MediaRoot $StateRoot
}else{& $module {
    param($Target,$ArtifactId,$MediaRoot,$SqlVersion,$SqlMediaPath,$StateRoot)
    if($ArtifactId){
        $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
        if(-not $artifact){throw 'LEGACY_SQL_ACCEPTANCE_ARTIFACT_NOT_FOUND'}
        $reasons=@(Get-HyperVManifestFallbackArtifactRejectionReasons -Artifact $artifact `
            -SqlVersion '' -MinimumEvaluationDaysRemaining 30 | Where-Object {
                $_ -notin @('artifact-not-sql-prepared-sealed','artifact-sql-not-prepared','sql-version-missing','sql-version-mismatch')
            })
        if($artifact.artifactState -ne 'OS_SEALED' -or $reasons.Count){
            throw "LEGACY_SQL_ACCEPTANCE_ARTIFACT_NOT_ELIGIBLE: $($reasons -join ',')"
        }
    }else{
        $selection=Resolve-HyperVImageArtifact -OperatingSystemId $Target.OperatingSystemId `
            -OperatingSystemVersion $Target.OperatingSystemVersion -Edition $Target.Edition `
            -InstallationType $Target.InstallationType -MinimumEvaluationDaysRemaining 30 -StateRoot $StateRoot
        if(-not $selection.Selected){throw 'LEGACY_SQL_ACCEPTANCE_OS_BASELINE_NOT_AVAILABLE'}
        $artifact=$selection.Selected
    }
    if([string]$artifact.operatingSystem.id -ne [string]$Target.OperatingSystemId -or
        [string]$artifact.operatingSystem.version -ne [string]$Target.OperatingSystemVersion -or
        [string]$artifact.operatingSystem.edition -ne [string]$Target.Edition -or
        [string]$artifact.operatingSystem.installationType -ne [string]$Target.InstallationType){
        throw 'LEGACY_SQL_ACCEPTANCE_OS_BASELINE_MISMATCH'
    }
    $packageSource=$null;$media=$null;$detected=$null
    $mediaArgs=@{MediaRoot=$MediaRoot;SqlVersion=$SqlVersion;MediaEdition=$Target.MediaEdition}
    if($SqlMediaPath){$mediaArgs.SqlMediaPath=$SqlMediaPath}
    $packageTarget=if($Target.PackageIsoRelativePath){Join-Path $MediaRoot ($Target.PackageIsoRelativePath.Replace('/','\'))}else{$null}
    if(-not $SqlMediaPath -and $Target.PackageSourceId -and -not(Test-Path -LiteralPath $packageTarget -PathType Leaf)){
        $entries=@(Get-LabMediaSourceCatalog -MediaRoot $MediaRoot|Where-Object Id -eq $Target.PackageSourceId)
        if($entries.Count -ne 1){throw "LEGACY_SQL_ACCEPTANCE_PACKAGE_SOURCE_NOT_FOUND: $($Target.PackageSourceId)"}
        $entry=$entries[0]
        if(-not $entry.Automatable -or -not $entry.ExpectedSha256 -or -not $entry.ExpectedBytes -or
            [string]$entry.SourceStatus -ne 'ACTIVE' -or [string]$entry.MediaKind -ne 'SELF_EXTRACTING_EXE' -or
            [string]$entry.Version -ne $SqlVersion -or [string]$entry.Edition -ne [string]$Target.MediaEdition -or
            [string]$entry.DerivedTargetRelativePath -ne [string]$Target.PackageIsoRelativePath -or
            [string]$entry.Conversion -ne 'IMAPI2FS_DATA_ISO'){
            throw 'LEGACY_SQL_ACCEPTANCE_PACKAGE_SOURCE_NOT_ELIGIBLE'
        }
        $packageSource=[pscustomobject]@{
            Id=[string]$entry.Id;RelativePath=[string]$entry.TargetRelativePath
            ExpectedSha256=[string]$entry.ExpectedSha256;ExpectedBytes=[long]$entry.ExpectedBytes
            TargetRelativePath=[string]$Target.PackageIsoRelativePath
        }
    }else{
        if(-not $SqlMediaPath -and $Target.PackageIsoRelativePath){$mediaArgs.SqlMediaPath=[string]$Target.PackageIsoRelativePath}
        $media=Resolve-HyperVSqlInstallationMedia @mediaArgs
        if([string]$media.HashStatus -ne 'SIDECAR_READY'){throw "LEGACY_SQL_ACCEPTANCE_MEDIA_HASH_REQUIRED: $($media.HashPath)"}
        $detected=Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion $SqlVersion
    }
    [pscustomobject]@{Artifact=$artifact;Media=$media;Detected=@($detected)[0];PackageSource=$packageSource;ExistingBuildId=$null}
} $target $ArtifactId $MediaRoot $SqlVersion $SqlMediaPath $StateRoot}

if($SqlVersion -in @('2012','2014')){
    $validationPath=Join-Path $MediaRoot 'Evidence\windows-server-evaluation-media-validation.json'
    if(-not(Test-Path -LiteralPath $validationPath -PathType Leaf)){throw 'LEGACY_SQL_ACCEPTANCE_WINDOWS_FEATURE_SOURCE_EVIDENCE_MISSING'}
    $validation=Get-Content -LiteralPath $validationPath -Raw -Encoding utf8|ConvertFrom-Json
    $windowsVersion=if($target.OperatingSystemVersion -eq '2012-r2'){'2012R2'}else{$target.OperatingSystemVersion}
    $sourceEvidence=@($validation.Results|Where-Object { $_.Status -eq 'VERIFIED' -and $_.WindowsVersion -eq $windowsVersion })
    if($sourceEvidence.Count -ne 1){throw "LEGACY_SQL_ACCEPTANCE_WINDOWS_FEATURE_SOURCE_NOT_UNIQUE: $($sourceEvidence.Count)"}
    $sourceIso=Get-Item -LiteralPath ([string]$sourceEvidence[0].IsoPath) -ErrorAction Stop
    if([long]$sourceEvidence[0].Bytes -ne [long]$sourceIso.Length -or
        $sourceIso.LastWriteTimeUtc -gt ([datetime]$sourceEvidence[0].CheckedAt).ToUniversalTime()){
        throw 'LEGACY_SQL_ACCEPTANCE_WINDOWS_FEATURE_SOURCE_CHANGED_REVERIFY_REQUIRED'
    }
    $sourceSidecar=Join-Path (Join-Path $MediaRoot 'Hashes') ([IO.Path]::GetRelativePath($MediaRoot,$sourceIso.FullName)+'.sha256')
    $sourceHashText=(Get-Content -LiteralPath $sourceSidecar -Raw -Encoding utf8).Trim()
    if($sourceHashText -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<file>.+)$' -or
        $Matches.sha -ne [string]$sourceEvidence[0].Sha256 -or $Matches.file -ne $sourceIso.Name){
        throw 'LEGACY_SQL_ACCEPTANCE_WINDOWS_FEATURE_SOURCE_HASH_BINDING_CHANGED'
    }
    $resolved|Add-Member -NotePropertyName WindowsFeatureSource -NotePropertyValue ([pscustomobject]@{
        IsoPath=$sourceIso.FullName;Sha256=[string]$sourceEvidence[0].Sha256;LengthBytes=[long]$sourceIso.Length
        LastWriteTimeUtc=$sourceIso.LastWriteTimeUtc.ToString('o');VerifiedAt=[string]$sourceEvidence[0].CheckedAt
    }) -Force
}

$plan=[pscustomobject]@{
    Status='PLANNED';SqlVersion=$SqlVersion;OperatingSystemId=[string]$resolved.Artifact.operatingSystem.id
    ArtifactId=[string]$resolved.Artifact.artifactId
    MediaRelativePath=if($resolved.Media){[string]$resolved.Media.RelativePath}else{[string]$resolved.PackageSource.TargetRelativePath}
    MediaSha256=if($resolved.Media){[string]$resolved.Media.ExpectedSha256}else{$null}
    PackageSourceId=if($resolved.PackageSource){[string]$resolved.PackageSource.Id}else{$null}
    PackageSourceSha256=if($resolved.PackageSource){[string]$resolved.PackageSource.ExpectedSha256}else{$null}
    GuestControl=[string]$resolved.Artifact.platform.guestControl
    ExistingBuildId=[string]$resolved.ExistingBuildId
    WindowsFeatureSourceSha256=if($resolved.WindowsFeatureSource){[string]$resolved.WindowsFeatureSource.Sha256}else{$null}
    CredentialDisclosed=$false;PasswordDisclosed=$false
}
if(-not $PSCmdlet.ShouldProcess("SQL Server $SqlVersion / $($resolved.Artifact.operatingSystem.id)",'Abnahmeumgebung erstellen und vollständigen SQL-Test ausführen')){
    return $plan
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'LEGACY_SQL_ACCEPTANCE_REQUIRES_ELEVATED_RUNNER'
}

try{
if($resolved.PackageSource){
    $packageMedia=& $module {
        param($Package,$MediaRoot,$SqlVersion,$MediaEdition)
        $saved=Save-SqlServerLabMediaSource -Id ([string]$Package.Id) -MediaRoot $MediaRoot -Confirm:$false
        if([string]$saved.Status -ne 'READY' -or [string]$saved.Sha256 -ne [string]$Package.ExpectedSha256 -or
            [long]$saved.Bytes -ne [long]$Package.ExpectedBytes){throw 'LEGACY_SQL_ACCEPTANCE_PACKAGE_DOWNLOAD_INVALID'}
        New-HyperVSqlPackageMediaIso -MediaRoot $MediaRoot -SourceRelativePath ([string]$Package.RelativePath) `
            -ExpectedSourceSha256 ([string]$Package.ExpectedSha256) -TargetRelativePath ([string]$Package.TargetRelativePath) `
            -SqlVersion $SqlVersion -MediaEdition $MediaEdition
    } $resolved.PackageSource $MediaRoot $SqlVersion $target.MediaEdition
    $detected=& $module {param($IsoPath,$SqlVersion) Confirm-HyperVSqlInstallationMediaVersion -IsoPath $IsoPath -SqlVersion $SqlVersion} $packageMedia.IsoPath $SqlVersion
    $resolved.Media=$packageMedia
    $resolved.Detected=@($detected)[0]
    $resolved.PackageSource=$null
}

    $result=& $module {
        param($Resolved,$Target,$SqlVersion,$MediaRoot,$StateRoot,$MemoryStartupMB,$ProcessorCount,$OobeTimeoutSeconds,$SetupTimeoutSeconds,$ReadinessTimeoutSeconds)
        $active=if($Resolved.ExistingBuildId){
            @(Get-HyperVSqlImageBuildPlan -BuildId ([string]$Resolved.ExistingBuildId) -StateRoot $StateRoot)
        }else{@(Get-HyperVSqlImageBuildPlans -StateRoot $StateRoot | Where-Object {
            [string]$_.provisioningMode -eq 'sealed-os-baseline' -and
            [string]$_.parentArtifact.artifactId -eq [string]$Resolved.Artifact.artifactId -and
            [string]$_.sql.version -eq $SqlVersion -and
            [string]$_.state -notin @('CLEANED_UP','SQL_PREPARED_SEALED')
        })}
        if($active.Count -gt 1){throw "LEGACY_SQL_ACCEPTANCE_BUILD_AMBIGUOUS: $($active.Count)"}
        if($active.Count -eq 1){$build=$active[0]}
        else{
            $init=@{
                MediaRoot=$MediaRoot;ImageArtifactId=[string]$Resolved.Artifact.artifactId
                SqlVersion=$SqlVersion;MediaEdition=[string]$Target.MediaEdition;SqlMediaPath=[string]$Resolved.Media.RelativePath
                SqlFeatures=@($Target.SqlFeatures)
                ImageName="SQL Server $SqlVersion Acceptance"
                MemoryStartupBytes=([long]$MemoryStartupMB*1MB);ProcessorCount=$ProcessorCount;StateRoot=$StateRoot
            }
            $build=Initialize-HyperVSqlPreparedImageBuild @init
        }
        if([string]$build.state -in @('MANUAL_ACTION_REQUIRED','OOBE_AUTOMATION_RUNNING')){
            $build=Invoke-HyperVSqlUnattendedOobe -BuildId $build.buildId `
                -TimeoutSeconds $OobeTimeoutSeconds -StateRoot $StateRoot
        }
        $credential=Get-HyperVSqlGuestCredential -Build $build
        $saPassword=Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
        if(-not $saPassword){$saPassword=New-HyperVSqlUnattendedPassword}
        if([string]$build.state -in @('OOBE_COMPLETED','SQL_INSTALL_RUNNING','SQL_INSTALL_REBOOT_REQUIRED')){
            if($Resolved.WindowsFeatureSource){
                $managed=Get-HyperVManagedVM -VMName ([string]$build.builder.vmName) `
                    -ExpectedRunId ([string]$build.buildId) -ExpectedScopeId ([string]$build.scopeId)
                if(-not $managed){throw 'LEGACY_SQL_ACCEPTANCE_VM_NOT_FOUND'}
                $attached=@(Get-VMDvdDrive -VM $managed.VM -ErrorAction Stop|Where-Object {
                    [string]$_.Path -eq [string]$Resolved.WindowsFeatureSource.IsoPath
                })
                if($attached.Count -eq 0){
                    $null=Add-VMDvdDrive -VM $managed.VM -Path ([string]$Resolved.WindowsFeatureSource.IsoPath) -ErrorAction Stop
                }elseif($attached.Count -gt 1){throw 'LEGACY_SQL_ACCEPTANCE_WINDOWS_FEATURE_SOURCE_AMBIGUOUS'}
            }
            $build=Invoke-HyperVSqlTestEnvironmentInstall -BuildId $build.buildId -Credential $credential `
                -SaPassword $saPassword -SetupTimeoutSeconds $SetupTimeoutSeconds `
                -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds -StateRoot $StateRoot
        }
        if([string]$build.state -eq 'SQL_READY_RUN'){
            $build=Test-HyperVSqlAcceptanceEnvironment -BuildId $build.buildId -Credential $credential `
                -SaPassword $saPassword -TimeoutSeconds $ReadinessTimeoutSeconds -StateRoot $StateRoot
        }
        if([string]$build.state -ne 'TESTS_PASSED'){
            throw "LEGACY_SQL_ACCEPTANCE_NOT_COMPLETE: $($build.state)"
        }
        [pscustomobject]@{
            Status='TESTS_PASSED';BuildId=[string]$build.buildId;VMName=[string]$build.builder.vmName
            SqlVersion=[string]$build.sql.version;SqlMajorVersion=[int]$build.acceptanceEvidence.majorVersion
            ProductVersion=[string]$build.testEnvironment.productVersion;Edition=[string]$build.testEnvironment.edition
            OperatingSystemId=[string]$build.parentArtifact.operatingSystem.id
            ArtifactId=[string]$build.parentArtifact.artifactId;MediaSha256=[string]$build.sql.mediaSha256
            GuestControl=[string]$build.parentArtifact.platform.guestControl
            Tests=[pscustomobject]@{
                databaseCreate=[bool]$build.acceptanceEvidence.databaseCreate
                insertSelect=[bool]$build.acceptanceEvidence.insertSelect
                backupChecksum=[bool]$build.acceptanceEvidence.backupChecksum
                restoreVerifyOnly=[bool]$build.acceptanceEvidence.restoreVerifyOnly
                databaseDrop=[bool]$build.acceptanceEvidence.databaseDrop
                backupRemoved=[bool]$build.acceptanceEvidence.backupRemoved
            }
            CredentialDisclosed=$false;PasswordDisclosed=$false;CompletedAt=[datetime]::UtcNow.ToString('o')
        }
    } $resolved $target $SqlVersion $MediaRoot $StateRoot $MemoryStartupMB $ProcessorCount $OobeTimeoutSeconds $SetupTimeoutSeconds $ReadinessTimeoutSeconds
}
catch{
    if($ResultPath){
        $failure=[pscustomobject]@{Status='FAILED';SqlVersion=$SqlVersion;ErrorCode=if($_.Exception.Message -match '[A-Z][A-Z0-9_]{5,}'){$Matches[0]}else{'LEGACY_SQL_ACCEPTANCE_FAILED'};CredentialDisclosed=$false;PasswordDisclosed=$false;FailedAt=[datetime]::UtcNow.ToString('o')}
        New-Item -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))) -ItemType Directory -Force|Out-Null
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($failure|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    throw
}
if($ResultPath){
    New-Item -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))) -ItemType Directory -Force|Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
$result
