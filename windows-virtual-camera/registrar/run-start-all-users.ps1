$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'bin\register_virtual_camera.exe'
if (-not (Test-Path $exe)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'All-users virtual camera registration needs an Administrator PowerShell window.'
}

& $exe start all-users
