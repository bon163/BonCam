$ErrorActionPreference = 'Stop'

$outDir = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$probes = @('probe_source_reader', 'probe_device_reader', 'probe_dshow')

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

foreach ($probe in $probes) {
    $source = Join-Path $PSScriptRoot "$probe.cpp"
    $out = Join-Path $outDir "$probe.exe"
    $cmd = 'call "' + $vcvars + '" >nul && cl /std:c++20 /EHsc /nologo "' + $source + '" /Fe:"' + $out + '"'
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Probe build failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path $out)) {
        throw "Build finished but probe was not created: $out"
    }
    Write-Host "Built $out" -ForegroundColor Green
}
