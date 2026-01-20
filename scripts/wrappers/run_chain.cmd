@echo off
setlocal
REM Wrapper to avoid PowerShell execution policy blocks.
REM Remove Python interactive REPL env vars that VS Code may set
set "PYTHONINSPECT="
set "PYTHONSTARTUP="
set "PYTHON_BASIC_REPL="
REM Default UX: open shell, do not auto-start guided demo.
REM You can run the guided walkthrough from the prompt with: demo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\run_chain.ps1" -SkipDemo %*
exit /b %ERRORLEVEL%
