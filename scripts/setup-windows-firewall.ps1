# Run this script from an elevated PowerShell window.
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Please run this script from an Administrator PowerShell window.'
    }
}

Ensure-Admin

$tcpRule = 'iPhone Camera Streaming TCP 41000'
$videoTcpRule = 'iPhone Camera Streaming TCP 41001'
$webRtcRule = 'iPhone Camera Streaming TCP 41003'

if (-not (Get-NetFirewallRule -DisplayName $tcpRule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $tcpRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 41000 -Profile Private | Out-Null
}

if (-not (Get-NetFirewallRule -DisplayName $videoTcpRule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $videoTcpRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 41001 -Profile Private | Out-Null
}

if (-not (Get-NetFirewallRule -DisplayName $webRtcRule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $webRtcRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 41003 -Profile Private | Out-Null
}

Write-Host 'Firewall rules are ready for TCP 41000, TCP 41001, and TCP 41003.' -ForegroundColor Green
