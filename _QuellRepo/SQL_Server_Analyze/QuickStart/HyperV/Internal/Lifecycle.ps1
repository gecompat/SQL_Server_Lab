function Remove-Environment {
    Write-Section 'Hyper-V QuickStart entfernen'
    $config = Read-EnvFile -Path $script:EnvPath
    if ($config.Count -eq 0) {
        Write-Host 'Keine Konfiguration gefunden. Nichts zu entfernen.'
        return
    }

    $labRoot = $config['LAB_ROOT']
    $scopeId = $config['SCOPE_ID']
    $versions = $config['SQL_VERSIONS'] -split ','
    $osMode = $config['OS_MODE']

    # Scope-Marker pruefen
    if (-not [string]::IsNullOrWhiteSpace($labRoot) -and (Test-Path -LiteralPath $labRoot)) {
        if (-not (Test-ScopeMarker -Path $labRoot -ScopeId $scopeId)) {
            throw "Scope-Marker in '$labRoot' stimmt nicht mit der aktuellen Konfiguration ueberein. Entfernung abgebrochen."
        }
    }

    # VM-Liste zusammenstellen
    $vmNames = @()
    foreach ($version in $versions) {
        if ($osMode -in @('Windows', 'Mixed')) { $vmNames += "SQL_Analyze_Win_$version" }
        if ($osMode -in @('Linux', 'Mixed')) { $vmNames += "SQL_Analyze_Linux_$version" }
    }

    Write-Host 'Folgende Ressourcen werden entfernt:'
    foreach ($name in $vmNames) {
        Write-Host "  - VM: $name"
    }
    Write-Host "  - Switch: $($script:SwitchName)"
    Write-Host "  - NAT: $($script:NatName)"
    Write-Host "  - Pfad: $labRoot"
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'VMs und Konfiguration entfernen?')) {
        Write-Host 'Abgebrochen.'
        return
    }

    # VMs stoppen und entfernen
    foreach ($vmName in $vmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($null -eq $vm) { continue }

        if ($vm.State -eq 'Running') {
            Write-Host "Stoppe VM '$vmName'..."
            Stop-VM -Name $vmName -TurnOff -Force
        }

        Write-Host "Entferne VM '$vmName'..."
        Remove-VM -Name $vmName -Force
    }

    # Netzwerk entfernen
    Remove-LabSwitch

    # Daten entfernen (zweite Bestaetigung fuer destruktive Aktion)
    if (Test-Path -LiteralPath $labRoot) {
        Write-Host ''
        if (Read-YesNo -Prompt "Datenpfad '$labRoot' vollstaendig loeschen? (UNWIDERRUFLICH)") {
            # Nochmals Scope-Marker pruefen vor Loeschung
            if (Test-ScopeMarker -Path $labRoot -ScopeId $scopeId) {
                # ReadOnly-Flag von Base-VHDs entfernen
                $baseDir = Join-Path $labRoot 'base'
                if (Test-Path -LiteralPath $baseDir) {
                    Get-ChildItem -Path $baseDir -Filter '*.vhdx' | ForEach-Object {
                        Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    }
                }
                Remove-Item -LiteralPath $labRoot -Recurse -Force
                Write-Host "Pfad '$labRoot' entfernt."
            }
            else {
                Write-Warning 'Scope-Marker nicht mehr gueltig. Manuelle Bereinigung erforderlich.'
            }
        }
    }

    # SSH-Keys entfernen
    $sshDir = Join-Path $PSScriptRoot '.ssh'
    if (Test-Path -LiteralPath $sshDir) {
        Remove-Item -LiteralPath $sshDir -Recurse -Force
        Write-Host 'SSH-Schluessel entfernt.'
    }

    # .env entfernen
    if (Test-Path -LiteralPath $script:EnvPath) {
        Remove-Item -LiteralPath $script:EnvPath -Force
        Write-Host 'Konfiguration entfernt.'
    }

    Write-Host ''
    Write-Host 'Hyper-V QuickStart vollstaendig entfernt.'
}
