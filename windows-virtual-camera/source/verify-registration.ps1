$ErrorActionPreference = 'Stop'
$clsid = '{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}'
$locations = @(
    "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\$clsid\InprocServer32",
    "Registry::HKEY_LOCAL_MACHINE\Software\Classes\CLSID\$clsid\InprocServer32"
)

foreach ($location in $locations) {
    Write-Host "Checking $location"
    if (Test-Path $location) {
        $item = Get-ItemProperty -Path $location
        $defaultValue = $item.'(default)'
        if (-not $defaultValue) {
            $defaultValue = (Get-Item -Path $location).GetValue('')
        }
        Write-Host "  DLL: $defaultValue" -ForegroundColor Green
        Write-Host "  ThreadingModel: $($item.ThreadingModel)" -ForegroundColor Green
    } else {
        Write-Host '  Not registered' -ForegroundColor Yellow
    }
}
