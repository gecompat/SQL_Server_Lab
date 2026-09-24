<#
.SYNOPSIS
    Startet einen eigenen, zeitlich begrenzten Windows-llama.cpp-Embeddingserver.
.DESCRIPTION
    Verlangt explizite Runtime, Embedding-GGUF, Backend, Accelerator, Dimension,
    Pooling, Port, TLS-Zertifikat und Key. Startet ausschließlich auf IPv4-
    Loopback und prüft Prozess-/Portbindung, TLS, Modell, Vektor und Runtime-Logs.
    Ein isolierter Worker beendet seine Prozesse bei Ownerverlust oder Fristende.
    Keine Downloads, Dienstinstallation, Truststoreänderungen oder Fallbacks.
    Die Lease läuft einschließlich Startphase. Stop verwendet dieselbe Modulsitzung.
.PARAMETER RuntimeDirectory
    Exaktes Verzeichnis einer zuvor ausgewählten Windows-Installation.
.PARAMETER Backend
    Explizit LlamaCppCuda oder LlamaCppOpenVino; mehrdeutige Pakete blockieren.
.PARAMETER Accelerator
    CPU, GPU oder NPU. CUDA-NPU ist ausgeschlossen; CUDA-GPU verwendet CUDA0.
.PARAMETER ComputeSelection
    Gebundene SqlServerLab.AiComputeSelection/1.0-Auswahl. Runtime, Modell,
    Inventar und Geräte werden vor dem Start erneut geprüft.
.PARAMETER Inventory
    Vollständiges Hardwareinventar, an das ComputeSelection gebunden ist.
.PARAMETER DeviceBinding
    Optionale explizite Zuordnung der ausgewählten Geräte zu llama.cpp-Selektoren.
    Ohne Angabe wird die aktuelle --list-devices-Ausgabe eindeutig ausgewertet.
.PARAMETER ModelPath
    Explizites vorhandenes Embedding-GGUF; Generationsmodelle sind ungeeignet.
.PARAMETER ModelName
    Einziger Modellalias, der anschließend am HTTPS-Endpunkt verifiziert wird.
.PARAMETER Dimension
    Erwartete Dimension zwischen 1 und 1998.
.PARAMETER Pooling
    Zum Modell passendes mean, cls oder last.
.PARAMETER Port
    Expliziter freier Loopback-Port; bestehende Listener werden nicht übernommen.
.PARAMETER CertificatePath
    Caller-eigenes PEM-Zertifikat mit SAN für 127.0.0.1.
.PARAMETER PrivateKeyPath
    Caller-eigener passender PEM-Key; wird weder kopiert noch entfernt.
.PARAMETER ApiKey
    SecureString mit 24 bis 256 ASCII-Buchstaben, Ziffern, Unterstrichen oder Bindestrichen.
.PARAMETER TrustedRootPath
    Optionales öffentliches CA-PEM, nur für die aktuelle Probe vertraut.
.PARAMETER StartTimeoutSeconds
    Startbudget bis zur erfolgreichen Probe, maximal 600 Sekunden.
.PARAMETER LeaseSeconds
    Maximale Gesamtlaufzeit des eigenen Servers, höchstens eine Stunde.
.PARAMETER ContextSize
    Explizites Kontext-/Batchbudget; muss zum Modell passen.
.PARAMETER CaptureArtifactEvidence
    Hasht optional erst nach lokaler Auswahl und erfolgreicher Probe die verwendeten Dateien.
.OUTPUTS
    SqlServerLab.LlamaCppOwnedRuntime/1.0; API-Key und lokale Dateipfade fehlen.
.EXAMPLE
    $runtime = Start-SqlServerLabLlamaCppRuntime -RuntimeDirectory 'C:\Pfad\llama' -Backend LlamaCppCuda -Accelerator GPU -ModelPath 'C:\Pfad\embedding.gguf' -ModelName local-embedding -Dimension 768 -Pooling mean -Port 19435 -CertificatePath $cert -PrivateKeyPath $key -ApiKey $apiKey
#>
function Start-SqlServerLabLlamaCppRuntime {
    [CmdletBinding(SupportsShouldProcess,DefaultParameterSetName='Explicit')]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory,ParameterSetName='Explicit')][ValidateSet('LlamaCppCuda','LlamaCppOpenVino')][string]$Backend,
        [Parameter(Mandatory,ParameterSetName='Explicit')][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory,ParameterSetName='Selected')][object]$ComputeSelection,
        [Parameter(Mandatory,ParameterSetName='Selected')][object]$Inventory,
        [Parameter(ParameterSetName='Selected')][ValidateCount(1,16)][object[]]$DeviceBinding,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ModelName,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidateSet('mean','cls','last')][string]$Pooling,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][SecureString]$ApiKey,
        [string]$TrustedRootPath,
        [ValidateRange(1,600)][int]$StartTimeoutSeconds=120,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900,
        [ValidateRange(32,8192)][int]$ContextSize=512,
        [switch]$CaptureArtifactEvidence
    )
    if ($PSCmdlet.ShouldProcess('owned llama.cpp runtime', 'Start')) {
        $arguments = @{} + $PSBoundParameters
        $arguments.Remove('WhatIf'); $arguments.Remove('Confirm')
        Start-LabLlamaCppOwnedRuntime @arguments
    }
}
