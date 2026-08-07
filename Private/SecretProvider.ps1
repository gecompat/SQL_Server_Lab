<#
.SYNOPSIS
    Secret-Management fuer SQL_Server_Lab.
.DESCRIPTION
    SA-Passwort interaktiv abfragen, validieren, speichern und lesen.
    Windows: DPAPI CurrentUser, bei nicht geladenem Runner-Profil DPAPI
    LocalMachine unter dem bestehenden Dateisystem-ACL. Linux: Base64 +
    chmod 600.
#>

function Test-SaPasswordComplexity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Password)
    $reasons = @()
    if ($Password.Length -lt 8) { $reasons += 'Mindestens 8 Zeichen' }
    if ($Password -notmatch '[A-Z]') { $reasons += 'Mindestens ein Grossbuchstabe' }
    if ($Password -notmatch '[a-z]') { $reasons += 'Mindestens ein Kleinbuchstabe' }
    if ($Password -notmatch '[0-9]') { $reasons += 'Mindestens eine Ziffer' }
    if ($Password -notmatch '[^A-Za-z0-9]') { $reasons += 'Mindestens ein Sonderzeichen' }
    [PSCustomObject]@{ Valid = $reasons.Count -eq 0; Reasons = $reasons }
}

function Read-SaPassword {
    [CmdletBinding()]
    param([int]$MaxAttempts = 3)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $secure = Read-Host 'SA-Passwort' -AsSecureString
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        $check = Test-SaPasswordComplexity -Password $plain
        if (-not $check.Valid) {
            Write-LabWarning "Passwort erfuellt nicht die Anforderungen:"
            $check.Reasons | ForEach-Object { Write-LabWarning "  - $_" }
            if ($i -lt $MaxAttempts) { Write-LabInfo "Erneut eingeben ($($i+1)/$MaxAttempts)." }
            continue
        }
        $confirm = Read-Host 'SA-Passwort bestaetigen' -AsSecureString
        $confirmPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm))
        if ($plain -ne $confirmPlain) {
            Write-LabWarning "Passwoerter stimmen nicht ueberein."
            if ($i -lt $MaxAttempts) { Write-LabInfo "Erneut eingeben ($($i+1)/$MaxAttempts)." }
            continue
        }
        $plain = $null; $confirmPlain = $null
        return $secure
    }
    throw "SA-Passwort konnte nach $MaxAttempts Versuchen nicht gesetzt werden."
}

function Get-LabManifestEnvironmentSecret {
    <#
    .SYNOPSIS
        Liest ein Manifest-Secret ausschließlich aus dem aufrufenden Prozess.
    .DESCRIPTION
        Manifestdateien dürfen niemals Kennwörter enthalten. Für CI/CD und
        automatisierte Setups darf ein Manifest deshalb nur eine eng benannte
        Prozess-Umgebungsvariable referenzieren. Der Name wird vor dem Zugriff
        validiert; der Wert wird nicht protokolliert oder in State-Dateien
        übernommen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^SQL_SERVER_LAB_SECRET_[A-Z0-9_]+$')]
        [string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "LAB_MANIFEST_SECRET_ENVIRONMENT_MISSING: Die Prozess-Umgebungsvariable '$Name' ist nicht gesetzt."
    }

    try {
        return ConvertTo-SecureString -String $value -AsPlainText -Force
    }
    finally {
        $value = $null
    }
}

function Save-LabSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][SecureString]$Secret
    )
    $secretDir = Join-Path $Path 'secrets'
    if (-not (Test-Path $secretDir)) { New-Item -Path $secretDir -ItemType Directory -Force | Out-Null }
    $secretFile = Join-Path $secretDir "$Name.secret"
    if ($IsWindows) {
        try {
            $encrypted = 'dpapi-currentuser-v1:' + (ConvertFrom-SecureString $Secret -ErrorAction Stop)
        }
        catch {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
            $plain = $null; $plainBytes = $null; $protectedBytes = $null
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $plainBytes = [Text.Encoding]::UTF8.GetBytes($plain)
                $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
                    $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
                $encrypted = 'dpapi-localmachine-v1:' + [Convert]::ToBase64String($protectedBytes)
            }
            finally {
                $plain = $null
                if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
                if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        Set-Content -Path $secretFile -Value $encrypted -Encoding utf8
    } else {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain))
        $plain = $null
        Set-Content -Path $secretFile -Value $encoded -Encoding utf8
        chmod 600 $secretFile 2>$null
    }
}

function Get-LabSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $secretFile = Join-Path $Path 'secrets' "$Name.secret"
    if (-not (Test-Path $secretFile)) { return $null }
    $content = (Get-Content $secretFile -Raw).Trim()
    if ($IsWindows) {
        if ($content.StartsWith('dpapi-currentuser-v1:', [System.StringComparison]::Ordinal)) {
            return ConvertTo-SecureString $content.Substring('dpapi-currentuser-v1:'.Length)
        }
        if ($content.StartsWith('dpapi-localmachine-v1:', [System.StringComparison]::Ordinal)) {
            $protectedBytes = [Convert]::FromBase64String($content.Substring('dpapi-localmachine-v1:'.Length))
            $plainBytes = $null; $plain = $null
            try {
                $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
                    $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
                $plain = [Text.Encoding]::UTF8.GetString($plainBytes)
                return ConvertTo-SecureString $plain -AsPlainText -Force
            }
            finally {
                $plain = $null
                if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
                if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
            }
        }
        # Rueckwaertskompatibilitaet fuer Dateien vor contractVersion v1.
        return ConvertTo-SecureString $content
    }
    else {
        $plain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content.Trim()))
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        $plain = $null
        return $secure
    }
}

function Remove-LabSecrets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $secretDir = Join-Path $Path 'secrets'
    if (Test-Path $secretDir) {
        Get-ChildItem $secretDir -File | ForEach-Object {
            [byte[]]$zeros = @(0) * 1024
            [IO.File]::WriteAllBytes($_.FullName, $zeros)
            Remove-Item $_.FullName -Force
        }
        Remove-Item $secretDir -Force -ErrorAction SilentlyContinue
    }
}
