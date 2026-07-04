$addresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike '127.*' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Select-Object InterfaceAlias, IPAddress

if (-not $addresses) {
    Write-Host 'No active IPv4 addresses were found.' -ForegroundColor Yellow
    exit 1
}

$addresses | Format-Table -AutoSize
Write-Host ''
Write-Host 'Use the Wi-Fi IPv4 address in the iPhone app host field.' -ForegroundColor Green
