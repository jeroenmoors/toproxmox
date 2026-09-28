@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "TOPROXMOX_PACKAGE=%~f0"
set "TOPROXMOX_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "TOPROXMOX_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%TOPROXMOX_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand __BOOTSTRAP__
set "TOPROXMOX_EXIT_CODE=%ERRORLEVEL%"
if not "%TOPROXMOX_EXIT_CODE%"=="0" if /i not "%~1"=="--no-pause" pause
exit /b %TOPROXMOX_EXIT_CODE%
