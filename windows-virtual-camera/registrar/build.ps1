$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'register_virtual_camera.cpp'
$outDir = Join-Path $PSScriptRoot 'bin'
$out = Join-Path $outDir 'register_virtual_camera.exe'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw 'Could not find vswhere.exe. Install Visual Studio 2022 Build Tools with Desktop development with C++.'
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw 'Could not find Visual C++ build tools. Install Visual Studio 2022 Build Tools with Desktop development with C++.'
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    throw "Could not find vcvars64.bat at $vcvars"
}

$cmd = 'call "' + $vcvars + '" >nul && cl /std:c++20 /EHsc /nologo "' + $source + '" /Fe:"' + $out + '"'
cmd /c $cmd
if ($LASTEXITCODE -ne 0) {
    throw "C++ build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $out)) {
    throw "Build finished but executable was not created: $out"
}

Write-Host "Built $out" -ForegroundColor Green
