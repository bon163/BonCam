$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'iphone_camera_source.cpp'
$outDir = Join-Path $PSScriptRoot 'bin'
$out = Join-Path $outDir 'iphone_camera_source.dll'
$def = Join-Path $PSScriptRoot 'iphone_camera_source.def'
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

$cmd = 'call "' + $vcvars + '" >nul && cl /std:c++20 /EHsc /LD /nologo "' + $source + '" /Fe:"' + $out + '" /link /DEF:"' + $def + '"'
cmd /c $cmd
if ($LASTEXITCODE -ne 0) {
    throw "C++ source DLL build failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $out)) {
    throw "Build finished but DLL was not created: $out"
}
Write-Host "Built $out" -ForegroundColor Green
