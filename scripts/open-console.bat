@echo off
REM ====================================================================
REM open-console.bat - open a 3270 console connected to local Hercules
REM ====================================================================
REM
REM Usage: open-console.bat
REM
REM Requires Hercules to be running in daemon mode. The console listener
REM accepts connections on TCP port 3270 (the standard TN3270 port,
REM exposed by HHC01024I 'Waiting for console connections on port 3270'):
REM   cd <repo-parent>\hercules_run
REM   .\hercules\windows\64\hercules.exe -d -f conf\tk4-.cnf
REM
REM Note: ports 27415-27418 are per-CPU COMM threads for internal
REM Hercules device traffic (CTC, LCS, etc.) -- they do NOT accept 3270
REM client connections and will silently drop them. Connect to 3270.
REM
REM Requires wc3270 4.5ga6 to be on PATH (or in C:\tools\wc3270-4.5ga6\).

setlocal

set WC3270=
where wc3270 >nul 2>nul
if not errorlevel 1 set WC3270=wc3270
if "%WC3270%"=="" if exist "C:\tools\wc3270-4.5ga6\wc3270.exe" set WC3270="C:\tools\wc3270-4.5ga6\wc3270.exe"
if "%WC3270%"=="" (
    echo wc3270.exe not found. Install it (download the no-installer zip from https://x3270.bgp.nu/download.html and extract to C:\tools\wc3270-4.5ga6\) or add it to PATH.
    exit /b 1
)

echo Opening 3270 console on localhost:3270 ...
%WC3270% -model 4 localhost:3270
