$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'bin\register_virtual_camera.exe'
if (-not (Test-Path $exe)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
& $exe start
