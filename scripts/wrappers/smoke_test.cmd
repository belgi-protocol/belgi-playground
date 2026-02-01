@echo off
setlocal
REM Wrapper to avoid PowerShell execution policy blocks.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\smoke_test.ps1" %*
exit /b %ERRORLEVEL%
