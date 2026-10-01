@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "TOPROXMOX_PACKAGE=%~f0"
set "TOPROXMOX_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "TOPROXMOX_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
rem Suppress the failure pause for non-interactive runs (automation/CLI).
set "TOPROXMOX_NOPAUSE="
for %%A in (%*) do (
    if /i "%%~A"=="--no-pause" set "TOPROXMOX_NOPAUSE=1"
    if /i "%%~A"=="--prepare-host" set "TOPROXMOX_NOPAUSE=1"
)
"%TOPROXMOX_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand __BOOTSTRAP__ %*
set "TOPROXMOX_EXIT_CODE=%ERRORLEVEL%"
if not "%TOPROXMOX_EXIT_CODE%"=="0" if not defined TOPROXMOX_NOPAUSE pause
exit /b %TOPROXMOX_EXIT_CODE%
