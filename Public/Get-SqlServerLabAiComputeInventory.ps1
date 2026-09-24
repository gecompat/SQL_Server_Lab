<#
.SYNOPSIS
    Inventarisiert lokale CPU-, GPU- und NPU-Geräte read-only.
.DESCRIPTION
    Erfasst unter Windows CPU und Anzeigegeräte über CIM sowie NPUs über die
    vorhandene ComputeAccelerator-PnP-Klasse. Unter Linux werden /proc/cpuinfo,
    DRM-sysfs und die Kernel-Accel-Klasse gelesen. Die Ausgabe enthält keine
    Hostnamen, Busadressen oder PnP-Instanzpfade. Nur vollständige Coverage
    erhält einen InventorySha256 für nachgelagerte Benchmarkbindungen.
.OUTPUTS
    SqlServerLab.AiComputeInventory/1.0.
#>
function Get-SqlServerLabAiComputeInventory {
    [CmdletBinding()]
    param()
    Get-LabAiComputeInventory -ProbeResult (Get-LabAiComputeHostProbe)
}
