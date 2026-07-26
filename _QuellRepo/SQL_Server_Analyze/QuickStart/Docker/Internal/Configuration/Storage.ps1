function New-MarkerContent {
    param(
        [Parameter(Mandatory)][string] $ScopeId,
        [Parameter(Mandatory)][string] $Role
    )
    return [ordered]@{
        SchemaVersion = 1
        Owner = $script:MarkerOwner
        ScopeId = $ScopeId
        Role = $Role
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-RootMarker {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ScopeId,
        [Parameter(Mandatory)][string] $Role
    )

    $markerPath = Join-Path $Root $script:MarkerFileName
    $json = New-MarkerContent -ScopeId $ScopeId -Role $Role | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($markerPath, $json, [Text.UTF8Encoding]::new($false))
}

function Read-RootMarker {
    param([Parameter(Mandatory)][string] $Root)

    $markerPath = Join-Path $Root $script:MarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Der verwaltete Marker fehlt unter '$Root'. Es werden keine Dateien verändert."
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($marker.Owner -ne $script:MarkerOwner) {
        throw "Der Marker unter '$Root' gehört nicht zu diesem QuickStart."
    }
    return $marker
}

function Assert-ManagedRoots {
    param([Parameter(Mandatory)][hashtable] $Env)

    Assert-EnvContract -Env $Env

    $scopeId = [string] $Env.QUICKSTART_SCOPE_ID
    $layout = [string] $Env.STORAGE_LAYOUT
    $labRoot = Get-CanonicalPath -Path ([string] $Env.LAB_ROOT)
    $marker = Read-RootMarker -Root $labRoot
    if ($marker.ScopeId -ne $scopeId) {
        throw "Der Marker unter '$labRoot' stimmt nicht mit dem Scope der .env-Datei überein."
    }

    if ($layout -eq 'SINGLE_ROOT') {
        if ($marker.Role -ne 'SINGLE_ROOT') {
            throw "Der Marker unter '$labRoot' hat nicht die erwartete SINGLE_ROOT-Rolle."
        }
        $expectedDataRoot = Get-CanonicalPath -Path (Join-Path $labRoot 'data')
        $expectedLogRoot = Get-CanonicalPath -Path (Join-Path $labRoot 'log')
        if (
            -not (Get-CanonicalPath -Path ([string] $Env.DATA_ROOT)).Equals($expectedDataRoot, $script:PathComparison) -or
            -not (Get-CanonicalPath -Path ([string] $Env.LOG_ROOT)).Equals($expectedLogRoot, $script:PathComparison)
        ) {
            throw 'Die SINGLE_ROOT-Pfade in der .env-Datei liegen nicht im erwarteten markierten Lab-Scope.'
        }
        return
    }

    if ($marker.Role -ne 'CONTROL_ROOT') {
        throw "Der Marker unter '$labRoot' hat nicht die erwartete CONTROL_ROOT-Rolle."
    }
    $expectedRoles = @{ DATA_ROOT = 'DATA_ROOT'; LOG_ROOT = 'LOG_ROOT' }
    foreach ($rootKey in @('DATA_ROOT', 'LOG_ROOT')) {
        $root = Get-CanonicalPath -Path ([string] $Env[$rootKey])
        $rootMarker = Read-RootMarker -Root $root
        if ($rootMarker.ScopeId -ne $scopeId) {
            throw "Der Marker unter '$root' stimmt nicht mit dem Scope der .env-Datei überein."
        }
        if ($rootMarker.Role -ne $expectedRoles[$rootKey]) {
            throw "Der Marker unter '$root' hat nicht die erwartete Rolle '$($expectedRoles[$rootKey])'."
        }
    }
}

function Initialize-ManagedRoots {
    param(
        [Parameter(Mandatory)][string] $ScopeId,
        [Parameter(Mandatory)][string] $StorageLayout,
        [Parameter(Mandatory)][string] $LabRoot,
        [Parameter(Mandatory)][string] $DataRoot,
        [Parameter(Mandatory)][string] $LogRoot
    )

    $roots = if ($StorageLayout -eq 'SINGLE_ROOT') {
        @($LabRoot)
    }
    else {
        @($LabRoot, $DataRoot, $LogRoot) | Select-Object -Unique
    }
    foreach ($root in $roots) {
        [IO.Directory]::CreateDirectory($root) | Out-Null
    }

    if ($StorageLayout -eq 'SINGLE_ROOT') {
        Write-RootMarker -Root $LabRoot -ScopeId $ScopeId -Role 'SINGLE_ROOT'
    }
    else {
        Write-RootMarker -Root $LabRoot -ScopeId $ScopeId -Role 'CONTROL_ROOT'
        Write-RootMarker -Root $DataRoot -ScopeId $ScopeId -Role 'DATA_ROOT'
        Write-RootMarker -Root $LogRoot -ScopeId $ScopeId -Role 'LOG_ROOT'
    }

    foreach ($path in @(
            (Join-Path $LabRoot 'control/installer'),
            (Join-Path $LabRoot 'backup/2019'),
            (Join-Path $LabRoot 'backup/2022'),
            (Join-Path $LabRoot 'backup/2025'),
            (Join-Path $DataRoot '2019'),
            (Join-Path $DataRoot '2022'),
            (Join-Path $DataRoot '2025'),
            (Join-Path $LogRoot '2019'),
            (Join-Path $LogRoot '2022'),
            (Join-Path $LogRoot '2025')
        )) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }

    $permissionRoots = if ($StorageLayout -eq 'SINGLE_ROOT') {
        @($LabRoot)
    }
    else {
        @($LabRoot, $DataRoot, $LogRoot)
    }
    Set-LinuxPersistentStoragePermissions -Roots $permissionRoots
}

function Set-LinuxPersistentStoragePermissions {
    param([Parameter(Mandatory)][string[]] $Roots)

    if ($script:IsWindowsHost) {
        return
    }
    foreach ($command in @('id', 'chgrp', 'chmod')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "Für persistente SQL-Containerpfade fehlt das Linux-Werkzeug '$command'."
        }
    }
    $effectiveUserId = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'id' -Arguments @('-u') -Quiet
    )
    if ($effectiveUserId -ne '0') {
        throw 'Die initiale Linux-Einrichtung muss als root ausgeführt werden, damit der nicht privilegierte SQL-Container Schreibzugriff auf die ausschließlich leeren Lab-Pfade erhält. Verwenden Sie z. B. sudo pwsh ./QuickStart/Docker/Setup.ps1.'
    }
    foreach ($root in @($Roots | Select-Object -Unique)) {
        Invoke-ExternalCommand -FilePath 'chgrp' -Arguments @('-R', '0', '--', $root) -Quiet | Out-Null
        Invoke-ExternalCommand -FilePath 'chmod' -Arguments @('-R', 'g=u', '--', $root) -Quiet | Out-Null
    }
}
