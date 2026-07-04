$ErrorActionPreference = 'Stop'
$clsid = '{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}'
Remove-Item -Recurse -Force "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\$clsid" -ErrorAction SilentlyContinue
Write-Host 'Removed current-user COM registration.' -ForegroundColor Green

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Remove-Item -Recurse -Force "Registry::HKEY_LOCAL_MACHINE\Software\Classes\CLSID\$clsid" -ErrorAction SilentlyContinue
    Write-Host 'Removed machine-wide COM registration.' -ForegroundColor Green
} else {
    Write-Host 'Machine-wide registration was not removed because this shell is not elevated.' -ForegroundColor Yellow
}
