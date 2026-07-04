$ErrorActionPreference = 'Stop'
$clsid = '{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}'
$dll = Join-Path $PSScriptRoot 'bin\iphone_camera_source.dll'
if (-not (Test-Path $dll)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
if (-not (Test-Path $dll)) {
    throw "Source DLL does not exist: $dll"
}

$base = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\$clsid"
$inproc = Join-Path $base 'InprocServer32'
New-Item -Force -Path $base | Out-Null
New-Item -Force -Path $inproc | Out-Null
Set-ItemProperty -Path $base -Name '(default)' -Value 'iPhone Camera Source'
Set-ItemProperty -Path $inproc -Name '(default)' -Value $dll
Set-ItemProperty -Path $inproc -Name 'ThreadingModel' -Value 'Both'

Write-Host "Registered current-user COM source:" -ForegroundColor Green
Write-Host "  CLSID: $clsid"
Write-Host "  DLL:   $dll"
