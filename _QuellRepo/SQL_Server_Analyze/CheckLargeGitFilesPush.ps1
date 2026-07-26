[CmdletBinding()]
param(
    [double]$LimitMB,
    [string]$LogFileName,
    [switch]$CheckOnly,
    [switch]$AllFiles,
    [Alias('help')]
    [switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

# Default-Konfiguration
$DefaultLimitMB     = 49
$DefaultLogFileName = 'large_files_log.txt'

# Parallelisierung
$ParallelMinFiles      = 40
$ParallelThrottleLimit = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 8))

function Write-ScriptMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [switch]$BlankLineBefore,
        [switch]$BlankLineAfter
    )

    if ($BlankLineBefore) {
        Write-Host ''
    }

    Write-Host $Message -ForegroundColor $Color

    if ($BlankLineAfter) {
        Write-Host ''
    }
}

function Write-StatusLine {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO','NEW','CHANGE','DELETE')]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $color = switch ($Type) {
        'INFO'   { [ConsoleColor]::Cyan }
        'NEW'    { [ConsoleColor]::Green }
        'CHANGE' { [ConsoleColor]::Yellow }
        'DELETE' { [ConsoleColor]::Red }
    }

    Write-Host ('[{0}] {1}' -f $Type, $Message) -ForegroundColor $color
}

function Show-Usage {
    param(
        [string]$ScriptName = 'CheckLargeGitFilesPush.ps1'
    )

    Write-ScriptMessage -Message $ScriptName -Color Cyan -BlankLineAfter
    Write-ScriptMessage -Message 'Funktion:' -Color Magenta
    Write-ScriptMessage -Message '  Prüft in einem Git-Repository Dateien auf eine Größe größer als LimitMB.' -Color Cyan
    Write-ScriptMessage -Message '  Standardmäßig werden nur neue oder geänderte Dateien geprüft.' -Color Cyan
    Write-ScriptMessage -Message '  Mit -AllFiles werden alle Dateien im Repository geprüft.' -Color Cyan
    Write-ScriptMessage -Message '  .gitignore wird berücksichtigt.' -Color Cyan -BlankLineAfter

    Write-ScriptMessage -Message 'Verhalten:' -Color Magenta
    Write-ScriptMessage -Message '  - Bei Treffern werden die Dateien auf der Konsole ausgegeben und zusätzlich in eine Logdatei im Git-Root geschrieben.' -Color Cyan
    Write-ScriptMessage -Message '  - Werden keine zu großen Dateien gefunden, wird kein Log geschrieben.' -Color Cyan
    Write-ScriptMessage -Message '  - Wenn keine zu großen Dateien gefunden wurden und -CheckOnly nicht gesetzt ist,' -Color Cyan
    Write-ScriptMessage -Message '    zeigt das Script zuerst die tatsächlich zu commitenden Dateien an und fragt danach nach einer Commit-Message.' -Color Cyan
    Write-ScriptMessage -Message '  - Anschließend führt das Script git commit und git push aus.' -Color Cyan
    Write-ScriptMessage -Message '  - LimitMB muss kleiner als 100 MB sein.' -Color Cyan -BlankLineAfter

    Write-ScriptMessage -Message 'Parameter:' -Color Magenta
    Write-ScriptMessage -Message "  -LimitMB <Zahl>        Optional. Default: $DefaultLimitMB" -Color Cyan
    Write-ScriptMessage -Message '      Maximale erlaubte Dateigröße in MB. Es werden nur Dateien > LimitMB gemeldet.' -Color Cyan
    Write-ScriptMessage -Message "  -LogFileName <Pfad>   Optional. Default: $DefaultLogFileName" -Color Cyan
    Write-ScriptMessage -Message '      Relativer Pfad zur Logdatei, bezogen auf das Git-Root.' -Color Cyan
    Write-ScriptMessage -Message '  -AllFiles             Prüft alle Dateien im Repository statt nur neue oder geänderte Dateien.' -Color Cyan
    Write-ScriptMessage -Message '  -CheckOnly            Führt nur die Prüfung aus. Commit und Push werden übersprungen.' -Color Cyan
    Write-ScriptMessage -Message '  -Help | -help | /?    Zeigt diese Hilfe mit Beispielen an.' -Color Cyan -BlankLineAfter

    Write-ScriptMessage -Message 'Aufrufbeispiele:' -Color Magenta
    Write-ScriptMessage -Message "  .\$ScriptName" -Color Cyan
    Write-ScriptMessage -Message "      Prüft nur neue oder geänderte Dateien mit dem Default-Limit von $DefaultLimitMB MB." -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -LimitMB 90" -Color Cyan
    Write-ScriptMessage -Message '      Prüft nur neue oder geänderte Dateien mit einem Limit von 90 MB.' -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -AllFiles" -Color Cyan
    Write-ScriptMessage -Message '      Prüft alle Dateien im Repository mit dem Default-Limit.' -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -AllFiles -LimitMB 90" -Color Cyan
    Write-ScriptMessage -Message '      Prüft alle Dateien im Repository mit einem Limit von 90 MB.' -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -CheckOnly" -Color Cyan
    Write-ScriptMessage -Message '      Prüft nur und führt keinen Commit und keinen Push aus.' -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -LogFileName 'logs\large_files_log.txt'" -Color Cyan
    Write-ScriptMessage -Message '      Schreibt das Log bei Treffern nach <GitRoot>\logs\large_files_log.txt.' -Color Green
    Write-ScriptMessage -Message "  .\$ScriptName -AllFiles -CheckOnly -LimitMB 50" -Color Cyan
    Write-ScriptMessage -Message '      Prüft alle Dateien mit 50 MB Limit, ohne Commit und ohne Push.' -Color Green
}

function Split-NullTerminatedGitOutput {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    return $Text -split "`0" | Where-Object { -not [string]::IsNullOrEmpty($_) }
}

function Get-CommitFileList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitRoot,
        [Parameter(Mandatory = $true)]
        [string]$GitLogPath
    )

    $output = & git -C $GitRoot diff --cached --name-status --find-renames=100% -- . ":(exclude)$GitLogPath"
    if ($LASTEXITCODE -ne 0) {
        throw 'Fehler beim Ermitteln der staged Dateien.'
    }

    $items = @()

    foreach ($line in ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) {
            continue
        }

        $statusCode = $parts[0]
        $pathText = if ($statusCode -match '^[RC]') {
            if ($parts.Count -ge 3) {
                '{0} -> {1}' -f $parts[1], $parts[2]
            }
            else {
                $parts[1]
            }
        }
        else {
            $parts[1]
        }

        $displayType = switch -Regex ($statusCode) {
            '^A' { 'NEW'; break }
            '^D' { 'DELETE'; break }
            default { 'CHANGE'; break }
        }

        $items += [PSCustomObject]@{
            Type       = $displayType
            StatusCode = $statusCode
            Path       = $pathText
        }
    }

    return @($items)
}

try {
    if ($ShowHelp -or ($RemainingArgs -contains '/?') -or ($RemainingArgs -contains '-help') -or ($RemainingArgs -contains '--help')) {
        Show-Usage -ScriptName ([System.IO.Path]::GetFileName($PSCommandPath))
        exit 0
    }

    # Prüfen, ob git verfügbar ist
    $null = Get-Command git -ErrorAction Stop

    # Git-Root früh ermitteln
    $GitRoot = (& git rev-parse --show-toplevel 2>$null).Trim()

    if ([string]::IsNullOrWhiteSpace($GitRoot)) {
        throw 'Das aktuelle Verzeichnis liegt nicht innerhalb eines Git-Repositories.'
    }

    # Effektive Konfiguration
    if (-not $PSBoundParameters.ContainsKey('LimitMB')) {
        $LimitMB = $DefaultLimitMB
    }

    if (-not $PSBoundParameters.ContainsKey('LogFileName')) {
        $LogFileName = $DefaultLogFileName
    }

    if ($LimitMB -le 0) {
        throw 'LimitMB muss größer als 0 sein.'
    }

    if ($LimitMB -ge 100) {
        throw 'LimitMB muss kleiner als 100 MB sein (GitHub unterstützt keine größeren Files!). Beispiel: .\CheckLargeGitFilesPush.ps1 -LimitMB 90'
    }

    if ([System.IO.Path]::IsPathRooted($LogFileName)) {
        throw 'LogFileName muss relativ zum Git-Root angegeben werden, nicht als absoluter Pfad.'
    }

    $LogFile      = Join-Path $GitRoot $LogFileName
    $GitLogPath   = ($LogFileName -replace '\\', '/')
    $LimitBytes   = [int64][Math]::Round($LimitMB * 1MB)
    $LogDirectory = Split-Path -Parent $LogFile

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    if ($AllFiles) {
        # Alle tracked Files + untracked, aber nicht ignorierte Files
        $allFilesRaw = & git -C $GitRoot ls-files -z --cached --others --exclude-standard
        if ($LASTEXITCODE -ne 0) {
            throw 'Fehler beim Ermitteln aller Dateien über git ls-files.'
        }

        foreach ($path in (Split-NullTerminatedGitOutput -Text $allFilesRaw)) {
            if ($path -ne $GitLogPath) {
                [void]$candidateSet.Add($path)
            }
        }
    }
    else {
        # Nur neue oder geänderte Files:
        # 1) neue/untracked Files, aber nicht ignorierte Files
        # 2) geänderte tracked Files (unstaged)
        # 3) geänderte tracked Files (staged)
        $untrackedRaw = & git -C $GitRoot ls-files -z --others --exclude-standard
        if ($LASTEXITCODE -ne 0) {
            throw 'Fehler beim Ermitteln untracked Dateien über git ls-files.'
        }

        foreach ($path in (Split-NullTerminatedGitOutput -Text $untrackedRaw)) {
            if ($path -ne $GitLogPath) {
                [void]$candidateSet.Add($path)
            }
        }

        $unstagedRaw = & git -C $GitRoot diff --name-only -z --diff-filter=ACMR
        if ($LASTEXITCODE -ne 0) {
            throw 'Fehler beim Ermitteln unstaged Änderungen über git diff.'
        }

        foreach ($path in (Split-NullTerminatedGitOutput -Text $unstagedRaw)) {
            if ($path -ne $GitLogPath) {
                [void]$candidateSet.Add($path)
            }
        }

        $stagedRaw = & git -C $GitRoot diff --cached --name-only -z --diff-filter=ACMR
        if ($LASTEXITCODE -ne 0) {
            throw 'Fehler beim Ermitteln staged Änderungen über git diff --cached.'
        }

        foreach ($path in (Split-NullTerminatedGitOutput -Text $stagedRaw)) {
            if ($path -ne $GitLogPath) {
                [void]$candidateSet.Add($path)
            }
        }
    }

    $relativePaths = @($candidateSet | Sort-Object)
    $useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($relativePaths.Count -ge $ParallelMinFiles)

    if ($relativePaths.Count -gt 0) {
        if ($useParallel) {
            $matches = $relativePaths | ForEach-Object -Parallel {
                $relativePath = $_
                $fullPath = Join-Path $Using:GitRoot $relativePath

                if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                    $file = Get-Item -LiteralPath $fullPath

                    if ($file.Length -gt $Using:LimitBytes) {
                        [PSCustomObject]@{
                            RelativePath = $relativePath
                            FullPath     = $fullPath
                            SizeBytes    = [int64]$file.Length
                            SizeMB       = [Math]::Round($file.Length / 1MB, 2)
                        }
                    }
                }
            } -ThrottleLimit $ParallelThrottleLimit
        }
        else {
            $matches = foreach ($relativePath in $relativePaths) {
                $fullPath = Join-Path $GitRoot $relativePath

                if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                    $file = Get-Item -LiteralPath $fullPath

                    if ($file.Length -gt $LimitBytes) {
                        [PSCustomObject]@{
                            RelativePath = $relativePath
                            FullPath     = $fullPath
                            SizeBytes    = [int64]$file.Length
                            SizeMB       = [Math]::Round($file.Length / 1MB, 2)
                        }
                    }
                }
            }
        }
    }
    else {
        $matches = @()
    }

    $matches = @($matches) |
        Where-Object { $null -ne $_ } |
        Sort-Object @(
            @{ Expression = 'SizeBytes'; Descending = $true }
            @{ Expression = 'RelativePath'; Descending = $false }
        )

    if ($matches.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
            $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        }

        if ($AllFiles) {
            $logHeader = "Large files > $LimitMB MB (alle Files im Repository)"
        }
        else {
            $logHeader = "Large files > $LimitMB MB (nur neue oder geänderte Files)"
        }

        $logLines = @(
            $logHeader
            "Git root: $GitRoot"
            "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            ''
        )

        foreach ($item in $matches) {
            $logLines += "{0}`t{1:N2} MB" -f $item.RelativePath, $item.SizeMB
        }

        $logLines | Out-File -FilePath $LogFile -Encoding UTF8

        Write-ScriptMessage -Message '---------------------------' -Color DarkCyan -BlankLineBefore
        Write-ScriptMessage -Message ("Folgende Files größer als {0} MB wurden gefunden:" -f $LimitMB) -Color Red -BlankLineAfter

        foreach ($item in $matches) {
            Write-ScriptMessage -Message ("{0}`t{1:N2} MB" -f $item.FullPath, $item.SizeMB) -Color Red
        }

        Write-Host ''
        Write-ScriptMessage -Message 'Du kannst das Limit wie folgt übersteuern:' -Color Magenta
        Write-ScriptMessage -Message '.\CheckLargeGitFilesPush.ps1 -LimitMB 90' -Color Cyan
        Write-ScriptMessage -Message '---------------------------' -Color DarkCyan -BlankLineAfter
        Write-ScriptMessage -Message ("Log geschrieben nach: {0}" -f $LogFile) -Color Cyan
        exit 0
    }

    if ($AllFiles) {
        Write-ScriptMessage -Message ("Keine Files im Repository größer als {0} MB gefunden." -f $LimitMB) -Color Green -BlankLineBefore
    }
    else {
        Write-ScriptMessage -Message ("Keine neuen oder geänderten Files größer als {0} MB gefunden." -f $LimitMB) -Color Green -BlankLineBefore
    }

    if ($CheckOnly) {
        Write-ScriptMessage -Message 'CheckOnly aktiv: Commit und Push werden übersprungen.' -Color Cyan
        exit 0
    }

    # Alle Änderungen stagen, aber die Logdatei explizit ausschließen.
    # Danach wird exakt angezeigt, was tatsächlich committed würde.
    & git -C $GitRoot add -A -- . ":(exclude)$GitLogPath"
    if ($LASTEXITCODE -ne 0) {
        throw 'Fehler bei git add.'
    }

    & git -C $GitRoot diff --cached --quiet --exit-code
    $hasStagedChanges = ($LASTEXITCODE -ne 0)

    if (-not $hasStagedChanges) {
        Write-ScriptMessage -Message 'Es gibt nichts zu committen. Commit und Push werden übersprungen.' -Color Green -BlankLineBefore
        exit 0
    }

    $commitFiles = Get-CommitFileList -GitRoot $GitRoot -GitLogPath $GitLogPath

    Write-ScriptMessage -Message 'Folgende Dateien werden committed:' -Color Magenta -BlankLineBefore -BlankLineAfter

    foreach ($item in $commitFiles) {
        Write-StatusLine -Type $item.Type -Message $item.Path
    }

    Write-ScriptMessage -Message 'Bitte Commit-Message eingeben:' -Color Magenta -BlankLineBefore
    $CommitMessage = Read-Host '>'
    Write-Host ''

    if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        throw 'Commit-Message darf nicht leer sein.'
    }

    & git -C $GitRoot commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        throw 'Fehler bei git commit.'
    }

    & git -C $GitRoot push
    if ($LASTEXITCODE -ne 0) {
        throw 'Fehler bei git push.'
    }

    Write-ScriptMessage -Message 'Commit und Push erfolgreich abgeschlossen.' -Color Green -BlankLineBefore
}
catch {
    Write-Host ''
    $errorMessage = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = $_ | Out-String
    }
    Write-Error $errorMessage
    exit 1
}
