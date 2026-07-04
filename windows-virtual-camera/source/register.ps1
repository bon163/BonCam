$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'register-user.ps1')
Write-Host ''
Write-Host 'If MFCreateVirtualCamera still reports Class not registered, run register-machine.ps1 from an Administrator PowerShell window.' -ForegroundColor Yellow
