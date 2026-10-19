@echo off
REM ====================================================================
REM open-console.bat - open a 3270 console connected to local Hercules
REM ====================================================================
REM
REM Usage: open-console.bat [cpu]
REM   cpu = 0..3 (which CPU's console to open). Defaults to 0.
REM
REM Requires Hercules to be running in daemon mode on TCP 27415..27418:
REM   cd <repo-parent>\hercules_run
REM   .\hercules\windows\64\hercules.exe -d -f conf\tk4-.cnf
REM
REM Each CPU gets its own TCP port: cpu 0 -> 27415, cpu 1 -> 27416, etc.
REM
REM Requires wc3270 4.5ga6 to be on PATH (or in C:\tools\wc3270-4.5ga6\).

setlocal

set CPU=%~1
if "%CPU%"=="" set CPU=0

set PORT=2741%CPU%

set WC3270=
where wc3270 >nul 2>nul
if not errorlevel 1 set WC3270=wc3270
if "%WC3270%"=="" if exist "C:\tools\wc3270-4.5ga6\wc3270.exe" set WC3270="C:\tools\wc3270-4.5ga6\wc3270.exe"
if "%WC3270%"=="" (
    echo wc3270.exe not found. Install it (e.g. via x3270 4.5ga6 zip at https://x3270.bgp.nu/download.html) or add it to PATH.
    exit /b 1
)

echo Opening 3270 console for CPU %CPU% on localhost:%PORT% ...
%WC3270% -model 4 localhost:%PORT%
