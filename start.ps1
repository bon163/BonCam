<#
    start.ps1 — ONE command to bring the iPhone virtual camera up for testing.

    Run it from a normal PowerShell window:

        .\start.cmd

    (Use the start.cmd wrapper — running start.ps1 directly can be blocked by the
    PowerShell execution policy; the .cmd is not.)

    It self-elevates (a single UAC prompt), then in the elevated window it:
      1. prints the address to type into the iPhone app,
      2. makes sure the virtual-camera DLL is installed machine-wide,
      3. registers the camera for ALL users (so Teams, Zoom, Discord all see it),
      4. runs the host in the foreground so you can watch the log.

    Press Ctrl+C to stop the host AND unregister the camera.

    The script auto-detects a stale installed DLL: it compares the built
    source\bin DLL to the one in ProgramData by hash and reinstalls only when they
    differ, so a rebuilt DLL is picked up on the next launch with no extra flags.

    Switches:
      -Rebuild   force a fresh compile of the virtual-camera DLL before the
                 up-to-date check (the reinstall-on-change happens either way)
      -Debug     run the host as an unoptimised debug build (default is release)

    The host now runs OPTIMISED (release) by default: the debug build's openh264
    decode + YUV->RGBA + latest.rgba write could not always sustain 720p30, which
    showed up as lag. Pass -Debug only for a fast-iterating dev loop.
#>
param(
    [switch]$Rebuild,
    [switch]$Debug
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
    if ($Debug) { $argList += '-Debug' }
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

# --- 2. Ensure the machine-wide DLL is present AND matches the built one ---
# We compare the freshly-built source\bin DLL against the one installed in
# ProgramData by hash, and only (re)install when they differ. That way a rebuilt
# DLL is picked up automatically on the next launch — no need to remember -Rebuild
# — while an unchanged DLL skips the install (and its FrameServer restart) entirely.
$buildScript   = Join-Path $root 'windows-virtual-camera\source\build.ps1'
$installScript = Join-Path $root 'windows-virtual-camera\source\install-machine.ps1'
$sourceDll     = Join-Path $root 'windows-virtual-camera\source\bin\iphone_camera_source.dll'
$installedDll  = Join-Path $env:ProgramData 'IPhoneCameraStreaming\iphone_camera_source.dll'

if ($Rebuild) {
    Write-Host 'Rebuilding the virtual-camera DLL (-Rebuild)...' -ForegroundColor Cyan
    & $buildScript
}
# Need a built DLL to compare against; build one if this is a fresh checkout.
if (-not (Test-Path $sourceDll)) {
    Write-Host 'No built DLL found; building it...' -ForegroundColor Cyan
    & $buildScript
}

function Get-DllHash($path) {
    if (Test-Path $path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash } else { $null }
}
$sourceHash    = Get-DllHash $sourceDll
$installedHash = Get-DllHash $installedDll

if (-not $installedHash) {
    Write-Host 'Virtual-camera DLL not installed yet; installing machine-wide...' -ForegroundColor Cyan
    & $installScript
} elseif ($sourceHash -and $sourceHash -ne $installedHash) {
    Write-Host 'Installed DLL is out of date; updating machine-wide (restarts the frame server)...' -ForegroundColor Cyan
    & $installScript
} else {
    Write-Host 'Virtual-camera DLL is already up to date.' -ForegroundColor DarkGray
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
    if (-not $Debug) { $hostArgs += '--release' }
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
