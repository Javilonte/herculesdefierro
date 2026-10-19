<#
.SYNOPSIS
    Sets up a runnable Hercules (TK4-) environment from a TK4- v1.00 update 5 zip.

.DESCRIPTION
    Extracts only the files needed to run the Windows 64-bit Hercules emulator
    (hercules.exe and its plugin DLLs) plus the MVS 3.8j DASD images, configs,
    JCL, scripts, and log directory from a TK4- v1.00 update 5 distribution
    zip. The result is a sibling directory `hercules_run/` next to the repo,
    ready to be started.

    Does NOT redistribute the TK4- zip or any third-party content. The zip
    remains under the Q Public License; you must obtain it from the official
    channels and respect its license.

.PARAMETER ZipPath
    Path to the TK4- v1.00 update 5 zip. If omitted, the script searches:
    1. The parent directory of the repo (looks for tk4-*.zip)
    2. %USERPROFILE%\Downloads (looks for tk4-*.zip)
    3. The current directory (looks for tk4-*.zip)

.PARAMETER RunDir
    Directory where the runnable environment is created. Defaults to
    <repo-parent>\hercules_run.

.EXAMPLE
    .\setup.ps1
    Auto-discovers the zip and creates hercules_run\ next to the repo.

.EXAMPLE
    .\setup.ps1 -ZipPath "C:\Users\you\Downloads\tk4-_v1.00_current-v05.zip"
    Uses the explicit zip path.

.NOTES
    Hercules and TK4- are third-party software under the Q Public License.
    This script only extracts them; it does not modify, recompile, or
    redistribute any binaries or source.
#>

[CmdletBinding()]
param(
    [string]$ZipPath,
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'

# Resolve script directory (works whether the script is run from a pipeline
# or directly).
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoDir   = Split-Path -Parent $ScriptDir
$ParentDir = Split-Path -Parent $RepoDir

# ---- discover the zip --------------------------------------------------------

if (-not $ZipPath) {
    $candidates = @(
        Join-Path $ParentDir 'tk4-_v1.00_current-v05.zip',
        Join-Path $env:USERPROFILE 'Downloads\tk4-_v1.00_current-v05.zip',
        Join-Path (Get-Location) 'tk4-_v1.00_current-v05.zip'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $ZipPath = $c; break }
    }
}

if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) {
    Write-Host "Could not auto-discover the TK4- v1.00 update 5 zip." -ForegroundColor Yellow
    Write-Host "Looked in:"
    Write-Host "  - $ParentDir\tk4-*.zip"
    Write-Host "  - $env:USERPROFILE\Downloads\tk4-*.zip"
    Write-Host "  - $(Get-Location)\tk4-*.zip"
    Write-Host ""
    Write-Host "Download the zip from the official TK4- distribution and pass"
    Write-Host "its path explicitly:"
    Write-Host ""
    Write-Host "  .\setup.ps1 -ZipPath 'C:\path\to\tk4-_v1.00_current-v05.zip'" -ForegroundColor Cyan
    exit 1
}

Write-Host "Using zip: $ZipPath"
$zipSize = (Get-Item -LiteralPath $ZipPath).Length
Write-Host ("  size: {0:N1} MB" -f ($zipSize / 1MB))

# ---- default RunDir ----------------------------------------------------------

if (-not $RunDir) {
    $RunDir = Join-Path $ParentDir 'hercules_run'
}
Write-Host "Run dir: $RunDir"

# ---- extract -----------------------------------------------------------------

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Subpaths from the zip that the Windows 64-bit emulator and MVS 3.8j need.
# Each prefix must end with "/". Anything not in this list is skipped, so we
# never extract Linux binaries, source code, PDFs, or 32-bit Windows builds.
$NeededPrefixes = @(
    'hercules/windows/64/',
    'conf/',
    'dasd/',
    'local_conf/',
    'scripts/',
    'log/',
    'jcl/',
    'tapes/',
    'pch/',
    'unattended/',
    'rdr/'
)

# Top-level files that need to end up next to hercules.exe (none currently,
# but listed for future-proofing).
$NeededTopLevel = @()

if (Test-Path -LiteralPath $RunDir) {
    Write-Host ""
    Write-Host "Run dir already exists. Re-extracting into the same directory" -ForegroundColor Yellow
    Write-Host "will overwrite matching files. Delete $RunDir first if you want"
    Write-Host "a clean run."
} else {
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $extracted = 0
    $skipped   = 0
    foreach ($e in $archive.Entries) {
        $matches = $false
        foreach ($p in $NeededPrefixes) {
            if ($e.FullName.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches = $true
                break
            }
        }
        if (-not $matches) {
            foreach ($t in $NeededTopLevel) {
                if ($e.FullName -eq $t) { $matches = $true; break }
            }
        }
        if (-not $matches) { $skipped++; continue }

        # Skip directory entries.
        if ($e.FullName.EndsWith('/')) { continue }

        $outPath = Join-Path $RunDir ($e.FullName.Replace('/', '\'))
        $outDir  = Split-Path -Parent $outPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $outPath, $true)
        $extracted++
    }
} finally {
    $archive.Dispose()
}

Write-Host ""
Write-Host "Extracted $extracted files into $RunDir"

# ---- verify ------------------------------------------------------------------

$must = @(
    'hercules\windows\64\hercules.exe',
    'hercules\windows\64\hengine.dll',
    'conf\tk4-.cnf',
    'scripts\ipl.rc'
)
$missing = @()
foreach ($m in $must) {
    if (-not (Test-Path -LiteralPath (Join-Path $RunDir $m))) {
        $missing += $m
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: the following required files are missing after extraction:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" }
    Write-Host ""
    Write-Host "The zip you provided may not be TK4- v1.00 update 5." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Verification: all required files present." -ForegroundColor Green

# ---- report ------------------------------------------------------------------

$dasdCount = (Get-ChildItem -LiteralPath (Join-Path $RunDir 'dasd') -File -ErrorAction SilentlyContinue | Measure-Object).Count
$hengineSize = (Get-Item -LiteralPath (Join-Path $RunDir 'hercules\windows\64\hengine.dll')).Length

Write-Host ""
Write-Host "Environment ready."
Write-Host "  hercules.exe:      $RunDir\hercules\windows\64\hercules.exe"
Write-Host ("  hengine.dll:       {0:N2} MB" -f ($hengineSize / 1MB))
Write-Host "  DASD images:       $dasdCount files in dasd\"
Write-Host "  Config:            $RunDir\conf\tk4-.cnf"
Write-Host "  Run log:           $RunDir\log\3033.log (after first start)"
Write-Host ""
Write-Host "To start Hercules in the foreground (3270 console in this terminal):" -ForegroundColor Cyan
Write-Host "  cd `"$RunDir`""
Write-Host "  .\hercules\windows\64\hercules.exe -f conf\tk4-.cnf"
Write-Host ""
Write-Host "To start Hercules in daemon mode (no console, listens on TCP 27415..27418):" -ForegroundColor Cyan
Write-Host "  cd `"$RunDir`""
Write-Host "  .\hercules\windows\64\hercules.exe -d -f conf\tk4-.cnf"
Write-Host ""
Write-Host "Press Ctrl+C in the foreground terminal, or send 'shutdown' over the 3270"
Write-Host "console, to stop Hercules cleanly."
