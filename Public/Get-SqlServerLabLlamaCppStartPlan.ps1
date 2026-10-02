function Get-SqlServerLabLlamaCppStartPlan {
    <#
    .SYNOPSIS
        Zeigt eine reine Dateivorschau für einen eigenen SQL-Embeddingserver.
    .DESCRIPTION
        Prüft eine explizite CUDA-/OpenVINO-Installation und genau vier GGUF-Bytes.
        Die Vorschau bleibt PLAN_ONLY/BLOCKED. Sie startet nichts und prüft weder
        Geräte, Port, TLS, Secrets noch SQL. Zwei Metadatenbeobachtungen sind kein
        Byteintegritäts-, CAS-, Kompatibilitäts- oder späterer Ausführungsnachweis.
        Die Ausgabe enthält keine lokalen Pfade und keinen ausführbaren PlanKey.
    .PARAMETER RuntimeDirectory
        Explizites lokales Installationsverzeichnis; höchstens 16 direkte Unterordner
        und 256 Dateien je betrachtetem Verzeichnis, keine Reparse-Pfade.
    .PARAMETER Backend
        Explizit LlamaCppCuda oder LlamaCppOpenVino; kein automatischer Fallback.
    .PARAMETER Accelerator
        Gewünschte CPU, GPU oder NPU; CUDA-NPU ist ausgeschlossen.
    .PARAMETER ModelPath
        Explizite reguläre lokale GGUF-Datei; das Format belegt keine Embeddingeignung.
    .PARAMETER Dimension
        Gewünschte Dimension zwischen 1 und 1998; nicht gegen das Modell verifiziert.
    .PARAMETER Pooling
        Gewünschtes mean, cls oder last; Kompatibilität bleibt ungeprüft.
    .PARAMETER Port
        Gewünschter Port von 1024 bis 65535; es wird kein Listener abgefragt oder gebunden.
    .PARAMETER StartTimeoutSeconds
        Vorgesehenes Startbudget von 1 bis 600 Sekunden.
    .PARAMETER LeaseSeconds
        Vorgesehene Lease von 30 bis 3600 Sekunden, größer als das Startbudget.
    .PARAMETER ContextSize
        Gewünschtes Kontextbudget von 32 bis 8192.
    .OUTPUTS
        SqlServerLab.LlamaCppStartPlan/1.0, nicht ausführbar, ohne Actions.
    .EXAMPLE
        Get-SqlServerLabLlamaCppStartPlan -RuntimeDirectory 'C:\Lab\Runtime' -Backend LlamaCppCuda -Accelerator CPU -ModelPath 'C:\Lab\embedding.gguf' -Dimension 768 -Pooling mean -Port 19435
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,4096)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][ValidateSet('LlamaCppCuda','LlamaCppOpenVino')][string]$Backend,
        [Parameter(Mandatory)][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,4096)][string]$ModelPath,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidateSet('mean','cls','last')][string]$Pooling,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [ValidateRange(1,600)][int]$StartTimeoutSeconds=120,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900,
        [ValidateRange(32,8192)][int]$ContextSize=512
    )
    # Canonical enum spelling prevents arbitrary/case-changed caller text in the DTO.
    $arguments=@{RuntimeDirectory=$RuntimeDirectory;ModelPath=$ModelPath;Dimension=$Dimension;Port=$Port}
    $arguments.Backend=if($Backend -ieq 'LlamaCppCuda'){'LlamaCppCuda'}else{'LlamaCppOpenVino'}
    $arguments.Accelerator=@{CPU='CPU';GPU='GPU';NPU='NPU'}[$Accelerator.ToUpperInvariant()]
    $arguments.Pooling=$Pooling.ToLowerInvariant()
    $arguments.StartTimeoutSeconds=$StartTimeoutSeconds;$arguments.LeaseSeconds=$LeaseSeconds;$arguments.ContextSize=$ContextSize
    Get-LabLlamaCppStartPlan @arguments
}
