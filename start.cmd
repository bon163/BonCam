@echo off
REM One-command launcher for the iPhone virtual camera test setup.
REM A .cmd wrapper is not subject to PowerShell's execution policy, so this runs
REM start.ps1 without needing Set-ExecutionPolicy or a long -ExecutionPolicy Bypass
REM command. Just run:  .\start.cmd   (optionally with -Rebuild or -Release)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
