<#
    start.ps1 — ONE command to bring the iPhone virtual camera up for testing.

    Run it from a normal PowerShell window:

        .\start.ps1

    It self-elevates (a single UAC prompt), then in the elevated window it:
      1. prints the address to type into the iPhone app,
      2. makes sure the virtual-camera DLL is installed machine-wide,
      3. registers the camera for ALL users (so Teams, Zoom, Discord all see it),
      4. runs the host in the foreground so you can watch the log.

    Press Ctrl+C to stop the host AND unregister the camera.

    Switches:
      -Rebuild   force a rebuild + reinstall of the virtual-camera DLL first
      -Release   run the host optimised (release build)
#>
param(
    [switch]$Rebuild,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Self-elevate: relaunch this same script in an elevated window, then exit ---
# Admin is required to register the camera for all users (the bit Teams needs).
if (-not (Test-Admin)) {
    Write-Host 'Requesting administrator rights (so every app, including Teams, can see the camera)...' -ForegroundColor Cyan
    $argList = @('-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    if ($Rebuild) { $argList += '-Rebuild' }
    if ($Release) { $argList += '-Release' }
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host 'Elevation was cancelled. The camera cannot be registered for Teams without it.' -ForegroundColor Red
    }
    return
}

# From here on we are elevated. RunAs does not set the working directory, so anchor
# everything to the script's own folder (this is also the Rust workspace root).
Set-Location $root

# --- 1. Show the address to type into the iPhone app ---
# Prefer a real DHCP-assigned LAN address (skip 169.254 link-local / loopback),
# and favour Wi-Fi when there is more than one.
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.PrefixOrigin -eq 'Dhcp' -and $_.IPAddress -notlike '169.*' } |
    Sort-Object -Property @{ Expression = { $_.InterfaceAlias -match 'Wi' } } -Descending |
    Select-Object -First 1).IPAddress
if (-not $ip) { $ip = '<no Wi-Fi/LAN IPv4 found - check the network>' }

Write-Host ''
Write-Host '=======================================================' -ForegroundColor Green
Write-Host "  On the iPhone app, set the Windows host to:" -ForegroundColor Green
Write-Host "      $ip" -ForegroundColor Yellow
Write-Host "  (bare IP only - no http://, no port, no /phone)" -ForegroundColor DarkGray
Write-Host '=======================================================' -ForegroundColor Green
Write-Host ''

# --- 2. Ensure the virtual-camera DLL is installed machine-wide ---
$installedDll = Join-Path $env:ProgramData 'IPhoneCameraStreaming\iphone_camera_source.dll'
if ($Rebuild -or -not (Test-Path $installedDll)) {
    Write-Host 'Building + installing the virtual-camera DLL (machine-wide)...' -ForegroundColor Cyan
    if ($Rebuild) { & (Join-Path $root 'windows-virtual-camera\source\build.ps1') }
    & (Join-Path $root 'windows-virtual-camera\source\install-machine.ps1')
} else {
    Write-Host 'Virtual-camera DLL already installed (pass -Rebuild to force a fresh build).' -ForegroundColor DarkGray
}

# --- 3. Register the camera for all users, in the background ---
# register_virtual_camera.exe blocks waiting for Enter and unregisters on exit, so
# we run it hidden, keep its handle, and tear it down ourselves in the finally block.
$regExe = Join-Path $root 'windows-virtual-camera\registrar\bin\register_virtual_camera.exe'
if (-not (Test-Path $regExe)) {
    Write-Host 'Building the camera registrar...' -ForegroundColor Cyan
    & (Join-Path $root 'windows-virtual-camera\registrar\build.ps1')
}
Write-Host 'Registering the virtual camera for all users...' -ForegroundColor Cyan
$reg = Start-Process -FilePath $regExe -ArgumentList 'start', 'all-users', 'system' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1
if ($reg.HasExited) {
    throw "Registrar exited immediately (exit code $($reg.ExitCode)); the camera was not registered. Check Windows Settings > Privacy & security > Camera."
}
Write-Host 'Camera registered.' -ForegroundColor Green

# --- 4. Run the host in the foreground; clean up on exit ---
try {
    Write-Host ''
    Write-Host 'Starting the host. Stream from the phone, then pick "iPhone Camera" in your app.' -ForegroundColor Green
    Write-Host 'Press Ctrl+C here to stop everything.' -ForegroundColor Green
    Write-Host ''
    $hostArgs = @('run', '-p', 'windows-host')
    if ($Release) { $hostArgs += '--release' }
    & cargo @hostArgs
} finally {
    Write-Host ''
    Write-Host 'Stopping and unregistering the virtual camera...' -ForegroundColor Cyan
    if ($reg -and -not $reg.HasExited) {
        Stop-Process -Id $reg.Id -Force -ErrorAction SilentlyContinue
    }
    try { & $regExe remove all-users system | Out-Null } catch { }
    Write-Host 'Done. Camera unregistered.' -ForegroundColor Green
}
