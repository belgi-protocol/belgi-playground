@echo off
setlocal
REM Wrapper to avoid PowerShell execution policy blocks.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\bootstrap.ps1" %*
exit /b %ERRORLEVEL%
